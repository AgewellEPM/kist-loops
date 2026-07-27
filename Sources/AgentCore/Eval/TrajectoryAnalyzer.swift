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
    public init(tool: String, argsFingerprint: String, success: Bool, failureDetail: String? = nil) {
        self.tool = tool; self.argsFingerprint = argsFingerprint; self.success = success
        self.failureDetail = failureDetail
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
    /// Analyze a sequence of actions. `maxIterations` lets us flag a run that's about to exhaust its
    /// budget. Pure → unit-tested.
    public static func analyze(_ steps: [ActionRecord],
                               maxIterations: Int = 0,
                               runawayThreshold: Int = 3,
                               failureRateThreshold: Double = 0.5) -> TrajectoryReport {
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

        // 4) No mutating progress: many calls, none of them an edit/write/run (read-only spinning).
        let mutating: Set<String> = ["write_file", "edit_file", "run_command"]
        if toolCalls >= 6, !steps.contains(where: { mutating.contains($0.tool) }) {
            issues.append(.init(kind: .noToolProgress,
                                detail: "\(toolCalls) tool calls, none mutating — possible read-only spin",
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
