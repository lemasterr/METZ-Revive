import Foundation

@main
struct CoreCheck {
    static func main() throws {
        try checkOwnedADBServer()
        precondition(localNetworkPermissionDenied(reason: .localNetworkDenied, error: nil))
        precondition(localNetworkPermissionDenied(reason: nil, error: .posix(.EACCES)))
        precondition(!localNetworkPermissionDenied(reason: .notAvailable, error: .posix(.ECONNREFUSED)))
        precondition(!localNetworkPermissionDenied(reason: nil, error: nil))
        let coldStart = CommandResult(exitCode: 0, output: "List of devices attached\n", timedOut: false, truncated: false,
            hasErrorOutput: true, errorOutput: "* daemon not running; starting now at tcp:5037\n* daemon started successfully\n")
        precondition(adbSucceeded(coldStart))
        precondition(!adbSucceeded(CommandResult(exitCode: 0, output: "", timedOut: false, truncated: false, hasErrorOutput: true, errorOutput: "permission denied")))
        let independent = adbEnvironment(["HOME": "/local-home", "ADB_VENDOR_KEYS": "/authorized-key-folder", "ADB_SERVER_SOCKET": "tcp:localhost:9999", "ANDROID_ADB_SERVER_PORT": "9999"])
        precondition(independent["HOME"] == "/local-home" && independent["ADB_VENDOR_KEYS"] == "/authorized-key-folder" && independent["ADB_SERVER_SOCKET"] == nil && independent["ANDROID_ADB_SERVER_PORT"] == nil)
        precondition(normalizedADBTarget("192.0.2.1") == "192.0.2.1:5555")
        precondition(normalizedADBTarget("192.0.2.1:1234") == "192.0.2.1:1234")
        for invalid in ["", "-a", "256.0.2.1", "192.0.2.1:0", "192.0.2.1:65536", "192.0.2.1;reboot", "192.0.2.1:5555:6"] { precondition(normalizedADBTarget(invalid) == nil) }
        precondition(parseSessionRequest("Broadcast completed: result=0, data=\"METZ_SESSION_TRUSTED\"") == true)
        precondition(parseSessionRequest("Broadcast completed: result=0, data=\"METZ_SESSION_NEEDS_TRUST\"") == false)
        precondition(parseSessionRequest("Broadcast completed: result=1, data=\"METZ_SESSION_TRUSTED\"") == nil)
        precondition(parseSessionRequest("Broadcast completed: result=0, data=\"unknown\"") == nil)
        precondition(HomeAppearance().valid)
        precondition(!HomeAppearance(columns: 4, titles: "show", order: "HOME,HOME,APPS").valid)
        precondition(ConnectionHealth.power("mWakefulness=Asleep").message == "ТВ спит")
        precondition(ConnectionHealth.power("  mWakefulness = Awake\n mWakefulnessChanging=false").message.contains("включён"))
        precondition(!ConnectionHealth.power("mWakefulnessChanging=Awake").message.contains("включён"))
        precondition(ConnectionHealth.power("").message.contains("не определено"))
        precondition(ReceiverReadiness(listening: false, trusted: true).message?.contains("не запущен") == true)
        precondition(ReceiverReadiness(listening: true, trusted: false).message?.contains("другой ключ") == true)
        precondition(ReceiverReadiness(listening: true, trusted: true).message == nil)
        let measurementTarget = "test-" + UUID().uuidString
        defer { MeasurementHistory.clear(measurementTarget) }
        for index in 0..<35 { _ = MeasurementHistory.append(ControlMeasurement(deliveryMS: Double(index)), serial: measurementTarget) }
        let recent = MeasurementHistory.load(measurementTarget)
        precondition(recent.count == 30 && recent.first?.deliveryMS == 5 && recent.last?.deliveryMS == 34)
        precondition(MeasurementHistory.load(measurementTarget + "other").isEmpty)

        let devices = parseDevices("List of devices attached\nunit-a device product:Metz model:METZ_2K_TV\nunit-b unauthorized\nunit-c offline\n* daemon started successfully\n")
        precondition(devices.count == 3 && devices.filter(\.available).count == 1)
        precondition(devices[0].serial == "unit-a" && devices[0].model == "METZ_2K_TV")
        precondition(!devices[1].available && !devices[2].available)
        let json = """
        {"results": {
          "memory": {"returncode": 0,"timed_out": false,"truncated": false,"stdout":"MemAvailable: 204800 kB","stderr":"Permission denied"},
          "audio_flinger": {"returncode": 0,"timed_out": false,"truncated": false,"stdout":"2 Tracks of which 0 are active\\n1 Tracks of which 1 are active\\nNormal mixer raw underrun counters: partial=0 empty=2"},
          "errors": {"returncode": 0,"timed_out": true,"truncated": false}
        }}
        """
        let summary = try SnapshotSummary(contents: Data(json.utf8))
        precondition(summary.total == 3 && summary.successful == 1 && summary.limited == 2)
        precondition(summary.availableMemoryKiB == 204800 && summary.audioActive == true)
        precondition(summary.mixerUnderruns == "partial=0 empty=2")
        precondition(summary.collectionComplete == nil)
        let settings = parseSoundSettings("sound_bass=70\nsound_surround=1\nsound_treble=null\naccount_token=123\nsound_style=unknown\nsound_bass=71\n")
        precondition(settings.map(\.id) == ["sound_bass", "sound_surround"])
        precondition(settings.map(\.value) == [71, 1])
        let second = """
        {"expected_commands":3,"collection_complete":false,"profile":"audio","results": {
          "memory": {"returncode":0,"timed_out":false,"truncated":false,"stdout":"MemAvailable: 102400 kB"},
          "audio_vendor_settings": {"returncode":0,"timed_out":false,"truncated":false,"stdout":"sound_bass=70\\nsound_surround=1"}
        }}
        """
        let other = try SnapshotSummary(contents: Data(second.utf8))
        precondition(other.collectionComplete == false && other.expectedCommands == 3)
        precondition(other.soundSettings.count == 2)
        let changedSound = second.replacingOccurrences(of: "sound_bass=70", with: "sound_bass=50")
        let changedSummary = try SnapshotSummary(contents: Data(changedSound.utf8))
        let changedValues = compareSnapshots(other, changedSummary)
        precondition(changedValues.count == 1 && changedValues[0].id == "sound_bass")
        precondition(changedValues[0].before == "70" && changedValues[0].after == "50")
        let differences = compareSnapshots(summary, other)
        precondition(differences.count == 1 && differences[0].id == "memory")
        precondition(differences[0].before == "204800" && differences[0].after == "102400")
        // Absent metrics do not become zeros or evidence of improvement.
        precondition(compareSnapshots(other, other).isEmpty)
        let complete = second.replacingOccurrences(of: "\"collection_complete\":false", with: "\"collection_complete\":true")
        let incompleteSummary = try SnapshotSummary(contents: Data(complete.utf8))
        precondition(incompleteSummary.collectionComplete == false)
        let actualComplete = complete.replacingOccurrences(of: "\"expected_commands\":3", with: "\"expected_commands\":2")
        let completedSummary = try SnapshotSummary(contents: Data(actualComplete.utf8))
        precondition(completedSummary.collectionComplete == true)
        do {
            _ = try SnapshotSummary(contents: Data("{\"results\":{}}".utf8))
            preconditionFailure("An empty snapshot must not appear successful")
        } catch { }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("metz-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = temporary.appendingPathComponent("project", isDirectory: true)
        let folder = project.appendingPathComponent("local/diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = folder.appendingPathComponent("a.json"), b = folder.appendingPathComponent("b.json")
        try Data(json.utf8).write(to: a)
        try Data(second.utf8).write(to: b)
        let outside = temporary.appendingPathComponent("outside.json")
        try Data(json.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.json"), withDestinationURL: outside)
        let big = folder.appendingPathComponent("big.json")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let bigHandle = try FileHandle(forWritingTo: big)
        try bigHandle.truncate(atOffset: UInt64(SnapshotStore.maximumBytes + 1))
        try bigHandle.close()
        let entries = try SnapshotStore.entries(project: project)
        guard entries.count == 2 else { throw NSError(domain: "HistoryCount", code: entries.count) }
        precondition(Set(entries.map(\.name)) == Set(["a", "b"]))
        let limitedEntries = try SnapshotStore.entries(project: project, limit: 1)
        let loaded = try SnapshotStore.load(entries[0].url, project: project)
        precondition(limitedEntries.count == 1 && loaded.total > 0)
        for rejected in [outside, folder.appendingPathComponent("linked.json"), big] {
            do {
                _ = try SnapshotStore.load(rejected, project: project)
                preconditionFailure("Outside, linked and oversized files must be rejected")
            } catch { }
        }
        let timeout = try runCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], timeout: 0.1)
        precondition(timeout.timedOut && timeout.exitCode != 0)
        guard let python = existingTool("python3") else { fatalError("Existing Python required") }
        let flooded = try runCommand(executable: python, arguments: ["-c", "import sys; sys.stdout.write('x'*200000); sys.stderr.write('y'*200000)"], timeout: 5)
        precondition(flooded.exitCode == 0 && flooded.truncated && !flooded.timedOut)
        precondition(flooded.output.utf8.count == 65536)
        let largePower = try runCommand(executable: python, arguments: ["-c",
            "import sys; print('  mWakefulness=Awake'); sys.stdout.write('x'*225000)"], timeout: 5,
            maximumOutputBytes: 1024 * 1024)
        precondition(adbSucceeded(largePower) && largePower.output.utf8.count > 225000)
        precondition(ConnectionHealth.power(largePower.output).message.contains("включён"))
        let inheritedStart = ProcessInfo.processInfo.systemUptime
        let inherited = try runCommand(executable: python, arguments: ["-c", "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(1.5)']); print('done')"], timeout: 1)
        precondition(ProcessInfo.processInfo.systemUptime - inheritedStart < 1.0 && inherited.truncated)
        let argument = "value with spaces; $(false)"
        let literal = try runCommand(executable: python, arguments: ["-c", "import sys; print(sys.argv[1])", argument], timeout: 5)
        precondition(literal.output.trimmingCharacters(in: .whitespacesAndNewlines) == argument)
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--project" {
            let project = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let history = try SnapshotStore.entries(project: project)
            let parsed = history.compactMap { try? SnapshotStore.load($0.url, project: project) }
            precondition(!parsed.isEmpty)
            print("Private local history integration: indexed \(history.count), parsed \(parsed.count), sound settings in \(parsed.filter { !$0.soundSettings.isEmpty }.count) snapshots; no raw output")
        }
        precondition(TVAction.up.shellArguments == ["input", "keyevent", "19"])
        precondition(TVAction.powerOff.shellArguments == ["input", "keyevent", "223"])
        precondition(TVAction.settings.shellArguments == ["am", "start", "-a", "android.settings.SETTINGS"])
        precondition(validComponent("com.example.tv/.MainActivity"))
        for invalid in ["com.example/.Main;reboot", "com.example/$(id)", "com.example/.Main Activity", "../Main"] {
            precondition(!validComponent(invalid))
        }
        precondition(parseTVApplications("noise\ncom.example/.Main\ncom.example/.Main\ncom.example/.Main;reboot").count == 1)
        precondition(broadcastData("Broadcast completed: result=0, data=\"[{\"title\":\"Видео\"}]\"\n") == "[{\"title\":\"Видео\"}]")
        precondition(broadcastData("Broadcast completed: result=1, data=\"bad\"") == nil)
        precondition(broadcastData("Broadcast completed: result=0") == nil)
        precondition(parseReceiverReadiness("Broadcast completed: result=0, data=\"{\"listening\":true,\"trusted\":true}\"") == true)
        precondition(parseReceiverReadiness("Broadcast completed: result=0, data=\"{\"listening\":false,\"trusted\":true}\"") == false)
        precondition(parseReceiverReadiness("Broadcast completed: result=0, data=\"{\"listening\":true,\"trusted\":false}\"") == false)
        precondition(parseReceiverReadiness("Broadcast completed: result=0, data=\"{\"listening\":true}\"") == nil)
        precondition(parseReceiverReadiness("Broadcast completed: result=1, data=\"{\"listening\":true,\"trusted\":true}\"") == nil)
        precondition(validFingerprint(normalizedFingerprint(String(repeating: "AA: ", count: 32))))
        precondition(!validFingerprint(String(repeating: "а", count: 64)))
        let memory = memoryValues("MemTotal: 900000 kB\nMemAvailable: 250000 kB\nnoise\n")
        precondition(memory.total == 900000 && memory.available == 250000)
        precondition(memoryValues("permission denied").available == nil)
        let cpuA = "cpu  10 0 10 80 0 0 0 0\n"
        let cpuB = "cpu  20 0 20 160 0 0 0 0\n"
        precondition(abs(cpuUsage(before: cpuA, after: cpuB)! - 20) < 0.001)
        precondition(cpuUsage(before: cpuB, after: cpuA) == nil)
        precondition(cpuUsage(before: cpuA, after: cpuA) == nil)
        precondition(cpuValues("cpu 18446744073709551615 1 1 1 1 1 1 1") == nil)
        let fakeADB = FileManager.default.temporaryDirectory.appendingPathComponent("metz-adb-\(UUID().uuidString)")
        let fakeScript = """
        #!/bin/sh
        if [ "$1" = devices ]; then
          printf 'List of devices attached\\nfake device model:METZ\\n'
        elif [ "$4" = pm ]; then
          printf 'package:/data/app/metz/base.apk\\n'
        elif [ "$4" = am ]; then
          case "$*" in
            *SessionRequestReceiver*bbbb*) printf 'Broadcast completed: result=0, data="METZ_SESSION_NEEDS_TRUST"\\n' ;;
            *SessionRequestReceiver*) printf 'Broadcast completed: result=0, data="METZ_SESSION_TRUSTED"\\n' ;;
            *'start -n com.metzrevive.display/.ReceiverActivity'*) printf 'Starting: Intent\\n' ;;
            *AppearanceReceiver*) printf 'Broadcast completed: result=0, data="{"columns":5,"titles":"auto","order":"HOME,APPS,SETTINGS"}"\\n' ;;
            *'operation search'*) printf 'Broadcast completed: result=0, data="METZ_TEXT_COMMITTED"\\n' ;;
            *'operation clear'*|*'operation text'*) printf 'Broadcast completed: result=0, data="METZ_TEXT_OK"\\n' ;;
            *) exit 1 ;;
          esac
        else
          printf 'METZ_READY_1\\n'
          while read -r command; do
            case "$command" in
              'KEY 19'|'KEY 23') printf 'OK\\n' ;;
              *) printf 'ERROR\\n' ;;
            esac
          done
        fi
        """
        try Data(fakeScript.utf8).write(to: fakeADB)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeADB.path)
        defer { try? FileManager.default.removeItem(at: fakeADB) }
        let connectRoot = FileManager.default.temporaryDirectory.appendingPathComponent("metz-connect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: connectRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: connectRoot) }
        let connector = connectRoot.appendingPathComponent("adb"), state = connectRoot.appendingPathComponent("state"), trace = connectRoot.appendingPathComponent("trace")
        let connectScript = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(trace.path)'
        if [ "$1" = devices ]; then
          printf 'List of devices attached\\n'
          if [ -f '\(state.path)' ]; then printf '192.0.2.1 device model:METZ\\n'; fi
        elif [ "$1" = start-server ]; then
          printf '* daemon started successfully\\n' >&2
        elif [ "$1" = '-s' ] && [ "$3" = wait-for-device ]; then
          test -f '\(state.path)'
        elif [ "$1" = connect ] && [ "$2" = 192.0.2.1:5555 ]; then
          printf 'ready' > '\(state.path)'
        else exit 1; fi
        """
        // The fixture uses the exact network serial returned by real ADB.
        try Data(connectScript.replacingOccurrences(of: "192.0.2.1 device", with: "192.0.2.1:5555 device").utf8).write(to: connector)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: connector.path)
        let connectedDevices = try TVController(adb: connector).connect(target: "192.0.2.1")
        precondition(connectedDevices.first?.available == true && connectedDevices.first?.serial == "192.0.2.1:5555")
        let connectTrace = try String(contentsOf: trace, encoding: .utf8)
        precondition(connectTrace == "devices -l\nstart-server\nconnect 192.0.2.1:5555\n-s 192.0.2.1:5555 wait-for-device\ndevices -l\n")
        do { _ = try TVController(adb: connector).connect(target: "-a;reboot"); preconditionFailure() } catch {}
        let controls = TVController(adb: fakeADB)
        let trustedSession = try controls.activateDisplaySession(pin: String(repeating: "a", count: 64), serial: "fake")
        precondition(trustedSession)
        let firstSession = try controls.activateDisplaySession(pin: String(repeating: "b", count: 64), serial: "fake")
        precondition(!firstSession)
        do {
            _ = try controls.activateDisplaySession(pin: "unsafe; input keyevent 3", serial: "fake")
            preconditionFailure("Invalid peer fingerprint must never launch a session")
        } catch { }
        let textDelivered = try controls.keyboard(operation: "text", text: "Привет 🌍", serial: "fake"); precondition(textDelivered)
        let searchPerformed = try controls.keyboard(operation: "search", text: "Видео", serial: "fake"); precondition(!searchPerformed)
        let cleared = try controls.keyboard(operation: "clear", serial: "fake"); precondition(cleared)
        let homeView = try controls.homeAppearance(serial: "fake")
        precondition(homeView == HomeAppearance())
        do {
            _ = try controls.homeAppearance(serial: "fake", set: HomeAppearance(order: "HOME;reboot,APPS,SETTINGS"))
            preconditionFailure("Unsafe configuration must be rejected")
        } catch { }
        let remote = RemoteSession()
        let firstKey = try remote.send(.up, serial: "fake", adb: fakeADB)
        let secondKey = try remote.send(.select, serial: "fake", adb: fakeADB)
        precondition(firstKey >= 0 && secondKey >= 0)
        remote.close()
        print("Broadcast parsing, Unicode key normalization, missing/reset CPU metrics and persistent remote with fake ADB passed; no device input")
        print("TV control whitelist, component injection rejection and app deduplication passed")
        print("Manager core: authorization, partial/legacy snapshots, sound whitelist, comparison, bounded private history, timeout, output bounds and literal arguments passed")
    }
}
