import CryptoKit
import Foundation
import Security

/// This Mac's owner key (Pond 1.1.0): 32 random bytes, sent as `X-Hook-Owner-Key` on owner
/// acts once the owner approved this Mac on Telegram. The Pond stores only its SHA-256.
public enum OwnerKey {
    /// 32 bytes from `SecRandomCopyBytes`, base64url without padding: 43 characters.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase hex SHA-256 of the key's UTF-8, as the Pond stores it.
    public static func hash(_ key: String) -> String {
        hex(SHA256.hash(data: Data(key.utf8)))
    }

    /// The 6-digit code Hook shows and the Telegram request repeats:
    /// `int(sha256("hook-enroll-v1\n" + id + "\n" + keyHash)[:12], 16) % 1_000_000`, zero-padded.
    public static func enrollCode(id: String, keyHash: String) -> String {
        let digest = hex(SHA256.hash(data: Data(("hook-enroll-v1\n" + id + "\n" + keyHash).utf8)))
        let value = UInt64(digest.prefix(12), radix: 16) ?? 0
        let code = String(value % 1_000_000)
        return String(repeating: "0", count: 6 - code.count) + code
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The Keychain item's data: the key and its enrollment state are one item, so the key is
/// never sent before the Pond approved it.
public struct OwnerKeyRecord: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, approved, refused
    }

    public var v: Int
    public var key: String
    public var enrollID: String?
    public var status: Status
    /// Hook's creation marker (`OwnerKeyVault.mark`): set on every write, checked on every read.
    public var mark: String?

    public init(v: Int = 1, key: String, enrollID: String? = nil, status: Status, mark: String? = nil) {
        self.v = v; self.key = key; self.enrollID = enrollID; self.status = status; self.mark = mark
    }
}

/// Reads and writes this Mac's owner key record for one Pond.
///
/// The Keychain can't say who made an item (an access list names an app by a path another
/// app can name too), so Hook marks each record it writes: `mark` is an HMAC of the Pond and
/// the key under the review seal, which only Hook can read. A record without a mark that
/// verifies, planted or copied from another Pond's item, is `.foreign`: never sent.
public enum OwnerKeyVault {
    /// The key, only while the record says approved and carries Hook's mark. Pending, refused,
    /// unreadable, unmarked, malformed or missing → nil, so an owner act then goes without a key.
    public static func approvedKey(_ store: any SecretStore, sourceKey: String, seal: SymmetricKey?) -> String? {
        guard let record = try? record(store, sourceKey: sourceKey, seal: seal), record.status == .approved else {
            return nil
        }
        return record.key
    }

    /// nil when there is no item or its data isn't a record; throws when the Keychain refuses,
    /// and `.foreign` for a record whose mark doesn't verify under `seal` (or with no seal).
    public static func record(_ store: any SecretStore, sourceKey: String, seal: SymmetricKey?) throws -> OwnerKeyRecord? {
        guard let data = try store.read(.ownerKey(sourceKey: sourceKey)),
              let record = try? JSONDecoder().decode(OwnerKeyRecord.self, from: data) else { return nil }
        guard let seal, let mark = record.mark.flatMap({ Data(hex: $0) }),
              HMAC<SHA256>.isValidAuthenticationCode(mark, authenticating: markInput(key: record.key, sourceKey: sourceKey),
                                                     using: seal) else {
            throw SecretStoreError.foreign
        }
        return record
    }

    /// Hex HMAC-SHA256 under the seal of `"hook-owner-key-v1\n" + sourceKey + "\n" + key`.
    public static func mark(key: String, sourceKey: String, seal: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: markInput(key: key, sourceKey: sourceKey), using: seal))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Rewrites Hook's own item (a new status, the enroll id), marked.
    public static func save(_ record: OwnerKeyRecord, _ store: any SecretStore, sourceKey: String,
                            seal: SymmetricKey) throws {
        try store.write(.ownerKey(sourceKey: sourceKey), encode(record, sourceKey: sourceKey, seal: seal))
    }

    /// A new key: whatever item is there, Hook's or planted, is deleted and a fresh one added, marked.
    public static func create(_ record: OwnerKeyRecord, _ store: any SecretStore, sourceKey: String,
                              seal: SymmetricKey) throws {
        try store.create(.ownerKey(sourceKey: sourceKey), encode(record, sourceKey: sourceKey, seal: seal))
    }

    private static func markInput(key: String, sourceKey: String) -> Data {
        Data(("hook-owner-key-v1\n" + sourceKey + "\n" + key).utf8)
    }

    private static func encode(_ record: OwnerKeyRecord, sourceKey: String, seal: SymmetricKey) throws -> Data {
        var marked = record
        marked.mark = mark(key: record.key, sourceKey: sourceKey, seal: seal)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(marked)
    }

    public static func delete(_ store: any SecretStore, sourceKey: String) throws {
        try store.delete(.ownerKey(sourceKey: sourceKey))
    }
}

