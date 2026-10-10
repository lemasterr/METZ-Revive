import Foundation
import Darwin

func checkOwnedADBServer() throws {
    let executable = FileManager.default.temporaryDirectory.appendingPathComponent("metz-adb-owner-\(UUID().uuidString).py")
    // Only a loopback fixture. Never invokes ADB or connects to the TV.
    let script = """
    #!/usr/bin/python3
    import socket,sys,os
    assert os.environ['ADB_MDNS_AUTO_CONNECT'] == '0'
    assert os.environ['ADB_LOCAL_TRANSPORT_MAX_PORT'] == '5554'
    assert sys.argv[1] == '-L' and sys.argv[3:] == ['server','nodaemon']
    assert sys.argv[2].startswith('tcp:') and sys.argv[2].count(':') == 1
    listener=socket.socket()
    listener.bind(('127.0.0.1',int(sys.argv[2][4:])))
    listener.listen()
    while True:
        connection,_=listener.accept()
        connection.close()
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let server = OwnedADBServer()
    defer { server.stop(); try? FileManager.default.removeItem(at: executable) }
    let endpoint = try server.socket(adb: executable)
    precondition(endpoint.hasPrefix("tcp:localhost:") && endpoint != "tcp:localhost:5037")
    let reused = try server.socket(adb: executable)
    precondition(reused == endpoint)
    let port = UInt16(endpoint.split(separator: ":").last!)!
    server.stop()
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let open = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
    precondition(!open, "Owned helper must close its listener on stop")
    _ = try server.socket(adb: executable)
    server.stop()
    print("Owned ADB helper: private loopback endpoint, reuse, stop and restart passed with local fixture")
}
