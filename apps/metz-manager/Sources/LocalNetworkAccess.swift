import Foundation
import Network

enum LocalNetworkAccessResult: Equatable { case allowed, denied, unavailable }

func localNetworkPermissionDenied(reason: NWPath.UnsatisfiedReason?, error: NWError?) -> Bool {
    if reason == .localNetworkDenied { return true }
    if case .posix(let code) = error { return code == .EACCES || code == .EPERM }
    return false
}

enum LocalNetworkAccess {
    // Run only after a human connection request. An app-owned socket lets macOS
    // attribute local network permission to Manager rather than Terminal/adb.
    static func check(target: String) async -> LocalNetworkAccessResult {
        guard let address = normalizedADBTarget(target) else { return .unavailable }
        let parts = address.split(separator: ":")
        guard let port = UInt16(parts[1]), let endpoint = NWEndpoint.Port(rawValue: port) else { return .unavailable }
        return await withCheckedContinuation { continuation in
            LocalNetworkRequest(host: String(parts[0]), port: endpoint, continuation: continuation).start()
        }
    }
}

// Mutable state and all callbacks stay on this request's serial queue.
private final class LocalNetworkRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.metzrevive.manager.network-access")
    private let connection: NWConnection
    private var finished = false
    private let continuation: CheckedContinuation<LocalNetworkAccessResult, Never>
    init(host: String, port: NWEndpoint.Port, continuation: CheckedContinuation<LocalNetworkAccessResult, Never>) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.continuation = continuation
    }
    func start() {
        connection.pathUpdateHandler = { [self] path in
            if localNetworkPermissionDenied(reason: path.unsatisfiedReason, error: nil) { finish(.denied) }
        }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: finish(.allowed)
            case .waiting(let error), .failed(let error):
                if localNetworkPermissionDenied(reason: connection.currentPath?.unsatisfiedReason, error: error) { finish(.denied) }
                else if case .failed = state { finish(.unavailable) }
            case .cancelled: finish(.unavailable)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [self] in finish(.unavailable) }
    }
    private func finish(_ result: LocalNetworkAccessResult) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: result)
    }
}
