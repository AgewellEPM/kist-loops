import Foundation

/// The user's pinned SKILL PUBLISHER public keys: `~/.config/kist/skill-publishers.json`, mapping a
/// publisher keyID → its base64 Ed25519 public key. A signed skill (`SKILL.md.sig`) is trusted only when
/// its `publisherKeyID` is pinned HERE and the signature checks out (see `SkillTrustResolver`).
///
/// Publisher trust is USER-GLOBAL, not per-project: pinning "acme-corp" once trusts acme-signed skills in
/// every project. (The hash-pin tier — `SkillTrustStore` — is per-project by design; these two scopes are
/// deliberately different, so they are separate stores.)
///
/// Stored in the user's home, NEVER in the repo — same threat model as the trust store: a cloned repo
/// must not be able to ship its own "trusted publisher" and self-authorize. Owner-only, symlink-rejected,
/// size-capped on read (via `SecureUserJSON`). FAIL CLOSED: unreadable/insecure ⇒ no keys ⇒ no publisher
/// tier (skills fall back to the hash-pin tier / untrusted).
public struct SkillPublisherKeyStore: Sendable, Equatable {
    public static let displayPath = "~/.config/kist/skill-publishers.json"

    private var keys: [String: String]   // keyID → base64 Ed25519 public key

    public init(keys: [String: String] = [:]) { self.keys = keys }

    /// The pinned keys as verifier-ready trusted keys. `SkillSignatureVerifier.init` re-validates each
    /// (bad base64 / non-Ed25519 dropped), so this can hand them over as-is.
    public func trustedKeys() -> [SkillSignatureVerifier.TrustedKey] {
        keys.map { SkillSignatureVerifier.TrustedKey(keyID: $0.key, publicKeyB64: $0.value) }
    }

    public var allPinned: [String: String] { keys }
    public func publicKey(for keyID: String) -> String? { keys[keyID] }

    /// Pin a publisher key (trust it). Returns a new store; persistence is the caller's job.
    public func pinning(keyID: String, publicKeyB64: String) -> SkillPublisherKeyStore {
        var copy = keys; copy[keyID] = publicKeyB64; return SkillPublisherKeyStore(keys: copy)
    }

    public func unpinning(keyID: String) -> SkillPublisherKeyStore {
        var copy = keys; copy[keyID] = nil; return SkillPublisherKeyStore(keys: copy)
    }

    // MARK: Persistence (USER-LEVEL, never inside the repo)

    public static func userStorePath() -> String? {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else { return nil }
        return home + "/.config/kist/skill-publishers.json"
    }

    private struct Doc: Codable { var version: Int; var publishers: [String: String] }

    /// The pinned publisher keys, read from the user-level store. Missing/unreadable/insecure ⇒ empty
    /// (fail-safe: no publisher trusted). `storePath` overrides the location (tests inject a temp path).
    public static func load(storePath: String? = nil) -> SkillPublisherKeyStore {
        guard let path = storePath ?? userStorePath() else { return SkillPublisherKeyStore() }
        switch SecureUserJSON.read(path) {
        case .absent:
            return SkillPublisherKeyStore()
        case .insecure:
            warnOnce("the publisher key store at \(displayPath) is not a private regular file (symlink / "
                + "wrong owner / group- or world-accessible / oversized) — ignoring it; no publisher is trusted")
            return SkillPublisherKeyStore()
        case .unreadable:
            warnOnce("the publisher key store at \(displayPath) exists but is unreadable — ignoring it; "
                + "no publisher is trusted until you re-pin")
            return SkillPublisherKeyStore()
        case .ok(let data):
            guard let doc = try? JSONDecoder().decode(Doc.self, from: data) else {
                warnOnce("the publisher key store at \(displayPath) is corrupt — ignoring it; no publisher is trusted")
                return SkillPublisherKeyStore()
            }
            return SkillPublisherKeyStore(keys: doc.publishers)
        }
    }

    /// Persist the pinned publisher keys owner-only (0600).
    public func save(storePath: String? = nil) throws {
        guard let path = storePath ?? Self.userStorePath() else {
            throw NSError(domain: "SkillPublisherKeyStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "HOME is not set; cannot locate the publisher key store"])
        }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        let doc = Doc(version: 1, publishers: keys)
        let data = try JSONEncoder().encode(doc)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private static let warnLock = NSLock()
    nonisolated(unsafe) private static var warned = false
    private static func warnOnce(_ message: String) {
        warnLock.lock(); defer { warnLock.unlock() }
        guard !warned else { return }
        warned = true
        FileHandle.standardError.write(Data("kist: \(message)\n".utf8))
    }
}
