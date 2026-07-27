import Foundation

/// Runs an eval suite against an agent. The agent is injected as a closure (so the runner is testable
/// without a live model), returning the run's output + trajectory. Deterministic assertions decide
/// pass/fail; an optional LLM judge adds a subjective-quality score. This is the eval-on-PR gate the
/// frontier (LangSmith/Braintrust) is built around — here, native and provider-agnostic.
public struct EvalRunner: Sendable {
    public struct RunOutcome: Sendable { public let output: String; public let trajectory: [ActionRecord]
        public init(output: String, trajectory: [ActionRecord]) { self.output = output; self.trajectory = trajectory } }

    /// Run one case → its output + trajectory.
    public typealias Agent = @Sendable (_ prompt: String) async -> RunOutcome
    /// Optional subjective scorer: (task, output, rubric) → 0…1.
    public typealias Judge = @Sendable (_ prompt: String, _ output: String) async -> Double?

    private let maxIterations: Int
    public init(maxIterations: Int = 12) { self.maxIterations = maxIterations }

    public func run(_ cases: [EvalCase], agent: Agent, judge: Judge? = nil) async -> EvalReport {
        var results: [EvalCaseResult] = []
        for c in cases {
            let outcome = await agent(c.prompt)
            var failures: [String] = []
            for assertion in c.assertions {
                let (ok, detail) = assertion.check(output: outcome.output, trajectory: outcome.trajectory, maxIterations: maxIterations)
                if !ok { failures.append(detail) }
            }
            let score = await judge?(c.prompt, outcome.output)
            results.append(EvalCaseResult(name: c.name, passed: failures.isEmpty, failures: failures, judgeScore: score))
        }
        return EvalReport(results: results)
    }
}

/// An LLM-as-judge: asks a model to score how well an output satisfies a task, 0..1. Provider-agnostic
/// (any wired model). Subjective by nature — kept SEPARATE from the deterministic assertions so a
/// flaky judge can never silently pass a hard requirement.
public struct LLMJudge: Sendable {
    private let registry: ProviderRegistry
    private let providerId: String
    private let model: String?
    private let budget: BudgetLedger?
    public init(registry: ProviderRegistry, providerId: String, model: String? = nil, budget: BudgetLedger? = nil) {
        self.registry = registry; self.providerId = providerId; self.model = model; self.budget = budget
    }

    public func score(prompt: String, output: String) async -> Double? {
        // Budget-gated like every other model call: past the cap, decline to score (nil) rather than spend.
        if let budget, await budget.isExceeded() { return nil }
        let judgePrompt = """
        Score from 0.0 to 1.0 how well the RESPONSE accomplishes the TASK. Reply with ONLY the number.
        TASK: \(prompt)
        RESPONSE: \(output.prefix(4000))
        """
        let settings = ModelSettings(temperature: 0, maxTokens: 16)
        guard let (text, usage) = try? await registry.completeWithUsage(
            providerId: providerId, model: model,
            messages: [ChatMessage(role: .user, content: judgePrompt)], settings: settings) else { return nil }
        if let budget {
            let measured = usage.isZero
                ? TokenUsage.estimate(promptChars: judgePrompt.count, completionChars: text.count) : usage
            let usd = CompetitiveBenchmark.priceUSD(vendor: providerId,
                                                    promptTokens: measured.promptTokens,
                                                    completionTokens: measured.completionTokens) ?? 0
            await budget.add(tokens: measured.total, usd: usd)
        }
        return Self.parseScore(text)
    }

    /// Pull the first 0..1 float out of the reply.
    static func parseScore(_ text: String) -> Double? {
        guard let m = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text), let v = Double(text[r]) else { return nil }
        return min(max(v > 1 ? v / 100 : v, 0), 1)   // tolerate a 0-100 reply
    }
}
