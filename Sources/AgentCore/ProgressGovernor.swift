import Foundation

/// The reliability brain for finishing gnarly multi-step tasks without babysitting.
///
/// The problem: a flat `maxIterations` (12) makes the loop QUIT on hard tasks (which need 50–100+ steps)
/// and, worse, report the wall as a FAILURE. Raising the cap blindly invites runaway loops + cost.
///
/// The fix: run to a MUCH higher ceiling, but GOVERN it live. Each iteration, decide from the trajectory:
///   • cont       — making progress (varied, mostly-successful actions) → keep going
///   • stopStuck  — a genuine loop the re-plan nudges couldn't break, or a sustained failure spike → stop
///                  CLEANLY with a reason (not a raw "failed"), so the model can hand back honestly
///   • stopCeiling — hit the absolute safety ceiling → pause, resumable via checkpoint (not "failed")
///
/// The governor is intentionally MORE LENIENT than the in-loop nudges: the loop already nudges/re-plans on
/// a 3× repeat or a failure streak; the governor only HARD-STOPS when that recovery has demonstrably failed
/// (a `stuckRepeat`× loop, or a `failureBar` failure rate over the recent window). It never stops a task that
/// is simply LONG but progressing — varied actions read as healthy, so the ceiling is the only cap on real work.
public struct ProgressGovernor: Sendable {
    public let hardCeiling: Int     // absolute step ceiling (safety) — the only cap on a progressing task
    public let stuckRepeat: Int     // repeats of the same/cyclic action that mean "recovery failed, stop"
    public let recentWindow: Int    // judge RECENT behavior, so early failures don't doom a recovered run
    public let failureBar: Double   // recent failure rate that means "this approach is doomed"

    public init(hardCeiling: Int = 60, stuckRepeat: Int = 5, recentWindow: Int = 12, failureBar: Double = 0.7) {
        self.hardCeiling = max(1, hardCeiling)
        self.stuckRepeat = max(2, stuckRepeat)
        self.recentWindow = max(stuckRepeat, recentWindow)
        self.failureBar = min(1, max(0, failureBar))
    }

    public enum Decision: Sendable, Equatable {
        case cont
        case stopStuck(reason: String)
        case stopCeiling
    }

    /// `analyzeFrom` — after a recovery reset, the loop passes the trajectory length AT the reset so the
    /// governor judges ONLY actions taken SINCE. Without this, the stale stuck-pattern that triggered the
    /// recovery is still in the window and would immediately re-stop the run before the new approach gets a
    /// chance. (Codex review: "stuck-recovery stops on stale trajectory".)
    public func decide(iteration: Int, trajectory: [ActionRecord], analyzeFrom: Int = 0,
                       taskIntent: TaskBrief.Intent? = nil) -> Decision {
        if iteration >= hardCeiling { return .stopCeiling }
        // Consider only post-recovery actions when a reset cursor is set.
        let considered = analyzeFrom > 0 ? Array(trajectory.dropFirst(min(analyzeFrom, trajectory.count))) : trajectory
        // Not enough NEW history to judge "stuck" — keep going (this is what gives recovery its chance).
        guard considered.count >= stuckRepeat else { return .cont }

        // Judge the RECENT window only, at the STUCK bar (higher than the in-loop nudge threshold), so we
        // only stop once the loop's own recovery has clearly failed.
        let recent = Array(considered.suffix(recentWindow))
        let report = TrajectoryAnalyzer.analyze(recent, runawayThreshold: stuckRepeat,
                                                failureRateThreshold: failureBar,
                                                taskIntent: taskIntent)

        if let loop = report.issues.first(where: { $0.kind == .runawayLoop }) {
            return .stopStuck(reason: "stuck in a loop the re-plan couldn't break — \(loop.detail)")
        }
        if let spike = report.issues.first(where: { $0.kind == .failureSpike }) {
            return .stopStuck(reason: "sustained failure spike — \(spike.detail)")
        }
        if let noProgress = report.issues.first(where: { $0.kind == .noToolProgress }) {
            return .stopStuck(reason: "build made no deliverable progress — \(noProgress.detail)")
        }
        return .cont
    }

    /// A HARD reset injected on the first stuck detection — one real chance to break out before giving up.
    /// Stronger than the in-loop re-plan nudge: it tells the model to ABANDON the current approach entirely,
    /// not tweak it. Only if the run is STILL stuck after this does the loop actually stop.
    public static func recoverySteering(reason: String) -> String {
        """
        STOP. You are stuck: \(reason). Do NOT repeat or lightly tweak what you've been doing — it is not
        working. Step back completely: re-read the original goal, state in one line WHY the current approach
        is failing, then choose a FUNDAMENTALLY DIFFERENT approach (different tool, different file, different
        strategy) and take the single most useful next action toward the goal. If no viable approach remains,
        finish and report honestly what blocked you.
        """
    }
}
