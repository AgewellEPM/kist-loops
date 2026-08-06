import Foundation
import AgentCore

// `/effort` — the CONFLICT-ESCALATION LADDER. Not a flat "ask everyone at once" (that's `/dig`). This is
// tiered, hostile, and cheap-first: build solo; only when the HARD GATE fails does it escalate, bringing
// in a DISTINCT-vendor adversarial mind whose findings feed the next attempt, then a rater, then the full
// gauntlet. The escalation IS the CaptainController drive loop — each failed gate drives the next, harder
// rung. The gate is the /fix judge (verified, non-monolith artifact — the machine decides, not a vote).
//
//   L1 solo build ──gate fail──▶ L2 (+adversarial reviewer) ──fail──▶ L3 (+rater) ──fail──▶ ULTRA (gauntlet)
//
// Cross-vendor by design: a strong builder, a DIFFERENT reviewer, a THIRD rater — cognitive diversity is
// the point, but the terminal authority is the compile/verify gate, never model consensus.
extension KistREPL {

    /// Parse `/effort [1|2|3|ultra] <goal>` → (startLevel 1...4, goal). No level token ⇒ start at L1.
    static func parseEffortArgs(_ args: String) -> (startLevel: Int, goal: String) {
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return (1, "") }
        let level: Int?
        switch first.lowercased() {
        case "1", "solo":                                 level = 1
        case "2", "pair", "review":                       level = 2
        case "3", "trio", "rate":                         level = 3
        case "4", "ultra", "max", "gauntlet", "fleet":    level = 4
        default:                                          level = nil
        }
        if let level {
            return (level, parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
        }
        return (1, trimmed)   // no level token → the whole thing is the goal, auto-escalate from L1
    }

    /// Run the escalation ladder. Reuses the proven build worker (planExecute → preflight+gate+critic),
    /// the /fix judge (the hard gate), and cross-vendor minds. Returns a HeavyRouteResult (honest: only a
    /// gate-passing build reports .passed).
    func runEffort(goal: String, startLevel: Int) async -> HeavyRouteResult {
        guard let planExecute else {
            return HeavyRouteResult(exitCode: 2, interruption: nil,
                                    review: .notApplicable("build worker unavailable in this mode"),
                                    verification: .unavailable("no worker to drive"))
        }
        let root = projectRoot
        let interrupted = MutableBox<InterruptibleTurn.InterruptReason?>(nil)

        // Cross-vendor cast: strongest reachable builder, a DISTINCT reviewer, a THIRD distinct rater.
        let builder = captainStrongRoles?()?.fallback ?? activeBinding
        let reviewer = autoReviewer(answeredBy: builder) ?? builder
        let rater = autoReviewer(answeredBy: reviewer) ?? reviewer

        let performer = FixBuildPerformer(planExecute: planExecute,
                                          roles: RoleBindings(default: builder),
                                          projectRoot: root,
                                          onInterrupt: { reason in interrupted.value = reason })
        let decider = EscalatingBuildDecider(startLevel: startLevel, projectRoot: root,
                                             grounding: reviewerGrounding(), modelComplete: modelComplete,
                                             builder: builder, reviewer: reviewer, rater: rater)
        // Exclude pre-existing dirt from the monolith gate (review finding) — same as /fix.
        let baselineChanged = Set(KistREPL.workingTreeChangedFiles(projectRoot: root))
        let judge = Self.makeFixJudge(projectRoot: root, baselineChanged: baselineChanged)
        // One shot per rung from startLevel up through ultra — escalate on every failure, bounded.
        let maxTicks = max(1, 5 - min(4, max(1, startLevel)))
        let captain = CaptainController(maxTicks: maxTicks, analysisPatience: 99, judge: judge,
                                        isKilled: { interrupted.value != nil })

        print("\u{001B}[35;1m⚔️  /effort\u{001B}[0m\u{001B}[2m · escalating ladder · builder=\(name(builder)) → reviewer=\(name(reviewer)) → rater=\(name(rater)) · the compile/verify gate decides, not a vote\u{001B}[0m")
        let outcome = await captain.drive(objective: goal, requiresArtifact: true,
                                          decider: decider, performer: performer)

        switch outcome {
        case .completed(let ticks):
            let rung = EscalatingBuildDecider.levelName(min(startLevel + ticks - 1, 4))
            print("\u{001B}[32;1m✓ /effort shipped at \(rung)\u{001B}[0m\u{001B}[2m — verified, non-monolith artifact\u{001B}[0m")
            return HeavyRouteResult(exitCode: 0, interruption: nil,
                                    review: .handledInternally("escalation ladder: adversarial minds critiqued, the gate verified"),
                                    verification: .passed("verified artifact at \(rung)"))
        case .exhausted:
            return HeavyRouteResult(exitCode: 1, interruption: nil,
                                    review: .handledInternally("escalated to the full gauntlet"),
                                    verification: .failed("survived escalation to ultra without a verified build — the change never passed the gate"))
        case .killed:
            return HeavyRouteResult(exitCode: 130, interruption: interrupted.value ?? .cancel,
                                    review: .notApplicable("interrupted"),
                                    verification: .unavailable("the /effort ladder was interrupted"))
        case .handedBack(let reason, _):
            return HeavyRouteResult(exitCode: 1, interruption: nil,
                                    review: .handledInternally("handed back: \(reason)"),
                                    verification: .unavailable("handed back: \(reason)"))
        }
    }

