import Foundation

/// Sentinel passed to `fallbackFinalPlan` when the council halts on `--budget` rather than a provider
/// error — so the fallback plan reads as an honest budget stop, not a failure.
struct CouncilBudgetExceeded: Error, CustomStringConvertible {
    var description: String { "token budget exceeded — council synthesized from completed minds without a final model call" }
}

/// Thrown by `AICouncil.withTimeout` when a wide-council mind exceeds its wall-clock budget, so one hung
/// provider degrades to a `failed` mind instead of stalling the whole panel.
struct CouncilMindTimeout: Error, CustomStringConvertible {
    var description: String { "mind timed out" }
}

public struct CouncilMindResult: Sendable, Codable, Equatable {
    public let name: String
    public let role: String
    public let binding: ProviderBinding?
    public let output: String
    public let failed: Bool

    public init(name: String, role: String, binding: ProviderBinding?, output: String, failed: Bool = false) {
        self.name = name
        self.role = role
        self.binding = binding
        self.output = output
        self.failed = failed
    }
}

public struct CouncilRunResult: Sendable, Codable, Equatable {
    public let goal: String
    public let minds: [CouncilMindResult]
    public let finalPlan: String
    public let markdown: String
    public let builderBrief: String

    public init(goal: String, minds: [CouncilMindResult], finalPlan: String, markdown: String, builderBrief: String) {
        self.goal = goal
        self.minds = minds
        self.finalPlan = finalPlan
        self.markdown = markdown
        self.builderBrief = builderBrief
    }
}

/// A role-bound "agent conference" for turning research into a decision and executable board.
///
/// The council is deliberately lighter than a fleet: it does not edit files or run tools. It asks
/// several model minds for opinions, records disagreement, then has the planner produce a builder
/// brief. The resulting markdown can be handed to plan-execute or saved as a kanban artifact.
public struct AICouncil: Sendable {
    public typealias ProgressSink = @Sendable (_ status: String, _ message: String) async -> Void

    private let providers: ProviderRegistry
    private let roles: RoleBindings
    private let memoryContext: String?
    private let researchDossier: String?
    private let recorder: TraceRecorder?
    private let progress: ProgressSink?
    /// Token ceiling for the council (--budget). Previously the council/research paths were the one
    /// big uncapped hole the cost-cap review flagged: every mind turn + the final synthesis spent
    /// freely. nil = uncapped.
    private let budget: BudgetLedger?
    /// Project root for GROUNDING the critic's code findings against real source (ReviewFindingVerifier).
    /// When set, a finding the critic emits that quotes code NOT present in the repo is flagged as likely
    /// fabricated — the antidote to a high-recall model's confident false positives, exactly the discipline
    /// a careful human applies by reading the cited code. nil = no grounding (e.g. a pure design council
    /// with no codebase to check against).
    private let projectRoot: String?
    /// The SECOND grounding gate: skeptics that judge whether a GROUNDED finding is a REAL bug (not just
    /// that its code exists). With a non-empty panel, a grounded finding is CONFIRMED only when a strict
    /// minority refute it; otherwise it's refutedPanel and dropped from the planner. Empty (default) = no
    /// panel ⇒ grounded findings stay `.unverified` (existence-only), as before. These cost model calls,
    /// so the caller opts in (and budget-gates) by passing refuters.
    private let refuters: [ReviewFindingRefuter]

    public init(providers: ProviderRegistry, roles: RoleBindings, memoryContext: String? = nil,
                researchDossier: String? = nil, recorder: TraceRecorder? = nil,
                progress: ProgressSink? = nil, budget: BudgetLedger? = nil, projectRoot: String? = nil,
                refuters: [ReviewFindingRefuter] = []) {
        self.providers = providers
        self.roles = roles
        self.memoryContext = memoryContext
        self.researchDossier = researchDossier
        self.recorder = recorder
        self.progress = progress
        self.budget = budget
        self.projectRoot = projectRoot
        self.refuters = refuters
    }

