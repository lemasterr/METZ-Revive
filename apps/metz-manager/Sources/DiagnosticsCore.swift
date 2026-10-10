import Foundation
import Darwin

struct TVDevice: Equatable, Identifiable {
    let serial: String
    let state: String
    let model: String
    var id: String { serial }
    var available: Bool { state == "device" }
}

func parseDevices(_ output: String) -> [TVDevice] {
    output.split(separator: "\n").compactMap { line in
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count >= 2, ["device", "offline", "unauthorized"].contains(fields[1]) else { return nil }
        let model = fields.first(where: { $0.hasPrefix("model:") })?.dropFirst(6)
        return TVDevice(serial: fields[0], state: fields[1], model: model.map(String.init) ?? "Android TV")
    }
}

enum DiagnosticProfile: String, CaseIterable, Identifiable {
    case audio, cast, remote, video
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audio: return "Звук"
        case .cast: return "Cast"
        case .remote: return "Управление"
        case .video: return "Видео"
        }
    }
}

struct CommandResult {
    let exitCode: Int32
    let output: String
    let timedOut: Bool
    let truncated: Bool
    let hasErrorOutput: Bool
    var errorOutput: String = ""
}

private final class OutputBuffer: @unchecked Sendable {
    let maximumBytes: Int
    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
    private(set) var data = Data()
    private(set) var truncated = false
    private(set) var ended = false
    func drainAvailable(_ file: FileHandle) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        // Limit each drain to avoid starving the other pipe or the process deadline.
        for _ in 0..<32 {
            let readCount = Darwin.read(file.fileDescriptor, &bytes, bytes.count)
            if readCount == 0 { ended = true; return }
            if readCount < 0 {
                if errno != EAGAIN && errno != EINTR { ended = true; truncated = true }
                return
            }
            let count = min(readCount, max(0, maximumBytes - data.count))
            data.append(contentsOf: bytes.prefix(count))
            truncated = truncated || count < readCount
        }
    }
}

