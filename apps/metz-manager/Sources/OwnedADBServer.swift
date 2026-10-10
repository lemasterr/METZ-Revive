import Foundation
import Darwin

// Manager owns this foreground helper on a private loopback port. It neither
// borrows nor restarts Terminal's global daemon, and stops its own PID on quit.
final class OwnedADBServer: @unchecked Sendable {
    static let shared = OwnedADBServer()
    private let lock = NSLock()
    private var process: Process?
    private var endpoint: String?

    func socket(adb: URL) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if process?.isRunning == true, let endpoint { return endpoint }
        stopLocked()
        let port = try loopbackPort()
        let value = "tcp:localhost:\(port)"
        let child = Process()
        child.executableURL = adb
        // Server -L accepts tcp:port; client ADB_SERVER_SOCKET uses host:port.
        child.arguments = ["-L", "tcp:\(port)", "server", "nodaemon"]
        var environment = adbEnvironment(ProcessInfo.processInfo.environment)
        environment["ADB_MDNS_AUTO_CONNECT"] = "0"
        environment["ADB_LOCAL_TRANSPORT_MAX_PORT"] = "5554"
        environment.removeValue(forKey: "ADB_TRACE")
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            if loopbackReady(port) { endpoint = value; return value }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stopLocked()
        throw TVControlError.unavailable
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }
    private func stopLocked() {
        if let process, process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process = nil; endpoint = nil
    }
    private func address(_ port: UInt16) -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = port.bigEndian
        value.sin_addr.s_addr = inet_addr("127.0.0.1")
        return value
    }
    private func loopbackPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TVControlError.unavailable }
        defer { Darwin.close(descriptor) }
        var value = address(0)
        let result = withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw TVControlError.unavailable }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard named == 0, value.sin_port != 0 else { throw TVControlError.unavailable }
        return UInt16(bigEndian: value.sin_port)
    }
    private func loopbackReady(_ port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var value = address(port)
        return withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
