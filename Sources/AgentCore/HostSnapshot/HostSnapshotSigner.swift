import Foundation
import Crypto   // apple/swift-crypto — to derive the public half of a persisted raw Ed25519 private key.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// PROTOTYPE — host_snapshot Ed25519 authenticity signer (SECURITY BOUNDARY: this is the ONLY guest-
// verifiable signature on a host frame).
//
// WHY a SECOND key, separate from ForgeSeal's HMAC:
//   - ForgeSeal's HMAC seal is SYMMETRIC. The host signs and the host verifies with the SAME secret. A
//     guest VM CANNOT verify it without holding the host secret — which would defeat the boundary. So the
//     HMAC `signature` field is a HOST-SIDE integrity/provenance tag ONLY, never guest-verifiable.
//   - Ed25519 is ASYMMETRIC. The host signs with a PRIVATE key it never exports; the guest verifies with
//     the PUBLIC key it pins OUT-OF-BAND (via `kist host-snapshot --pubkey`). THIS is the guest-verifiable
//     authenticity signature.
//
// Key management mirrors ForgeSeal exactly: a 0600 owner-only file under ~/.mythos/keys, created-if-absent,
// and FAIL-CLOSED on load (bad perms / wrong size / not-a-regular-file / not-owned-by-us → THROW, never a
// silent re-key that would rotate the pinned public key out from under a guest). Under test the key is
// process-EPHEMERAL (never written to ~/.mythos). We DO NOT roll new crypto — every primitive is
// `MythosCrypto` (swift-crypto), the same wrappers PromotionAttestation uses.
public enum HostSnapshotSigner {

    /// The persisted Ed25519 private key is exactly the 32-byte raw representation swift-crypto emits.
    static let keyByteCount = 32

    // MARK: - Public API

    /// The host_snapshot Ed25519 PUBLIC key (raw 32 bytes) for THIS install, creating the private key on
    /// first use. Fail-closed: throws if the key file exists but is untrustworthy (never silently re-keys).
    public static func publicKeyRaw() throws -> Data {
        try currentKeyPair().publicRaw
    }

    /// The host_snapshot Ed25519 public key as base64 — the exact string an operator pins into a guest.
    public static func publicKeyBase64() throws -> String {
        try publicKeyRaw().base64EncodedString()
    }

    /// Short, stable fingerprint of the public key: first 16 hex chars of sha256(publicRaw). Lets a guest
    /// name WHICH key it pinned and lets the operator confirm the pin matches without diffing raw bytes.
    public static func keyID(forPublicKeyRaw publicRaw: Data) -> String {
        let digest = MythosCrypto.sha256(publicRaw).map { String(format: "%02x", $0) }.joined()
        return String(digest.prefix(16))
    }

    /// This install's key_id (creating the key on first use).
    public static func keyID() throws -> String {
        keyID(forPublicKeyRaw: try publicKeyRaw())
    }

    /// Detached Ed25519 signature over `canonical` as lowercase hex. Throws if no usable key material
    /// (fail-closed: the caller refuses to emit a frame with an empty ed25519 signature).
    public static func sign(_ canonical: String) throws -> String {
        let pair = try currentKeyPair()
        let sig = try MythosCrypto.ed25519Sign(message: Data(canonical.utf8), privateKeyRaw: pair.privateRaw)
        return sig.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Key management (mirrors ForgeSeal.swift)

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedPair: MythosCrypto.Ed25519KeyPair?
    nonisolated(unsafe) private static var forceEphemeral = false
    /// Test-only override of the key directory (exercise the FILE path against a temp dir without touching
    /// the user's real ~/.mythos). When set, the ephemeral branch is skipped.
    nonisolated(unsafe) static var keyDirectoryOverrideForTesting: String?

    private static var keyDir: String { (keyDirectoryOverrideForTesting ?? NSHomeDirectory() + "/.mythos/keys") }
    private static var keyPath: String { keyDir + "/host-snapshot-ed25519-v1.key" }

    /// Load or create the install's Ed25519 key pair. Test bundle (or forced) → process-ephemeral (never
    /// persisted). Production → a 0600 file under ~/.mythos/keys so the pinned public key survives runs.
    /// FAIL-CLOSED on load: an existing file MUST be a trustworthy 32-byte, 0600, owner-only regular file or
    /// this THROWS — never silently regenerated (a silent re-key would rotate the guest's pinned key away).
    static func currentKeyPair() throws -> MythosCrypto.Ed25519KeyPair {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let pair = cachedPair { return pair }

        if keyDirectoryOverrideForTesting == nil,
           forceEphemeral || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let ephemeral = MythosCrypto.ed25519GenerateKeyPair()
            cachedPair = ephemeral
            return ephemeral
        }
        // Fail-closed on an insecure key directory for BOTH load and create — an existing key under a
        // group/world-writable or non-owner-owned ~/.mythos/keys must never be trusted.
        try validateKeyDirectorySecure()
        if FileManager.default.fileExists(atPath: keyPath) {
            let priv = try loadPrivateKeyRaw()          // throws on bad perms / wrong size — no silent re-key
            let pair = try derivePair(privateRaw: priv)
            cachedPair = pair
            return pair
        }
        let fresh = MythosCrypto.ed25519GenerateKeyPair()
        // Exclusive create — if the file appeared between the existence check and here (race), do NOT
        // overwrite it: fall through to the fail-closed loader and use whatever is on disk (or throw if it's
        // untrustworthy). Only a genuinely-new key is derived from the freshly-written bytes.
        let created = try storePrivateKeyRaw(fresh.privateRaw)
        if !created {
            let priv = try loadPrivateKeyRaw()
            let pair = try derivePair(privateRaw: priv)
            cachedPair = pair
            return pair
        }
        // Read back through the fail-closed loader so we never trust bytes we couldn't persist correctly.
        let reloaded = try loadPrivateKeyRaw()
        guard reloaded == fresh.privateRaw else { throw HostSnapshotSignerError.keyReadFailed }
        cachedPair = fresh
        return fresh
    }

