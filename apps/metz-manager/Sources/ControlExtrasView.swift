import AppKit
import SwiftUI

struct KeyboardInputView: View {
    @ObservedObject var model: ManagerModel
    var enabled: Bool { model.selectedDevice?.available == true && !model.busy }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ввод на телевизоре").font(.title2).bold()
            TextField("Откройте поле ввода на ТВ и напишите здесь", text: $model.keyboardText, axis: .vertical)
                .lineLimit(4...8).textFieldStyle(.roundedBorder).font(.title3)
            HStack(spacing: 12) {
                Button("Вставить") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        if text.utf16.count <= 2048 { model.keyboardText = text }
                        else { model.keyboardStatus = "Буфер длиннее 2048 символов. Вставьте текст частями." }
                    }
                }
                Button("Отправить") { model.sendText() }.disabled(!enabled || model.keyboardText.isEmpty || model.keyboardText.utf16.count > 2048)
                Button("Поиск") { model.sendText(operation: "search") }.disabled(!enabled || model.keyboardText.utf16.count > 2048)
            }
            HStack(spacing: 12) {
                Button("Удалить символ") { model.sendText(operation: "delete") }.disabled(!enabled)
                Button("Удалить всё на ТВ") { model.sendText(operation: "clear") }.disabled(!enabled)
                Button("Ввод") { model.sendText(operation: "enter") }.disabled(!enabled)
            }
            Text(model.keyboardStatus).font(.callout).foregroundStyle(.secondary)
            Text("Текст отправляется в выбранное поле на ТВ. Содержимое буфера читается только по кнопке «Вставить».")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct HomeAppearanceView: View {
    @ObservedObject var model: ManagerModel
    var enabled: Bool { model.selectedDevice?.available == true && !model.busy }
    var body: some View {
        DisclosureGroup("Настройка Home на ТВ") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Плитки", selection: $model.appearance.columns) {
                        Text("Крупные · 2 × 4").tag(4); Text("Обычные · 2 × 5").tag(5); Text("Компактные · 2 × 6").tag(6)
                    }
                    Picker("Названия", selection: $model.appearance.titles) {
                        Text("Автоматически").tag("auto"); Text("Показывать").tag("show"); Text("Скрывать").tag("hide")
                    }
                    Picker("Порядок разделов", selection: $model.appearance.order) {
                        Text("Главная · Приложения · Настройки").tag("HOME,APPS,SETTINGS")
                        Text("Главная · Настройки · Приложения").tag("HOME,SETTINGS,APPS")
                        Text("Приложения · Главная · Настройки").tag("APPS,HOME,SETTINGS")
                        Text("Приложения · Настройки · Главная").tag("APPS,SETTINGS,HOME")
                        Text("Настройки · Главная · Приложения").tag("SETTINGS,HOME,APPS")
                        Text("Настройки · Приложения · Главная").tag("SETTINGS,APPS,HOME")
                    }
                }.disabled(!enabled || !model.appearanceLoaded)
                HStack {
                    Button("Загрузить с ТВ") { model.homeSettings(save: false) }.disabled(!enabled)
                    Button("Применить") { model.homeSettings(save: true) }.disabled(!enabled || !model.appearanceLoaded)
                    Button("Стандартный вид") { model.appearance = HomeAppearance() }.disabled(!model.appearanceLoaded || !enabled)
                    Text(model.appearanceStatus).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 12)
        }
    }
}
struct MeasurementHistoryView: View {
    @ObservedObject var model: ManagerModel
    var body: some View {
        DisclosureGroup("История показаний и доставки команд · последние 30") {
            if model.measurements.isEmpty { Text("Обновите показания или отправьте команду пульта.").foregroundStyle(.secondary) }
            else {
                Table(Array(model.measurements.reversed())) {
                    TableColumn("Время") { item in Text(item.date.formatted(date: .abbreviated, time: .standard)) }
                    TableColumn("CPU") { item in Text(item.cpuPercent.map { String(format: "%.0f %%", $0) } ?? "—") }
                    TableColumn("RAM доступно") { item in Text(item.availableKiB.map { "\($0 / 1024) МиБ" } ?? "—") }
                    TableColumn("Доставка команды") { item in Text(item.deliveryMS.map { String(format: "%.0f мс", $0) } ?? "—") }
                }.frame(height: 180)
                Text("Доставка — подтверждение получения команды; это не время отображения результата на ТВ.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.bottom, 12)
    }
}

struct ManagerMetricsView: View {
    @ObservedObject var model: ManagerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Система").font(.headline)
                Spacer()
                Button("Обновить данные", action: model.refreshMetrics).disabled(model.selectedDevice?.available != true || model.busy)
            }
            HStack(alignment: .top, spacing: 24) {
            metric("CPU", model.metrics?.cpuPercent.map { String(format: "%.0f %%", $0) } ?? "Нет данных")
            metric("RAM · занято / доступно", memory)
            metric("Хранилище · свободно", model.metrics?.storageAvailableKiB.map { "\($0 / 1024) МиБ" } ?? "Нет данных")
            }
            if let date = model.metrics?.measuredAt {
                Text("Данные ТВ · \(date.formatted(date: .numeric, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
        }.monospacedDigit()
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(MetzStyle.secondary)
            Text(value).font(.system(size: 22, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var memory: String {
        guard let used = model.metrics?.usedKiB, let available = model.metrics?.availableKiB else { return "Нет данных" }
        return "\(used / 1024) / \(available / 1024) МиБ"
    }
}
