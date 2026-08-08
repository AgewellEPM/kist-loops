import Foundation

/// The headless agent loop — Mythos's canonical, GUI-free plan→act→observe→repeat core.
///
/// It supports two acquisition protocols over one execution core: native provider tool calls when
/// the selected model advertises them, and a provider-agnostic structured-text (ReAct) fallback for
/// local/compatibility models. Both dispatch through the same sandboxed `ToolRegistry` and share
/// approvals, checkpoints, progress policy, verification, and context preparation.
///
/// Foundation-only + `Sendable`: it runs from a terminal (`Kist`), an MCP server, or the GUI via
/// the same `RuntimeEventSink`. Rich features port INTO this loop (not duplicated): durable
/// **resume** (here, via `LoopCheckpoint` persisted every iteration) is the first.
///
/// Resume is reconciled: each tool is bracketed — the action is persisted as PENDING before it
/// runs and cleared after its observation. If the process dies mid-tool, resume detects the
/// pending action and steers the model to VERIFY current state rather than blindly replay a
/// non-idempotent write/command (the GUI monolith's Codex HIGH-1, ported).
public struct HeadlessAgentLoop: Sendable {

    public struct Outcome: Sendable {
        public let success: Bool
        public let summary: String
        public let iterations: Int
        public let checkpointId: String
        /// True when this run FAILED because the PROVIDER faulted server-side (5xx / rate-limit / transport),
        /// classified from the STRUCTURED error — so the great-loop can route around that provider without
        /// regexing the summary. Default false (success, or a non-provider failure like a bad edit).
        public let providerFault: Bool
        public init(success: Bool, summary: String, iterations: Int, checkpointId: String, providerFault: Bool = false) {
            self.success = success; self.summary = summary; self.iterations = iterations
            self.checkpointId = checkpointId; self.providerFault = providerFault
        }
    }

    // Visibility: several members are `internal` (not `private`) so cohesive method groups can live in
    // same-module `extension HeadlessAgentLoop` files (Config/Compaction/Persistence/Observation/
    // Prompts/ToolDisplay). Swift `private` is file-scoped, so a member touched across the split must be
    // at least `internal`. No member was widened beyond `internal`.
    let providers: ProviderRegistry
    let providerId: String
    let model: String?
    let tools: ToolRegistry
    let context: ToolContext
    let sink: RuntimeEventSink
    private let interactor: RuntimeInteractor
    var approvalTools: Set<String>    // tools that need human y/n before running (runtime-switchable via approving(_:))
    var planMode: Bool                // plan mode: only read-only tools may run (propose, don't execute)
    private let toolMode: ToolMode            // native / text / auto (capability-routed) tool acquisition
    let hooks: AgentHooks?            // user lifecycle hooks (PreToolUse/PostToolUse/Stop); nil = none
    let checkpoints: LoopCheckpointStore?
    private let maxIterations: Int
    /// Verify-before-done: how many times a "done" on unverified code changes is pushed back to actually
    /// build/test before the loop lets it finish (bounded so a genuinely blocked run isn't trapped).
    static let maxVerificationNudges = 3
    /// Extended thinking: when ON, the loop lets the model REASON before each action (the reasoning stream
    /// is surfaced + persisted to the replay) instead of forcing it off. Opt-in (default OFF) so the tight,
    /// low-latency tool loop is unchanged unless the user asks to think — `--think` / `/think`.
    var extendedThinking: Bool
    /// Hard token ceiling for this run. When the SAME ledger is injected into every fleet agent it
    /// becomes a GLOBAL cap (BudgetLedger is an actor → correct across parallel workers): one rogue
    /// agent can't blow the whole fleet's budget. nil = uncapped. The loop halts at the ceiling
    /// rather than discovering the overage after the bill — the #1 production objection the council
    /// flagged.
    let budget: BudgetLedger?
    let conversationWindow: ConversationWindowPreparer
    /// Every loop owns a trajectory recorder so progress and verify-before-done cannot silently turn
    /// off in delegated/headless callers. A host may inject the same recorder to observe the run.
    let recorder: TrajectoryRecorder
    private let ownsRecorder: Bool
    /// Optional host-owned span recorder for token/cost telemetry. nil = off.
    private let traceRecorder: TraceRecorder?
    private let traceRole: String?
    /// Agent-Skills: the Tier-1 `<available_skills>` menu injected into the system prompt
    /// (empty when no skills are discovered). Tracker tracks on-demand loads for telemetry.
    let skillsXML: String
    let skillTracker: SkillTracker?
    /// Verified local-model profiles (chat template + stop sequences) from Drop-a-Key/Drop-a-Doc
    /// onboarding. When a profile matches (providerId, model), its stops are injected into generation
    /// so a local model halts at its real turn boundary. nil = none (provider/server-side stops apply).
    let modelProfiles: LocalModelProfileStore?

    /// P1 recall→plan read-back: an optional per-turn hook that, given the turn's goal, returns an
    /// ADVISORY block of recalled VERIFIED lessons to append to the system prompt (empty ⇒ nothing
    /// injected). Set by the runtime on a WARM loop (interactive REPL + the injection-ON ablation arm);
    /// left nil on a COLD/injection-OFF loop. It's the single toggle that isolates P1's contribution:
    /// injection-ON vs injection-OFF with the toolset held constant. Not in `init` (a post-construction
    /// var) so the ablation can build two otherwise-identical loops that differ ONLY in this hook.
    public var recallLessons: (@Sendable (_ query: String) async -> String)? = nil

    /// P2 — task-targeted self__ surfacing. When true, each turn ADVERTISES only the self-authored tools whose
    /// manifest matches the goal (trims schema bloat as the self__ population grows). ADVERTISEMENT-ONLY and
    /// FAIL-OPEN: execution (full `tools`), steering validToolNames, and `toolNames` (self-evolution's tool
    /// universe) all stay on the FULL registry, so a filtered-out tool is never unreachable and the engine
    /// never re-authors an existing capability. Post-construction toggle (mirrors `recallLessons`) so the
    /// ablation can build two identical loops differing only in this bit. Default OFF.
    public var filterSelfToolsByRelevance: Bool = false

    /// Tools that never modify state — the only ones permitted while plan mode is ON.
    /// An ALLOWLIST (not a denylist) so unknown/MCP tools are blocked by default in plan mode.
    public static let readOnlyTools: Set<String> = ["read_file", "list_files", "glob_files", "search_code", "ast_grep", "git", "symbols", "context_brain", "fetch_url", "web_search"]
    let maxObservationBytes = 8_000   // internal: +VerificationReplay envelopes observations too
    private let replanThreshold = 2      // consecutive tool failures before steering a re-plan
    private let maxReplans = 2           // budget so a doomed run can't loop on re-plans forever

    /// A compactor may preserve the first messages of a multi-turn REPL transcript even though they
    /// belong to an OLD turn. Keep the current turn's raw user request as the final controlling message
    /// after every compaction, so a weak model cannot snap back to the first-ever topic. The stable marker
    /// lets repeated compactions replace (rather than accumulate) the reminder.
    static let currentTurnObjectiveMarker = ConversationWindowPreparer.currentTurnObjectiveMarker

