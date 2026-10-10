import Foundation

struct StreamMode: Hashable, Codable, Identifiable {
    let width: Int
    let height: Int
    let fps: Int
    var id: String { "\(width)x\(height)@\(fps)" }
    var title: String { "\(width)×\(height) · \(fps) кадров/с" }
    static let conservative = StreamMode(width: 1280, height: 720, fps: 30)
    static let candidates = [(854, 480), (960, 540), (1280, 720), (1366, 768)].flatMap { w, h in
        [30, 50, 60].map { StreamMode(width: w, height: h, fps: $0) }
    }
    var valid: Bool { Self.candidates.contains(self) }
    var level: String { width * height > 1280 * 720 && fps == 60 ? "4.2" : (width == 1366 || (fps >= 50 && width >= 960) ? "4.1" : "3.1") }
    static func parse(_ data: Data) -> [StreamMode] {
        guard data.count <= 4096, let values = try? JSONDecoder().decode([StreamMode].self, from: data),
            values.count <= candidates.count, values.allSatisfy(\.valid) else { return [] }
        return Array(Set(values)).sorted { a, b in a.fps == b.fps ? a.width * a.height > b.width * b.height : a.fps > b.fps }
    }
}

enum StreamError: Error { case invalid, unavailable, overloaded, expired }

/// A deadline belongs to one write, even if a later write is already pending.
struct WriteDeadlineGate {
    private var sequence: UInt64 = 0
    private(set) var pending: UInt64?
    mutating func begin() -> UInt64? {
        guard pending == nil else { return nil }
        sequence &+= 1; pending = sequence
        return sequence
    }
    mutating func complete(_ id: UInt64) {
        if pending == id { pending = nil }
    }
    func expired(_ id: UInt64) -> Bool { pending == id }
}

/// Select fresh source frames on an absolute timeline, without accumulating callback jitter.
struct FrameRateSelector {
    private var next: Double?
    private var previous: Double?
    mutating func accepts(_ time: Double, fps: Int) -> Bool {
        guard time.isFinite, fps > 0, previous.map({ time > $0 }) ?? true else { return false }
        previous = time
        let interval = 1 / Double(fps)
        guard let deadline = next else { next = time + interval; return true }
        guard time + 0.0005 >= deadline else { return false }
        // Skip elapsed deadlines after a stall; never replay or burst old frames.
        next = deadline + max(1, floor((time + 0.0005 - deadline) / interval) + 1) * interval
        return true
    }
}

