import Foundation

// MARK: - The verify spine: a finding is report-ready ONLY if it is authorized, survives the adversarial
// panel, AND reproduces. This is the moat. It fuses three fail-closed gates, ALL required:
//
//   1. Pass-1 rules gate  (BountyGate)      — may we even reproduce this? (scope + program rules)
//   2. adversarial panel  (FindingVerifier) — does a skeptic panel fail to refute it? (existing spine)
//   3. reproducible PoC   (PoCReproducer)   — does the exploit actually reproduce? (the new half)
//
// Any gate failing ⇒ DROPPED with a reason. Nothing an LLM says can promote a finding; it can only be
// held or dropped. This is what keeps the assistant off the AI-slop ban list.

public enum BountyFindingVerdict: Sendable, Equatable {
    case reportReady
    case dropped(reason: String)
    public var isReportReady: Bool { if case .reportReady = self { return true }; return false }
    public var dropReason: String? { if case .dropped(let r) = self { return r }; return nil }
}

/// A finding carried all the way through the spine, with every stage's evidence attached for audit.
///
/// UNFORGEABILITY (panel review): the fields are read-only and the initializer is INTERNAL (memberwise
/// default, made explicit here), so no code OUTSIDE AgentCore can mint a `.reportReady` finding — only
/// `BountyFindingVerifier` (in this module) produces them. Downstream consumers (Kist, the REPL, a report
/// drafter) can inspect `isReportReady` but cannot fabricate it. Do NOT widen this init to `public`.
public struct VerifiedBountyFinding: Sendable, Equatable {
    public let finding: SecurityFinding
    public let poc: ProofOfConcept?
    public let panel: VerifiedFinding?   // the adversarial verdict, when the panel stage was reached
    public let repro: ReproResult?       // the reproduction outcome, when that stage was reached
    public let verdict: BountyFindingVerdict

    init(finding: SecurityFinding, poc: ProofOfConcept?, panel: VerifiedFinding?,
         repro: ReproResult?, verdict: BountyFindingVerdict) {
        self.finding = finding; self.poc = poc; self.panel = panel; self.repro = repro; self.verdict = verdict
    }

    public var isReportReady: Bool { verdict.isReportReady }
}

/// Runs a candidate finding through the full verify spine. Holds the authorization gate + the reproducer;
/// the adversarial panel is passed per-call (it's the caller's skeptic set).
public struct BountyFindingVerifier: Sendable {
    public let gate: BountyGate
    public let reproducer: PoCReproducer

    public init(gate: BountyGate = BountyGate(), reproducer: PoCReproducer) {
        self.gate = gate
        self.reproducer = reproducer
    }

    public func verify(finding: SecurityFinding,
                       poc: ProofOfConcept?,
                       engagement: SecurityEngagement,
                       rules: BountyProgramRules,
                       auditRepo: String,
                       panel: [FindingRefuter]) async -> VerifiedBountyFinding {

        // 1) NO PoC ⇒ never report-ready. An unproven finding is exactly the slop that gets a hunter banned.
        guard let poc else {
            return drop(finding, nil, nil, nil,
                        "no proof-of-concept — a finding without a reproducible PoC is never report-ready")
        }

        // 2) AUTHORIZATION TO REPRODUCE — gate the repro action (scope + program rules) BEFORE any traffic.
        //    Out-of-scope host, banned automation, wrong vuln class, over rate ⇒ we don't even attempt it.
        let decision = gate.evaluate(poc.reproAction, engagement: engagement, rules: rules)
        guard decision.isAllowed else {
            return drop(finding, poc, nil, nil,
                        "not authorized to reproduce (\(decision.ruleHit ?? "rule")): \(decision.reason)")
        }

        // 3) ADVERSARIAL PANEL — reuse the hardened FindingVerifier (scope-binds by repo, fail-closed,
        //    strict-minority-refute to confirm). Anything short of .confirmed is dropped.
        let verified = await FindingVerifier.verify(
            findings: [finding], engagement: engagement, auditRepo: auditRepo, panel: panel).first
        guard let verified else {
            return drop(finding, poc, nil, nil, "internal: verifier returned no result")
        }
        guard verified.isReportReady else {
            return drop(finding, poc, verified, nil, "adversarial panel did not confirm: \(verified.rationale)")
        }

        // 4) REPRODUCE — the moat. If the PoC does not reproduce, treat it as a false positive and DROP it,
        //    even though the panel confirmed. Reproduction is the ground truth; the panel is only reasoning.
        let repro = await reproducer.reproduce(poc)
        guard repro.reproduced else {
            return drop(finding, poc, verified, repro,
                        "PoC did not reproduce → treated as a false positive: \(repro.observed)")
        }

        // 5) Authorized + panel-confirmed + reproduced ⇒ report-ready.
        return VerifiedBountyFinding(finding: finding, poc: poc, panel: verified, repro: repro,
                                     verdict: .reportReady)
    }

    /// Convenience: run a batch and return ONLY the report-ready findings (the set a report drafter may use).
    public func reportReady(from candidates: [(SecurityFinding, ProofOfConcept?)],
                            engagement: SecurityEngagement,
                            rules: BountyProgramRules,
                            auditRepo: String,
                            panel: [FindingRefuter]) async -> [VerifiedBountyFinding] {
        var out: [VerifiedBountyFinding] = []
        for (f, p) in candidates {
            let v = await verify(finding: f, poc: p, engagement: engagement, rules: rules,
                                 auditRepo: auditRepo, panel: panel)
            if v.isReportReady { out.append(v) }
        }
        return out
    }

    private func drop(_ f: SecurityFinding, _ p: ProofOfConcept?, _ panel: VerifiedFinding?,
                      _ repro: ReproResult?, _ reason: String) -> VerifiedBountyFinding {
        VerifiedBountyFinding(finding: f, poc: p, panel: panel, repro: repro, verdict: .dropped(reason: reason))
    }
}