    public func run(goal: String) async -> CouncilRunResult {
        let normalizedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        await heartbeat(status: "council", message: "council started")
        var minds: [CouncilMindResult] = []

        let researcher = await ask(
            name: "Researcher", role: .worker,
            brief: """
            Extract the strongest facts, market signals, repo observations, and uncertainty from the user's research/task.
            Do not invent sources. If the supplied research is incomplete, say exactly what still needs verification.
            Output concise bullets.
            """,
            goal: normalizedGoal,
            prior: minds
        )
        minds.append(researcher)

        let architect = await ask(
            name: "Architect", role: .planner,
            brief: """
            Turn the research into an architecture direction. Identify the next build primitive, the system boundary,
            and what should not be built yet. Output concise bullets.
            """,
            goal: normalizedGoal,
            prior: minds
        )
        minds.append(architect)

        let coder = await ask(
            name: "Coder", role: .coder,
            brief: """
            Evaluate buildability. Name likely modules, tests, migration risks, and the smallest first implementation.
            Output concise bullets that a builder can act on.
            """,
            goal: normalizedGoal,
            prior: minds
        )
        minds.append(coder)

        // The structured-finding instruction is added ONLY when we can ground against a real codebase
        // (projectRoot set). With no codebase, asking for code quotes we can't verify would be noise — and
        // it keeps the nil-projectRoot path a TRUE no-op vs. the original critic behavior (Codex MED).
        let criticBrief = """
            Attack the proposal. Find failure modes, vague claims, scope creep, missing tests, and where the plan could
            become a messy clone instead of a defensible system.
            Output concise bullets and be specific.
            """ + (projectRoot == nil ? "" : """


            For any CONCRETE finding about EXISTING code (a real bug/risk at a specific place), ALSO emit a
            machine-checkable block so it can be GROUNDED against the source — a finding whose quoted code is
            not actually in the file will be flagged as likely fabricated and DROPPED before the plan is built.
            Quote the REAL code (a substantial snippet, not a single ubiquitous token):
            <<<FINDING
            severity: HIGH|MED|LOW
            file: <project-relative path>
            line: <1-based line, optional>
            claim: <one line>
            code: <the exact code you are flagging, copied verbatim from the file>
            FINDING>>>
            Only emit a block when you can quote real code; omit it for purely strategic critique.
            """)
        let critic = await ask(
            name: "Critic", role: .critic,
            brief: criticBrief,
            goal: normalizedGoal,
            prior: minds
        )
        minds.append(critic)

        let ux = await ask(
            name: "UX", role: .worker,
            brief: """
            Speak for the human at the terminal. Identify the magic moment, confusing commands, missing feedback, and
            the smallest interface that would feel natural.
            Output concise bullets.
            """,
            goal: normalizedGoal,
            prior: minds
        )
        minds.append(ux)

        minds.append(memoryMind())

        // GROUND the critic's code findings against the real source BEFORE the final synthesis (Codex
        // HIGH: if grounding runs after finalDecision, the planner has already consumed a fabricated
        // finding). The PLANNER sees a sanitized critic — raw finding blocks removed, un-grounded ones
        // dropped — so a high-recall model's confident false positive can't reach the plan. The human
        // transcript keeps the ORIGINAL critic plus a grounding-verdict section.
        var mindsForDecision = minds
        var groundingSection = ""
        if let projectRoot, let idx = minds.firstIndex(where: { $0.name == "Critic" && !$0.failed }) {
            let findings = ReviewFindingVerifier.parse(minds[idx].output)
            let verified = findings.isEmpty ? []
                : await ReviewFindingVerifier.verify(findings: findings, projectRoot: projectRoot, panel: refuters)
            // ALWAYS sanitize the planner's view of the Critic when grounding is active — even with no
            // PARSED findings — so an UNTERMINATED `<<<FINDING` block (which `parse` drops) still gets its
            // raw markers stripped before the planner sees them, instead of leaking through (Codex). With
            // no findings this just strips stray markers; the strategic prose is preserved.
            let sanitized = ReviewFindingVerifier.sanitizedForPlanner(minds[idx].output, verified: verified)
            mindsForDecision[idx] = CouncilMindResult(name: minds[idx].name, role: minds[idx].role,
                                                      binding: minds[idx].binding, output: sanitized, failed: false)
            groundingSection = Self.renderGroundingSection(verified)
        }
        let finalPlan = await finalDecision(goal: normalizedGoal, minds: mindsForDecision)
        var markdown = Self.renderMarkdown(goal: normalizedGoal, minds: minds, finalPlan: finalPlan)
        if !groundingSection.isEmpty { markdown += "\n\n" + groundingSection }
        let builderBrief = Self.renderBuilderBrief(goal: normalizedGoal, markdown: markdown)
        await heartbeat(status: "council", message: "council completed")
        return CouncilRunResult(goal: normalizedGoal, minds: minds, finalPlan: finalPlan,
                                markdown: markdown, builderBrief: builderBrief)
    }

