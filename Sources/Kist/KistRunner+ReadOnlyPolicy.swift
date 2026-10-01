import Foundation
import AgentCore

extension KistRunner {
    /// Capability-reduced registry for ordinary answer/evidence runs. Browser rendering is admitted only
    /// when the operator configured an explicit host boundary (`--fetch-host` or equivalent config); it is
    /// not computer-use and never admits desktop, Accessibility, ScreenCapture, or host-control MCP tools.
    /// BrowserTool independently requires shell launch authority and always applies its own OS sandbox.
    static func readOnlyOneShotTools(
        from tools: ToolRegistry,
        fetchAllowedHosts: [String]
    ) -> ToolRegistry {
        var allowed = HeadlessAgentLoop.readOnlyTools
        if !fetchAllowedHosts.isEmpty { allowed.insert("browse") }
        return ToolRegistry(tools.all().filter { allowed.contains($0.name) })
    }

    /// BuilderRun is a build/verification coordinator, not the universal answer path. Keep explicit
    /// high-assurance build surfaces and resumptions gated, while read-only answer/evidence work runs
    /// through the ordinary agent loop without inheriting a governed-workspace mutation contract.
    static func builderRunRequired(for opts: KistOptions, goal: String) -> Bool {
        if opts.planMode && opts.planExecute { return false }
        if opts.resumeId != nil || opts.resumeLast || opts.planExecuteResumeID != nil { return true }
        let intent = PromptCompiler.inferIntent(goal, mode: .inline)
        if intent == .delegate { return false }
        if opts.headless || opts.mission || opts.fleet || opts.greatLoop || opts.ship
            || opts.planExecute { return true }
        if opts.planMode { return false }
        if intent == .build && (AgentMetadataRequest.matches(goal) || DecisionToolRequest.matches(goal)) { return false }
        if builderCompletionMode(for: goal) == .verificationOnly { return true }

        switch intent {
        case .build, .fleet, .desktop:
            return true
        case .chat, .plan, .delegate, .research, .review:
            return false
        }
    }

