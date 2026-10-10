import Foundation

@main
struct IdentityCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw StreamError.invalid }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let identity = try StreamIdentity(folder: folder)
        precondition(Wire.validPin(identity.fingerprint))
        print("Local PKCS12 identity imported in memory; fingerprint valid. No key material printed, no network/capture/private API invocation.")
    }
}
