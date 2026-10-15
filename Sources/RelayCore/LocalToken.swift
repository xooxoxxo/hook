import CryptoKit
import Foundation
import Security

/// The local-mode bearer token and the server proof. The token is
/// never logged or shown; the UI shows only `file`'s path.
public struct LocalToken: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// The token, created when the file is missing or empty. An existing file with
    /// permissions wider than 0600 is tightened. Calls are serialised in this
    /// process, so two callers racing on a missing file get the same token (the
    /// one left on disk), never one each.
    public func ensure() throws -> String {
        try Self.ensureLock.withLock { try ensureLocked() }
    }

    private static let ensureLock = NSLock()

    private func ensureLocked() throws -> String {
        try checkTrusted()
        if let existing = read() {
            try tighten()
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw LocalTokenError.randomFailed(status) }
        let token = Self.hex(bytes)
        try PrivateFile.write(Data(token.utf8), to: file)
        return token
    }

    /// Trimmed contents; nil when the file is missing, unreadable or empty.
    public func read() -> String? {
        do {
            try checkTrusted()
        } catch {
            NSLog("Relay: %@", error.localizedDescription)
            return nil
        }
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Lowercase hex of HMAC-SHA256(key: the token's UTF-8,
    /// message: "relay-proof-v1\n" + String(port) + "\n" + nonce). The port binds the
    /// proof to this listener, so one answered on another port never matches.
    public static func proof(token: String, port: Int, nonce: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(("relay-proof-v1\n" + String(port) + "\n" + nonce).utf8),
            using: SymmetricKey(data: Data(token.utf8)))
        return hex(Array(code))
    }

    /// 32 to 64 ASCII hex digits, either case.
    public static func isValidNonce(_ nonce: String) -> Bool {
        let bytes = Array(nonce.utf8)
        guard (32...64).contains(bytes.count) else { return false }
        return bytes.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Constant time whatever the inputs: compares HMACs of both strings under a
    /// key that exists only in this process, so neither length nor content leaks.
    public static func matches(_ presented: String, _ expected: String) -> Bool {
        let key = SymmetricKey(data: processKey)
        let a = HMAC<SHA256>.authenticationCode(for: Data(presented.utf8), using: key)
        let b = HMAC<SHA256>.authenticationCode(for: Data(expected.utf8), using: key)
        return a == b
    }

    /// Raw bytes rather than a `SymmetricKey`, which isn't declared Sendable.
    private static let processKey: Data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func checkTrusted() throws {
        let directory = file.deletingLastPathComponent()
        // A missing folder is created (and checked) by PrivateFile.write.
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try PrivateFile.checkTrusted(directory: directory)
        try PrivateFile.checkTrusted(file: file)
    }

    private func tighten() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if mode & 0o777 & ~0o600 != 0 {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}

enum LocalTokenError: Error, Sendable {
    case randomFailed(OSStatus)
}
