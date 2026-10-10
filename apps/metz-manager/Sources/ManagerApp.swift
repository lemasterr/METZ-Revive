import AppKit
import SwiftUI

@MainActor
final class ManagerAppDelegate: NSObject, NSApplicationDelegate {
    static var operationActive = false
    // Keep cleanup owners alive after SwiftUI removes the last window.
    static var displayManager: ConnectionManager?
    static var model: ManagerModel?
    private var terminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            // Let an in-flight bounded ADB operation finish before releasing its server.
            while Self.operationActive { try? await Task.sleep(for: .milliseconds(100)) }
            await Self.model?.shutdownRemote()
            await Self.displayManager?.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { OwnedADBServer.shared.stop() }
}

@MainActor
final class ManagerModel: ObservableObject {
    private let remoteSession = RemoteSession()
    private var remoteTail: Task<Void, Never>?
    private var pendingKeys = 0
    func shutdownRemote() async {
        await remoteTail?.value
        let session = remoteSession
        await Task.detached { session.close() }.value
    }
    @Published var fastRemote = true
    @Published var roundTripMS: Double?
    @Published var metrics: DeviceMetrics?
    @Published var measurements: [ControlMeasurement] = []
    @Published var health = ConnectionHealth(message: "Соединение не проверено", action: "Нажмите «Проверить соединение».")
    @Published var appearance = HomeAppearance()
    @Published var appearanceLoaded = false
    @Published var appearanceStatus = "Загрузите настройки с ТВ"
    @Published var keyboardText = ""
    @Published var keyboardStatus = "Выберите на ТВ «Клавиатура Mac (METZ)» и откройте поле ввода"
    @Published var applications: [TVApplication] = []
    @Published var controlStatus = "Выберите подключённый телевизор"
    @Published var project: URL?
    @Published var devices: [TVDevice] = []
    @Published var connectionCheckedAt: Date?
    @Published var healthCheckedAt: Date?
    @Published var selectedSerial: String?
    @Published var connectionAddress = UserDefaults.standard.string(forKey: "adbTarget") ?? UserDefaults.standard.string(forKey: "displayHost") ?? ""
    private var reconnectAfter = Date.distantPast
    @Published var profile = DiagnosticProfile.audio
    @Published var busy = false {
        didSet { ManagerAppDelegate.operationActive = busy }
    }
    @Published var status = "Выберите папку METZ Revive"
    @Published var summary: SnapshotSummary?
    @Published var snapshot: URL?
    @Published var history: [SnapshotEntry] = []
    @Published var selectedSnapshot: URL?
    @Published var baselineSummary: SnapshotSummary?
    @Published var baselineSnapshot: URL?
    @Published var historyStatus = "Обновите историю, чтобы открыть сохранённый снимок"

