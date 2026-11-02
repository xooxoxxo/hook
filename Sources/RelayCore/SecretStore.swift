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
    func write(_ name: SecretName, _ data: Data) throws
    /// Deleting a missing item is not an error.
    func delete(_ name: SecretName) throws
}

/// The login Keychain, each item readable without a prompt only by this app (an access list
/// that trusts the calling app alone). Under ad-hoc signing every build is a new app, so
/// after an update macOS asks once for the login password; refusing gives `.unreadable`.
///
/// An item found by service and account is trusted only when every access-list entry that
/// lets an app read its secret names this app alone: one made with "any app may read" or
/// for another app is `.foreign`, since its maker may know the value.
///
/// `SecAccessCreate`, `SecTrustedApplicationCreateFromPath` and the `SecACL` calls are
/// deprecated but are the only way to give or read a file-based Keychain item's access list;
/// they stay in this one file.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func read(_ name: SecretName) throws -> Data? {
        guard try Self.checkOwn(name) else { return nil }
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
        // Never update a planted item in place: the new secret would land where its maker reads.
        _ = try Self.checkOwn(name)
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

    /// False when there is no item; throws `.foreign` for an item whose access list isn't this
    /// app's alone.
    private static func checkOwn(_ name: SecretName) throws -> Bool {
        var query = Self.query(name)
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: return false
        default: throw SecretStoreError.unreadable(status)
        }
        guard let result, CFGetTypeID(result) == SecKeychainItemGetTypeID() else { throw SecretStoreError.foreign }
        let item = result as! SecKeychainItem
        guard let me = selfData(), isOwn(decryptLists: try decryptLists(item), me: me) else {
            throw SecretStoreError.foreign
        }
        return true
    }

    /// Each access-list entry that allows decrypting (or anything): its trusted apps' data,
    /// nil for an entry that allows any app.
    private static func decryptLists(_ item: SecKeychainItem) throws -> [[Data]?] {
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { throw SecretStoreError.foreign }
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL] else {
            throw SecretStoreError.foreign
        }
        let reading: Set<String> = [kSecACLAuthorizationDecrypt as String, kSecACLAuthorizationAny as String]
        var out: [[Data]?] = []
        for acl in acls {
            let authorizations = (SecACLCopyAuthorizations(acl) as? [String]) ?? []
            guard !reading.isDisjoint(with: authorizations) else { continue }
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &description, &prompt) == errSecSuccess else { throw SecretStoreError.foreign }
            guard let apps = apps as? [SecTrustedApplication] else {
                out.append(nil)
                continue
            }
            out.append(apps.map { app in
                var data: CFData?
                return SecTrustedApplicationCopyData(app, &data) == errSecSuccess ? appPath((data as Data?) ?? Data()) : Data()
            })
        }
        return out
    }

    /// This app as an access list names it.
    private static func selfData() -> Data? {
        var app: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &app) == errSecSuccess, let app else { return nil }
        var data: CFData?
        guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess, let data else { return nil }
        return appPath(data as Data)
    }

    /// An entry's data is the app's path as a C string: compared without its trailing NULs.
    private static func appPath(_ data: Data) -> Data {
        var bytes = data
        while bytes.last == 0 { bytes.removeLast() }
        return bytes
    }

    /// The rule, on the access list's contents: at least one entry allows reading, and every
    /// such entry names a non-empty list of apps that are all this one.
    static func isOwn(decryptLists: [[Data]?], me: Data) -> Bool {
        !decryptLists.isEmpty && decryptLists.allSatisfy { apps in
            guard let apps, !apps.isEmpty else { return false }
            return apps.allSatisfy { $0 == me }
        }
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

    /// Successful writes so far.
    public var writes: Int { locked { _writes } }

    /// An item another app made (any app may read it): `read` and `write` throw `.foreign`.
    public func plantForeign(_ name: SecretName, _ data: Data) {
        locked {
            items[name] = data
            foreign.insert(name)
        }
    }

    /// The stored bytes, bypassing `readError`.
    public func peek(_ name: SecretName) -> Data? { locked { items[name] } }

    public func read(_ name: SecretName) throws -> Data? {
        try locked {
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