    public init(providers: ProviderRegistry,
                providerId: String,
                model: String?,
                tools: ToolRegistry,
                context: ToolContext,
                sink: RuntimeEventSink = NullEventSink(),
                interactor: RuntimeInteractor = AutoApproveInteractor(),
                approvalTools: Set<String> = [],
                planMode: Bool = false,
                injectAskUser: Bool = true,
                toolMode: ToolMode = .auto,
                hooks: AgentHooks? = nil,
                checkpoints: LoopCheckpointStore? = nil,
                // Reliability: a flat 12 quit on hard multi-step tasks (which need 50-100+ steps) and
                // reported the wall as a FAILURE. Raised, made safe by the live ProgressGovernor which
                // stops EARLY on a genuine loop — so the budget is spent finishing real work, not spinning.
                maxIterations: Int = 50,
                extendedThinking: Bool = false,
                budget: BudgetLedger? = nil,
                contextWindow: ContextWindowManager = .default,
                compactor: ConversationCompactor = .default,
                recorder: TrajectoryRecorder? = nil,
                traceRecorder: TraceRecorder? = nil,
                traceRole: String? = nil,
                modelProfiles: LocalModelProfileStore? = nil) {
        self.modelProfiles = modelProfiles
        self.budget = budget
        self.recorder = recorder ?? TrajectoryRecorder()
        self.ownsRecorder = recorder == nil
        self.traceRecorder = traceRecorder
        self.traceRole = traceRole
        self.providers = providers
        self.providerId = providerId
        self.model = model
        // Inject `ask_user` so the agent can ask a clarifying question (wires the interactor). Available in
        // both protocols' tool schemas; harmless in non-interactive contexts (returns a "proceed" note).
        // `injectAskUser: false` keeps a HERMETIC agent truly zero-tool (a specialist with `tools: []` or a
        // restrictive allowlist gets no communication primitive it didn't ask for) — see SpecialistSpawner.
        self.tools = injectAskUser ? tools.adding(AskUserTool(interactor: interactor)) : tools
        // Agent-Skills: discover builtin + project-local skills once (best-effort; empty on any
        // failure). The menu goes into the system prompt; the location index + tracker ride on the
        // context so `read_file` can recognize and record an on-demand skill load.
        let skillManager = SkillManager.discover(projectRoot: context.projectRoot)
        let tracker: SkillTracker? = skillManager.activeSkills.isEmpty
            ? nil : SkillTracker(activeSkills: skillManager.activeSkills)
        self.skillsXML = skillManager.promptXML()
        self.skillTracker = tracker
        self.context = context.withSkills(locations: skillManager.locationIndex(), tracker: tracker)
        self.sink = sink
        self.interactor = interactor
        self.approvalTools = approvalTools
        self.planMode = planMode
        self.toolMode = toolMode
        self.hooks = hooks
        self.checkpoints = checkpoints
        self.maxIterations = maxIterations
        self.extendedThinking = extendedThinking
        self.conversationWindow = ConversationWindowPreparer(contextWindow: contextWindow,
                                                             compactor: compactor)
    }

    // MARK: - Entry points

    /// Start a fresh run.
    public func run(goal: String) async -> Outcome {
        if ownsRecorder { recorder.reset() }
        let rawRequest = Self.scopeRequestSource(for: goal)
        let mode: PromptCompiler.Mode = planMode ? .plan : .inline
        let intent = PromptCompiler.inferIntent(rawRequest, mode: mode)
        let cp = LoopCheckpoint(goal: goal, rawRequest: rawRequest, intent: intent,
                                expectedOutcome: PromptCompiler.expectedOutcome(intent: intent, mode: mode),
                                providerId: providerId, model: model,
                                projectRoot: context.projectRoot,
                                messages: [ChatMessage(role: .user, content: goal)])
        return await drive(cp).0
    }

    /// Resume a previously-checkpointed run from exactly where it stopped.
    public func resume(from checkpoint: LoopCheckpoint) async -> Outcome {
        // A finished run is not resumable — return its result rather than re-driving it.
        guard checkpoint.status != .completed else {
            return Outcome(success: true, summary: checkpoint.summary ?? "already completed",
                           iterations: checkpoint.iteration, checkpointId: checkpoint.id)
        }
        // Restore the exact ledger, then invalidate any execution proof whose workspace state was not
        // fingerprinted across the process boundary. The synthetic may-mutate record does not erase an
        // earlier confirmed mutation, but it requires a fresh verifier after every qualifying resume.
        let mode: PromptCompiler.Mode = planMode ? .plan : .inline
        let raw = checkpoint.rawRequest ?? Self.scopeRequestSource(for: checkpoint.goal)
        let intent = checkpoint.intent ?? PromptCompiler.inferIntent(raw, mode: mode)
        let expectedOutcome = checkpoint.expectedOutcome
            ?? PromptCompiler.expectedOutcome(intent: intent, mode: mode)
        var restored = checkpoint.trajectory ?? []
        if let boundary = Self.resumeBoundaryRecord(for: restored, expectedOutcome: expectedOutcome) {
            restored.append(boundary)
        }
        recorder.restore(restored)
        var cp = checkpoint
        cp.trajectory = restored
        cp.status = .running
        persist(&cp)
        return await drive(cp).0
    }

    /// Run ONE conversational turn (REPL): append the user input to `transcript`, drive the loop
    /// up to `maxIterations` for THIS turn, and write the grown transcript back so context carries
    /// across turns. NOTE: this DOES persist — drive() checkpoints every iteration and an
    /// interrupted turn is saved as `.paused` (R1's interject-keeps / double-ESC-abandons
    /// semantics depend on that persistence; the old "interactive sessions aren't checkpointed"
    /// comment here was wrong).
    public func turn(transcript: inout [ChatMessage], userInput: String,
                     attachments: [MediaAttachment] = [],
                     rawRequest: String? = nil,
                     resolvedIntent: TaskBrief.Intent? = nil) async -> Outcome {
        if ownsRecorder { recorder.reset() }
        await hooks?.fireNotification(.userPromptSubmit, detail: String(userInput.prefix(500)))
        var messages = transcript
        messages.append(ChatMessage(role: .user, content: userInput, attachments: attachments))
        let raw = rawRequest ?? Self.scopeRequestSource(for: userInput)
        let mode: PromptCompiler.Mode = planMode ? .plan : .inline
        let intent = resolvedIntent ?? PromptCompiler.inferIntent(raw, mode: mode)
        let cp = LoopCheckpoint(goal: userInput, rawRequest: raw, intent: intent,
                                expectedOutcome: PromptCompiler.expectedOutcome(intent: intent, mode: mode),
                                providerId: providerId, model: model,
                                projectRoot: context.projectRoot, messages: messages)
        let (outcome, finalCp) = await drive(cp)
        transcript = finalCp.messages
        return outcome
    }

    // MARK: - The loop core

    /// Route to the NATIVE tool-calling loop or the universal text-protocol loop, decided by the
    /// (provider, model) CAPABILITIES and the `toolMode` override. `.auto` uses native only when the
    /// model actually supports it — local/small models fall to the text protocol (honest "all AIs").
    private func drive(_ initial: LoopCheckpoint) async -> (Outcome, LoopCheckpoint) {
        // Normalize old checkpoints once at the boundary. Every downstream decision then reads the
        // persisted turn contract instead of reclassifying prose independently.
        var prepared = initial
        let mode: PromptCompiler.Mode = planMode ? .plan : .inline
        let raw = prepared.rawRequest ?? Self.scopeRequestSource(for: prepared.goal)
        let intent = prepared.intent ?? PromptCompiler.inferIntent(raw, mode: mode)
        prepared.rawRequest = raw
        prepared.intent = intent
        prepared.expectedOutcome = prepared.expectedOutcome
            ?? PromptCompiler.expectedOutcome(intent: intent, mode: mode)
        if providers.usesNativeTools(providerId: providerId, model: model, mode: toolMode) {
            switch await driveNative(prepared) {
            case .finished(let result):
                return result
            case .downgrade(let cp):
                // The model claimed native tool-calling but the provider REJECTED the tool request
                // (e.g. a tool-history 400). Don't die — re-drive this same run through the universal
                // text protocol, carrying the work done so far. Only reached in `.auto` mode.
                sink.emit(.replanStarted(reason: "native tool-calling rejected by the provider — downgrading to the text protocol"))
                var downgraded = cp
                downgraded.messages = NativeProtocolDowngrade.flattenForText(cp.messages)
                downgraded.status = .running
                // Budget is per-RUN, not per-path: cap the text continuation at the SAME ceiling the run
                // started with (initial.iteration + maxIterations) so native iterations already spent are
                // NOT refunded — otherwise a late downgrade would grant up to 2× the iteration budget.
                let runLimit = Self.iterationLimit(from: prepared.iteration, budget: maxIterations)
                return await driveText(downgraded, iterationLimitOverride: runLimit)
            }
        }
        return await driveText(prepared)
    }

    /// Interactive CHAT/REVIEW turns must NOT be handed `spawn_agent` — a weak model (e.g. MiMo) will
    /// delegate a trivial "review this" into a runaway web-research SUB-agent (Luke, 2026-08-06: a 34-char
    /// review ask spawned 3 web searches + a fetch_url for ~200k tokens — "too much research, not listening
    /// to me"). Delegation belongs to the EXPLICIT heavy routes (/effort, /fleet, /council, /dive), never a
    /// plain reply. build/plan/fleet/research/desktop intents keep it. A direct `web_search` stays available
    /// (it's a single bounded call); only the RECURSIVE spawn vector is removed, so a simple answer can't
    /// balloon into a research expedition. nil intent ⇒ unchanged (fail-open, exactly as before).
    static func conversationalToolset(_ tools: ToolRegistry, intent: TaskBrief.Intent?) -> ToolRegistry {
        guard intent == .chat || intent == .review else { return tools }
        let spawnVector: Set<String> = ["spawn_agent", "spawn_specialist"]
        let kept = tools.all().filter { !spawnVector.contains($0.name) }
        return kept.count == tools.all().count ? tools : ToolRegistry(kept)
    }

