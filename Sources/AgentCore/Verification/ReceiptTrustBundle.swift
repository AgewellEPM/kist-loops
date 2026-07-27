import Foundation

/// SIGNED TRUST BUNDLE — the distributable issuer-set. Today a verifier pins each issuer public key by hand
/// (`ReceiptIssuerKeyStore`); that doesn't scale to an org rotating issuers across many repos/CIs. A trust bundle
/// inverts it: an org has ONE long-lived ROOT Ed25519 key, pins only the ROOT public key on each verifier, and
/// SIGNS a bundle listing all its current issuer public keys (+ revocations). Rotating an issuer = re-issue the
/// bundle; no verifier reconfig. The bundle can be committed to the repo (`.kist/trust-bundle.json`) because it's
/// only trusted after its signature verifies against a PINNED root — an attacker can't forge the root signature.
///
/// Same unforgeability shape as `ReceiptAttestation` / `SkillAttestation`: `VerifiedBundle`'s init is
/// `fileprivate`, so only `TrustBundleVerifier.verify` (this file) mints one, and only after the root signature
/// checks out. FAIL CLOSED: no pinned root ⇒ every bundle is `.unknownRoot`.

/// The issuer set an org vouches for, as of `issuedAtEpoch`. `issuers` map keyID → base64 Ed25519 public key;
/// `revoked` map keyID → burned pubkey fingerprint (same material-scoped revocation as the local store).
public struct TrustBundle: Codable, Equatable, Sendable {
    public let issuers: [String: String]
    public let revoked: [String: String]
    public let rootKeyID: String            // which root this bundle is signed under (defeats cross-root reuse)
    public let issuedAtEpoch: Double
    public let note: String

    public init(issuers: [String: String], revoked: [String: String], rootKeyID: String,
                issuedAtEpoch: Double, note: String = "") {
        self.issuers = issuers; self.revoked = revoked; self.rootKeyID = rootKeyID
        self.issuedAtEpoch = issuedAtEpoch; self.note = note
    }

    /// Canonical bytes the root signs (excludes the signature). Deterministic sorted-key JSON.
    public func canonicalPayload() -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data()
    }
}

/// A bundle + its detached Ed25519 signature by the root key. This is what's distributed / committed.
public struct SignedTrustBundle: Codable, Equatable, Sendable {
    public let bundle: TrustBundle
    public let signatureB64: String
    public init(bundle: TrustBundle, signatureB64: String) {
        self.bundle = bundle; self.signatureB64 = signatureB64
    }
    public func canonicalBytes() -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data()
    }
    public static func make(bundle: TrustBundle, rootPrivateKeyRaw: Data) throws -> SignedTrustBundle {
        let sig = try MythosCrypto.ed25519Sign(message: bundle.canonicalPayload(), privateKeyRaw: rootPrivateKeyRaw)
        return SignedTrustBundle(bundle: bundle, signatureB64: sig.base64EncodedString())
    }
}

/// A bundle that passed root verification. `fileprivate` init ⇒ only `TrustBundleVerifier` mints it.
public struct VerifiedBundle: Equatable, Sendable {
    public let bundle: TrustBundle
    public let rootKeyID: String
    fileprivate init(bundle: TrustBundle, rootKeyID: String) { self.bundle = bundle; self.rootKeyID = rootKeyID }

    /// The EFFECTIVE issuer trusted-keys from this verified bundle: issuers minus anything the bundle itself
    /// revokes (by keyID or by burned fingerprint). Ready to hand to `ReceiptAttestationVerifier`.
    public func trustedIssuerKeys() -> [ReceiptAttestationVerifier.TrustedKey] {
        let burned = Set(bundle.revoked.values.filter { !$0.isEmpty })
        return bundle.issuers.compactMap { kv in
            if bundle.revoked[kv.key] != nil { return nil }
            if let fp = ReceiptIssuerKeyStore.fingerprint(kv.value), burned.contains(fp) { return nil }
            return ReceiptAttestationVerifier.TrustedKey(keyID: kv.key, publicKeyB64: kv.value)
        }
    }
}

/// Verifies a `SignedTrustBundle` against PINNED root Ed25519 public keys. Holds ONLY root public keys.
/// FAIL CLOSED: no pinned root ⇒ `.unknownRoot`.
public struct TrustBundleVerifier: Sendable {
    private let roots: [String: Data]   // rootKeyID → raw public key (validated at init)

    public init(trustedRoots: [ReceiptAttestationVerifier.TrustedKey]) {
        var decoded: [String: Data] = [:]
        for r in trustedRoots {
            guard let raw = Data(base64Encoded: r.publicKeyB64), MythosCrypto.ed25519ValidPublicKey(raw) else { continue }
            decoded[r.keyID] = raw
        }
        self.roots = decoded
    }
    public var isEmpty: Bool { roots.isEmpty }

    public enum Verification: Equatable {
        case valid(VerifiedBundle)
        case unknownRoot     // no pinned root matches bundle.rootKeyID
        case badSignature    // pinned root found, signature did not verify
        case malformed       // signature not canonical / wrong length
        case rootMismatch    // signature valid but bundle names a different rootKeyID than signed under
    }

    public func verify(_ signed: SignedTrustBundle) -> Verification {
        guard let pubRaw = roots[signed.bundle.rootKeyID] else { return .unknownRoot }
        guard let sig = Data(base64Encoded: signed.signatureB64),
              sig.count == 64, sig.base64EncodedString() == signed.signatureB64 else { return .malformed }
        guard MythosCrypto.ed25519Verify(signature: sig, message: signed.bundle.canonicalPayload(),
                                         publicKeyRaw: pubRaw) else { return .badSignature }
        // rootKeyID is inside the SIGNED payload, so a valid signature already binds it; this is belt-and-suspenders.
        guard roots[signed.bundle.rootKeyID] != nil else { return .rootMismatch }
        return .valid(VerifiedBundle(bundle: signed.bundle, rootKeyID: signed.bundle.rootKeyID))
    }
}
