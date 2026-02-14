import Foundation
import Security

/// Manages per-user OpenRouter API keys in macOS Keychain
///
/// The key is stored ONLY in the macOS Keychain (not UserDefaults, not files).
/// On first login, the key is received from the Edge Function and stored here.
/// If lost (reinstall), `get-cloud-key` Edge Function re-provisions it.
public enum CloudKeyManager {

    private static let serviceName = "com.findit.openrouter-key"

    // MARK: - CRUD

    /// Store OpenRouter key in Keychain
    public static func storeKey(_ key: String, for userId: String) throws {
        guard let keyData = key.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // Delete existing (ignore errors)
        deleteKey(for: userId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: userId,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Retrieve OpenRouter key from Keychain
    public static func retrieveKey(for userId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: userId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    /// Delete key from Keychain (on sign out)
    @discardableResult
    public static func deleteKey(for userId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: userId,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if a key exists for the user
    public static func hasKey(for userId: String) -> Bool {
        retrieveKey(for: userId) != nil
    }

    // MARK: - Errors

    public enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        case invalidData

        public var errorDescription: String? {
            switch self {
            case .saveFailed(let s):
                return "Keychain save failed: OSStatus \(s)"
            case .invalidData:
                return "Invalid key data"
            }
        }
    }
}
