import Foundation

/// THE ISSUER-SIGNATURE TRUST TIER for Verification Receipts — the cross-org upgrade that removes the symmetric
/// HMAC seal's "whoever holds the key can mint anything" limit (docs/kist/RECEIPT_THREAT_MODEL.md). The HMAC seal
/// says "someone in this trust domain (who holds KIST_RECEIPT_KEY) vouches for this change"; an ISSUER SIGNATURE
/// says "an issuer whose PUBLIC key this verifier PINNED signed this exact change as passing." The verifier holds
/// ONLY public keys; the issuer signs with a private key the verifier never possesses — so an attacker who steals
/// the HMAC key still cannot forge an issuer signature.
///
/// Structurally the Ed25519 sibling of `SkillAttestation` (the skill publisher tier) and `PromotionAttestation`
/// (the fleet deploy tier) — re-subjected from a skill/build approval to a RECEIPT approval bound to the exact
/// diff. THE UNFORGEABILITY GUARANTEE: a `VerifiedAttestation` exists only if a signature checks out against a
/// PINNED public key AND is bound to THIS change's diffDigest AND attests a `pass` verdict. Its init is
/// `fileprivate`, so the ONLY minting site is `ReceiptAttestationVerifier.verify` (same file).
///
/// FAIL CLOSED: with no pinned issuer keys, every input is `.unknownKey`. Distrust is the default.

/// An issuer's claim that a specific change (bound by its diffDigest) passed verification. NO verifier secret
/// here — the issuer signs with a key the verifier never has.
public struct ReceiptApproval: Codable, Equatable, Sendable {
    public let diffDigest: String        // the exact change this attests (defeats cross-change reuse)
    public let verdict: String           // the attested verdict; MUST be "pass" to admit (defeats fail-attest)
    public let issuerKeyID: String       // which pinned issuer key attests it
    public let nonce: String             // provenance/uniqueness (covered by the signature; revoke by unpinning)
    public let approvedAtEpoch: Double
    public let note: String              // free-text provenance ("acme security team") — advisory

    public init(diffDigest: String, verdict: String, issuerKeyID: String,
                nonce: String, approvedAtEpoch: Double, note: String = "") {
        self.diffDigest = diffDigest; self.verdict = verdict; self.issuerKeyID = issuerKeyID
        self.nonce = nonce; self.approvedAtEpoch = approvedAtEpoch; self.note = note
    }

    /// Canonical, stable-ordered bytes the issuer signs (excludes the signature, which lives on
    /// `AttestedReceipt`). Deterministic: sortedKeys → a fixed order so an equal value ⇒ equal bytes.
    public func canonicalPayload() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data()
    }
}

/// An approval + its detached Ed25519 signature (over `approval.canonicalPayload()`). Shipped as the receipt
/// sidecar `.kist/receipts/<digest>.sig.json`.
public struct AttestedReceipt: Codable, Equatable, Sendable {
    public let approval: ReceiptApproval
    public let signatureB64: String
    public init(approval: ReceiptApproval, signatureB64: String) {
        self.approval = approval; self.signatureB64 = signatureB64
    }

    /// Canonical on-disk bytes for the sidecar file — byte-for-byte authenticable, like the sealed receipt.
    public func canonicalBytes() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data()
    }

    /// Helper for an issuer (or a test): sign an approval with a raw Ed25519 private key.
    public static func make(approval: ReceiptApproval, privateKeyRaw: Data) throws -> AttestedReceipt {
        let sig = try MythosCrypto.ed25519Sign(message: approval.canonicalPayload(), privateKeyRaw: privateKeyRaw)
        return AttestedReceipt(approval: approval, signatureB64: sig.base64EncodedString())
    }
}

/// A VERIFIED attestation — an `AttestedReceipt` that passed `ReceiptAttestationVerifier`. Its initializer is
/// `fileprivate`, so ONLY the verifier (this file) can mint one — the compile-time root of unforgeability.
public struct VerifiedAttestation: Equatable, Sendable {
    public let attested: AttestedReceipt
    public let keyID: String
    fileprivate init(attested: AttestedReceipt, keyID: String) {
        self.attested = attested; self.keyID = keyID
    }
}

/// Verifies an `AttestedReceipt` against PINNED issuer Ed25519 public keys, bound to a change's diffDigest and
/// requiring a `pass` verdict. Holds ONLY public keys. FAIL CLOSED: with no trusted keys, every input is
/// `.unknownKey`.
public struct ReceiptAttestationVerifier: Sendable {

    /// A pinned issuer public key — the raw 32-byte Ed25519 public key, base64-encoded.
    public struct TrustedKey: Equatable, Sendable {
        public let keyID: String
        public let publicKeyB64: String
        public init(keyID: String, publicKeyB64: String) { self.keyID = keyID; self.publicKeyB64 = publicKeyB64 }
    }

    /// keyID → raw public key bytes, validated once at init. A pin whose base64/raw-rep is invalid is dropped
    /// (never trusted, never a crash over a bad operator pin).
    private let keys: [String: Data]

    public init(trusted: [TrustedKey]) {
        var decoded: [String: Data] = [:]
        for key in trusted {
            guard let raw = Data(base64Encoded: key.publicKeyB64), MythosCrypto.ed25519ValidPublicKey(raw)
            else { continue }
            decoded[key.keyID] = raw
        }
        self.keys = decoded
    }

    /// True when no usable trusted key is pinned (then the guard stays on the HMAC-only tier).
    public var isEmpty: Bool { keys.isEmpty }

    public enum Verification: Equatable {
        case valid(VerifiedAttestation)
        case unknownKey        // no pinned key matches issuerKeyID
        case badSignature      // pinned key found, signature did not verify
        case malformed         // signature base64 could not be decoded
        case digestMismatch    // signature valid but for a DIFFERENT change
        case notPass           // signature valid but attests a non-pass verdict
    }

    /// Verify order (FAIL CLOSED at each gate): pinned key for issuerKeyID (else .unknownKey) → decode the
    /// signature base64 (else .malformed) → Ed25519 check over the EXACT canonical payload (else .badSignature)
    /// → the approval names THIS change's digest (else .digestMismatch) → the approval attests `pass` (else
    /// .notPass) → only then mint `.valid` (the ONLY mint site). `diffDigest` is the CURRENT change being gated,
    /// so a signature for a benign change can't authorize a different one.
    public func verify(_ attested: AttestedReceipt, diffDigest: String) -> Verification {
        guard let pubRaw = keys[attested.approval.issuerKeyID] else { return .unknownKey }
        guard let sig = Data(base64Encoded: attested.signatureB64) else { return .malformed }
        // CANONICAL encoding only: an Ed25519 signature is exactly 64 bytes, and the base64 must be the canonical
        // form (no extra padding / whitespace variants that decode to the same bytes) — else `signatureB64` is a
        // covert byte channel in an otherwise byte-canonical sidecar (Codex gate7 LOW).
        guard sig.count == 64, sig.base64EncodedString() == attested.signatureB64 else { return .malformed }
        guard MythosCrypto.ed25519Verify(signature: sig, message: attested.approval.canonicalPayload(),
                                         publicKeyRaw: pubRaw) else { return .badSignature }
        guard attested.approval.diffDigest == diffDigest else { return .digestMismatch }
        guard attested.approval.verdict == ReceiptVerdict.pass.rawValue else { return .notPass }
        return .valid(VerifiedAttestation(attested: attested, keyID: attested.approval.issuerKeyID))
    }
}
