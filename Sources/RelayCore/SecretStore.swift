import Foundation
import Security

/// A Keychain item's service and account.
public struct SecretName: Hashable, Sendable {
    public var service: String
    public var account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// The phone's bearer token for one configured Pond (`SourceKey`).
    public static func pondToken(sourceKey: String) -> SecretName {
        SecretName(service: "io.github.xooxoxxo.relay.pond-token", account: sourceKey)
    }

    /// This device's owner key for one Pond (`SourceKey`), with its enrollment state.
    public static func ownerKey(sourceKey: String) -> SecretName {
        SecretName(service: "io.github.xooxoxxo.relay.owner-key", account: sourceKey)
    }

    /// The key that seals the review store.
    public static let reviewSeal = SecretName(service: "io.github.xooxoxxo.relay.review-seal", account: "default")


}

public enum SecretStoreError: Error, Equatable, Sendable {
    /// The item is there but couldn't be read: the owner refused the password prompt after
    /// an update (ad-hoc signing), the Keychain is locked, or interaction isn't allowed.
    /// Never treated as "no item": a refused read must not mint a new key over the old one.
    case unreadable(OSStatus)
    /// The item is there, but its access list lets an app other than Hook read it (or anyone
    /// at all): it may have been planted with a value its maker knows. Hook neither trusts
    /// nor updates it.
    case foreign
    case writeFailed(OSStatus)
    case deleteFailed(OSStatus)
}

/// Where Hook keeps its secrets. `read` is nil only when there is no item; an item Hook
/// didn't make for itself throws `.foreign` from both `read` and `write`.
public protocol SecretStore: Sendable {
    func read(_ name: SecretName) throws -> Data?
    /// Updates Hook's own item in place, or adds one when there is none; never replaces a
    /// foreign item.
    func write(_ name: SecretName, _ data: Data) throws
    /// Makes a fresh item. The Mac ACL store retains its legacy delete/add behavior;
    /// data-protection storage is add-only and fails if an item already exists.
    func create(_ name: SecretName, _ data: Data) throws
    /// Explicitly replaces a secret for enrollment/reset. Data-protection storage requires
    /// a successful read before deleting an existing item; unreadable items stay intact.
    func replace(_ name: SecretName, _ data: Data) throws
    /// Deleting a missing item is not an error.
    func delete(_ name: SecretName) throws
}

extension SecretStore {
    /// Preserve the Mac ACL store's established fresh-item behavior.
    public func replace(_ name: SecretName, _ data: Data) throws { try create(name, data) }
}

/// An in-memory store for tests and the gallery. Setting a `…Error` makes every matching
/// call throw it, as a refused or failing Keychain would; `holdReads()` makes every read wait,
/// as one behind a Keychain prompt nobody has answered does.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    /// The reads held by `holdReads()` wait on this, apart from `lock`.
    private let gate = NSCondition()
    private var held = false
    private var _waitingReads = 0
    private var items: [SecretName: Data] = [:]
    private var _readError: SecretStoreError?
    private var _writeError: SecretStoreError?
    private var _deleteError: SecretStoreError?
    private var _writes = 0
    private var _creates = 0
    private var foreign: Set<SecretName> = []

    public init(_ items: [SecretName: Data] = [:]) {
        self.items = items
    }

    public var readError: SecretStoreError? {
        get { locked { _readError } }
        set { locked { _readError = newValue } }
    }

    public var writeError: SecretStoreError? {
        get { locked { _writeError } }
        set { locked { _writeError = newValue } }
    }

    public var deleteError: SecretStoreError? {
        get { locked { _deleteError } }
        set { locked { _deleteError = newValue } }
    }

    /// Successful writes so far, `create` included.
    public var writes: Int { locked { _writes } }

    /// Successful `create` calls so far.
    public var creates: Int { locked { _creates } }

    /// An item another app made (any app may read it): `read` and `write` throw `.foreign`.
    public func plantForeign(_ name: SecretName, _ data: Data) {
        locked {
            items[name] = data
            foreign.insert(name)
        }
    }

    /// The stored bytes, bypassing `readError` and a hold.
    public func peek(_ name: SecretName) -> Data? { locked { items[name] } }

    /// From now on every `read` waits until `releaseReads()`.
    public func holdReads() {
        gate.lock()
        held = true
        gate.unlock()
    }

    /// The reads waiting go on, and later ones don't wait.
    public func releaseReads() {
        gate.lock()
        held = false
        gate.broadcast()
        gate.unlock()
    }

    /// How many reads are waiting on a hold now.
    public var waitingReads: Int {
        gate.lock()
        defer { gate.unlock() }
        return _waitingReads
    }

    public func read(_ name: SecretName) throws -> Data? {
        gate.lock()
        _waitingReads += 1
        while held { gate.wait() }
        _waitingReads -= 1
        gate.unlock()
        return try locked {
            if let error = _readError { throw error }
            if foreign.contains(name), items[name] != nil { throw SecretStoreError.foreign }
            return items[name]
        }
    }

    public func write(_ name: SecretName, _ data: Data) throws {
        try locked {
            if let error = _writeError { throw error }
            if foreign.contains(name), items[name] != nil { throw SecretStoreError.foreign }
            items[name] = data
            _writes += 1
        }
    }

    public func create(_ name: SecretName, _ data: Data) throws {
        try locked {
            if let error = _deleteError { throw error }
            if let error = _writeError { throw error }
            foreign.remove(name)
            items[name] = data
            _writes += 1
            _creates += 1
        }
    }

    public func delete(_ name: SecretName) throws {
        try locked {
            if let error = _deleteError { throw error }
            items[name] = nil
            foreign.remove(name)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
