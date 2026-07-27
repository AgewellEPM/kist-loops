import Foundation

/// The deterministic, no-LLM judge. Given a fact-set it returns the same verdict every time. No model,
/// no hallucination. It is the JUDGE half of the Captain — the LLM stays the generative PROPOSER; this
/// layer rules on whether a build may be trusted as done.
///
/// THREE verdicts, and the middle one is the whole point:
///   • .green        — all structural invariants hold AND no drift.
///   • .blocked      — a structural invariant FAILED (process violation; hard no).
///   • .driftFlagged — the process looks green, but the WORLD has not confirmed THIS build (rules say
///                     green, reality says nothing / can't be seen). The alarm no LLM judge could raise.
///
/// DETERMINISM: judge() iterates the rule arrays in order, with no clock, randomness, I/O, or unordered
/// container — so `failedBlockers`/`warnings` come out in a STABLE order (rule-declaration order), and
/// identical input always yields an identical judgment. Ported from TinkySDR's Captain (Stage 1.4).

/// The deterministic verdict over one fact-set.
public struct CaptainJudgment: Equatable, Sendable {
    /// Codable so the signoff ledger (Stage 1.5) can persist the verdict to JSONL. Payload-free, so the
    /// String raw value is stable on disk.
    public enum Verdict: String, Codable, Equatable, Sendable { case green, blocked, driftFlagged }

    public let verdict: Verdict
    public let failedBlockers: [String]      // structural-blocker rule ids that failed (declaration order)
    public let driftReason: String?          // set iff drift detected (proxy shippable, world unconfirmed)
    public let warnings: [String]            // non-blocking failures, surfaced not blocking
    public let ungroundedProxies: [String]   // proxies with NO declared correspondent (the honest sting)
    public let worldSignalMissing: Bool      // no conscience wired → every help-"green" is unverified

    public init(verdict: Verdict, failedBlockers: [String], driftReason: String?, warnings: [String],
                ungroundedProxies: [String], worldSignalMissing: Bool) {
        self.verdict = verdict
        self.failedBlockers = failedBlockers
        self.driftReason = driftReason
        self.warnings = warnings
        self.ungroundedProxies = ungroundedProxies
        self.worldSignalMissing = worldSignalMissing
    }
}

/// The deterministic Captain. Pure: `judge` is a function of (facts, rulebook) alone — no clock,
/// randomness, or I/O — so the same input always yields the same judgment.
public final class SymbolicCaptain {

    public let structuralRules: [StructuralRule]
    public let proxyRules: [ProxyRule]

    public init(structural: [StructuralRule] = CaptainRuleSet.structural,
                proxies: [ProxyRule] = CaptainRuleSet.proxies) {
        self.structuralRules = structural
        self.proxyRules = proxies
    }

    /// Audit the rulebook itself: how much is right-by-construction vs assumed.
    public func auditRules() -> CaptainRuleSet.Audit {
        CaptainRuleSet.audit(structural: structuralRules, proxies: proxyRules)
    }

    /// Rule on one fact-set. Deterministic.
    public func judge(_ facts: CaptainFacts) -> CaptainJudgment {
        var failedBlockers: [String] = []
        var warnings: [String] = []
        var driftReason: String?

        // Structural rules see ONLY build facts (type-enforced). A failed blocker is a hard violation.
        for rule in structuralRules {
            guard case .fail(let evidence) = rule.evaluate(facts.build) else { continue }
            if rule.severity == .blocker { failedBlockers.append(rule.id) }
            else { warnings.append("\(rule.id): \(evidence)") }
        }

        // Proxy rules may read the world-signal. A failed proxy is DRIFT.
        for rule in proxyRules {
            guard case .fail(let evidence) = rule.check(facts.build, facts.world) else { continue }
            if driftReason == nil { driftReason = evidence }   // first drift is the headline
            warnings.append("\(rule.id): \(evidence)")
        }

        // Precedence: a process violation is the hardest no; drift next; else green.
        let verdict: CaptainJudgment.Verdict =
            !failedBlockers.isEmpty ? .blocked
            : (driftReason != nil ? .driftFlagged : .green)

        return CaptainJudgment(
            verdict: verdict,
            failedBlockers: failedBlockers,
            driftReason: driftReason,
            warnings: warnings,
            ungroundedProxies: proxyRules.filter { $0.isUngrounded }.map(\.id),
            worldSignalMissing: !facts.world.hasSignal)
    }
}
