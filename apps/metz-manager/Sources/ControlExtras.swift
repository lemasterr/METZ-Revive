import Foundation
import CryptoKit

struct HomeAppearance: Codable, Equatable {
    var columns = 5
    var titles = "auto"
    var order = "HOME,APPS,SETTINGS"
    var valid: Bool {
        let pages = order.split(separator: ",").map(String.init)
        return (4...6).contains(columns) && ["auto", "show", "hide"].contains(titles) &&
            pages.count == 3 && Set(pages) == Set(["HOME", "APPS", "SETTINGS"])
    }
}
struct ReceiverReadiness {
    let listening: Bool
    let trusted: Bool
    var message: String? {
        if !trusted && !listening { return "Первое подключение: подтвердите доверие к этому Mac на ТВ один раз, затем нажмите «Подключить» снова." }
        if !listening { return "Приёмник не запущен. Повторите подключение из Manager; проверьте, что ТВ включён." }
        if !trusted { return "Приёмник ожидает другой ключ Mac. Подготовьте подключение заново и подтвердите новый ключ на ТВ." }
        return nil
    }
}
struct ConnectionHealth {
    var message: String
    var action: String
    static func power(_ output: String) -> ConnectionHealth {
        let expression = try? NSRegularExpression(pattern: #"(?m)^\s*mWakefulness\s*=\s*(Awake|Asleep|Dozing|Dreaming)\b"#)
        let match = expression?.firstMatch(in: output, range: NSRange(output.startIndex..., in: output))
        let state = match.flatMap { Range($0.range(at: 1), in: output) }.map { String(output[$0]) }
        if state == "Asleep" || state == "Dozing" {
            return ConnectionHealth(message: "ТВ спит", action: "Включите ТВ физическим пультом, затем обновите соединение.")
        }
        if state == "Dreaming" {
            return ConnectionHealth(message: "ТВ показывает заставку", action: "Нажмите кнопку физического пульта и обновите соединение.")
        }
        if state == "Awake" {
            return ConnectionHealth(message: "ТВ включён · ADB доступен", action: "Для экрана проверьте готовность приёмника во вкладке «Экран».")
        }
        return ConnectionHealth(message: "ТВ отвечает · питание не определено", action: "Прошивка не сообщила состояние питания. Управление доступно.")
    }
}
struct ControlMeasurement: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var availableKiB: Int?
    var cpuPercent: Double?
    var deliveryMS: Double?
}
enum MeasurementHistory {
    static let limit = 30
    private static func key(_ serial: String) -> String {
        "controlMeasurements-" + SHA256.hash(data: Data(serial.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func clear(_ serial: String) { UserDefaults.standard.removeObject(forKey: key(serial)) }
    static func load(_ serial: String) -> [ControlMeasurement] {
        guard let data = UserDefaults.standard.data(forKey: key(serial)), data.count <= 65536,
              let entries = try? JSONDecoder().decode([ControlMeasurement].self, from: data) else { return [] }
        return Array(entries.suffix(limit))
    }
    static func append(_ entry: ControlMeasurement, serial: String) -> [ControlMeasurement] {
        let entries = Array((load(serial) + [entry]).suffix(limit))
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key(serial)) }
        return entries
    }
}
extension TVController {
    func homeAppearance(serial: String, set value: HomeAppearance? = nil) throws -> HomeAppearance {
        var args = ["am", "broadcast", "-n", "com.metzrevive.home/.AppearanceReceiver", "--es", "operation", value == nil ? "get" : "set"]
        if let value {
            guard value.valid else { throw TVControlError.failed }
            args += ["--ei", "columns", String(value.columns), "--es", "titles", value.titles, "--es", "order", value.order]
        }
        let result = try execute(serial: serial, shell: args)
        guard let raw = broadcastData(result.output), let decoded = try? JSONDecoder().decode(HomeAppearance.self, from: Data(raw.utf8)), decoded.valid else { throw TVControlError.failed }
        return decoded
    }
    func connectionHealth(serial: String) throws -> ConnectionHealth {
        ConnectionHealth.power(try execute(serial: serial, shell: ["dumpsys", "power"]).output)
    }
    func receiverHealth(pin: String, serial: String) throws -> ReceiverReadiness {
        guard validFingerprint(pin) else { throw TVControlError.failed }
        let result = try execute(serial: serial, shell: ["am", "broadcast", "-n", "com.metzrevive.display/.ReceiverStatusReceiver", "--es", "peer_pin", pin.lowercased()])
        guard let raw = broadcastData(result.output), let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let listening = value["listening"] as? Bool, let trusted = value["trusted"] as? Bool else { throw TVControlError.failed }
        return ReceiverReadiness(listening: listening, trusted: trusted)
    }
}
