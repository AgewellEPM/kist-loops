import Foundation

/// HMAC-SHA256 provenance seal for persisted verified records — the forge boundary at persist/load.
/// Without it, a hand-crafted JSON file could manufacture verified-done items. With it, every
/// persisted record is signed with a per-install HMAC key; any record failing verification on load is
/// DROPPED. This is the cryptographic primitive the gavel's `sealed=1` token rides on.
///
/// Ported from TinkySDR's Captain (Stage 1.3): HMAC via `MythosCrypto` (swift-crypto, cross-platform)
/// instead of CryptoKit directly; the key moved from macOS Keychain to a protected file
/// (`~/.mythos/keys/forgeseal-v1.key`, 0600) so it works on macOS AND Linux. Under test (or when forced)
/// the key is process-EPHEMERAL — never written to disk.
public enum ForgeSeal {

    // MARK: - Public API

    /// Sign `canonical` with the install's HMAC key → lowercase hex HMAC-SHA256 tag ("" if no key).
    public static func sign(_ canonical: String) -> String {
        guard let key = try? currentKey() else { return "" }
        let tag = MythosCrypto.hmacSHA256(key: key, message: Data(canonical.utf8))
        return tag.map { String(format: "%02x", $0) }.joined()
    }

    /// True iff `seal` was produced by `sign(_:)` with the current install key over the same canonical.
    public static func verify(_ canonical: String, seal: String) -> Bool {
        guard !seal.isEmpty else { return false }
        let expected = sign(canonical)
        return !expected.isEmpty && expected == seal
    }

    /// Escape a free-text field for a canonical signing string: percent-encode EVERYTHING
    /// non-alphanumeric so the join delimiters (`|`, `=`) can never appear inside a value. This makes
    /// the canonical string INJECTIVE — two different logical records can never collide (closing the
    /// pipe-collision gap where `item="a|evidence=b"` could impersonate `item="a", evidence="b"`).
    public static func field(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    // MARK: - Key management

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedKey: Data?
    nonisolated(unsafe) private static var forceEphemeral = false
    /// Test-only override of the key directory, so the FILE path can be exercised against a temp dir
    /// without touching the user's real ~/.mythos. When set, the ephemeral branch is skipped.
    nonisolated(unsafe) static var keyDirectoryOverrideForTesting: String?

    /// Load or create the install's HMAC key. Test bundle (or forced) → process-ephemeral (never
    /// persisted); production → a 0600 file under ~/.mythos/keys so seals survive across runs.
    ///
    /// FAIL-CLOSED on load (Codex HIGH): if a key file already EXISTS it must be a trustworthy 32-byte
    /// 0600 file or this THROWS — it is NEVER silently regenerated. That (a) refuses a group/world-
    /// accessible key (a leaked/planted key), and (b) denies a forced-rekey DoS where corrupting the
    /// file would otherwise wipe the trust history. A throw makes every seal "" → the ledger empties
    /// (stricter, never looser).
    ///
    /// HONEST RESIDUAL: like the original's same-user-accessible Keychain item, a file key cannot defend
    /// against a SAME-USER local attacker who can write ~/.mythos BEFORE first run (they could plant a
    /// known 0600 key and forge internal seals). That is exactly why promotion-to-main requires the
    /// EXTERNAL Ed25519 attestation (the two-tier model, Stage 3 deploy gate) — the internal HMAC seal is
    /// the internal tier only.
    static func currentKey() throws -> Data {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let k = cachedKey { return k }

        if keyDirectoryOverrideForTesting == nil,
           forceEphemeral || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let ephemeral = MythosCrypto.randomKey()
            cachedKey = ephemeral
            return ephemeral
        }
        if FileManager.default.fileExists(atPath: keyPath) {
            let raw = try loadKeyRaw()   // throws on bad perms / wrong size / unreadable — no silent re-key
            cachedKey = raw
            return raw
        }
        let fresh = MythosCrypto.randomKey()
        try storeKeyRaw(fresh)
        cachedKey = fresh
        return fresh
    }

    private static var keyDir: String { (keyDirectoryOverrideForTesting ?? NSHomeDirectory() + "/.mythos/keys") }
    private static var keyPath: String { keyDir + "/forgeseal-v1.key" }

    /// Read an EXISTING key file, fail-closed. The file must be exactly 32 bytes AND not accessible by
    /// group or other (perms & 0o077 == 0) — a looser-permission key is treated as compromised.
    private static func loadKeyRaw() throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: keyPath)
        if let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue, (perms & 0o077) != 0 {
            throw ForgeSealError.keyInsecurePermissions
        }
        guard let d = FileManager.default.contents(atPath: keyPath), d.count == 32 else {
            throw ForgeSealError.keyReadFailed
        }
        return d
    }

    private static func storeKeyRaw(_ raw: Data) throws {
        try? FileManager.default.createDirectory(atPath: keyDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: keyPath, contents: raw,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ForgeSealError.keyWriteFailed
        }
    }

    // MARK: - Test hooks

    /// FORCE a process-ephemeral key (so tests never write ~/.mythos and are deterministic). Generates
    /// a FRESH key each call.
    public static func forceEphemeralKeyForTesting() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        forceEphemeral = true
        keyDirectoryOverrideForTesting = nil   // a prior file-path test must not leak its temp dir
        cachedKey = MythosCrypto.randomKey()
    }

    /// Clear the in-process key cache. Also clears the forced-ephemeral flag and the test dir override,
    /// so a test that exercised the FILE path doesn't leak state into the next test.
    public static func resetCacheForTesting() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedKey = nil
        forceEphemeral = false
        keyDirectoryOverrideForTesting = nil
    }
}

public enum ForgeSealError: Error, Sendable { case keyReadFailed, keyWriteFailed, keyInsecurePermissions }