    init() {
        selectedSerial = normalizedADBTarget(connectionAddress)
        if let saved = UserDefaults.standard.string(forKey: "projectFolder") {
            let url = URL(fileURLWithPath: saved)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/collect_diagnostics.py").path) {
                project = url
                status = "Обновите список подключённых устройств"
            }
        }
        if project == nil {
            var folder = Bundle.main.bundleURL
            for _ in 0..<7 {
                folder.deleteLastPathComponent()
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent("scripts/collect_diagnostics.py").path) {
                    project = folder
                    UserDefaults.standard.set(folder.path, forKey: "projectFolder")
                    status = "Обновите список подключённых устройств"
                    break
                }
            }
        }
    }

    var selectedDevice: TVDevice? { devices.first { $0.serial == selectedSerial } }
    var canCollect: Bool { project != nil && selectedDevice?.available == true && !busy }
    var differences: [SnapshotDifference]? {
        guard let baselineSummary, let summary, let baselineSnapshot, let snapshot,
              baselineSnapshot.resolvingSymlinksInPath().path != snapshot.resolvingSymlinksInPath().path else { return nil }
        return compareSnapshots(baselineSummary, summary)
    }

    func control(_ action: TVAction) {
        // Power-off bypasses the Home bridge's intentionally narrow key whitelist.
        guard fastRemote, action.keyCode != nil, action != .powerOff else {
            operate { controller, serial in try controller.send(action, serial: serial); return nil }
            return
        }
        guard let device = selectedDevice, device.available, !busy, pendingKeys < 8, let adb = existingTool("adb") else { return }
        let serial = device.serial, previous = remoteTail, session = remoteSession
        pendingKeys += 1
        controlStatus = "Отправка…"
        remoteTail = Task {
            await previous?.value
            guard selectedSerial == serial else { pendingKeys -= 1; return }
            let result = await Task.detached { () -> Result<Double, Error> in
                Result { try session.send(action, serial: serial, adb: adb) }
            }.value
            pendingKeys -= 1
            switch result {
            case .success(let elapsed):
                roundTripMS = elapsed; controlStatus = "Команда доставлена"
                measurements = MeasurementHistory.append(ControlMeasurement(deliveryMS: elapsed), serial: serial)
            case .failure: controlStatus = "Быстрый канал недоступен. Обновите Home на ТВ; резервный ADB можно выбрать ниже. Повтор — через минуту."
            }
        }
    }
    func disconnectRemote() {
        let previous = remoteTail, session = remoteSession
        remoteTail = Task { await previous?.value; await Task.detached { session.close() }.value }
        roundTripMS = nil
    }
    func switchKeyboard(restore: Bool) {
        guard !busy, let device = selectedDevice, device.available, let adb = existingTool("adb") else { return }
        let serial = device.serial, storageKey = "keyboardRecovery-" + device.serial
        let saved = UserDefaults.standard.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(KeyboardRecovery.self, from: $0) }
        if restore && saved == nil { keyboardStatus = "Сохранённого состояния нет. Выберите клавиатуру через настройки ТВ."; return }
        if !restore && saved != nil { keyboardStatus = "Сначала верните прежнюю клавиатуру — её состояние уже сохранено."; return }
        busy = true
        Task {
            let success = await Task.detached { () -> Bool in
                let controller = TVController(adb: adb)
                do {
                    if restore, let saved { try controller.restoreKeyboard(serial: serial, recovery: saved) }
                    else { try controller.activateKeyboard(serial: serial) { recovery in
                        if let bytes = try? JSONEncoder().encode(recovery) { UserDefaults.standard.set(bytes, forKey: storageKey) }
                    } }
                    return true
                } catch { return false }
            }.value
            busy = false
            if success && restore { UserDefaults.standard.removeObject(forKey: storageKey) }
            keyboardStatus = success ? (restore ? "Прежняя клавиатура возвращена" : "Клавиатура Mac включена. Откройте поле ввода на ТВ.") : "Переключение не завершено. Состояние сохранено; верните клавиатуру или откройте настройки ТВ."
        }
    }
    func sendText(operation: String = "text") {
        let value = keyboardText
        keyboardStatus = "Отправка…"
        guard !busy, let device = selectedDevice, device.available, let adb = existingTool("adb") else { keyboardStatus = "ADB недоступен. Проверьте соединение."; return }
        busy = true
        let serial = device.serial
        Task {
            let delivered = await Task.detached { try? TVController(adb: adb).keyboard(operation: operation, text: value, serial: serial) }.value
            let success = delivered != nil
            busy = false
            guard selectedSerial == serial else { return }
            if success && ["text", "search", "clear"].contains(operation) && keyboardText == value { keyboardText = "" }
            keyboardStatus = success ? (delivered == true ? "Готово" : "Текст доставлен. Приложение на ТВ не поддерживает команду поиска; нажмите «Ввод».") : "Не выполнено. Откройте поле на ТВ и включите ввод с Mac. Поиск и очистка должны поддерживаться приложением на ТВ."
        }
    }
    func refreshMetrics() {
        guard let device = selectedDevice, device.available, !busy, let adb = existingTool("adb") else { return }
        busy = true
        let serial = device.serial
        Task {
            let value = await Task.detached { try? TVController(adb: adb).metrics(serial: serial) }.value
            busy = false
            if selectedSerial == serial {
                metrics = value
                if let value, value.availableKiB != nil || value.cpuPercent != nil {
                    measurements = MeasurementHistory.append(ControlMeasurement(date: value.measuredAt, availableKiB: value.availableKiB, cpuPercent: value.cpuPercent), serial: serial)
                }
            }
            controlStatus = value == nil ? "Показания недоступны: проверьте подключение и доступ к /proc" : "Показания обновлены"
        }
    }
    func prepareDisplay(pin: String, completion: @escaping (String?) -> Void) {
        guard !busy, let device = selectedDevice, device.available, let adb = existingTool("adb"), validFingerprint(pin) else { completion(nil); return }
        busy = true
        let serial = device.serial
        Task {
            let value = await Task.detached { () -> String? in
                let controller = TVController(adb: adb)
                guard (try? controller.preparePairing(pin: pin, serial: serial)) != nil else { return nil }
                return try? controller.televisionPin(serial: serial)
            }.value
            busy = false
            controlStatus = value == nil ? "Не удалось прочитать ключ ТВ. Обновите METZ Display на ТВ." : "Ключи подготовлены. Подтвердите доверие на ТВ."
            completion(value)
        }
    }
    func loadDisplayModes(completion: @escaping ([StreamMode]) -> Void) {
        guard !busy, let device = selectedDevice, device.available, let adb = existingTool("adb") else { completion([]); return }
        busy = true
        let serial = device.serial
        Task {
            let data = await Task.detached { try? TVController(adb: adb).displayModes(serial: serial) }.value
            busy = false
            completion(selectedSerial == serial ? data.map(StreamMode.parse) ?? [] : [])
        }
    }
    func reconnectTV(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !busy, let adb = existingTool("adb") else { status = "ADB недоступен или выполняется операция"; completion(false); return }
        guard let target = normalizedADBTarget(connectionAddress) else { status = "Введите IP-адрес ТВ; порт ADB по умолчанию 5555"; completion(false); return }
        guard Date() >= reconnectAfter else { status = "После ошибки подключения подождите минуту"; completion(false); return }
        busy = true; status = "Подключение к ТВ…"
        Task {
            let access = await LocalNetworkAccess.check(target: target)
            guard access == .allowed else {
                busy = false
                if access == .denied {
                    status = "Разрешите METZ Manager доступ: Настройки системы → Конфиденциальность и безопасность → Локальная сеть. Затем нажмите подключение снова."
                } else {
                    reconnectAfter = Date().addingTimeInterval(60)
                    status = "Порт ADB на ТВ недоступен. Проверьте адрес и сеть; повтор — через минуту. Если macOS спрашивает доступ к локальной сети, разрешите его для METZ Manager."
                }
                completion(false)
                return
            }
            let found = await Task.detached { try? TVController(adb: adb).connect(target: target) }.value
            busy = false
            if let found { devices = found }
            connectionCheckedAt = Date()
            let state = found?.first { $0.serial == target }
            if state?.available == true {
                selectedSerial = target; connectionAddress = target
                UserDefaults.standard.set(target, forKey: "adbTarget")
                status = "ТВ подключён"; reconnectAfter = .distantPast; completion(true)
            } else {
                reconnectAfter = Date().addingTimeInterval(60)
                status = state?.state == "unauthorized" ? "Подтвердите разрешение ADB на ТВ, затем подключитесь снова через минуту" : "ТВ недоступен. Проверьте адрес, сеть и включённый ADB; повтор — через минуту"
                completion(false)
            }
        }
    }
    func verifyDisplay(pin: String, completion: @escaping (String?) -> Void) {
        guard !busy else { completion("Дождитесь завершения операции."); return }
        if let target = normalizedADBTarget(selectedSerial ?? connectionAddress) {
            connectionAddress = target
            reconnectTV { connected in
                if connected { self.activateDisplay(pin: pin, completion: completion) }
                else { completion(self.status) }
            }
        } else { activateDisplay(pin: pin, completion: completion) }
    }
    private func activateDisplay(pin: String, completion: @escaping (String?) -> Void) {
        guard !busy, let device = selectedDevice, device.available, let adb = existingTool("adb") else {
            completion("Подключите ТВ по адресу в верхней панели и дождитесь завершения операции."); return
        }
        busy = true
        let serial = device.serial
        Task {
            let ready = await Task.detached { () -> ReceiverReadiness? in
                let controller = TVController(adb: adb)
                guard let trusted = try? controller.activateDisplaySession(pin: pin, serial: serial) else { return nil }
                if !trusted { return ReceiverReadiness(listening: false, trusted: false) }
                for _ in 0..<10 {
                    guard let state = try? controller.receiverHealth(pin: pin, serial: serial) else { return nil }
                    if state.listening { return state }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                return ReceiverReadiness(listening: false, trusted: true)
            }.value
            busy = false
            guard selectedSerial == serial else { completion("Телевизор изменился. Подготовьте подключение заново."); return }
            if let ready {
                controlStatus = ready.message ?? "Приёмник ТВ готов"
                completion(ready.message)
            }
            else { completion("ADB недоступен или Display не отвечает. Проверьте соединение, затем подготовьте подключение.") }
        }
    }
    func checkConnection() {
        guard !busy else { return }
        // A cold owned server has no transports even if Terminal used this TV.
        // Resolve the saved target through the same explicit connect flow first.
        if selectedDevice?.available != true, normalizedADBTarget(connectionAddress) != nil {
            reconnectTV { connected in
                if connected { self.checkConnection() }
                else {
                    self.health = ConnectionHealth(message: "Нет ответа по ADB", action: self.status)
                    self.healthCheckedAt = Date()
                }
            }
            return
        }
        guard let device = selectedDevice, device.available, let adb = existingTool("adb") else {
            health = ConnectionHealth(message: selectedDevice?.state == "unauthorized" ? "Подтвердите ADB на ТВ" : "Подключение не проверено",
                action: "Выберите телевизор или укажите адрес в настройках подключения.")
            return
        }
        busy = true
        let serial = device.serial
        Task {
            let result = await Task.detached { try? TVController(adb: adb).connectionHealth(serial: serial) }.value
            busy = false
            guard selectedSerial == serial else { return }
            healthCheckedAt = Date()
            health = result ?? ConnectionHealth(message: "Не удалось проверить питание", action: "Нет ответа на запрос. Это не подтверждает выключение ТВ; подключитесь снова через минуту.")
        }
    }
    func homeSettings(save: Bool) {
        guard !busy, let device = selectedDevice, device.available, let adb = existingTool("adb"), !save || appearanceLoaded else { return }
        let serial = device.serial, value = appearance
        busy = true
        Task {
            let result = await Task.detached { try? TVController(adb: adb).homeAppearance(serial: serial, set: save ? value : nil) }.value
            busy = false
            guard selectedSerial == serial else { return }
            if let result { appearance = result; appearanceLoaded = true; appearanceStatus = save ? "Настройки применены на ТВ" : "Настройки загружены с ТВ" }
            else { appearanceLoaded = false; appearanceStatus = "Настройки недоступны. Проверьте ADB и обновите Home на ТВ." }
        }
    }
    func loadApplications() {
        guard !busy, let device = selectedDevice, device.available, let adb = existingTool("adb") else { return }
        busy = true
        let serial = device.serial
        Task {
            let controller = TVController(adb: adb)
            let result = await Task.detached { try? controller.applications(serial: serial) }.value
            guard selectedSerial == serial else { busy = false; return }
            guard let result else { busy = false; controlStatus = "Список недоступен"; return }
            applications = result
            controlStatus = "Приложения: \(result.count). Загрузка иконок…"
            for app in result {
                guard selectedSerial == serial else { break }
                let bytes = await Task.detached { try? controller.icon(for: app, serial: serial) }.value
                if let index = applications.firstIndex(where: { $0.id == app.id }) { applications[index].icon = bytes }
            }
            busy = false; controlStatus = "Приложения загружены"
        }
    }
    func launch(_ app: TVApplication) {
        operate { controller, serial in try controller.launch(app, serial: serial); return nil }
    }
    func preparePairing(pin: String) {
        operate { controller, serial in try controller.preparePairing(pin: pin, serial: serial); return nil }
    }
    private func operate(_ operation: @escaping (TVController, String) throws -> [TVApplication]?) {
        guard !busy, let device = selectedDevice, device.available, let adb = existingTool("adb") else {
            controlStatus = "Обновите устройства и выберите ТВ в состоянии device"
            return
        }
        busy = true
        controlStatus = "Выполняется…"
        let serial = device.serial
        Task {
            let result = await Task.detached { () -> Result<[TVApplication]?, Error> in
                Result { try operation(TVController(adb: adb), serial) }
            }.value
            busy = false
            switch result {
            case .success(let apps):
                if let apps { applications = apps }
                controlStatus = "Готово"
                keyboardStatus = "Доставлено. Можно вводить следующий текст."
            case .failure:
                controlStatus = "Команда не выполнена. Проверьте ADB и повторите вручную через минуту."
                keyboardStatus = "Не доставлено. Откройте поле на ТВ и выберите клавиатуру Mac."
            }
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать проект"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/collect_diagnostics.py").path) else {
            status = "В папке нет scripts/collect_diagnostics.py"
            return
        }
        project = url
        summary = nil
        snapshot = nil
        history = []
        selectedSnapshot = nil
        baselineSummary = nil
        baselineSnapshot = nil
        UserDefaults.standard.set(url.path, forKey: "projectFolder")
        status = "Обновите список подключённых устройств"
        refreshHistory()
    }

    func refreshHistory() {
        guard let project, !busy else { return }
        busy = true
        historyStatus = "Чтение списка снимков…"
        Task {
            let entries = await Task.detached { try? SnapshotStore.entries(project: project) }.value
            busy = false
            guard let entries else {
                history = []; selectedSnapshot = nil
                historyStatus = "История недоступна; проверьте папку local/diagnostics"
                return
            }
            history = entries
            if !entries.contains(where: { $0.url == selectedSnapshot }) { selectedSnapshot = entries.first?.url }
            historyStatus = entries.isEmpty ? "Сохранённых снимков нет" : "Последние снимки: \(entries.count)"
        }
    }

    func openSnapshot() {
        guard let project, let selectedSnapshot, !busy else { return }
        busy = true
        historyStatus = "Чтение снимка…"
        Task {
            let parsed = await Task.detached { try? SnapshotStore.load(selectedSnapshot, project: project) }.value
            busy = false
            guard let parsed else {
                historyStatus = "Снимок не прочитан: требуется JSON сборщика в local/diagnostics, не более 16 МиБ"
                return
            }
            summary = parsed
            snapshot = selectedSnapshot
            historyStatus = "Снимок открыт локально"
        }
    }

    func useAsBaseline() {
        guard !busy, let summary, let snapshot else { return }
        baselineSummary = summary
        baselineSnapshot = snapshot
    }

    func refreshDevices() {
        guard !busy else { return }
        guard let adb = existingTool("adb") else { status = "ADB не найден; установка не выполняется"; return }
        busy = true
        status = "Проверка подключения…"
        Task {
            let result = await Task.detached {
                try? runCommand(executable: adb, arguments: ["devices", "-l"], timeout: 10)
            }.value
            busy = false
            guard let result, adbSucceeded(result) else {
                devices = []
                status = "Не удалось получить список ADB; повторите проверку вручную"
                return
            }
            devices = parseDevices(result.output)
            connectionCheckedAt = Date()
            if connectionAddress.isEmpty, let target = devices.first(where: { $0.available && normalizedADBTarget($0.serial) != nil })?.serial {
                connectionAddress = target; UserDefaults.standard.set(target, forKey: "adbTarget")
            }
            if !devices.contains(where: { $0.serial == selectedSerial }) {
                selectedSerial = devices.first(where: { $0.available })?.serial ?? normalizedADBTarget(connectionAddress)
            }
            status = devices.isEmpty ? "Подключённых устройств нет" : "Выберите устройство в состоянии device"
        }
    }

    func collect() {
        guard canCollect, let project, let device = selectedDevice,
              let python = existingTool("python3"), let adb = existingTool("adb") else {
            status = "Нужны существующие Python 3, ADB и подключённый ТВ"
            return
        }
        busy = true
        summary = nil
        snapshot = nil
        status = "Сбор снимка только чтением…"
        let chosenProfile = profile
        let label = "manager-\(chosenProfile.rawValue)-\(UUID().uuidString.lowercased())"
        let destination = project.appendingPathComponent("local/diagnostics/\(label).json")
        let script = project.appendingPathComponent("scripts/collect_diagnostics.py")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = adb.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        let processEnvironment = environment
        Task {
            let result = await Task.detached {
                guard let environment = try? adbCommandEnvironment(processEnvironment, executable: adb) else { return nil as CommandResult? }
                return try? runCommand(executable: python,
                                arguments: [script.path, "--serial", device.serial, "--profile", chosenProfile.rawValue, "--label", label],
                                timeout: 420, environment: environment)
            }.value
            busy = false
            guard let result, result.exitCode == 0, !result.timedOut, !result.truncated,
                  let parsed = try? SnapshotStore.load(destination, project: project) else {
                status = "Сбор не завершён; проверьте подключение. Частичный снимок, если есть, остаётся в local/diagnostics"
                return
            }
            snapshot = destination
            summary = parsed
            status = parsed.limited == 0 ? "Снимок собран" : "Снимок собран с ограничениями доступа/команд"
            refreshHistory()
        }
    }
}