/// What Settings › Queue shows for this Mac's owner key.
public enum OwnerKeyState: Equatable, Sendable {
    case notSetUp
    /// Waiting for the owner's tap on Telegram; `code` is the one the request repeats.
    case waiting(id: String, code: String)
    case approved
    /// Why this Mac has no key the Pond accepts.
    case refused(String)
    /// The Keychain refused a read or a write.
    case unavailable(String)
}

/// Setting up, checking and losing this Mac's owner key for the connected Pond. Settings
/// drives it through `SettingsViewModel`; the Store reports a refused key.
@MainActor public final class OwnerKeyFlow {
    public nonisolated static let pollInterval: Duration = .seconds(3)
    public nonisolated static let pollLimit: Duration = .seconds(600)
    /// The Pond's limit for a key's label.
    public nonisolated static let maxLabel = 40

    public nonisolated static let saveFailed = "Hook couldn't save its key in the Keychain."
    public nonisolated static let readFailed =
        "Hook couldn't read its key from the Keychain. Allow Hook when macOS asks, or set it up again."
    public nonisolated static let noLongerAccepted = "The Pond no longer accepts this Mac's key."
    public nonisolated static let declined = "The request was turned down on Telegram."
    public nonisolated static let expired = "The request expired before it was approved."

    public private(set) var state: OwnerKeyState = .notSetUp { didSet { if state != oldValue { onChange?() } } }
    /// The last `GET /owner`; nil until read, or for a source without the owner key.
    public private(set) var status: OwnerStatus? { didSet { if status != oldValue { onChange?() } } }
    /// Turning the requirement off waits for the owner's tap on Telegram.
    public private(set) var requireOffPending = false { didSet { if requireOffPending != oldValue { onChange?() } } }
    /// Why the last requirement change failed, as one line.
    public private(set) var requireProblem: String? { didSet { if requireProblem != oldValue { onChange?() } } }
    public var onChange: (@MainActor () -> Void)?

    private let secrets: any SecretStore
    /// The review seal that marks this Mac's records (`OwnerKeyVault`); nil before Hook made one.
    private let seal: @Sendable () throws -> SymmetricKey?
    private let label: String
    private let sleep: @Sendable (Duration) async throws -> Void
    private let generate: @Sendable () -> String
    /// The Pond attached (`SourceKey`); nil outside mailbox mode.
    public private(set) var sourceKey: String?
    private var source: (any QueueSource)?
    private var task: Task<Void, Never>?

    public init(secrets: any SecretStore, seal: @escaping @Sendable () throws -> SymmetricKey?, label: String,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                generate: @escaping @Sendable () -> String = OwnerKey.generate) {
        self.secrets = secrets
        self.seal = seal
        self.label = Self.label(from: label)
        self.sleep = sleep
        self.generate = generate
    }

    /// The host name as a key label: hidden characters and line breaks dropped, trimmed, cut
    /// to 40 characters; "Mac" when nothing is left.
    public nonisolated static func label(from name: String) -> String {
        let kept = String(String.UnicodeScalarView(name.unicodeScalars.filter {
            !Sanitize.isHidden($0, as: .prose) && $0 != "\n" && $0 != "\t"
        })).trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? "Mac" : String(kept.prefix(maxLabel))
    }

    /// The provider `MailboxClient` reads on each owner act: no seal, no key.
    public nonisolated static func provider(_ secrets: any SecretStore, sourceKey: String,
                                            seal: @escaping @Sendable () throws -> SymmetricKey?) -> @Sendable () -> String? {
        { OwnerKeyVault.approvedKey(secrets, sourceKey: sourceKey, seal: (try? seal()) ?? nil) }
    }

    /// Require is offered only once two Macs are approved, this one among them, so turning it
    /// on never locks the owner out of answering from the other Mac.
    public var canRequireOwnerKey: Bool {
        guard let status, status.self_?.status == "approved" else { return false }
        return status.keys.filter { $0.status == "approved" }.count >= 2
    }

