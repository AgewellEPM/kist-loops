import Foundation

/// THE GO/NO-GO FUSION — Luke's policy made into one decision: "nothing goes live without the council
/// blessing it AND a captain's OK." This composes the two independent gates and is PURE + FAIL-CLOSED:
///
///   GO  ⟺  council.isShipWorthy  AND  promotion == .promote
///
/// Either gate can VETO. NEITHER can authorize alone:
///   • The council (`CouncilPromotionVerdict`) is the product/quality judgment — it can only make the
///     decision STRICTER. A blessed council with no captain crypto sign-off is still NO-GO.
///   • The captain (`FleetPromotionGate.decide`) is the cryptographic sign-off (internal readiness +
///     Ed25519 external attestation bound to this build, replay-protected). A valid sign-off the council
///     vetoed is still NO-GO.
///
/// Like its inputs, this NEVER writes main. It returns GO/NO-GO; the actual merge is a deliberate step
/// that consults this verdict. The build id only rides through from the captain's already-validated
/// promotion decision, so it inherits that gate's trusted-build-id provenance.
public struct CaptainGateDecision: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case go(buildID: String)      // council blessed AND captain cryptographically approved THIS build
        case noGo(reason: String)     // any gate vetoed — fail closed
    }
    public let verdict: Verdict
    public init(verdict: Verdict) { self.verdict = verdict }

    public var isGo: Bool { if case .go = verdict { return true }; return false }
    public var buildID: String? { if case let .go(b) = verdict { return b }; return nil }
    public var refusalReason: String? { if case let .noGo(r) = verdict { return r }; return nil }
}

public enum CaptainGate {

    /// Fuse the council verdict and the captain's promotion decision into one GO/NO-GO. FAIL-CLOSED:
    /// BOTH must pass. The council is checked first (cheap, product judgment) so a HOLD short-circuits the
    /// crypto gate, but order is immaterial to correctness — a single failing gate yields NO-GO either way.
    public static func decide(council: CouncilPromotionVerdict,
                              promotion: FleetPromotionDecision) -> CaptainGateDecision {
        // Gate 1 — the council of minds must bless it (it can VETO, never authorize alone).
        guard council.isShipWorthy else {
            return .init(verdict: .noGo(reason: "council of minds did not bless: \(council.summary)"))
        }
        // Gate 2 — the captain's cryptographic sign-off must promote THIS build.
        switch promotion.verdict {
        case .refuse(let reason):
            return .init(verdict: .noGo(reason: "captain refused: \(reason)"))
        case .promote(let buildID):
            return .init(verdict: .go(buildID: buildID))
        }
    }
}
