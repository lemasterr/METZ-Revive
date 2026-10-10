import Foundation

struct DeviceMetrics {
    var totalKiB: Int?
    var availableKiB: Int?
    var cpuPercent: Double?
    var storageAvailableKiB: Int?
    var measuredAt = Date()
    var usedKiB: Int? {
        guard let totalKiB, let availableKiB, availableKiB <= totalKiB else { return nil }
        return totalKiB - availableKiB
    }
}
func memoryValues(_ text: String) -> (total: Int?, available: Int?) {
    var values: [String: Int] = [:]
    for line in text.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        if fields.count >= 2, let value = Int(fields[1]), value >= 0 { values[String(fields[0])] = value }
    }
    return (values["MemTotal:"], values["MemAvailable:"])
}
func cpuValues(_ text: String) -> (total: UInt64, idle: UInt64)? {
    guard let row = text.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") }) else { return nil }
    let values = row.split(whereSeparator: { $0.isWhitespace }).dropFirst().prefix(8).compactMap { UInt64($0) }
    guard values.count == 8 else { return nil }
    var total: UInt64 = 0
    for value in values { let sum = total.addingReportingOverflow(value); guard !sum.overflow else { return nil }; total = sum.partialValue }
    let idle = values[3].addingReportingOverflow(values[4]); guard !idle.overflow else { return nil }
    return (total, idle.partialValue)
}
func cpuUsage(before: String, after: String) -> Double? {
    guard let a = cpuValues(before), let b = cpuValues(after), b.total > a.total, b.idle >= a.idle,
          b.idle - a.idle <= b.total - a.total else { return nil }
    return 100 * (1 - Double(b.idle-a.idle)/Double(b.total-a.total))
}
extension TVController {
    func metrics(serial: String) throws -> DeviceMetrics {
        let memory = try? execute(serial: serial, shell: ["cat", "/proc/meminfo"])
        let before = try? execute(serial: serial, shell: ["cat", "/proc/stat"])
        Thread.sleep(forTimeInterval: 0.5)
        let after = try? execute(serial: serial, shell: ["cat", "/proc/stat"])
        let disk = try? execute(serial: serial, shell: ["df", "-k", "/data"])
        let values = memoryValues(memory?.output ?? "")
        let fields = (disk?.output ?? "").split(separator: "\n").last?.split(whereSeparator: { $0.isWhitespace }) ?? []
        let available = fields.count >= 4 ? Int(fields[3]) : nil
        let cpu = cpuUsage(before: before?.output ?? "", after: after?.output ?? "")
        guard values.available != nil || cpu != nil || available != nil else { throw TVControlError.failed }
        return DeviceMetrics(totalKiB: values.total, availableKiB: values.available,
            cpuPercent: cpu, storageAvailableKiB: available)
    }
}