    /// Result of the native loop: either it finished (success or honest failure), or it asks to be
    /// re-driven in the text protocol because the provider rejected native tool-calling mid-run.
    private enum NativeRun {
        case finished((Outcome, LoopCheckpoint))
        case downgrade(LoopCheckpoint)
    }

    /// P1: the advisory recall block for THIS turn's goal, as a system-prompt SUFFIX (empty ⇒ no-op).
    /// Appended to BOTH the text and native system prompts so the read-back is protocol-agnostic, and
    /// rebuilt per turn (no accumulation). No-op unless a WARM loop set `recallLessons`.
    private func recalledLessonsSuffix(goal: String) async -> String {
        guard let recallLessons else { return "" }
        let block = await recallLessons(goal)
        return block.isEmpty ? "" : "\n\n" + block
    }

    /// P2 filter application (advertisement-only, fail-open). Returns `registry` UNCHANGED unless the toggle is
    /// on AND a positive relevance match lets us drop some self__ tools. Only `.selfAuthored` names are ever in
    /// scope — native/foreign tools are mechanically untouchable here (namespace guard). Applied at BOTH the
    /// text and native seams; a match-miss (or nil manifests) surfaces everything.
    func surfaceRelevantSelfTools(_ registry: ToolRegistry, goal: String) -> ToolRegistry {
        guard filterSelfToolsByRelevance else { return registry }
        let all = registry.all()
        let selfManifests = all.compactMap { ($0 as? ScriptTool)?.manifest }
        guard !selfManifests.isEmpty,
              let keep = SelfToolRelevance.relevant(goal: goal, manifests: selfManifests) else { return registry }
        let kept = all.filter { ToolOwnershipResolver.owner(of: $0.name) != .selfAuthored || keep.contains($0.name) }
        return kept.count == all.count ? registry : ToolRegistry(kept)
    }