/// A bounded window of actual intervals; absent samples never become zero.
struct FrameCadence {
    private var previous: Double?
    private var intervals: [Double] = []
    private(set) var longGaps = 0
    mutating func record(_ time: Double, expectedFPS: Int) {
        guard time.isFinite, expectedFPS > 0 else { return }
        guard let previous else { self.previous = time; return }
        guard time > previous else { return }
        self.previous = time
        let ms = (time - previous) * 1000
        if ms > 1500 / Double(expectedFPS) { longGaps += 1 }
        intervals.append(ms)
        if intervals.count > 120 { intervals.removeFirst() }
    }
    var p95MS: Double? {
        guard !intervals.isEmpty else { return nil }
        let sorted = intervals.sorted()
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
    var maximumMS: Double? { intervals.max() }
}

/// Processing time of recent completed operations, bounded to two seconds at 60 FPS.
struct FrameLatency {
    private var samples: [Double] = []
    mutating func record(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        samples.append(seconds * 1000)
        if samples.count > 120 { samples.removeFirst() }
    }
    var p95MS: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
    var maximumMS: Double? { samples.max() }
}

struct TVFrameReport: Equatable {
    let output: UInt64
    let rendered: UInt64
    let elapsedUS: UInt64
    static func parse(_ data: Data) throws -> Self {
        guard data.count == 24 else { throw StreamError.invalid }
        let values = stride(from: 0, to: 24, by: 8).map { offset in
            data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        guard values[2] > 0, values[1] <= values[0] else { throw StreamError.invalid }
        return Self(output: values[0], rendered: values[1], elapsedUS: values[2])
    }
    func rates(since previous: Self) -> (Double, Double)? {
        guard elapsedUS > previous.elapsedUS, output >= previous.output, rendered >= previous.rendered else { return nil }
        let seconds = Double(elapsedUS - previous.elapsedUS) / 1_000_000
        return (Double(output - previous.output) / seconds, Double(rendered - previous.rendered) / seconds)
    }
}

/// Network acceptance and decoder admission may arrive in either order.
struct FrameDeliveryGate {
    let pts: UInt64
    init(pts: UInt64 = 0) { self.pts = pts }
    private(set) var written = false
    private(set) var admitted = false
    mutating func markWritten() { written = true }
    mutating func acknowledge(pts: UInt64 = 0) -> Bool {
        guard !admitted, self.pts == pts else { return false }
        admitted = true
        return true
    }
    var complete: Bool { written && admitted }
}

enum FrameDeliveryProgress { case invalid, waiting, complete }

/// Ordered, bounded decoder credit. ACK RTT must not become a one-frame FPS limit.
struct FrameDeliveryWindow {
    let capacity: Int
    private var frames: [FrameDeliveryGate] = []
    private var lastSubmitted: UInt64?
    init(capacity: Int = 2) { precondition((1...2).contains(capacity)); self.capacity = capacity }
    var isEmpty: Bool { frames.isEmpty }
    func contains(_ pts: UInt64) -> Bool { frames.contains { $0.pts == pts } }
    func written(_ pts: UInt64) -> Bool { frames.first { $0.pts == pts }?.written == true }
    mutating func reserve(_ pts: UInt64) -> Bool {
        guard frames.count < capacity, lastSubmitted.map({ pts > $0 }) ?? true else { return false }
        frames.append(FrameDeliveryGate(pts: pts)); lastSubmitted = pts
        return true
    }
    mutating func markWritten(_ pts: UInt64) -> FrameDeliveryProgress {
        guard let index = frames.firstIndex(where: { $0.pts == pts }), !frames[index].written else { return .invalid }
        frames[index].markWritten()
        return finish(index)
    }
    mutating func acknowledge(_ pts: UInt64) -> FrameDeliveryProgress {
        guard let index = frames.firstIndex(where: { !$0.admitted }), frames[index].pts == pts,
              frames[index].acknowledge(pts: pts) else { return .invalid }
        return finish(index)
    }
    private mutating func finish(_ index: Int) -> FrameDeliveryProgress {
        guard frames[index].complete else { return .waiting }
        frames.remove(at: index)
        return .complete
    }
}

enum Wire {
    static let maximumPayload = 1_048_576
    static let headerSize = 24
    static func receiptPTS(_ bytes: Data) throws -> UInt64 {
        guard bytes.count == 8 else { throw StreamError.invalid }
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    // Big endian: magic(4), version(1), type(1), flags(2), length(4), epoch(4), ptsUs(8).
    static func packet(type: UInt8, flags: UInt16 = 0, epoch: UInt32, pts: UInt64 = 0, payload: Data) throws -> Data {
        guard [UInt8(1), 2, 3, 4].contains(type), payload.count <= maximumPayload,
              type == 2 || payload.count <= 65_536,
              type != 4 || (!payload.isEmpty && payload.count <= 8192 && payload.count % 4 == 0 && flags == 0) else { throw StreamError.invalid }
        var data = Data([0x4d, 0x54, 0x5a, 0x31, 1, type])
        append(flags, to: &data); append(UInt32(payload.count), to: &data)
        append(epoch, to: &data); append(pts, to: &data)
        data.append(payload)
        return data
    }
    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
    static func validPin(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
    static func annexB(_ data: Data, nalLength: Int) throws -> Data {
        guard (1...4).contains(nalLength), data.count <= maximumPayload else { throw StreamError.invalid }
        var offset = 0, result = Data()
        while offset < data.count {
            guard data.count - offset >= nalLength else { throw StreamError.invalid }
            var size = 0
            for byte in data[offset..<(offset + nalLength)] { size = (size << 8) | Int(byte) }
            offset += nalLength
            guard size > 0, size <= data.count - offset else { throw StreamError.invalid }
            result.append(contentsOf: [0, 0, 0, 1]); result.append(data[offset..<(offset + size)])
            guard result.count <= maximumPayload else { throw StreamError.invalid }
            offset += size
        }
        guard !result.isEmpty else { throw StreamError.invalid }
        return result
    }
}
