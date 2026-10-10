import Foundation
import Darwin

/// One authenticated ADB shell per active remote. No TCP listener or device daemon.
final class RemoteSession: @unchecked Sendable {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var buffered = Data()
    private var serial: String?
    private var failedAt: TimeInterval?
    deinit { close() }

    func send(_ action: TVAction, serial: String, adb: URL) throws -> Double {
        if let failedAt, ProcessInfo.processInfo.systemUptime - failedAt < 60 { throw TVControlError.unavailable }
        do {
            if self.serial != serial || process?.isRunning != true { try open(serial: serial, adb: adb) }
            guard let key = action.keyCode, let input else { throw TVControlError.failed }
            let start = ProcessInfo.processInfo.systemUptime
            try input.write(contentsOf: Data("KEY \(key)\n".utf8))
            guard try readLine(timeout: 2) == "OK" else { throw TVControlError.failed }
            return (ProcessInfo.processInfo.systemUptime - start) * 1000
        } catch {
            close(); failedAt = ProcessInfo.processInfo.systemUptime
            throw error
        }
    }
    func close() {
        try? input?.close(); input = nil
        if let process, process.isRunning {
            process.terminate()
            let until = ProcessInfo.processInfo.systemUptime + 0.3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? output?.close(); try? errorOutput?.close()
        output = nil; errorOutput = nil; process = nil; serial = nil; buffered.removeAll()
    }
    private func open(serial: String, adb: URL) throws {
        close()
        let controller = TVController(adb: adb)
        let result = try controller.execute(serial: serial, shell: ["pm", "path", "com.metzrevive.home"])
        guard let path = result.output.split(separator: "\n").first(where: { $0.hasSuffix("/base.apk") })?.dropFirst(8),
              path.hasPrefix("/data/app/"), path.count < 400,
              path.range(of: #"^[A-Za-z0-9_/.=+~\-]+$"#, options: .regularExpression) != nil else { throw TVControlError.unavailable }
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = adb
        process.environment = try adbCommandEnvironment(ProcessInfo.processInfo.environment, executable: adb)
        process.arguments = ["-s", serial, "shell", "-T", "CLASSPATH='\(path)' app_process / com.metzrevive.home.RemoteBridge"]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; errorOutput = stderr.fileHandleForReading
        for file in [output, errorOutput].compactMap({ $0 }) {
            let fd = file.fileDescriptor; _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        guard try readLine(timeout: 10) == "METZ_READY_1" else { throw TVControlError.unavailable }
        self.serial = serial
    }
    private func readLine(timeout: Double) throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        guard let output else { throw TVControlError.failed }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let newline = buffered.firstIndex(of: 10) {
                let value = String(decoding: buffered[..<newline], as: UTF8.self)
                buffered.removeSubrange(...newline)
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                buffered.append(contentsOf: bytes.prefix(count))
                if buffered.count > 8192 { throw TVControlError.failed }
            } else if count == 0 { throw TVControlError.unavailable }
            else if errno != EAGAIN && errno != EINTR { throw TVControlError.failed }
            if let errorOutput {
                let errors = Darwin.read(errorOutput.fileDescriptor, &bytes, bytes.count)
                if errors > 0 { throw TVControlError.failed }
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        throw TVControlError.failed
    }
}