    /// Text-protocol ReAct loop — the universal fallback (model emits JSON actions as text).
    /// `iterationLimitOverride` lets a native→text downgrade impose the RUN's original ceiling instead of
    /// granting the text path a fresh per-invocation budget (see the downgrade site in `drive`).
    private func driveText(_ initial: LoopCheckpoint, iterationLimitOverride: Int? = nil) async -> (Outcome, LoopCheckpoint) {
        var cp = initial
        // A checkpoint cursor comes from disk (user-writable); bound it before any arithmetic.
        // `maxIterations` is a per-invocation step budget, not an absolute cursor ceiling: a run
        // paused at iter 10 must resume with another N steps instead of being called corrupt.
        guard let iterationLimit = iterationLimitOverride ?? Self.iterationLimit(from: cp.iteration, budget: maxIterations) else {
            return finishFailed(&cp, "invalid checkpoint cursor (\(cp.iteration))", "checkpoint is corrupt or out of range")
        }

        reconcile(&cp)   // interrupted-action reconciliation (shared with the native loop)
        let scopedContext = context.withAuthorizationScope(AuthorizationScopeEngine.evaluate(Self.scopeRequestSource(for: cp.goal)))
        // Interactive chat/review turns don't get the recursive spawn vector (runaway-research guard) —
        // applies to BOTH the standard prompt and the weak-model primer below (MiMo takes the weak path).
        let turnTools = surfaceRelevantSelfTools(Self.conversationalToolset(tools, intent: cp.intent), goal: cp.goal)   // P2: task-targeted self__ advertisement (fail-open, no-op unless toggled)
        var system = Self.systemPrompt(tools: turnTools, projectRoot: scopedContext.projectRoot, planMode: planMode,
                                       shellEnabled: scopedContext.shell.enabled, skillsXML: skillsXML,
                                       readableRoots: scopedContext.externalReadRoots)
        // Item #4: small local models stall on the strict JSON protocol. Lead with a gentle, example-
        // driven "simple mode" primer for the weak tier. Only the text path reaches here (frontier API
        // models use the native path), so this targets exactly the local/small models that need it.
        let tierModel = providers.provider(id: providerId)?.resolvedModel(model) ?? model
        if ModelTier.of(providerId: providerId, model: tierModel) == .weak {
            system = Self.weakModelTextPrimer(tools: turnTools, shellEnabled: scopedContext.shell.enabled) + "\n\n" + system
        }
        system += await recalledLessonsSuffix(goal: cp.goal)   // P1 recall→plan read-back (no-op unless warm)
        var settings = ModelSettings(temperature: 0.2, maxTokens: 4096, systemPrompt: system, disableThinking: !extendedThinking)
        let profileStopsApplied = applyModelProfileStops(&settings)
        var parseFailures = 0
        var consecutiveFailures = 0
        var replansUsed = 0
        var consecutiveGathering = 0       // read-only (gathering) calls in a row → forced-synthesis nudge
        var lastSynthesisNudge = -100
        var verificationNudges = 0         // verify-before-done: re-nudge up to a bound, then finish honestly
        var lastVerify: VerificationReplay? = nil   // last PASSING build/test of this run — re-verify replay candidate
        var replayAttempted = false                 // one deterministic replay per fresh candidate, never a loop
        var recoveryAttempted = false      // stuck-recovery: one hard reset before giving up
        var recoveryMark = 0               // trajectory length at recovery — judge only actions since
        var steeredSpiral: String? = nil   // last tool-error spiral we corrected — steer ONCE per signature

        sink.emit(.stateChanged(.analyzing))

        let start = cp.iteration + 1
        guard start <= iterationLimit else {
            return finishFailed(&cp, "reached max iterations", ".failed: out of budget on resume")
        }

        for iteration in start...iterationLimit {
            if Task.isCancelled { return finishInterrupted(&cp) }   // esc-to-interrupt
            if let halt = await budgetHalt(&cp) { return halt }
            sink.emit(.stateChanged(.executing))
            let outboundMessages = await prepareForProviderCall(&cp, mode: .text)

            // 1) Ask the model for the next action.
            let text: String
            do {
                text = try await streamCompletion(messages: outboundMessages, settings: settings,
                                                  allowFallback: !profileStopsApplied)
            } catch is BudgetDeniedError {
                return await budgetDeniedHalt(&cp)                       // atomic reserve denied this call
            } catch {
                if Task.isCancelled { return finishInterrupted(&cp) }   // ESC mid-stream
                return finishFailed(&cp, "provider error: \(error)", "provider '\(providerId)' error: \(error)",
                                    providerFault: ProviderFault.isProviderFault(error))
            }

            // 2) Parse the action; nudge (bounded) when the model wanders off-protocol.
            guard let action = ActionParser.parse(text) else {
                parseFailures += 1
                cp.messages.append(ChatMessage(role: .assistant, content: text))
                if parseFailures >= 3 {
                    if let final = await attemptTextFinalSynthesis(&cp, iteration: iteration) {
                        return final
                    }
                    return finishFailed(&cp, "no parseable action",
                                        "model did not emit a valid action after 3 attempts")
                }
                cp.messages.append(ChatMessage(role: .user, content:
                    Self.jsonProtocolRecoverySteering(tools: tools, shellEnabled: scopedContext.shell.enabled,
                                                      attempt: parseFailures)))
                cp.iteration = iteration; persist(&cp)
                continue
            }
            parseFailures = 0
            cp.messages.append(ChatMessage(role: .assistant, content: text))

            // 3) Done?
            if action.done {
                let summary = action.summary ?? action.message ?? "done"
                // VERIFY-BEFORE-DONE (R7): a code change that was never built/tested is NOT done. Nudge
                // up to N times; if it's STILL unverified, finish HONESTLY as a failure — never launder
                // an unbuilt change into success (the LLM's "done" doesn't outrank a real build/test).
                var doneDecision = verifyBeforeDone(canRunCommands: scopedContext.shell.enabled,
                                                    expectedOutcome: cp.expectedOutcome,
                                                    taskIntent: cp.intent,
                                                    nudges: verificationNudges)
                // SYMBOLIC RE-VERIFY (dogfood 2026-08-06): a done-claim with an unverified source edit
                // doesn't go back to the model first — if THIS run already produced a passing build/test,
                // the loop replays that exact approved command and re-judges on the real result. Only
                // when no replay exists (or it fails) do we spend a nudge asking the model.
                if case .nudge = doneDecision, let replay = lastVerify, !replayAttempted {
                    replayAttempted = true
                    if await replayVerification(replay, cp: &cp, iteration: iteration) {
                        doneDecision = verifyBeforeDone(canRunCommands: scopedContext.shell.enabled,
                                                        expectedOutcome: cp.expectedOutcome,
                                                        taskIntent: cp.intent,
                                                        nudges: verificationNudges)
                    }
                }
                switch doneDecision {
                case .nudge(let why):
                    verificationNudges += 1
                    cp.messages.append(ChatMessage(role: .user, content: CompletionVerifier.steering(reason: why)))
                    cp.iteration = iteration; persist(&cp)
                    continue
                case .failUnverified(let why):
                    let honest = "unverified — \(why)"
                    cp.status = .failed; cp.summary = honest; cp.iteration = iteration; persist(&cp)
                    await fireStopHook(summary: honest, success: false)
                    sink.emit(.stateChanged(.failed)); sink.emit(.failed(honest))
                    return (Outcome(success: false, summary: honest, iterations: iteration, checkpointId: cp.id), cp)
                case .accept:
                    break
                }
                cp.status = .completed; cp.summary = summary; cp.iteration = iteration; persist(&cp)
                await fireStopHook(summary: summary, success: true)
                sink.emit(.stateChanged(.completed)); sink.emit(.completed(summary: summary))
                return (Outcome(success: true, summary: summary, iterations: iteration, checkpointId: cp.id), cp)
            }

            // 4) Run the chosen tool.
            guard let tool = action.tool, !tool.isEmpty else {
                cp.messages.append(ChatMessage(role: .user, content:
                    "No tool specified and done was not set. Choose a tool or set \"done\": true."))
                cp.iteration = iteration; persist(&cp)
                continue
            }
            // 4a) Plan mode: refuse state-changing tools (propose, don't execute).
            if let block = planModeBlock(tool: tool, args: action.parameters) {
                sink.emit(.actionFinished(index: iteration, success: false, output: "", error: "blocked by plan mode"))
                cp.messages.append(ChatMessage(role: .user, content: block))
                cp.iteration = iteration; persist(&cp)
                continue
            }
            // 4b) Human-in-the-loop: sensitive tools require approval (shared with the native loop).
            let approvedForScope = await approve(tool: tool, args: action.parameters, context: scopedContext)
            if !approvedForScope {
                cp.messages.append(ChatMessage(role: .user, content:
                    "The user DECLINED to run \(tool). Do not retry it — choose a different approach or finish with done."))
                cp.iteration = iteration; persist(&cp)
                continue
            }
            // 4c) PreToolUse hooks may veto the action (user-configured guard).
            if let block = await preHookBlock(tool: tool, args: action.parameters) {
                sink.emit(.actionFinished(index: iteration, success: false, output: "", error: "blocked by PreToolUse hook"))
                cp.messages.append(ChatMessage(role: .user, content: block))
                cp.iteration = iteration; persist(&cp)
                continue
            }
            // Bracket the side effect: persist the action as PENDING BEFORE running it, so a crash
            // mid-tool is reconciled (not replayed) on resume.
            cp.pendingAction = PendingAction(
                tool: tool, argsSummary: Self.compactArgs(action.parameters), iteration: iteration,
                predictedEffects: tools.effectObservation(name: tool, arguments: action.parameters))
            persist(&cp)
            let displayDescription = Self.toolDisplayDescription(tool: tool,
                                                                 args: action.parameters,
                                                                 thinking: action.thinking)
            sink.emit(.actionStarted(index: iteration, tool: tool, description: displayDescription))
            let executionContext = scopedContext.withScopeOverrideApproved(approvedForScope)
            let result = await tools.execute(name: tool, arguments: action.parameters, context: executionContext)
            sink.emit(.actionFinished(index: iteration, success: result.success, output: result.output, error: result.error))
            let observed = tools.effectObservation(name: tool, arguments: action.parameters, result: result)
            recorder.record(tool: tool, argsFingerprint: TrajectoryAnalyzer.fingerprint(action.parameters), success: result.success,
                             failureDetail: result.success ? nil : String(Self.failureAwareRaw(result).prefix(1500)),
                             effectObservation: observed)
            if let cand = Self.replayCandidate(tool: tool, args: action.parameters, context: executionContext,
                                               succeeded: result.success, observed: observed) {
                lastVerify = cand; replayAttempted = false
            }

            // 5) Feed the observation back, wrapped in an envelope marked as untrusted DATA
            // (prompt-injection defense: file/shell/MCP output must never be obeyed as instructions).
            let raw = Self.failureAwareRaw(result)
            let body = Self.toolObservationBody(raw: raw, metadata: result.metadata,
                                                maxBytes: maxObservationBytes)
            let observation = Self.toolOutputEnvelope(tool: tool, success: result.success, body: body)
            cp.messages.append(ChatMessage(role: .user, content: observation))
            cp.pendingAction = nil   // the action completed; clear the bracket
            await firePostHook(tool: tool, args: action.parameters, success: result.success, output: body)

            // 5a) CAPABILITY-DENIAL fast recovery: when a tool is denied because it's unavailable (shell
            // off) or the action/tool doesn't exist, steer the model IMMEDIATELY to the real tools instead
            // of letting it burn turns retrying the same dead end (the desktop-cleanup death-spiral).
            if !result.success, let steer = Self.capabilityDenialSteer(error: result.error ?? body,
                                                                       tools: tools, shellEnabled: scopedContext.shell.enabled,
                                                                       readableRoots: scopedContext.externalReadRoots) {
                cp.messages.append(ChatMessage(role: .user, content: steer))
            }

            // 5b) Live re-plan: after a streak of failures, steer the model to revise its approach
            // (instead of looping on a doomed one), bounded by a re-plan budget.
            if result.success {
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
                if consecutiveFailures >= replanThreshold && replansUsed < maxReplans {
                    replansUsed += 1; consecutiveFailures = 0
                    let tv = Self.validToolNames(tools, shellEnabled: scopedContext.shell.enabled)
                    // Escalate: soft "revise" on the first re-plan, EXPLICIT diagnose→alternatives→pick once
                    // that didn't work (replansUsed >= 2).
                    let structured = replansUsed >= 2
                    sink.emit(.replanStarted(reason: structured
                        ? "structured re-plan (failures continued)"
                        : "\(replanThreshold) consecutive tool failures"))
                    let steer = structured
                        ? Self.structuredReplanSteering(recentFailure: body, validTools: tv)
                        : Self.replanSteering(recentFailure: body, validTools: tv)
                    cp.messages.append(ChatMessage(role: .user, content: steer))
                }
            }

            // 5b') TOOL-ERROR SPIRAL: the SAME tool + SAME args failing repeatedly (sharper + earlier than
            // the generic consecutive-failure replan above). Inject a targeted "stop repeating THIS exact
            // call, do X instead" steer to BREAK it — ONCE per distinct spiral signature, so we don't spam
            // (and if it keeps spiraling past the steer, the governor stops the run cleanly).
            if let spiral = ToolSpiralDetector.detect(recorder.snapshot()),
               spiral.signature != steeredSpiral {
                steeredSpiral = spiral.signature
                sink.emit(.replanStarted(reason: "breaking a tool-error spiral (\(spiral.tool) ×\(spiral.count))"))
                cp.messages.append(ChatMessage(role: .user, content: ToolSpiralDetector.steer(
                    tool: spiral.tool, count: spiral.count, error: result.error ?? body,
                    validTools: Self.validToolNames(tools, shellEnabled: scopedContext.shell.enabled))))
            }

            // 5c) Forced synthesis: research/audit loops can read forever and never write findings. Count
            // consecutive GATHERING (read-only) calls and, past a threshold, steer the model to STOP
            // reading and synthesize NOW. Bounded to one nudge per threshold-window (the MiMo audit gap).
            if Self.readOnlyTools.contains(tool) { consecutiveGathering += 1 } else { consecutiveGathering = 0 }
            if Self.shouldForceSynthesis(consecutiveGathering: consecutiveGathering, iteration: iteration,
                                         lastNudge: lastSynthesisNudge, maxIterations: maxIterations) {
                lastSynthesisNudge = iteration; consecutiveGathering = 0
                cp.messages.append(ChatMessage(role: .user,
                                               content: Self.synthesisSteering(
                                                validTools: Self.validToolNames(tools,
                                                                               shellEnabled: scopedContext.shell.enabled))))
            }
            cp.iteration = iteration; persist(&cp)
            // Reliability governor: stop EARLY (cleanly, with an honest summary) on a genuine loop the
            // re-plan nudges couldn't break — so the larger budget is spent FINISHING work, not spinning.
            let govTrajectory = recorder.snapshot()
            if case .stopStuck(let reason) = ProgressGovernor(hardCeiling: maxIterations)
                .decide(iteration: iteration, trajectory: govTrajectory,
                        analyzeFrom: recoveryAttempted ? recoveryMark : 0,
                        taskIntent: cp.intent) {
                if !recoveryAttempted {
                    // One HARD reset before giving up: abandon the failing approach, try a different one.
                    // Mark the trajectory position so the next stuck-check judges only POST-reset actions
                    // (else the stale stuck-pattern re-stops the run before recovery gets a chance).
                    recoveryAttempted = true
                    recoveryMark = govTrajectory.count
                    cp.messages.append(ChatMessage(role: .user, content: ProgressGovernor.recoverySteering(reason: reason)))
                    cp.iteration = iteration; persist(&cp)
                    continue
                }
                if let final = await attemptTextFinalSynthesis(&cp, iteration: iteration) { return final }
                return finishFailed(&cp, "stopped early — \(reason)", "stopped early (stuck after recovery): \(reason)")
            }
        }

        if let final = await attemptTextFinalSynthesis(&cp, iteration: iterationLimit) {
            return final
        }
        return finishFailed(&cp, "reached max iterations", "reached max iterations (\(maxIterations)) without finishing")
    }