    /// The connected Pond (nil outside mailbox mode). A new one stops any setup in flight and
    /// reads its record; a pending request is polled again.
    @discardableResult
    public func attach(sourceKey: String?, source: (any QueueSource)?) -> Task<Void, Never>? {
        guard sourceKey != self.sourceKey else {
            self.source = source
            return nil
        }
        task?.cancel()
        task = nil
        self.sourceKey = sourceKey
        self.source = source
        status = nil
        requireOffPending = false
        requireProblem = nil
        guard let sourceKey else {
            state = .notSetUp
            return nil
        }
        let record: OwnerKeyRecord?
        do {
            record = try ownRecord(sourceKey)
        } catch {
            state = .unavailable(Self.readFailed)
            return nil
        }
        switch record?.status {
        case nil: state = .notSetUp
        case .approved?: state = .approved
        case .refused?: state = .refused(Self.noLongerAccepted)
        case .pending?:
            guard let record, let id = record.enrollID else {
                state = .notSetUp       // the enroll call never answered: nothing is waiting
                return nil
            }
            state = .waiting(id: id, code: OwnerKey.enrollCode(id: id, keyHash: OwnerKey.hash(record.key)))
            let task = Task { await self.poll(id: id, sourceKey: sourceKey) }
            self.task = task
            return task
        }
        return nil
    }

    /// Set up: the key and a pending record go to the Keychain first, in a fresh item (any item
    /// already there is deleted, never filled), then the Pond gets its hash; the returned task
    /// polls until the owner answers on Telegram (or 10 minutes pass). A Keychain that refuses
    /// the read gets nothing new: the old item stays.
    @discardableResult
    public func setUp() -> Task<Void, Never>? {
        guard let sourceKey, let source, task == nil else { return nil }
        switch state {
        case .waiting, .approved: return nil
        case .notSetUp, .refused, .unavailable: break
        }
        do {
            if try ownRecord(sourceKey)?.status == .approved {
                state = .approved
                return nil
            }
        } catch {
            state = .unavailable(Self.readFailed)
            return nil
        }
        let key = generate()
        do {
            try OwnerKeyVault.create(OwnerKeyRecord(key: key, status: .pending), secrets, sourceKey: sourceKey,
                                     seal: markingSeal())
        } catch {
            state = .unavailable(Self.saveFailed)
            return nil
        }
        let label = self.label
        let task = Task {
            let hash = OwnerKey.hash(key)
            let enrollment: Enrollment
            do {
                enrollment = try await source.enroll(keyHash: hash, label: label)
            } catch {
                guard !Task.isCancelled, self.sourceKey == sourceKey else { return }
                self.drop(sourceKey: sourceKey)
                self.state = .refused("Couldn't start the setup: " + UserFacingError.text(error))
                self.task = nil
                return
            }
            guard !Task.isCancelled, self.sourceKey == sourceKey else { return }
            do {
                try OwnerKeyVault.save(OwnerKeyRecord(key: key, enrollID: enrollment.id, status: .pending), self.secrets,
                                       sourceKey: sourceKey, seal: self.markingSeal())
            } catch {
                self.state = .unavailable(Self.saveFailed)
                self.task = nil
                return
            }
            self.state = .waiting(id: enrollment.id, code: OwnerKey.enrollCode(id: enrollment.id, keyHash: hash))
            await self.poll(id: enrollment.id, sourceKey: sourceKey)
        }
        self.task = task
        return task
    }

    /// Stops waiting and forgets the pending key. The Pond's request expires on its own.
    public func cancelSetup() {
        guard case .waiting = state, let sourceKey else { return }
        task?.cancel()
        task = nil
        drop(sourceKey: sourceKey)
        state = .notSetUp
    }

    /// `GET /owner`, on launch and each time Settings opens. An approved record whose key the
    /// Pond no longer lists as approved (revoked, rejected, or unknown) becomes refused, but only
    /// when the record still reads: a Keychain that refuses the read sent no key, so the Pond's
    /// `self: null` says nothing about it.
    @discardableResult
    public func refresh() -> Task<Void, Never>? {
        guard let source, let sourceKey else { return nil }
        return Task {
            guard let status = try? await source.ownerStatus(), self.sourceKey == sourceKey else { return }
            self.status = status
            if !status.required { self.requireOffPending = false }     // the owner tapped Turn off
            guard self.state == .approved, status.self_?.status != "approved" else { return }
            self.refuse(sourceKey: sourceKey)
        }
    }

    /// An owner act got 403 "unknown owner key": the next one goes without a key.
    public func keyRefused() {
        guard let sourceKey, state == .approved else { return }
        refuse(sourceKey: sourceKey)
    }

