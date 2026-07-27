import Foundation

/// The "great loop": keep working a goal across CYCLES — assess effort → execute a work cycle → verify →
/// learn → re-assess → repeat — until it's genuinely done-and-verified, or a SAFETY CAP stops it. This is
/// what turns the single-turn agent loop into a long-horizon (hours-long) autonomous runner.
///
/// Split in two: `GreatLoopController` is the PURE decision brain (when to keep going vs stop, and WHY —
/// including every safety rail), unit-tested exhaustively; `GreatLoopRunner` is the thin execution shell
/// that drives cycles through an injected `runCycle` (the real agent loop when wired; a stub in tests).

/// Hard limits a long unattended run MUST respect — the non-negotiable rails. A run stops the instant ANY
/// is hit. `noDestructive`/`noAutoMerge` are passed through to the work cycle, not decided here.
public struct GreatLoopCaps: Sendable, Equatable {
    public let maxCycles: Int
    public let maxTokens: Int?          // hard token/$ ceiling (nil = no token cap; a cycle/time cap still bounds it)
    public let deadlineEpoch: Double?   // wall-clock cutoff (nil = none)
    public let noProgressLimit: Int     // stop after this many cycles with no progress (anti-spin)
    public let noDestructive: Bool      // forbid irreversible ops in the work cycle
    public let noAutoMerge: Bool        // never merge/deploy to main unattended
    public init(maxCycles: Int = 30, maxTokens: Int? = nil, deadlineEpoch: Double? = nil,
                noProgressLimit: Int = 3, noDestructive: Bool = true, noAutoMerge: Bool = true) {
        self.maxCycles = max(1, maxCycles)
        self.maxTokens = maxTokens
        self.deadlineEpoch = deadlineEpoch
        self.noProgressLimit = max(1, noProgressLimit)
        self.noDestructive = noDestructive
        self.noAutoMerge = noAutoMerge
    }
}

public struct GreatLoopState: Sendable, Equatable {
    public let cycle: Int
    public let tokensSpent: Int
    public let nowEpoch: Double
    public let lastCycleDoneAndVerified: Bool
    public let consecutiveNoProgress: Int
    public init(cycle: Int, tokensSpent: Int, nowEpoch: Double,
                lastCycleDoneAndVerified: Bool, consecutiveNoProgress: Int) {
        self.cycle = cycle; self.tokensSpent = tokensSpent; self.nowEpoch = nowEpoch
        self.lastCycleDoneAndVerified = lastCycleDoneAndVerified
        self.consecutiveNoProgress = consecutiveNoProgress
    }
}

public enum GreatLoopDecision: Sendable, Equatable {
    case keepGoing(reason: String)
    case stopDone(reason: String)
    case stopBudget(reason: String)
    case stopDeadline(reason: String)
    case stopCycles(reason: String)
    case stopNoProgress(reason: String)
    public var isTerminal: Bool { if case .keepGoing = self { return false }; return true }
    public var succeeded: Bool { if case .stopDone = self { return true }; return false }
}

public enum GreatLoopController {
    /// The single decision point. Order is deliberate: SUCCESS first (a verified done always wins), then the
    /// hard safety caps (budget → deadline → cycles), then the anti-spin guard, else keep going.
    public static func decide(state: GreatLoopState, caps: GreatLoopCaps) -> GreatLoopDecision {
        if state.lastCycleDoneAndVerified {
            return .stopDone(reason: "goal completed and verified in cycle \(state.cycle)")
        }
        if let cap = caps.maxTokens, state.tokensSpent >= cap {
            return .stopBudget(reason: "token ceiling reached (\(state.tokensSpent)/\(cap)) — stopping to respect the budget")
        }
        if let deadline = caps.deadlineEpoch, state.nowEpoch >= deadline {
            return .stopDeadline(reason: "wall-clock deadline reached — stopping")
        }
        if state.cycle >= caps.maxCycles {
            return .stopCycles(reason: "reached the max of \(caps.maxCycles) cycle(s) without a verified finish")
        }
        if state.consecutiveNoProgress >= caps.noProgressLimit {
            return .stopNoProgress(reason: "\(state.consecutiveNoProgress) cycle(s) with no progress — stopping rather than spinning")
        }
        return .keepGoing(reason: "cycle \(state.cycle + 1) — continuing toward a verified finish")
    }
}

