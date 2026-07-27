import Foundation

/// Phase 3.1 execution — the orchestration for best-of-N: try up to N INDEPENDENT attempts and take the
/// first that VERIFIES (execution-selection, fail-closed). Pure over an injected `attempt` closure, so the
/// selection logic is tested with stubs; the real caller passes a worktree-isolated attempt (WorktreeBestOfN)
/// so the live tree is never touched until a verified winner's diff applies cleanly.
///
/// Sequential with early-stop (not concurrent): cheaper for a token-bounded 20h loop (stop at the first
/// pass), and it sidesteps N concurrent agent loops fighting for resources. Order-independent otherwise.
public enum ParallelAttempts {
    public struct Attempt<R: Sendable>: Sendable {
        public let result: R
        public let verified: Bool
        public let quality: Int
        public init(result: R, verified: Bool, quality: Int) {
            self.result = result; self.verified = verified; self.quality = quality
        }
    }

    public struct Selection<R: Sendable>: Sendable {
        public let winner: R
        public let attemptsUsed: Int      // how many attempts ran before the verified winner (1-based)
        public let width: Int
    }

    /// Run up to `width` attempts; return the FIRST verified one (fail-closed: nil if NONE verify — an
    /// unverified best-of-N is still not done, so the caller must not merge anything). `width <= 1` runs a
    /// single attempt (no best-of-N overhead).
    public static func firstVerified<R: Sendable>(
        width: Int,
        attempt: @Sendable (_ index: Int) async -> Attempt<R>
    ) async -> Selection<R>? {
        let n = max(1, width)
        for i in 0..<n {
            let a = await attempt(i)
            if a.verified { return Selection(winner: a.result, attemptsUsed: i + 1, width: n) }
        }
        return nil
    }
}