    /// On takes effect at once (when `canRequireOwnerKey`); off waits for the Telegram tap.
    @discardableResult
    public func requireOwnerKey(_ on: Bool) -> Task<Void, Never>? {
        guard let source, let sourceKey, state == .approved, status?.self_?.status == "approved" else { return nil }
        if on && !canRequireOwnerKey { return nil }
        requireProblem = nil
        return Task {
            do {
                let outcome = try await source.requireOwnerKey(on)
                guard self.sourceKey == sourceKey else { return }
                self.requireOffPending = outcome == .pending
                if outcome != .pending, var status = self.status {
                    status.required = outcome == .on
                    self.status = status
                }
            } catch QueueError.ownerKeyRefused {
                guard self.sourceKey == sourceKey else { return }
                self.refuse(sourceKey: sourceKey)
            } catch {
                guard self.sourceKey == sourceKey else { return }
                self.requireProblem = UserFacingError.text(error)
            }
        }
    }

    // MARK: -

    private func poll(id: String, sourceKey: String) async {
        let rounds = Int(Self.pollLimit / Self.pollInterval)
        for _ in 0..<rounds {
            do { try await sleep(Self.pollInterval) } catch { return }
            guard !Task.isCancelled, self.sourceKey == sourceKey, let source else { return }
            guard let enrollment = try? await source.enrollment(id) else { continue }
            guard !Task.isCancelled, self.sourceKey == sourceKey else { return }
            switch enrollment.status {
            case "approved"?:
                do {
                    guard let record = try ownRecord(sourceKey) else {
                        state = .refused(Self.noLongerAccepted)
                        task = nil
                        return
                    }
                    var approved = record
                    approved.status = .approved
                    try OwnerKeyVault.save(approved, secrets, sourceKey: sourceKey, seal: markingSeal())
                    state = .approved
                } catch {
                    state = .unavailable(Self.saveFailed)
                }
                task = nil
                refresh()
                return
            case "rejected"?:
                finish(sourceKey: sourceKey, reason: Self.declined)
                return
            case "expired"?:
                finish(sourceKey: sourceKey, reason: Self.expired)
                return
            default:
                continue
            }
        }
        guard !Task.isCancelled, self.sourceKey == sourceKey else { return }
        finish(sourceKey: sourceKey, reason: Self.expired)
    }

    private func finish(sourceKey: String, reason: String) {
        drop(sourceKey: sourceKey)
        state = .refused(reason)
        task = nil
    }

    /// The Pond turned the key down: the record becomes refused. A read the Keychain refuses
    /// leaves the item in place and only gives `.unavailable`, since the provider sends no key
    /// then and the Pond's answer says nothing about it.
    private func refuse(sourceKey: String) {
        let record: OwnerKeyRecord?
        do {
            record = try ownRecord(sourceKey)
        } catch {
            state = .unavailable(Self.readFailed)
            return
        }
        if let record { markRefused(record, sourceKey: sourceKey) }
        state = .refused(Self.noLongerAccepted)
    }

    /// Deletes the record; when the delete fails, marks it refused so the provider still gives nil.
    /// A read the Keychain refuses changes nothing: the provider already gives nil then.
    private func drop(sourceKey: String) {
        do {
            try OwnerKeyVault.delete(secrets, sourceKey: sourceKey)
        } catch {
            guard let record = try? ownRecord(sourceKey) else { return }
            markRefused(record, sourceKey: sourceKey)
        }
    }

    /// Rewrites a record that read fine as refused; when that write fails, deletes it. Either way
    /// the provider gives nil.
    private func markRefused(_ record: OwnerKeyRecord, sourceKey: String) {
        var refused = record
        refused.status = .refused
        do {
            try OwnerKeyVault.save(refused, secrets, sourceKey: sourceKey, seal: markingSeal())
        } catch {
            try? OwnerKeyVault.delete(secrets, sourceKey: sourceKey)
        }
    }

    /// This Mac's record, verified. One Hook didn't make (`.foreign`) is no record: it is never
    /// sent, and setting up replaces it. A refused Keychain or seal read throws.
    private func ownRecord(_ sourceKey: String) throws -> OwnerKeyRecord? {
        let seal = try seal()
        do {
            return try OwnerKeyVault.record(secrets, sourceKey: sourceKey, seal: seal)
        } catch SecretStoreError.foreign {
            return nil
        }
    }

    /// The seal a write marks with; without one nothing is written.
    private func markingSeal() throws -> SymmetricKey {
        guard let seal = try seal() else { throw SecretStoreError.writeFailed(errSecItemNotFound) }
        return seal
    }
}
