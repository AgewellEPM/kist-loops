import Foundation
import Security

/// Minimal storage contract so key-management UI can be unit-tested with an
/// in-memory fake instead of polluting the real login Keychain.
protocol KeychainStoring {
    func save(key: String, value: String) throws
    func get(key: String) -> String?
    func delete(key: String) throws
    func exists(key: String) -> Bool
}

/// Secure storage for API keys using macOS Keychain
/// Replaces insecure UserDefaults storage
final class KeychainService: KeychainStoring {
    static let shared = KeychainService()

    private let service = "com.floatingchatapp.apikeys"

    private init() {}

    // MARK: - Public API

    /// Save an API key securely
    func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // First try to update existing item
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        var status = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

        // If item doesn't exist, add it
        if status == errSecItemNotFound {
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]

            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Retrieve an API key
    func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    /// Delete an API key
    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Check if a NON-EMPTY key exists. An empty stored string is treated as
    /// "no key" so the missing-key guards don't get bypassed by a blank entry.
    func exists(key: String) -> Bool {
        return !(get(key: key) ?? "").isEmpty
    }

    /// List all stored keys (not values)
    func listKeys() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: - Convenience Methods for Common Keys

    static let anthropicAPIKey = "anthropic_api_key"
    static let openAIAPIKey = "openai_api_key"
    static let deepSeekAPIKey = "deepseek_api_key"

    var anthropicKey: String? {
        get { get(key: Self.anthropicAPIKey) }
        set {
            if let value = newValue {
                try? save(key: Self.anthropicAPIKey, value: value)
            } else {
                try? delete(key: Self.anthropicAPIKey)
            }
        }
    }

    var openAIKey: String? {
        get { get(key: Self.openAIAPIKey) }
        set {
            if let value = newValue {
                try? save(key: Self.openAIAPIKey, value: value)
            } else {
                try? delete(key: Self.openAIAPIKey)
            }
        }
    }

    var deepSeekKey: String? {
        get { get(key: Self.deepSeekAPIKey) }
        set {
            if let value = newValue {
                try? save(key: Self.deepSeekAPIKey, value: value)
            } else {
                try? delete(key: Self.deepSeekAPIKey)
            }
        }
    }

    // MARK: - Migration from UserDefaults

    /// Migrate API keys from UserDefaults to Keychain
    /// Call this once on app launch
    func migrateFromUserDefaults() {
        let defaults = UserDefaults.standard
        let keysToMigrate = [
            ("anthropic_api_key", Self.anthropicAPIKey),
            ("openai_api_key", Self.openAIAPIKey),
            ("deepseek_api_key", Self.deepSeekAPIKey)
        ]

        for (defaultsKey, keychainKey) in keysToMigrate {
            if let value = defaults.string(forKey: defaultsKey), !value.isEmpty {
                // Only migrate if not already in keychain
                if !exists(key: keychainKey) {
                    try? save(key: keychainKey, value: value)
                }
                // Remove from UserDefaults after migration
                defaults.removeObject(forKey: defaultsKey)
            }
        }
    }
}

// MARK: - Errors

enum KeychainError: LocalizedError {
    case invalidData
    case unhandledError(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Invalid data - could not encode string to UTF-8"
        case .unhandledError(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error: \(message)"
            }
            return "Keychain error with status: \(status)"
        }
    }
}
