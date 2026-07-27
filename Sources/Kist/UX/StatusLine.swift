import Foundation

/// The always-visible state line — finding #3 (NN/g heuristic #1: visibility of system status). A compact,
/// dim header shown before each prompt so the user always knows: which model/team, what mode, what it's
/// costing, what's active, and what's next. Pure + rendered from plain strings so it's trivially testable;
/// the REPL composes the inputs from live state.
struct StatusLine {
    var modelLabel: String      // plain model/team label ("Gemini" or the team description)
    var mode: String            // "chat" | "plan" | "autopilot"
    var cost: String            // compact cost/token string, e.g. "$0.01 · 1.2k tok" ("—" when idle)
    var activeTask: String?     // current task title (with id)
    var nextStep: String?       // next task title (with id)

    private func c(_ code: String, _ s: String, _ color: Bool) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }

    /// One dim status line + an optional "doing/next" line when a task board is active.
    func render(color: Bool = true) -> String {
        let dot = c("2", "·", color)
        var top = c("2", "─ ", color)
        top += c("36", modelLabel, color)
        top += " \(dot) " + c("2", "mode: ", color) + c(mode == "autopilot" ? "33;1" : "2", mode, color)
        top += " \(dot) " + c("2", "cost: ", color) + c("2", cost, color)
        var out = top
        if activeTask != nil || nextStep != nil {
            var line = "  "
            if let activeTask { line += c("2", "doing: ", color) + c("32", activeTask, color) }
            if let nextStep {
                if activeTask != nil { line += "   " }
                line += c("2", "next: ", color) + nextStep
            }
            out += "\n" + line
        }
        return out
    }
}

/// Decides whether the persisted project plan should drive the always-on status line's `doing:`/`next:`.
///
/// A kist plan is persisted per-project (`.kist/plan.json`) so a long multi-step effort survives across
/// sessions — but that means a plan left behind by a PRIOR session (or auto-seeded by a council run)
/// would otherwise greet every fresh `kist` invocation with a stale `next:` that has nothing to do with
/// the new conversation (finding from Luke: "why is this appearing when a new session starts").
///
/// The rule: surface the plan when it represents work that is alive for THIS session —
///   • it has an in-progress task (genuine mid-flight work, including a plan you exited and came back
///     to continue — that visibility must survive a cold restart), OR
///   • the plan file was written at/after this session started (this session is actively advancing it,
///     e.g. the agent started a task or a council seeded the board).
/// A plain all-`todo` backlog left behind by a prior session (the council-seed shape that greeted Luke)
/// stays silent on a cold start. The plan is always reachable on demand via `/tasks`.
enum PlanStatusVisibility {
    static func shouldShow(planModifiedAt: Date?, sessionStart: Date, hasActiveTask: Bool) -> Bool {
        // Show ONLY when THIS session has touched the plan (started/advanced a task ⇒ the file's mtime is
        // at/after sessionStart). A prior session's plan stays silent on a cold start — EVEN one with an
        // in-progress task, which was exactly the leak (Luke: a stale `resolve-aliases.sh` greeting every
        // startup). `hasActiveTask` is kept for callers but no longer force-shows. Board is on /tasks.
        _ = hasActiveTask
        guard let modified = planModifiedAt else { return false }
        return modified >= sessionStart
    }
}