    /// Native tool-calling loop: the model calls tools via the provider's native mechanism; we
    /// execute them and return tool-RESULT messages, until the model replies with no tool call.
    private func driveNative(_ initial: LoopCheckpoint) async -> NativeRun {
        var cp = initial
        guard let iterationLimit = Self.iterationLimit(from: cp.iteration, budget: maxIterations) else {
            return .finished(finishFailed(&cp, "invalid checkpoint cursor (\(cp.iteration))", "checkpoint is corrupt or out of range"))
        }
        reconcile(&cp)
        let scopedContext = context.withAuthorizationScope(AuthorizationScopeEngine.evaluate(Self.scopeRequestSource(for: cp.goal)))
        // Interactive chat/review turns don't get the recursive spawn vector (runaway-research guard).
        let turnTools = surfaceRelevantSelfTools(Self.conversationalToolset(tools, intent: cp.intent), goal: cp.goal)   // P2: task-targeted self__ advertisement (fail-open, no-op unless toggled)
        let specs = turnTools.toolSpecs()
        var nativeSystem = Self.nativeSystemPrompt(tools: turnTools, projectRoot: scopedContext.projectRoot,
                                                   planMode: planMode, shellEnabled: scopedContext.shell.enabled,
                                                   skillsXML: skillsXML,
                                                   readableRoots: scopedContext.externalReadRoots)
        nativeSystem += await recalledLessonsSuffix(goal: cp.goal)   // P1 recall→plan read-back (no-op unless warm)
        var settings = ModelSettings(temperature: 0.2, maxTokens: 4096,
                                     systemPrompt: nativeSystem,
                                     disableThinking: !extendedThinking)
        let profileStopsApplied = applyModelProfileStops(&settings)
        var consecutiveFailures = 0
        var replansUsed = 0
        var consecutiveGathering = 0
        var lastSynthesisNudge = -100
        var verificationNudges = 0         // verify-before-done: re-nudge up to a bound, then finish honestly
        var lastVerify: VerificationReplay? = nil   // last PASSING build/test of this run — re-verify replay candidate
        var replayAttempted = false                 // one deterministic replay per fresh candidate, never a loop
        var recoveryAttempted = false      // stuck-recovery: one hard reset before giving up
        var recoveryMark = 0               // trajectory length at recovery — judge only actions since

        func countFailure(_ body: String) {
            consecutiveFailures += 1
            if consecutiveFailures >= replanThreshold && replansUsed < maxReplans {
                replansUsed += 1
                consecutiveFailures = 0
                let tv = Self.validToolNames(tools, shellEnabled: scopedContext.shell.enabled)
                let structured = replansUsed >= 2   // escalate to explicit re-plan once the soft nudge failed
                sink.emit(.replanStarted(reason: structured
                    ? "structured re-plan (native failures continued)"
                    : "\(replanThreshold) consecutive native tool failures"))
                let steer = structured
                    ? Self.nativeStructuredReplanSteering(recentFailure: body, validTools: tv)
                    : Self.nativeReplanSteering(recentFailure: body, validTools: tv)
                cp.messages.append(ChatMessage(role: .user, content: steer))
            }
        }

        sink.emit(.stateChanged(.analyzing))
        let start = cp.iteration + 1
        guard start <= iterationLimit else { return .finished(finishFailed(&cp, "reached max iterations", "out of budget on resume")) }

        for iteration in start...iterationLimit {
            if Task.isCancelled { return .finished(finishInterrupted(&cp)) }   // esc-to-interrupt (main)
            if let halt = await budgetHalt(&cp) { return .finished(halt) }
            // Atomic reserve BEFORE the call (C2, aplus): if this call's estimate would breach the cap,
            // halt now — under a shared fleet ledger this stops two parallel agents both overspending.
            // Prepare and estimate from the exact prompt actually sent (not the full checkpoint).
            let outboundMessages = await prepareForProviderCall(&cp, mode: .native)
            let promptChars = outboundMessages.reduce(0) { $0 + $1.content.count }
            guard let reservation = await reserveForCall(promptChars: promptChars,
                                                         maxOutputTokens: settings.maxTokens) else {
                return .finished(await budgetDeniedHalt(&cp))   // wrap in NativeRun (main's return type)
            }
            sink.emit(.stateChanged(.executing))
            // Native preparation groups each assistant tool-call turn with all of its results, so
            // summarization and hard-window trimming can only keep or omit the exchange as a whole.
            var text = ""
            var calls: [ToolCallRef] = []
            var usage = TokenUsage.zero
            let started = Date()
            do {
                let stream = try await providers.streamTools(providerId: providerId, model: model,
                                                             messages: outboundMessages,
                                                             settings: settings, tools: specs,
                                                             allowFallback: !profileStopsApplied)
                for try await event in stream {
                    switch event {
                    case .delta(let d):
                        text += d
                    case .reasoning(let r): sink.emit(.reasoningDelta(r))
                    case .toolCall(let id, let name, let args): calls.append(ToolCallRef(id: id, name: name, argumentsJSON: args))
                    case .usage(let p, let c): usage = TokenUsage(promptTokens: p, completionTokens: c)
                    default: break
                    }
                }
                await recordLLMSpan(usage: usage, promptChars: promptChars,
                                    completionChars: text.count, started: started, status: .ok, reservation: reservation)
            } catch {
                await recordLLMSpan(usage: .zero, promptChars: promptChars,
                                    completionChars: 0, started: started, status: .error, reservation: reservation)
                if Task.isCancelled { return .finished(finishInterrupted(&cp)) }   // ESC mid-stream (main)
                // The model was routed to native tool-calling but the provider REJECTED the tool request.
                // In `.auto` mode, downgrade to the text protocol instead of dying. Forced `--tools native`
                // gets the honest failure — no silent protocol switch behind the user's back.
                // No successful tool round-trip yet ⇒ this is the FIRST native call — a rejection here is a
                // tool-schema/support problem (not history growth), so downgrade even on a generic 5xx.
                let noToolRoundTripYet = !cp.messages.contains { $0.role == .tool }
                if toolMode == .auto,
                   NativeProtocolDowngrade.shouldDowngrade(from: error, initialToolCall: noToolRoundTripYet) {
                    return .downgrade(cp)
                }
                return .finished(finishFailed(&cp, "provider error: \(error)", "provider '\(providerId)' error: \(error)",
                                              providerFault: ProviderFault.isProviderFault(error)))
            }

            // No tool call → the assistant's text is the final answer.
            if calls.isEmpty {
                let summary = text.isEmpty ? "done" : text
                if !text.isEmpty { sink.emit(.tokenDelta(text)) }
                cp.messages.append(ChatMessage(role: .assistant, content: text))
                // VERIFY-BEFORE-DONE (R7, native path): same symbolic gate — an unbuilt/untested code
                // change finishes as an honest failure after the nudge budget, never a laundered success.
                var doneDecision = verifyBeforeDone(canRunCommands: scopedContext.shell.enabled,
                                                    expectedOutcome: cp.expectedOutcome,
                                                    taskIntent: cp.intent,
                                                    nudges: verificationNudges)
                // SYMBOLIC RE-VERIFY (dogfood 2026-08-06): a done-claim with an unverified source edit
                // doesn't go back to the model first — if THIS run already produced a passing build/test,
                // the loop replays that exact approved command and re-judges on the real result. Only
                // when no replay exists (or it fails) do we spend a nudge asking the model.
                if case .nudge = doneDecision, let replay = lastVerify, !replayAttempted {
                    replayAttempted = true
                    if await replayVerification(replay, cp: &cp, iteration: iteration) {
                        doneDecision = verifyBeforeDone(canRunCommands: scopedContext.shell.enabled,
                                                        expectedOutcome: cp.expectedOutcome,
                                                        taskIntent: cp.intent,
                                                        nudges: verificationNudges)
                    }
                }
                switch doneDecision {
                case .nudge(let why):
                    verificationNudges += 1
                    cp.messages.append(ChatMessage(role: .user, content: CompletionVerifier.steering(reason: why)))
                    cp.iteration = iteration; persist(&cp)
                    continue
                case .failUnverified(let why):
                    let honest = "unverified — \(why)"
                    cp.status = .failed; cp.summary = honest; cp.iteration = iteration; persist(&cp)
                    await fireStopHook(summary: honest, success: false)
                    sink.emit(.stateChanged(.failed)); sink.emit(.failed(honest))
                    return .finished((Outcome(success: false, summary: honest, iterations: iteration, checkpointId: cp.id), cp))
                case .accept:
                    break
                }
                cp.status = .completed; cp.summary = summary; cp.iteration = iteration; persist(&cp)
                await fireStopHook(summary: summary, success: true)
                sink.emit(.stateChanged(.completed)); sink.emit(.completed(summary: summary))
                return .finished((Outcome(success: true, summary: summary, iterations: iteration, checkpointId: cp.id), cp))
            }

            // Record the assistant turn (text + the calls it made), then execute each call.
            cp.messages.append(ChatMessage(role: .assistant, content: text, toolCalls: calls))
            for call in calls {
                let args = Self.parseArgs(call.argumentsJSON)
                if let block = planModeBlock(tool: call.name, args: args) {
                    // Plan mode is a deliberate read-only setting — a blocked write is the user's CHOICE,
                    // not a tool failure. Don't feed the re-plan spiral (matches the text loop). (Codex Q3:
                    // same native/text divergence as the decline bug.)
                    sink.emit(.actionFinished(index: iteration, success: false, output: "", error: "blocked by plan mode"))
                    cp.messages.append(ChatMessage.toolResult(
                        callId: call.id,
                        content: Self.toolOutputEnvelope(tool: call.name, success: false, body: block)
                    ))
                    continue
                }
                let approvedForScope = await approve(tool: call.name, args: args, context: scopedContext)
                if !approvedForScope {
                    // A user DECLINE is a deliberate choice, NOT a tool failure. Counting it toward the
                    // re-plan/"unable to" failure spiral made kist abandon a task after a couple of skips
                    // and falsely report "I am unable to create directories" (it had just created one).
                    let body = "The user DECLINED to run \(call.name). Do not retry it — choose a different approach or finish with done."
                    cp.messages.append(ChatMessage.toolResult(
                        callId: call.id,
                        content: Self.toolOutputEnvelope(tool: call.name, success: false, body: body)
                    ))
                    continue
                }
                if let block = await preHookBlock(tool: call.name, args: args) {
                    // A PreToolUse hook veto is a policy denial, not a tool malfunction — inform the model
                    // (so it routes around it) but don't count it as a failure (matches the text loop).
                    sink.emit(.actionFinished(index: iteration, success: false, output: "", error: "blocked by PreToolUse hook"))
                    cp.messages.append(ChatMessage.toolResult(
                        callId: call.id,
                        content: Self.toolOutputEnvelope(tool: call.name, success: false, body: block)
                    ))
                    continue
                }
                cp.pendingAction = PendingAction(
                    tool: call.name, argsSummary: Self.compactArgs(args), iteration: iteration,
                    predictedEffects: tools.effectObservation(name: call.name, arguments: args))
                persist(&cp)
                let displayDescription = Self.toolDisplayDescription(tool: call.name, args: args)
                sink.emit(.actionStarted(index: iteration, tool: call.name, description: displayDescription))
                let executionContext = scopedContext.withScopeOverrideApproved(approvedForScope)
                let result = await tools.execute(name: call.name, arguments: args, context: executionContext)
                sink.emit(.actionFinished(index: iteration, success: result.success, output: result.output, error: result.error))
                let observed = tools.effectObservation(name: call.name, arguments: args, result: result)
                recorder.record(tool: call.name, argsFingerprint: TrajectoryAnalyzer.fingerprint(args), success: result.success,
                                 failureDetail: result.success ? nil : String(Self.failureAwareRaw(result).prefix(1500)),
                                 effectObservation: observed)
                if let cand = Self.replayCandidate(tool: call.name, args: args, context: executionContext,
                                                   succeeded: result.success, observed: observed) {
                    lastVerify = cand; replayAttempted = false
                }
                let raw = Self.failureAwareRaw(result)
                let body = Self.toolObservationBody(raw: raw, metadata: result.metadata,
                                                    maxBytes: maxObservationBytes)
                cp.messages.append(ChatMessage.toolResult(
                    callId: call.id,
                    content: Self.toolOutputEnvelope(tool: call.name, success: result.success, body: body)
                ))
                cp.pendingAction = nil
                await firePostHook(tool: call.name, args: args, success: result.success, output: body)
                if result.success {
                    consecutiveFailures = 0
                } else {
                    countFailure(body)
                }
                if Self.readOnlyTools.contains(call.name) { consecutiveGathering += 1 } else { consecutiveGathering = 0 }
            }
            // Forced synthesis (same as the text path): stop endless read-only gathering, write findings.
            if Self.shouldForceSynthesis(consecutiveGathering: consecutiveGathering, iteration: iteration,
                                         lastNudge: lastSynthesisNudge, maxIterations: maxIterations) {
                lastSynthesisNudge = iteration; consecutiveGathering = 0
                cp.messages.append(ChatMessage(role: .user,
                                               content: Self.synthesisSteering(
                                                validTools: Self.validToolNames(tools,
                                                                               shellEnabled: scopedContext.shell.enabled))))
            }
            cp.iteration = iteration; persist(&cp)
            // Reliability governor (native path): same early-stop on an unrecoverable loop.
            let govTrajectory = recorder.snapshot()
            if case .stopStuck(let reason) = ProgressGovernor(hardCeiling: maxIterations)
                .decide(iteration: iteration, trajectory: govTrajectory,
                        analyzeFrom: recoveryAttempted ? recoveryMark : 0,
                        taskIntent: cp.intent) {
                if !recoveryAttempted {
                    recoveryAttempted = true
                    recoveryMark = govTrajectory.count
                    cp.messages.append(ChatMessage(role: .user, content: ProgressGovernor.recoverySteering(reason: reason)))
                    cp.iteration = iteration; persist(&cp)
                    continue
                }
                if let final = await attemptNativeFinalSynthesis(&cp, iteration: iteration) { return .finished(final) }
                return .finished(finishFailed(&cp, "stopped early — \(reason)", "stopped early (stuck after recovery): \(reason)"))
            }
        }
        if let final = await attemptNativeFinalSynthesis(&cp, iteration: iterationLimit) {
            return .finished(final)
        }
        return .finished(finishFailed(&cp, "reached max iterations", "reached max iterations (\(maxIterations)) without finishing"))
    }

