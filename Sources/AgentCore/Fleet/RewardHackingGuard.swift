import Foundation

/// The reward-hacking GAP signal — ported from TinkySDR's Captain (C1). The frontier's central
/// 2025–26 finding: agents saturate the tests they can SEE while failing HELD-OUT tests. A
/// CI-integrity guard stops an agent WEAKENING the harness; it does NOT stop an agent satisfying
/// visible tests without satisfying intent. The fix is a held-out evaluator the worktree cannot read
/// or write, owned by the Foreman: when the visible suite is green but the held-out suite is red,
/// that's the signature of test-gaming → BLOCK the signoff. STRICTER-ONLY: never clears a visible-red.
/// PURE decision core; the IO half (provisioning + running a held-out suite) is Foreman wiring.
public enum GapVerdict: Equatable, Sendable {
    case clean                  // visible green AND held-out green (or no gap) — pass
    case noHeldOut              // no held-out suite provisioned — gap UNMEASURED (guard abstains)
    case visibleFailed          // the visible suite itself failed — must NOT sign off
    case blocked(String)        // REWARD-HACKING GAP: visible green, held-out red — gamed

    /// Gate signoff with THIS: allowed only when clean or abstaining. A `.visibleFailed`/`.blocked`
    /// NEVER allows signoff (so a caller can't accidentally clear a visible-red).
    public var allowsSignoff: Bool {
        switch self { case .clean, .noHeldOut: return true; case .visibleFailed, .blocked: return false }
    }
    public var isBlocking: Bool { !allowsSignoff }
}

public enum RewardHackingGuard {

    /// Boolean gap. `heldOutPassed == nil` ⇒ no held-out suite ⇒ `.noHeldOut` (never invent a gap we
    /// couldn't measure). Visible-red ⇒ `.visibleFailed`. Only visible-green + held-out-red ⇒ `.blocked`.
    public static func verdict(visiblePassed: Bool, heldOutPassed: Bool?) -> GapVerdict {
        guard visiblePassed else { return .visibleFailed }
        guard let held = heldOutPassed else { return .noHeldOut }
        return held ? .clean
            : .blocked("REWARD-HACKING GAP: the visible suite passes but the HELD-OUT suite (the agent could not read or write) FAILS — the change games the visible tests without satisfying intent")
    }

    /// Rate gap for partial/scored suites: Δ = visibleRate − heldOutRate. Δ above `maxGap` flags
    /// gaming. NaN ⇒ `.noHeldOut` (can't measure). An invalid `maxGap` (NaN/inf/<0/>1) fails STRICT
    /// to 0 (any gap blocks) — never looser. Stricter-only.
    public static func rateVerdict(visibleRate: Double, heldOutRate: Double, maxGap: Double = 0.15) -> GapVerdict {
        guard !visibleRate.isNaN, !heldOutRate.isNaN else { return .noHeldOut }
        let mg = (maxGap.isFinite && maxGap >= 0 && maxGap <= 1) ? maxGap : 0
        let v = clamp(visibleRate), h = clamp(heldOutRate)
        let gap = v - h
        guard gap > mg else { return .clean }
        return .blocked("REWARD-HACKING GAP: visible \(pct(v)) vs held-out \(pct(h)) — Δ \(pct(gap)) exceeds \(pct(mg)); the change is over-fit to the visible tests")
    }

    private static func clamp(_ d: Double) -> Double { min(1, max(0, d)) }
    private static func pct(_ d: Double) -> String { "\(Int((d * 100).rounded()))%" }
}
