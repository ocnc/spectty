import Foundation
import Security

// MARK: - Errors

/// Errors that can occur during Keychain operations.
public enum KeychainError: Error, Sendable {
    case saveFailed(status: OSStatus)
    case loadFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)
    case listFailed(status: OSStatus)
    case unexpectedItemData
    case itemAlreadyExists
}

// MARK: - KeychainManager

/// Thread-safe actor for storing and retrieving SSH private keys from the iOS Keychain.
///
/// Keys are stored as `kSecClassGenericPassword` items, keyed by account name under a
/// fixed service identifier.
public actor KeychainManager {

    // MARK: Constants

    /// The service name used to scope all items stored by this manager.
    private static let serviceName = "sh.ligma.Spectty.ssh-keys"

    // MARK: Initialisation

    public init() {}

    // MARK: Save

    /// Persist an SSH private key blob in the Keychain.
    ///
    /// - Parameters:
    ///   - key: Raw private-key data to store.
    ///   - account: A human-readable identifier (e.g. `"id_ed25519"`).
    /// - Throws: ``KeychainError/itemAlreadyExists`` if an entry for `account` already exists,
    ///           or ``KeychainError/saveFailed(status:)`` on any other Security framework error.
    public func save(key: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw KeychainError.itemAlreadyExists
        default:
            throw KeychainError.saveFailed(status: status)
        }
    }

    // MARK: Load

    /// Retrieve the SSH private key data for a given account.
    ///
    /// - Parameter account: The identifier the key was stored under.
    /// - Returns: The raw key `Data`, or `nil` if no matching item exists.
    /// - Throws: ``KeychainError/loadFailed(status:)`` on Security framework errors,
    ///           or ``KeychainError/unexpectedItemData`` if the stored value is not `Data`.
    public func load(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedItemData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.loadFailed(status: status)
        }
    }

    // MARK: Delete

    /// Remove the SSH private key for a given account from the Keychain.
    ///
    /// - Parameter account: The identifier of the key to delete.
    /// - Throws: ``KeychainError/deleteFailed(status:)`` if the deletion fails for any reason
    ///           other than the item not being found.
    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)

        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.deleteFailed(status: status)
        }
    }

    // MARK: List

    /// Return the account identifiers for every SSH key stored by this manager.
    ///
    /// - Returns: An array of account name strings, possibly empty.
    /// - Throws: ``KeychainError/listFailed(status:)`` on Security framework errors.
    public func listAccounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else {
                return []
            }
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.listFailed(status: status)
        }
    }
}