// Commands use argument arrays. A bounded process runs only while the user requests a snapshot.
func runCommand(executable: URL, arguments: [String], timeout: TimeInterval,
                environment: [String: String]? = nil, maximumOutputBytes: Int = 65536) throws -> CommandResult {
    precondition((65536...4 * 1024 * 1024).contains(maximumOutputBytes))
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = executable.lastPathComponent == "adb" ? try adbCommandEnvironment(environment ?? ProcessInfo.processInfo.environment, executable: executable) : environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    let stdout = OutputBuffer(maximumBytes: maximumOutputBytes), stderr = OutputBuffer(maximumBytes: maximumOutputBytes)
    try process.run()
    // Close parent write ends so EOF does not depend on Pipe deallocation.
    try? output.fileHandleForWriting.close()
    try? errors.fileHandleForWriting.close()
    defer { try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close() }
    for pipe in [output, errors] {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var timedOut = false
    while process.isRunning {
        stdout.drainAvailable(output.fileHandleForReading)
        stderr.drainAvailable(errors.fileHandleForReading)
        if ProcessInfo.processInfo.systemUptime >= deadline {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            break
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    process.waitUntilExit()
    // A Python/ADB child may inherit pipes; EOF must never hold the Manager open indefinitely.
    let drainDeadline = ProcessInfo.processInfo.systemUptime + 0.2
    while (!stdout.ended || !stderr.ended) && ProcessInfo.processInfo.systemUptime < drainDeadline {
        stdout.drainAvailable(output.fileHandleForReading)
        stderr.drainAvailable(errors.fileHandleForReading)
        Thread.sleep(forTimeInterval: 0.005)
    }
    return CommandResult(exitCode: process.terminationStatus,
                         output: String(decoding: stdout.data, as: UTF8.self),
                         timedOut: timedOut, truncated: stdout.truncated || stderr.truncated || !stdout.ended || !stderr.ended,
                         hasErrorOutput: !stderr.data.isEmpty, errorOutput: String(decoding: stderr.data, as: UTF8.self))
}

// A Finder-launched client must use the same local ADB server as an app-launched client.
// Keep HOME and authorization key settings; discard only alternate server endpoints.
func adbEnvironment(_ environment: [String: String]) -> [String: String] {
    var value = environment
    for key in ["ADB_SERVER_SOCKET", "ANDROID_ADB_SERVER_ADDRESS", "ANDROID_ADB_SERVER_PORT"] { value.removeValue(forKey: key) }
    return value
}
func adbCommandEnvironment(_ value: [String: String], executable: URL) throws -> [String: String] {
    var result = adbEnvironment(value)
    #if METZ_MANAGER || METZ_ADB_CHECK
    result["ADB_SERVER_SOCKET"] = try OwnedADBServer.shared.socket(adb: executable)
    #endif
    return result
}
func adbSucceeded(_ result: CommandResult) -> Bool {
    guard result.exitCode == 0, !result.timedOut, !result.truncated else { return false }
    if !result.hasErrorOutput { return true }
    // A cold daemon writes normal startup notices to stderr even on success.
    let lines = result.errorOutput.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    return !lines.isEmpty && lines.allSatisfy {
        $0 == "* daemon not running; starting now at tcp:5037" || $0 == "* daemon started successfully"
    }
}
func existingTool(_ name: String) -> URL? {
    if name == "adb" {
        let sdk = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb")
        if FileManager.default.isExecutableFile(atPath: sdk.path) { return sdk }
    }
    let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                 NSHomeDirectory() + "/Library/Android/sdk/platform-tools"]
    return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
}

struct SnapshotSummary {
    let successful: Int
    let total: Int
    let limited: Int
    let availableMemoryKiB: Int?
    let audioActive: Bool?
    let mixerUnderruns: String?
    let soundSettings: [SoundSetting]
    let profile: String?
    let collectionComplete: Bool?
    let expectedCommands: Int?

    init(contents: Data) throws {
        guard let document = try JSONSerialization.jsonObject(with: contents) as? [String: Any],
              let results = document["results"] as? [String: [String: Any]],
              !results.isEmpty, results.count <= 64 else {
            throw NSError(domain: "METZSnapshot", code: 1)
        }
        total = results.count
        let expected = document["expected_commands"] as? Int
        expectedCommands = expected.flatMap { (1...64).contains($0) ? $0 : nil }
        if let complete = document["collection_complete"] as? Bool {
            collectionComplete = complete && expectedCommands == total
        } else { collectionComplete = nil }
        let suppliedProfile = document["profile"] as? String
        profile = ["audio", "cast", "remote", "video", "baseline"].contains(suppliedProfile ?? "") ? suppliedProfile : nil
        successful = results.values.filter {
            ($0["returncode"] as? Int) == 0 && ($0["timed_out"] as? Bool) == false &&
            ($0["truncated"] as? Bool) == false &&
            ($0["stderr"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        limited = total - successful
        func firstMatch(_ pattern: String, in text: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        let memory = results["memory"]?["stdout"] as? String ?? ""
        availableMemoryKiB = firstMatch("MemAvailable:\\s+(\\d+)\\s+kB", in: memory).flatMap(Int.init)
        let audio = results["audio_flinger"]?["stdout"] as? String ?? ""
        let tracks = try NSRegularExpression(pattern: "Tracks of which (\\d+) are active")
        let matches = tracks.matches(in: audio, range: NSRange(audio.startIndex..., in: audio))
        audioActive = matches.isEmpty ? nil : matches.contains { match in
            guard let range = Range(match.range(at: 1), in: audio) else { return false }
            return (Int(audio[range]) ?? 0) > 0
        }
        mixerUnderruns = firstMatch("Normal mixer raw underrun counters: (partial=\\d+ empty=\\d+)", in: audio)
        let settings = (results["audio_vendor_settings"]?["stdout"] as? String) ??
            (results["sound_settings"]?["stdout"] as? String) ?? ""
        soundSettings = parseSoundSettings(settings)
    }
}

struct SoundSetting: Equatable, Identifiable {
    let id: String
    let title: String
    let value: Int
}

private let soundSettingNames: [(String, String)] = [
    ("sound_style", "Код профиля"),
    ("sound_bass", "Bass"), ("sound_treble", "Treble"),
    ("sound_balance", "Баланс"), ("sound_surround", "Surround"),
    ("sound_sound_surround", "Vendor surround"),
    ("sound_equalizer", "Код эквалайзера"),
    ("sound_equalizer_detail_120hz", "EQ 120 Hz"),
    ("sound_equalizer_detail_500hz", "EQ 500 Hz"),
    ("sound_equalizer_detail_1500hz", "EQ 1500 Hz"),
    ("sound_equalizer_detail_5000hz", "EQ 5000 Hz"),
    ("sound_equalizer_detail_10000hz", "EQ 10000 Hz"),
    ("sound_auto_volume_control", "Автогромкость"),
    ("sound_auto_volume_leveling", "Выравнивание громкости"),
    ("sound_advanced_sound_mode", "Код расширенного режима"),
    ("sound_advanced_dialogue_enhancer", "Выделение диалогов"),
    ("sound_advanced_surround_virtualizer", "Виртуальный surround"),
    ("sound_advanced_volume_leveler", "Vendor leveler"),
]

func parseSoundSettings(_ output: String) -> [SoundSetting] {
    var values: [String: Int] = [:]
    let allowed = Set(soundSettingNames.map { $0.0 })
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, allowed.contains(String(parts[0])), let value = Int(parts[1]) else { continue }
        values[String(parts[0])] = value
    }
    return soundSettingNames.compactMap { key, title in
        values[key].map { SoundSetting(id: key, title: title, value: $0) }
    }
}
