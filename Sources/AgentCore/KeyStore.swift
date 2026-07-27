import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// The key-resolution seam: how AgentCore obtains an API key for a provider.
/// macOS uses env vars, the login Keychain (shared with the FloatingChatApp wizard),
/// then an owner-only on-disk fallback; Linux uses env vars + the same optional file. This is the
/// "keychain reader with env fallback" seam from the unification spec.
public protocol KeyStore: Sendable {
    func key(forAccount account: String) -> String?
}

/// Env-var first/last helpers shared by both implementations. Account
/// `mimo_api_key` maps to env `MIMO_API_KEY`.
private func envKey(_ account: String) -> String? {
    let v = ProcessInfo.processInfo.environment[account.uppercased()]
    return (v?.isEmpty == false) ? v : nil
}

#if canImport(Security)
/// macOS: env -> login Keychain (service shared with the GUI app) -> owner-only file fallback.
public struct KeychainKeyStore: KeyStore {
    public let service: String
    private let fileFallback: (any KeyStore)?

    public init(service: String = "com.floatingchatapp.apikeys",
                fileFallback: (any KeyStore)? = FileKeyStore()) {
        self.service = service
        self.fileFallback = fileFallback
    }

    public func key(forAccount account: String) -> String? {
        if let v = envKey(account) { return v }   // env always wins; never touch Keychain when set
        // File store is checked BEFORE the Keychain on purpose: once a key lives in the
        // owner-only on-disk file, kist resolves it without ever calling SecItemCopyMatching,
        // so the OS never throws a "enter your login password" auth prompt. This is what keeps
        // a frequently-rebuilt CLI (whose code signature changes each build, invalidating the
        // Keychain's "Always Allow") from re-prompting forever. The Keychain remains a fallback
        // for any key the file doesn't carry (kept in sync with the GUI app's wizard).
        if let v = fileFallback?.key(forAccount: account), !v.isEmpty { return v }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        // CLI health/startup must never hang behind a Keychain UI/auth prompt. If the item is
        // inaccessible, fail fast and report "missing key" rather than blocking the terminal.
        //
        // NOTE on the two guards below: LAContext.interactionNotAllowed only suppresses
        // *access-control* prompts (biometric/passcode for kSecAttrAccessControl items). It does
        // NOT suppress the legacy ACL "<app> wants to use your confidential information … enter the
        // login keychain password" dialog that fires when an untrusted (ad-hoc-signed) caller reads
        // an item another app owns — which is exactly what bit Luke on every rebuild. The only API
        // that turns THAT dialog into a fast errSecInteractionNotAllowed is kSecUseAuthenticationUI
        // = …UIFail. It's deprecated in favour of the LAContext path, but the replacement does not
        // cover legacy ACL trust, so we deliberately keep it: a silent "missing key" beats a
        // blocking password prompt in a terminal.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        #if canImport(LocalAuthentication)
        let auth = LAContext()
        auth.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = auth
        #endif
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        return nil
    }
}
#endif

/// Linux / portable: env vars, then an optional JSON file ({account: key}).
public struct FileKeyStore: KeyStore {
    private let path: String
    public init(path: String? = nil) {
        self.path = path ?? (ProcessInfo.processInfo.environment["HOME"].map { $0 + "/.config/agentcore/keys.json" } ?? "")
    }

    /// Read the owner-only secret file on EACH lookup (not cached at init). A long-running kist session
    /// that adds a key mid-session (via `SecretWriter`, e.g. adding a key to a red model in the picker, or
    /// `/model import`) then resolves it WITHOUT a restart. The owner-only perms gate runs per read; env
    /// still wins over the file. The file is tiny and OS-page-cached, so per-lookup reads are cheap.
    private func fileKeys() -> [String: String] {
        guard !path.isEmpty, Self.isOwnerOnlySecretFile(path: path),
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return json
    }

    static func isOwnerOnlySecretFile(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let perms = attrs[.posixPermissions] as? NSNumber else {
            return false
        }
        return (perms.intValue & 0o077) == 0
    }

    public func key(forAccount account: String) -> String? {
        if let v = envKey(account) { return v }
        let v = fileKeys()[account]
        return (v?.isEmpty == false) ? v : nil
    }
}

/// Default KeyStore for the current platform.
public enum DefaultKeyStore {
    public static func make() -> KeyStore {
        #if canImport(Security)
        return KeychainKeyStore()
        #else
        return FileKeyStore()
        #endif
    }
}
