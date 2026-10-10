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

final class FramePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "metz.stream.encoder", qos: .userInteractive)
    private var session: VTCompressionSession?
    private var pending: (CVPixelBuffer, CMTime)?
    // Encoder and transmission overlap, but compressed reference frames remain ordered.
    // At most one encode, one queued packet and one transmission can exist.
    private var encoding = false // encoder queue only
    private var sending = false // encoder queue only
    private var queuedPacket: (Data, UInt64)? // encoder queue only
    private var encodingBegan = 0.0
    private var stopped = false
    private var basePTS: CMTime?
    private var lastPTS: CMTime = .invalid
    private var forceIDR = true
    private var encoded = 0
    private var captured = 0
    private var audioSubmitted = 0
    private var codecFrames = 0
    private var encoderLatency = FrameLatency()
    private var admissionLatency = FrameLatency()
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
    var timing: (FrameCadence, FrameCadence) { lock.lock(); defer { lock.unlock() }; return (captureCadence, admissionCadence) }
    var processing: (frames: Int, encoder: FrameLatency, admission: FrameLatency) {
        lock.lock(); defer { lock.unlock() }; return (codecFrames, encoderLatency, admissionLatency)
    }

    init(transport: FramePacketTransport, mode: StreamMode = .conservative, audio: Bool = false) throws {
        guard mode.valid else { throw StreamError.invalid }
        self.transport = transport; self.mode = mode; self.audio = audio
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

    func submit(_ buffer: CVPixelBuffer, pts: CMTime) {
        guard pts.isValid, pts.isNumeric, CVPixelBufferGetWidth(buffer) == mode.width,
              CVPixelBufferGetHeight(buffer) == mode.height else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        captured += 1
        captureCadence.record(pts.seconds, expectedFPS: mode.fps)
        if pending != nil { dropped += 1 }
        pending = (buffer, pts)
        lock.unlock()
        queue.async { self.encodeNext() }
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
        encodingBegan = ProcessInfo.processInfo.systemUptime
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
            lock.lock(); self.dropped += 1; lock.unlock()
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
                let config: [String: Any] = ["width": mode.width, "height": mode.height, "fps": mode.fps, "profile": "baseline-" + mode.level, "audio": audio, "telemetry": true,
                    "sps": sets[0].base64EncodedString(), "pps": sets[1].base64EncodedString()]
                packets.append(try Wire.packet(type: 1, epoch: epoch, payload: JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])))
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let us = CMTimeConvertScale(time, timescale: 1_000_000, method: .roundTowardZero).value
            guard us >= 0 else { throw StreamError.invalid }
            packets.append(try Wire.packet(type: 2, flags: key ? 1 : 0, epoch: epoch, pts: UInt64(us),
                payload: Wire.annexB(avcc, nalLength: Int(nalLength))))
            lock.lock(); codecFrames += 1
            encoderLatency.record(seconds: ProcessInfo.processInfo.systemUptime - encodingBegan)
            lock.unlock()
            encoding = false
            queuedPacket = (packets, UInt64(us))
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
        guard !sending, let packet = queuedPacket else { return }
        lock.lock(); let inactive = stopped; lock.unlock()
        guard !inactive else { return }
        queuedPacket = nil
        sending = true
        let began = ProcessInfo.processInfo.systemUptime
        transport.send(packet.0, pts: packet.1) { [weak self] success in
            guard let self else { return }
            self.queue.async {
                self.lock.lock()
                guard !self.stopped else { self.lock.unlock(); return }
                if success {
                    self.encoded += 1
                    self.admissionCadence.record(ProcessInfo.processInfo.systemUptime, expectedFPS: self.mode.fps)
                    self.admissionLatency.record(seconds: ProcessInfo.processInfo.systemUptime - began)
                }
                self.lock.unlock()
                self.sending = false
                guard success else { self.failed("Не удалось передать кадр на ТВ."); return }
                self.sendNext()
                self.encodeNext()
            }
        }
    }
    private func failed(_ reason: String) {
        lock.lock(); let notify = !stopped; stopped = true; pending = nil; lock.unlock()
        if notify { failure?(reason) }
    }
    func stop() {
        lock.lock(); stopped = true; pending = nil; lock.unlock()
        queue.sync {
            queuedPacket = nil
            encoding = false; sending = false
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
        }
    }
}
