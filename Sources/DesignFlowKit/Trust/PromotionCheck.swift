import Foundation
import AgentCore

/// A DRY, human-invoked consultation of the fleet's external deploy gate
/// (`FleetPromotionGate`). It ties DesignFlow's OWN internal tier — the sealed
/// signoff chain — to the external Ed25519 tier, and returns GO/NO-GO.
///
/// IT NEVER ARMS ANYTHING. No git write, no main write, no key generation. Mythos
/// holds only PUBLIC pinned keys + an operator-supplied signed approval; the
/// unforgeability guarantee (VerifiedApproval's fileprivate init) is inherited
/// untouched. This is a check a human consults before a deliberate deploy — it is
/// deliberately NOT part of the autonomous loop (the loop has no external attester,
/// so it would always, correctly, refuse).
public enum PromotionCheck {

    /// Internal-tier readiness (Codex BLOCKER-3). "Any non-empty intact ledger" is NOT
    /// enough — a design-only run, a truncated valid prefix, or a copied ledger from
    /// another project would all pass. Readiness requires ALL of:
    ///   1. the chain verifies (seal + hash chain intact), AND
    ///   2. the signoffs cover EXACTLY the expected stages, in order (full pipeline —
    ///      no truncation, no partial), AND
    ///   3. the final signoff's commit BINDS to this workspace's current HEAD (so a
    ///      stale/copied ledger from another checkout can't satisfy it).
    public static func internallyReady(_ ledger: StageSignoffLedger,
                                       expectedStages: [AgentKind],
                                       headSHA: String) -> Bool {
        guard ledger.verifyChain() == nil else { return false }
        let entries = ledger.entries()
        guard entries.map(\.stageRaw) == expectedStages.map(\.rawValue) else { return false }
        guard let last = entries.last else { return false }
        let head = headSHA.trimmingCharacters(in: .whitespacesAndNewlines)
        // commitSHA is a short SHA; HEAD is full. Bind: full HEAD must start with it.
        guard !last.commitSHA.isEmpty, !head.isEmpty, head.hasPrefix(last.commitSHA) else { return false }
        return true
    }

    /// Consult the deploy gate. Pure pass-through to `FleetPromotionGate.decide`, so
    /// every fail-closed guard (readiness, pinned key, signature, build-binding,
    /// replay) is the fleet's, unmodified.
    public static func decide(buildID: String,
                              internallyReady: Bool,
                              attestation: SignedApproval?,
                              pins: [AttestationVerifier.TrustedKey],
                              consumedApprovals: Set<String>) -> FleetPromotionDecision {
        FleetPromotionGate.decide(
            integrationBuildID: buildID,
            internallyReady: internallyReady,
            attestation: attestation,
            verifier: AttestationVerifier(trusted: pins),
            consumedApprovals: consumedApprovals)
    }

    // MARK: - Operator-file parsing (fail-soft: bad input ⇒ nil/empty ⇒ fail-closed refuse)

    /// A pinned external public key as it appears in an operator's pins file.
    public struct PinDTO: Codable, Sendable {
        public let keyID: String
        public let publicKeyB64: String
    }

    public static func parsePins(_ json: String) -> [AttestationVerifier.TrustedKey] {
        guard let data = json.data(using: .utf8),
              let dtos = try? JSONDecoder().decode([PinDTO].self, from: data) else { return [] }
        return dtos.map { .init(keyID: $0.keyID, publicKeyB64: $0.publicKeyB64) }
    }

    public static func parseApproval(_ json: String) -> SignedApproval? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SignedApproval.self, from: data)
    }

    /// Consumed replay keys, one `approverKeyID\u{0}nonce` per line (blank lines ignored).
    public static func parseConsumed(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty })
    }
}
