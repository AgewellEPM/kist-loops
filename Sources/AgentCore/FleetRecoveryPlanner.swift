import Foundation

/// Recover a stalled subtask instead of restarting from zero. The supervisor's plain retry-within-budget
/// → terminal `.failed` is too blunt; this adds the missing middle: when an agent exhausts retries or
/// times out, decide whether to RE-PLAN (decompose finer, guided by the recorded blockers) or ESCALATE
/// to a human.
///
/// SAFETY: this is a pure DECISION. The supervisor RECORDS the recommendation on the board — it does NOT
/// auto-spawn re-planned agents. Arming the fleet to act on a re-plan is a separate, explicit step (never
/// without Luke). Pure + deterministic. Ported from TinkySDR's Captain (Stage 2). LABEL: PROTOTYPE.
public struct RecoveryDecision: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case retry                          // still within budget — bounce back to the agent
        case replan(reason: String)         // stalled, but we know WHY → decompose finer
        case escalate(reason: String)       // no usable signal to re-plan from → human
    }
    public let action: Action
    public init(action: Action) { self.action = action }

    public var summary: String {
        switch action {
        case .retry: return "retry (within budget)"
        case let .replan(r): return "RE-PLAN: \(r)"
        case let .escalate(r): return "ESCALATE: \(r)"
        }
    }
}

public enum FleetRecoveryPlanner {

    /// Decide how to recover a struggling subtask. Within retry budget + not timed out → retry. On a
    /// STALL (retries exhausted or a timeout): RE-PLAN when we have recorded blockers to guide a finer
    /// decomposition; ESCALATE when there's no diagnostic signal (re-planning blind just burns agents).
    /// Pure.
    public static func decide(rejectCount: Int, maxRejects: Int, timedOut: Bool,
                              blockers: [String]) -> RecoveryDecision {
        if !timedOut && rejectCount <= maxRejects {
            return RecoveryDecision(action: .retry)
        }
        let real = blockers.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if real.isEmpty {
            return RecoveryDecision(action: .escalate(reason:
                timedOut ? "timed out with no diagnostic — human review"
                         : "retries exhausted with no recorded blocker — human review"))
        }
        let why = timedOut
            ? "timed out — likely too large; decompose into smaller subtasks (blockers: \(real.joined(separator: ", ")))"
            : "retries exhausted — re-decompose around: \(real.joined(separator: ", "))"
        return RecoveryDecision(action: .replan(reason: why))
    }
}
