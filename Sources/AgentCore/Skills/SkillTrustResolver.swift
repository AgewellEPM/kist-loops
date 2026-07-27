import Foundation

/// The single trust verdict for a project skill's CURRENT bytes, unifying the two trust tiers:
///   1. PUBLISHER SIGNATURE (Ed25519) — a `SKILL.md.sig` sidecar signed by a PINNED publisher key,
///      bound to this skill name and these exact bytes. Trusted WITHOUT a local pin.
///   2. LOCAL HASH PIN — the exact bytes' SHA-256 is pinned in this project's `SkillTrustStore`.
/// Either tier ⇒ `.trusted`; neither ⇒ `.untrusted` (loads read-only). FAIL CLOSED: any decode/verify
/// failure in the signature tier falls through to the hash-pin tier, never to trusted.
///
/// This centralizes the decision so the enforcement chokepoint (`ReadFileTool.readProjectSkill`) stays a
/// one-liner and the logic is unit-testable without the tool. Callers pass values DERIVED FROM THE BYTES
/// THEY JUST READ (not stale discovery-time values) — the resolver never touches the filesystem for
/// content, only for the (already-vetted, user-level) trust stores.
public enum SkillTrustResolver {

    /// Resolve trust for `skillName` given its current `content`.
    /// - `signatureJSON`: the raw `SKILL.md.sig` bytes if present (a `SignedSkill` JSON), else nil.
    /// - `trustStorePath` / `publisherStorePath`: override the user-level store locations (tests).
    public static func resolve(skillName: String,
                               content: String,
                               projectRoot: String,
                               signatureJSON: String? = nil,
                               trustStorePath: String? = nil,
                               publisherStorePath: String? = nil) -> SkillTrust {
        let hash = SkillTrustStore.hash(content)

        // TIER 1 — publisher signature. A valid signature from a pinned publisher, bound to THIS name and
        // THESE bytes, is trust on its own. Any failure (no sidecar, malformed JSON, unknown key, bad sig,
        // subject/content mismatch) simply does NOT grant tier-1 trust — we fall through, never up.
        if let signed = decodeSignedSkill(signatureJSON) {
            let verifier = SkillSignatureVerifier(trusted: SkillPublisherKeyStore.load(storePath: publisherStorePath).trustedKeys())
            if case .valid = verifier.verify(signed, skillName: skillName, contentHash: hash) {
                return .trusted
            }
        }

        // TIER 2 — local hash pin (per-project, user reviewed these exact bytes).
        if SkillTrustStore.load(root: projectRoot, storePath: trustStorePath).isPinned(name: skillName, hash: hash) {
            return .trusted
        }

        return .untrusted
    }

    /// Decode a `SignedSkill` from raw sidecar bytes. Fail-soft: nil/garbage ⇒ nil (no tier-1 trust).
    private static func decodeSignedSkill(_ json: String?) -> SignedSkill? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SignedSkill.self, from: data)
    }

    /// The conventional sidecar path for a skill's signature (next to its SKILL.md).
    public static func signaturePath(forSkillAt skillPath: String) -> String { skillPath + ".sig" }
}
