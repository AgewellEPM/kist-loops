import Foundation

/// THE PUBLISHER-SIGNATURE TRUST TIER for skills — the "a distributed skill can't lie about who signed
/// it" core, enforced by the compiler. This is the Ed25519 sibling of the local hash-pin tier
/// (`SkillTrustStore`): the hash pin says "I (this user) reviewed these exact bytes"; a publisher
/// signature says "a publisher whose key this user PINNED signed these exact bytes for this skill."
/// A signed skill from a pinned publisher is trusted WITHOUT a prior local pin — that is the whole point
/// of signing for marketplace / shared / fleet-subproject skills.
///
/// Cloned verbatim in structure from `PromotionAttestation` (the fleet-promotion external-trust tier),
/// re-subjected from a build-promotion approval to a skill approval. Mythos holds ONLY publisher PUBLIC
/// keys; the publisher signs with a private key Mythos never possesses.
///
/// THE UNFORGEABILITY GUARANTEE: a `VerifiedSkill` exists only if a publisher signature checks out against
/// a PINNED public key AND is bound to this skill's name AND to these exact content bytes.
/// `VerifiedSkill.init` is `fileprivate`, so the ONLY code that can mint one is
/// `SkillSignatureVerifier.verify` (same file), and only after `ed25519Verify` returns true and both
/// bindings match. The trust resolver treats a `.valid` verdict — and nothing else — as trusted.
///
/// FAIL CLOSED: with no pinned publisher keys, EVERYTHING is `.unknownKey`. Distrust is the default.
/// LABEL: PROTOTYPE.

/// A publisher's claim that a specific skill's exact content is theirs. NO Mythos secret here — the
/// publisher signs, with a key Mythos never has.
public struct SkillApproval: Codable, Equatable, Sendable {
    public let skillName: String         // the skill this approval is bound to (defeats cross-skill sig reuse)
    public let contentHash: String       // SHA-256 hex of the exact SKILL.md bytes signed (defeats tamper)
    public let publisherKeyID: String    // which pinned publisher key attests it
    // Signed-in uniqueness. NOT consumed as a one-shot: a skill signature is meant to be reusable across
    // every load (unlike a one-shot build promotion, which has a consumedApprovals replay store). It is
    // covered by the signature (so it can't be altered) and is here for provenance / a future revocation
    // list; trust is revoked by UNPINNING the publisher key, not by burning a nonce.
    public let nonce: String
    public let approvedAtEpoch: Double
    public let note: String              // free-text provenance ("acme skills v1.2") — advisory

    public init(skillName: String, contentHash: String, publisherKeyID: String,
                nonce: String, approvedAtEpoch: Double, note: String = "") {
        self.skillName = skillName; self.contentHash = contentHash; self.publisherKeyID = publisherKeyID
        self.nonce = nonce; self.approvedAtEpoch = approvedAtEpoch; self.note = note
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case skillName, contentHash, publisherKeyID, nonce, approvedAtEpoch, note
    }

    /// Canonical, stable-ordered bytes the publisher signs (excludes the signature, which lives on
    /// SignedSkill). Deterministic: sortedKeys → a fixed key order so an equal value ⇒ equal bytes.
    public func canonicalPayload() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(self) else {
            fatalError("SkillApproval canonical encode must not fail")
        }
        return data
    }
}

/// An approval + its detached Ed25519 signature (over `approval.canonicalPayload()`). This is what a
/// publisher ships alongside a skill (a `SKILL.md.sig` sidecar).
public struct SignedSkill: Codable, Equatable, Sendable {
    public let approval: SkillApproval
    public let signatureB64: String
    public init(approval: SkillApproval, signatureB64: String) {
        self.approval = approval; self.signatureB64 = signatureB64
    }

    /// Helper for a publisher (or a test): sign an approval with a raw Ed25519 private key.
    public static func make(approval: SkillApproval, privateKeyRaw: Data) throws -> SignedSkill {
        let sig = try MythosCrypto.ed25519Sign(message: approval.canonicalPayload(), privateKeyRaw: privateKeyRaw)
        return SignedSkill(approval: approval, signatureB64: sig.base64EncodedString())
    }
}

/// A VERIFIED skill signature — a `SignedSkill` that passed `SkillSignatureVerifier`. Its initializer is
/// `fileprivate`, so ONLY `SkillSignatureVerifier` (this file) can mint one. The trust resolver treats
/// this type as proof of the publisher tier; nothing else can construct it.
public struct VerifiedSkill: Equatable, Sendable {
    public let signed: SignedSkill
    public let keyID: String
    // fileprivate: ONLY the verifier (same file) may construct this — the compile-time root of the
    // unforgeability guarantee. No other file can name this initializer.
    fileprivate init(signed: SignedSkill, keyID: String) {
        self.signed = signed; self.keyID = keyID
    }
}

/// Verifies a `SignedSkill` against PINNED publisher Ed25519 public keys, bound to a skill name and to
/// exact content bytes. Mythos holds ONLY public keys. FAIL CLOSED: with no trusted keys, every input is
/// `.unknownKey`.
public struct SkillSignatureVerifier: Sendable {

    /// A pinned publisher public key — the raw 32-byte Ed25519 public key, base64-encoded.
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
            guard let raw = Data(base64Encoded: key.publicKeyB64), MythosCrypto.ed25519ValidPublicKey(raw)
            else { continue }
            decoded[key.keyID] = raw
        }
        self.keys = decoded
    }

    /// True when no usable trusted key is pinned (then `verify` returns `.unknownKey` for everything).
    public var isEmpty: Bool { keys.isEmpty }

    public enum Verification: Equatable {
        case valid(VerifiedSkill)
        case unknownKey        // no pinned key matches publisherKeyID
        case badSignature      // pinned key found, signature did not verify
        case malformed         // signature base64 could not be decoded
        case subjectMismatch   // signature valid but for a DIFFERENT skill name
        case contentMismatch   // signature valid but for DIFFERENT content bytes (tamper)
    }

    /// Verify order (FAIL CLOSED at each gate): pinned key for publisherKeyID (else .unknownKey) → decode
    /// the signature base64 (else .malformed) → Ed25519 check over the EXACT canonical bytes (else
    /// .badSignature) → the approval names THIS skill (else .subjectMismatch) → the approval names THESE
    /// bytes (else .contentMismatch) → only then mint `.valid(VerifiedSkill)` (the ONLY mint site).
    ///
    /// `skillName`/`contentHash` are the CURRENT, freshly-derived values at load — so a signature made for
    /// benign bytes can't authorize swapped-in malicious bytes, and a signature for skill A can't be
    /// dropped next to skill B.
    public func verify(_ signed: SignedSkill, skillName: String, contentHash: String) -> Verification {
        guard let pubRaw = keys[signed.approval.publisherKeyID] else { return .unknownKey }
        guard let sig = Data(base64Encoded: signed.signatureB64) else { return .malformed }
        guard MythosCrypto.ed25519Verify(signature: sig, message: signed.approval.canonicalPayload(),
                                         publicKeyRaw: pubRaw) else { return .badSignature }
        guard signed.approval.skillName == skillName else { return .subjectMismatch }
        guard signed.approval.contentHash == contentHash else { return .contentMismatch }
        return .valid(VerifiedSkill(signed: signed, keyID: signed.approval.publisherKeyID))
    }
}
