import Foundation

/// The CONTROLLER half of the Captain — the deterministic loop-OWNER that sits ON TOP of the agent.
///
/// kist already has the JUDGE half (`SymbolicCaptain`): given facts, it rules green/blocked/drift.
/// What was missing — and what let the agent drift into "analyze forever, never build" — is THIS:
/// the boss that OWNS the loop and makes the LLM a subordinate PROPOSER. Today `HeadlessAgentLoop`
/// is owned by the model: it loops, the model picks tools, and it ends when the MODEL says "done".
/// So a cautious model completes a build objective by *analyzing* it (analysis is safe, building is
/// risky), declares done, and parks. This type inverts that.
///
/// INVERSION OF CONTROL (the whole point):
///   Captain.drive(objective) OWNS the loop. Each tick:
///     1. decider.propose(...)        → a MOVE   (the LLM proposes; it does NOT decide)
///     2. the Captain GATES the move  → approve / override-to-action / reject premature "done"
///     3. performer.perform(move)     → an outcome (did it produce a real ARTIFACT?)
///     4. the Captain records it and asks the JUDGE if the objective is truly met
///   The loop ends when the JUDGE says done — NEVER because the model claimed done.
///
/// Ported from TinkySDR's `AutonomousCaptainHarness` + `CaptainDriveLoop` safety spine, plus the one
/// thing the original lacked: ACTION-FORCING. On a build objective, an analysis-only tick is
/// non-progress; after `analysisPatience` of them the Captain OVERRIDES the proposer and issues a
/// direct build order. That is the teeth against "it knows what to fix but never acts".
///
/// SAFETY — structural, not by convention (same invariants as the TinkySDR spine):
///   • BOUNDED by `maxTicks` — no unbounded loop, no recursion, no timer.
///   • KILL checked at the TOP of every tick — a stop is honored promptly.
///   • `performer.perform` is reached from exactly ONE place, only for an approved move.
///   • OFF unless explicitly driven — there is no ambient/auto start; a caller must call `drive`.
///   • All stored state is immutable (`let` + `@Sendable` closures) — the controller cannot
///     mutate itself, so it cannot acquire new capability mid-run.
///
/// LABEL: PROTOTYPE — the deterministic spine, fully unit-tested with fakes. Not yet wired to the
/// live loop; that is a separate, flag-gated increment (`--captain`).

// MARK: - Moves & outcomes

/// One move the Captain can run. The key distinction is ACTION vs ANALYSIS: only an action is
/// expected to produce an artifact, and only analysis can be "forced" into an action.
public enum CaptainMove: Sendable, Equatable {
    case build(step: String)        // an ACTION that should produce a real artifact (file/diff/build)
    case investigate(step: String)  // ANALYSIS: read/search/reason — no artifact expected
    case handBack(reason: String)   // legitimately needs the human — a valid terminal move
    case declareDone                // the proposer CLAIMS the objective is met (a claim, not a verdict)

    public var isAction: Bool { if case .build = self { return true }; return false }
}

/// What a performed move actually did. `producedArtifact` is the anti-analysis signal: a move that
/// only read/reasoned did not build anything, no matter how good the reasoning.
public struct MoveOutcome: Sendable, Equatable {
    public let success: Bool
    public let producedArtifact: Bool
    public let summary: String
    public init(success: Bool, producedArtifact: Bool, summary: String) {
        self.success = success
        self.producedArtifact = producedArtifact
        self.summary = summary
    }
}

/// The deterministic completion verdict over the run so far.
public enum CaptainVerdict: Sendable, Equatable {
    case done
    case notDone(reason: String)
}

/// How a drive ended. Every case names the tick so a caller can see how far the Captain got.
public enum CaptainDriveOutcome: Sendable, Equatable {
    case completed(ticks: Int)              // the JUDGE confirmed the objective is met
    case exhausted(ticks: Int)              // hit maxTicks without a done verdict — bounded, honest
    case killed(tick: Int)                  // cooperative stop honored
    case handedBack(reason: String, tick: Int)
}

// MARK: - Injected organs (the LLM is behind these — a subordinate tool)

/// Proposes the next move. The LLM adapter implements this; tests use a fake. `forcedAction == true`
/// means the Captain is ORDERING a concrete artifact this tick — the proposer must return a `.build`.
public protocol CaptainDecider: Sendable {
    func propose(objective: String, history: [MoveOutcome], forcedAction: Bool) async -> CaptainMove
}

/// Executes an approved move and reports what actually happened. The real agent-loop adapter
/// implements this; tests use a fake.
public protocol CaptainPerformer: Sendable {
    func perform(_ move: CaptainMove, objective: String) async -> MoveOutcome
}

// MARK: - The controller

public final class CaptainController: Sendable {

