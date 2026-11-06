import Foundation
import Security

/// The Security boundary, injectable so storage policy can be tested without a real Keychain.
public protocol DataProtectionSecurityAPI: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

public struct SystemDataProtectionSecurity: DataProtectionSecurityAPI {
    public init() {}

    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    public func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    public func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    public func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// App-scoped data-protection Keychain, with no iCloud synchronization or Mac ACL calls.
/// Use AfterFirstUnlockThisDeviceOnly for a Pond token; WhenUnlockedThisDeviceOnly for the
/// owner key and review seal. Call on `KeychainQueue`, as with every synchronous SecretStore.
public struct DataProtectionSecretStore: SecretStore {
    public enum Accessibility: Sendable {
        case afterFirstUnlockThisDeviceOnly
        case whenUnlockedThisDeviceOnly

        fileprivate var value: CFString {
            switch self {
            case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .whenUnlockedThisDeviceOnly: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }
    }

    private let accessibility: Accessibility
    private let security: any DataProtectionSecurityAPI

    public init(accessibility: Accessibility, security: any DataProtectionSecurityAPI = SystemDataProtectionSecurity()) {
        self.accessibility = accessibility
        self.security = security
    }

    public func read(_ name: SecretName) throws -> Data? {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = security.copyMatching(query)
        switch result.status {
        case errSecItemNotFound: return nil
        case errSecSuccess:
            guard let data = result.data else { throw SecretStoreError.unreadable(errSecDecode) }
            return data
        default: throw SecretStoreError.unreadable(result.status)
        }
    }

    public func write(_ name: SecretName, _ data: Data) throws {
        // Refused reads never turn into writes, and an absent item is add-only (a racing
        // creation fails with duplicate rather than silently updating that new item).
        guard try read(name) != nil else { try create(name, data); return }
        let status = security.update(query(name), attributes: [kSecValueData as String: data])
        guard status == errSecSuccess else { throw SecretStoreError.writeFailed(status) }
    }

    /// Add-only: in particular, a duplicate seal is never deleted or updated.
    public func create(_ name: SecretName, _ data: Data) throws {
        var query = query(name)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibility.value
        let status = security.add(query)
        guard status == errSecSuccess else { throw SecretStoreError.writeFailed(status) }
    }

    /// Explicit enrollment/reset. A locked or otherwise unreadable item remains intact.
    public func replace(_ name: SecretName, _ data: Data) throws {
        if try read(name) != nil { try delete(name) }
        try create(name, data)
    }

    public func delete(_ name: SecretName) throws {
        let status = security.delete(query(name))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.deleteFailed(status) }
    }

    private func query(_ name: SecretName) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: name.service,
         kSecAttrAccount as String: name.account,
         kSecUseDataProtectionKeychain as String: true]
    }
}
