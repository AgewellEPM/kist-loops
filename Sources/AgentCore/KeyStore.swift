import Foundation
import Crypto
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
    /// Presence checks must not require decrypting the secret. The default preserves compatibility
    /// for simple stores; Keychain overrides it so startup/catalog probes cannot block on ACL UI.
    func containsKey(forAccount account: String) -> Bool
}

public extension KeyStore {
    func containsKey(forAccount account: String) -> Bool {
        key(forAccount: account) != nil
    }
}

/// Env-var first/last helpers shared by both implementations. Account
/// `mimo_api_key` maps to env `MIMO_API_KEY`.
private func envKey(_ account: String) -> String? {
    let v = ProcessInfo.processInfo.environment[account.uppercased()]
    return (v?.isEmpty == false) ? v : nil
}

/// Logical secret record shared by the file and Keychain backends. The digest binds the version to
/// the value, so an external Keychain rotation that changes the value while leaving old metadata is
/// detected rather than mistaken for an already-synchronized record.
struct VersionedSecretRecord: Codable, Sendable, Equatable {
    let value: String
    let updatedAtMilliseconds: Int64
    let digest: String

    static func make(value: String, updatedAtMilliseconds: Int64) -> VersionedSecretRecord {
        VersionedSecretRecord(value: value, updatedAtMilliseconds: updatedAtMilliseconds,
                              digest: SecretVersioning.digest(value))
    }

    var isValid: Bool { !value.isEmpty && digest == SecretVersioning.digest(value) }

    enum CodingKeys: String, CodingKey {
        case value
        case updatedAtMilliseconds = "updated_at_ms"
        case digest
    }
}

struct SecretFileEnvelope: Codable, Sendable, Equatable {
    static let currentFormat = 1
    let formatVersion: Int
    var keys: [String: VersionedSecretRecord]

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case keys
    }
}

enum SecretRecordSource: Sendable, Equatable { case primary, fallback }

enum SecretVersioning {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func milliseconds(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    /// Deterministic newest-record selection. A tie prefers the primary backend; synchronized records
    /// normally have the same digest, while a same-version/different-value tie is ambiguous and must not
    /// let a fallback silently replace the primary.
    static func newest(primary: VersionedSecretRecord?, fallback: VersionedSecretRecord?)
        -> (record: VersionedSecretRecord, source: SecretRecordSource)? {
        switch (primary?.isValid == true ? primary : nil, fallback?.isValid == true ? fallback : nil) {
        case let (.some(primary), .some(fallback)):
            return fallback.updatedAtMilliseconds > primary.updatedAtMilliseconds
                ? (fallback, .fallback) : (primary, .primary)
        case let (.some(primary), .none): return (primary, .primary)
        case let (.none, .some(fallback)): return (fallback, .fallback)
        case (.none, .none): return nil
        }
    }
}

protocol VersionedKeyStore: KeyStore {
    func versionedKey(forAccount account: String) -> VersionedSecretRecord?
    func synchronize(_ record: VersionedSecretRecord, forAccount account: String) throws
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
        let versionedFallback = fileFallback as? any VersionedKeyStore
        let fallbackRecord = versionedFallback?.versionedKey(forAccount: account)
        // Preserve compatibility for injected/legacy KeyStore implementations that cannot expose a version:
        // their old fallback-first behavior remains unchanged. FileKeyStore is version-aware and takes the
        // newest-record path below.
        if versionedFallback == nil, let value = fileFallback?.key(forAccount: account), !value.isEmpty {
            return value
        }
        let keychain = keychainRecord(forAccount: account,
                                      staleMetadataFloor: fallbackRecord?.updatedAtMilliseconds)
        guard let selected = SecretVersioning.newest(primary: keychain?.record, fallback: fallbackRecord) else {
            return nil
        }

        switch selected.source {
        case .primary:
            // Stamp missing/stale digest-bound metadata, then update an EXISTING fallback record only.
            // Do not create a new plaintext file for a Keychain-only user.
            if keychain?.metadataTrusted != true { synchronizeKeychain(selected.record, account: account, includeValue: false) }
            if let fallbackRecord,
               fallbackRecord.digest != selected.record.digest ||
               fallbackRecord.updatedAtMilliseconds != selected.record.updatedAtMilliseconds {
                try? versionedFallback?.synchronize(selected.record, forAccount: account)
            }
        case .fallback:
            // Update an EXISTING Keychain item only. Do not create one for file-only/headless users, which
            // would reintroduce ACL prompts on frequently rebuilt command-line binaries.
            if keychain != nil { synchronizeKeychain(selected.record, account: account, includeValue: true) }
        }
        return selected.record.value
    }

    public func containsKey(forAccount account: String) -> Bool {
        if envKey(account) != nil { return true }
        if fileFallback?.containsKey(forAccount: account) == true { return true }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard applyNoninteractiveAuthentication(to: &query) else { return false }
        // No kSecReturnData: existence checks must never decrypt a secret or trigger an ACL prompt.
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private struct KeychainCandidate {
        let record: VersionedSecretRecord
        let metadataTrusted: Bool
    }

    private struct KeychainMetadata: Codable {
        let formatVersion: Int
        let updatedAtMilliseconds: Int64
        let digest: String

        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case updatedAtMilliseconds = "updated_at_ms"
            case digest
        }
    }

