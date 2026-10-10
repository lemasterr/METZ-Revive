import Foundation

enum TVAction: String, CaseIterable {
    case up, down, left, right, select, home, back, volumeUp, volumeDown, mute, playPause, enter, delete, menu, keyboardSettings, settings, powerOff
    var keyCode: Int? {
        switch self {
        case .up: return 19
        case .down: return 20
        case .left: return 21
        case .right: return 22
        case .select: return 23
        case .home: return 3
        case .back: return 4
        case .volumeUp: return 24
        case .volumeDown: return 25
        case .mute: return 164
        case .playPause: return 85
        case .enter: return 66
        case .delete: return 67
        case .menu: return 82
        // SLEEP is idempotent; POWER would wake an already sleeping television.
        case .powerOff: return 223
        case .settings, .keyboardSettings: return nil
        }
    }
    var shellArguments: [String] {
        if let keyCode { return ["input", "keyevent", String(keyCode)] }
        return ["am", "start", "-a", self == .keyboardSettings ? "android.settings.INPUT_METHOD_SETTINGS" : "android.settings.SETTINGS"]
    }
}

struct TVApplication: Identifiable, Equatable {
    let component: String
    var label: String? = nil
    var icon: Data? = nil
    var id: String { component }
    var title: String {
        if let label, !label.isEmpty { return label }
        let package = component.split(separator: "/").first.map(String.init) ?? component
        return ["com.google.android.youtube.tv": "YouTube", "tv.twitch.android.app": "Twitch",
                "com.metzrevive.home": "METZ Home", "com.metzrevive.display": "METZ Display",
                "com.aengix.tvbrowser": "Browser", "com.kick.mobile": "Kick"][package] ?? package
    }
}

func validComponent(_ value: String) -> Bool {
    // ADB shell joins remote arguments; restrict components to shell-inert identifier characters.
    value.count <= 240 && value.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.]+$"#,
                                    options: .regularExpression) != nil
}

func parseTVApplications(_ output: String) -> [TVApplication] {
    let values = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    return Array(Set(values.filter(validComponent))).sorted().prefix(80).map { TVApplication(component: $0) }
}

enum TVControlError: Error { case unavailable, invalidComponent, failed, displayStage(String) }

func normalizedADBTarget(_ value: String) -> String? {
    let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 1 || parts.count == 2 else { return nil }
    let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) && (0...255).contains(Int($0) ?? -1) }) else { return nil }
    let port = parts.count == 2 ? Int(parts[1]) : 5555
    guard let port, (1...65535).contains(port), parts.count == 1 || parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return octets.map { String(Int($0)!) }.joined(separator: ".") + ":" + String(port)
}