    // MARK: - Shared helpers

    /// In plan mode, block any tool that isn't read-only and return the steering message to feed
    /// back (nil = allowed). Keeps the agent investigating + proposing rather than executing.
    /// Read-only `tasks` subactions (viewing/validating the board) never mutate plan.json, so they are
    /// safe in plan mode even though the `tasks` tool as a whole is a writer. Kept in sync with
    /// ManageTasksTool: `list`, `validate`, `check`, and the default (no action == list).
    static let readOnlyTaskActions: Set<String> = ["list", "validate", "check"]

    /// Pure, testable: a `tasks` call that only READS the board (safe in plan mode). A plan-mode agent
    /// must be able to READ the shared board to ground its proposal; only board WRITES (add/start/done/
    /// block/update/evidence/clear) stay blocked. Default (no action) is `list` — a read. Mirrors
    /// ManageTasksTool.execute's action normalization exactly.
    static func isReadOnlyTasksCall(tool: String, args: [String: Any]) -> Bool {
        guard tool == "tasks" else { return false }
        let action = (args["action"] as? String ?? "list").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return readOnlyTaskActions.contains(action)
    }

    private func planModeBlock(tool: String, args: [String: Any] = [:]) -> String? {
        guard planMode, !Self.readOnlyTools.contains(tool) else { return nil }
        if Self.isReadOnlyTasksCall(tool: tool, args: args) { return nil }
        return "PLAN MODE is ON — \"\(tool)\" would modify state, so it was NOT run. Only read/search " +
            "tools are allowed (\(Self.readOnlyTools.sorted().joined(separator: ", "))). Investigate further, " +
            "using read_file, context_brain, search_code, list_files, or glob_files; do NOT retry blocked " +
            "tools in plan mode. Or finish with done:true and present your step-by-step PLAN as the summary. " +
            "The user reviews the plan and turns plan mode off before anything is executed."
    }

