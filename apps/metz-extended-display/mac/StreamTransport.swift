import Foundation
import Network
import Security
import CryptoKit

struct StreamIdentity {
    let identity: SecIdentity
    let fingerprint: String
    init(folder: URL) throws {
        let p12 = folder.appendingPathComponent("identity.p12")
        let passwordFile = folder.appendingPathComponent("password.txt")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p12.path),
              (attrs[.size] as? Int ?? Int.max) < 65_536 else { throw StreamError.invalid }
        guard let passwordAttrs = try? FileManager.default.attributesOfItem(atPath: passwordFile.path),
              (passwordAttrs[.size] as? Int ?? Int.max) <= 256 else { throw StreamError.invalid }
        let password = try String(contentsOf: passwordFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard password.count >= 32, password.count <= 128 else { throw StreamError.invalid }
        var imported: CFArray?
        var options: [CFString: Any] = [kSecImportExportPassphrase: password]
        if #available(macOS 15, *) { options[kSecImportToMemoryOnly] = true }
        guard SecPKCS12Import(try Data(contentsOf: p12) as CFData, options as CFDictionary, &imported) == errSecSuccess,
              let entry = (imported as? [[String: Any]])?.first,
              let value = entry[kSecImportItemIdentity as String], CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else { throw StreamError.unavailable }
        identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw StreamError.unavailable }
        fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Single ordered send in flight; no growing queue or dropped H.264 reference frames.
protocol FramePacketTransport: AnyObject {
    func send(_ data: Data, pts: UInt64, completion: @escaping (Bool) -> Void)
    func sendAudio(_ data: Data)
}
final class StreamTransport: FramePacketTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "metz.stream.transport")
    private var connection: NWConnection?
    private var sending = false
    private var protocolReady = false
    private var delivery = FrameDeliveryGate()
    private var sendCompletion: ((Bool) -> Void)?
    private var generation = UUID()
    private var sendSequence: UInt64 = 0
    private var heartbeat: DispatchSourceTimer?
    private var heartbeatPending = false
    private var audioWrites = WriteDeadlineGate()
    private var trustFailure: String?
    private var waitingError: NWError?
    var decoded: (() -> Void)?
    var frameReport: ((TVFrameReport) -> Void)?
    var keyframeRequested: (() -> Void)?
    var ready: (() -> Void)?
    var failure: ((String) -> Void)?

    func connect(host: String, pin: String, identity: StreamIdentity) throws {
        guard Wire.validPin(pin), !host.isEmpty, host.count <= 253,
              !host.contains(where: { $0.isWhitespace }) else { throw StreamError.invalid }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        guard let local = sec_identity_create(identity.identity) else { throw StreamError.unavailable }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        let expected = pin.lowercased()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let leaf = (SecTrustCopyCertificateChain(trustRef) as? [SecCertificate])?.first else { complete(false); return }
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
            // Out-of-band full leaf fingerprint is the explicit trust anchor; never accept any cert.
            guard fingerprint == expected else {
                self?.trustFailure = "Ключ ТВ изменился. Подготовьте подключение заново и подтвердите доверие на ТВ."
                complete(false); return
            }
            SecTrustSetPolicies(trustRef, SecPolicyCreateBasicX509())
            SecTrustSetAnchorCertificates(trustRef, [leaf] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trustRef, true)
            let valid = SecTrustEvaluateWithError(trustRef, nil)
            if !valid { self?.trustFailure = "Сертификат ТВ не прошёл проверку. Проверьте дату устройств и подготовьте ключи заново." }
            complete(valid)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 47_421, using: parameters)
        queue.async {
            self.connection?.cancel()
            self.completeSend(false)
            self.generation = UUID(); self.connection = connection; self.sending = false; self.protocolReady = false; self.audioWrites = WriteDeadlineGate()
            self.trustFailure = nil; self.waitingError = nil
            let token = self.generation
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == token else { return }
                switch state {
                case .ready:
                    self.readReceipt(connection, token: token)
                    self.startHeartbeat(connection, token: token)
                case .failed(let error): self.fail(self.trustFailure ?? Self.explanation(error))
                case .waiting(let error): self.waitingError = error
                default: break
                }
            }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.generation == token, !self.protocolReady else { return }
                self.fail(self.trustFailure ?? self.waitingError.map(Self.explanation) ?? "ТВ не подтвердил готовность за 10 секунд. Проверьте сеть и обновление приёмника.")
            }
        }
    }

    func send(_ data: Data, pts: UInt64, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard let connection = self.connection, connection.state == .ready, self.protocolReady, !self.sending,
                  data.count <= Wire.maximumPayload + Wire.headerSize + 65_560 else {
                completion(false); return
            }
            self.sending = true
            self.delivery = FrameDeliveryGate(pts: pts); self.sendCompletion = completion
            let token = self.generation
            self.sendSequence &+= 1
            let sequence = self.sendSequence
            connection.send(content: data, completion: .contentProcessed { error in
                guard self.generation == token else { return }
                if error != nil { self.fail(); return }
                self.delivery.markWritten()
                if self.delivery.complete { self.completeSend(true) }
            })
            self.queue.asyncAfter(deadline: .now() + 3) {
                if self.generation == token && self.sendSequence == sequence && self.sending {
                    self.fail(self.delivery.written ? "Декодер ТВ не подтвердил приём кадра за 3 секунды." : "Передача кадра на ТВ остановилась.")
                }
            }
        }
    }
    // Audio has at most one small network write in flight and never holds video credit.
    // Drop raw sound samples under congestion rather than growing latency or memory.
    func sendAudio(_ data: Data) {
        queue.async {
            guard data.count <= 8216, self.protocolReady,
                let connection = self.connection, connection.state == .ready,
                let write = self.audioWrites.begin() else { return }
            let token = self.generation
            connection.send(content: data, completion: .contentProcessed { error in
                guard self.generation == token else { return }
                self.audioWrites.complete(write)
                if error != nil { self.fail() }
            })
            self.queue.asyncAfter(deadline: .now() + 2) {
                if self.generation == token && self.audioWrites.expired(write) { self.fail("Передача звука остановилась. Повторите подключение без звука.") }
            }
        }
    }
    private func readReceipt(_ connection: NWConnection, token: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, ended, error in
            guard let self, self.generation == token else { return }
            if let byte = data?.first {
                if byte == 0x52 {
                    guard !self.protocolReady else { self.fail(); return }
                    self.protocolReady = true; self.ready?()
                }
                else if byte == 0x46 {
                    guard !ended, error == nil else { self.fail(); return }
                    self.readFrameReceipt(connection, token: token)
                    return
                }
                else if byte == 0x54 {
                    self.readFrameReport(connection, token: token); return
                }
                else if byte == 0xE4 {
                    self.readFormatFailure(connection, token: token); return
                }
                else if byte == 0xE3 { self.fail("Звук ТВ недоступен. Повторите подключение без трансляции звука."); return }
                else if byte == 0xE2 { self.fail("Аппаратный декодер ТВ остановился. Повторите подключение."); return }
                else if byte == 0x50 { self.decoded?() }
                else if byte == 0x49 { self.keyframeRequested?() }
                else if byte != 0x41 { self.fail(); return }
            }
            if ended || error != nil { self.fail() }
            else { self.readReceipt(connection, token: token) }
        }
    }
    private func readFormatFailure(_ connection: NWConnection, token: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, _ in
            guard let self, self.generation == token else { return }
            let stages = [1: "HEADER", 2: "PAYLOAD", 3: "CONFIG", 4: "VIDEO", 5: "AUDIO", 6: "PING"]
            let code = data?.first.flatMap { stages[Int($0)] } ?? "UNKNOWN"
            self.fail("ТВ отклонил данные потока [TV_\(code)]. Повторите подключение.")
        }
    }
    private func readFrameReport(_ connection: NWConnection, token: UUID) {
        connection.receive(minimumIncompleteLength: 24, maximumLength: 24) { [weak self] data, _, ended, error in
            guard let self, self.generation == token else { return }
            guard let data, !ended, error == nil, let report = try? TVFrameReport.parse(data) else { self.fail(); return }
            self.frameReport?(report)
            self.readReceipt(connection, token: token)
        }
    }
    private func readFrameReceipt(_ connection: NWConnection, token: UUID) {
        connection.receive(minimumIncompleteLength: 8, maximumLength: 8) { [weak self] data, _, ended, error in
            guard let self, self.generation == token else { return }
            guard let data, let pts = try? Wire.receiptPTS(data), !ended, error == nil,
                self.sending, self.delivery.acknowledge(pts: pts) else { self.fail(); return }
            if self.delivery.complete { self.completeSend(true) }
            self.readReceipt(connection, token: token)
        }
    }
    private func startHeartbeat(_ connection: NWConnection, token: UUID) {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 4, repeating: 4)
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == token, !self.sending, !self.heartbeatPending else { return }
            guard let ping = try? Wire.packet(type: 3, epoch: 1, payload: Data()) else { return }
            self.heartbeatPending = true
            connection.send(content: ping, completion: .contentProcessed { error in
                if self.generation == token { self.heartbeatPending = false; if error != nil { self.fail() } }
            })
            self.queue.asyncAfter(deadline: .now() + 2) {
                if self.generation == token && self.heartbeatPending { self.fail() }
            }
        }
        heartbeat = timer; timer.resume()
    }
    private static func explanation(_ error: NWError) -> String {
        switch error {
        case .posix(.ECONNREFUSED): return "ТВ ещё не принимает экран. Нажмите «Подтвердить и принимать» в METZ Display на ТВ."
        case .tls: return "Не удалось подтвердить доверие. Сверьте ключи Mac и ТВ и дату устройств."
        case .dns: return "Адрес ТВ не найден. Выберите подключённый телевизор или проверьте адрес."
        default: return "Соединение с ТВ прервано. Проверьте локальную сеть и повторите подключение."
        }
    }
    private func fail(_ reason: String = "Поток прерван. Повторите подключение вручную.") {
        heartbeat?.cancel(); heartbeat = nil
        connection?.cancel(); connection = nil; generation = UUID(); protocolReady = false; audioWrites = WriteDeadlineGate()
        failure?(reason)
        completeSend(false)
    }
    private func completeSend(_ success: Bool) {
        let completion = sendCompletion; sendCompletion = nil; sending = false
        completion?(success)
    }
    func stop() {
        queue.async {
            self.heartbeat?.cancel(); self.heartbeat = nil; self.connection?.cancel(); self.connection = nil
            self.generation = UUID(); self.protocolReady = false; self.completeSend(false)
        }
    }
    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.heartbeat?.cancel(); self.heartbeat = nil
                self.connection?.cancel(); self.connection = nil
                self.generation = UUID(); self.protocolReady = false; self.completeSend(false)
                continuation.resume()
            }
        }
    }
}
