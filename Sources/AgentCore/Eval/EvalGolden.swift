import Foundation

/// The GOLDEN EVAL SUITE + regression tracking — the "know the instant it regresses" layer (roadmap #1).
/// The eval framework (EvalRunner/EvalCase/assertions) already exists; this adds the three missing pieces:
/// a FIXED suite of representative behaviors, a persisted BASELINE, and REGRESSION detection so a score
/// drop is caught instead of discovered live. The assertions are deterministic (trajectory-grounded), so
/// pass/fail is objective even though the model isn't — the external-verifier anchor the research says is
/// the only thing that actually works.
public enum EvalGoldenSuite {
    /// Bump when the built-in cases change so a baseline from an old suite isn't compared apples-to-oranges.
    public static let version = 1

    /// Safe, project-agnostic, mostly read-only behaviors that MUST keep working. Deliberately small and
    /// side-effect-light so the suite can run anywhere; extend per-project via `.kist/eval/suite.json`.
    public static let builtIn: [EvalCase] = [
        EvalCase(name: "answers-directly",
                 prompt: "What is 2+2? Reply with ONLY the number, nothing else.",
                 assertions: [.outputContains("4"), .trajectoryHealthy, .maxSteps(5), .noToolFailures]),
        EvalCase(name: "uses-tools-without-failing",
                 prompt: "List the files in this project's root directory.",
                 assertions: [.trajectoryHealthy, .noToolFailures, .maxSteps(10)]),
        EvalCase(name: "stays-bounded",
                 prompt: "In two sentences, say what kind of project this looks like based on its files.",
                 assertions: [.trajectoryHealthy, .maxSteps(12), .noToolFailures]),
    ]

    /// The built-in suite plus any project-local cases at `.kist/eval/suite.json` (a JSON array of
    /// {name, prompt, assertions:[{contains:"…"} | {toolCalled:"…"} | "healthy" | "noToolFailures" | {maxSteps:n}]}).
    /// Malformed custom files are ignored (fail-soft) — the built-ins always run.
    public static func cases(projectRoot: String) -> [EvalCase] {
        builtIn + loadCustom(projectRoot: projectRoot, file: "suite.json")
    }

    /// The CAPABILITY-exercising held-out corpus for the ablation oracle (P0.5). Distinct from the golden
    /// regression suite: these are tasks where ACCUMULATED state (a `self__` tool, a recalled winning
    /// approach) can help — the surface on which a WARM-vs-COLD advantage can actually appear. The golden
    /// suite is basic-behavior checks (both arms pass 100% ⇒ +0%); this is where compounding shows up.
    /// Empty built-in on purpose: it's seeded from `.kist/eval/capability-suite.json` and, later, grown by
    /// the flywheel (a promoted skill deposits a capability case). Honest note: with only a trivial accumulated
    /// tool the advantage may still read ~0 — the corpus is the right SURFACE; a non-zero number needs
    /// non-trivial accumulated capability + the read-back wires (P1/P2).
    public static let capabilityBuiltIn: [EvalCase] = []

    public static func capabilityCases(projectRoot: String) -> [EvalCase] {
        capabilityBuiltIn + loadCustom(projectRoot: projectRoot, file: "capability-suite.json")
    }

    /// P1 — the RECALL corpus: memory-dependent tasks answerable only from a locally checked advisory lesson (not
    /// general knowledge, not a self__ tool). This is the surface `/ablation recall` uses to isolate the P1
    /// injection A/B (injection-OFF vs injection-ON, toolset held constant). Empty built-in on purpose:
    /// seeded from `.kist/eval/recall-suite.json` with project-specific facts whose only source is memory.
    public static let recallBuiltIn: [EvalCase] = []

    public static func recallCases(projectRoot: String) -> [EvalCase] {
        recallBuiltIn + loadCustom(projectRoot: projectRoot, file: "recall-suite.json")
    }

    static func loadCustom(projectRoot: String, file: String) -> [EvalCase] {
        let path = projectRoot + "/.kist/eval/" + file
        guard let data = FileManager.default.contents(atPath: path),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return raw.compactMap { obj -> EvalCase? in
            guard let name = obj["name"] as? String, let prompt = obj["prompt"] as? String else { return nil }
            let assertions = (obj["assertions"] as? [Any] ?? []).compactMap(parseAssertion)
            return EvalCase(name: name, prompt: prompt, assertions: assertions)
        }
    }

