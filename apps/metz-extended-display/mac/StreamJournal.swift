import Foundation

/// Numeric diagnostics only. Capture/encoder queues never serialize JSON or write files.
final class StreamJournal: @unchecked Sendable {
    enum Event: String { case capture, encode, encoded, send, admission, replaced, codecDrop, sample, tvReport, tvFrame, stop }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("METZ/StreamSessions.noindex", isDirectory: true)
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "metz.stream.journal", qos: .utility)
    private let folder: URL
    private let session = UUID().uuidString.lowercased()
    private let started = ProcessInfo.processInfo.systemUptime
    private let header: [String: Double]
    private let segmentBytes: Int
    private var pending: [[String: Any]] = []
    private var scheduled = false
    private var closed = false
    private var omitted = 0
    private var unavailable = false
    var available: Bool { lock.lock(); defer { lock.unlock() }; return !unavailable }
    // Remaining state belongs to the journal queue.
    private var file: FileHandle?
    private var bytes = 0
    private var segment = -1
    private var sequence = 0
    private var failed = false
    private var finalized = false
    private var latestSample: [String: Any] = [:]

    init(mode: StreamMode, audio: Bool, folder: URL = StreamJournal.directory,
         segmentBytes: Int = 2 * 1024 * 1024, retainedSessions: Int = 8) throws {
        self.folder = folder; self.segmentBytes = max(1024, segmentBytes)
        header = ["schema": 1, "width": Double(mode.width), "height": Double(mode.height),
                  "target_fps": Double(mode.fps), "audio": audio ? 1 : 0,
                  "started_unix_s": Date().timeIntervalSince1970]
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: folder.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw StreamError.invalid }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        // Retire only this writer's UUID-named regular files; never touch unrelated files.
        let files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var groups: [String: [(URL, Date)]] = [:]
        for url in files {
            guard let id = Self.sessionID(url.lastPathComponent),
                  let attrs = try? manager.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            groups[id, default: []].append((url, attrs[.modificationDate] as? Date ?? .distantPast))
        }
        let oldest = groups.keys.sorted { (groups[$0]!.map(\.1).max()!) < (groups[$1]!.map(\.1).max()!) }
        for id in oldest.prefix(max(0, groups.count - max(1, retainedSessions) + 1)) {
            for (url, _) in groups[id]! { try manager.removeItem(at: url) }
        }
        queue.async { self.drain() }
    }

    private static func sessionID(_ name: String) -> String? {
        guard name.hasPrefix("session-"), name.count > 44 else { return nil }
        let id = String(name.dropFirst(8).prefix(36))
        guard UUID(uuidString: id) != nil,
              ["session-\(id)-0.jsonl", "session-\(id)-1.jsonl", "session-\(id)-summary.json"].contains(name) else { return nil }
        return id
    }

    func record(_ event: Event, _ fields: [String: Double] = [:]) {
        guard fields.values.allSatisfy(\.isFinite) else { return }
        var record: [String: Any] = fields
        record["event"] = event.rawValue
        record["t_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
        lock.lock()
        guard !closed, !unavailable else { lock.unlock(); return }
        // A slow/full disk must not retain frames or create an unbounded task queue.
        if pending.count < 2048 { pending.append(record) } else { omitted += 1 }
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule { queue.asyncAfter(deadline: .now() + 0.25) { self.drain() } }
    }

    func finish(_ fields: [String: Double]) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !closed {
                closed = true
                var end: [String: Any] = fields.filter { $0.value.isFinite }
                end["event"] = Event.stop.rawValue
                end["t_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
                if pending.count == 2048 { pending.removeFirst(); omitted += 1 }
                pending.append(end)
            }
            lock.unlock()
            queue.async {
                self.drain()
                try? self.file?.close(); self.file = nil
                continuation.resume()
            }
        }
    }

    private func drain() {
        guard !finalized else { return }
        lock.lock()
        let batch = pending; pending.removeAll(keepingCapacity: true)
        let skipped = omitted; scheduled = false; let finished = closed
        lock.unlock()
        guard !failed else { return }
        do {
            if segment < 0 { try rotate() }
            for var record in batch {
                sequence += 1; record["seq"] = sequence
                var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                line.append(10)
                guard line.count < segmentBytes else { continue }
                if bytes + line.count > segmentBytes { try rotate() }
                try file?.write(contentsOf: line); bytes += line.count
                if record["event"] as? String == Event.sample.rawValue || record["event"] as? String == Event.stop.rawValue {
                    latestSample = record
                }
            }
            var summary: [String: Any] = header
            summary["last"] = latestSample; summary["ended"] = finished
            summary["events"] = sequence; summary["omitted_events"] = skipped
            summary["history_rotations"] = max(0, segment - 1)
            let url = folder.appendingPathComponent("session-\(session)-summary.json")
            // Keep checkpoint data after an abnormal exit, without replaying a video recording.
            try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if finished {
                finalized = true
                try file?.close(); file = nil
            }
        } catch {
            failed = true
            lock.lock(); unavailable = true; lock.unlock()
            try? file?.close(); file = nil
        }
    }

    private func rotate() throws {
        try file?.close(); file = nil
        segment += 1
        let url = folder.appendingPathComponent("session-\(session)-\(segment % 2).jsonl")
        if FileManager.default.fileExists(atPath: url.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw StreamError.invalid }
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw StreamError.unavailable }
        file = try FileHandle(forWritingTo: url)
        var record: [String: Any] = header
        record["event"] = "start"; record["segment"] = segment
        var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]); line.append(10)
        try file?.write(contentsOf: line); bytes = line.count
    }
}