@main
struct METZManagerApp: App {
    @NSApplicationDelegateAdaptor(ManagerAppDelegate.self) private var delegate
    @StateObject private var model = ManagerModel()
    var body: some Scene {
        WindowGroup("METZ Manager") {
            ManagerView(model: model)
                .frame(minWidth: 960, minHeight: 720)
        }
        .windowResizability(.contentSize)
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: ManagerModel
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                MetzPageTitle(title: "Диагностика")
                Spacer()
                Button("Папка проекта…", action: model.chooseProject).disabled(model.busy)
            }
            ManagerMetricsView(model: model)
            VStack(alignment: .leading, spacing: 12) {
                Picker("Диагностика", selection: $model.profile) {
                    ForEach(DiagnosticProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.segmented).disabled(model.busy)
            }
            HStack(spacing: 12) {
                Button("Обновить устройства", action: model.refreshDevices).disabled(model.busy)
                Button("Проверить сейчас", action: model.collect).buttonStyle(MetzButtonStyle(primary: true)).disabled(!model.canCollect)
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Сбор данных") }
            }
            Text(model.status).foregroundStyle(.secondary)
                .accessibilityLabel("Статус: \(model.status)")
            Divider()
            HStack(alignment: .top, spacing: 28) {
                snapshotResults.frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(MetzStyle.line).frame(width: 1)
                snapshotHistory.frame(width: 270, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            MeasurementHistoryView(model: model)
            HStack {
                Text("Raw-снимки остаются в local/diagnostics").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let snapshot = model.snapshot {
                    Button("Показать снимок") { NSWorkspace.shared.activateFileViewerSelecting([snapshot]) }
                }
            }
        }
        .padding(MetzStyle.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var snapshotHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("История снимков").font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                Picker("Снимок", selection: $model.selectedSnapshot) {
                    Text("Выберите снимок").tag(URL?.none)
                    ForEach(model.history) { entry in
                        Text("\(entry.modifiedAt.formatted(date: .numeric, time: .shortened)) — \(entry.name)")
                            .tag(Optional(entry.url))
                    }
                }
                .disabled(model.busy)
                Button("Обновить", action: model.refreshHistory).disabled(model.project == nil || model.busy)
                Button("Открыть", action: model.openSnapshot).disabled(model.selectedSnapshot == nil || model.busy)
            }
            Text(model.historyStatus).font(.callout).foregroundStyle(.secondary)
        }
    }
    private var snapshotResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.summary == nil {
                Label("Пока нет снимка", systemImage: "waveform.path.ecg").font(.headline)
                Text("Запустите проверку или откройте сохранённый снимок.").foregroundStyle(MetzStyle.secondary)
            }
            if let summary = model.summary {
                Divider()
                Text(model.snapshot?.deletingPathExtension().lastPathComponent ?? "Снимок").font(.headline)
                if let profile = summary.profile { Text("Профиль: \(profile)").foregroundStyle(.secondary) }
                Text(summary.collectionComplete == true ? "Сбор завершён" :
                    summary.collectionComplete == false ? "Сбор не завершён" : "Старый снимок: полнота сбора не зафиксирована")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Команды без ограничений: \(summary.successful) из \(summary.total)")
                if let expected = summary.expectedCommands, expected != summary.total {
                    Text("Собрано команд: \(summary.total) из \(expected)")
                }
                if summary.limited > 0 { Text("С ограничениями: \(summary.limited)") }
                if let memory = summary.availableMemoryKiB {
                    Text("Доступная Android RAM: \(memory / 1024) МиБ")
                }
                if let active = summary.audioActive {
                    Text(active ? "Активная аудиодорожка найдена" : "Активной аудиодорожки в снимке нет")
                }
                if let underruns = summary.mixerUnderruns { Text("Mixer underruns: \(underruns)") }
                if !summary.soundSettings.isEmpty {
                    DisclosureGroup("Сохранённые настройки звука") {
                        ForEach(summary.soundSettings) { setting in
                            LabeledContent(setting.title, value: String(setting.value))
                        }
                        Text("Числа из vendor settings; шкала и применение в DSP не подтверждены.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Взять этот снимок как A", action: model.useAsBaseline).disabled(model.busy)
                Text("Один снимок не подтверждает исправность звука или прирост скорости.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let baseline = model.baselineSnapshot {
                Text("A: \(baseline.deletingPathExtension().lastPathComponent)")
                    .font(.callout).foregroundStyle(.secondary)
                if let baselineSummary = model.baselineSummary {
                    Text(baselineSummary.collectionComplete == true ? "A: сбор завершён" :
                        baselineSummary.collectionComplete == false ? "A: сбор не завершён" : "A: полнота старого снимка не зафиксирована")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let differences = model.differences {
                Divider()
                Text("Различия A → текущий снимок").font(.headline)
                if differences.isEmpty {
                    Text("В общих доступных показаниях различий не найдено.")
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        GridRow { Text("Показание").bold(); Text("A").bold(); Text("Текущий").bold() }
                        ForEach(differences) { difference in
                            GridRow { Text(difference.title); Text(difference.before); Text(difference.after) }
                        }
                    }
                }
                Text("Устройство и условия между снимками не подтверждены. Это различия показаний, а не замер улучшения. Счётчики могли сброситься после перезапуска.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

}


/// Local key monitor exists only while explicitly enabled and the Manager is frontmost.
struct RemoteKeyCapture: NSViewRepresentable {
    let send: (TVAction) -> Void
    func makeNSView(context: Context) -> NSView { context.coordinator.install(); return NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.send = send }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }
    func makeCoordinator() -> Coordinator { Coordinator(send: send) }
    final class Coordinator {
        var send: (TVAction) -> Void
        private var monitor: Any?
        private var menuObservers: [NSObjectProtocol] = []
        private var menuTracking = false
        init(send: @escaping (TVAction) -> Void) { self.send = send }
        func install() {
            menuObservers = [
                NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = true },
                NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = false }
            ]
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard NSApp.isActive, NSApp.modalWindow == nil, self?.menuTracking == false,
                    !(NSApp.keyWindow?.firstResponder is NSTextView), event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                let mapping: [UInt16: TVAction] = [123: .left, 124: .right, 125: .down, 126: .up, 36: .select, 53: .back]
                guard let action = mapping[event.keyCode] else { return event }
                self?.send(action); return nil
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            menuObservers.forEach(NotificationCenter.default.removeObserver); menuObservers = []
        }
        deinit { remove() }
    }
}
