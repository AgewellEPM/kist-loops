import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

    /// Verification path for strictly read-only projections. Unlike `verify`, it never creates a
    /// missing install key; absent key material simply means the seal cannot be authenticated.
    static func verifyWithoutCreatingKey(_ canonical: String, seal: String) -> Bool {
        guard !seal.isEmpty, let key = try? existingKeyWithoutCreating() else { return false }
        let tag = MythosCrypto.hmacSHA256(key: key, message: Data(canonical.utf8))
        let expected = tag.map { String(format: "%02x", $0) }.joined()
        return expected == seal
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
    nonisolated(unsafe) private static var cachedFileIdentity: KeyFileIdentity?
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
        if let key = cachedKey {
            try validateCachedKey(key)
            return key
        }

        if keyDirectoryOverrideForTesting == nil,
           forceEphemeral || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let ephemeral = MythosCrypto.randomKey()
            cachedKey = ephemeral
            cachedFileIdentity = nil
            return ephemeral
        }
        if FileManager.default.fileExists(atPath: keyPath) {
            let loaded = try loadKeyRaw()   // throws on bad perms / wrong size / unreadable — no silent re-key
            cachedKey = loaded.key
            cachedFileIdentity = loaded.identity
            return loaded.key
        }
        let fresh = MythosCrypto.randomKey()
        try storeKeyRaw(fresh)
        let loaded = try loadKeyRaw()
        guard loaded.key == fresh else { throw ForgeSealError.keyReadFailed }
        cachedKey = fresh
        cachedFileIdentity = loaded.identity
        return fresh
    }

    private static func existingKeyWithoutCreating() throws -> Data? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cachedKey {
            try validateCachedKey(cachedKey)
            return cachedKey
        }
        guard FileManager.default.fileExists(atPath: keyPath) else { return nil }
        let existing = try loadKeyRaw()
        cachedKey = existing.key
        cachedFileIdentity = existing.identity
        return existing.key
    }

    private static var keyDir: String { (keyDirectoryOverrideForTesting ?? NSHomeDirectory() + "/.mythos/keys") }
    private static var keyPath: String { keyDir + "/forgeseal-v1.key" }

    /// Absolute authority-key path for host-owned sandbox policy and state attestation. Reading this
    /// value never creates or loads the key; untrusted subprocesses receive only a kernel deny rule.
    static var protectedKeyPath: String { keyPath }

    /// Read an EXISTING key file, fail-closed. The file must be exactly 32 bytes AND not accessible by
    /// group or other (perms & 0o077 == 0) — a looser-permission key is treated as compromised.
    private static func loadKeyRaw() throws -> (key: Data, identity: KeyFileIdentity) {
        let fd = open(keyPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ForgeSealError.keyReadFailed }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == geteuid(),
              before.st_size == 32 else { throw ForgeSealError.keyReadFailed }
        guard before.st_mode & mode_t(0o077) == 0 else {
            throw ForgeSealError.keyInsecurePermissions
        }
        var data = Data(count: 32)
        let readOK = data.withUnsafeMutableBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        var after = stat()
        guard readOK, fstat(fd, &after) == 0,
              KeyFileIdentity.same(before, after) else { throw ForgeSealError.keyReadFailed }
        let identity = KeyFileIdentity(
            path: keyPath, device: UInt64(after.st_dev), inode: UInt64(after.st_ino),
            owner: UInt32(after.st_uid), mode: UInt16(after.st_mode & mode_t(0o777)),
            size: Int64(after.st_size))
        return (data, identity)
    }

    private static func validateCachedKey(_ key: Data) throws {
        if let identity = cachedFileIdentity {
            guard identity.path == keyPath else { throw ForgeSealError.keyReadFailed }
            let loaded = try loadKeyRaw()
            guard loaded.identity == identity, loaded.key == key else {
                throw ForgeSealError.keyReadFailed
            }
            return
        }
        guard keyDirectoryOverrideForTesting == nil,
              forceEphemeral
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            throw ForgeSealError.keyReadFailed
        }
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
        cachedFileIdentity = nil
    }

    /// Clear the in-process key cache. Also clears the forced-ephemeral flag and the test dir override,
    /// so a test that exercised the FILE path doesn't leak state into the next test.
    public static func resetCacheForTesting() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedKey = nil
        cachedFileIdentity = nil
        forceEphemeral = false
        keyDirectoryOverrideForTesting = nil
    }
}

private struct KeyFileIdentity: Equatable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let mode: UInt16
    let size: Int64

    static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        guard lhs.st_dev == rhs.st_dev, lhs.st_ino == rhs.st_ino,
              lhs.st_uid == rhs.st_uid, lhs.st_mode == rhs.st_mode,
              lhs.st_size == rhs.st_size else { return false }
        #if canImport(Darwin)
        return lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
        #else
        return lhs.st_mtim.tv_sec == rhs.st_mtim.tv_sec
            && lhs.st_mtim.tv_nsec == rhs.st_mtim.tv_nsec
            && lhs.st_ctim.tv_sec == rhs.st_ctim.tv_sec
            && lhs.st_ctim.tv_nsec == rhs.st_ctim.tv_nsec
        #endif
    }
}

public enum ForgeSealError: Error, Sendable { case keyReadFailed, keyWriteFailed, keyInsecurePermissions }
