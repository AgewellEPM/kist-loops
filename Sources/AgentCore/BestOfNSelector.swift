import Foundation

/// Phase 3.1 — execution-based selection over N independent attempts. The research is unanimous: on hard
/// problems, spending compute on breadth + a VERIFIER beats a bigger single shot (Snell et al. — matched
/// compute beat a 14× larger model; CodeT +18.8pts on HumanEval by dual-execution agreement). The catch:
/// best-of-N with a WEAK selector is wasted tokens — you must select by what actually PASSED, never by the
/// model's own preference. So this picks among attempts that cleared the Phase-0 anti-Goodhart gate.
///
/// Pure — the contract the (worktree-isolated) execution will feed. No git, no model.
public enum BestOfNSelector {
    public struct Attempt: Sendable, Equatable {
        public let verified: Bool      // cleared GreatLoopVerifier (real build/test + un-gamed)
        public let quality: Int        // EffortScorer quality 0…100 (tie-break among verified)
        public init(verified: Bool, quality: Int) { self.verified = verified; self.quality = quality }
    }

    /// Index of the attempt to keep: among VERIFIED attempts, the highest quality (ties → earliest, stable).
    /// nil when NONE verified — no attempt earned "done", so the loop must not merge any of them (fail
    /// closed: an unverified best-of-N is still not done).
    public static func pick(_ attempts: [Attempt]) -> Int? {
        var best: (idx: Int, quality: Int)? = nil
        for (i, a) in attempts.enumerated() where a.verified {
            if best == nil || a.quality > best!.quality { best = (i, a.quality) }
        }
        return best?.idx
    }

    /// How many verified attempts there were — useful for logging "3/5 attempts verified".
    public static func verifiedCount(_ attempts: [Attempt]) -> Int { attempts.filter { $0.verified }.count }
}
