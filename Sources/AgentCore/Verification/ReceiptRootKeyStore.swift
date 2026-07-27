import Foundation

/// The verifier's pinned TRUST-ROOT public keys: `~/.config/kist/receipt-roots.json` (keyID → base64 Ed25519
/// public key). A signed trust bundle (`.kist/trust-bundle.json`) is trusted only when its `rootKeyID` is pinned
/// HERE and the root signature checks out (`TrustBundleVerifier`). Pinning a root once lets an org distribute and
/// rotate its whole issuer set via signed bundles — no per-issuer, per-verifier pinning.
///
/// Same storage discipline as the issuer store: user/CI-global, never in-repo, owner-only + symlink-rejected via
/// `SecureUserJSON`, fail-closed on any problem (⇒ no root ⇒ bundles are untrusted).
public struct ReceiptRootKeyStore: Sendable, Equatable {
    public static let displayPath = "~/.config/kist/receipt-roots.json"
    private var keys: [String: String]

    public init(keys: [String: String] = [:]) { self.keys = keys }

    public func trustedKeys() -> [ReceiptAttestationVerifier.TrustedKey] {
        keys.map { ReceiptAttestationVerifier.TrustedKey(keyID: $0.key, publicKeyB64: $0.value) }
    }
    public var allPinned: [String: String] { keys }
    public var isEmpty: Bool { keys.isEmpty }
    public func pinning(keyID: String, publicKeyB64: String) -> ReceiptRootKeyStore {
        var copy = keys; copy[keyID] = publicKeyB64; return ReceiptRootKeyStore(keys: copy)
    }
    public func unpinning(keyID: String) -> ReceiptRootKeyStore {
        var copy = keys; copy[keyID] = nil; return ReceiptRootKeyStore(keys: copy)
    }

    public static func userStorePath() -> String? {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else { return nil }
        return home + "/.config/kist/receipt-roots.json"
    }
    private struct Doc: Codable { var version: Int; var roots: [String: String] }

    public static func load(storePath: String? = nil) -> ReceiptRootKeyStore {
        guard let path = storePath ?? userStorePath() else { return ReceiptRootKeyStore() }
        switch SecureUserJSON.read(path) {
        case .absent: return ReceiptRootKeyStore()
        case .insecure, .unreadable:
            let msg = "kist: the trust-root store at \(displayPath) is not a private regular file or is "
                    + "unreadable — ignoring it; no root is trusted\n"
            FileHandle.standardError.write(Data(msg.utf8))
            return ReceiptRootKeyStore()
        case .ok(let data):
            guard let doc = try? JSONDecoder().decode(Doc.self, from: data) else { return ReceiptRootKeyStore() }
            return ReceiptRootKeyStore(keys: doc.roots)
        }
    }
    public func save(storePath: String? = nil) throws {
        guard let path = storePath ?? Self.userStorePath() else {
            throw NSError(domain: "ReceiptRootKeyStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "HOME is not set; cannot locate the root store"])
        }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(Doc(version: 1, roots: keys))
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
