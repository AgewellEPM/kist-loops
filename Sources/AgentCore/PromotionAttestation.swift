import Foundation

/// THE EXTERNAL TRUST TIER — the "can't mint your own approval" core, enforced by the compiler.
///
/// The internal tier (FleetSignoffLedger + ForgeSeal HMAC) proves "the captain verified this work on THIS
/// machine." That is the right model for joining signed branches onto an integration branch. But the
/// captain is the BUILDER — it must not be the sole authority that says "ship this to main." So the final
/// promotion (integration → main) requires an EXTERNAL holder — whose Ed25519 PRIVATE key Mythos never has
/// — to have SIGNED an approval for THIS exact integration build.
///
/// THE UNFORGEABILITY GUARANTEE: a `VerifiedApproval` only exists if an external signature checks out
/// against a PINNED public key. `VerifiedApproval.init` is `fileprivate`, so the ONLY code that can mint
/// one is `AttestationVerifier.verify` (same file), and it does so ONLY after `ed25519Verify` returns
/// true. The promotion gate requires a VerifiedApproval — so there is NO path that promotes without a
/// passed external signature. The builder cannot forge approval; it can't even name the constructor.
///
/// FAIL CLOSED: with no pinned keys, EVERYTHING is `.unknownKey`. Distrust is the default; trust is
/// something an operator explicitly pins. Ported from TinkySDR's Conscience (Stage 3), genericized from a
/// PHI consequential-outcome to a build-promotion approval; CryptoKit → MythosCrypto (swift-crypto).
/// LABEL: PROTOTYPE.

/// An external holder's claim that a specific integration build is approved for promotion to main. NO
/// builder secret here — Mythos signs nothing; the holder does, with a key Mythos never possesses.
public struct PromotionApproval: Codable, Equatable, Sendable {
    public let buildID: String           // the integration build this approval is bound to
    public let approverKeyID: String     // which pinned external holder attests it
    public let nonce: String             // replay protection (inside the signed payload)
    public let approvedAtEpoch: Double
    public let note: String              // free-text provenance ("reviewed PR #42") — advisory

    public init(buildID: String, approverKeyID: String, nonce: String, approvedAtEpoch: Double, note: String = "") {
        self.buildID = buildID; self.approverKeyID = approverKeyID; self.nonce = nonce
        self.approvedAtEpoch = approvedAtEpoch; self.note = note
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case buildID, approverKeyID, nonce, approvedAtEpoch, note
    }

    /// Canonical, stable-ordered bytes the external holder signs (excludes the signature, which lives on
    /// SignedApproval). Deterministic: sortedKeys gives a fixed key order so an equal value → equal bytes.
    public func canonicalPayload() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(self) else {
            fatalError("PromotionApproval canonical encode must not fail")
        }
        return data
    }
}

/// An approval + its detached Ed25519 signature (over `approval.canonicalPayload()`).
public struct SignedApproval: Codable, Equatable, Sendable {
    public let approval: PromotionApproval
    public let signatureB64: String
    public init(approval: PromotionApproval, signatureB64: String) {
        self.approval = approval; self.signatureB64 = signatureB64
    }

    /// Helper for an external holder (or a test): sign an approval with a raw Ed25519 private key.
    public static func make(approval: PromotionApproval, privateKeyRaw: Data) throws -> SignedApproval {
        let sig = try MythosCrypto.ed25519Sign(message: approval.canonicalPayload(), privateKeyRaw: privateKeyRaw)
        return SignedApproval(approval: approval, signatureB64: sig.base64EncodedString())
    }
}

/// A VERIFIED approval — a `SignedApproval` whose external Ed25519 signature passed `AttestationVerifier`.
/// Its initializer is `fileprivate`, so ONLY `AttestationVerifier` (this file) can mint one. The promotion
/// gate requires this type, so nothing promotes without passing external-signature verification.
public struct VerifiedApproval: Equatable, Sendable {
    public let signed: SignedApproval
    public let keyID: String
    // fileprivate: ONLY the verifier (same file) may construct this — the compile-time root of the
    // unforgeability guarantee. No other file, including the fleet/builder, can name this initializer.
    fileprivate init(signed: SignedApproval, keyID: String) {
        self.signed = signed; self.keyID = keyID
    }
}

/// Verifies a `SignedApproval` against PINNED external Ed25519 public keys. Mythos holds ONLY public keys.
/// FAIL CLOSED: with no trusted keys, every input is `.unknownKey`.
public struct AttestationVerifier: Sendable {

    /// A pinned external public key — the raw 32-byte Ed25519 public key, base64-encoded.
    public struct TrustedKey: Equatable, Sendable {
        public let keyID: String
        public let publicKeyB64: String
        public init(keyID: String, publicKeyB64: String) { self.keyID = keyID; self.publicKeyB64 = publicKeyB64 }
    }

    /// keyID → raw public key bytes, validated once at init. A pin whose base64/raw-rep is invalid is
    /// dropped (not trusted) — fail closed, never crash over a bad operator pin.
    private let keys: [String: Data]

    public init(trusted: [TrustedKey]) {
        var decoded: [String: Data] = [:]
        for key in trusted {
            // A pin whose base64 is invalid OR whose bytes aren't a well-formed Ed25519 public key is
            // DROPPED (not trusted) — caught at setup, fail closed, never crashes over a bad operator pin.
            guard let raw = Data(base64Encoded: key.publicKeyB64), MythosCrypto.ed25519ValidPublicKey(raw)
            else { continue }
            decoded[key.keyID] = raw
        }
        self.keys = decoded
    }

    /// True when no usable trusted key is pinned (then `verify` returns `.unknownKey` for everything).
    public var isEmpty: Bool { keys.isEmpty }

    public enum Verification: Equatable {
        case valid(VerifiedApproval)
        case unknownKey   // no pinned key matches approverKeyID
        case badSignature // pinned key found, signature did not verify
        case malformed    // signature base64 could not be decoded
    }

    /// Verify order (FAIL CLOSED at each gate): pinned key for approverKeyID (else .unknownKey) → decode
    /// the signature base64 (else .malformed) → Ed25519 check over the EXACT canonical bytes (else
    /// .badSignature) → only then mint `.valid(VerifiedApproval)` (the ONLY mint site).
    public func verify(_ signed: SignedApproval) -> Verification {
        guard let pubRaw = keys[signed.approval.approverKeyID] else { return .unknownKey }
        guard let sig = Data(base64Encoded: signed.signatureB64) else { return .malformed }
        guard MythosCrypto.ed25519Verify(signature: sig, message: signed.approval.canonicalPayload(),
                                         publicKeyRaw: pubRaw) else { return .badSignature }
        return .valid(VerifiedApproval(signed: signed, keyID: signed.approval.approverKeyID))
    }
}
