import Foundation
import CoreVideo
import CoreMedia

// Generated blank/pattern frames only: no ScreenCaptureKit, display, network or UI.
private final class EncoderSink: FramePacketTransport {
    let arrived = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private(set) var configuration: [String: Any] = [:]
    private(set) var error: String?
    func fail(_ message: String) { lock.lock(); error = message; lock.unlock(); arrived.signal() }
    func send(_ data: Data, pts: UInt64, completion: @escaping (Bool) -> Void) {
        var offset = 0
        var video = false
        while offset < data.count {
            precondition(data.count - offset >= Wire.headerSize)
            let type = data[offset + 5]
            let size = data[(offset + 8)..<(offset + 12)].reduce(0) { ($0 << 8) | Int($1) }
            precondition(size <= Wire.maximumPayload && offset + 24 + size <= data.count)
            let payload = data[(offset + 24)..<(offset + 24 + size)]
            if type == 1 {
                lock.lock(); configuration = try! JSONSerialization.jsonObject(with: Data(payload)) as! [String: Any]; lock.unlock()
            } else if type == 2 { precondition(!payload.isEmpty); video = true }
            else { preconditionFailure("Unexpected encoder packet") }
            offset += 24 + size
        }
        precondition(video)
        completion(true)
        arrived.signal()
    }
    func sendAudio(_ data: Data) { preconditionFailure("Audio disabled in generated frame check") }
    func snapshot() -> ([String: Any], String?) { lock.lock(); defer { lock.unlock() }; return (configuration, error) }
}

private final class HeldFrameSink: FramePacketTransport {
    private let lock = NSLock()
    private var callback: ((Bool) -> Void)?
    private var timestamps: [UInt64] = []
    var sent: [UInt64] { lock.lock(); defer { lock.unlock() }; return timestamps }
    func send(_ data: Data, pts: UInt64, completion: @escaping (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        precondition(callback == nil, "Concurrent compressed sends")
        precondition(timestamps.last.map { $0 < pts } ?? true, "Compressed PTS reordered")
        timestamps.append(pts); callback = completion
    }
    func sendAudio(_ data: Data) { preconditionFailure("Generated video check only") }
    func release() {
        lock.lock(); let completed = callback; callback = nil; lock.unlock()
        completed?(true)
    }
}

private func checkBoundedOverlap() throws {
    let sink = HeldFrameSink(), mode = StreamMode(width: 1366, height: 768, fps: 60)
    let pipeline = try FramePipeline(transport: sink, mode: mode)
    defer { pipeline.stop() }
    pipeline.failure = { _ in preconditionFailure("Generated pipeline failed") }
    var pixel: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, mode.width, mode.height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
    let buffer = pixel!
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer)!, 70, CVPixelBufferGetBytesPerRow(buffer) * mode.height)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    func wait(_ condition: () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.002) }
        precondition(condition(), "Generated pipeline timed out")
    }
    for frame in 0..<60 {
        pipeline.submit(buffer, pts: CMTime(value: Int64(frame), timescale: 60))
        Thread.sleep(forTimeInterval: 0.004)
    }
    wait { pipeline.processing.frames == 2 }
    precondition(sink.sent.count == 1 && pipeline.counts.0 == 0 && pipeline.counts.1 > 0)
    sink.release()
    wait { pipeline.processing.frames == 3 && pipeline.counts.0 == 1 }
    precondition(sink.sent.count == 2)
    sink.release()
    wait { sink.sent.count == 3 && pipeline.counts.0 == 2 }
    precondition(sink.sent.last == UInt64(59 * 1_000_000 / 60), "Latest raw frame was not selected")
    pipeline.stop(); let admitted = pipeline.counts.0
    sink.release(); Thread.sleep(forTimeInterval: 0.05)
    precondition(pipeline.counts.0 == admitted, "Late ACK changed stopped counters")
    print("Bounded overlap, compressed ordering, latest raw selection and late ACK after stop passed")
}
@main
struct EncoderCheck {
    static func main() throws {
        for mode in StreamMode.candidates { for pixelFormat in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            let sink = EncoderSink()
            let pipeline = try FramePipeline(transport: sink, mode: mode)
            pipeline.failure = sink.fail
            defer { pipeline.stop() }
            var image: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, mode.width, mode.height, pixelFormat,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess)
            let buffer = image!
            for index in 0..<2 {
                CVPixelBufferLockBaseAddress(buffer, [])
                if CVPixelBufferIsPlanar(buffer) {
                    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                        let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
                        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, plane == 0 ? Int32(40 + index * 80) : 128, bytes)
                    }
                } else {
                    let bytes = CVPixelBufferGetBytesPerRow(buffer) * mode.height
                    memset(CVPixelBufferGetBaseAddress(buffer)!, Int32(index * 80), bytes)
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                pipeline.requestKeyframe()
                pipeline.submit(buffer, pts: CMTime(value: Int64(index), timescale: Int32(mode.fps)))
                precondition(sink.arrived.wait(timeout: .now() + 5) == .success, "Encoder did not produce generated frame")
                let (config, error) = sink.snapshot()
                precondition(error == nil, "Encoder failure")
                precondition(config["width"] as? Int == mode.width && config["height"] as? Int == mode.height && config["fps"] as? Int == mode.fps)
                precondition(config["profile"] as? String == "baseline-" + mode.level)
            }
            pipeline.stop()
            print("Hardware generated frames passed: \(mode.id), pixel format \(pixelFormat)")
        } }
        print("\(StreamMode.candidates.count * 4) generated frames; no captured content, display/private API, network, UI or speed benchmark.")
        try checkBoundedOverlap()
    }
}
