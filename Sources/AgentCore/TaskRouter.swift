import Foundation

/// Complexity-aware ROUTING at the front door — the "simple → fast, complex → full pipeline" decision that
/// makes kist feel instant on easy tasks and bring its full power only when the task earns it. It reuses
/// the existing `EffortController` brain (the same 0-100 complexity score that already tunes the great-loop)
/// so there's ONE notion of complexity, and turns it into a top-level route.
///
/// Design principles (the asymmetric-risk rule): UNDER-serving — fast-pathing a task that needed the
/// pipeline — erodes trust far faster than a little latency, so the router is CONSERVATIVE: it only takes
/// the fast lane for a clearly-trivial, non-mutating goal, defaults to the standard loop when unsure, and
/// supports cheap AUTO-escalation (feed live struggle `Signals` back and re-route) so a fast/standard run
/// that hits a wall is promoted without the user re-asking.
public enum TaskRouter {

    public enum Route: String, Sendable, Equatable {
        case fast       // trivial, non-mutating: lean loop — economy model, read-only tools, few iterations, skip heavy memory
        case standard   // the normal one-shot agent loop (the current default)
        case pipeline   // complex: escalate to the full machinery (plan-execute / great-loop / council)
    }

    public struct Decision: Sendable, Equatable {
        public let route: Route
        public let complexity: Int
        public let reason: String
    }

    /// Verbs that imply changing files/system state — a mutating goal never takes the fast (answer-y) lane
    /// even when it's short, because it has to actually DO something and verify it.
    static let mutatingVerbs: [String] = [
        "write", "edit", "create", "build", "add", "refactor", "fix", "implement", "delete", "remove",
        "rename", "move", "update", "change", "generate", "install", "migrate", "rewrite", "replace",
        "set up", "wire", "commit", "deploy", "configure", "convert", "port", "scaffold", "make ",
        "patch", "bump", "format", "apply", "tidy",
    ]

    static func looksMutating(_ goal: String) -> Bool {
        let t = goal.lowercased()
        return mutatingVerbs.contains { t.contains($0) }
    }

    /// Positive read-only/question INTENT signal — the fail-closed gate for the fast lane. A denylist of
    /// mutating verbs can never be complete ("bump version", "patch README" would slip through), so the
    /// fast lane requires the goal to LOOK like a question/lookup; any unknown imperative defaults out.
    static let readOnlyStarts: [String] = [
        "what", "how", "why", "when", "where", "which", "who", "whose", "is ", "are ", "does ", "do ",
        "can ", "could ", "should ", "would ", "explain", "describe", "summarize", "summarise",
        "tell me", "show me", "list ", "find ", "search", "look up", "look at", "read ", "count ",
        "compare", "define", "what's", "how's", "where's",
    ]

    static let actionRequestStarts: [String] = [
        "can you ", "could you ", "would you ", "will you ",
        "can u ", "could u ", "would u ", "will u ",
        "please ",
    ]

    static func looksReadOnly(_ goal: String) -> Bool {
        looksReadOnly(goal, allowBareQuestion: true)
    }

    private static func looksReadOnly(_ goal: String, allowBareQuestion: Bool) -> Bool {
        let t = goal.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix = actionRequestStarts.first(where: { t.hasPrefix($0) }) {
            let rest = String(t.dropFirst(prefix.count))
            return looksReadOnly(rest, allowBareQuestion: false)
        }
        if allowBareQuestion && t.hasSuffix("?") { return true } // informational question
        return readOnlyStarts.contains { t.hasPrefix($0) }
    }

    /// Route a goal. Struggle signals always escalate to pipeline; otherwise `userForced` (from an explicit
    /// flag/mode) wins. Without those, route pipeline for genuinely complex work, fast only for a
    /// clearly-trivial NON-mutating goal, standard otherwise.
    public static func route(goal: String,
                             signals: EffortController.Signals = .cold,
                             calibration: EffortController.Calibration = .neutral,
                             userForced: Route? = nil) -> Decision {
        let assessment = EffortController.assess(goal: goal, signals: signals, calibration: calibration)
        let score = assessment.complexity

        // Auto-escalation is the UNCONDITIONAL safety net — a struggling run goes to the pipeline even if a
        // route was forced, because the fast/standard lane already couldn't finish it (Codex MED).
        if signals.isStuck || signals.failureRate > 0.4 || signals.replansUsed >= 2 {
            return Decision(route: .pipeline, complexity: score, reason: "escalated: the run is struggling (\(assessment.rationale))")
        }
        if let userForced {
            return Decision(route: userForced, complexity: score, reason: "user-selected \(userForced.rawValue) mode")
        }
        if score >= complexThreshold {
            return Decision(route: .pipeline, complexity: score, reason: "complex (\(score)/100) → full pipeline")
        }
        // FAIL-CLOSED fast lane: needs a POSITIVE read-only/question signal (not merely the absence of
        // known mutating verbs), a low score, AND no mutating verb — so an unknown short imperative like
        // "bump version" defaults to .standard rather than slipping to fast (Codex HIGH).
        if score < fastThreshold && looksReadOnly(goal) && !looksMutating(goal) {
            return Decision(route: .fast, complexity: score, reason: "trivial, read-only (\(score)/100) → fast lane")
        }
        return Decision(route: .standard, complexity: score, reason: "standard (\(score)/100) → one-shot loop")
    }

    /// Below this ⇒ fast lane (must also be non-mutating). Deliberately low: only the obvious ones.
    public static let fastThreshold = 18
    /// At/above this ⇒ full pipeline. Aligned with EffortController's own `decompose` planning tier (55):
    /// a task complex enough to warrant decomposition warrants the pipeline.
    public static let complexThreshold = 55
}
