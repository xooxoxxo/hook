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

    /// Where the key may go: https, or plain http only to this Mac itself (127.0.0.1, ::1,
    /// localhost). Anything else could be read on the way.
    public static func mayCarry(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https"?: return true
        case "http"?: return ["127.0.0.1", "::1", "[::1]", "localhost"].contains((url.host(percentEncoded: false) ?? "").lowercased())
        default: return false
        }
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
    /// The Pond URL's scheme when the key was set up (`https`, or `http` to this Mac itself): the
    /// key goes to no other. nil names none.
    public var scheme: String?
    /// Hook's creation marker (`OwnerKeyVault.mark`): set on every write, checked on every read.
    public var mark: String?

    public init(v: Int = 1, key: String, enrollID: String? = nil, status: Status, scheme: String? = nil,
                mark: String? = nil) {
        self.v = v; self.key = key; self.enrollID = enrollID; self.status = status; self.scheme = scheme
        self.mark = mark
    }
}

/// Reads and writes this Mac's owner key record for one Pond.
///
/// The Keychain can't say who made an item (an access list names an app by a path another
/// app can name too), so Hook marks each record it writes: `mark` is an HMAC of the Pond and
/// the key under the review seal, which only Hook can read. A record without a mark that
/// verifies, planted or copied from another Pond's item, is `.foreign`: never sent.
public enum OwnerKeyVault {
    /// The key, only while the record says approved and carries Hook's mark, and only for `url`
    /// (the Pond's) when it may carry the key and has the scheme the key was set up on. Pending,
    /// refused, unreadable, unmarked, malformed, missing, or another scheme → nil, so an owner act
    /// then goes without a key.
    public static func approvedKey(_ store: any SecretStore, sourceKey: String, url: URL, seal: SymmetricKey?) -> String? {
        guard OwnerKey.mayCarry(url), let record = try? record(store, sourceKey: sourceKey, seal: seal),
              record.status == .approved, let scheme = record.scheme, scheme == url.scheme?.lowercased() else {
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
    /// The record is being read: the Keychain may be waiting on its password prompt.
    case reading
    /// Waiting for the owner's tap on Telegram; `code` is the one the request repeats.
    case waiting(id: String, code: String)
    case approved
    /// Approved, but for another scheme than the Pond URL's now: Hook doesn't send it there
    /// (`OwnerKeyVault.approvedKey`). The text says so.
    case notUsedHere(String)
    /// Why this Mac has no key the Pond accepts.
    case refused(String)
    /// The Keychain refused a read or a write.
    case unavailable(String)
}

/// Setting up, checking and losing this Mac's owner key for the connected Pond. Settings
/// drives it through `SettingsViewModel`; the Store reports a refused key.
///
/// Every Keychain call runs on `KeychainQueue`, never on the main actor: a prompt after an
/// update holds only the flow (`.reading`), not the app. Each call that changes the item
/// returns the task doing it.
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
    public nonisolated static let needsHTTPS = "The owner key needs a Pond URL that starts with https."
    public nonisolated static let expired = "The request expired before it was approved."
    /// While the record is read (`.reading`).
    public nonisolated static let readingKeychain = "Waiting for Keychain access"

    /// An approved key the Pond URL's scheme doesn't take (`scheme` is the one it was set up on).
    public nonisolated static func notUsedHere(scheme: String?) -> String {
        guard let scheme else { return "Hook doesn't send this Mac's key to this address." }
        return "This Mac's key was approved for the Pond's \(scheme) address. Hook doesn't send it to this one."
    }

    public private(set) var state: OwnerKeyState = .notSetUp { didSet { if state != oldValue { onChange?() } } }
    /// The last `GET /owner`; nil until read, or for a source without the owner key.
    public private(set) var status: OwnerStatus? { didSet { if status != oldValue { onChange?() } } }
    /// Turning the requirement off waits for the owner's tap on Telegram.
    public private(set) var requireOffPending = false { didSet { if requireOffPending != oldValue { onChange?() } } }
    /// Why the last requirement change failed, as one line.
    public private(set) var requireProblem: String? { didSet { if requireProblem != oldValue { onChange?() } } }
    public var onChange: (@MainActor () -> Void)?
    /// A setup asked for while the record was read (`setUpAfterRead`), now that it reads as
    /// not approved: the app opens Settings › Queue and sets up.
    public var onSetUpAfterRead: (@MainActor () -> Void)?
    private var setUpWanted = false

    private let secrets: any SecretStore
    /// The review seal that marks this Mac's records (`OwnerKeyVault`); nil before Hook made one.
    private let seal: @Sendable () throws -> SymmetricKey?
    private let label: String
    private let sleep: @Sendable (Duration) async throws -> Void
    private let generate: @Sendable () -> String
    /// Where the flow's Keychain calls run.
    private let keychain: KeychainQueue
    /// The Pond attached (`SourceKey`); nil outside mailbox mode.
    public private(set) var sourceKey: String?
    /// Its URL, whose scheme a new key is bound to.
    private var url: URL?
    private var source: (any QueueSource)?
    /// The read, setup or poll in flight; a second one waits for it to end.
    private var task: Task<Void, Never>?
    /// The last change to the item that runs apart from `task` (a cancel's delete, a refusal),
    /// so a setup after it never races it.
    private var cleanup: Task<Void, Never>?
    /// The record as this flow last read or wrote it for `sourceKey`; a new URL for the same
    /// Pond is judged from it, without another Keychain read.
    private var lastRecord: OwnerKeyRecord?

    public init(secrets: any SecretStore, seal: @escaping @Sendable () throws -> SymmetricKey?, label: String,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                generate: @escaping @Sendable () -> String = OwnerKey.generate,
                keychain: KeychainQueue = .shared) {
        self.secrets = secrets
        self.keychain = keychain
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

    /// The provider `MailboxClient` reads on each owner act to the Pond at `url`: no seal, no
    /// key. It reads the Keychain on `KeychainQueue`.
    public nonisolated static func provider(_ secrets: any SecretStore, sourceKey: String, url: URL,
                                            seal: @escaping @Sendable () throws -> SymmetricKey?,
                                            keychain: KeychainQueue = .shared) -> @Sendable () async -> String? {
        {
            await keychain.run {
                OwnerKeyVault.approvedKey(secrets, sourceKey: sourceKey, url: url, seal: (try? seal()) ?? nil)
            }
        }
    }

    /// The flow says approved for this Pond at this URL: what the provider would send a key
    /// to, read from the flow's state, so the main actor never waits on the Keychain for it.
    public func isApproved(sourceKey: String, url: URL?) -> Bool {
        state == .approved && self.sourceKey == sourceKey && self.url == url
    }

    /// While the record is being read: remember that a setup is wanted (a report's Send held
    /// for the key) and return true; `onSetUpAfterRead` runs once the read ends, unless the key
    /// reads as approved (the held note then goes on its own). False when not reading: the
    /// caller sets up now.
    public func setUpAfterRead() -> Bool {
        guard state == .reading else { return false }
        setUpWanted = true
        return true
    }

    /// Require is offered only once two Macs are approved, this one among them, so turning it
    /// on never locks the owner out of answering from the other Mac.
    public var canRequireOwnerKey: Bool {
        guard let status, status.self_?.status == "approved" else { return false }
        return status.keys.filter { $0.status == "approved" }.count >= 2
    }

    /// The connected Pond (nil outside mailbox mode) and its URL. A new one stops any setup in
    /// flight and reads its record (`.reading` until the Keychain answers); a pending request
    /// is polled again. The returned task ends once the record is read (and a pending
    /// request's poll is over).
    @discardableResult
    public func attach(sourceKey: String?, url: URL?, source: (any QueueSource)?) -> Task<Void, Never>? {
        let urlChanged = url != self.url
        self.url = url
        guard sourceKey != self.sourceKey else {
            self.source = source
            // The same Pond on another scheme: an approved key may no longer go to it, or again.
            if urlChanged, task == nil, sourceKey != nil, Self.followsURL(state) { stateForURL() }
            return nil
        }
        task?.cancel()
        task = nil
        self.sourceKey = sourceKey
        self.source = source
        status = nil
        requireOffPending = false
        requireProblem = nil
        lastRecord = nil
        guard let sourceKey else {
            state = .notSetUp
            return nil
        }
        state = .reading
        let task = Task { await self.read(sourceKey) }
        self.task = task
        return task
    }

    /// `attach`'s read: the record's state, and a pending request polled again.
    private func read(_ sourceKey: String) async {
        await cleanup?.value
        let record: OwnerKeyRecord?
        do {
            record = try await ownRecord(sourceKey)
        } catch {
            guard current(sourceKey) else { return }
            state = .unavailable(Self.readFailed)
            task = nil
            askForSetUpIfWanted()
            return
        }
        guard current(sourceKey) else { return }
        lastRecord = record
        defer { askForSetUpIfWanted() }
        switch record?.status {
        case nil: state = .notSetUp
        case .approved?:
            state = record.map(approvedState) ?? .notSetUp
            // `GET /owner` may have answered while the read waited: the check `refresh` skipped.
            if state == .approved, let status, status.self_?.status != "approved" {
                await refuse(sourceKey: sourceKey)
            }
        case .refused?: state = .refused(Self.noLongerAccepted)
        case .pending?:
            guard let record, let id = record.enrollID else {
                state = .notSetUp       // the enroll call never answered: nothing is waiting
                break
            }
            state = .waiting(id: id, code: OwnerKey.enrollCode(id: id, keyHash: OwnerKey.hash(record.key)))
            await poll(id: id, sourceKey: sourceKey)
            return
        }
        if current(sourceKey) { task = nil }
    }

    /// Set up: the key and a pending record go to the Keychain first, in a fresh item (any item
    /// already there is deleted, never filled), then the Pond gets its hash; the returned task
    /// polls until the owner answers on Telegram (or 10 minutes pass). A Keychain that refuses
    /// the read gets nothing new: the old item stays. The key is bound to the Pond URL's scheme,
    /// and only a URL that may carry it (`OwnerKey.mayCarry`) gets one.
    @discardableResult
    public func setUp() -> Task<Void, Never>? {
        guard let sourceKey, let source, task == nil else { return nil }
        switch state {
        case .waiting, .approved, .reading: return nil
        case .notSetUp, .notUsedHere, .refused, .unavailable: break
        }
        guard let url, OwnerKey.mayCarry(url), let scheme = url.scheme?.lowercased() else {
            state = .refused(Self.needsHTTPS)
            return nil
        }
        let label = self.label
        let task = Task {
            await self.cleanup?.value
            do {
                if let record = try await self.ownRecord(sourceKey), record.status == .approved, record.scheme == scheme {
                    guard self.current(sourceKey) else { return }
                    self.lastRecord = record
                    self.state = .approved
                    self.task = nil
                    return
                }
            } catch {
                guard self.current(sourceKey) else { return }
                self.state = .unavailable(Self.readFailed)
                self.task = nil
                return
            }
            guard self.current(sourceKey) else { return }
            let key = self.generate()
            do {
                try await self.marked { secrets, seal in
                    try OwnerKeyVault.create(OwnerKeyRecord(key: key, status: .pending, scheme: scheme), secrets,
                                             sourceKey: sourceKey, seal: seal)
                }
            } catch {
                guard self.current(sourceKey) else { return }
                self.state = .unavailable(Self.saveFailed)
                self.task = nil
                return
            }
            guard self.current(sourceKey) else { return }
            self.lastRecord = OwnerKeyRecord(key: key, status: .pending, scheme: scheme)
            let hash = OwnerKey.hash(key)
            let enrollment: Enrollment
            do {
                enrollment = try await source.enroll(keyHash: hash, label: label)
            } catch {
                guard self.current(sourceKey) else { return }
                await self.drop(sourceKey: sourceKey)
                self.state = .refused("Couldn't start the setup: " + UserFacingError.text(error))
                self.task = nil
                return
            }
            guard self.current(sourceKey) else { return }
            do {
                try await self.marked { secrets, seal in
                    try OwnerKeyVault.save(OwnerKeyRecord(key: key, enrollID: enrollment.id, status: .pending, scheme: scheme),
                                           secrets, sourceKey: sourceKey, seal: seal)
                }
            } catch {
                guard self.current(sourceKey) else { return }
                self.state = .unavailable(Self.saveFailed)
                self.task = nil
                return
            }
            guard self.current(sourceKey) else { return }
            self.lastRecord = OwnerKeyRecord(key: key, enrollID: enrollment.id, status: .pending, scheme: scheme)
            self.state = .waiting(id: enrollment.id, code: OwnerKey.enrollCode(id: enrollment.id, keyHash: hash))
            await self.poll(id: enrollment.id, sourceKey: sourceKey)
        }
        self.task = task
        return task
    }

    /// Stops waiting and forgets the pending key; the returned task ends once it is gone. The
    /// Pond's request expires on its own.
    @discardableResult
    public func cancelSetup() -> Task<Void, Never>? {
        guard case .waiting = state, let sourceKey else { return nil }
        task?.cancel()
        task = nil
        lastRecord = nil
        state = .notSetUp
        return afterCleanup { await $0.drop(sourceKey: sourceKey) }
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
            await self.refuse(sourceKey: sourceKey)
        }
    }

    /// The record read again, as `attach` reads it: after the review seal changed (Reset Review
    /// Records…), a record marked under the old one reads as not set up.
    @discardableResult
    public func reread() -> Task<Void, Never>? {
        let current = sourceKey
        sourceKey = nil
        return attach(sourceKey: current, url: url, source: source)
    }

    /// An owner act got 403 "unknown owner key": the next one goes without a key.
    @discardableResult
    public func keyRefused() -> Task<Void, Never>? {
        guard let sourceKey, state == .approved else { return nil }
        return afterCleanup { await $0.refuse(sourceKey: sourceKey) }
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
                await self.refuse(sourceKey: sourceKey)
            } catch {
                guard self.sourceKey == sourceKey else { return }
                self.requireProblem = UserFacingError.text(error)
            }
        }
    }

    // MARK: -

    /// The read ended: a setup asked for meanwhile starts now, unless the key is approved or
    /// a request is already waiting.
    private func askForSetUpIfWanted() {
        guard setUpWanted else { return }
        setUpWanted = false
        switch state {
        case .approved, .waiting, .reading: return
        case .notSetUp, .notUsedHere, .refused, .unavailable: onSetUpAfterRead?()
        }
    }

    /// The same Pond is still attached and this task wasn't stopped.
    private func current(_ sourceKey: String) -> Bool {
        !Task.isCancelled && self.sourceKey == sourceKey
    }

    /// `work` after the last cleanup, kept as the new last one.
    private func afterCleanup(_ work: @escaping @MainActor (OwnerKeyFlow) async -> Void) -> Task<Void, Never> {
        let previous = cleanup
        let next = Task { @MainActor in
            await previous?.value
            await work(self)
        }
        cleanup = next
        return next
    }

    private func poll(id: String, sourceKey: String) async {
        let rounds = Int(Self.pollLimit / Self.pollInterval)
        for _ in 0..<rounds {
            do { try await sleep(Self.pollInterval) } catch { return }
            guard current(sourceKey), let source else { return }
            guard let enrollment = try? await source.enrollment(id) else { continue }
            guard current(sourceKey) else { return }
            switch enrollment.status {
            case "approved"?:
                do {
                    guard let record = try await ownRecord(sourceKey) else {
                        guard current(sourceKey) else { return }
                        state = .refused(Self.noLongerAccepted)
                        task = nil
                        return
                    }
                    var approved = record
                    approved.status = .approved
                    let saved = approved
                    try await marked { secrets, seal in try OwnerKeyVault.save(saved, secrets, sourceKey: sourceKey, seal: seal) }
                    guard current(sourceKey) else { return }
                    lastRecord = approved
                    state = approvedState(approved)
                } catch {
                    guard current(sourceKey) else { return }
                    state = .unavailable(Self.saveFailed)
                }
                task = nil
                refresh()
                return
            case "rejected"?:
                await finish(sourceKey: sourceKey, reason: Self.declined)
                return
            case "expired"?:
                await finish(sourceKey: sourceKey, reason: Self.expired)
                return
            default:
                continue
            }
        }
        guard current(sourceKey) else { return }
        await finish(sourceKey: sourceKey, reason: Self.expired)
    }

    /// An approved record's state for the URL attached now: `.approved` only where
    /// `OwnerKeyVault.approvedKey` would send it.
    private func approvedState(_ record: OwnerKeyRecord) -> OwnerKeyState {
        guard let url, OwnerKey.mayCarry(url), let scheme = record.scheme, scheme == url.scheme?.lowercased() else {
            return .notUsedHere(Self.notUsedHere(scheme: record.scheme))
        }
        return .approved
    }

    /// The states a new URL for the same Pond can change: an approved key, one not used on the
    /// old URL, or a setup the old URL refused.
    private nonisolated static func followsURL(_ state: OwnerKeyState) -> Bool {
        switch state {
        case .approved, .notUsedHere: return true
        case .refused(let reason): return reason == needsHTTPS
        case .notSetUp, .reading, .waiting, .unavailable: return false
        }
    }

    /// The state for the URL attached now (`followsURL` states only), from the record as the
    /// flow last saw it.
    private func stateForURL() {
        switch lastRecord?.status {
        case nil: state = .notSetUp
        case .approved?: state = lastRecord.map(approvedState) ?? .notSetUp
        case .refused?: state = .refused(Self.noLongerAccepted)
        case .pending?: break
        }
    }

    private func finish(sourceKey: String, reason: String) async {
        await drop(sourceKey: sourceKey)
        guard self.sourceKey == sourceKey else { return }
        lastRecord = nil
        state = .refused(reason)
        task = nil
    }

    /// The Pond turned the key down: the record becomes refused. A read the Keychain refuses
    /// leaves the item in place and only gives `.unavailable`, since the provider sends no key
    /// then and the Pond's answer says nothing about it.
    private func refuse(sourceKey: String) async {
        let secrets = self.secrets, seal = self.seal
        let read = await keychain.run { () -> Bool in
            do {
                if let record = try Self.ownRecord(secrets, seal: seal, sourceKey: sourceKey) {
                    Self.markRefused(record, secrets, seal: seal, sourceKey: sourceKey)
                }
                return true
            } catch {
                return false
            }
        }
        guard self.sourceKey == sourceKey else { return }
        if read { lastRecord = nil }
        state = read ? .refused(Self.noLongerAccepted) : .unavailable(Self.readFailed)
    }

    /// Deletes the record; when the delete fails, marks it refused so the provider still gives nil.
    /// A read the Keychain refuses changes nothing: the provider already gives nil then.
    private func drop(sourceKey: String) async {
        let secrets = self.secrets, seal = self.seal
        await keychain.run {
            do {
                try OwnerKeyVault.delete(secrets, sourceKey: sourceKey)
            } catch {
                guard let record = try? Self.ownRecord(secrets, seal: seal, sourceKey: sourceKey) else { return }
                Self.markRefused(record, secrets, seal: seal, sourceKey: sourceKey)
            }
        }
    }

    /// Rewrites a record that read fine as refused; when that write fails, deletes it. Either way
    /// the provider gives nil. Runs on the Keychain queue.
    private nonisolated static func markRefused(_ record: OwnerKeyRecord, _ secrets: any SecretStore,
                                                seal: @Sendable () throws -> SymmetricKey?, sourceKey: String) {
        var refused = record
        refused.status = .refused
        do {
            try OwnerKeyVault.save(refused, secrets, sourceKey: sourceKey, seal: markingSeal(seal))
        } catch {
            try? OwnerKeyVault.delete(secrets, sourceKey: sourceKey)
        }
    }

    /// This Mac's record, verified, read on the Keychain queue. One Hook didn't make
    /// (`.foreign`) is no record: it is never sent, and setting up replaces it. A refused
    /// Keychain or seal read throws.
    private func ownRecord(_ sourceKey: String) async throws -> OwnerKeyRecord? {
        let secrets = self.secrets, seal = self.seal
        return try await keychain.run { try Self.ownRecord(secrets, seal: seal, sourceKey: sourceKey) }
    }

    private nonisolated static func ownRecord(_ secrets: any SecretStore, seal: @Sendable () throws -> SymmetricKey?,
                                              sourceKey: String) throws -> OwnerKeyRecord? {
        let seal = try seal()
        do {
            return try OwnerKeyVault.record(secrets, sourceKey: sourceKey, seal: seal)
        } catch SecretStoreError.foreign {
            return nil
        }
    }

    /// A write marked with the seal, on the Keychain queue; without a seal nothing is written.
    private func marked(_ write: @escaping @Sendable (any SecretStore, SymmetricKey) throws -> Void) async throws {
        let secrets = self.secrets, seal = self.seal
        try await keychain.run { try write(secrets, OwnerKeyFlow.markingSeal(seal)) }
    }

    /// The seal a write marks with; without one nothing is written.
    private nonisolated static func markingSeal(_ seal: @Sendable () throws -> SymmetricKey?) throws -> SymmetricKey {
        guard let seal = try seal() else { throw SecretStoreError.writeFailed(errSecItemNotFound) }
        return seal
    }
}