    /// Hard upper bound on ticks. Immutable so a run can never extend itself. Clamped to ≥1.
    public let maxTicks: Int
    /// Consecutive analysis-only ticks tolerated on a build objective before the Captain forces an
    /// action. 0 = force action immediately after any analysis; the default (2) allows a little
    /// looking-around before it demands a build. Clamped to ≥0.
    public let analysisPatience: Int

    /// The deterministic completion judge. Injected so increment 2 can supply a `SymbolicCaptain`-
    /// backed judge without changing the spine. Defaults to the conservative artifact-grounded rule.
    private let judge: @Sendable (_ objective: String, _ history: [MoveOutcome]) -> CaptainVerdict
    /// Cooperative kill switch, checked at the TOP of every tick.
    private let isKilled: @Sendable () -> Bool

    public init(maxTicks: Int = 12,
                analysisPatience: Int = 2,
                judge: @escaping @Sendable (String, [MoveOutcome]) -> CaptainVerdict = { CaptainController.defaultJudge(objective: $0, history: $1) },
                isKilled: @escaping @Sendable () -> Bool = { false }) {
        self.maxTicks = max(1, maxTicks)
        self.analysisPatience = max(0, analysisPatience)
        self.judge = judge
        self.isKilled = isKilled
    }

    /// The conservative, artifact-grounded default judge. A build objective is DONE only when the
    /// history contains a successful artifact-producing move and the last move did not fail —
    /// analysis alone is NEVER done. Deterministic: same history → same verdict.
    public static func defaultJudge(objective: String, history: [MoveOutcome]) -> CaptainVerdict {
        guard history.contains(where: { $0.success && $0.producedArtifact }) else {
            return .notDone(reason: "no successful artifact produced yet — analysis is not completion")
        }
        if let last = history.last, !last.success {
            return .notDone(reason: "the last move failed — a failure is not completion")
        }
        return .done
    }

    /// Own the loop and drive `objective` to completion.
    ///
    /// - Parameter requiresArtifact: true for a BUILD objective (done must be proven by an artifact,
    ///   and analysis-only ticks are forced toward action). false for a pure ANALYSIS objective
    ///   (e.g. "analyze yourself") — there, a `.declareDone` is accepted, because analyzing IS the job.
    public func drive(objective: String,
                      requiresArtifact: Bool,
                      decider: CaptainDecider,
                      performer: CaptainPerformer) async -> CaptainDriveOutcome {
        var history: [MoveOutcome] = []
        var consecutiveAnalysis = 0

        for tick in 1...maxTicks {
            // (1) Kill check at the TOP — a stop is honored before any work.
            if isKilled() { return .killed(tick: tick) }

            // (2) ACTION-FORCING: on a build objective, once the proposer has only analyzed for too
            //     long, the Captain ORDERS an artifact this tick and tells the proposer so.
            let forceAction = requiresArtifact && consecutiveAnalysis >= analysisPatience

            var move = await decider.propose(objective: objective, history: history, forcedAction: forceAction)

            // (3) OVERRIDE the dodge: if action is forced but the proposer STILL tried to analyze or
            //     to declare done without proof, the Captain converts it to a direct build order. The
            //     model does not get to keep talking when it was told to build.
            if forceAction, !move.isAction {
                move = .build(step: "FORCED BUILD — produce a concrete artifact toward the objective now, "
                             + "no more analysis: \(objective)")
            }

            switch move {
            case .handBack(let reason):
                return .handedBack(reason: reason, tick: tick)

            case .declareDone:
                // The LLM does NOT end the loop — the JUDGE does. For a pure analysis objective,
                // analyzing is the deliverable, so a claimed done is accepted.
                if !requiresArtifact { return .completed(ticks: tick) }
                switch judge(objective, history) {
                case .done:
                    return .completed(ticks: tick)
                case .notDone(let reason):
                    // Claimed done but unproven → record the rejection and force action next tick.
                    // Critically, we do NOT stop: a premature "done" is the exact failure to break.
                    history.append(MoveOutcome(success: false, producedArtifact: false,
                                               summary: "Captain rejected premature done: \(reason)"))
                    consecutiveAnalysis += 1
                }

            case .investigate, .build:
                // (4) THE SOLE perform site — reached only for an approved (or Captain-forced) move.
                let outcome = await performer.perform(move, objective: objective)
                history.append(outcome)
                if move.isAction && outcome.producedArtifact {
                    consecutiveAnalysis = 0            // real progress resets the patience counter
                } else {
                    consecutiveAnalysis += 1           // analysis, or a build that produced nothing
                }
                // Did that move complete the objective? Deterministic, artifact-grounded.
                if case .done = judge(objective, history) { return .completed(ticks: tick) }
            }
        }

        // Cap reached without a done verdict. Bounded and honest — not a hang.
        return .exhausted(ticks: maxTicks)
    }
}