struct TVController {
    let adb: URL
    func execute(serial: String, shell: [String], maximumOutputBytes: Int = 1024 * 1024, allowedErrorLines: Set<String> = []) throws -> CommandResult {
        let devices = try runCommand(executable: adb, arguments: ["devices", "-l"], timeout: 10)
        guard adbSucceeded(devices),
              parseDevices(devices.output).contains(where: { $0.serial == serial && $0.available }) else {
            throw TVControlError.unavailable
        }
        let result = try runCommand(executable: adb, arguments: ["-s", serial, "shell"] + shell, timeout: 10,
            maximumOutputBytes: maximumOutputBytes)
        let benignWarning = result.exitCode == 0 && !result.timedOut && !result.truncated && result.hasErrorOutput &&
            result.errorOutput.split(separator: "\n").allSatisfy { allowedErrorLines.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard adbSucceeded(result) || benignWarning,
              !result.output.contains("Error:"), !result.output.contains("Exception") else { throw TVControlError.failed }
        return result
    }
    func connect(target: String) throws -> [TVDevice] {
        guard let target = normalizedADBTarget(target) else { throw TVControlError.invalidComponent }
        let before = try runCommand(executable: adb, arguments: ["devices", "-l"], timeout: 10)
        guard adbSucceeded(before) else { throw TVControlError.unavailable }
        if !parseDevices(before.output).contains(where: { $0.serial == target && $0.available }) {
            let started = try runCommand(executable: adb, arguments: ["start-server"], timeout: 10)
            guard adbSucceeded(started) else { throw TVControlError.unavailable }
            let connected = try runCommand(executable: adb, arguments: ["connect", target], timeout: 12)
            guard adbSucceeded(connected) else { throw TVControlError.unavailable }
            // connect can finish before authentication/transport registration is device-ready.
            // One bounded wait, no repeated connect or global server restart.
            _ = try runCommand(executable: adb, arguments: ["-s", target, "wait-for-device"], timeout: 8)
        }
        let after = try runCommand(executable: adb, arguments: ["devices", "-l"], timeout: 10)
        guard adbSucceeded(after) else { throw TVControlError.unavailable }
        return parseDevices(after.output)
    }
    func displayModes(serial: String) throws -> Data {
        let result = try execute(serial: serial, shell: ["am", "broadcast", "-n", "com.metzrevive.display/.StreamModesReceiver"])
        guard let raw = broadcastData(result.output), raw.utf8.count <= 4096 else { throw TVControlError.failed }
        return Data(raw.utf8)
    }
    func send(_ action: TVAction, serial: String) throws {
        _ = try execute(serial: serial, shell: action.shellArguments)
    }
    func applications(serial: String) throws -> [TVApplication] {
        let result = try execute(serial: serial, shell: ["am", "broadcast", "-n", "com.metzrevive.home/.CatalogReceiver"])
        guard let data = broadcastData(result.output),
              let entries = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [[String: String]] else {
            let fallback = try execute(serial: serial, shell: ["cmd", "package", "query-activities", "--brief", "--user", "0",
                "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LEANBACK_LAUNCHER"])
            return parseTVApplications(fallback.output)
        }
        return entries.prefix(80).compactMap {
            guard let component = $0["component"], validComponent(component) else { return nil }
            return TVApplication(component: component, label: $0["title"])
        }
    }
    func icon(for app: TVApplication, serial: String) throws -> Data? {
        guard validComponent(app.component) else { throw TVControlError.invalidComponent }
        let result = try execute(serial: serial, shell: ["am", "broadcast", "-n", "com.metzrevive.home/.CatalogReceiver", "--es", "component", app.component])
        guard let raw = broadcastData(result.output), let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String],
              let encoded = object["icon"], let bytes = Data(base64Encoded: encoded), bytes.count <= 40000 else { return nil }
        return bytes
    }
    @discardableResult func keyboard(operation: String, text: String = "", serial: String) throws -> Bool {
        guard ["text", "delete", "enter", "search", "clear"].contains(operation), text.utf16.count <= 2048 else { throw TVControlError.failed }
        var args = ["am", "broadcast", "-a", "com.metzrevive.home.KEYBOARD", "-p", "com.metzrevive.home", "--es", "operation", operation]
        if operation == "text" || (operation == "search" && !text.isEmpty) {
            guard !text.isEmpty else { throw TVControlError.failed }
            args += ["--es", "text64", Data(text.utf8).base64EncodedString()]
        }
        let result = try execute(serial: serial, shell: args)
        let response = broadcastData(result.output)
        guard response == "METZ_TEXT_OK" || (operation == "search" && response == "METZ_TEXT_COMMITTED") else { throw TVControlError.failed }
        return response == "METZ_TEXT_OK"
    }
    func televisionPin(serial: String) throws -> String {
        let result = try execute(serial: serial, shell: ["am", "broadcast", "-n", "com.metzrevive.display/.PairingInfoReceiver"])
        guard let value = broadcastData(result.output), validFingerprint(value) else { throw TVControlError.failed }
        return value.lowercased()
    }
    func receiverReady(pin: String, serial: String) throws -> Bool {
        guard validFingerprint(pin) else { throw TVControlError.failed }
        let result = try execute(serial: serial, shell: ["am", "broadcast", "-n", "com.metzrevive.display/.ReceiverStatusReceiver", "--es", "peer_pin", pin.lowercased()])
        guard let ready = parseReceiverReadiness(result.output) else { throw TVControlError.failed }
        return ready
    }
    func launch(_ app: TVApplication, serial: String) throws {
        guard validComponent(app.component) else { throw TVControlError.invalidComponent }
        _ = try execute(serial: serial, shell: ["am", "start", "-a", "android.intent.action.MAIN", "-n", app.component])
    }
    func preparePairing(pin: String, serial: String) throws {
        guard pin.count == 64, pin.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw TVControlError.invalidComponent }
        _ = try execute(serial: serial, shell: ["am", "start", "-n", "com.metzrevive.display/.ReceiverActivity",
                                               "--es", "peer_pin", pin.lowercased()], allowedErrorLines: [
            "Warning: Activity not started, intent has been delivered to currently running top-most instance.",
            "Warning: Activity not started, its current task has been brought to the front."])
    }
    func activateDisplaySession(pin: String, serial: String) throws -> Bool {
        guard validFingerprint(pin) else { throw TVControlError.invalidComponent }
        let requested: CommandResult
        do { requested = try execute(serial: serial, shell: ["am", "broadcast", "-n",
            "com.metzrevive.display/.SessionRequestReceiver", "--es", "peer_pin", pin.lowercased()]) }
        catch { throw TVControlError.displayStage("REQUEST") }
        guard let trusted = parseSessionRequest(requested.output) else { throw TVControlError.failed }
        // The protected broadcast arms a one-shot launch only for the saved certificate.
        // Explicit ADB activity launch works even when the receiver process was evicted.
        do { try preparePairing(pin: pin, serial: serial) }
        catch { throw TVControlError.displayStage("LAUNCH") }
        return trusted
    }
}

