import Foundation

/// A deterministic assertion about an agent run's output + trajectory. The backbone of regression
/// eval: unit-checkable claims ("the output mentions X", "it called build", "no tool failed") that
/// can gate CI without an LLM. (Subjective quality is the separate LLM-judge layer.)
public enum EvalAssertion: Sendable, Equatable {
    case outputContains(String)
    case outputMatches(String)       // regex
    case toolCalled(String)
    case toolNotCalled(String)
    case toolsInOrder([String])
    case noToolFailures
    case maxSteps(Int)
    case trajectoryHealthy           // no runaway loop / failure spike (TrajectoryAnalyzer)

    /// Returns (passed, human-readable detail).
    public func check(output: String, trajectory: [ActionRecord], maxIterations: Int) -> (Bool, String) {
        switch self {
        case .outputContains(let s):
            return (output.localizedCaseInsensitiveContains(s), "output contains \"\(s)\"")
        case .outputMatches(let pattern):
            let ok = (try? NSRegularExpression(pattern: pattern))?.firstMatch(
                in: output, range: NSRange(output.startIndex..., in: output)) != nil
            return (ok, "output matches /\(pattern)/")
        case .toolCalled(let t):
            return (trajectory.contains { $0.tool == t }, "tool \(t) was called")
        case .toolNotCalled(let t):
            return (!trajectory.contains { $0.tool == t }, "tool \(t) was NOT called")
        case .toolsInOrder(let tools):
            var cursor = 0
            for step in trajectory where cursor < tools.count && step.tool == tools[cursor] {
                cursor += 1
            }
            return (cursor == tools.count, "tools appeared in order: \(tools.joined(separator: " → "))")
        case .noToolFailures:
            let fails = trajectory.filter { !$0.success }.count
            return (fails == 0, "no tool failures (\(fails) failed)")
        case .maxSteps(let n):
            return (trajectory.count <= n, "≤ \(n) steps (\(trajectory.count))")
        case .trajectoryHealthy:
            let report = TrajectoryAnalyzer.analyze(trajectory, maxIterations: maxIterations)
            return (report.healthy, "trajectory healthy (\(report.issues.count) issues)")
        }
    }
}

public struct EvalCase: Sendable, Equatable {
    public let name: String
    public let prompt: String
    public let assertions: [EvalAssertion]
    public init(name: String, prompt: String, assertions: [EvalAssertion]) {
        self.name = name; self.prompt = prompt; self.assertions = assertions
    }
}

public struct EvalCaseResult: Sendable, Equatable {
    public let name: String
    public let passed: Bool
    public let failures: [String]      // assertions that failed
    public let judgeScore: Double?     // optional LLM-judge score 0…1
    public init(name: String, passed: Bool, failures: [String], judgeScore: Double? = nil) {
        self.name = name; self.passed = passed; self.failures = failures; self.judgeScore = judgeScore
    }
}

public struct EvalReport: Sendable, Equatable {
    public let results: [EvalCaseResult]
    public var passed: Int { results.filter(\.passed).count }
    public var total: Int { results.count }
    /// Did the suite clear the bar? (CI gate.)
    public var allPassed: Bool { results.allSatisfy(\.passed) }

    public func render() -> String {
        var s = "Eval · \(passed)/\(total) cases passed\n"
        for r in results {
            s += (r.passed ? "✓ " : "✗ ") + r.name
            if let j = r.judgeScore { s += " (judge \(String(format: "%.2f", j)))" }
            s += "\n"
            for f in r.failures { s += "    ✗ \(f)\n" }
        }
        return s
    }
}
