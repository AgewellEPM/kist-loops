import Foundation

/// The verifier's pinned RECEIPT ISSUER public keys: `~/.config/kist/receipt-issuers.json`, mapping an issuer
/// keyID → its base64 Ed25519 public key. An issuer-signed receipt (`.kist/receipts/<digest>.sig.json`) is
/// trusted only when its `issuerKeyID` is pinned HERE and the signature checks out (see
/// `ReceiptAttestationVerifier`).
///
/// Issuer trust is USER/CI-GLOBAL, not per-project — pinning "acme-security" once trusts acme-signed receipts in
/// every repo the verifier gates. Stored in the user's home, NEVER in the repo (a cloned repo must not be able to
/// ship its own "trusted issuer" and self-authorize). Owner-only, symlink-rejected, size-capped via
/// `SecureUserJSON`. FAIL CLOSED: unreadable/insecure ⇒ no keys ⇒ the issuer tier is simply inactive (the guard
/// stays on the HMAC seal tier), and a `.sig.json` sidecar can never mint trust.
public struct ReceiptIssuerKeyStore: Sendable, Equatable {
    public static let displayPath = "~/.config/kist/receipt-issuers.json"

    private var keys: [String: String]     // keyID → base64 Ed25519 public key (ACTIVE pins)
    private var revoked: [String: String]  // revoked keyID → its pubkey FINGERPRINT ("" if unknown at revoke time)

    /// SHA-256 hex fingerprint of a base64 Ed25519 public key — identifies the KEY MATERIAL independent of the
    /// keyID alias, so revoking a compromised key can't be defeated by re-pinning the same bytes under a new name.
    public static func fingerprint(_ publicKeyB64: String) -> String? {
        guard let raw = Data(base64Encoded: publicKeyB64) else { return nil }
        return MythosCrypto.sha256(raw).map { String(format: "%02x", $0) }.joined()
    }

    /// The set of BURNED key-material fingerprints (from every revocation that captured one).
    private var burnedFingerprints: Set<String> { Set(revoked.values.filter { !$0.isEmpty }) }

    public init(keys: [String: String] = [:], revoked: [String: String] = [:]) {
        self.revoked = revoked
        let burned = Set(revoked.values.filter { !$0.isEmpty })
        // A key is dropped from the ACTIVE set if its keyID is revoked OR its material fingerprint is burned —
        // revocation wins by keyID AND by bytes (fail-closed against re-trusting a compromised key under any alias
        // or a stale pin merged back in).
        self.keys = keys.filter { kv in
            if revoked[kv.key] != nil { return false }
            if let fp = Self.fingerprint(kv.value), burned.contains(fp) { return false }
            return true
        }
    }

    /// The pinned keys as verifier-ready trusted keys (the verifier re-validates each; bad ones are dropped).
    /// Revoked keys are already excluded from `keys` by init, so they can never reach the verifier.
    public func trustedKeys() -> [ReceiptAttestationVerifier.TrustedKey] {
        keys.map { ReceiptAttestationVerifier.TrustedKey(keyID: $0.key, publicKeyB64: $0.value) }
    }

    public var allPinned: [String: String] { keys }
    public var revokedKeyIDs: Set<String> { Set(revoked.keys) }
    public var revokedMap: [String: String] { revoked }   // keyID → burned fingerprint (for bundling)
    public var isEmpty: Bool { keys.isEmpty }
    public func publicKey(for keyID: String) -> String? { keys[keyID] }
    public func isRevoked(_ keyID: String) -> Bool { revoked[keyID] != nil }
    /// True if this exact KEY MATERIAL has been burned by a revocation (under any alias).
    public func isMaterialRevoked(publicKeyB64: String) -> Bool {
        guard let fp = Self.fingerprint(publicKeyB64) else { return false }
        return burnedFingerprints.contains(fp)
    }