    /// Fire PreToolUse hooks; returns a steering message if a hook BLOCKED the action (nil = allowed).
    private func preHookBlock(tool: String, args: [String: Any]) async -> String? {
        guard let hooks else { return nil }
        let decision = await hooks.firePreToolUse(tool: tool, arguments: args)
        guard decision.blocked else { return nil }
        return "A PreToolUse hook BLOCKED \"\(tool)\": \(decision.reason ?? "no reason given"). " +
            "Do NOT retry it — choose a different approach or finish with done."
    }

    /// Fire PostToolUse hooks (observe only — the side effect already happened).
    private func firePostHook(tool: String, args: [String: Any], success: Bool, output: String) async {
        guard let hooks else { return }
        await hooks.firePostToolUse(tool: tool, arguments: args, success: success, output: output)
    }

    /// Fire Stop hooks when the run reaches a terminal state.
    private func fireStopHook(summary: String, success: Bool) async {
        guard let hooks else { return }
        await hooks.fireStop(summary: summary, success: success)
    }

    /// Ask for approval if the tool is sensitive (both loops).
    private func approve(tool: String, args: [String: Any], context: ToolContext) async -> Bool {
        if let reason = context.authorizationScope?.requiresExplicitApproval(tool: tool, arguments: args) {
            let desc = "AUTHORIZATION SCOPE — \(tool)(\(Self.compactArgs(args))): \(reason)"
            sink.emit(.awaitingApproval(planSummary: desc))
            return await interactor.requestApproval(planSummary: desc, dangerous: true)
        }
        // ACT-vs-ASK: classify the action's reversibility. `.safe` never prompts; `.dangerous`
        // (irreversible/high-blast-radius) ALWAYS prompts — even when the tool isn't in the configured
        // approval set and even past a session "allow all"; `.mutating` follows the normal approval set.
        let risk = ReversibilityClassifier.assess(tool: tool, args: args, projectRoot: context.projectRoot)
        if risk == .safe { return true }
        guard risk == .dangerous || approvalTools.contains(tool) else { return true }
        let desc = (risk == .dangerous ? "⚠ IRREVERSIBLE — " : "") + "\(tool)(\(Self.compactArgs(args)))"
        sink.emit(.awaitingApproval(planSummary: desc))
        return await interactor.requestApproval(planSummary: desc, dangerous: risk == .dangerous)
    }

    private func finishFailed(_ cp: inout LoopCheckpoint, _ summary: String, _ reason: String,
                              providerFault: Bool = false) -> (Outcome, LoopCheckpoint) {
        cp.status = .failed; cp.summary = summary; persist(&cp)
        sink.emit(.failed(reason))
        return (Outcome(success: false, summary: summary, iterations: cp.iteration, checkpointId: cp.id,
                        providerFault: providerFault), cp)
    }

    /// R7: the verify-before-done decision, shared by BOTH done sites (native tool-call path + text
    /// path). `.accept` = finish; `.nudge` = steer once more (budget remains); `.failUnverified` =
    /// nudges exhausted AND the code change is STILL unbuilt/untested → finish HONESTLY as a failure
    /// instead of laundering an unverified change into success (symbolic-first: the LLM's "done" is
    /// not trusted over a real build/test). A source mutation with shell unavailable fails unverified
    /// immediately: repeatedly nudging the model to run a command it cannot run would only waste turns.
    enum DoneDecision: Equatable { case accept, nudge(String), failUnverified(String) }
    func verifyBeforeDone(canRunCommands: Bool,
                          expectedOutcome: TaskBrief.ExpectedOutcome? = nil,
                          taskIntent: TaskBrief.Intent? = nil,
                          nudges: Int) -> DoneDecision {
        let trajectory = recorder.snapshot()
        guard case .needsVerification(let why) = CompletionVerifier().check(
            trajectory: trajectory, canRunCommands: canRunCommands,
            expectedOutcome: expectedOutcome, taskIntent: taskIntent) else { return .accept }
        // Missing promised work can still be repaired by its own tools when shell execution is disabled:
        // filesystem tools for mutation, research/read tools for evidence, and desktop/control tools for
        // external actuation. Only a source-verification failure is impossible without a shell and should
        // therefore fail immediately instead of spending the nudge budget on an unavailable command.
        let missingToolReachableOutcome: Bool
        switch expectedOutcome {
        case .mutation:
            missingToolReachableOutcome = !trajectory.contains {
                $0.success && ($0.observedEffects.confirmsMutation
                    || (taskIntent == .fleet && $0.observedEffects.progress == .delegation))
            }
        case .evidence:
            missingToolReachableOutcome = !trajectory.contains {
                $0.success && ($0.observedEffects.progress == .research
                    || $0.observedEffects.progress == .evidence)
            }
        case .externalAction:
            missingToolReachableOutcome = !trajectory.contains {
                $0.success && $0.observedEffects.progress == .externalState
            }
        case .answer, .plan, .none:
            missingToolReachableOutcome = false
        }
        if !canRunCommands && !missingToolReachableOutcome { return .failUnverified(why) }
        return nudges < Self.maxVerificationNudges ? .nudge(why) : .failUnverified(why)
    }

    /// User pressed ESC (esc-to-interrupt). The driving Task is cancelled; we end the turn cleanly at the
    /// next iteration boundary and persist the checkpoint as PAUSED so the run can be resumed, not lost.
    private func finishInterrupted(_ cp: inout LoopCheckpoint) -> (Outcome, LoopCheckpoint) {
        cp.status = .paused; cp.summary = "interrupted"; persist(&cp)
        sink.emit(.stateChanged(.cancelled))
        return (Outcome(success: false, summary: "interrupted", iterations: cp.iteration, checkpointId: cp.id), cp)
    }

    /// Safe absolute iteration limit for this invocation. Resume gets a fresh budget.
    static func iterationLimit(from cursor: Int, budget: Int) -> Int? {
        guard cursor >= 0, budget > 0, cursor <= Int.max - budget else { return nil }
        return cursor + budget
    }

    /// If the token ceiling is reached, finish the run as a budget failure (checked at the top of
    /// each iteration, BEFORE the next model call — so a resumed run that's already over halts at
    /// once and never spends past the cap). Returns nil when uncapped or still under budget.
    private func budgetHalt(_ cp: inout LoopCheckpoint) async -> (Outcome, LoopCheckpoint)? {
        guard let budget, let reason = await budget.exceededReason() else { return nil }
        sink.emit(.stateChanged(.failed))
        return finishFailed(&cp, reason, "\(reason) — raise --budget / --max-cost to continue")
    }

    /// Last-chance answer pass. Research models can spend the whole action budget gathering; this
    /// converts "I gathered a lot and then failed" into a final synthesis without granting more tools.
    private func attemptTextFinalSynthesis(_ cp: inout LoopCheckpoint, iteration: Int) async -> (Outcome, LoopCheckpoint)? {
        // Don't spend another model call on synthesis once the budget is already blown (this pass
        // runs after the loop, so the top-of-iteration check can't guard it).
        if let budget, await budget.isExceeded() { return nil }
        cp.messages.append(ChatMessage(role: .user, content: Self.finalSynthesisSteering(textProtocol: true)))
        var settings = ModelSettings(temperature: 0.2, maxTokens: 4096,
                                     systemPrompt: Self.finalOnlySystemPrompt(textProtocol: true),
                                     disableThinking: !extendedThinking)
        let profileStopsApplied = applyModelProfileStops(&settings)
        let text: String
        do {
            let outboundMessages = await prepareForProviderCall(&cp, mode: .text,
                                                                reassertObjective: false)
            text = try await streamCompletion(messages: outboundMessages, settings: settings,
                                              allowFallback: !profileStopsApplied)
        } catch {
            return nil
        }
        cp.messages.append(ChatMessage(role: .assistant, content: text))

        if let action = ActionParser.parse(text), action.done {
            let summary = action.summary ?? action.message ?? "done"
            return await finishCompleted(&cp, summary: summary, iteration: iteration)
        }
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty, ActionParser.parse(text)?.tool == nil else { return nil }
        return await finishCompleted(&cp, summary: plain, iteration: iteration)
    }