    private func keychainRecord(forAccount account: String, staleMetadataFloor: Int64?) -> KeychainCandidate? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        // CLI health/startup must never hang behind a Keychain authentication prompt. Bind a
        // noninteractive LAContext to this exact query; if that API is unavailable, fail closed
        // instead of issuing a potentially interactive secret read.
        guard applyNoninteractiveAuthentication(to: &query) else { return nil }
        // LAContext.interactionNotAllowed alone does NOT suppress the legacy ACL login-password
        // dialog for GUI-created / old-signature Keychain items. Pair it with the UI-fail option so
        // those legacy reads fail closed (errSecInteractionNotAllowed) instead of blocking on a
        // dialog after an ad-hoc rebuild. READ site.
        applyLegacyUIFail(to: &query)
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let item = result as? [String: Any],
           let data = item[kSecValueData as String] as? Data,
           let value = String(data: data, encoding: .utf8), !value.isEmpty {
            let digest = SecretVersioning.digest(value)
            let metadataData = item[kSecAttrGeneric as String] as? Data
            let metadata = metadataData.flatMap { try? JSONDecoder().decode(KeychainMetadata.self, from: $0) }
            let trusted = metadata?.formatVersion == SecretFileEnvelope.currentFormat && metadata?.digest == digest
            let modified = (item[kSecAttrModificationDate as String] as? Date).map(SecretVersioning.milliseconds) ?? 0
            var logicalVersion = trusted ? (metadata?.updatedAtMilliseconds ?? modified) : modified
            // Metadata whose digest no longer matches proves an external writer rotated the value without
            // updating Kist metadata. Make that observed rotation newer than the compared fallback even if
            // Keychain timestamps are coarse or the wall clock moved backwards.
            if metadataData != nil, !trusted, let floor = staleMetadataFloor, logicalVersion <= floor {
                logicalVersion = floor == Int64.max ? floor : floor + 1
            }
            return KeychainCandidate(record: .make(value: value, updatedAtMilliseconds: logicalVersion),
                                     metadataTrusted: trusted)
        }
        return nil
    }

    private func synchronizeKeychain(_ record: VersionedSecretRecord, account: String, includeValue: Bool) {
        let metadata = KeychainMetadata(formatVersion: SecretFileEnvelope.currentFormat,
                                        updatedAtMilliseconds: record.updatedAtMilliseconds,
                                        digest: record.digest)
        guard let metadataData = try? JSONEncoder().encode(metadata) else { return }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard applyNoninteractiveAuthentication(to: &query) else { return }
        // Same legacy-ACL hazard as the read path: a GUI-created / old-signature item would otherwise
        // pop the login-password dialog on SecItemUpdate despite interactionNotAllowed. Pair the
        // context with the UI-fail option so a legacy update fails closed rather than blocking. UPDATE site.
        applyLegacyUIFail(to: &query)
        var updates: [String: Any] = [kSecAttrGeneric as String: metadataData]
        if includeValue { updates[kSecValueData as String] = Data(record.value.utf8) }
        _ = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
    }

    /// Security.framework's supported noninteractive path. The context is retained by the query
    /// dictionary for the duration of SecItemCopyMatching/SecItemUpdate.
    private func applyNoninteractiveAuthentication(to query: inout [String: Any]) -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return true
        #else
        return false
        #endif
    }

    /// Legacy-ACL backstop for value-bearing reads/updates. `LAContext.interactionNotAllowed`
    /// suppresses biometric/passcode UI, but items created by the GUI wizard or carrying an old code
    /// signature still route through the classic ACL path, where only `kSecUseAuthenticationUIFail`
    /// prevents the blocking login-password dialog and instead returns errSecInteractionNotAllowed.
    /// Kept macOS-only (Security is present) and applied at the read and update sites so a real
    /// provider resolution after an ad-hoc rebuild fails closed rather than hanging on a dialog.
    private func applyLegacyUIFail(to query: inout [String: Any]) {
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }
}
#endif

/// Linux / portable: env vars, then an optional JSON file ({account: key}).
public struct FileKeyStore: VersionedKeyStore {
    private let path: String
    public init(path: String? = nil) {
        // $HOME wins (respects sudo/CI overrides); NSHomeDirectory() keeps key lookups working when
        // HOME is unset instead of silently degrading to an empty path that never resolves a key.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        self.path = path ?? home + "/.config/agentcore/keys.json"
    }

    /// Read the owner-only secret file on EACH lookup (not cached at init). A long-running kist session
    /// that adds a key mid-session (via `SecretWriter`, e.g. adding a key to a red model in the picker, or
    /// `/model import`) then resolves it WITHOUT a restart. The owner-only perms gate runs per read; env
    /// still wins over the file. The file is tiny and OS-page-cached, so per-lookup reads are cheap.
    func versionedKey(forAccount account: String) -> VersionedSecretRecord? {
        guard !path.isEmpty, Self.isOwnerOnlySecretFile(path: path),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        if let envelope = try? JSONDecoder().decode(SecretFileEnvelope.self, from: data),
           envelope.formatVersion == SecretFileEnvelope.currentFormat,
           let record = envelope.keys[account], record.isValid {
            return record
        }
        // Legacy compatibility: flat `{account: key}` files remain readable. Their per-key logical version
        // starts at the file modification time and is materialized into the envelope on the next write.
        guard let legacy = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let value = legacy[account], !value.isEmpty else { return nil }
        let modified = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)
            .map(SecretVersioning.milliseconds) ?? 0
        return .make(value: value, updatedAtMilliseconds: modified)
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
        return versionedKey(forAccount: account)?.value
    }

    func synchronize(_ record: VersionedSecretRecord, forAccount account: String) throws {
        try SecretWriter.writeVersioned(account: account, record: record, path: path)
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
