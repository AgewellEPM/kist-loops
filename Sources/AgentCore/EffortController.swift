import Foundation

/// The adaptive "how hard should I work on this?" brain. Given a goal — and, mid-run, how the run is
/// actually going — it decides how much THINKING (extended reasoning), how much PLANNING (decompose first
/// vs just act), how much TEAM (solo / review / full council), and how big an iteration budget to grant.
/// This is what lets a long autonomous run be EFFICIENT: don't deep-think a rename, don't wing a migration.
///
/// Pure over its inputs (goal text + run signals) so the policy is unit-tested and deterministic; the
/// runner reads the assessment to configure the loop, and can RE-ASSESS mid-run as signals change.
public enum EffortController {

    public enum Thinking: String, Sendable, Equatable { case none, light, deep }
    public enum Planning: String, Sendable, Equatable { case direct, plan, decompose }
    public enum Team: String, Sendable, Equatable { case solo, review, council }
    /// Which strength of mind a cycle deserves — the runner routes a frontier tier to the strongest keyed
    /// provider so hard cycles get a stronger model instead of grinding on a weak one.
    public enum ModelTier: String, Sendable, Equatable { case economy, standard, frontier }

    public struct Assessment: Sendable, Equatable {
        public let thinking: Thinking
        public let planning: Planning
        public let team: Team
        public let modelTier: ModelTier
        public let iterationBudget: Int
        /// Compute-optimal search width: how many INDEPENDENT attempts to make and select among by
        /// EXECUTION (Snell et al. — hard problems want breadth, easy want one shot). 1 = single attempt.
        public let searchWidth: Int
        public let complexity: Int          // 0…100, the score the tiers derive from
        public let rationale: String
    }

    /// Live signals the runner feeds back so effort can ESCALATE when a run is struggling (or DE-escalate
    /// when it's cruising). All optional; a cold assessment passes the defaults.
    public struct Signals: Sendable, Equatable {
        public var failureRate: Double      // 0…1 of tool calls that failed
        public var iterationsUsed: Int
        public var isStuck: Bool            // governor / trajectory flagged a loop
        public var replansUsed: Int
        public init(failureRate: Double = 0, iterationsUsed: Int = 0, isStuck: Bool = false, replansUsed: Int = 0) {
            self.failureRate = failureRate; self.iterationsUsed = iterationsUsed
            self.isStuck = isStuck; self.replansUsed = replansUsed
        }
        public static let cold = Signals()
    }

    // Words that signal genuine build/engineering complexity (planning + thinking pay off).
    static let heavyWords: Set<String> = [
        "build", "create", "implement", "design", "architect", "refactor", "migrate", "rewrite",
        "optimize", "integrate", "port", "add feature", "end-to-end", "pipeline", "system", "framework",
        "research", "investigate", "audit", "analyze", "debug", "diagnose", "fix bug", "root cause",
    ]
    // Words that signal a trivial, do-it-now task (thinking/planning are waste).
    static let trivialWords: Set<String> = [
        "rename", "typo", "read", "show", "list", "print", "what is", "explain", "display", "cat",
        "grep", "find the", "look up", "format", "lint", "bump version",
    ]
    // Words that demand verification rigor regardless of size.
    static let rigorWords: Set<String> = ["production", "enterprise", "security", "payment", "auth", "migration", "deploy"]

    /// A learned correction from history: how much to nudge the predicted complexity for goals like this
    /// one, based on how similar past runs ACTUALLY went (see EffortMemory). `bias` is already
    /// confidence-weighted; `samples` is how many past runs informed it (0 ⇒ neutral, no history yet).
    public struct Calibration: Sendable, Equatable {
        public let bias: Int
        public let samples: Int
        public init(bias: Int = 0, samples: Int = 0) { self.bias = bias; self.samples = samples }
        public static let neutral = Calibration()
    }

    /// A coarse bucket key so similar goals share a history: the heavy/trivial keywords present + a length
    /// band. Two "build an X service" goals land in the same bucket and learn from each other.
    public static func signature(for goal: String) -> String {
        let text = goal.lowercased()
        let heavy = heavyWords.filter { text.contains($0) }.sorted().prefix(3).joined(separator: ",")
        let trivial = trivialWords.filter { text.contains($0) }.sorted().prefix(2).joined(separator: ",")
        let words = text.split { $0 == " " || $0 == "\n" }.count
        let band = words < 8 ? "s" : (words < 30 ? "m" : "l")
        return "h[\(heavy)]t[\(trivial)]|\(band)"
    }