    /// Direct ordinary agent path for answer/evidence work and fixed-path agent registration.
    /// The headless loop narrows registration turns to metadata actions; other non-delegation runs
    /// use the canonical read-only registry. Every retained tool still traverses its ordinary gates.
    static func runReadOnlyOneShot(
        _ opts: KistOptions,
        goal: String,
        registry: ProviderRegistry,
        root: String,
        tools: ToolRegistry,
        context: ToolContext,
        checkpoints: LoopCheckpointStore?,
        fetchAllowedHosts: [String],
        toolMode: ToolMode,
        providerId: String,
        model: String?
    ) async -> Int32 {
        guard let checkpoints else {
            err("read-only run requires a checkpoint store")
            return 2
        }
        guard let roles = resolveRoles(opts, registry, providerId: providerId, model: model) else {
            return 2
        }
        let mode: PromptCompiler.Mode = opts.planMode ? .plan : .inline
        let intent = PromptCompiler.inferIntent(goal, mode: mode)
        let agentMetadataOnly = intent == .build && (AgentMetadataRequest.matches(goal) || DecisionToolRequest.matches(goal))
        guard !intent.expectsMutation || agentMetadataOnly else {
            err("read-only route refused mutation intent")
            return 2
        }

        // Delegation keeps the full SESSION ceiling inside SpawnAgentTool, while HeadlessAgentLoop
        // projects the PARENT to read + trusted orchestration tools. Pre-filtering here would also
        // cripple an explicitly authorized implementation child.
        // The headless loop restricts metadata requests to fixed-path agent registration and reads.
        // Keep the host ceiling here so a stored role may request tools for a later authorized task.
        let routeTools = intent == .delegate || agentMetadataOnly ? tools : readOnlyOneShotTools(
            from: tools, fetchAllowedHosts: fetchAllowedHosts)
        let recorder = TrajectoryRecorder()
        let traceRecorder = TraceRecorder(traceId: TraceID.make())
        let runReplay = RunReplayStore(projectRoot: root, provider: providerId, model: model)
        let proofStore = TurnProofStore(replayStore: runReplay)
        let lessonStore = opts.noMemory ? nil : LessonStore()
        let effort = EffortController.assess(goal: goal)
        proofStore.startTurn(goal: goal)

        // ONE ledger for the WHOLE run (Codex P1-C). `--budget`/`--max-cost` are documented as hard
        // ceilings for the ENTIRE run, so the first attempt and any provider-substitution retry MUST
        // draw from the SAME depleting instance. Constructing a fresh ledger for the retry (the old bug)
        // let a first attempt burn ~all of the cap, fail, and then the substitute spend the full cap
        // again — one command spending the ceiling twice. BudgetLedger is an actor (reference type), so
        // threading this single instance into both loops shares the depleted `spent` across attempts.
        let runBudget = opts.makeBudget()

        let loop = makeLoop(
            registry: registry, providerId: providerId, model: model, context: context,
            tools: routeTools, checkpoints: checkpoints,
            maxIterations: min(opts.maxIterations, effort.iterationBudget),
            budget: runBudget, planMode: opts.planMode,
            extendedThinking: opts.extendedThinking || effort.thinking != .none,
            toolMode: toolMode, roles: roles, delegationDepth: intent == .delegate ? 1 : 0,
            showReasoning: opts.extendedThinking || effort.thinking == .deep,
            sinkOverride: TerminalEventSink(
                showReasoning: opts.extendedThinking || effort.thinking == .deep,
                style: .calm, proofStore: proofStore),
            recorder: recorder, traceRecorder: traceRecorder
        )
        let memoryContext = Self.sessionMemory(root: root, opts: opts)
        let personaContext = opts.fast ? nil : TaskPersonaMatcher.promptContext(
            matches: TaskPersonaMatcher(projectRoot: root).matches(for: goal, limit: 3))
        let reviewContext = opts.fast ? nil
            : ReviewContext.renderIfNeeded(request: goal, projectRoot: root)
        let compiledGoal = PromptCompiler.compiledPrompt(
            goal,
            mode: mode,
            projectContext: briefContext(
                memoryContext: memoryContext,
                roles: roles,
                lessons: opts.fast ? nil : lessonStore?.primer(forGoal: goal),
                specialists: personaContext,
                reviewTargets: reviewContext
            ),
            resolvedIntent: intent
        )
        var outcome = await loop.run(goal: compiledGoal, rawRequest: goal,
                                     resolvedIntent: intent)
        // Provider resilience (parity with the REPL lane): a failed run whose trajectory is
        // safe to replay retries ONCE on a substitute provider instead of dying terminally.
        // Rate-limit/outage failures also cool the provider down cross-process so the next
        // one-shot doesn't walk into the same wall.
        if !outcome.success {
            let cooldowns = ProviderCooldownStore()
            if let sub = Self.oneShotSubstitution(
                outcomeSuccess: outcome.success, outcomeSummary: outcome.summary,
                trajectory: recorder.snapshot(),
                current: ProviderBinding(providerId: providerId, model: model),
                roles: roles, registry: registry, cooldowns: cooldowns) {
                if sub.shouldCooldown {
                    cooldowns.record(providerId,
                                     ttl: KistREPL.providerCooldownTTL(forFailureSummary: outcome.summary))
                }
                note("↳ model substitution · \(providerId) benched for \(sub.decision.reason); "
                     + "retrying once on \(sub.decision.replacement.providerId)")
                let retryLoop = makeLoop(
                    registry: registry,
                    providerId: sub.decision.replacement.providerId,
                    model: sub.decision.replacement.model, context: context,
                    tools: routeTools, checkpoints: checkpoints,
                    maxIterations: min(opts.maxIterations, effort.iterationBudget),
                    // SAME ledger as the first attempt (Codex P1-C): the retry inherits the DEPLETED cap
                    // instead of resetting it, so `--budget`/`--max-cost` bound the whole run, not each
                    // attempt independently. Do NOT reconstruct a fresh ledger here.
                    budget: runBudget, planMode: opts.planMode,
                    extendedThinking: opts.extendedThinking || effort.thinking != .none,
                    toolMode: toolMode, roles: roles,
                    delegationDepth: intent == .delegate ? 1 : 0,
                    showReasoning: opts.extendedThinking || effort.thinking == .deep,
                    sinkOverride: TerminalEventSink(
                        showReasoning: opts.extendedThinking || effort.thinking == .deep,
                        style: .calm, proofStore: proofStore),
                    recorder: recorder, traceRecorder: traceRecorder
                )
                outcome = await retryLoop.run(goal: compiledGoal, rawRequest: goal,
                                              resolvedIntent: intent)
            }
        }
        recordRuntimeLessons(goal: goal, success: outcome.success, recorder: recorder,
                             lessonStore: lessonStore, maxIterations: opts.maxIterations,
                             mode: mode)
        Self.autoJournalRun(goal: goal, success: outcome.success, root: root,
                            enabled: !opts.noMemory)
        print(KistREPL.renderSimpleSummary(projectRoot: root,
                                           spans: await traceRecorder.all(),
                                           trajectory: recorder.snapshot()))
        let grounding = GroundedReviewValidator.audit(outcome.summary, projectRoot: root)
        if !grounding.isGrounded {
            print(grounding.render(color: TerminalCapabilities.stdoutIsInteractive))
        }
        printUsageDelta(from: [], to: await traceRecorder.all(), label: "usage",
                        projectRoot: root)
        note("replay · kist --replay \(runReplay.manifest.runID)")
        if !outcome.success {
            note("paused — resume with: kist --resume \(outcome.checkpointId)")
        }
        return outcome.success ? 0 : 1
    }

    static func usablePrimaryResearchEvidence(_ result: ToolResult) -> Bool {
        guard result.success, result.metadata["evidence_id"] != nil,
              !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        for key in ["count", "chunks", "matches"] {
            if let raw = result.metadata[key], Int(raw) == 0 { return false }
        }
        return true
    }

    static func requiredCouncilCriticFailure(_ result: CouncilRunResult) -> String? {
        guard let critic = result.minds.first(where: {
            $0.role.lowercased() == AgentRole.critic.rawValue
                || $0.name.lowercased() == "critic"
        }) else {
            return "required critic did not run"
        }
        let output = critic.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !critic.failed, !output.isEmpty,
              !output.lowercased().hasPrefix("failed:") else {
            return "required critic failed: " + (output.isEmpty ? "empty response" : output)
        }
        guard let verdict = critic.criticVerdict else {
            return "required critic did not return a valid structured verdict"
        }
        switch verdict.decision {
        case .accept:
            return nil
        case .reject:
            return "required critic rejected the research: \(verdict.rationale)"
        }
    }
}