    private func name(_ b: ProviderBinding) -> String { TeamLanguage.displayName(b.providerId) }
}

/// The ladder's decider: each attempt escalates a rung and, from L2 up, brings a distinct adversarial mind
/// in to critique the CURRENT diff, feeding the findings into the next build. Serial (the drive awaits each
/// move) ⇒ `@unchecked Sendable` is safe. Degrades gracefully if no reviewer model is available (builds without findings).
final class EscalatingBuildDecider: CaptainDecider, @unchecked Sendable {
    private let startLevel: Int
    private let projectRoot: String
    private let grounding: String
    private let modelComplete: ((String, String?, String, String) async -> String?)?
    private let builder: ProviderBinding
    private let reviewer: ProviderBinding
    private let rater: ProviderBinding

    init(startLevel: Int, projectRoot: String, grounding: String,
         modelComplete: ((String, String?, String, String) async -> String?)?,
         builder: ProviderBinding, reviewer: ProviderBinding, rater: ProviderBinding) {
        self.startLevel = startLevel; self.projectRoot = projectRoot; self.grounding = grounding
        self.modelComplete = modelComplete
        self.builder = builder; self.reviewer = reviewer; self.rater = rater
    }

    static func levelName(_ level: Int) -> String {
        switch level {
        case 1:  return "effort L1 (solo)"
        case 2:  return "effort L2 (+reviewer)"
        case 3:  return "effort L3 (+rater)"
        default: return "ULTRA (full gauntlet)"
        }
    }

    func propose(objective: String, history: [MoveOutcome], forcedAction: Bool) async -> CaptainMove {
        let level = min(startLevel + history.count, 4)
        switch level {
        case 1:
            print("\u{001B}[36m⚔️  \(Self.levelName(1)) · \(TeamLanguage.displayName(builder.providerId)) writes it\u{001B}[0m")
            return .build(step: objective)
        case 2:
            print("\u{001B}[33m↑ escalating → \(Self.levelName(2)) · \(TeamLanguage.displayName(reviewer.providerId)) rips L1 apart\u{001B}[0m")
            let review = await reviewCurrentDiff(objective: objective)
            return .build(step: augment(objective, review: review, rating: nil, level: 2))
        case 3:
            print("\u{001B}[33m↑ escalating → \(Self.levelName(3)) · \(TeamLanguage.displayName(rater.providerId)) scores success probability\u{001B}[0m")
            let review = await reviewCurrentDiff(objective: objective)
            let rating = await rateCurrentDiff(objective: objective)
            return .build(step: augment(objective, review: review, rating: rating, level: 3))
        default:
            print("\u{001B}[35;1m⚔️  \(Self.levelName(4))\u{001B}[0m\u{001B}[2m · every mind critiques before the gate\u{001B}[0m")
            let review = await reviewCurrentDiff(objective: objective)
            let rating = await rateCurrentDiff(objective: objective)
            return .build(step: augment(objective, review: review, rating: rating, level: 4))
        }
    }

    private func currentDiff() -> String? {
        let diff = KistREPL.workingTreeDiff(projectRoot: projectRoot)
        return diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : diff
    }

    private func reviewCurrentDiff(objective: String) async -> String? {
        guard let modelComplete, let diff = currentDiff() else { return nil }
        let user = BallBusting.prompt(subject: diff, label: "the working-tree diff so far", grounding: grounding)
        return await modelComplete(reviewer.providerId, reviewer.model, BallBusting.systemPrompt, user)
    }

    private func rateCurrentDiff(objective: String) async -> String? {
        guard let modelComplete, let diff = currentDiff() else { return nil }
        let system = "You are a skeptical release manager. Rate 0–100% the probability that the change below "
            + "CORRECTLY and COMPLETELY solves the objective, then in 2–3 lines name the single biggest remaining "
            + "risk. Be honest — do not inflate; a change that doesn't build/test is not high probability."
        let user = "OBJECTIVE:\n\(objective)\n\nCHANGE (working-tree diff):\n\(diff)"
        return await modelComplete(rater.providerId, rater.model, system, user)
    }

    /// Fold the adversarial findings into the next build order so the escalation actually CHANGES the work.
    private func augment(_ objective: String, review: String?, rating: String?, level: Int) -> String {
        var parts = [objective]
        if let review, !review.isEmpty {
            parts.append("An independent reviewer (\(TeamLanguage.displayName(reviewer.providerId))) found these problems — "
                + "FIX every one in this build, do not hand-wave:\n\(review)")
        }
        if let rating, !rating.isEmpty {
            parts.append("A rater (\(TeamLanguage.displayName(rater.providerId))) assessed the current attempt:\n\(rating)\n"
                + "Raise the real success probability by fixing the risks it named.")
        }
        if level >= 4 {
            parts.append("FULL GAUNTLET: the change must survive every critique above AND compile / pass tests. "
                + "Model agreement is not enough — the build gate is the judge.")
        }
        return parts.joined(separator: "\n\n")
    }
}
