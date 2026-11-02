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

    /// This Mac's owner key for one Pond (`SourceKey`), with its enrollment state.
    public static func ownerKey(sourceKey: String) -> SecretName {
        SecretName(service: "io.github.xooxoxxo.relay.owner-key", account: sourceKey)
    }

    /// The key that seals the review store.
    public static let reviewSeal = SecretName(service: "io.github.xooxoxxo.relay.review-seal", account: "default")

    /// What Keychain Access shows for the item.
    var label: String {
        switch service {
        case Self.reviewSeal.service: return "Hook review seal"
        default: return "Hook owner key"
        }
    }
}

public enum SecretStoreError: Error, Equatable, Sendable {
    /// The item is there but couldn't be read: the owner refused the password prompt after
    /// an update (ad-hoc signing), the Keychain is locked, or interaction isn't allowed.
    /// Never treated as "no item": a refused read must not mint a new key over the old one.
    case unreadable(OSStatus)
    case writeFailed(OSStatus)
    case deleteFailed(OSStatus)
}

/// Where Hook keeps its secrets. `read` is nil only when there is no item.
public protocol SecretStore: Sendable {
    func read(_ name: SecretName) throws -> Data?
    func write(_ name: SecretName, _ data: Data) throws
    /// Deleting a missing item is not an error.
    func delete(_ name: SecretName) throws
}

/// The login Keychain, each item readable without a prompt only by this app (an access list
/// that trusts the calling app alone). Under ad-hoc signing every build is a new app, so
/// after an update macOS asks once for the login password; refusing gives `.unreadable`.
///
/// `SecAccessCreate` and `SecTrustedApplicationCreateFromPath` are deprecated but are the only
/// way to give a file-based Keychain item an access list; they stay in this one file.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func read(_ name: SecretName) throws -> Data? {
        var query = Self.query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw SecretStoreError.unreadable(errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.unreadable(status)
        }
    }

    public func write(_ name: SecretName, _ data: Data) throws {
        let update = SecItemUpdate(Self.query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw SecretStoreError.writeFailed(update)
        }
        var add = Self.query(name)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = name.label
        if let access = Self.access(label: name.label) { add[kSecAttrAccess as String] = access }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.writeFailed(status) }
    }

    public func delete(_ name: SecretName) throws {
        let status = SecItemDelete(Self.query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.deleteFailed(status)
        }
    }

    private static func query(_ name: SecretName) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: name.service,
         kSecAttrAccount as String: name.account]
    }

    /// An access list whose only trusted application is this one (a nil path is the caller).
    private static func access(label: String) -> SecAccess? {
        var app: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &app) == errSecSuccess, let app else { return nil }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, [app] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}

/// An in-memory store for tests and the gallery. Setting a `…Error` makes every matching
/// call throw it, as a refused or failing Keychain would.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SecretName: Data] = [:]
    private var _readError: SecretStoreError?
    private var _writeError: SecretStoreError?
    private var _deleteError: SecretStoreError?
    private var _writes = 0

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

    /// Successful writes so far.
    public var writes: Int { locked { _writes } }

    /// The stored bytes, bypassing `readError`.
    public func peek(_ name: SecretName) -> Data? { locked { items[name] } }

    public func read(_ name: SecretName) throws -> Data? {
        try locked {
            if let error = _readError { throw error }
            return items[name]
        }
    }

    public func write(_ name: SecretName, _ data: Data) throws {
        try locked {
            if let error = _writeError { throw error }
            items[name] = data
            _writes += 1
        }
    }

    public func delete(_ name: SecretName) throws {
        try locked {
            if let error = _deleteError { throw error }
            items[name] = nil
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
