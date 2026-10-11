import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import QuartzCore

@MainActor
private final class RuntimeMotionView: NSView {
    private(set) var tick = 0
    func startMotion(pattern: String = "bar") {
        wantsLayer = true
        guard let layer, bounds.width > 120 else { return }
        layer.backgroundColor = NSColor.black.cgColor
        if pattern == "grid" {
            for row in 0..<6 { for column in 0..<10 {
                let tile = CAGradientLayer()
                let cell = CGSize(width: bounds.width / 10, height: bounds.height / 6)
                tile.bounds = CGRect(origin: .zero, size: cell)
                tile.position = CGPoint(x: (Double(column) + 0.5) * cell.width, y: (Double(row) + 0.5) * cell.height)
                tile.colors = [NSColor(hue: CGFloat((row * 10 + column) % 13) / 13,
                    saturation: 0.8, brightness: 0.9, alpha: 1).cgColor, NSColor.black.cgColor]
                tile.startPoint = CGPoint(x: 0, y: 0); tile.endPoint = CGPoint(x: 1, y: 1)
                layer.addSublayer(tile)
                let movement = CABasicAnimation(keyPath: "transform.rotation.z")
                movement.fromValue = 0; movement.toValue = Double.pi * 2
                movement.duration = 2 + Double((row + column) % 4) / 3
                movement.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
                movement.repeatCount = .greatestFiniteMagnitude
                movement.timingFunction = CAMediaTimingFunction(name: .linear)
                tile.add(movement, forKey: "runtimeGrid")
            } }
            return
        }
        let bar = CALayer()
        bar.bounds = CGRect(x: 0, y: 0, width: 120, height: bounds.height)
        bar.position = CGPoint(x: 60, y: bounds.midY)
        bar.backgroundColor = NSColor.systemBlue.cgColor
        layer.addSublayer(bar)
        let movement = CABasicAnimation(keyPath: "position.x")
        movement.fromValue = 60; movement.toValue = bounds.width - 60
        movement.duration = 3; movement.autoreverses = true
        movement.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        movement.repeatCount = .greatestFiniteMagnitude
        movement.timingFunction = CAMediaTimingFunction(name: .linear)
        bar.add(movement, forKey: "runtimeMotion")
    }
    // This counts clock callbacks only. Captured complete frames measure compositor output.
    @objc func advance(_ link: CADisplayLink) { tick += 1 }
}

private final class DisplayCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let pipeline: FramePipeline
    private let lock = NSLock()
    private var frameStates: [Int: Int] = [:]
    var frameCounts: (complete: Int, idle: Int, other: Int) {
        lock.lock(); defer { lock.unlock() }
        let complete = frameStates[SCFrameStatus.complete.rawValue, default: 0]
        let idle = frameStates[SCFrameStatus.idle.rawValue, default: 0]
        return (complete, idle, frameStates.values.reduce(0, +) - complete - idle)
    }
    var failure: ((String) -> Void)?
    init(pipeline: FramePipeline) { self.pipeline = pipeline }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { submitAudio(sample); return }
        guard type == .screen, sample.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int else { return }
        lock.lock(); frameStates[status, default: 0] += 1; lock.unlock()
        guard status == SCFrameStatus.complete.rawValue,
            let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        // displayTime is mach absolute time, independently of the sample PTS epoch.
        // Convert it explicitly; absent metadata must not become zero latency.
        let delivery = (attachments.first?[.displayTime] as? NSNumber).flatMap { timestamp -> Double? in
            guard timestamp.uint64Value > 0 else { return nil }
            let displayed = CMClockMakeHostTimeFromSystemUnits(timestamp.uint64Value)
            let seconds = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), displayed).seconds
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        }
        pipeline.submit(buffer, pts: pts, deliverySeconds: delivery)
    }
    private func submitAudio(_ sample: CMSampleBuffer) {
        guard sample.isValid, let description = CMSampleBufferGetFormatDescription(sample),
            let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
            format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == 48000,
            format.mChannelsPerFrame == 2, format.mBitsPerChannel == 32,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= 2048 else { return }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard buffers.count == (planar ? 2 : 1), buffers.allSatisfy({ $0.mData != nil && Int($0.mDataByteSize) >= frames * (planar ? 4 : 8) }) else { return }
        var pcm = Data(count: frames * 4)
        pcm.withUnsafeMutableBytes { storage in
            let samples = storage.bindMemory(to: Int16.self)
            for frame in 0..<frames { for channel in 0..<2 {
                let value = buffers[planar ? channel : 0].mData!.assumingMemoryBound(to: Float.self)[planar ? frame : frame * 2 + channel]
                let clamped = value.isFinite ? min(1, max(-1, value)) : 0
                samples[frame * 2 + channel] = Int16(clamped * 32767).littleEndian
            } }
        }
        let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 1_000_000, method: .roundTowardZero).value
        if pts >= 0 { pipeline.submitAudio(pcm, pts: UInt64(pts)) }
        withExtendedLifetime(block) {}
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Numeric error only: descriptions may contain window titles or private paths.
        failure?("Захват экрана остановлен (\((error as NSError).code)).")
    }
}

