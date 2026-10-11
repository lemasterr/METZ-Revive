import Foundation

@main
struct StreamJournalCheck {
    static func main() async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("metz-journal-check-" + UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        let unrelated = folder.appendingPathComponent("user-note.jsonl")
        try Data("preserve".utf8).write(to: unrelated)
        let mode = StreamMode(width: 1366, height: 768, fps: 30)
        for session in 0..<4 {
            let journal = try StreamJournal(mode: mode, audio: true, folder: folder, segmentBytes: 1024, retainedSessions: 2)
            for frame in 0..<5000 {
                journal.record(.capture, ["frame": Double(frame), "selected": Double(frame % 2)])
            }
            journal.record(.sample, ["capture_fps": 60, "admission_fps": 30])
            await journal.finish(["session_number": Double(session), "admitted_frames": 2500])
            // Idempotent finish, including an already scheduled background flush.
            await journal.finish(["session_number": -1])
            precondition(journal.available)
        }
        let files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let summaries = files.filter { $0.lastPathComponent.hasSuffix("-summary.json") }
        let traces = files.filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "jsonl" }
        precondition(summaries.count == 2 && traces.count <= 4, "Retention exceeded")
        for trace in traces {
            let bytes = try Data(contentsOf: trace)
            precondition(bytes.count <= 1024, "Ring segment exceeded its size limit")
            precondition(bytes.last == 10, "Incomplete JSONL line")
            for line in bytes.split(separator: 10) {
                let record = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
                precondition(record["event"] as? String != nil)
            }
        }
        for summary in summaries {
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: summary)) as! [String: Any]
            precondition(record["ended"] as? Bool == true && record["history_rotations"] as! Int > 0)
            let last = record["last"] as! [String: Any]
            precondition(last["event"] as? String == "stop" && last["admitted_frames"] as? Int == 2500)
            precondition([2, 3].contains(last["session_number"] as! Int))
        }
        for url in traces + summaries {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
        }
        let permissions = try manager.attributesOfItem(atPath: folder.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o700)
        let preserved = try Data(contentsOf: unrelated)
        precondition(preserved == Data("preserve".utf8))
        let invalid = folder.appendingPathComponent("not-a-directory")
        try Data().write(to: invalid)
        do {
            _ = try StreamJournal(mode: mode, audio: false, folder: invalid)
            preconditionFailure("Invalid destination must be reported without changing the stream")
        } catch {}
        print("Journal ring, JSON integrity, bounded backlog, retention, permissions and idempotent finish passed; no capture/UI.")
    }
}