    /// Rebuild the public half from a raw private key (validating the private bytes in the process). Uses
    /// swift-crypto directly — the SAME primitive MythosCrypto.ed25519GenerateKeyPair uses to derive the
    /// public key — so no new crypto is rolled here; we only recover the public half of a persisted key.
    private static func derivePair(privateRaw: Data) throws -> MythosCrypto.Ed25519KeyPair {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateRaw) else {
            throw HostSnapshotSignerError.keyReadFailed
        }
        return MythosCrypto.Ed25519KeyPair(privateRaw: privateRaw, publicRaw: key.publicKey.rawRepresentation)
    }

    /// Read an EXISTING key file, fail-closed. Exactly 32 bytes, owned by us, a regular file, and NOT
    /// accessible by group/other (perms & 0o077 == 0) — mirrors ForgeSeal.loadKeyRaw's checks. Uses
    /// O_NOFOLLOW so a symlink planted at the path is refused, not followed.
    private static func loadPrivateKeyRaw() throws -> Data {
        let fd = open(keyPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw HostSnapshotSignerError.keyReadFailed }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              st.st_uid == geteuid(),
              st.st_size == off_t(keyByteCount) else { throw HostSnapshotSignerError.keyReadFailed }
        guard st.st_mode & mode_t(0o077) == 0 else { throw HostSnapshotSignerError.keyInsecurePermissions }
        var data = Data(count: keyByteCount)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard ok else { throw HostSnapshotSignerError.keyReadFailed }
        return data
    }

    /// Create the key with atomic-exclusive, no-follow, owner-only semantics. Returns true if THIS call
    /// created the file, false if it already existed (EEXIST) — the caller then falls through to the
    /// fail-closed loader and never overwrites an existing key. Throws on any other write failure.
    ///
    /// Hardened over the old `FileManager.createFile` (which lacks O_EXCL/O_NOFOLLOW): a symlink or a
    /// pre-existing file at the path can't be silently followed/clobbered, the key directory is validated to
    /// be owner-owned and not group/world-writable BEFORE creation, and the bytes are fsync'd to disk.
    @discardableResult
    private static func storePrivateKeyRaw(_ raw: Data) throws -> Bool {
        try? FileManager.default.createDirectory(atPath: keyDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try validateKeyDirectorySecure()   // fail-closed if the dir is not owner-owned / is group/world-writable
        let fd = open(keyPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd < 0 {
            if errno == EEXIST { return false }   // someone created it first — don't overwrite; loader takes over
            throw HostSnapshotSignerError.keyWriteFailed
        }
        defer { close(fd) }
        let ok = raw.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> Bool in
            guard let base = rawBuf.baseAddress else { return false }
            var written = 0
            let total = rawBuf.count
            while written < total {
                let n = write(fd, base.advanced(by: written), total - written)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { return false }
                written += n
            }
            return true
        }
        guard ok else { throw HostSnapshotSignerError.keyWriteFailed }
        guard fsync(fd) == 0 else { throw HostSnapshotSignerError.keyWriteFailed }
        return true
    }

    /// Validate that the key DIRECTORY is owner-owned and not group/world-writable before we create a key in
    /// it. A dir another user can write is a vector to pre-plant or swap the key file — fail closed.
    private static func validateKeyDirectorySecure() throws {
        let fd = open(keyDir, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard fd >= 0 else { throw HostSnapshotSignerError.keyWriteFailed }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              st.st_uid == geteuid() else { throw HostSnapshotSignerError.keyInsecurePermissions }
        // No group/other WRITE bit (0o022) may be set on the key directory.
        guard st.st_mode & mode_t(0o022) == 0 else { throw HostSnapshotSignerError.keyInsecurePermissions }
    }

    // MARK: - Test hooks

    /// FORCE a process-ephemeral key pair (tests never write ~/.mythos, deterministic per call).
    public static func forceEphemeralKeyForTesting() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        forceEphemeral = true
        keyDirectoryOverrideForTesting = nil
        cachedPair = MythosCrypto.ed25519GenerateKeyPair()
    }

    /// Clear cache + all forced/override state so a FILE-path test can't leak into the next test.
    public static func resetCacheForTesting() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedPair = nil
        forceEphemeral = false
        keyDirectoryOverrideForTesting = nil
    }
}

public enum HostSnapshotSignerError: Error, Sendable, Equatable {
    case keyReadFailed, keyWriteFailed, keyInsecurePermissions
}