@MainActor
final class ConnectionManager: ObservableObject {
    private var streamActivity: NSObjectProtocol?
    @Published private(set) var status = "Готов к подключению"
    @Published private(set) var active = false
    @Published private(set) var statistics = ""
    @Published private(set) var processingStatistics = ""
    @Published private(set) var decodedOnTV = false
    @Published private(set) var isStopping = false
    @Published private(set) var configuredMode = StreamMode.conservative
    @Published private(set) var capturedFPS: Double?
    @Published private(set) var admittedFPS: Double?
    @Published private(set) var outputFPS: Double?
    @Published private(set) var renderedFPS: Double?
    private var previousReport: TVFrameReport?
    private var lastReportTime: Double?
    private var journal: StreamJournal?
    private var sourceRefresh: Double?
    private var previousSample: (time: Double, captured: Int, admitted: Int, bytes: Int)?
    private var previousEncodedFrames = 0
    @Published private(set) var lastFailure = UserDefaults.standard.string(forKey: "displayLastFailure") ?? ""
    private var lastDisplayID: CGDirectDisplayID = 0
    private var captureDisplayID: CGDirectDisplayID = 0
    private var mode = StreamMode.conservative
    @Published private(set) var audio = false
    private var testWindow: NSWindow?
    private var originalCursor: CGPoint?
    private var handle: UnsafeMutableRawPointer?
    private var capture: SCStream?
    private var output: DisplayCaptureEngine?
    private var pipeline: FramePipeline?
    private var transport: StreamTransport?
    private var startTask: Task<Void, Never>?
    private var token = UUID()
    private var stopping = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var monitor: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    init() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.stop() } }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.capture != nil else { return }
                    let id = self.captureDisplayID
                    if DisplayTopology.state(of: id)?.matches(self.mode) != true {
                        await self.stop(reason: "Экран изменён. Подключите заново.")
                    }
                }
            }
    }
    deinit {
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
    func showReadinessError(_ message: String) {
        guard !active else { return }
        status = message
        lastFailure = message
        UserDefaults.standard.set(message, forKey: "displayLastFailure")
    }

    func start(host: String, pin: String, identity: StreamIdentity, existingVirtualDisplay: CGDirectDisplayID? = nil, mode: StreamMode = .conservative, audio: Bool = false) {
        guard !active, !stopping, mode.valid else { return }
        self.mode = mode; self.audio = audio
        configuredMode = mode
        active = true; status = "Проверка доступа к экрану…"; statistics = ""; processingStatistics = ""; decodedOnTV = false
        streamActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Передача второго экрана на телевизор")
        capturedFPS = nil; admittedFPS = nil; outputFPS = nil; renderedFPS = nil
        previousReport = nil; previousSample = nil; lastReportTime = nil; sourceRefresh = nil
        journal = try? StreamJournal(mode: mode, audio: audio)
        let current = UUID(); token = current
        let transport = StreamTransport(); self.transport = transport
        let sessionJournal = journal
        transport.frameTrace = { trace in
            sessionJournal?.record(.tvReport, ["trace_omitted": Double(trace.omitted)])
            for frame in trace.frames {
                sessionJournal?.record(.tvFrame, ["stage": Double(frame.stage), "pts_us": Double(frame.pts),
                    "receiver_elapsed_us": Double(frame.elapsedUS)])
            }
        }
        transport.failure = { [weak self] reason in Task { @MainActor in
            guard let self, self.token == current else { return }
            await self.stop(reason: reason)
        } }
        transport.decoded = { [weak self] in Task { @MainActor in
            guard let self, self.token == current, self.active else { return }
            self.decodedOnTV = true
            self.status = "Второй экран подключён · ТВ подтвердил декодирование"
        } }
        transport.frameReport = { [weak self] report in Task { @MainActor in
            guard let self, self.token == current, self.active else { return }
            if let previous = self.previousReport, let rates = report.rates(since: previous) {
                self.outputFPS = rates.0
                // Android 11 does not guarantee a render callback for every
                // Surface frame. An absent callback is not a measured zero FPS.
                self.renderedFPS = report.rendered > 0 ? rates.1 : nil
            }
            self.previousReport = report
            self.lastReportTime = ProcessInfo.processInfo.systemUptime
            self.journal?.record(.tvReport, ["output_frames": Double(report.output),
                "rendered_frames": Double(report.rendered), "receiver_elapsed_us": Double(report.elapsedUS)])
        } }
        transport.keyframeRequested = { [weak self] in Task { @MainActor in
            guard let self, self.token == current else { return }
            self.pipeline?.requestKeyframe()
        } }
        transport.ready = { [weak self] in Task { @MainActor in
            guard let self, self.token == current, self.active, self.startTask == nil else { return }
            self.startTask = Task { await self.createAndCapture(current: current, transport: transport, existingVirtualDisplay: existingVirtualDisplay) }
        } }
        // ScreenCaptureKit is authoritative; a false CoreGraphics preflight must
        // not reject already authorized SCK access or repeatedly request permission.
        // This runs only after the user confirms starting the selected second screen.
        startTask = Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                try Task.checkCancellation()
                guard token == current else { return }
                startTask = nil
                status = "Защищённое подключение…"
                do { try transport.connect(host: host, pin: pin, identity: identity) }
                catch { await stop(reason: "Проверьте адрес, отпечаток и ключ подключения.") }
            } catch {
                if token == current { await cleanup(reason: CaptureAccess.explanation(error, stage: .access, application: applicationName)) }
                if token == current { startTask = nil }
            }
        }
    }

    private var applicationName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "METZ Manager" }

    private func createAndCapture(current: UUID, transport: StreamTransport, existingVirtualDisplay: CGDirectDisplayID?) async {
        var stage = CaptureStage.virtualDisplay
        do {
            status = "Создание второго экрана…"
            let id: CGDirectDisplayID
            let sourceMode = StreamMode(width: mode.width, height: mode.height, fps: 60)
            if let existingVirtualDisplay {
                // Explicit user selection only. Never fall back to an arbitrary physical screen.
                guard existingVirtualDisplay != CGMainDisplayID(),
                    let selected = DisplayTopology.state(of: existingVirtualDisplay), !selected.builtIn,
                    selected.matches(mode) else { throw StreamError.invalid }
                id = existingVirtualDisplay
            } else {
                var failure = METZDisplayFailure.none
                guard let created = METZCreateDisplayWithMode(UInt32(mode.width), UInt32(mode.height), UInt32(sourceMode.fps), &failure) else { throw VirtualDisplayFailure.creation(Int(failure.rawValue)) }
                handle = created
                var identifier = METZDisplayID(created)
                for _ in 0..<50 {
                    try Task.checkCancellation()
                    if identifier != kCGNullDirectDisplay { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                    identifier = METZDisplayID(created)
                }
                guard identifier != kCGNullDirectDisplay else { throw VirtualDisplayFailure.registration }
                id = identifier
            }
            captureDisplayID = id
            lastDisplayID = id
            for _ in 0..<50 {
                try Task.checkCancellation()
                if DisplayTopology.state(of: id)?.active == true { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Task.checkCancellation()
            guard token == current else { throw CancellationError() }
            guard let registered = DisplayTopology.state(of: id), registered.active else { throw VirtualDisplayFailure.registration }
            if handle != nil {
                var requested: CGDisplayMode?
                for _ in 0..<30 {
                    try Task.checkCancellation()
                    let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? []
                    requested = modes.first { DisplayModeChoice.matches(width: $0.pixelWidth, height: $0.pixelHeight, rate: $0.refreshRate, requested: sourceMode) }
                    if requested != nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard let requested else { throw VirtualDisplayFailure.mode }
                var configuration: CGDisplayConfigRef?
                let begin = CGBeginDisplayConfiguration(&configuration)
                guard begin == .success, let configuration else {
                    throw VirtualDisplayFailure.mirrorOperation("начало настройки", Int(begin.rawValue))
                }
                if registered.mirrored {
                    let change = CGConfigureDisplayMirrorOfDisplay(configuration, id, kCGNullDirectDisplay)
                    guard change == .success else {
                        CGCancelDisplayConfiguration(configuration)
                        throw VirtualDisplayFailure.mirrorOperation("отключение зеркалирования", Int(change.rawValue))
                    }
                }
                let change = CGConfigureDisplayWithDisplayMode(configuration, id, requested, nil)
                guard change == .success else {
                    CGCancelDisplayConfiguration(configuration)
                    throw VirtualDisplayFailure.mirrorOperation("выбор разрешения", Int(change.rawValue))
                }
                let complete = CGCompleteDisplayConfiguration(configuration, .forSession)
                guard complete == .success else {
                    throw VirtualDisplayFailure.mirrorOperation("применение режима", Int(complete.rawValue))
                }
            }
            // Unmirroring can change the mode asynchronously. Wait for the
            // owned display's final mode rather than testing it in the same turn.
            for _ in 0..<50 {
                try Task.checkCancellation()
                if DisplayTopology.state(of: id)?.matches(mode) == true { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard token == current else { throw CancellationError() }
            guard let configured = DisplayTopology.state(of: id), configured.active else { throw VirtualDisplayFailure.registration }
            guard !configured.mirrored else { throw VirtualDisplayFailure.mirror }
            guard configured.matches(mode) else { throw VirtualDisplayFailure.mode }
            status = "Подготовка захвата экрана…"
            stage = .content
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            guard token == current, let display = content.displays.first(where: { $0.displayID == id }) else { throw StreamError.unavailable }
            stage = .encoder
            let refresh = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
            sourceRefresh = refresh > 0 && refresh.isFinite ? refresh : nil
            let encoder = try FramePipeline(transport: transport, mode: mode, audio: audio,
                sourceFPS: sourceRefresh.map { Int($0.rounded()) } ?? 60, journal: journal, paced: true)
            pipeline = encoder
            let failure: (String) -> Void = { [weak self] reason in Task { @MainActor in
                guard let self, self.token == current else { return }
                await self.stop(reason: "\(reason) Подключите заново.")
            } }
            encoder.failure = failure
            let output = DisplayCaptureEngine(pipeline: encoder); output.failure = failure; self.output = output
            stage = .capture
            let configuration = SCStreamConfiguration()
            configuration.width = mode.width; configuration.height = mode.height
            // Keep the owned compositor at 60 Hz. Select fresh frames on one
            // timeline for lower stream rates, instead of stacking equal-rate throttles.
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(handle != nil ? 60 : mode.fps))
            configuration.queueDepth = 5; configuration.showsCursor = true
            // Capture in the hardware encoder's native YUV format, avoiding retained
            // full-size RGB surfaces and a separate RGB conversion for every encode.
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.capturesAudio = audio
            configuration.sampleRate = 48000; configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = true
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: output)
            capture = stream
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "metz.stream.capture", qos: .userInteractive))
            if audio { try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "metz.stream.audio", qos: .userInitiated)) }
            try await stream.startCapture()
            try Task.checkCancellation()
            guard token == current else { throw CancellationError() }
            status = "Второй экран подключён · \(mode.title) · звук \(audio ? "включён" : "выключен")"
            previousSample = (ProcessInfo.processInfo.systemUptime, encoder.capturedCount, encoder.counts.0, encoder.processing.bytes)
            previousEncodedFrames = encoder.snapshot.codecFrames
            monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let pipeline = self.pipeline else { return }
                    guard self.token == current, self.active else { return }
                    let snapshot = pipeline.snapshot
                    var encodedMbps: Double?
                    let now = ProcessInfo.processInfo.systemUptime, captured = snapshot.captured
                    var fields = snapshot.numbers
                    fields["target_fps"] = Double(self.configuredMode.fps)
                    fields["source_refresh_hz"] = self.sourceRefresh
                    if let previous = self.previousSample, now > previous.time {
                        self.capturedFPS = Double(captured - previous.captured) / (now - previous.time)
                        self.admittedFPS = Double(snapshot.admitted - previous.admitted) / (now - previous.time)
                        encodedMbps = Double(snapshot.bytes - previous.bytes) * 8 / (now - previous.time) / 1_000_000
                        fields["interval_s"] = now - previous.time
                        fields["encoded_fps"] = Double(snapshot.codecFrames - self.previousEncodedFrames) / (now - previous.time)
                    }
                    self.previousEncodedFrames = snapshot.codecFrames
                    self.previousSample = (now, captured, snapshot.admitted, snapshot.bytes)
                    if let reportTime = self.lastReportTime {
                        fields["tv_report_age_s"] = now - reportTime
                        if now - reportTime > 2.5 { self.outputFPS = nil; self.renderedFPS = nil }
                    }
                    fields["capture_fps"] = self.capturedFPS; fields["admission_fps"] = self.admittedFPS
                    fields["output_fps"] = self.outputFPS; fields["surface_fps"] = self.renderedFPS
                    fields["video_mbps"] = encodedMbps
                    func fps(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "нет данных" }
                    self.statistics = "Кадры/с · захват Mac: \(fps(self.capturedFPS)) · приём декодера: \(fps(self.admittedFPS)) · выход декодера: \(fps(self.outputFPS)) · Surface ТВ: \(fps(self.renderedFPS))\nПринято: \(snapshot.admitted) · заменено до кодирования: \(snapshot.replaced) · пропущено кодером: \(snapshot.codecDropped)"
                    let frames = self.output?.frameCounts ?? (complete: 0, idle: 0, other: 0)
                    fields["capture_complete"] = Double(frames.complete); fields["capture_idle"] = Double(frames.idle)
                    fields["capture_other"] = Double(frames.other)
                    self.journal?.record(.sample, fields)
                    self.processingStatistics = "Видеопоток, кодирование: \(fps(encodedMbps)) Мбит/с\nКодирование, p95: \(fps(snapshot.encoderLatency.p95MS)) мс · доставка захвата, p95: \(fps(snapshot.captureDelivery.p95MS)) мс · подтверждение ТВ, p95: \(fps(snapshot.admissionLatency.p95MS)) мс\nЗахват: \(frames.complete) готовых · \(frames.idle) без обновления · \(frames.other) прочих · закодировано: \(snapshot.codecFrames)\nПланировщик \(self.configuredMode.fps): новых кадров захвата \(snapshot.freshEncoded) · повторов \(snapshot.repeatedEncoded)\nПропущено тактов: \(snapshot.pacingSkipped) · обновлений объединено: \(snapshot.selectionSkipped)"
                    if self.journal?.available != true { self.processingStatistics += "\nЖурнал сеанса недоступен" }
                }
            }
            startTask = nil
        } catch {
            if token == current { await cleanup(reason: CaptureAccess.explanation(error, stage: stage, application: applicationName)) }
            startTask = nil
        }
    }

    func stop(reason: String = "Остановлено") async {
        if stopping {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        stopping = true
        isStopping = true; status = "Остановка трансляции…"
        defer {
            stopping = false; isStopping = false
            let waiters = stopWaiters; stopWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        token = UUID()
        let starting = startTask; startTask = nil; starting?.cancel()
        await transport?.stopAndWait()
        await starting?.value
        await cleanup(reason: reason)
    }
    private func cleanup(reason: String) async {
        token = UUID()
        if reason != "Остановлено" {
            lastFailure = reason
            UserDefaults.standard.set(reason, forKey: "displayLastFailure")
        }
        monitor?.invalidate(); monitor = nil
        let sessionJournal = journal; journal = nil
        let ownedDisplay = handle != nil ? captureDisplayID : nil
        testWindow?.close(); testWindow = nil
        if let originalCursor { CGWarpMouseCursorPosition(originalCursor); self.originalCursor = nil }
        let stream = capture; capture = nil
        var captureStopped = true
        if let stream {
            do { try await stream.stopCapture() } catch { captureStopped = false }
        }
        pipeline?.stop()
        let finalCounts = pipeline?.snapshot.numbers ?? [:]
        pipeline = nil; output = nil
        await transport?.stopAndWait(); transport = nil
        if let handle {
            let releasedID = captureDisplayID
            METZReleaseDisplay(handle); self.handle = nil
            // WindowServer deregistration is asynchronous; do not race the next creation.
            for _ in 0..<20 {
                if DisplayTopology.contains(releasedID) != true { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        captureDisplayID = 0
        var endFields = finalCounts
        endFields["normal_stop"] = reason == "Остановлено" ? 1 : 0
        endFields["capture_released"] = capture == nil ? 1 : 0
        endFields["capture_stop_succeeded"] = captureStopped ? 1 : 0
        endFields["pipeline_released"] = pipeline == nil ? 1 : 0
        endFields["transport_released"] = transport == nil ? 1 : 0
        endFields["display_released"] = handle == nil ? 1 : 0
        if let ownedDisplay, let present = DisplayTopology.contains(ownedDisplay) {
            endFields["display_removed"] = present ? 0 : 1
        }
        await sessionJournal?.finish(endFields)
        if let activity = streamActivity { ProcessInfo.processInfo.endActivity(activity); streamActivity = nil }
        active = false; decodedOnTV = false; statistics = ""; processingStatistics = ""; status = reason
        capturedFPS = nil; admittedFPS = nil; outputFPS = nil; renderedFPS = nil
    }

    // Explicit --check only. Ordinary launch never creates a display or captures.
    func runtimeCheck(configuration: URL, prepare: ((String, @escaping (String?) -> Void) -> Void)? = nil) async {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: configuration.path)
            guard (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 16_384 else { throw StreamError.invalid }
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as? [String: String]
            guard let config, let host = config["host"], let pin = config["peer_pin"], let folder = config["identity_folder"] else { throw StreamError.invalid }
            let identity = try StreamIdentity(folder: URL(fileURLWithPath: folder))
            let requested = StreamMode(width: Int(config["width"] ?? "1366") ?? 1366,
                height: Int(config["height"] ?? "768") ?? 768, fps: Int(config["fps"] ?? "60") ?? 60)
            guard requested.valid else { throw StreamError.invalid }
            let withAudio = config["audio"] == "true"
            // Explicit runtime checks only; bound their duration and report size.
            let cycles = min(4, max(1, Int(config["cycles"] ?? "2") ?? 2))
            let measureSeconds = min(60, max(5, Int(config["measure_seconds"] ?? (withAudio ? "15" : "8")) ?? 8))
            // Let the newly launched benchmark UI settle before changing display topology.
            // This delay belongs to explicit checks, never to normal user sessions.
            try await Task.sleep(nanoseconds: 8_000_000_000)
            var runs: [[String: Any]] = []
            func checkpoint(_ data: [String: Any]) {
                guard let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return }
                _ = FileManager.default.createFile(atPath: configuration.deletingLastPathComponent()
                    .appendingPathComponent("runtime-progress.json").path, contents: bytes, attributes: [.posixPermissions: 0o600])
            }
            for cycle in 1...cycles {
                if let prepare {
                    let error: String? = await withCheckedContinuation { continuation in
                        prepare(identity.fingerprint) { continuation.resume(returning: $0) }
                    }
                    if let error {
                        checkpoint(["runs": runs, "cycle": cycle, "failure": error])
                        showReadinessError(error); throw StreamError.unavailable
                    }
                }
                start(host: host, pin: pin, identity: identity, mode: requested, audio: withAudio)
                for _ in 0..<200 {
                    if capture != nil && startTask == nil || !active { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let id = captureDisplayID
                guard active, capture != nil, let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == id
                }) else {
                    runs.append(["cycle": cycle, "started": false, "failure": status]); break
                }
                let window = NSWindow(contentRect: NSRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40,
                    width: CGFloat(requested.width - 80), height: CGFloat(requested.height - 80)),
                    styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
                // ARC owns both local and stored references across await stop().
                // close() must not release that object behind those references.
                window.isReleasedWhenClosed = false
                window.title = "METZ · проверка \(requested.fps) FPS"
                let view = RuntimeMotionView()
                view.wantsLayer = true
                window.contentView = view
                window.orderFrontRegardless(); testWindow = window
                window.setFrameOrigin(NSPoint(x: screen.frame.minX + 40, y: screen.frame.minY + 40))
                view.startMotion(pattern: config["stimulus"] == "grid" ? "grid" : "bar")
                let motion = screen.displayLink(target: view, selector: #selector(RuntimeMotionView.advance(_:)))
                let stimulusFPS = 60
                motion.preferredFrameRateRange = CAFrameRateRange(minimum: Float(stimulusFPS), maximum: Float(stimulusFPS), preferred: Float(stimulusFPS))
                motion.add(to: .main, forMode: .common)
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let initialCount = pipeline?.counts.0 ?? 0, initialCaptured = pipeline?.capturedCount ?? 0
                let initialTV = previousReport
                let initialTicks = view.tick
                let began = ProcessInfo.processInfo.systemUptime
                var sampledAt = began, sampledCapture = initialCaptured, sampledAdmission = initialCount
                var sampledTick = initialTicks, sampledBytes = pipeline?.processing.bytes ?? 0
                var sampledCodec = pipeline?.processing.frames ?? 0
                var sampledIdle = output?.frameCounts.idle ?? 0
                var samples: [[String: Any]] = []
                for _ in 0..<measureSeconds {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard active else { break }
                    let now = ProcessInfo.processInfo.systemUptime, elapsed = now - sampledAt
                    let capture = pipeline?.capturedCount ?? 0, admission = pipeline?.counts.0 ?? 0
                    let processing = pipeline?.processing, idle = output?.frameCounts.idle ?? 0
                    samples.append(["elapsed": now - began,
                        "capture_fps": Double(capture - sampledCapture) / elapsed,
                        "admission_fps": Double(admission - sampledAdmission) / elapsed,
                        "stimulus_fps": Double(view.tick - sampledTick) / elapsed,
                        "codec_fps": Double((processing?.frames ?? 0) - sampledCodec) / elapsed,
                        "encoded_video_mbps": Double((processing?.bytes ?? 0) - sampledBytes) * 8 / elapsed / 1_000_000,
                        "capture_idle": idle - sampledIdle,
                        "raw_queue_p95_ms": processing?.rawQueue.p95MS ?? -1,
                        "encoder_p95_ms": processing?.encoder.p95MS ?? -1,
                        "admission_p95_ms": processing?.admission.p95MS ?? -1,
                        "decoder_output_fps": outputFPS ?? -1, "surface_fps": renderedFPS ?? -1])
                    sampledAt = now; sampledCapture = capture; sampledAdmission = admission
                    sampledTick = view.tick; sampledBytes = processing?.bytes ?? 0
                    sampledCodec = processing?.frames ?? 0; sampledIdle = idle
                    checkpoint(["runs": runs, "cycle": cycle, "target_fps": requested.fps, "samples": samples])
                }
                let seconds = ProcessInfo.processInfo.systemUptime - began
                let finalCount = pipeline?.counts ?? (0, 0), finalCaptured = pipeline?.capturedCount ?? 0
                let tvRates = initialTV.flatMap { previousReport?.rates(since: $0) }
                let timing = pipeline?.timing
                let processing = pipeline?.processing
                let captureCounts = output?.frameCounts
                var run: [String: Any] = ["cycle": cycle, "started": true, "target_fps": requested.fps,
                    "width": requested.width, "height": requested.height,
                    "mode_matches": DisplayTopology.state(of: id)?.matches(requested) == true,
                    "decoded_confirmed": decodedOnTV, "seconds": seconds,
                    "capture_fps": Double(finalCaptured - initialCaptured) / seconds,
                    "admission_fps": Double(finalCount.0 - initialCount) / seconds,
                    "dropped_before_send": finalCount.1, "samples": samples, "status_before_stop": status]
                run["test_window_on_owned_display"] = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == id
                run["audio_packets_submitted"] = pipeline?.audioPacketCount ?? 0
                run["stimulus_fps"] = Double(view.tick - initialTicks) / seconds
                run["frame_capacity"] = transport?.frameCapacity ?? 2
                run["source_refresh_fps"] = 60
                run["quartz_refresh_fps"] = CGDisplayCopyDisplayMode(id)?.refreshRate
                run["manager_foreground"] = NSApp.isActive
                run["active_before_stop"] = active
                run["capture_complete"] = captureCounts?.complete
                run["capture_idle"] = captureCounts?.idle
                run["capture_other"] = captureCounts?.other
                run["codec_frames"] = processing?.frames
                run["encoder_latency_p95_ms"] = processing?.encoder.p95MS
                run["encoder_latency_max_ms"] = processing?.encoder.maximumMS
                run["admission_latency_p95_ms"] = processing?.admission.p95MS
                run["admission_latency_max_ms"] = processing?.admission.maximumMS
                if let timing {
                    run["capture_interval_p95_ms"] = timing.0.p95MS
                    run["capture_interval_max_ms"] = timing.0.maximumMS
                    run["capture_long_gaps"] = timing.0.longGaps
                    run["admission_interval_p95_ms"] = timing.1.p95MS
                    run["admission_interval_max_ms"] = timing.1.maximumMS
                    run["admission_long_gaps"] = timing.1.longGaps
                }
                if let tvRates {
                    run["decoder_output_fps"] = tvRates.0
                    if previousReport?.rendered ?? 0 > 0 { run["surface_fps"] = tvRates.1 }
                }
                motion.invalidate()
                await stop()
                run["display_removed"] = DisplayTopology.contains(id) == false
                run["active_after_stop"] = active
                run["session_resources_released"] = capture == nil && pipeline == nil && output == nil && transport == nil && handle == nil && monitor == nil && startTask == nil && streamActivity == nil
                runs.append(run)
                checkpoint(["runs": runs, "cycle": cycle, "stopped": true])
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let report: [String: Any] = ["runs": runs, "capture_scope": "owned virtual display with generated moving bar", "stimulus": config["stimulus"] == "grid" ? "generated rotating gradient grid" : "Core Animation moving layer; display link counts clock callbacks only", "audio": withAudio]
            let destination = configuration.deletingLastPathComponent().appendingPathComponent("runtime-report-\(UUID().uuidString).json")
            let saved = FileManager.default.createFile(atPath: destination.path,
                contents: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]), attributes: [.posixPermissions: 0o600])
            status = saved ? "Проверка завершена; отчёт сохранён локально" : "Отчёт не сохранён"
        } catch { await stop(reason: "Проверка не завершена: " + status) }
    }
}
