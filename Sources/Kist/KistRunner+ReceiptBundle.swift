import Foundation
import AgentCore

/// CLI for SIGNED TRUST BUNDLES (the distributable issuer-set):
///   kist --trust-root <keyID> <pubB64>   → pin a TRUST ROOT public key (verifiers trust bundles it signs)
///   kist --list-roots                    → show pinned trust roots
///   kist --make-bundle --root-key <priv> [--bundle-out <path>]
///                                        → sign the local issuer set (+ revocations) into a bundle
///   kist --verify-bundle <path>          → verify a signed bundle against pinned roots
/// An org pins ONE root per verifier, then rotates issuers by re-issuing the bundle — no per-verifier reconfig.
extension KistRunner {

    static func runTrustRoot(_ opts: KistOptions) -> Int32 {
        guard let (keyID, pubB64) = opts.trustRoot else { rcptStderr("usage: kist --trust-root <keyID> <pubB64>"); return 2 }
        guard let raw = Data(base64Encoded: pubB64), MythosCrypto.ed25519ValidPublicKey(raw) else {
            rcptStderr("✗ not a valid Ed25519 public key"); return 1
        }
        do { try ReceiptRootKeyStore.load().pinning(keyID: keyID, publicKeyB64: pubB64).save()
             rcptStderr("pinned trust root '\(keyID)'. Bundles it signs now distribute trusted issuers."); return 0
        } catch { rcptStderr("could not save root store: \(error)"); return 1 }
    }

    static func runListRoots(_ opts: KistOptions) -> Int32 {
        let pinned = ReceiptRootKeyStore.load().allPinned
        if pinned.isEmpty {
            print("no trust roots pinned. Pin one with: kist --trust-root <keyID> <pubB64>")
        } else {
            print("pinned trust roots (\(ReceiptRootKeyStore.displayPath)):")
            for (id, pub) in pinned.sorted(by: { $0.key < $1.key }) { print("  \(id)  \(pub)") }
        }
        return 0
    }

    static func runMakeBundle(_ opts: KistOptions) -> Int32 {
        guard let priv = loadRootPrivateKey(opts) else { return 1 }
        let issuerStore = ReceiptIssuerKeyStore.load()
        // Allow a REVOCATION-ONLY bundle (issuers empty but revocations present) — publishing "issuer X is revoked"
        // is a valid, important bundle even when it leaves no active issuers.
        guard !(issuerStore.allPinned.isEmpty && issuerStore.revokedMap.isEmpty) else {
            rcptStderr("nothing to bundle — pin issuers with `kist --trust-issuer` (or revoke one) first"); return 1
        }
        let bundle = TrustBundle(issuers: issuerStore.allPinned, revoked: issuerStore.revokedMap,
                                 rootKeyID: priv.keyID, issuedAtEpoch: Date().timeIntervalSince1970,
                                 note: "kist --make-bundle")
        do {
            let signed = try SignedTrustBundle.make(bundle: bundle, rootPrivateKeyRaw: priv.raw)
            let outPath = opts.bundleOut ?? (opts.project as NSString).appendingPathComponent(".kist/trust-bundle.json")
            try? FileManager.default.createDirectory(atPath: (outPath as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try signed.canonicalBytes().write(to: URL(fileURLWithPath: outPath))
            print("signed trust bundle (\(bundle.issuers.count) issuer(s), \(bundle.revoked.count) revoked) "
                + "as root '\(priv.keyID)' → \(outPath)")
            print("Commit it; verifiers that pinned '\(priv.keyID)' with --trust-root will honor its issuers.")
            return 0
        } catch { rcptStderr("bundle signing failed (bad root key?): \(error)"); return 1 }
    }

    static func runVerifyBundle(_ opts: KistOptions) -> Int32 {
        guard let path = opts.verifyBundle else { return 2 }
        guard let data = FileManager.default.contents(atPath: path),
              let signed = try? JSONDecoder().decode(SignedTrustBundle.self, from: data) else {
            rcptStderr("✗ could not read a signed trust bundle from \(path)"); return 1
        }
        let verifier = TrustBundleVerifier(trustedRoots: ReceiptRootKeyStore.load().trustedKeys())
        if verifier.isEmpty { rcptStderr("✗ no trust root pinned — pin one with `kist --trust-root` to verify bundles"); return 1 }
        switch verifier.verify(signed) {
        case .valid(let vb):
            let issuers = vb.trustedIssuerKeys().map { $0.keyID }.sorted()
            print("✓ bundle valid — signed by pinned root '\(vb.rootKeyID)'. Trusted issuers: \(issuers.joined(separator: ", "))")
            return 0
        case .unknownRoot: rcptStderr("✗ bundle's root '\(signed.bundle.rootKeyID)' is not a pinned trust root"); return 1
        case .badSignature: rcptStderr("✗ bundle signature does not verify against the pinned root"); return 1
        case .malformed: rcptStderr("✗ bundle signature is malformed / non-canonical"); return 1
        case .rootMismatch: rcptStderr("✗ bundle root mismatch"); return 1
        }
    }

    /// Load a ROOT private key (base64 of raw Ed25519 private key). keyID derived from filename `issuer-<id>.key`
    /// / `root-<id>.key` (a root key is generated the same way as an issuer key).
    private static func loadRootPrivateKey(_ opts: KistOptions) -> (raw: Data, keyID: String)? {
        guard let path = opts.rootKeyPath else {
            rcptStderr("--make-bundle needs --root-key <private-key-file> (see `kist --gen-issuer-key <rootID>`)"); return nil
        }
        guard let s = try? String(contentsOfFile: path, encoding: .utf8),
              let raw = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            rcptStderr("could not read a base64 Ed25519 private key from \(path)"); return nil
        }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var keyID = stem
        for prefix in ["issuer-", "root-"] where stem.hasPrefix(prefix) { keyID = String(stem.dropFirst(prefix.count)) }
        return (raw, keyID.isEmpty ? "root" : keyID)
    }
}