func parseSessionRequest(_ output: String) -> Bool? {
    switch broadcastData(output) {
    case "METZ_SESSION_TRUSTED": return true
    case "METZ_SESSION_NEEDS_TRUST": return false
    default: return nil
    }
}

func parseReceiverReadiness(_ output: String) -> Bool? {
    guard let raw = broadcastData(output),
          let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
          let listening = value["listening"] as? Bool, let trusted = value["trusted"] as? Bool else { return nil }
    return listening && trusted
}

func broadcastData(_ output: String) -> String? {
    guard let marker = output.range(of: "Broadcast completed: result=0, data=\""),
          let end = output[marker.upperBound...].lastIndex(of: "\"") else { return nil }
    return String(output[marker.upperBound..<end])
}
func validFingerprint(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isASCII && $0.isHexDigit }
}
func normalizedFingerprint(_ value: String) -> String {
    value.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }.lowercased()
}

struct KeyboardRecovery: Codable {
    let previous: String
    let wasEnabled: Bool
}
extension TVController {
    static let macKeyboard = "com.metzrevive.home/.MacKeyboard"
    func activateKeyboard(serial: String, preserve: (KeyboardRecovery) -> Void) throws {
        let current = try execute(serial: serial, shell: ["settings", "get", "secure", "default_input_method"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = try execute(serial: serial, shell: ["settings", "get", "secure", "enabled_input_methods"]).output
        guard validComponent(current), canonicalComponent(current) != canonicalComponent(Self.macKeyboard) else { throw TVControlError.failed }
        let recovery = KeyboardRecovery(previous: current,
            wasEnabled: enabled.split(separator: ":").contains { $0.split(separator: ";").first.map { canonicalComponent(String($0.trimmingCharacters(in: .whitespacesAndNewlines))) } == canonicalComponent(Self.macKeyboard) })
        preserve(recovery)
        do {
            _ = try execute(serial: serial, shell: ["ime", "enable", Self.macKeyboard])
            _ = try execute(serial: serial, shell: ["ime", "set", Self.macKeyboard])
            let actual = try execute(serial: serial, shell: ["settings", "get", "secure", "default_input_method"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard canonicalComponent(actual) == canonicalComponent(Self.macKeyboard) else { throw TVControlError.failed }
        } catch {
            // Restore the captured state if switching was only partially applied.
            try? restoreKeyboard(serial: serial, recovery: recovery)
            throw error
        }
    }
    func restoreKeyboard(serial: String, recovery: KeyboardRecovery) throws {
        guard validComponent(recovery.previous) else { throw TVControlError.invalidComponent }
        _ = try execute(serial: serial, shell: ["ime", "set", recovery.previous])
        if !recovery.wasEnabled { _ = try execute(serial: serial, shell: ["ime", "disable", Self.macKeyboard]) }
        let current = try execute(serial: serial, shell: ["settings", "get", "secure", "default_input_method"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canonicalComponent(current) == canonicalComponent(recovery.previous) else { throw TVControlError.failed }
    }
}

func canonicalComponent(_ value: String) -> String {
    let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return value }
    return parts[0] + "/" + (parts[1].hasPrefix(".") ? parts[0] + parts[1] : parts[1])
}
