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
@main
struct EncoderCheck {
    static func main() throws {
        for mode in StreamMode.candidates {
            let sink = EncoderSink()
            let pipeline = try FramePipeline(transport: sink, mode: mode)
            pipeline.failure = sink.fail
            defer { pipeline.stop() }
            var image: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, mode.width, mode.height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess)
            let buffer = image!
            for index in 0..<2 {
                CVPixelBufferLockBaseAddress(buffer, [])
                let bytes = CVPixelBufferGetBytesPerRow(buffer) * mode.height
                memset(CVPixelBufferGetBaseAddress(buffer)!, Int32(index * 80), bytes)
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
            print("Hardware generated frames passed: " + mode.id)
        }
        print("\(StreamMode.candidates.count * 2) generated frames; no captured content, display/private API, network, UI or speed benchmark.")
    }
}
