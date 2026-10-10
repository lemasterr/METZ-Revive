import AppKit
import SwiftUI

#if !METZ_MANAGER
@MainActor
final class DisplayAppDelegate: NSObject, NSApplicationDelegate {
    static weak var manager: ConnectionManager?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = Self.manager, manager.active else { return .terminateNow }
        Task { await manager.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct METZDisplayApp: App {
    @NSApplicationDelegateAdaptor(DisplayAppDelegate.self) private var delegate
    @StateObject private var manager = ConnectionManager()
    var body: some Scene {
        Window("METZ Display", id: "display") {
            DisplayView(manager: manager).frame(minWidth: 740, minHeight: 580)
                .onAppear { DisplayAppDelegate.manager = manager }
                .onDisappear { Task { await manager.stop() } }
        }.windowResizability(.contentSize)
    }
}

#endif

struct DisplayView: View {
    @ObservedObject var manager: ConnectionManager
    var project: URL? = nil
    var serial: String? = nil
    var prepareTV: ((String, @escaping (String?) -> Void) -> Void)? = nil
    var verifyTV: ((String, @escaping (String?) -> Void) -> Void)? = nil
    var loadModes: ((@escaping ([StreamMode]) -> Void) -> Void)? = nil
    @State private var modes = [StreamMode.conservative]
    @State private var mode = StreamMode.conservative
    @State private var audio = false
    @State private var modesStatus = "Проверьте режимы ТВ; до проверки доступен 1280×720 / 30"
    @State private var host = ""
    @State private var pin = ""
    @State private var identity: StreamIdentity?
    @State private var identityStatus = "Выберите созданную папку ключа"
    @State private var pairing = false
    @State private var checkStarted = false
    @State private var selectedDisplay: UInt32 = 0
    @State private var confirmedVirtual = false
    @State private var externalDisplays: [(id: UInt32, name: String)] = []
    @State private var showingFailure = false
    private let background = Color(red: 11/255, green: 18/255, blue: 32/255)
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            MetzPageTitle(title: "Экран")
            HStack(alignment: .top, spacing: 32) {
                connectionSetup.frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(MetzStyle.line).frame(width: 1)
                VStack(alignment: .leading, spacing: 16) {
                    Label(manager.active ? "Трансляция" : "Подключение", systemImage: manager.active ? "dot.radiowaves.left.and.right" : "display")
                        .font(.headline).foregroundStyle(MetzStyle.secondary)
                    Text(manager.status).font(.title3).fontWeight(.medium).textSelection(.enabled)
                    if manager.active {
                        Text(manager.configuredMode.title).font(.callout).foregroundStyle(MetzStyle.secondary)
                        if !manager.statistics.isEmpty { Text(manager.statistics).font(.callout).monospacedDigit().textSelection(.enabled) }
                    }
                    if !manager.lastFailure.isEmpty {
                        Button { showingFailure = true } label: {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                Text("Последняя ошибка…")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                        }.help("Полный текст последней ошибки")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 12) {
                Button(pairing ? "Подключение…" : "Начать трансляцию") {
                    if let verifyTV, let identity {
                        pairing = true
                        verifyTV(identity.fingerprint) { error in
                            pairing = false
                            if let error { manager.showReadinessError(error) }
                            else { identityStatus = "ТВ готов к приёму"; connectWithModes() }
                        }
                    } else { connect() }
                }.buttonStyle(MetzButtonStyle(primary: true))
                    .disabled(pairing || manager.active || identity == nil || !Wire.validPin(pin) || host.isEmpty || (selectedDisplay != 0 && !confirmedVirtual))
                Button(manager.isStopping ? "Остановка…" : "Остановить") { Task { await manager.stop() } }
                    .disabled(!manager.active || manager.isStopping)
            }
            DisclosureGroup("Технические данные") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(manager.active ? "Задано: " + manager.configuredMode.title : "Нет активной трансляции").font(.callout)
                    if manager.active && !manager.statistics.isEmpty { Text(manager.statistics).font(.callout).monospacedDigit().textSelection(.enabled) }
                    Text("Приём в декодер и вывод на Surface — разные замеры. Частота захвата снижается, когда изображение не меняется.").font(.caption).foregroundStyle(.secondary)
                    connectionDetails
                    Button("Доступ к записи экрана…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                    }
                }.padding(.top, 12)
            }
        }.padding(MetzStyle.pagePadding).frame(maxWidth: .infinity, alignment: .leading)
        }.background(MetzStyle.background).tint(MetzStyle.accent).preferredColorScheme(.dark)
        .buttonStyle(MetzButtonStyle())
        .sheet(isPresented: $showingFailure) {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("Ошибка трансляции").font(.title2).bold(); Spacer(); Button("Закрыть") { showingFailure = false } }
                ScrollView { Text(manager.lastFailure).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Скопировать ошибку") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(manager.lastFailure, forType: .string)
                }
            }.padding(24).frame(width: 560, height: 300)
        }
        .onChange(of: selectedDisplay) { confirmedVirtual = false }
        .onChange(of: mode) { selectedDisplay = 0; confirmedVirtual = false }
        .onChange(of: serial) { oldValue, value in if !manager.active {
            if let value, value != oldValue { modes = [.conservative]; mode = .conservative; refreshModes() }
            if let value {
                host = value.split(separator: ":").first.map(String.init) ?? ""
                pin = UserDefaults.standard.string(forKey: "displayPin-" + value) ?? ""
            }
        } }
        .onAppear {
            if host.isEmpty { host = serial?.split(separator: ":").first.map(String.init) ?? UserDefaults.standard.string(forKey: "displayHost") ?? "" }
            if pin.isEmpty, let serial { pin = UserDefaults.standard.string(forKey: "displayPin-" + serial) ?? "" }
            if identity == nil {
                let saved = UserDefaults.standard.string(forKey: "displayIdentityFolder").map { URL(fileURLWithPath: $0) }
                if let folder = saved ?? project?.appendingPathComponent("local/display-identity"), let loaded = try? StreamIdentity(folder: folder) {
                    identity = loaded; identityStatus = "Ключ Mac готов"
                }
            }
            externalDisplays = NSScreen.screens.compactMap { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                    id != CGMainDisplayID(), let state = DisplayTopology.state(of: id),
                    !state.builtIn, state.active, !state.mirrored else { return nil }
                return (id: id, name: "Существующий: \(screen.localizedName)")
            }
            if serial != nil && !manager.active && !CommandLine.arguments.contains("--check") { refreshModes() }
            let arguments = CommandLine.arguments
            if !checkStarted, let index = arguments.firstIndex(of: "--check"), arguments.count > index + 1 {
                checkStarted = true
                Task { await manager.runtimeCheck(configuration: URL(fileURLWithPath: arguments[index + 1]), prepare: verifyTV) }
            }
        }
    }
    private func connectWithModes() {
        guard let loadModes else { connect(); return }
        // Re-read on connection, so restored ADB and a changed TV cannot reuse stale capabilities.
        let hadChoices = modes.count > 1
        pairing = true
        loadModes { available in
            pairing = false
            guard !available.isEmpty else { manager.showReadinessError("Не удалось проверить режимы ТВ. Обновите приёмник и повторите подключение."); return }
            modes = available
            if !hadChoices, let saved = UserDefaults.standard.string(forKey: "displayMode"), let previous = available.first(where: { $0.id == saved }) { mode = previous }
            else if !hadChoices || !available.contains(mode) { mode = available[0] }
            connect()
        }
    }
    private func refreshModes() {
        guard !pairing, !manager.active, let loadModes else { return }
        pairing = true
        loadModes { available in
            pairing = false
            guard !available.isEmpty else { modesStatus = "Не удалось проверить режимы. Подключите ТВ и обновите приёмник."; return }
            modes = available
            if let saved = UserDefaults.standard.string(forKey: "displayMode"), let previous = available.first(where: { $0.id == saved }) { mode = previous }
            else { mode = available[0] }
            modesStatus = available.contains(StreamMode(width: 1366, height: 768, fps: 60)) ? "1366×768 · 60 кадр/с заявлены декодером" : "1366×768 / 60 не заявлен декодером. Выберите доступное разрешение и частоту ниже."
        }
    }
    private func connect() {
        guard let identity, !manager.active, Wire.validPin(pin), !host.isEmpty,
            selectedDisplay == 0 || confirmedVirtual else { return }
        UserDefaults.standard.set(host, forKey: "displayHost")
        UserDefaults.standard.set(mode.id, forKey: "displayMode")
        if let serial { UserDefaults.standard.set(pin, forKey: "displayPin-" + serial) }
        manager.start(host: host, pin: pin, identity: identity, existingVirtualDisplay: selectedDisplay == 0 ? nil : selectedDisplay, mode: mode, audio: audio)
    }
    private var connectionSetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Источник и качество").font(.headline)
            Picker("Экран Mac", selection: $selectedDisplay) {
                Text("Создать виртуальный экран").tag(UInt32(0))
                ForEach(externalDisplays, id: \.id) { display in Text(display.name).tag(display.id) }
            }
            if selectedDisplay != 0 {
                Toggle("Подтверждаю: выбран виртуальный экран", isOn: $confirmedVirtual)
            }
            if manager.active {
                LabeledContent("Задано", value: manager.configuredMode.title)
            } else {
                Picker("Разрешение и частота", selection: $mode) { ForEach(modes) { Text($0.title).tag($0) } }
            }
            if loadModes != nil {
                HStack {
                    Button(pairing ? "Проверка…" : "Режимы ТВ", action: refreshModes).disabled(serial == nil).help(modesStatus)

                }
            }
            Toggle("Звук на ТВ", isOn: Binding(get: { manager.active ? manager.audio : audio }, set: { audio = $0 })).help("Системный звук Mac без микрофона; настройки применяются к следующему сеансу")
            if let identity, let prepareTV {
                Button(pairing ? "Подготовка…" : "Подготовить ТВ") {
                    pairing = true
                    prepareTV(identity.fingerprint) { value in
                        pairing = false
                        if let value { pin = value; identityStatus = "Подтвердите доверие на ТВ" }
                        else { identityStatus = "Подготовка не завершена. Проверьте подключение и версию Display на ТВ." }
                    }
                }.disabled(serial == nil)
            }
            Text(identityStatus).font(.callout).foregroundStyle(.secondary)
            if identity == nil { Button("Выбрать папку ключа…", action: chooseIdentity) }
        }.disabled(manager.active || pairing)
    }
    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Адрес ТВ").font(.caption)
            TextField("IP-адрес телевизора", text: $host)
            Text("Ключ ТВ").font(.caption)
            SecureField("Отпечаток сертификата", text: $pin)
                .onChange(of: pin) { (_: String, value: String) in
                    let normalized = normalizeDisplayPin(value)
                    if normalized != value { pin = normalized }
                }
            if !pin.isEmpty { Text(Wire.validPin(pin) ? "Ключ сохранён" : "Ключ: \(pin.count) из 64 символов").font(.caption) }
            if let identity {
                Button("Скопировать ключ Mac") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(identity.fingerprint, forType: .string)
                }
            }
            Button("Выбрать папку ключа…", action: chooseIdentity)
        }.textFieldStyle(.roundedBorder).disabled(manager.active || pairing)
    }
    private func chooseIdentity() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { identity = try StreamIdentity(folder: url); identityStatus = "Ключ выбран"; UserDefaults.standard.set(url.path, forKey: "displayIdentityFolder") }
        catch { identity = nil; identityStatus = "Нужны identity.p12 и password.txt" }
    }
}

private func normalizeDisplayPin(_ value: String) -> String {
    let characters = value.filter { (character: Character) in
        !character.isWhitespace && character != ":" && character != "-"
    }
    return characters.lowercased()
}