    /// Pin an issuer key. Refused (returns self unchanged) if the keyID is revoked OR the key MATERIAL is burned —
    /// so a compromised key can't be re-trusted under a new alias. Un-revoke first (a deliberate two-step).
    public func pinning(keyID: String, publicKeyB64: String) -> ReceiptIssuerKeyStore {
        guard revoked[keyID] == nil, !isMaterialRevoked(publicKeyB64: publicKeyB64) else { return self }
        var copy = keys; copy[keyID] = publicKeyB64
        return ReceiptIssuerKeyStore(keys: copy, revoked: revoked)
    }
    /// Remove a pin entirely (stop trusting; no compromise record). Re-pinnable later.
    public func unpinning(keyID: String) -> ReceiptIssuerKeyStore {
        var copy = keys; copy[keyID] = nil; return ReceiptIssuerKeyStore(keys: copy, revoked: revoked)
    }
    /// REVOKE a keyID (compromised): drop the active pin AND burn its key MATERIAL (fingerprint) so its signatures
    /// are rejected and neither the keyID nor the same bytes under a new alias can be re-pinned until un-revoked.
    public func revoking(keyID: String) -> ReceiptIssuerKeyStore {
        var copy = keys; let pub = copy[keyID]; copy[keyID] = nil
        var rev = revoked
        rev[keyID] = pub.flatMap { Self.fingerprint($0) } ?? ""   // capture the burned fingerprint when known
        return ReceiptIssuerKeyStore(keys: copy, revoked: rev)
    }
    /// Lift a revocation for a keyID — also un-burns its captured fingerprint (so the material can be pinned again).
    public func unrevoking(keyID: String) -> ReceiptIssuerKeyStore {
        var rev = revoked; rev[keyID] = nil
        return ReceiptIssuerKeyStore(keys: keys, revoked: rev)
    }

    /// Merge issuers + revocations from a VERIFIED trust bundle. LOCAL pins/revocations win (a bundle can't
    /// override a locally-pinned key's bytes or un-revoke a locally-burned key); the init re-applies the combined
    /// revocation filter (by keyID AND fingerprint), so a key revoked on EITHER side is dropped.
    public func addingBundle(issuers: [String: String], revoked bundleRevoked: [String: String]) -> ReceiptIssuerKeyStore {
        var k = keys
        for (id, pub) in issuers where k[id] == nil { k[id] = pub }
        var r = revoked
        for (id, fp) in bundleRevoked where r[id] == nil { r[id] = fp }
        return ReceiptIssuerKeyStore(keys: k, revoked: r)
    }

    // MARK: Persistence (USER/CI-LEVEL, never inside the repo)

    public static func userStorePath() -> String? {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else { return nil }
        return home + "/.config/kist/receipt-issuers.json"
    }

    // v3: `revoked` is keyID → burned pubkey fingerprint (material-scoped). Optional so a v1 store (no field)
    // loads clean; a corrupt/incompatible shape falls through to the fail-safe empty store in `load`.
    private struct Doc: Codable { var version: Int; var issuers: [String: String]; var revoked: [String: String]? }

    /// The pinned issuer keys, read from the user-level store. Missing/unreadable/insecure ⇒ empty (fail-safe).
    public static func load(storePath: String? = nil) -> ReceiptIssuerKeyStore {
        guard let path = storePath ?? userStorePath() else { return ReceiptIssuerKeyStore() }
        switch SecureUserJSON.read(path) {
        case .absent:
            return ReceiptIssuerKeyStore()
        case .insecure:
            warnOnce("the receipt issuer store at \(displayPath) is not a private regular file (symlink / wrong "
                + "owner / group- or world-accessible / oversized) — ignoring it; no issuer is trusted")
            return ReceiptIssuerKeyStore()
        case .unreadable:
            warnOnce("the receipt issuer store at \(displayPath) exists but is unreadable — ignoring it; "
                + "no issuer is trusted until you re-pin")
            return ReceiptIssuerKeyStore()
        case .ok(let data):
            guard let doc = try? JSONDecoder().decode(Doc.self, from: data) else {
                warnOnce("the receipt issuer store at \(displayPath) is corrupt — ignoring it; no issuer is trusted")
                return ReceiptIssuerKeyStore()
            }
            return ReceiptIssuerKeyStore(keys: doc.issuers, revoked: doc.revoked ?? [:])
        }
    }

    /// Persist the pinned issuer keys owner-only (0600), in a 0700 dir.
    public func save(storePath: String? = nil) throws {
        guard let path = storePath ?? Self.userStorePath() else {
            throw NSError(domain: "ReceiptIssuerKeyStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "HOME is not set; cannot locate the issuer store"])
        }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        let doc = Doc(version: 3, issuers: keys, revoked: revoked.isEmpty ? nil : revoked)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(doc)
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
