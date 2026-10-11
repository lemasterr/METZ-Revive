import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox

enum EncoderOutputDisposition {
    case failed, dropped, encoded
    static func classify(status: OSStatus, dropped: Bool) -> Self {
        if status != noErr { return .failed }
        return dropped ? .dropped : .encoded
    }
}

enum SessionAudioTime {
    static func relative(_ captureUS: UInt64, origin: CMTime) -> UInt64? {
        let start = CMTimeConvertScale(origin, timescale: 1_000_000, method: .roundTowardZero)
        guard start.isNumeric, start.value >= 0, captureUS >= UInt64(start.value) else { return nil }
        return captureUS - UInt64(start.value)
    }
}

struct FramePipelineSnapshot {
    let captured, selected, selectionSkipped, replaced, codecDropped, admitted, codecFrames, bytes, audioPackets: Int
    let freshSelected, repeatedSelected, pacingSkipped: Int
    let freshEncoded, repeatedEncoded: Int
    let capture, admission: FrameCadence
    let rawQueue, encoderLatency, admissionLatency, captureDelivery: FrameLatency
    var numbers: [String: Double] {
        var result = ["capture_frames": Double(captured), "selected_frames": Double(selected),
            "selection_skipped": Double(selectionSkipped), "raw_replaced": Double(replaced),
            "codec_dropped": Double(codecDropped), "admitted_frames": Double(admitted),
            "encoded_frames": Double(codecFrames), "video_bytes": Double(bytes), "audio_submitted": Double(audioPackets),
            "fresh_selected": Double(freshSelected), "repeated_selected": Double(repeatedSelected),
            "pacing_skipped": Double(pacingSkipped),
            "fresh_encoded": Double(freshEncoded), "repeated_encoded": Double(repeatedEncoded),
            "capture_long_gaps": Double(capture.longGaps), "admission_long_gaps": Double(admission.longGaps)]
        for (name, value) in [("capture_p95_ms", capture.p95MS), ("capture_max_ms", capture.maximumMS),
            ("admission_p95_ms", admission.p95MS), ("admission_max_ms", admission.maximumMS),
            ("raw_queue_p95_ms", rawQueue.p95MS), ("capture_delivery_p95_ms", captureDelivery.p95MS),
            ("encode_p95_ms", encoderLatency.p95MS),
            ("ack_p95_ms", admissionLatency.p95MS)] {
            if let value { result[name] = value }
        }
        return result
    }
}

