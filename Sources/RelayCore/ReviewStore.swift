import CryptoKit
import Foundation
import Security

/// What this Mac knows about one corrected ask: the revision the owner accepted, the one
/// they last saw as current, and every hash it has pinned (rollback detection). It lives in
/// `reviews.json`, each record sealed with HMAC under a key only Hook can read, never in
/// UserDefaults: a plain `defaults write` would pre-accept a correction.
public struct ReviewRecord: Codable, Equatable, Sendable {
    public var accepted: RevisionStamp?
    /// Set when the detail first rendered this stamp while it was current; a locked render never sets it.
    public var seen: RevisionStamp?
    /// rev → hash, for every verified stamp seen. Pinning never sets `seen`.
    public var pins: [Int: String]
    /// Step ids that show "Changed" or "New" until ticked.
    public var changed: [String]
    /// The local acceptance hasn't reached the Pond yet: it is sent again before Done or answers.
    public var pondAcceptPending: Bool
    /// Of `changed`, the ids that were added (chip "New"); the rest show "Changed".
    public var added: [String]

    public init(accepted: RevisionStamp? = nil, seen: RevisionStamp? = nil, pins: [Int: String] = [:],
                changed: [String] = [], pondAcceptPending: Bool = false, added: [String] = []) {
        self.accepted = accepted; self.seen = seen; self.pins = pins; self.changed = changed
        self.pondAcceptPending = pondAcceptPending; self.added = added
    }

    /// The highest pinned rev; 0 without pins.
    public var highestPin: Int { pins.keys.max() ?? 0 }
}

/// `reviews.json`: `{"v":1,"records":{key:{"record":…,"mac":"<hex HMAC-SHA256>"}}}`. The MAC
/// covers `"hook-review-v1\n" + key + "\n" + record` (sorted-keys JSON), so a record edited on
/// disk, or copied to another ask's key, no longer verifies. App-local: no other side reads it.
public enum ReviewStore {
    public static let version = 1

    public static func key(sourceKey: String, id: String) -> String { sourceKey + "|" + id }

    /// The records whose MAC verifies. A record that fails is dropped and `tampered` is true;
    /// so is a file that isn't a review file. A missing file is no records, not tampered.
    public static func load(from url: URL, sealKey: SymmetricKey) -> (records: [String: ReviewRecord], tampered: Bool) {
        guard let data = try? Data(contentsOf: url) else { return ([:], false) }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.v == version else { return ([:], true) }
        var records: [String: ReviewRecord] = [:]
        var tampered = false
        for (key, entry) in file.records {
            guard let mac = Data(hex: entry.mac),
                  HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: macInput(key: key, record: entry.record),
                                                         using: sealKey) else {
                tampered = true
                continue
            }
            records[key] = entry.record
        }
        return (records, tampered)
    }

    /// The whole file, every record sealed.
    public static func sealed(records: [String: ReviewRecord], sealKey: SymmetricKey) -> Data {
        var entries: [String: Entry] = [:]
        for (key, record) in records {
            let mac = HMAC<SHA256>.authenticationCode(for: macInput(key: key, record: record), using: sealKey)
            entries[key] = Entry(record: record, mac: Data(mac).map { String(format: "%02x", $0) }.joined())
        }
        return (try? encoder.encode(File(v: version, records: entries))) ?? Data()
    }

    static func macInput(key: String, record: ReviewRecord) -> Data {
        var input = Data(("hook-review-v1\n" + key + "\n").utf8)
        input.append((try? encoder.encode(record)) ?? Data())
        return input
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private struct File: Codable {
        var v: Int
        var records: [String: Entry]
    }

    private struct Entry: Codable {
        var record: ReviewRecord
        var mac: String
    }
}

/// The review store's seal key: 32 random bytes in the Keychain item "Hook review seal".
public enum ReviewSeal {
    /// The stored key, or a new one when there is no item. A read the Keychain refuses throws
    /// (`SecretStoreError.unreadable`) and never mints a new key over the old one.
    public static func loadOrCreate(_ secrets: any SecretStore) throws -> SymmetricKey {
        if let data = try secrets.read(.reviewSeal) {
            guard data.count == 32 else { throw SecretStoreError.unreadable(errSecDecode) }
            return SymmetricKey(data: data)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SecretStoreError.writeFailed(errSecAllocate)
        }
        try secrets.write(.reviewSeal, Data(bytes))
        return SymmetricKey(data: bytes)
    }
}

extension Data {
    /// Lowercase or uppercase hex, two digits a byte; nil for anything else.
    init?(hex: String) {
        let scalars = Array(hex.unicodeScalars)
        guard scalars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(scalars.count / 2)
        var index = 0
        while index < scalars.count {
            guard let high = Self.nibble(scalars[index]), let low = Self.nibble(scalars[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ c: Unicode.Scalar) -> UInt8? {
        switch c {
        case "0"..."9": return UInt8(c.value - 48)
        case "a"..."f": return UInt8(c.value - 87)
        case "A"..."F": return UInt8(c.value - 55)
        default: return nil
        }
    }
}
