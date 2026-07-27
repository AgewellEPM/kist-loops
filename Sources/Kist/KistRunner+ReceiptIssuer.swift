import Foundation
import AgentCore

/// CLI for the receipt ISSUER-SIGNATURE tier (docs/kist/RECEIPT_THREAT_MODEL.md — the cross-org Ed25519 upgrade):
///   kist --gen-issuer-key <keyID>        → generate an Ed25519 issuer keypair (private 0600 + public base64)
///   kist --trust-issuer <keyID> <pubB64> → pin an issuer PUBLIC key (verifiers trust its signatures)
///   kist --list-issuers                  → show pinned issuer keys
///   kist --sign-receipt <digest|latest> --issuer-key <priv> → sign a stored receipt's change → sidecar
/// The verifier (guard/ci-guard) holds only PUBLIC keys; the issuer signs with a private key it never has.
extension KistRunner {

    static func runGenIssuerKey(_ opts: KistOptions) -> Int32 {
        guard let keyID = opts.genIssuerKey, !keyID.isEmpty else { rcptStderr("usage: kist --gen-issuer-key <keyID>"); return 2 }
        let kp = MythosCrypto.ed25519GenerateKeyPair()
        // Write the PRIVATE key to a 0600 file (base64) the issuer keeps secret; print the PUBLIC key to pin.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = (home as NSString).appendingPathComponent(".config/kist")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let privPath = (dir as NSString).appendingPathComponent("issuer-\(keyID).key")
        let privB64 = kp.privateRaw.base64EncodedString()
        guard FileManager.default.createFile(atPath: privPath, contents: Data(privB64.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            rcptStderr("could not write private key to \(privPath)"); return 1
        }
        print("issuer keypair '\(keyID)' generated.")
        print("  private key (KEEP SECRET, 0600): \(privPath)")
        print("  public key  (pin on verifiers):  \(kp.publicRaw.base64EncodedString())")
        print("Pin it where receipts are verified:  kist --trust-issuer \(keyID) <public-key>")
        return 0
    }

    static func runTrustIssuer(_ opts: KistOptions) -> Int32 {
        guard let (keyID, pubB64) = opts.trustIssuer else { rcptStderr("usage: kist --trust-issuer <keyID> <pubB64>"); return 2 }
        guard let raw = Data(base64Encoded: pubB64), MythosCrypto.ed25519ValidPublicKey(raw) else {
            rcptStderr("✗ not a valid Ed25519 public key (base64 of 32 raw bytes)"); return 1
        }
        let store = ReceiptIssuerKeyStore.load()
        guard !store.isRevoked(keyID) else {
            rcptStderr("✗ '\(keyID)' is REVOKED — refusing to re-pin a compromised key. "
                     + "Run `kist --unrevoke-issuer \(keyID)` first if this is intentional."); return 1
        }
        guard !store.isMaterialRevoked(publicKeyB64: pubB64) else {
            rcptStderr("✗ this public KEY MATERIAL was revoked (under another alias) — refusing to re-trust burned "
                     + "key bytes. Un-revoke the original keyID first, or rotate to fresh key material."); return 1
        }
        do {
            try store.pinning(keyID: keyID, publicKeyB64: pubB64).save()
            rcptStderr("pinned receipt issuer '\(keyID)'. Receipts it signs are now trusted by the guard/ci-guard.")
            return 0
        } catch { rcptStderr("could not save issuer store: \(error)"); return 1 }
    }

    static func runListIssuers(_ opts: KistOptions) -> Int32 {
        let store = ReceiptIssuerKeyStore.load()
        let pinned = store.allPinned
        if pinned.isEmpty {
            print("no receipt issuers pinned (issuer-signature tier inactive — guard is HMAC-only). "
                + "Pin one with: kist --trust-issuer <keyID> <pubB64>")
        } else {
            print("pinned receipt issuers (\(ReceiptIssuerKeyStore.displayPath)):")
            for (id, pub) in pinned.sorted(by: { $0.key < $1.key }) { print("  \(id)  \(pub)") }
        }
        let revoked = store.revokedKeyIDs.sorted()
        if !revoked.isEmpty { print("REVOKED (signatures rejected, not re-pinnable): \(revoked.joined(separator: ", "))") }
        return 0
    }

    static func runUnpinIssuer(_ opts: KistOptions) -> Int32 {
        guard let keyID = opts.unpinIssuer else { return 2 }
        do { try ReceiptIssuerKeyStore.load().unpinning(keyID: keyID).save()
             rcptStderr("unpinned issuer '\(keyID)' — its signatures are no longer trusted (re-pinnable later)."); return 0
        } catch { rcptStderr("could not save issuer store: \(error)"); return 1 }
    }

    static func runRevokeIssuer(_ opts: KistOptions) -> Int32 {
        guard let keyID = opts.revokeIssuer else { return 2 }
        do { try ReceiptIssuerKeyStore.load().revoking(keyID: keyID).save()
             rcptStderr("REVOKED issuer '\(keyID)' — its signatures are now rejected and it cannot be re-pinned "
                      + "until `--unrevoke-issuer \(keyID)`. Rotate: --gen-issuer-key <new> + --trust-issuer <new>."); return 0
        } catch { rcptStderr("could not save issuer store: \(error)"); return 1 }
    }

    static func runUnrevokeIssuer(_ opts: KistOptions) -> Int32 {
        guard let keyID = opts.unrevokeIssuer else { return 2 }
        do { try ReceiptIssuerKeyStore.load().unrevoking(keyID: keyID).save()
             rcptStderr("lifted revocation on '\(keyID)' — it can be pinned again with --trust-issuer."); return 0
        } catch { rcptStderr("could not save issuer store: \(error)"); return 1 }
    }

    static func runSignReceipt(_ opts: KistOptions) -> Int32 {
        let root = opts.project
        guard let priv = loadIssuerPrivateKey(opts) else { return 1 }
        // Resolve the target receipt digest: an explicit digest, or the change currently staged ("latest").
        let target = opts.signReceipt ?? "latest"
        let digest: String
        if target == "latest" || target.isEmpty {
            let (status, diff) = stagedDiffForSigning(root: root)
            guard status == 0, !diff.isEmpty else {
                rcptStderr("nothing staged to sign — stage the change (and run `kist --verify`) first, "
                         + "or pass an explicit digest: kist --sign-receipt <digest>"); return 2 }
            digest = ReceiptSubject.digest(ofDiff: diff)
        } else { digest = target }
        let store = ReceiptStore(projectRoot: root)
        guard let sealed = store.load(diffDigest: digest) else {
            rcptStderr("no stored receipt for digest \(digest.prefix(12))… — run `kist --verify` first"); return 1
        }
        guard sealed.receipt.verdict == .pass else {
            rcptStderr("refusing to sign a non-pass receipt (verdict '\(sealed.receipt.verdict.rawValue)')"); return 1
        }
        let approval = ReceiptApproval(diffDigest: digest, verdict: ReceiptVerdict.pass.rawValue,
                                       issuerKeyID: priv.keyID, nonce: newNonce(),
                                       approvedAtEpoch: Date().timeIntervalSince1970, note: "kist --sign-receipt")
        do {
            let attested = try AttestedReceipt.make(approval: approval, privateKeyRaw: priv.raw)
            guard store.saveAttestation(attested) else { rcptStderr("could not write the attestation sidecar"); return 1 }
            print("signed receipt \(digest.prefix(12))… as issuer '\(priv.keyID)' → .kist/receipts/\(digest).sig.json")
            print("Commit the sidecar with the change. Verifiers that pinned '\(priv.keyID)' will now trust it.")
            return 0
        } catch { rcptStderr("signing failed (bad private key?): \(error)"); return 1 }
    }

    // MARK: helpers

    /// Load the issuer private key: base64 of a raw Ed25519 private key, from --issuer-key <path>. The keyID is
    /// derived from the filename `issuer-<keyID>.key` when possible, else the file stem.
    private static func loadIssuerPrivateKey(_ opts: KistOptions) -> (raw: Data, keyID: String)? {
        guard let path = opts.issuerKeyPath else {
            rcptStderr("--sign-receipt needs --issuer-key <private-key-file> (see `kist --gen-issuer-key`)"); return nil
        }
        guard let s = try? String(contentsOfFile: path, encoding: .utf8),
              let raw = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            rcptStderr("could not read a base64 Ed25519 private key from \(path)"); return nil
        }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let keyID = stem.hasPrefix("issuer-") ? String(stem.dropFirst("issuer-".count)) : stem
        return (raw, keyID.isEmpty ? "issuer" : keyID)
    }

    private static func stagedDiffForSigning(root: String) -> (status: Int32, diff: String) {
        // Reuse the SAME stable flags + receipt exclusion the verify/guard digest uses, so the signed digest
        // matches the receipt's digest exactly.
        var args = stableDiffRangeFlags
        args.insert("--cached", at: args.firstIndex(of: "diff")! + 1)
        args.append(contentsOf: receiptPathExclusion)
        let r = gitRun(args, cwd: root)
        return (r.status, losslessString(r.data))
    }

    /// A random hex nonce (no Date/Math.random dependency issues — uses crypto random bytes).
    private static func newNonce() -> String {
        MythosCrypto.randomKey(byteCount: 12).map { String(format: "%02x", $0) }.joined()
    }
}