final class FramePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "metz.stream.encoder", qos: .userInteractive)
    private var session: VTCompressionSession?
    private var pending: (CVPixelBuffer, CMTime, Double, Int, Int)?
    // Encoder and transmission overlap, but compressed reference frames remain ordered.
    // At most one encode, one queued packet and two transmissions can exist.
    private var encoding = false // encoder queue only
    private var sending = 0 // encoder queue only
    private var queuedPacket: (Data, UInt64, Int, Double)? // encoder queue only
    private var encodingFrameID = 0
    private var encodingSourceID = 0 // encoder queue
    private var lastEncodedSourceID = 0 // encoder queue
    private var encodingBegan = 0.0
    private var stopped = false
    private var basePTS: CMTime?
    private var lastPTS: CMTime = .invalid
    private var forceIDR = true
    private var encoded = 0
    private var captured = 0
    private var frameSelector = FrameRateSelector()
    private let paced: Bool
    private var latestCapture: (buffer: CVPixelBuffer, pts: CMTime, source: Int)? // lock
    private var selectedSource = 0 // lock
    private var freshSelected = 0 // lock
    private var repeatedSelected = 0 // lock
    private var pacingSkipped = 0 // lock
    private var freshEncoded = 0 // lock
    private var repeatedEncoded = 0 // lock
    private var pacingStarted = false // lock
    private var pacingTimer: DispatchSourceTimer? // encoder queue
    private var frameClock: FrameClock? // encoder queue
    private var clockPTS: CMTime? // encoder queue
    private let sourceFPS: Int
    private let journal: StreamJournal?
    private var captureOrigin: CMTime?
    private var selected = 0
    private var selectionSkipped = 0
    private var replaced = 0
    private var codecDropped = 0
    private var audioSubmitted = 0
    private var codecFrames = 0
    private var videoBytes = 0
    private var rawQueue = FrameLatency()
    private var encoderLatency = FrameLatency()
    private var admissionLatency = FrameLatency()
    private var captureDelivery = FrameLatency()
    private var captureCadence = FrameCadence()
    private var admissionCadence = FrameCadence()
    private var dropped = 0
    private let epoch = UInt32.random(in: 1...UInt32.max)
    let transport: FramePacketTransport
    let mode: StreamMode
    let audio: Bool
    var failure: ((String) -> Void)?
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (encoded, dropped) }
    var capturedCount: Int { lock.lock(); defer { lock.unlock() }; return captured }
    var audioPacketCount: Int { lock.lock(); defer { lock.unlock() }; return audioSubmitted }
    var snapshot: FramePipelineSnapshot {
        lock.lock(); defer { lock.unlock() }
        return FramePipelineSnapshot(captured: captured, selected: selected, selectionSkipped: selectionSkipped,
            replaced: replaced, codecDropped: codecDropped, admitted: encoded, codecFrames: codecFrames,
            bytes: videoBytes, audioPackets: audioSubmitted,
            freshSelected: freshSelected, repeatedSelected: repeatedSelected, pacingSkipped: pacingSkipped,
            freshEncoded: freshEncoded, repeatedEncoded: repeatedEncoded,
            capture: captureCadence, admission: admissionCadence,
            rawQueue: rawQueue, encoderLatency: encoderLatency, admissionLatency: admissionLatency, captureDelivery: captureDelivery)
    }
    var timing: (FrameCadence, FrameCadence) { lock.lock(); defer { lock.unlock() }; return (captureCadence, admissionCadence) }
    var processing: (frames: Int, bytes: Int, rawQueue: FrameLatency, encoder: FrameLatency, admission: FrameLatency) {
        lock.lock(); defer { lock.unlock() }; return (codecFrames, videoBytes, rawQueue, encoderLatency, admissionLatency)
    }

    init(transport: FramePacketTransport, mode: StreamMode = .conservative, audio: Bool = false,
         sourceFPS: Int = 60, journal: StreamJournal? = nil, paced: Bool = false) throws {
        guard mode.valid else { throw StreamError.invalid }
        self.transport = transport; self.mode = mode; self.audio = audio
        self.sourceFPS = max(1, sourceFPS); self.journal = journal; self.paced = paced
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(mode.width), height: Int32(mode.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, flags, sample in
                guard let refcon else { return }
                let pipeline = Unmanaged<FramePipeline>.fromOpaque(refcon).takeUnretainedValue()
                pipeline.queue.async { pipeline.output(status: status, dropped: flags.contains(.frameDropped), sample: sample) }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else { throw StreamError.unavailable }
        self.session = session
        do {
            let properties: [(CFString, CFTypeRef)] = [
                (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
                (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
                // Low-latency rate control does not bound decoder reference buffers.
                // Keep the emitted decoder buffer requirement small for live display.
                (kVTCompressionPropertyKey_ReferenceBufferCount, NSNumber(value: 1)),
                (kVTCompressionPropertyKey_ProfileLevel, ("H264_Baseline_" + mode.level.replacingOccurrences(of: ".", with: "_")) as CFString),
                (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: mode.width * mode.height * mode.fps / 9)),
                (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: mode.fps)),
                (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: mode.fps))
            ]
            for (key, value) in properties {
                guard VTSessionSetProperty(session, key: key, value: value) == noErr else { throw StreamError.unavailable }
            }
            // Apple's low-latency hardware encoder may reject this optional property.
            // RealTime, disabled reordering and low-latency rate control remain required.
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 1))
            var hardware: Unmanaged<CFTypeRef>?
            let hardwareStatus = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: nil, valueOut: &hardware)
            let hardwareValue = hardware?.takeRetainedValue() as? Bool
            // The low-latency encoder returns PropertyNotSupported for this query.
            // RequireHardware at creation already prohibits software fallback; a reported false still fails.
            guard (hardwareStatus == noErr && hardwareValue == true) || hardwareStatus == kVTPropertyNotSupportedErr,
                VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { throw StreamError.unavailable }
        } catch { VTCompressionSessionInvalidate(session); self.session = nil; throw error }
    }

    func submit(_ buffer: CVPixelBuffer, pts: CMTime, deliverySeconds: Double? = nil) {
        guard pts.isValid, pts.isNumeric, CVPixelBufferGetWidth(buffer) == mode.width,
              CVPixelBufferGetHeight(buffer) == mode.height else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        if paced, let latest = latestCapture, pts <= latest.pts { lock.unlock(); return }
        captured += 1
        if let deliverySeconds { captureDelivery.record(seconds: deliverySeconds) }
        captureCadence.record(pts.seconds, expectedFPS: sourceFPS)
        if captureOrigin == nil { captureOrigin = pts }
        if paced {
            var captureFields = ["frame": Double(captured),
                "source_pts_us": CMTimeSubtract(pts, captureOrigin!).seconds * 1_000_000]
            if let deliverySeconds, deliverySeconds.isFinite, deliverySeconds >= 0 {
                captureFields["delivery_ms"] = deliverySeconds * 1000
            }
            journal?.record(.capture, captureFields)
            // Keep only the newest source surface, including while transmission is blocked.
            if let previous = latestCapture, previous.source != selectedSource { selectionSkipped += 1 }
            latestCapture = (buffer, pts, captured)
            let start = !pacingStarted; pacingStarted = true
            lock.unlock()
            if start { queue.async { self.startPacing() } }
            return
        }
        let accept = frameSelector.accepts(pts.seconds, fps: mode.fps)
        journal?.record(.capture, ["frame": Double(captured),
            "source_pts_us": CMTimeSubtract(pts, captureOrigin!).seconds * 1_000_000, "selected": accept ? 1 : 0])
        if !accept { selectionSkipped += 1; lock.unlock(); return }
        selected += 1; freshSelected += 1
        if let pending {
            dropped += 1; replaced += 1
            journal?.record(.replaced, ["frame": Double(pending.3), "by_frame": Double(captured)])
        }
        pending = (buffer, pts, ProcessInfo.processInfo.systemUptime, captured, captured)
        lock.unlock()
        queue.async { self.encodeNext() }
    }

    private func startPacing() {
        lock.lock()
        guard !stopped, let first = latestCapture else { lock.unlock(); return }
        basePTS = first.pts; clockPTS = first.pts
        lock.unlock()
        // Sampling on the capture boundary races its callback: one source update
        // is repeated, then two arrive before the next tick. Sample between source
        // deadlines instead, leaving half a source interval for callback jitter.
        let samplingDelay = FrameClock.captureMargin(sourceFPS: sourceFPS, outputFPS: mode.fps)
        frameClock = FrameClock(origin: ProcessInfo.processInfo.systemUptime + samplingDelay, fps: mode.fps)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + samplingDelay, repeating: 1 / Double(mode.fps), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.paceNext() }
        pacingTimer = timer; timer.resume()
    }

    private func paceNext() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let tick = frameClock?.tick(at: now), let origin = clockPTS else { return }
        lock.lock()
        guard !stopped, let latest = latestCapture else { lock.unlock(); return }
        let repeated = latest.source == selectedSource
        selectedSource = latest.source
        if repeated { repeatedSelected += 1 } else { freshSelected += 1 }
        selected += 1; pacingSkipped += Int(tick.skipped)
        let pts = CMTimeAdd(origin, CMTime(value: tick.index, timescale: Int32(mode.fps)))
        journal?.record(.pace, ["frame": Double(selected), "source_frame": Double(latest.source),
            "source_pts_us": CMTimeSubtract(latest.pts, captureOrigin!).seconds * 1_000_000,
            "pts_us": CMTimeSubtract(pts, origin).seconds * 1_000_000,
            "repeated": repeated ? 1 : 0, "late_ms": tick.lateMS,
            "skipped": Double(tick.skipped)])
        if let previous = pending {
            dropped += 1; replaced += 1
            journal?.record(.replaced, ["frame": Double(previous.3), "by_frame": Double(selected)])
        }
        pending = (latest.buffer, pts, now, selected, latest.source)
        lock.unlock()
        encodeNext()
    }
    func requestKeyframe() { queue.async {
        self.lock.lock(); let inactive = self.stopped; self.lock.unlock()
        if !inactive { self.forceIDR = true }
    } }

    private func encodeNext() {
        guard !encoding, queuedPacket == nil else { return }
        lock.lock()
        guard !stopped, let frame = pending else { lock.unlock(); return }
        pending = nil
        lock.unlock()
        guard let session else { failed("Кодировщик недоступен."); return }
        lock.lock()
        if basePTS == nil { basePTS = frame.1 }
        let origin = basePTS!
        lock.unlock()
        let pts = CMTimeSubtract(frame.1, origin)
        if pts < .zero || (lastPTS.isValid && pts <= lastPTS) { encodeNext(); return }
        lastPTS = pts
        let properties: CFDictionary? = forceIDR ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceIDR = false
        var flags: VTEncodeInfoFlags = []
        encoding = true
        encodingFrameID = frame.3
        encodingSourceID = frame.4
        encodingBegan = ProcessInfo.processInfo.systemUptime
        lock.lock(); rawQueue.record(seconds: encodingBegan - frame.2); lock.unlock()
        journal?.record(.encode, ["frame": Double(encodingFrameID),
            "raw_wait_ms": (encodingBegan - frame.2) * 1000])
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: frame.0, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: Int32(mode.fps)), frameProperties: properties,
            sourceFrameRefcon: nil, infoFlagsOut: &flags)
        if status != noErr { failed("Ошибка подачи кадра H.264 (\(status)).") }
    }

    private func output(status: OSStatus, dropped: Bool, sample: CMSampleBuffer?) {
        lock.lock(); let inactive = stopped; lock.unlock()
        guard !inactive else { return }
        let result = EncoderOutputDisposition.classify(status: status, dropped: dropped)
        guard result != .failed else { failed("Ошибка кодирования H.264 (\(status))."); return }
        // VideoToolbox may drop a frame successfully under real-time load.
        // No compressed reference frame exists to send; continue with the latest raw frame.
        if result == .dropped {
            lock.lock(); self.dropped += 1; codecDropped += 1; lock.unlock()
            journal?.record(.codecDrop, ["frame": Double(encodingFrameID)])
            forceIDR = true
            encoding = false
            encodeNext()
            return
        }
        guard let sample, CMSampleBufferDataIsReady(sample),
              let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { failed("Кодировщик не вернул данные кадра."); return }
        do {
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0, length <= Wire.maximumPayload else { throw StreamError.invalid }
            var avcc = Data(count: length)
            let copied = avcc.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard copied == noErr else { throw StreamError.invalid }
            var nalLength: Int32 = 0
            var count = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalLength) == noErr else { throw StreamError.invalid }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
            var packets = Data()
            if key {
                guard count == 2 else { throw StreamError.invalid }
                var sets: [Data] = []
                for index in 0..<count {
                    var pointer: UnsafePointer<UInt8>?, size = 0
                    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                        let pointer, size > 0, size <= 4096 else { throw StreamError.invalid }
                    sets.append(Data([0, 0, 0, 1]) + Data(bytes: pointer, count: size))
                }
                let config: [String: Any] = ["width": mode.width, "height": mode.height, "fps": mode.fps, "profile": "baseline-" + mode.level, "audio": audio, "telemetry": true, "frame_trace": journal != nil,
                    "sps": sets[0].base64EncodedString(), "pps": sets[1].base64EncodedString()]
                packets.append(try Wire.packet(type: 1, epoch: epoch, payload: JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])))
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let us = CMTimeConvertScale(time, timescale: 1_000_000, method: .roundTowardZero).value
            guard us >= 0 else { throw StreamError.invalid }
            packets.append(try Wire.packet(type: 2, flags: key ? 1 : 0, epoch: epoch, pts: UInt64(us),
                payload: Wire.annexB(avcc, nalLength: Int(nalLength))))
            let completed = ProcessInfo.processInfo.systemUptime
            let repeated = encodingSourceID == lastEncodedSourceID
            lastEncodedSourceID = encodingSourceID
            lock.lock(); codecFrames += 1; videoBytes += packets.count
            if repeated { repeatedEncoded += 1 } else { freshEncoded += 1 }
            encoderLatency.record(seconds: completed - encodingBegan)
            lock.unlock()
            journal?.record(.encoded, ["frame": Double(encodingFrameID), "pts_us": Double(us),
                "bytes": Double(packets.count), "encode_ms": (completed - encodingBegan) * 1000,
                "keyframe": key ? 1 : 0, "source_frame": Double(encodingSourceID),
                "repeated": repeated ? 1 : 0])
            encoding = false
            queuedPacket = (packets, UInt64(us), encodingFrameID, completed)
            sendNext()
            encodeNext()
        } catch { failed("Некорректный кадр H.264.") }
    }

    func submitAudio(_ pcm: Data, pts: UInt64) {
        lock.lock(); let ready = !stopped && encoded > 0, origin = basePTS; lock.unlock()
        guard audio, ready, let origin,
            let relative = SessionAudioTime.relative(pts, origin: origin),
            let packet = try? Wire.packet(type: 4, epoch: epoch, pts: relative, payload: pcm) else { return }
        lock.lock(); audioSubmitted += 1; lock.unlock()
        transport.sendAudio(packet)
    }
    private func sendNext() {
        guard sending < min(2, max(1, transport.frameCapacity)), let packet = queuedPacket else { return }
        lock.lock(); let inactive = stopped; lock.unlock()
        guard !inactive else { return }
        queuedPacket = nil
        sending += 1
        let began = ProcessInfo.processInfo.systemUptime
        journal?.record(.send, ["frame": Double(packet.2), "pts_us": Double(packet.1),
            "wait_ms": (began - packet.3) * 1000, "credits_used": Double(sending)])
        transport.send(packet.0, pts: packet.1) { [weak self] success in
            guard let self else { return }
            self.queue.async {
                self.lock.lock()
                guard !self.stopped else { self.lock.unlock(); return }
                if success {
                    self.encoded += 1
                    self.admissionCadence.record(ProcessInfo.processInfo.systemUptime, expectedFPS: self.mode.fps)
                    self.admissionLatency.record(seconds: ProcessInfo.processInfo.systemUptime - began)
                    self.journal?.record(.admission, ["frame": Double(packet.2), "pts_us": Double(packet.1),
                        "ack_ms": (ProcessInfo.processInfo.systemUptime - began) * 1000])
                }
                self.lock.unlock()
                self.sending -= 1
                guard success else { self.failed("Не удалось передать кадр на ТВ."); return }
                self.sendNext()
                self.encodeNext()
            }
        }
    }
    private func failed(_ reason: String) {
        lock.lock(); let notify = !stopped; stopped = true; pending = nil; latestCapture = nil; lock.unlock()
        pacingTimer?.cancel(); pacingTimer = nil
        if notify { failure?(reason) }
    }
    func stop() {
        lock.lock(); stopped = true; pending = nil; latestCapture = nil; lock.unlock()
        queue.sync {
            pacingTimer?.cancel(); pacingTimer = nil; frameClock = nil; clockPTS = nil
            queuedPacket = nil
            encoding = false; sending = 0
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
        }
    }
}
