import Foundation

/// The injectable judging step — lets the pipeline's fusion be unit-tested with a stub council instead of
/// a live model. `CouncilPromotionJudge` is the production conformer.
public protocol PromotionCouncil: Sendable {
    func judge(_ ctx: PromotionContext, threshold: Int) async -> CouncilPromotionVerdict
}
extension CouncilPromotionJudge: PromotionCouncil {}

/// THE PROMOTION PIPELINE — one call that "hooks it all up": the council of minds judges the built,
/// captain-verified integration branch, and the result is fused with the captain's cryptographic
/// promotion gate into a single GO/NO-GO. This is the ONLY composed entry point a merge-to-main path
/// should consult.
///
/// It performs NO git/main write — it returns a `CaptainGateDecision`. The actual merge stays a deliberate,
/// separately-armed step (never auto-armed without Luke's say-so). FAIL-CLOSED throughout: the council can
/// veto, the captain can veto, and neither can authorize alone.
public struct PromotionPipeline: Sendable {
    private let council: PromotionCouncil

    public init(council: PromotionCouncil) { self.council = council }

    /// Run the full go/no-go.
    ///
    /// ⚠️ Inherits `FleetPromotionGate`'s WIRING CONSTRAINT: `integrationBuildID` MUST come from a TRUSTED
    /// source (the integration branch HEAD SHA the system reads, or a sealed manifest) — NEVER user input —
    /// or a stale valid attestation could be matched. `consumedApprovals` has no default so a caller can't
    /// silently forget replay protection.
    public func evaluate(context: PromotionContext,
                         integrationBuildID: String,
                         internallyReady: Bool,
                         attestation: SignedApproval?,
                         verifier: AttestationVerifier,
                         consumedApprovals: Set<String>,
                         councilThreshold: Int = 3) async -> CaptainGateDecision {
        let councilVerdict = await council.judge(context, threshold: councilThreshold)
        let promotion = FleetPromotionGate.decide(integrationBuildID: integrationBuildID,
                                                  internallyReady: internallyReady,
                                                  attestation: attestation,
                                                  verifier: verifier,
                                                  consumedApprovals: consumedApprovals)
        return CaptainGate.decide(council: councilVerdict, promotion: promotion)
    }
}
