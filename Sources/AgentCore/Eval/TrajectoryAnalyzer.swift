import Foundation

/// One step in an agent's trajectory — the unit observability operates on. A tool call + whether it
/// succeeded + a fingerprint of its arguments (so repeats are detectable without storing full args).
public struct ActionRecord: Sendable, Equatable, Codable {
    public let tool: String
    public let argsFingerprint: String
    public let success: Bool
    /// Truncated failure output (e.g. a compiler/test error) for a FAILED tool call — so the great-loop can
    /// carry the concrete error forward to the next cycle instead of the model rediscovering it. nil on
    /// success or when no detail was captured.
    public let failureDetail: String?
    /// Argument-aware effect captured before fingerprints truncate values. Optional so checkpoints written
    /// by older binaries continue to decode; consumers fall back to the central legacy classifier.
    public let effectObservation: ToolEffectObservation?

    public init(tool: String, argsFingerprint: String, success: Bool, failureDetail: String? = nil,
                effectObservation: ToolEffectObservation? = nil) {
        self.tool = tool; self.argsFingerprint = argsFingerprint; self.success = success
        self.failureDetail = failureDetail
        self.effectObservation = effectObservation
    }

    public var observedEffects: ToolEffectObservation {
        effectObservation ?? ToolEffectCatalog.inferLegacy(tool: tool, argsFingerprint: argsFingerprint)
    }
}

/// A detected reliability problem in a trajectory. Research is blunt: most agent incidents are
/// tool-call failures, context truncation, and runaway loops — NOT model errors — and standard APM
/// can't see them. This analyzer detects exactly those, deterministically, with evidence (step indices).
public struct TrajectoryIssue: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case runawayLoop, failureSpike, nearIterationBudget, noToolProgress }
    public let kind: Kind
    public let detail: String
    public let stepIndices: [Int]
    public init(kind: Kind, detail: String, stepIndices: [Int]) {
        self.kind = kind; self.detail = detail; self.stepIndices = stepIndices
    }
}

public struct TrajectoryReport: Sendable, Equatable, Codable {
    public let totalSteps: Int
    public let toolCalls: Int
    public let failures: Int
    public let issues: [TrajectoryIssue]
    public var failureRate: Double { toolCalls == 0 ? 0 : Double(failures) / Double(toolCalls) }
    public var healthy: Bool { issues.isEmpty }

    public func render() -> String {
        var s = "Trajectory · \(totalSteps) steps · \(toolCalls) tool calls · \(failures) failed (\(Int(failureRate * 100))%)\n"
        if issues.isEmpty { s += "no reliability issues detected." ; return s }
        for i in issues { s += "⚠ \(i.kind.rawValue): \(i.detail) [steps \(i.stepIndices.map(String.init).joined(separator: ","))]\n" }
        return s
    }
}

public enum TrajectoryAnalyzer {
    /// Compatibility projection for callers that displayed the old catalog. Progress decisions must use
    /// the per-invocation observation: membership alone cannot distinguish `swift test` from `ls`.
    @available(*, deprecated, message: "Use ActionRecord.observedEffects.advancesBuild")
    public static let buildProgressTools: Set<String> =
        ToolEffectCatalog.knownMutationTools.union(ToolEffectCatalog.knownCommandTools)

    /// Analyze a sequence of actions. `maxIterations` lets us flag a run that's about to exhaust its
    /// budget. `taskIntent` is opt-in because read-only chat/research/review work is real work; only
    /// an explicit build intent should be warned for spending many calls without making a change.
    /// Pure → unit-tested.
    public static func analyze(_ steps: [ActionRecord],
                               maxIterations: Int = 0,
                               runawayThreshold: Int = 3,
                               failureRateThreshold: Double = 0.5,
                               taskIntent: TaskBrief.Intent? = nil) -> TrajectoryReport {
        let toolCalls = steps.count
        let failures = steps.filter { !$0.success }.count
        var issues: [TrajectoryIssue] = []

        // 1) Runaway loop: the SAME (tool, args) repeated ≥ threshold within a sliding window. The
        // classic "stuck retrying the identical action" failure.
        var run: [Int] = []
        func flushRun() {
            if run.count >= runawayThreshold {
                let key = "\(steps[run[0]].tool)(\(steps[run[0]].argsFingerprint))"
                issues.append(.init(kind: .runawayLoop, detail: "repeated \(key) \(run.count)× in a row", stepIndices: run))
            }
            run = []
        }
        for (i, step) in steps.enumerated() {
            if let last = run.last, steps[last].tool == step.tool, steps[last].argsFingerprint == step.argsFingerprint {
                run.append(i)
            } else { flushRun(); run = [i] }
        }
        flushRun()

        // 1b) Cyclic loop: a short pattern (len 2…4) repeated back-to-back ≥ runawayThreshold times —
        // catches alternating spins (read A → test → read A → test …) that the consecutive check misses.
        if issues.allSatisfy({ $0.kind != .runawayLoop }) {
            let keys = steps.map { "\($0.tool)(\($0.argsFingerprint))" }
            outer: for len in 2...4 where keys.count >= len * runawayThreshold {
                for start in 0...(keys.count - len * runawayThreshold) {
                    let cycle = Array(keys[start..<start + len])
                    var reps = 0, j = start
                    while j + len <= keys.count, Array(keys[j..<j + len]) == cycle { reps += 1; j += len }
                    if reps >= runawayThreshold {
                        let indices = Array(start..<(start + reps * len))
                        issues.append(.init(kind: .runawayLoop,
                                            detail: "cyclic pattern of \(len) actions repeated \(reps)×",
                                            stepIndices: indices))
                        break outer
                    }
                }
            }
        }

        // 2) Failure spike: a high share of tool calls failed (over a meaningful sample).
        if toolCalls >= 4, Double(failures) / Double(toolCalls) > failureRateThreshold {
            issues.append(.init(kind: .failureSpike,
                                detail: "\(failures)/\(toolCalls) tool calls failed",
                                stepIndices: steps.enumerated().filter { !$0.element.success }.map { $0.offset }))
        }

        // 3) Near the iteration budget — likely to get cut off (context/loop pressure).
        if maxIterations > 0, toolCalls >= Int(Double(maxIterations) * 0.8) {
            issues.append(.init(kind: .nearIterationBudget,
                                detail: "\(toolCalls) steps vs budget \(maxIterations) — may be truncated",
                                stepIndices: []))
        }

        // 4) No mutating progress applies ONLY to a build. Research, chat, review, and plan turns can
        // correctly use many read/search calls and then answer. Require a successful progress action:
        // a failed edit attempt did not actually move the build forward, and a successful `ls` is still
        // only inspection. Effects come from the shared catalog/recorded observation, not a local name set.
        if taskIntent?.expectsMutation == true, toolCalls >= 6,
           !steps.contains(where: { $0.success && $0.observedEffects.advances(intent: taskIntent) }) {
            issues.append(.init(kind: .noToolProgress,
                                detail: "\(toolCalls) tool calls for a build, none made mutating/execution progress — possible read-only spin",
                                stepIndices: []))
        }

        return TrajectoryReport(totalSteps: steps.count, toolCalls: toolCalls, failures: failures, issues: issues)
    }

    /// A stable, compact fingerprint of tool args (so repeats match without storing full payloads).
    public static func fingerprint(_ args: [String: Any]) -> String {
        let parts = args.keys.sorted().map { key -> String in
            let v = args[key]
            let s = (v as? String) ?? (v.map { "\($0)" } ?? "")
            return "\(key)=\(s.prefix(40))"
        }
        return parts.joined(separator: "&")
    }
}
