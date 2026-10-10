import AppKit
import SwiftUI

private enum ManagerPage: String, CaseIterable {
    case control = "Пульт", applications = "Приложения", display = "Экран", diagnostics = "Диагностика", settings = "Настройки"
    var symbol: String {
        switch self {
        case .control: return "dpad"
        case .applications: return "square.grid.2x2"
        case .display: return "display"
        case .diagnostics: return "waveform.path.ecg"
        case .settings: return "gearshape"
        }
    }
}

struct ManagerView: View {
    @ObservedObject var model: ManagerModel
    @StateObject private var displayManager = ConnectionManager()
    @State private var page = ManagerPage.control
    @State private var appQuery = ""
    @AppStorage("remoteKeyboardEnabled") private var keyboardMode = true
    @State private var inputMode = false
    @State private var confirmKeyboard = false
    @State private var connectionDetails = false
    private var canControl: Bool { model.selectedDevice?.available == true && !model.busy }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1100
            HStack(spacing: 0) {
                sidebar(compact: compact)
                Rectangle().fill(MetzStyle.line).frame(width: 1)
                VStack(spacing: 0) {
                    header
                    Rectangle().fill(MetzStyle.line).frame(height: 1)
                    Group {
                        switch page {
                        case .control: remote
                        case .applications: apps
                        case .display:
                            DisplayView(manager: displayManager, project: model.project, serial: model.selectedSerial,
                                prepareTV: model.prepareDisplay, verifyTV: model.verifyDisplay, loadModes: model.loadDisplayModes)
                        case .diagnostics: DiagnosticsView(model: model)
                        case .settings: settings
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    footer
                }
            }
        }
        .background(MetzStyle.background).tint(MetzStyle.accent).preferredColorScheme(.dark)
        .buttonStyle(MetzButtonStyle())
        .onAppear {
            ManagerAppDelegate.displayManager = displayManager
            ManagerAppDelegate.model = model
            if CommandLine.arguments.contains("--check") { page = .display }
        }
        .onChange(of: model.selectedSerial) { _, value in
            if let value, let target = normalizedADBTarget(value) {
                model.connectionAddress = target; UserDefaults.standard.set(target, forKey: "adbTarget")
            }
            model.disconnectRemote(); model.applications = []; model.metrics = nil
            model.appearanceLoaded = false; model.appearanceStatus = "Загрузите настройки с ТВ"
            model.measurements = model.selectedSerial.map(MeasurementHistory.load) ?? []
            model.health = ConnectionHealth(message: "Соединение не проверено", action: "Нажмите «Проверить подключение».")
            model.healthCheckedAt = nil
        }
        .onChange(of: model.fastRemote) { _, _ in model.disconnectRemote() }
        .onChange(of: page) { _, _ in if page != .control { model.disconnectRemote() } }
        .onDisappear { model.disconnectRemote() }
        .sheet(isPresented: $connectionDetails) { connectionSheet }
        .confirmationDialog("Включить клавиатуру Mac на выбранном ТВ?", isPresented: $confirmKeyboard) {
            Button("Включить клавиатуру Mac") { model.switchKeyboard(restore: false) }
        } message: {
            Text("Прежняя клавиатура будет сохранена. Вернуть её можно в настройках. Текст передаётся только в открытое поле на ТВ.")
        }
    }
    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact {
                HStack(spacing: 4) { Text("METZ").fontWeight(.bold); Text("Manager").fontWeight(.light) }
                    .font(.system(size: 19)).padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 24)
            }
            ForEach(ManagerPage.allCases, id: \.self) { item in
                Button { page = item } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol).font(.system(size: 20)).frame(width: 24)
                        if !compact { Text(item.rawValue).font(.system(size: 14, weight: page == item ? .semibold : .regular)); Spacer() }
                    }.frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(page == item ? MetzStyle.accent : MetzStyle.secondary)
                        .background(page == item ? MetzStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .leading) { if page == item { Capsule().fill(MetzStyle.accent).frame(width: 3, height: 24) } }
                }.buttonStyle(.plain).accessibilityLabel(item.rawValue)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                    .help(item.rawValue)
            }.padding(.horizontal, 8)
            Spacer()
            if !compact {
                Text("Управление с Mac").font(.caption).foregroundStyle(.secondary).padding(24)
            }
        }.padding(.top, compact ? 16 : 0).frame(width: compact ? 64 : 216).background(MetzStyle.sidebar)
    }
    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "tv").font(.title3).foregroundStyle(MetzStyle.accent)
            Picker("Телевизор", selection: $model.selectedSerial) {
                Text("Выбрать телевизор").tag(String?.none)
                if let serial = model.selectedSerial, !model.devices.contains(where: { $0.serial == serial }) {
                    Text("Сохранённый телевизор").tag(Optional(serial))
                }
                ForEach(model.devices) { Text($0.model.replacingOccurrences(of: "_", with: " ")).tag(Optional($0.serial)) }
            }.labelsHidden().frame(width: 210).disabled(model.busy || displayManager.active)
            VStack(alignment: .leading, spacing: 2) {
                Label(model.busy ? "Выполняется…" : (model.selectedDevice?.available == true ? "ADB подтверждён" : "Не подключено"), systemImage: model.selectedDevice?.available == true ? "checkmark.circle" : "circle")
                    .font(.callout).foregroundStyle(model.selectedDevice?.available == true ? MetzStyle.success : MetzStyle.secondary)
                if let date = model.connectionCheckedAt {
                    Text("Проверено в \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Подключить") { model.reconnectTV() }.disabled(model.busy || displayManager.active || normalizedADBTarget(model.connectionAddress) == nil)
            Menu {
                Button("Настроить подключение…") { connectionDetails = true }
                Button("Обновить устройства", action: model.refreshDevices).disabled(model.busy)
                Button("Проверить подключение", action: model.checkConnection).disabled(model.busy)
                Divider()
                Button("Выбрать папку проекта…", action: model.chooseProject).disabled(model.busy)
            } label: { Image(systemName: "ellipsis").frame(width: 24) }
                .menuStyle(.borderlessButton).fixedSize().help("Дополнительные действия").accessibilityLabel("Дополнительные действия")
        }.padding(.horizontal, 24).frame(height: 52)
    }
    private var connectionSheet: some View {
        VStack(alignment: .leading, spacing: 24) {
            MetzPageTitle(title: "Подключение телевизора")
            VStack(alignment: .leading, spacing: 8) {
                Text("IP-адрес и порт ADB").font(.headline)
                TextField("Например, 192.0.2.1:5555", text: $model.connectionAddress).textFieldStyle(.roundedBorder)
                Text("Порт по умолчанию — 5555. Подтвердите запрос отладки на телевизоре.").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.status).font(.callout).textSelection(.enabled)
            HStack {
                Button("Подключить") { model.reconnectTV() }.buttonStyle(MetzButtonStyle(primary: true))
                    .disabled(model.busy || displayManager.active || normalizedADBTarget(model.connectionAddress) == nil)
                Spacer()
                Button("Готово") { connectionDetails = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(32).frame(width: 520).background(MetzStyle.background)
    }
    private var footer: some View {
        HStack(spacing: 16) {
            Text(model.busy ? model.status : model.controlStatus).lineLimit(2)
            Spacer()
            if let elapsed = model.roundTripMS { Text("Доставка: \(Int(elapsed.rounded())) мс").monospacedDigit().help("Подтверждение команды, без времени отрисовки на ТВ") }
            if model.busy { ProgressView().controlSize(.small) }
        }.font(.caption).foregroundStyle(MetzStyle.secondary).padding(.horizontal, 24).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(MetzStyle.line).frame(height: 1) }
    }
    private var remote: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MetzPageTitle(title: "Пульт")
                Picker("Управление", selection: $inputMode) { Text("Пульт").tag(false); Text("Ввод с Mac").tag(true) }
                    .pickerStyle(.segmented).frame(width: 300)
                if inputMode {
                    KeyboardInputView(model: model)
                    Button("Включить клавиатуру Mac…") { confirmKeyboard = true }.disabled(!canControl)
                } else {
                    HStack(spacing: 8) {
                        remoteKey("Главная", "house", .home)
                        remoteKey("Назад", "arrow.uturn.backward", .back)
                        remoteKey("Меню", "line.3.horizontal", .menu)
                        remoteKey("Настройки ТВ", "gearshape", .settings)
                    }
                    HStack(alignment: .center, spacing: 24) {
                        VStack(spacing: 8) {
                            remoteKey("Громче", "plus", .volumeUp, iconOnly: true)
                            Image(systemName: "speaker.wave.2").font(.body).accessibilityHidden(true)
                            remoteKey("Тише", "minus", .volumeDown, iconOnly: true)
                            remoteKey("Без звука", "speaker.slash", .mute, iconOnly: true)
                        }.frame(width: 60)
                        Spacer(minLength: 0)
                        DirectionPad(enabled: canControl) { model.control($0) }
                        Spacer(minLength: 0)
                        VStack(spacing: 8) {
                            remoteKey("Пауза", "playpause", .playPause)
                            Button { inputMode = true } label: { Image(systemName: "keyboard").frame(width: 20, height: 20) }.help("Ввод с Mac").accessibilityLabel("Ввод с Mac")
                            Button { page = .applications } label: { Image(systemName: "square.grid.2x2").frame(width: 20, height: 20) }.help("Приложения").accessibilityLabel("Приложения")
                            Button { page = .display } label: { Image(systemName: "display").frame(width: 20, height: 20) }.help("Экран").accessibilityLabel("Экран")
                        }.frame(width: 48)
                    }.padding(.vertical, 12)
                    Toggle("Управление стрелками клавиатуры", isOn: $keyboardMode).disabled(!canControl)
                    if keyboardMode && canControl { RemoteKeyCapture { model.control($0) }.frame(width: 1, height: 1) }
                }
                DisclosureGroup("Подробности подключения") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.health.message).font(.headline)
                        Text(model.health.action).font(.callout).foregroundStyle(.secondary)
                        if let date = model.healthCheckedAt { Text(date.formatted(date: .numeric, time: .standard)).font(.caption).foregroundStyle(.secondary) }
                        Button("Проверить подключение", action: model.checkConnection).disabled(model.busy)
                    }.padding(.top, 12)
                }
            }.padding(MetzStyle.pagePadding).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func remoteKey(_ title: String, _ symbol: String, _ action: TVAction, iconOnly: Bool = true) -> some View {
        Button { model.control(action) } label: {
            if iconOnly { Image(systemName: symbol).font(.system(size: 18)).frame(width: 20, height: 20) }
            else { Label(title, systemImage: symbol).frame(maxWidth: .infinity) }
        }.disabled(!canControl).help(title).accessibilityLabel(title)
    }
    private var apps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MetzPageTitle(title: "Приложения")
                HStack(spacing: 16) {
                    TextField("Найти приложение", text: $appQuery).textFieldStyle(.roundedBorder).accessibilityLabel("Найти приложение")
                    Button("Обновить список", action: model.loadApplications).disabled(!canControl)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 24) {
                    ForEach(model.applications.filter { appQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(appQuery) }) { app in
                        Button { model.launch(app) } label: {
                            HStack(spacing: 12) {
                                Group {
                                    if let bytes = app.icon, let image = NSImage(data: bytes) { Image(nsImage: image).resizable().scaledToFit() }
                                    else { Image(systemName: "app").font(.title).foregroundStyle(MetzStyle.secondary) }
                                }.frame(width: 64, height: 48)
                                Text(app.title).font(.headline).lineLimit(2)
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!canControl).help("Открыть на ТВ: " + app.title)
                    }
                }
                if model.applications.isEmpty {
                    Text(canControl ? "Обновите список, чтобы увидеть приложения на ТВ." : "Подключите телевизор, чтобы увидеть приложения.").foregroundStyle(.secondary)
                } else if !appQuery.isEmpty && !model.applications.contains(where: { $0.title.localizedCaseInsensitiveContains(appQuery) }) {
                    Text("Приложения не найдены").foregroundStyle(.secondary)
                }
            }.padding(MetzStyle.pagePadding)
        }
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MetzPageTitle(title: "Настройки")
                Text("Устройство").font(.headline)
                Button("Настроить подключение…") { connectionDetails = true }
                Button("Выбрать папку проекта…", action: model.chooseProject).disabled(model.busy)
                Divider()
                Text("Управление").font(.headline)
                Picker("Канал пульта", selection: $model.fastRemote) {
                    Text("Быстрый ввод").tag(true); Text("ADB (резерв)").tag(false)
                }.pickerStyle(.segmented).frame(maxWidth: 420)
                HStack {
                    Button("Включить клавиатуру Mac…") { confirmKeyboard = true }
                    Button("Вернуть клавиатуру ТВ") { model.switchKeyboard(restore: true) }
                }.disabled(!canControl)
                Button("Открыть настройки ввода на ТВ") { model.control(.keyboardSettings) }.disabled(!canControl)
                Text(model.keyboardStatus).font(.caption).foregroundStyle(.secondary)
                Divider()
                HomeAppearanceView(model: model)
            }.padding(MetzStyle.pagePadding).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DirectionSector: Shape {
    let angle: Double
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) / 2
        let start = Angle.degrees(angle - 44), end = Angle.degrees(angle + 44)
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: radius * 0.36, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}
private struct DirectionPad: View {
    let enabled: Bool
    let send: (TVAction) -> Void
    private let directions: [(TVAction, String, String, Double)] = [(.up, "Вверх", "chevron.up", -90), (.right, "Вправо", "chevron.right", 0), (.down, "Вниз", "chevron.down", 90), (.left, "Влево", "chevron.left", 180)]
    var body: some View {
        ZStack {
            Circle().fill(MetzStyle.panel).overlay(Circle().stroke(MetzStyle.line, lineWidth: 1))
            ForEach(directions, id: \.0) { action, title, icon, angle in
                Button { send(action) } label: {
                    DirectionSector(angle: angle).fill(Color.clear)
                        .overlay {
                            Image(systemName: icon).font(.system(size: 22, weight: .medium))
                                .offset(x: cos(angle * .pi / 180) * 68, y: sin(angle * .pi / 180) * 68)
                        }.contentShape(DirectionSector(angle: angle))
                }.buttonStyle(.plain).help(title).accessibilityLabel(title)
            }
            Button { send(.select) } label: { Image(systemName: "checkmark").font(.system(size: 20, weight: .semibold)) }
                .frame(width: 64, height: 64).background(MetzStyle.accent.opacity(0.15), in: Circle())
                .overlay(Circle().stroke(MetzStyle.accent, lineWidth: 2)).contentShape(Circle()).buttonStyle(.plain)
                .accessibilityLabel("Подтвердить")
        }.frame(width: 200, height: 200).disabled(!enabled).opacity(enabled ? 1 : 0.45)
    }
}
