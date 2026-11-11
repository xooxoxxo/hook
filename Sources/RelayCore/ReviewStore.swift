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
    /// `ReviewGate.bodyHash` of the verified rev 1 body pinned at `pins[1]`: an older Pond may
    /// serve the ask without revisions, but only with exactly this payload.
    public var firstBodyHash: String?
    /// The last day (whole days since 1970, UTC) the ask was listed, in Recently closed or open
    /// here. The Pond controls the list, so a record with pins outlives a poll that leaves the
    /// ask out: it goes only after `retentionDays` without one.
    public var listedDay: Int?

    /// How long a pinned record outlives its ask's absence from the list.
    public static let retentionDays = 30

    public init(accepted: RevisionStamp? = nil, seen: RevisionStamp? = nil, pins: [Int: String] = [:],
                changed: [String] = [], pondAcceptPending: Bool = false, added: [String] = [],
                firstBodyHash: String? = nil, listedDay: Int? = nil) {
        self.accepted = accepted; self.seen = seen; self.pins = pins; self.changed = changed
        self.pondAcceptPending = pondAcceptPending; self.added = added; self.firstBodyHash = firstBodyHash
        self.listedDay = listedDay
    }

    /// Whole days since 1970, UTC.
    public static func day(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) }

    /// The highest pinned rev; 0 without pins.
    public var highestPin: Int { pins.keys.max() ?? 0 }
}

/// `reviews.json`: `{"v":1,"seal":"<id>","records":{key:{"record":…,"mac":"<hex HMAC-SHA256>"}}}`.
/// The MAC covers `"hook-review-v1\n" + key + "\n" + record` (sorted-keys JSON), so a record
/// edited on disk, or copied to another ask's key, no longer verifies. `seal` is `sealID` of the
/// key that sealed it: Hook's creation marker for the seal item (`ReviewSeal`). App-local: no
/// other side reads it.
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

    /// The whole file, every record sealed, naming its seal.
    public static func sealed(records: [String: ReviewRecord], sealKey: SymmetricKey) -> Data {
        var entries: [String: Entry] = [:]
        for (key, record) in records {
            let mac = HMAC<SHA256>.authenticationCode(for: macInput(key: key, record: record), using: sealKey)
            entries[key] = Entry(record: record, mac: hex(Data(mac)))
        }
        return (try? encoder.encode(File(v: version, seal: sealID(sealKey), records: entries))) ?? Data()
    }

    /// Names a seal key without giving it away: hex HMAC-SHA256 of `"hook-review-seal-v1"` under it.
    public static func sealID(_ sealKey: SymmetricKey) -> String {
        hex(Data(HMAC<SHA256>.authenticationCode(for: Data("hook-review-seal-v1".utf8), using: sealKey)))
    }

    /// The seal the file names; nil without a file, or one that isn't a review file or names none.
    public static func sealMarker(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data), file.v == version else { return nil }
        return file.seal
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

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
        var seal: String?
        var records: [String: Entry]
    }

    private struct Entry: Codable {
        var record: ReviewRecord
        var mac: String
    }
}

/// The review store's seal key: 32 random bytes in the Keychain item "Hook review seal".
///
/// The Keychain can't say who made an item (an access list names an app by a path another app
/// can name too), so Hook trusts only the seal it made itself: at the first creation it adds a
/// fresh item and writes `reviews.json` naming it (`ReviewStore.sealID`). An item the marker
/// doesn't name is `.foreign`, and so is any item while the marker is missing: losing
/// `reviews.json` locks the records rather than resetting them. Only the owner's reset
/// (`create`) replaces an item that is there.
public enum ReviewSeal {
    /// Hook's seal key; nil when Hook hasn't made one (no marker in `file`, or no item). A read
    /// the Keychain refuses throws `.unreadable`; an item the marker doesn't name, or that another
    /// app can read, throws `.foreign`.
    public static func load(_ secrets: any SecretStore, file: URL) throws -> SymmetricKey? {
        guard let marker = ReviewStore.sealMarker(at: file), let data = try secrets.read(.reviewSeal) else { return nil }
        let key = SymmetricKey(data: data)
        guard data.count == 32, ReviewStore.sealID(key) == marker else { throw SecretStoreError.foreign }
        return key
    }

    /// `load`, or else the first creation: a fresh item and a `file` with no records that names
    /// it, only when there is no item at all. A refused read, a `.foreign` item, or any item
    /// while the marker is missing never mints a new key over the old one.
    public static func loadOrCreate(_ secrets: any SecretStore, file: URL) throws -> SymmetricKey {
        try open(secrets, file: file).key
    }

    /// `loadOrCreate`, saying whether this call made the key.
    public static func open(_ secrets: any SecretStore, file: URL) throws -> (key: SymmetricKey, created: Bool) {
        if let key = try load(secrets, file: file) { return (key, false) }
        // With no marker, `load` didn't look: an item there, even one that can't be read, isn't
        // known to be Hook's, and replacing it would erase every acceptance and pin unasked.
        if ReviewStore.sealMarker(at: file) == nil, itemExists(secrets) { throw SecretStoreError.foreign }
        return (try make(secrets, file: file, replacing: false), true)
    }

    /// The owner's explicit reset: a fresh seal item and a `file` with no records that names
    /// it. Every record and every owner key marked under the old seal stops verifying.
    /// Data-protection storage refuses this reset while the existing seal cannot be read;
    /// `open` uses add-only creation on a first launch instead.
    @discardableResult
    public static func create(_ secrets: any SecretStore, file: URL) throws -> SymmetricKey {
        try make(secrets, file: file, replacing: true)
    }

    private static func make(_ secrets: any SecretStore, file: URL, replacing: Bool) throws -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SecretStoreError.writeFailed(errSecAllocate)
        }
        let key = SymmetricKey(data: bytes)
        if replacing {
            try secrets.replace(.reviewSeal, Data(bytes))
        } else {
            try secrets.create(.reviewSeal, Data(bytes))
        }
        try PrivateFile.write(ReviewStore.sealed(records: [:], sealKey: key), to: file)
        return key
    }

    /// Whether a seal item is there: one the Keychain refuses, or another app's, counts.
    private static func itemExists(_ secrets: any SecretStore) -> Bool {
        do { return try secrets.read(.reviewSeal) != nil } catch { return true }
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
