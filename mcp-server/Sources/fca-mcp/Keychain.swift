import Foundation
import Security

/// Reads API keys from the SAME Keychain service the FloatingChatApp wizard
/// writes to, so this server uses whatever keys you've added in the app.
enum Keychain {
    static let service = "com.floatingchatapp.apikeys"

    static func get(_ account: String) -> String? {
        // Keychain is primary; env-var (e.g. mimo_api_key -> MIMO_API_KEY) is the
        // fallback for headless/CI or when the keychain item isn't readable.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8),
           !value.isEmpty {
            return value
        }
        if let env = ProcessInfo.processInfo.environment[account.uppercased()], !env.isEmpty {
            return env
        }
        return nil
    }
}