/// What one work cycle reports back so the loop can learn + decide.
public struct CycleResult: Sendable {
    public let doneAndVerified: Bool
    public let tokensSpent: Int          // tokens this cycle consumed
    public let madeProgress: Bool        // did anything change / advance
    public let signals: EffortController.Signals   // struggle signals → next assessment
    public let summary: String
    /// The cycle FAILED because the PROVIDER faulted server-side (structured classification, not a string
    /// match). The runner surfaces this so the caller can route around that provider on later cycles.
    public let providerFault: Bool
    public init(doneAndVerified: Bool, tokensSpent: Int, madeProgress: Bool,
                signals: EffortController.Signals, summary: String, providerFault: Bool = false) {
        self.doneAndVerified = doneAndVerified; self.tokensSpent = tokensSpent
        self.madeProgress = madeProgress; self.signals = signals; self.summary = summary
        self.providerFault = providerFault
    }
}

public final class GreatLoopRunner {
    private let goal: String
    private let caps: GreatLoopCaps
    private let memory: EffortMemory
    private let clock: @Sendable () -> Double
    private let runCycle: @Sendable (_ goal: String, _ effort: EffortController.Assessment, _ cycle: Int, _ budgetRemaining: Int?) async -> CycleResult
    private let emit: @Sendable (String) -> Void

    public init(goal: String, caps: GreatLoopCaps, memory: EffortMemory,
                clock: @escaping @Sendable () -> Double,
                runCycle: @escaping @Sendable (_ goal: String, _ effort: EffortController.Assessment, _ cycle: Int, _ budgetRemaining: Int?) async -> CycleResult,
                emit: @escaping @Sendable (String) -> Void = { _ in }) {
        self.goal = goal; self.caps = caps; self.memory = memory
        self.clock = clock; self.runCycle = runCycle; self.emit = emit
    }

    /// Drive the loop to a terminal decision. Each cycle: assess (with learned calibration) → run → score →
    /// record (learn) → update state → decide. Returns why it stopped.
    public func run() async -> GreatLoopDecision {
        let signature = EffortController.signature(for: goal)
        var cycle = 0
        var tokensSpent = 0
        var noProgress = 0
        var lastDone = false
        var signals = EffortController.Signals.cold

        while true {
            let state = GreatLoopState(cycle: cycle, tokensSpent: tokensSpent, nowEpoch: clock(),
                                       lastCycleDoneAndVerified: lastDone, consecutiveNoProgress: noProgress)
            let decision = GreatLoopController.decide(state: state, caps: caps)
            if decision.isTerminal {
                emit(terminalLine(decision))
                return decision
            }

            let calibration = memory.calibration(forGoal: goal)
            let effort = EffortController.assess(goal: goal, signals: signals, calibration: calibration)
            emit("↻ cycle \(cycle + 1)/\(caps.maxCycles) · \(effort.rationale)"
                 + (calibration.samples > 0 ? " · learned±\(calibration.bias) from \(calibration.samples)" : ""))

            let budgetRemaining = caps.maxTokens.map { max(0, $0 - tokensSpent) }
            let result = await runCycle(goal, effort, cycle, budgetRemaining)

            // Learn: record how this cycle ACTUALLY went vs what was predicted.
            let actual = EffortScorer.actualDifficulty(failureRate: result.signals.failureRate,
                                                       iterationsUsed: result.signals.iterationsUsed,
                                                       replansUsed: result.signals.replansUsed,
                                                       wasStuck: result.signals.isStuck)
            let quality = EffortScorer.quality(success: result.doneAndVerified, verified: result.doneAndVerified,
                                               failureRate: result.signals.failureRate,
                                               iterationsUsed: result.signals.iterationsUsed,
                                               iterationBudget: effort.iterationBudget)
            memory.record(EffortOutcome(signature: signature, predicted: effort.complexity, actual: actual,
                                        quality: quality, success: result.doneAndVerified, at: clock()))

            tokensSpent += max(0, result.tokensSpent)
            noProgress = result.madeProgress ? 0 : noProgress + 1
            lastDone = result.doneAndVerified
            signals = result.signals
            cycle += 1
        }
    }

    private func terminalLine(_ d: GreatLoopDecision) -> String {
        switch d {
        case .stopDone(let r):       return "✓ great-loop done — \(r)"
        case .stopBudget(let r):     return "■ great-loop stopped — \(r)"
        case .stopDeadline(let r):   return "■ great-loop stopped — \(r)"
        case .stopCycles(let r):     return "■ great-loop stopped — \(r)"
        case .stopNoProgress(let r): return "■ great-loop stopped — \(r)"
        case .keepGoing(let r):      return r
        }
    }
}