    private static func parseAssertion(_ a: Any) -> EvalAssertion? {
        if let s = a as? String {
            switch s.lowercased() {
            case "healthy", "trajectoryhealthy": return .trajectoryHealthy
            case "notoolfailures":               return .noToolFailures
            default:                             return nil
            }
        }
        guard let o = a as? [String: Any] else { return nil }
        if let s = o["contains"] as? String    { return .outputContains(s) }
        if let s = o["matches"] as? String      { return .outputMatches(s) }
        if let s = o["toolCalled"] as? String   { return .toolCalled(s) }
        if let s = o["toolNotCalled"] as? String { return .toolNotCalled(s) }
        if let n = o["maxSteps"] as? Int         { return .maxSteps(n) }
        return nil
    }
}

/// One suite run's outcome, persisted so later runs can detect a drop.
public struct EvalRunSummary: Codable, Sendable, Equatable {
    public let suiteVersion: Int
    public let atEpoch: Double
    public let passed: Int
    public let total: Int
    public let caseResults: [String: Bool]     // case name → passed
    public let build: String?                   // the kist build/version this ran against, if known

    public init(suiteVersion: Int, atEpoch: Double, passed: Int, total: Int,
                caseResults: [String: Bool], build: String? = nil) {
        self.suiteVersion = suiteVersion; self.atEpoch = atEpoch
        self.passed = passed; self.total = total; self.caseResults = caseResults; self.build = build
    }
    public var passRate: Double { total == 0 ? 0 : Double(passed) / Double(total) }
}

/// What changed vs the baseline. A per-case regression (passed→fail) is the strongest signal; a pass-rate
/// drop is the coarse one. Either fails the gate.
public struct EvalRegression: Sendable, Equatable {
    public let regressedCases: [String]         // passed in baseline, FAIL now
    public let fixedCases: [String]             // failed in baseline, pass now
    public let passRateDelta: Double            // now − baseline (negative = worse)
    public let hadBaseline: Bool
    public var isRegression: Bool { hadBaseline && (!regressedCases.isEmpty || passRateDelta < -0.0001) }

    /// Compare a fresh summary to the baseline (typically the previous run). No baseline ⇒ never a regression.
    public static func compare(current: EvalRunSummary, baseline: EvalRunSummary?) -> EvalRegression {
        guard let baseline else {
            return EvalRegression(regressedCases: [], fixedCases: [], passRateDelta: 0, hadBaseline: false)
        }
        var regressed: [String] = []
        var fixed: [String] = []
        for (name, nowPass) in current.caseResults {
            guard let wasPass = baseline.caseResults[name] else { continue }   // only compare shared cases
            if wasPass && !nowPass { regressed.append(name) }
            if !wasPass && nowPass { fixed.append(name) }
        }
        return EvalRegression(regressedCases: regressed.sorted(), fixedCases: fixed.sorted(),
                              passRateDelta: current.passRate - baseline.passRate, hadBaseline: true)
    }
}

/// Append-only history of suite runs at `.kist/eval/history.jsonl`; the baseline is the most recent run of
/// the SAME suite version (comparing across suite versions would be apples-to-oranges).
public final class EvalHistoryStore {
    public static let relativePath = ".kist/eval/history.jsonl"
    private let path: String
    private let maxRuns: Int
    public init(projectRoot: String, maxRuns: Int = 500) {
        self.path = projectRoot + "/" + Self.relativePath
        self.maxRuns = max(10, maxRuns)
    }

    public func load() -> [EvalRunSummary] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            $0.data(using: .utf8).flatMap { try? JSONDecoder().decode(EvalRunSummary.self, from: $0) }
        }
    }

    /// The baseline to compare a new run against: the most recent prior run of the same suite version.
    public func baseline(suiteVersion: Int) -> EvalRunSummary? {
        load().last { $0.suiteVersion == suiteVersion }
    }

    public func record(_ summary: EvalRunSummary) {
        var all = load()
        all.append(summary)
        if all.count > maxRuns { all = Array(all.suffix(maxRuns)) }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let text = all.compactMap { (try? JSONEncoder().encode($0)).flatMap { String(data: $0, encoding: .utf8) } }
            .joined(separator: "\n")
        try? (text + (text.isEmpty ? "" : "\n")).write(toFile: path, atomically: true, encoding: .utf8)
    }

    public static func summarize(_ report: EvalReport, suiteVersion: Int, at: Double, build: String?) -> EvalRunSummary {
        var byName: [String: Bool] = [:]
        for r in report.results { byName[r.name] = r.passed }
        return EvalRunSummary(suiteVersion: suiteVersion, atEpoch: at, passed: report.passed,
                              total: report.total, caseResults: byName, build: build)
    }
}