    /// Native equivalent of the last-chance answer pass. It deliberately uses the plain completion
    /// route (no tool specs) so the provider has one job: write the answer from gathered context.
    private func attemptNativeFinalSynthesis(_ cp: inout LoopCheckpoint, iteration: Int) async -> (Outcome, LoopCheckpoint)? {
        // Don't spend another model call on synthesis once the budget is already blown (this pass
        // runs after the loop, so the top-of-iteration check can't guard it).
        if let budget, await budget.isExceeded() { return nil }
        cp.messages.append(ChatMessage(role: .user, content: Self.finalSynthesisSteering(textProtocol: false)))
        var settings = ModelSettings(temperature: 0.2, maxTokens: 4096,
                                     systemPrompt: Self.finalOnlySystemPrompt(textProtocol: false),
                                     disableThinking: !extendedThinking)
        let profileStopsApplied = applyModelProfileStops(&settings)
        let text: String
        do {
            let outboundMessages = await prepareForProviderCall(&cp, mode: .native,
                                                                reassertObjective: false)
            text = try await streamCompletion(messages: outboundMessages, settings: settings,
                                              allowFallback: !profileStopsApplied)
        } catch {
            return nil
        }
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        cp.messages.append(ChatMessage(role: .assistant, content: plain))
        sink.emit(.tokenDelta(plain))
        return await finishCompleted(&cp, summary: plain, iteration: iteration)
    }

    private func finishCompleted(_ cp: inout LoopCheckpoint, summary: String,
                                 iteration: Int) async -> (Outcome, LoopCheckpoint) {
        // Final synthesis is still only a model claim. It must pass the same durable external-evidence
        // gate as the ordinary text/native done paths; otherwise exhausting the loop after a paused,
        // unverified edit could launder that edit into success through this fallback.
        if case .needsVerification(let why) = CompletionVerifier().check(
            trajectory: recorder.snapshot(), canRunCommands: context.shell.enabled,
            expectedOutcome: cp.expectedOutcome, taskIntent: cp.intent) {
            cp.iteration = iteration
            let honest = "unverified — \(why)"
            await fireStopHook(summary: honest, success: false)
            return finishFailed(&cp, honest, honest)
        }
        cp.status = .completed; cp.summary = summary; cp.iteration = iteration; persist(&cp)
        await fireStopHook(summary: summary, success: true)
        sink.emit(.stateChanged(.completed)); sink.emit(.completed(summary: summary))
        return (Outcome(success: true, summary: summary, iterations: iteration, checkpointId: cp.id), cp)
    }

    private func streamCompletion(messages: [ChatMessage], settings: ModelSettings, allowFallback: Bool = true) async throws -> String {
        let started = Date()
        let promptChars = messages.reduce(0) { $0 + $1.content.count }
        // Atomic reserve BEFORE the call (C2, aplus). Denied ⇒ throw so the caller halts without spending.
        guard let reservation = await reserveForCall(promptChars: promptChars,
                                                     maxOutputTokens: settings.maxTokens) else {
            throw BudgetDeniedError(reason: await budget?.exceededReason() ?? "budget would be exceeded by the next model call")
        }
        var text = ""
        var usage = TokenUsage.zero
        do {
            // The stream() call is INSIDE this do so that a throw HERE (unknown provider, connection
            // refused, etc.) still releases the reservation — otherwise the hold leaks and falsely
            // denies every later call, wedging the run (Codex HIGH #1).
            let stream = try await providers.stream(providerId: providerId, model: model, messages: messages,
                                                    settings: settings, allowFallback: allowFallback)
            for try await event in stream {
                switch event {
                case .delta(let d):
                    // The visible text protocol is internal control data. Do not stream it to hosts,
                    // or terminal consumers will print raw action JSON and tool arguments.
                    text += d
                case .reasoning(let r): sink.emit(.reasoningDelta(r))
                case .usage(let p, let c): usage = TokenUsage(promptTokens: p, completionTokens: c)
                default: break
                }
            }
        } catch {
            // Release the reservation on ANY failure so a failed call doesn't leak its hold.
            await recordLLMSpan(usage: .zero, promptChars: promptChars, completionChars: 0,
                                started: started, status: .error, reservation: reservation)
            throw error
        }
        await recordLLMSpan(usage: usage,
                            promptChars: promptChars,
                            completionChars: text.count,
                            started: started,
                            status: .ok,
                            reservation: reservation)
        return text
    }

    /// A held reservation. `id` is the BudgetLedger reservation id to release at commit (nil when there
    /// is no budget → nothing to commit). Passed from the call site to recordLLMSpan so the hold is
    /// released and reconciled to actual at the single chokepoint.
    struct Reservation: Sendable { let id: Int? }

    /// Thrown by the text path's streamCompletion when a reservation is denied, so the caller halts
    /// with an honest budget message rather than a generic provider error.
    struct BudgetDeniedError: Error { let reason: String }

    /// Atomic reserve-before-spend (C2): estimate this call's cost and reserve it BEFORE issuing it.
    /// Returns nil = DENIED (the reservation would breach a cap → the caller halts without calling).
    /// On an uncapped ledger (or no budget) returns a zero reservation (always allowed).
    func reserveForCall(promptChars: Int, maxOutputTokens: Int) async -> Reservation? {
        guard let budget else { return Reservation(id: nil) }   // no budget → nothing to reserve/commit
        let estPrompt = max(0, promptChars) / 4
        let estCompletion = max(0, maxOutputTokens)
        let estTokens = estPrompt + estCompletion
        let estUSD = CompetitiveBenchmark.priceUSD(vendor: providerId,
                                                   promptTokens: estPrompt, completionTokens: estCompletion) ?? 0
        guard let id = await budget.reserve(tokens: estTokens, usd: estUSD) else { return nil }   // denied
        return Reservation(id: id)
    }

    /// Halt when a reservation was denied (the next call would breach the cap).
    private func budgetDeniedHalt(_ cp: inout LoopCheckpoint) async -> (Outcome, LoopCheckpoint) {
        let reason = await budget?.exceededReason()
            ?? "budget would be exceeded by the next model call"
        sink.emit(.stateChanged(.failed))
        return finishFailed(&cp, reason, "\(reason) — raise --budget / --max-cost to continue")
    }

    func recordLLMSpan(usage: TokenUsage, promptChars: Int, completionChars: Int,
                               started: Date, status: SpanStatus, reservation: Reservation? = nil) async {
        // Budget accounting runs at THIS single chokepoint (both the native and text drive paths
        // funnel every model call through recordLLMSpan), and BEFORE the trace guard so the cap is
        // enforced even when no trace recorder is attached. Measured tokens when the provider reports
        // them; a clearly-labeled ~4-char estimate otherwise.
        let measured = usage.isZero ? TokenUsage.estimate(promptChars: promptChars, completionChars: completionChars) : usage
        let usd = CompetitiveBenchmark.priceUSD(vendor: providerId,
                                                promptTokens: measured.promptTokens,
                                                completionTokens: measured.completionTokens) ?? 0
        // Commit (aplus): release the pre-call reservation (by id) and book the ACTUAL spend (atomic
        // reserve→commit). A reservation with a nil id means there was no budget — nothing to commit.
        // Legacy callers without a reservation (post-loop synthesis) fall back to a plain add.
        if let reservation {
            if let id = reservation.id {
                await budget?.commit(reservation: id, actualTokens: measured.total, actualUSD: usd)
            }
        } else {
            await budget?.add(tokens: measured.total, usd: usd)
        }
        // main: emit the live token-usage signal for the UI (aplus dropped this — restored).
        sink.emit(.usage(promptTokens: measured.promptTokens,
                         completionTokens: measured.completionTokens,
                         estimated: usage.isZero))
        guard let traceRecorder else { return }
        await traceRecorder.record(AgentSpan(id: TraceID.make(), traceId: traceRecorder.traceId,
                                             kind: .llmCall, role: traceRole,
                                             vendor: providerId, model: model,
                                             promptTokens: measured.promptTokens,
                                             completionTokens: measured.completionTokens,
                                             startedAt: started, endedAt: Date(),
                                             status: status))
    }

    /// The live tool contract for THIS loop (what the model sees) — used by `/tools` so the user can audit it.
    public func renderToolContract() -> String {
        ToolContractBook.render(tools: tools, disabled: ToolContractBook.disabledMap(shellEnabled: context.shell.enabled))
    }

    /// The names of every tool callable this turn — used by self-evolution's CapabilityDiscovery to point a
    /// knowledge-gap recovery at a tool's real "list capabilities" sibling (only ones that actually exist).
    public var toolNames: [String] { tools.all().map { $0.name } }

    /// Whether run_command may actually execute this turn — needed to apply the same execution-grounding
    /// verifier the great loop uses (GreatLoopVerifier) to the interactive turn-end scorecard (P6 fix).
    public var shellEnabled: Bool { context.shell.enabled }

}