    /// Assess effort for a goal, optionally adjusted by live run signals AND a learned calibration.
    public static func assess(goal: String, signals: Signals = .cold, calibration: Calibration = .neutral) -> Assessment {
        let text = goal.lowercased()
        var score = 0

        // 1) Length / number of steps — more clauses ⇒ more planning.
        let words = text.split { $0 == " " || $0 == "\n" }.count
        score += min(30, words / 6)                                  // up to +30 for a long brief
        let steps = text.components(separatedBy: CharacterSet(charactersIn: ".;\n")).filter { $0.contains(" ") }.count
        let conjunctions = countOccurrences(of: [" and ", " then ", " after ", ", "], in: text)
        score += min(20, (steps + conjunctions) * 4)                 // multi-step ⇒ decompose

        // 2) Keyword signals.
        score += 12 * heavyWords.filter { text.contains($0) }.count
        score -= 10 * trivialWords.filter { text.contains($0) }.count
        let needsRigor = rigorWords.contains { text.contains($0) }
        if needsRigor { score += 10 }

        // 3) Mid-run escalation: a struggling run earns more effort (bounded).
        if signals.isStuck { score += 25 }
        if signals.failureRate > 0.4 { score += 20 }
        if signals.replansUsed >= 1 { score += 10 }

        // 4) LEARNED calibration: nudge by how similar past runs ACTUALLY went (self-correction).
        score += calibration.bias

        score = max(0, min(100, score))

        // Derive the tiers from the score.
        let thinking: Thinking = score >= 60 ? .deep : (score >= 25 ? .light : .none)
        let planning: Planning = score >= 55 ? .decompose : (score >= 25 ? .plan : .direct)
        let team: Team = score >= 70 ? .council : (score >= 40 ? .review : .solo)
        let modelTier: ModelTier = score >= 60 ? .frontier : (score >= 25 ? .standard : .economy)
        // Breadth is EXPENSIVE (N× full attempts), so reserve it for genuinely HARD cycles — a live
        // dogfood showed best-of-2 on a moderate (54) task burned the whole budget before the loop could
        // even confirm done. Only real frontier work pays the N× cost.
        let searchWidth: Int = score >= 82 ? 3 : (score >= 68 ? 2 : 1)
        // Budget scales with complexity; a struggling long run still gets headroom to finish.
        let budget = max(15, min(400, 15 + score * 3 + signals.iterationsUsed / 4))

        let rationale = "complexity \(score)/100 "
            + "(\(words)w, \(steps) step(s)"
            + (needsRigor ? ", rigor" : "")
            + (signals.isStuck ? ", STUCK↑" : "")
            + (signals.failureRate > 0.4 ? ", failing↑" : "")
            + ") → think:\(thinking.rawValue) plan:\(planning.rawValue) team:\(team.rawValue) model:\(modelTier.rawValue) N:\(searchWidth) budget:\(budget)"

        return Assessment(thinking: thinking, planning: planning, team: team, modelTier: modelTier,
                          iterationBudget: budget, searchWidth: searchWidth, complexity: score, rationale: rationale)
    }

    private static func countOccurrences(of needles: [String], in text: String) -> Int {
        needles.reduce(0) { acc, n in
            acc + text.components(separatedBy: n).count - 1
        }
    }
}

/// Routes a `ModelTier` to the strongest KEYED provider — so a frontier-tier (hard) cycle gets a stronger
/// mind instead of grinding on a weak one (the exact ceiling the dogfood hit). Pure; strength is a coarse
/// known ranking (unknown providers rank mid), and it only steps UP, never down from the session default.
public enum ModelEscalator {
    static let strength: [String: Int] = [
        "anthropic": 100, "claude": 100, "openai": 95, "gemini": 85, "deepseek": 70,
        "grok": 65, "moonshot": 60, "mimo": 45, "baichuan": 40, "ollama": 20, "local": 20,
    ]
    public static func rank(_ id: String) -> Int { strength[id.lowercased()] ?? 50 }

    /// Pick the provider for a cycle. `keyed` = provider ids that HAVE a usable key. economy → keep the
    /// session default; standard → step up only to a meaningfully stronger keyed provider; frontier → the
    /// strongest keyed. Never returns a provider weaker than `preferred`.
    public static func pick(tier: EffortController.ModelTier, keyed: [String], preferred: String,
                            exclude: Set<String> = []) -> String {
        // Fault tolerance: a provider that ERRORED this run is routed around (unless it's the only option).
        let usable = keyed.filter { !exclude.contains($0) }
        let candidates = (usable.isEmpty ? (keyed.isEmpty ? [preferred] : keyed) : usable)
        // If the session default itself errored, treat the strongest usable as the floor to beat.
        let base = exclude.contains(preferred) ? (candidates.max(by: { rank($0) < rank($1) }) ?? preferred) : preferred
        let strongest = candidates.max(by: { rank($0) < rank($1) }) ?? base
        switch tier {
        case .economy:  return base
        case .standard:
            // Step up to a MID model, NOT the reasoning-frontier — a moderate task shouldn't pay
            // gpt-5.5/claude reasoning-token cost (live dogfood: a standard task escalated to gpt-5.5 burned
            // ~28k tokens/call and blew the budget). Reserve rank>85 (openai/anthropic) for .frontier.
            let mid = candidates.filter { rank($0) <= 85 }.max(by: { rank($0) < rank($1) }) ?? base
            // If the session default itself is EXCLUDED (it faulted), we MUST move — pick the best MID-tier
            // usable, NOT `base` (the strongest overall = a frontier model). Routing around a broken default
            // shouldn't silently upgrade a standard cycle to gpt-5.5/claude.
            if exclude.contains(preferred) { return mid }
            return rank(mid) > rank(base) + 15 ? mid : base
        case .frontier: return rank(strongest) > rank(base) ? strongest : base
        }
    }
}
