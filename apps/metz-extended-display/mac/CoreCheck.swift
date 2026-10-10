import Foundation
import ScreenCaptureKit

@main
struct CoreCheck {
    static func main() throws {
        var cadence = FrameCadence()
        var latency = FrameLatency()
        precondition(latency.p95MS == nil)
        latency.record(seconds: .nan); latency.record(seconds: -1)
        precondition(latency.maximumMS == nil)
        latency.record(seconds: 10)
        for _ in 0..<120 { latency.record(seconds: 0.002) }
        precondition(latency.maximumMS == 2 && latency.p95MS == 2)
        cadence.record(0, expectedFPS: 60)
        cadence.record(1.0 / 60, expectedFPS: 60)
        cadence.record(0, expectedFPS: 60) // Out-of-order timestamps must not shift the origin.
        cadence.record(2.0 / 60, expectedFPS: 60)
        precondition(abs(cadence.maximumMS! - 1000.0 / 60) < 0.001 && cadence.longGaps == 0)
        cadence.record(0.1, expectedFPS: 60)
        precondition(cadence.longGaps == 1 && cadence.p95MS! > 60)
        precondition(SessionAudioTime.relative(2_020_000, origin: CMTime(value: 2, timescale: 1)) == 20_000)
        precondition(SessionAudioTime.relative(1_000_000, origin: CMTime(value: 2, timescale: 1)) == nil)
        precondition(SessionAudioTime.relative(0, origin: .invalid) == nil)
        var writes = WriteDeadlineGate()
        let oldWrite = writes.begin()!
        precondition(writes.begin() == nil && writes.expired(oldWrite))
        writes.complete(oldWrite)
        let currentWrite = writes.begin()!
        // The old two-second deadline must not fail a newer audio packet.
        precondition(!writes.expired(oldWrite) && writes.expired(currentWrite))
        writes.complete(oldWrite)
        precondition(writes.expired(currentWrite))
        writes.complete(currentWrite)
        precondition(!writes.expired(currentWrite))
        precondition(DisplayModeChoice.matches(width: 960, height: 540, rate: 60, requested: StreamMode(width: 960, height: 540, fps: 60)))
        precondition(!DisplayModeChoice.matches(width: 1280, height: 720, rate: 60, requested: StreamMode(width: 960, height: 540, fps: 60)))
        precondition(!DisplayModeChoice.matches(width: 960, height: 540, rate: 30, requested: StreamMode(width: 960, height: 540, fps: 60)))
        precondition(!DisplayModeChoice.matches(width: 960, height: 540, rate: .nan, requested: StreamMode(width: 960, height: 540, fps: 60)))
        var reportBytes = Data()
        for value in [UInt64(100), 90, 1_000_000] { Wire.append(value, to: &reportBytes) }
        let report = try TVFrameReport.parse(reportBytes)
        let next = TVFrameReport(output: 160, rendered: 149, elapsedUS: 2_000_000)
        precondition(next.rates(since: report)?.0 == 60 && next.rates(since: report)?.1 == 59)
        precondition(report.rates(since: next) == nil)
        do { _ = try TVFrameReport.parse(Data(count: 23)); preconditionFailure() } catch {}
        let native60 = StreamMode(width: 1366, height: 768, fps: 60)
        let native50 = StreamMode(width: 1366, height: 768, fps: 50)
        precondition(native50.valid && native50.level == "4.1")
        precondition(StreamMode(width: 1280, height: 720, fps: 50).level == "4.1")
        precondition(native60.valid && native60.level == "4.2")
        precondition(StreamMode(width: 960, height: 540, fps: 60).level == "4.1")
        precondition(!StreamMode(width: 1920, height: 1080, fps: 60).valid)
        let modes = StreamMode.parse(try JSONEncoder().encode([.conservative, native60, native60]))
        precondition(modes.count == 2 && modes.first == native60)
        precondition(StreamMode.parse(Data("[{\"width\":1920,\"height\":1080,\"fps\":60}]".utf8)).isEmpty)
        let pcm = try Wire.packet(type: 4, epoch: 1, payload: Data(count: 8192))
        precondition(pcm.count == 8216)
        for length in [0, 3, 8196] {
            do { _ = try Wire.packet(type: 4, epoch: 1, payload: Data(count: length)); preconditionFailure() } catch {}
        }
        var writtenFirst = FrameDeliveryGate()
        writtenFirst.markWritten(); precondition(!writtenFirst.complete)
        precondition(writtenFirst.acknowledge() && writtenFirst.complete)
        precondition(!writtenFirst.acknowledge())
        var admittedFirst = FrameDeliveryGate()
        precondition(admittedFirst.acknowledge() && !admittedFirst.complete)
        admittedFirst.markWritten(); precondition(admittedFirst.complete)
        precondition(!FrameDeliveryGate().complete)
        var identifiedFrame = FrameDeliveryGate(pts: 1234)
        identifiedFrame.markWritten()
        precondition(!identifiedFrame.acknowledge(pts: 1233) && !identifiedFrame.complete)
        precondition(identifiedFrame.acknowledge(pts: 1234) && identifiedFrame.complete)
        let receiptPTS = try Wire.receiptPTS(Data([0, 0, 0, 0, 0, 0, 4, 210]))
        precondition(receiptPTS == 1234)
        do { _ = try Wire.receiptPTS(Data(count: 7)); preconditionFailure() } catch { }
        precondition(EncoderOutputDisposition.classify(status: 0, dropped: true) == .dropped)
        precondition(EncoderOutputDisposition.classify(status: 0, dropped: false) == .encoded)
        precondition(EncoderOutputDisposition.classify(status: -1, dropped: true) == .failed)
        precondition(EncoderOutputDisposition.classify(status: -1, dropped: false) == .failed)
        precondition(DisplayState(active: 1, mirrored: 0, builtIn: 0, width: 1280, height: 720)?.independent720p == true)
        precondition(DisplayState(active: 0, mirrored: 0, builtIn: 0, width: 1280, height: 720)?.independent720p == false)
        precondition(DisplayState(active: 1, mirrored: 1, builtIn: 0, width: 1280, height: 720)?.independent720p == false)
        precondition(DisplayState(active: 1, mirrored: 0, builtIn: 0, width: 0, height: 0)?.independent720p == false)
        for invalid in [Int32(-1), 2, 1001, Int32.max] {
            precondition(DisplayState(active: invalid, mirrored: 0, builtIn: 0, width: 1280, height: 720) == nil)
            precondition(DisplayState(active: 1, mirrored: invalid, builtIn: 0, width: 1280, height: 720) == nil)
            precondition(DisplayState(active: 1, mirrored: 0, builtIn: invalid, width: 1280, height: 720) == nil)
        }
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        precondition(CaptureAccess.explanation(denied, stage: .capture, application: "METZ Manager").contains("именно METZ Manager"))
        precondition(CaptureAccess.explanation(denied, stage: .access, application: "METZ Display").contains("именно METZ Display"))
        let unrelated = NSError(domain: "other", code: SCStreamError.Code.userDeclined.rawValue)
        precondition(!CaptureAccess.explanation(unrelated, stage: .encoder, application: "METZ Manager").contains("не разрешает"))
        precondition(!CaptureAccess.explanation(StreamError.unavailable, stage: .virtualDisplay, application: "METZ Manager").contains("разреш"))
        precondition(CaptureAccess.explanation(VirtualDisplayFailure.creation(4), stage: .virtualDisplay, application: "METZ Manager").contains("дескриптор"))
        precondition(CaptureAccess.explanation(VirtualDisplayFailure.mode, stage: .virtualDisplay, application: "METZ Manager").contains("выбранное разрешение"))
        precondition(CaptureAccess.explanation(VirtualDisplayFailure.registration, stage: .virtualDisplay, application: "METZ Manager").contains("5 секунд"))

        let frame = Data([0, 0, 0, 2, 0x65, 0xab, 0, 0, 0, 1, 0x06])
        let annex = try Wire.annexB(frame, nalLength: 4)
        precondition(annex == Data([0, 0, 0, 1, 0x65, 0xab, 0, 0, 0, 1, 0x06]))
        for malformed in [Data(), Data([0, 0, 0]), Data([0, 0, 0, 0]), Data([0, 0, 1, 0, 1])] {
            do { _ = try Wire.annexB(malformed, nalLength: 4); preconditionFailure("Malformed NAL accepted") } catch { }
        }
        let short = try Wire.annexB(Data([1, 0x65]), nalLength: 1)
        precondition(short == Data([0, 0, 0, 1, 0x65]))
        let packet = try Wire.packet(type: 2, flags: 1, epoch: 7, pts: 1_000_000, payload: annex)
        precondition(packet.count == 24 + annex.count)
        precondition(packet.prefix(8) == Data([0x4d, 0x54, 0x5a, 0x31, 1, 2, 0, 1]))
        precondition(packet[15] == 7 && packet.suffix(annex.count) == annex)
        for invalid in ["", String(repeating: "g", count: 64), String(repeating: "a", count: 63), "$(id)"] {
            precondition(!Wire.validPin(invalid))
        }
        precondition(Wire.validPin(String(repeating: "a", count: 64)))
        do { _ = try Wire.packet(type: 2, epoch: 1, payload: Data(count: Wire.maximumPayload + 1)); preconditionFailure() } catch { }
        do { _ = try Wire.packet(type: 1, epoch: 1, payload: Data(count: 65_537)); preconditionFailure() } catch { }
        print("Display core: decoder admission gate handles both callback orders and rejects duplicate ACK; dropped encoder frames stay nonfatal; framing/pins passed; no capture/private API invocation.")
    }
}