    // MARK: - "dig in deep" — the WIDE council

    /// Natural-language trigger for the wide council. Deliberately narrow: fires only on an explicit
    /// "ask everyone" intent, never on incidental phrasing, so a normal message is never hijacked.
    public static func looksLikeDigDeep(_ input: String) -> Bool {
        let t = input.lowercased()
        let phrases = ["dig in deep", "dig deep", "consult the minds", "consult the mind",
                       "ask all the models", "ask all of the models", "all of the ai models",
                       "all the ai models", "every model", "consult all the", "get multiple opinions",
                       "multiple models weigh in", "council of models", "ask everyone"]
        return phrases.contains { t.contains($0) }
    }

    /// "Dig in deep" — ask EVERY reachable model the SAME question IN PARALLEL, then synthesize where they
    /// AGREE and DISAGREE. Unlike `run()`, this is NOT role-based and builds no kanban: it's a multi-mind
    /// second-opinion panel ("consult the minds, not repeat the same answer"). Free/keyless providers are
    /// asked first (cheap, no metering); capped at `maxMinds`; each mind has its own wall-clock timeout so
    /// one hung provider can't stall the report; budget-gated like `run()`.
    public func runWide(goal: String, maxMinds: Int = 5, perMindTimeout: TimeInterval = 90) async -> CouncilRunResult {
        let normalizedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        await heartbeat(status: "council", message: "dig-in-deep started")

        // Reachable providers, FREE/keyless first (claude-cli/codex-cli/mlx/ollama), then keyed. Dedup by
        // id, cap at maxMinds. The catalog already drops CLI providers whose binary isn't installed.
        let reachable = providers.providers
            .filter { providers.hasKey(for: $0) }
            .sorted { ($0.requiresAPIKey ? 1 : 0) < ($1.requiresAPIKey ? 1 : 0) }
        var seen = Set<String>()
        let chosen = Array(reachable.filter { seen.insert($0.id).inserted }.prefix(maxMinds))
        guard !chosen.isEmpty else {
            let none = "Decision:\n- No reachable models. Set a provider key in ~/.config/kist/secrets.env or install claude-cli / codex-cli."
            return CouncilRunResult(goal: normalizedGoal, minds: [], finalPlan: none, markdown: none, builderBrief: "")
        }

        // Fan out — each mind answers the SAME question independently, order preserved for a stable report.
        let question = normalizedGoal
        let minds: [CouncilMindResult] = await withTaskGroup(of: (Int, CouncilMindResult).self) { group in
            for (i, p) in chosen.enumerated() {
                let (pid, model, label) = (p.id, p.defaultModel, p.name)
                group.addTask {
                    (i, await self.askWide(providerId: pid, model: model, label: label,
                                           question: question, timeout: perMindTimeout))
                }
            }
            var slots = [CouncilMindResult?](repeating: nil, count: chosen.count)
            for await (i, r) in group { slots[i] = r }
            return slots.compactMap { $0 }
        }

        let answered = minds.filter { !$0.failed }
        let finalPlan: String
        if answered.count >= 2 {
            finalPlan = await synthesizeWide(goal: normalizedGoal, minds: answered)
        } else if let only = answered.first {
            finalPlan = "Decision:\n- Only one model was reachable (\(only.name)); no cross-check was possible. Its answer stands above."
        } else {
            finalPlan = "Decision:\n- Every model failed to answer — see the per-model errors above."
        }
        let markdown = Self.renderMarkdown(goal: normalizedGoal, minds: minds, finalPlan: finalPlan)
        await heartbeat(status: "council", message: "dig-in-deep completed")
        return CouncilRunResult(goal: normalizedGoal, minds: minds, finalPlan: finalPlan,
                                markdown: markdown, builderBrief: "")
    }

    /// One wide-council mind: ask a single provider the raw question, raced against a wall-clock timeout so
    /// a hung provider degrades to a `failed` mind instead of stalling the whole panel.
    private func askWide(providerId: String, model: String, label: String,
                         question: String, timeout: TimeInterval) async -> CouncilMindResult {
        let binding = ProviderBinding(providerId: providerId, model: model)
        if let budget, await budget.isExceeded() {
            return CouncilMindResult(name: label, role: "mind", binding: binding,
                                     output: "SKIPPED — token budget exceeded before this mind ran.", failed: true)
        }
        let messages = [ChatMessage(role: .user, content: question)]
        let settings = ModelSettings(temperature: 0.3, maxTokens: 1200,
                                     systemPrompt: "You are ONE of several independent expert AI models answering the SAME question in parallel for a 'consult the minds' panel. Answer DIRECTLY and concretely. State your key claims and explicitly flag anything you are unsure about. No meta-commentary about being an AI. Substantive but concise.",
                                     disableThinking: true)
        let started = Date()
        await heartbeat(status: "council", message: "\(label) started")
        do {
            let (text, usage) = try await Self.withTimeout(seconds: timeout) {
                try await self.providers.completeWithUsage(providerId: providerId, model: model,
                                                           messages: messages, settings: settings)
            }
            await record(role: "council_mind_\(label.lowercased())", binding: binding, usage: usage,
                         promptChars: question.count, completionChars: text.count, started: started, status: .ok)
            await heartbeat(status: "council", message: "\(label) completed")
            return CouncilMindResult(name: label, role: "mind", binding: binding, output: text.trimmedOrPlaceholder())
        } catch {
            await record(role: "council_mind_\(label.lowercased())", binding: binding, usage: .zero,
                         promptChars: question.count, completionChars: 0, started: started, status: .error)
            await heartbeat(status: "council", message: "\(label) failed")
            let reason = (error is CouncilMindTimeout) ? "TIMED OUT after \(Int(timeout))s" : "FAILED: \(error)"
            return CouncilMindResult(name: label, role: "mind", binding: binding, output: reason, failed: true)
        }
    }

    /// Merge the wide panel's answers into ONE decisive verdict with explicit agree/disagree. Uses the
    /// planner binding (a strong model). Produces a `Decision:` section so CouncilCard renders it.
    private func synthesizeWide(goal: String, minds: [CouncilMindResult]) async -> String {
        let binding = roles.binding(for: .planner)
        if let budget, await budget.isExceeded() { return Self.fallbackFinalPlan(error: CouncilBudgetExceeded(), minds: minds) }
        let transcript = minds.map { "### \($0.name) (\($0.binding?.model ?? "?"))\n\($0.output)" }.joined(separator: "\n\n")
        let prompt = """
        Several INDEPENDENT AI models answered the SAME question below. Synthesize their answers — do not
        just summarize each in turn; produce ONE merged verdict.

        Output shape:
        Decision:
        - The single strongest merged answer to the question.

        Agreement:
        - Where the models agree.

        Disagreement:
        - Where they diverge, and which position is more credible and why.

        Confidence: <low|medium|high> — one line why.

        Question:
        \(goal)

        Model answers:
        \(transcript)
        """
        let messages = [ChatMessage(role: .user, content: prompt)]
        let settings = ModelSettings(temperature: 0.2, maxTokens: 1600,
                                     systemPrompt: "You merge multiple expert opinions into one decisive, honest answer, naming agreement and disagreement plainly.",
                                     disableThinking: true)
        do {
            let (text, usage) = try await providers.completeWithUsage(providerId: binding.providerId, model: binding.model,
                                                                      messages: messages, settings: settings)
            await record(role: "council_wide_synthesis", binding: binding, usage: usage,
                         promptChars: prompt.count, completionChars: text.count, started: Date(), status: .ok)
            return text.trimmedOrPlaceholder()
        } catch {
            return Self.fallbackFinalPlan(error: error, minds: minds)
        }
    }

    /// Race an async op against a wall clock; throws `CouncilMindTimeout` if the timer wins.
    static func withTimeout<T: Sendable>(seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw CouncilMindTimeout()
            }
            defer { group.cancelAll() }
            let first = try await group.next()!
            return first
        }
    }

    /// Convenience for tests / simple callers: parse a critic's output, ground each finding, render the
    /// verdict section. Empty when there are no structured findings.
    static func groundingSection(_ criticOutput: String, projectRoot: String) async -> String {
        let findings = ReviewFindingVerifier.parse(criticOutput)
        guard !findings.isEmpty else { return "" }
        let verified = await ReviewFindingVerifier.verify(findings: findings, projectRoot: projectRoot)
        return renderGroundingSection(verified)
    }

    /// Render the human-facing grounding verdict. HONEST framing (Codex): "grounded" means the cited code
    /// EXISTS in the repo — NOT that the bug is real (a refute panel is the second gate, not yet wired).
    static func renderGroundingSection(_ verified: [VerifiedReviewFinding]) -> String {
        guard !verified.isEmpty else { return "" }
        let grounded = verified.filter { $0.verdict != .refutedFabricated }
        let fabricated = verified.filter { $0.verdict == .refutedFabricated }
        var lines = ["## Finding Grounding",
                     "Critic code findings checked against the actual source — \"grounded\" = the cited code EXISTS in the repo (not a guarantee the bug is real); \"fabricated\" = the cited code was not found (\(grounded.count) grounded, \(fabricated.count) likely fabricated):"]
        for v in verified {
            let mark = v.verdict == .refutedFabricated ? "✗ LIKELY FABRICATED" : "✓ grounded"
            let loc = v.finding.line.map { "\(v.finding.file):\($0)" } ?? v.finding.file
            lines.append("- [\(mark)] \(v.finding.severity) \(loc) — \(v.finding.claim) (\(v.rationale))")
        }
        if !fabricated.isEmpty {
            lines.append("")
            lines.append("> \(fabricated.count) finding(s) quoted code not present in the repo — DROPPED before the plan was built. This is the same check a careful human applies by reading the source.")
        }
        return lines.joined(separator: "\n")
    }

    private func ask(name: String, role: AgentRole, brief: String, goal: String,
                     prior: [CouncilMindResult]) async -> CouncilMindResult {
        let binding = roles.binding(for: role)
        // Halt before spending another mind turn once the budget is gone.
        if let budget, await budget.isExceeded() {
            return CouncilMindResult(name: name, role: role.rawValue, binding: binding,
                                     output: "SKIPPED — token budget exceeded before this mind ran.", failed: true)
        }
        let prompt = Self.mindPrompt(name: name, brief: brief, goal: goal,
                                     memoryContext: memoryContext,
                                     researchDossier: researchDossier,
                                     prior: prior)
        let messages = [ChatMessage(role: .user, content: prompt)]
        let settings = ModelSettings(temperature: 0.2, maxTokens: 1400,
                                     systemPrompt: Self.systemPrompt(mindName: name),
                                     disableThinking: true)
        let started = Date()
        await heartbeat(status: "council", message: "\(name) started")
        do {
            let (text, usage) = try await providers.completeWithUsage(providerId: binding.providerId,
                                                                      model: binding.model,
                                                                      messages: messages,
                                                                      settings: settings)
            await record(role: "council_\(name.lowercased())", binding: binding, usage: usage,
                         promptChars: prompt.count, completionChars: text.count,
                         started: started, status: .ok)
            await heartbeat(status: "council", message: "\(name) completed")
            return CouncilMindResult(name: name, role: role.rawValue, binding: binding,
                                     output: text.trimmedOrPlaceholder())
        } catch {
            await record(role: "council_\(name.lowercased())", binding: binding, usage: .zero,
                         promptChars: prompt.count, completionChars: 0,
                         started: started, status: .error)
            await heartbeat(status: "council", message: "\(name) failed")
            return CouncilMindResult(name: name, role: role.rawValue, binding: binding,
                                     output: "FAILED: \(error)", failed: true)
        }
    }

    private func finalDecision(goal: String, minds: [CouncilMindResult]) async -> String {
        let binding = roles.binding(for: .planner)
        // If the budget is gone, synthesize from what the minds already produced rather than spending
        // another (large) model call.
        if let budget, await budget.isExceeded() {
            return Self.fallbackFinalPlan(error: CouncilBudgetExceeded(), minds: minds)
        }
        let prompt = """
        You are the Final Plan Agent. Given the council transcript, produce the decision and the board.

        Required output shape:
        Decision:
        - One clear build decision.

        Task Analysis:
        - Why this is the next move.
        - Dependencies and risks.
        - What to avoid.

        Kanban Board:
        | Status | Task | Owner | Acceptance |
        | --- | --- | --- | --- |
        | Ready | ... | builder | ... |
        | Backlog | ... | researcher | ... |

        Next Builder Brief:
        - A direct instruction the builder model can execute first.

        Rules:
        - Turn disagreement into a decision, not a summary.
        - If research is incomplete, include a Ready research-verification task before build tasks.
        - Keep the first implementation small and testable.
        - Do not reveal chain-of-thought, private scratchpad, or "the user wants..." analysis.

        Goal:
        \(goal)

        Council transcript:
        \(Self.renderMindSections(minds))

        Research dossier:
        \(String((researchDossier ?? "No research dossier was attached.").prefix(8_000)))
        """
        let messages = [ChatMessage(role: .user, content: prompt)]
        let settings = ModelSettings(temperature: 0.15, maxTokens: 2200,
                                     systemPrompt: Self.systemPrompt(mindName: "Final Plan Agent"),
                                     disableThinking: true)
        let started = Date()
        await heartbeat(status: "council", message: "Final Plan Agent started")
        do {
            let (text, usage) = try await providers.completeWithUsage(providerId: binding.providerId,
                                                                      model: binding.model,
                                                                      messages: messages,
                                                                      settings: settings)
            await record(role: "council_final_plan", binding: binding, usage: usage,
                         promptChars: prompt.count, completionChars: text.count,
                         started: started, status: .ok)
            await heartbeat(status: "council", message: "Final Plan Agent completed")
            return text.trimmedOrPlaceholder()
        } catch {
            await record(role: "council_final_plan", binding: binding, usage: .zero,
                         promptChars: prompt.count, completionChars: 0,
                         started: started, status: .error)
            await heartbeat(status: "council", message: "Final Plan Agent failed")
            return Self.fallbackFinalPlan(error: error, minds: minds)
        }
    }

    private func memoryMind() -> CouncilMindResult {
        let trimmed = memoryContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let output = trimmed.isEmpty
            ? "No project memory found. Treat this as a fresh council decision and save the outcome."
            : "Relevant project memory:\n\(String(trimmed.prefix(4000)))"
        return CouncilMindResult(name: "Memory", role: "memory", binding: nil, output: output)
    }

    private func record(role: String, binding: ProviderBinding, usage: TokenUsage,
                        promptChars: Int, completionChars: Int, started: Date,
                        status: SpanStatus) async {
        let measured = usage.isZero
            ? TokenUsage.estimate(promptChars: promptChars, completionChars: completionChars)
            : usage
        // Account tokens + live dollar cost at the single chokepoint (every mind turn + final synthesis
        // flows through record), BEFORE the recorder guard so the cap holds even with no trace recorder.
        let usd = CompetitiveBenchmark.priceUSD(vendor: binding.providerId,
                                                promptTokens: measured.promptTokens,
                                                completionTokens: measured.completionTokens) ?? 0
        await budget?.add(tokens: measured.total, usd: usd)
        guard let recorder else { return }
        await recorder.record(AgentSpan(id: TraceID.make(), traceId: recorder.traceId, kind: .llmCall,
                                        role: role, vendor: binding.providerId, model: binding.model,
                                        promptTokens: measured.promptTokens,
                                        completionTokens: measured.completionTokens,
                                        finishReason: nil, startedAt: started, endedAt: Date(),
                                        status: status))
    }

    private func heartbeat(status: String, message: String) async {
        guard let progress else { return }
        await progress(status, message)
    }

    private static func systemPrompt(mindName: String) -> String {
        """
        You are \(mindName), one mind in an AI engineering council. Be concise, concrete, and honest.
        Do not claim work is done. Do not invent sources, files, or tests. Your job is to improve the
        shared decision before a builder acts. Do not reveal chain-of-thought, private scratchpad, or
        "the user wants..." analysis; provide conclusions and actionable bullets only.
        """
    }

    private static func mindPrompt(name: String, brief: String, goal: String, memoryContext: String?,
                                   researchDossier: String?,
                                   prior: [CouncilMindResult]) -> String {
        var sections = [
            "Council mind: \(name)",
            "Task:\n\(brief)",
            "User research/task:\n\(goal)",
        ]
        if let memoryContext, !memoryContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Project memory context:\n\(String(memoryContext.prefix(4000)))")
        }
        if let researchDossier, !researchDossier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Research evidence dossier:\n\(String(researchDossier.prefix(8000)))")
        }
        if !prior.isEmpty {
            sections.append("Earlier council opinions:\n\(renderMindSections(prior))")
        }
        sections.append("Output only your \(name) opinion as concise bullets.")
        return sections.joined(separator: "\n\n")
    }

    public static func renderMarkdown(goal: String, minds: [CouncilMindResult], finalPlan: String) -> String {
        """
        # AI Council Result

        ## Goal
        \(goal)

        \(renderMindSections(minds))

        ## Decision, Task Analysis, And Kanban
        \(finalPlan)
        """
    }

    public static func renderBuilderBrief(goal: String, markdown: String) -> String {
        """
        Build from this AI Council decision. Start with the Ready task(s), keep scope small, update the kanban artifact if task status changes, and verify with focused tests.

        Original goal:
        \(goal)

        Council board:
        \(markdown)
        """
    }

    static func renderMindSections(_ minds: [CouncilMindResult]) -> String {
        minds.map { mind in
            let binding = mind.binding.map { b in
                b.providerId + (b.model.map { ":\($0)" } ?? "")
            } ?? "deterministic"
            return """
            ## \(mind.name)
            _role: \(mind.role) · model: \(binding)\(mind.failed ? " · failed" : "")_

            \(mind.output)
            """
        }.joined(separator: "\n\n")
    }

    private static func fallbackFinalPlan(error: Error, minds: [CouncilMindResult]) -> String {
        """
        Decision:
        - Final planner failed: \(error). Use the council opinions as advisory input and do not auto-execute broad work.

        Task Analysis:
        - The council ran, but the final decision pass failed.
        - Human review should choose the first Ready task before builder execution.

        Kanban Board:
        | Status | Task | Owner | Acceptance |
        | --- | --- | --- | --- |
        | Ready | Review failed final-planner output and choose first implementation slice | planner | A narrow first task is written down |
        | Backlog | Convert council opinions into executable tasks | builder | Tasks have owners and acceptance criteria |

        Next Builder Brief:
        - Do not build yet. First repair the council decision from the saved mind outputs.

        Council minds captured:
        \(minds.map { "- \($0.name): \($0.failed ? "failed" : "ok")" }.joined(separator: "\n"))
        """
    }
}

private extension String {
    func trimmedOrPlaceholder() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty response)" : trimmed
    }
}
