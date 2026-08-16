import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Wires AgentCore's providers + sandboxed tools (+ external MCP server tools) + the headless
/// loop into a one-shot, resumed, or interactive run.
enum KistRunner {

    // internal (not private) so sibling command files in the Kist module can reuse them.
    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    static func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// Built-in providers + any user-added custom providers, behind the default key resolver.
    /// Rebuilt after a model is added so the new one is immediately selectable.
    static func makeRegistry() -> ProviderRegistry {
        ProviderRegistry(providers: ProviderCatalog.all + CustomProviderStore.load(),
                         fallbackProviderIds: ModelRouter.defaultFallbackProviderIds)
    }

    /// Choose the semantic-memory embedder. `KIST_EMBEDDER=ollama` opts into LOCAL embeddings
    /// (offline, free, no key — requires a running Ollama); otherwise Gemini when its key is
    /// present. Returns nil (semantic memory off) when neither applies — no silent local dependency.
    static func makeEmbedder(registry: ProviderRegistry) -> EmbeddingProviding? {
        let choice = (ProcessInfo.processInfo.environment["KIST_EMBEDDER"] ?? "").lowercased()
        if choice == "ollama" {
            let model = ProcessInfo.processInfo.environment["KIST_EMBED_MODEL"] ?? OllamaEmbeddingClient.defaultModel
            return OllamaEmbeddingClient(model: model)
        }
        if let geminiKey = registry.apiKey(forProviderId: "gemini") {
            return GeminiEmbeddingClient(apiKey: geminiKey)
        }
        return nil
    }
    private struct ProviderPick { let providerId: String; let model: String? }

    /// Tools that mutate state, run code/network, or read live desktop/app state — prompt for approval in
    /// interactive mode.
    static let sensitiveTools: Set<String> = [
        // ast_grep_apply spawns the external ast-grep binary to rewrite files — a
        // process-spawning mutator like run_command, NOT a ConfinedRoot-confined edit,
        // so it stays approval-gated even under FILE-TREE TRUST.
        "run_command", "computer_control", "desktop_control", "computer_use_selftest", "tap", "locate", "look", "ui_elements", "ax_press", "wait_for_screen", "watch_screen", "browse", "watch_video", "live_screen_watch",
        "custom_tool", "visual_verify", "research_run", "ast_grep_apply", "pentest",
    ]
    // FILE-TREE TRUST: file mutations (write_file/edit_file/apply_patch/move_file/make_dir) and media
    // generation are NOT gated — they're confined to the project root (ConfinedRoot blocks any escape),
    // so they're safe and gating every mkdir/write is what caused the approval-deadlock token burn.
    // Still gated: run_command (arbitrary shell), custom_tool (arbitrary code), browse/computer_control.

    /// The file-mutation subset auto-approved by the shift+tab "accept edits" tier (Claude-Code-style).
    /// Deliberately EXCLUDES apply_patch (can delete files via delete-hunks) and move_file (can clobber)
    /// — those keep prompting even in accept-edits (MiMo review). Shell/browse/computer-control/media
    /// generation also still prompt.
    static let editTools: Set<String> = [
        "write_file", "edit_file", "make_dir",
    ]

    /// Returns a process exit code (0 success, non-zero failure).
    static func run(_ opts: KistOptions) async -> Int32 {
        // Route MCP diagnostics through the same terminal owner as stdout/stderr. Before a pinned
        // REPL exists the router preserves ordinary stderr behavior; during a sticky turn it joins
        // the coordinator's serialized transcript stream.
        MCPLog.installDiagnosticSink { TerminalScreenCoordinator.routeDiagnosticLine($0) }
        defer { MCPLog.resetDiagnosticSink() }

        // Hidden, offline visual verification. Dispatch before registry/tool/MCP construction so this
        // cannot touch a provider, keychain, server, or network.
        if opts.stickyBarSelfTest {
            return await runStickyBarSelfTest()
        }

        var registry = makeRegistry()
        let checkpoints = LoopCheckpointStore()
        let config = KistConfig.load()
        let model = opts.model ?? config.model       // flags > config > provider default
        let toolMode = ToolMode(rawValue: opts.toolMode) ?? .auto
        let fetchAllowedHosts = opts.fetchAllowedHosts.isEmpty ? config.fetchAllowedHosts : opts.fetchAllowedHosts

        if opts.listProviders { return listProviders(registry) }
        if opts.geminiTest { return await runGeminiTest(registry) }
        if let spec = opts.probeModel { return await runModelProbe(spec, registry) }
        if let path = opts.inspectModel { return runInspectModel(path) }
        // Read-only archive view — dispatch EARLY (like --list-providers): it needs no goal and must not
        // fall through to the interactive REPL.
        if opts.evolveStatus { return runEvolutionStatus(root: ToolContext.canonicalize(opts.project) ?? opts.project) }
        if opts.evolveTree { return runEvolutionTree(root: ToolContext.canonicalize(opts.project) ?? opts.project) }
        if opts.evolveArm { return runEvolveArm(opts, root: ToolContext.canonicalize(opts.project) ?? opts.project) }
        if opts.evolveDisarm { return runEvolveDisarm(root: ToolContext.canonicalize(opts.project) ?? opts.project) }
        if let spec = opts.onboardModel { return await runOnboard(spec, doc: opts.onboardDoc, registry) }
        if opts.providerHealth {
            // Offline health must be instant/noninteractive. Do not touch the macOS Keychain here:
            // locked/UI-gated items can block a CLI with no prompt. Real runs and live probes still
            // use the default Keychain+env resolver.
            let noninteractive = ProviderRegistry(keyStore: FileKeyStore(),
                                                  fallbackProviderIds: ModelRouter.defaultFallbackProviderIds)
            return await providerHealth(noninteractive, probe: false)
        }
        if opts.probeProviders { return await providerHealth(registry, probe: true) }
        if opts.providersDoctor { print(await providerDoctorReport(registry)); return 0 }
        if let mcpAuthArgs = opts.mcpAuth { return await runMCPAuth(mcpAuthArgs) }
        if opts.protocolStatus { return protocolStatus(projectRoot: opts.project) }
        if let replayId = opts.replayId { return replayRun(projectRoot: opts.project, id: replayId) }
        if opts.listRuns { return listRuns(checkpoints) }
        if opts.installGuardHook { return installReceiptHook(opts) }
        if opts.verifyReceipt { return runReceiptVerify(opts) }
        if opts.guardReceipt { return runReceiptGuard(opts) }
        if opts.ciGuard { return runReceiptCIGuard(opts) }
        if opts.genIssuerKey != nil { return runGenIssuerKey(opts) }
        if opts.trustIssuer != nil { return runTrustIssuer(opts) }
        if opts.unpinIssuer != nil { return runUnpinIssuer(opts) }
        if opts.revokeIssuer != nil { return runRevokeIssuer(opts) }
        if opts.unrevokeIssuer != nil { return runUnrevokeIssuer(opts) }
        if opts.listIssuers { return runListIssuers(opts) }
        if opts.trustRoot != nil { return runTrustRoot(opts) }
        if opts.listRoots { return runListRoots(opts) }
        if opts.makeBundle { return runMakeBundle(opts) }
        if opts.verifyBundle != nil { return runVerifyBundle(opts) }
        if opts.signReceipt != nil { return runSignReceipt(opts) }

        // HOST-CONTROL HARD-DENY (council 2026-07-03): host-control is in the DEFAULT deny list, so it's denied
        // at EVERY ShellPolicy site (evolve/fleet workers too — Codex multi-site catch). Only THIS top-level
        // path opts OUT when armed, by passing baseDeny. Unarmed ⇒ defaultDeny (incl. host-control) → hard
        // refusal via binaryRefusalReason, independent of the interactor (--auto/--yolo/AutoApprove can't run
        // osascript); nested kist forces enableComputerUse=false so it's covered. Armed ⇒ normal approval.
        let shellDeny = opts.enableComputerUse ? ShellPolicy.baseDeny : ShellPolicy.defaultDeny
        // `sandboxed` tracks the SAME opts.sandbox that arms the Seatbelt policy below, so raw shell
        // (pipes/redirects) can run hands-off ONLY when the kernel is actually confining the process
        // (writes → project root, network denied); they can never diverge.
        let shell: ShellPolicy = opts.allowShell
            ? ShellPolicy(enabled: true, autoApprove: true, deny: shellDeny, sandboxed: opts.sandbox)
            : .denied
        let sandbox: SandboxPolicy = opts.sandbox ? .confined() : .disabled
        // External READ-ONLY roots (--allow-read). Warn loudly on a root that doesn't resolve —
        // ToolContext drops it silently (fail-closed), and the user should know their CD/USB
        // path granted nothing rather than discover it mid-run.
        for dir in opts.allowReadPaths where ToolContext.canonicalize(dir) == nil {
            err("warning: --allow-read path does not exist (granting nothing): \(dir)")
        }
        if opts.allowReadPaths.contains(where: { ToolContext.canonicalize($0) == "/" }) {
            err("warning: --allow-read / is refused — arm specific trees (e.g. /Volumes) instead")
        }
        // Broad-ancestor warning: arming $HOME (or an ancestor of it, e.g. /Users) makes every
        // secret under it (~/.ssh, ~/.aws, browser data) readable evidence for the model. Allowed
        // — explicit user grant — but never silent.
        let home = NSHomeDirectory()
        for dir in opts.allowReadPaths {
            if let real = ToolContext.canonicalize(dir), real == home || home.hasPrefix(real + "/") {
                err("warning: --allow-read \(dir) exposes your ENTIRE home tree (incl. ~/.ssh, ~/.aws) read-only to the model — prefer a narrower path like /Volumes")
            }
        }
        // L2 GUARDRAIL (council 2026-07-03): warn loudly if this UNARMED coding binary already holds a
        // host-control TCC grant — the state where an agent could drive the desktop via in-language APIs that
        // no deny-list stops. The complete fix is a separately-signed computer-use binary (documented).
        if let hostControlWarning = HostControlPreflight.warningForCurrentProcess(enableComputerUse: opts.enableComputerUse) {
            err(hostControlWarning)
        }

        // RESUME: provider/model/project come from the saved checkpoint; policy from this invocation.
        if opts.resumeLast || opts.resumeId != nil {
            let cp: LoopCheckpoint
            if let id = opts.resumeId {
                guard let c = try? checkpoints.load(id: id) else { err("error: unknown checkpoint '\(id)'. Try --list."); return 2 }
                cp = c
            } else {
                guard let c = checkpoints.resumable().first else { err("error: no resumable runs. (--list)"); return 2 }
                cp = c
            }
            guard let root = ToolContext.canonicalize(cp.projectRoot) else {
                err("error: the run's project path no longer exists: \(cp.projectRoot)"); return 2
            }
            let context = ToolContext(projectRoot: root, shell: shell, sandbox: sandbox,
                                      externalReadRoots: opts.allowReadPaths)
            note("kist · resuming \(cp.title) · \(cp.providerId) · iter \(cp.iteration)")
            // Resume with the SAME full tool set as a fresh run (previously it lost cortex/browse/tasks/etc.).
            let resumeExtraTools = Self.buildExtraTools(root: root, fetchAllowedHosts: fetchAllowedHosts, opts: opts, registry: registry)
            return await withTools(projectRoot: root, fetchAllowedHosts: fetchAllowedHosts, extraTools: resumeExtraTools, enableComputerUse: opts.enableComputerUse) { tools in
                let recorder = TrajectoryRecorder()
                let lessonStore = opts.noMemory ? nil : LessonStore()
                let traceRecorder = TraceRecorder(traceId: TraceID.make())
                let loop = makeLoop(registry: registry, providerId: cp.providerId, model: cp.model, context: context,
                                    tools: tools, checkpoints: checkpoints, maxIterations: opts.maxIterations,
                                    budget: opts.makeBudget(),
                                    extendedThinking: opts.extendedThinking,
                                    toolMode: toolMode, delegationDepth: opts.delegationDepth, recorder: recorder,
                                    traceRecorder: traceRecorder)
                let mem = opts.noMemory ? "" : CortexMemory().context(projectName: (root as NSString).lastPathComponent)
                let outcome = await loop.resume(from: Self.withMemoryRefresh(cp, memory: mem, enabled: !opts.noMemory))
                recordRuntimeLessons(goal: cp.title, success: outcome.success, recorder: recorder,
                                     lessonStore: lessonStore, maxIterations: opts.maxIterations,
                                     mode: .inline)
                Self.autoJournalRun(goal: cp.title, success: outcome.success, root: root, enabled: !opts.noMemory)
                printUsageDelta(from: [], to: await traceRecorder.all(), label: "usage", projectRoot: root)
                if !outcome.success { note("paused — resume with: kist --resume \(outcome.checkpointId)") }
                return outcome.success ? 0 : 1
            }
        }

        // Provider + project root are shared by the REPL and one-shot paths.
        // Session-default pick reads the per-model scorecard (best-effort root resolve; the real root guard
        // is below) so a chronically-failing provider isn't silently made the default (the MiMo trap).
        let sessionVerdicts: [String: ModelVerdict] = (opts.noMemory ? nil : ToolContext.canonicalize(opts.project))
            .map { CaptainLearningStore(projectRoot: $0).modelVerdicts() } ?? [:]
        // Selection policy: explicit flag > config > power (default). Only steers the auto-default pick.
        let selectionPolicy = opts.selectBy ?? config.selectBy ?? .power
        guard let providerId = resolveProvider(opts, registry, configProvider: config.provider,
                                               verdicts: sessionVerdicts, policy: selectionPolicy) else { return 2 }
        guard let root = ToolContext.canonicalize(opts.project) else {
            err("error: project path does not exist: \(opts.project)"); return 2
        }
        let context = ToolContext(projectRoot: root, shell: shell, sandbox: sandbox,
                                  externalReadRoots: opts.allowReadPaths)
        let chosen = registry.provider(id: providerId)

        // Full tool set (media/data/memory/vision + agent-writable Cortex). Extracted so the
        // --resume path gets the SAME tools (it previously ran with only the headless set).
        let extraTools = Self.buildExtraTools(root: root, fetchAllowedHosts: fetchAllowedHosts, opts: opts, registry: registry)

        return await withTools(projectRoot: root, fetchAllowedHosts: fetchAllowedHosts, extraTools: extraTools, enableComputerUse: opts.enableComputerUse) { tools in
            // Autonomous cross-session evolution: run ONE session IF explicitly armed (fail-closed). Its
            // objective comes from the arming file (not a goal arg), so it MUST be handled BEFORE the
            // no-goal → interactive-REPL gate below, or it would drop into the chat prompt.
            if opts.evolveSession {
                return await runEvolveSession(opts, registry: registry, root: root, tools: tools,
                                              context: context, providerId: providerId, model: model)
            }
            // No goal → interactive REPL (sensitive tools prompt for approval unless --yolo).
            guard let goal = opts.goal, !goal.isEmpty else {
                // DEFAULT = open straight to the prompt with AUTO-ROUTING on (kist picks the best model
                // per request). No forced menu. The legacy picker is still reachable with KIST_PICK_MODEL=1,
                // and any explicit --provider / config default pins a model (auto off).
                let forcePicker = ProcessInfo.processInfo.environment["KIST_PICK_MODEL"] == "1"
                let pick = (forcePicker && opts.providerId == nil && config.provider == nil) ? await pickProvider(registry) : nil
                if pick != nil { registry = makeRegistry() }   // pick up a model added during the picker
                let providerId = pick?.providerId ?? providerId
                let model = pick?.model ?? model
                let chosen = registry.provider(id: providerId)
                // Auto-route unless the user pinned a provider. CLI flag / picker always pin; a
                // config default provider pins too UNLESS config says `"autoRouting": true` — then
                // it's only the starting model and the Captain keeps choosing per turn.
                let autoRouting = AutoModelRouter.routingEnabled(
                    pickedInteractively: pick != nil, cliProvider: opts.providerId != nil,
                    configProvider: config.provider != nil, configAutoRouting: config.autoRouting)
                // Candidate models for the heuristic router: every configured/local provider's default
                // model, tagged with capabilities. Vision engine (gemini) ordered first for the vision tier.
                let preferredVision = registry.provider(id: "gemini").flatMap { registry.hasKey(for: $0) ? "gemini" : nil }
                let routeCandidates: [AutoModelRouter.Candidate] = registry.providers
                    .filter { !$0.requiresAPIKey || registry.hasKey(for: $0) }
                    .map { p in
                        let mid = p.defaultModel
                        let caps = registry.capabilities(providerId: p.id, model: mid)
                        let ctx = caps.contextWindowTokens ?? 0
                        return AutoModelRouter.Candidate(
                            binding: ProviderBinding(providerId: p.id, model: mid.isEmpty ? nil : mid),
                            vision: caps.vision, reasoning: caps.reasoning, contextTokens: ctx,
                            fast: AutoModelRouter.isFastModel(mid, contextTokens: ctx))
                    }
                    .sorted { a, _ in a.binding.providerId == preferredVision }
                let autoRouter = AutoModelRouter(candidates: routeCandidates,
                                                 fallback: ProviderBinding(providerId: providerId, model: model))
                // Autopilot must be UNMISSABLE: a bold red banner so you always know guards-off mode is armed.
                let autoTag = opts.auto ? "  \u{001B}[1;41;97m ⚠ AUTOPILOT — sandboxed, no prompts \u{001B}[0m"
                                        : (opts.yolo ? " · yolo" : "")
                if opts.auto || opts.yolo {
                    note("safety · \(autoTag.trimmingCharacters(in: .whitespaces))")
                }
                let providerAliases = providerAliases(for: registry)
                var roleSelection = KistREPL.RoleSelection(default: ProviderBinding(providerId: providerId, model: model))
                guard applyProfileAndRoleFlags(opts, to: &roleSelection, knownProviders: providerAliases) else { return 2 }
                // SELF-MONITORING + MEMORY shared by the standard REPL and opt-in TUI.
                let recorder = TrajectoryRecorder()
                let traceRecorder = TraceRecorder(traceId: TraceID.make())
                let runReplay = RunReplayStore(projectRoot: root, provider: providerId, model: model)
                let proofStore = TurnProofStore(replayStore: runReplay)
                let lessonStore = opts.noMemory ? nil : LessonStore()
                // TUI (PROTOTYPE, opt-in): raw-mode persistent-input box + single-key approvals. Only on
                // a real TTY; otherwise fall through to the standard line REPL. Chat + core commands only.
                if opts.tui, stdinIsTTY() {
                    let ui = TerminalUI()
                    let tuiSink = TUIEventSink(ui: ui, showReasoning: opts.extendedThinking)
                    let tuiLoop = makeLoop(registry: registry, providerId: providerId, model: model, context: context,
                                           tools: tools, checkpoints: checkpoints, maxIterations: opts.maxIterations,
                                    budget: opts.makeBudget(),
                                           interactor: TUIInteractor(ui: ui), approvalTools: opts.yolo ? [] : sensitiveTools,
                                           planMode: opts.planMode, extendedThinking: opts.extendedThinking, toolMode: toolMode,
                                           roles: roleSelection.bindings, delegationDepth: opts.delegationDepth,
                                           sinkOverride: tuiSink, recorder: recorder, traceRecorder: traceRecorder)
                    let memoryContext = Self.sessionMemory(root: root, opts: opts)   // cortex + project memory
                    let personaMatcher = TaskPersonaMatcher(projectRoot: root)
                    let convo = TUIConversation(
                        ui: ui, loop: tuiLoop,
                        modelLabel: (chosen?.name ?? providerId) + (model.map { " (\($0))" } ?? ""),
                        briefCompiler: { input, mode in
                            let personaContext = TaskPersonaMatcher.promptContext(
                                matches: personaMatcher.matches(for: input, limit: 3))
                            let reviewContext = ReviewContext.renderIfNeeded(request: input, projectRoot: root)
                            return PromptCompiler.compiledPrompt(input, mode: mode,
                                                                 projectContext: briefContext(memoryContext: memoryContext,
                                                                                              roles: roleSelection.bindings,
                                                                                              lessons: lessonStore?.primer(forGoal: input),
                                                                                              specialists: personaContext,
                                                                                              reviewTargets: reviewContext))
                        },
                        recorder: recorder,
                        lessonStore: lessonStore,
                        sensitiveTools: sensitiveTools,
                        editTools: editTools,
                        initialPermissionMode: opts.yolo ? .bypass : (opts.planMode ? .plan : .normal))
                    await convo.run()
                    return 0
                }
                let terminalInteractor = terminalInteractor(for: opts)
                // R2a: ONE constructor for every REPL chat sink — both the initial loop and every
                // loopFactory rebuild get the typed-input renderer + refresh hook. (Review catch:
                // only the loopFactory site had it, so typing was captured INVISIBLY on fresh and
                // pinned-model sessions — the exact missed-sibling shape.)
                func makeReplSink(showReasoning: Bool) -> TerminalEventSink {
                    // Honor NO_COLOR + the configured mono (screen-reader) theme, not just isatty, so the
                    // tool lane + streamed-prose coloring go dark exactly when the dashboard does.
                    let sink = TerminalEventSink(color: KistREPL.stdoutColorEnabled(projectRoot: root),
                                                 showReasoning: showReasoning, style: .calm, proofStore: proofStore,
                                                 typedInput: { TurnInputQueue.shared.preview() })
                    TurnInputQueue.shared.addOnChange { sink.refreshLiveStatus() }
                    return sink
                }
                // P1 / Roadmap #3 — ONE embedder-gated semantic-memory service (fail-soft; nil under
                // --no-memory or no embedder) shared by the verified-win DEPOSIT (rememberLesson, below) and
                // the P1 recall→plan READ-BACK injection. Same store the `recall` tool reads.
                let semanticMemory: SemanticMemoryService? = opts.noMemory
                    ? nil
                    : Self.makeEmbedder(registry: registry).map {
                        SemanticMemoryService(embedder: $0,
                                              store: FileBackedVectorStore(path: root + "/.kist/memory/vectors.json"))
                      }
                // P1 injection is OFF by default (zero per-turn cost, no behavior change) until `/ablation
                // recall` proves the wire compounds (advantage>0); opt in with KIST_RECALL_INJECT=1. When on,
                // each turn's system prompt gains an ADVISORY block of recalled VERIFIED lessons for the goal.
                let recallInject: (@Sendable (_ q: String) async -> String)?
                if ProcessInfo.processInfo.environment["KIST_RECALL_INJECT"] == "1", let s = semanticMemory {
                    recallInject = { q in await s.recallBlock(for: q) }
                } else {
                    recallInject = nil
                }
                // P2 task-targeted self__ surfacing — OFF by default (advertisement-only, fail-open; only
                // trims schema bloat once the self__ population is large). Opt in with KIST_SURFACE_SELFTOOLS=1.
                let surfaceSelfTools = ProcessInfo.processInfo.environment["KIST_SURFACE_SELFTOOLS"] == "1"
                var loop = makeLoop(registry: registry, providerId: providerId, model: model, context: context,
                                    tools: tools, checkpoints: checkpoints, maxIterations: opts.maxIterations,
                                    budget: opts.makeBudget(),
                                    interactor: terminalInteractor, approvalTools: opts.yolo ? [] : sensitiveTools,
                                    planMode: opts.planMode, extendedThinking: opts.extendedThinking, toolMode: toolMode,
                                    roles: roleSelection.bindings, delegationDepth: opts.delegationDepth,
                                    showReasoning: opts.extendedThinking,   // --think → watch the reasoning inline
                                    sinkOverride: makeReplSink(showReasoning: opts.extendedThinking),
                                    recorder: recorder, traceRecorder: traceRecorder)
                loop.recallLessons = recallInject   // P1: nil unless KIST_RECALL_INJECT=1 (default off)
                loop.filterSelfToolsByRelevance = surfaceSelfTools   // P2: off unless KIST_SURFACE_SELFTOOLS=1
                // CONVERSATIONAL ESCALATION: reach the fleet / plan-DAG from inside the chat, plus an
                // auto-router that PROPOSES (never silently spends) when a plain message looks like a big build.
                var repl = KistREPL(loop: loop, commands: KistCommands.load(projectRoot: root))
                repl.defaultAgents = opts.agents
                repl.autoApproveClipboardVision = opts.auto
                repl.pinnedBarEnabled = opts.pinnedBar   // R2b: bottom-glued input bar (default on for TTYs)
                repl.stickyTurnsEnabled = opts.stickyTurns   // R2b+ trial: keep the box pinned DURING turns
                // Permission bar (shift+tab): the tool classification + the tier the session launched in.
                repl.sensitiveTools = sensitiveTools
                repl.editTools = editTools
                repl.initialPermissionMode = opts.yolo ? .bypass : (opts.planMode ? .plan : .normal)
                repl.roleSelection = roleSelection
                repl.autoRouting = autoRouting
                // Captain-driven interactive routing: when auto-routing, capture a bounded project snapshot
                // + the learned-outcome context ONCE, so each escalation turn picks the best model from
                // PROJECT DATA (the same scoring the fleet uses per subtask) instead of a keyword heuristic.
                // Ordinary turns still STAY on the current model (the stability guard) — no churn, and the
                // streamed "thinking" display is preserved (the dogfooding "everything flips to gemini" guard).
                if autoRouting {
                    let snapshot = ProjectSnapshot.capture(repo: root, registry: registry)
                    // Respect --no-memory: no learned-outcome retrieval when cross-run memory is disabled
                    // (mirrors the fleet's gate). Snapshot + learning captured ONCE (not per turn).
                    let learning = opts.noMemory ? nil : CaptainLearningStore(projectRoot: root).assignmentContext()
                    repl.autoRoute = { text, _, current in
                        // No keyed providers to reason over ⇒ the standalone heuristic (one-provider setups).
                        guard !snapshot.providers.isEmpty else { return autoRouter.route(text, hasMedia: false, current: current) }
                        // Fall back to the CURRENT model (not the startup default): "stay" must mean stay on
                        // whatever we're on now, or a no-signal turn route-flips back after any switch (Codex HIGH).
                        let a = ModelAssignmentEngine.assignInteractive(turn: text, snapshot: snapshot,
                                                                        fallback: current, learning: learning)
                        return AutoModelRouter.captainDecision(a, fallback: current)
                    }
                } else {
                    repl.autoRoute = { text, hasMedia, current in autoRouter.route(text, hasMedia: hasMedia, current: current) }
                }
                repl.addModelFlow = { _ = await AddModelFlow.run() }
                repl.importModelFlow = { url in await ImportModelWizard.run(url: url) }
                // Add a key to an existing (red) provider from the picker → green + usable live.
                repl.saveProviderKey = { pid, key in
                    guard let p = registry.provider(id: pid) else { return false }
                    do { try SecretWriter.write(account: p.keyAccount, key: key); return true } catch { return false }
                }
                // /bug-bounty adversarial panel: one-shot completions on the current model (nil-safe).
                // Snapshot an immutable copy — the @Sendable closure must not capture the `var registry`.
                let bountyRegistry = registry
                repl.bountyComplete = { system, user in
                    try? await bountyRegistry.complete(
                        providerId: providerId, model: model,
                        messages: [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: user)],
                        settings: ModelSettings(temperature: 0.0, maxTokens: 300))
                }
                // /copilot co-reviewer: complete on an ARBITRARY (provider, model), not just the session model.
                repl.modelComplete = { coProvider, coModel, system, user in
                    // A second-opinion review is short prose, but 700 tokens truncated real reviews mid-word
                    // on any REASONING reviewer (hidden reasoning eats the budget; the completeWithUsage
                    // self-heal only rescues an EMPTY answer, not a partially-truncated one). 4000 gives the
                    // visible answer ample room after reasoning. (claude-cli ignores maxTokens entirely — its
                    // truncation was a separate display bug in the pinned bar's re-pin; see reReserveSequence.)
                    try? await bountyRegistry.complete(
                        providerId: coProvider, model: coModel,
                        messages: [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: user)],
                        settings: ModelSettings(temperature: 0.0, maxTokens: 4000))
                }
                // /compact: summarize older history on the ACTIVE model (the REPL passes the current binding,
                // so compaction follows /model switches). Bigger token budget for a real summary.
                repl.compactComplete = { cProvider, cModel, system, user in
                    try? await bountyRegistry.complete(
                        providerId: cProvider, model: cModel,
                        messages: [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: user)],
                        settings: ModelSettings(temperature: 0.2, maxTokens: 1200))
                }
                // Explicit hard-spawn of a named specialist. Applies FULL permissionMode fidelity (mode →
                // planMode + approval tier) — richer than the proactive spawn_specialist tool's inline plan
                // check. Returns nil when no specialist has that name (the REPL reports it).
                let specSensitive = sensitiveTools, specEdit = editTools
                repl.runSpecialist = { name, task, parentApproval, parentPlan in
                    let specialists = SpecialistRegistry(projectRoot: root).load()
                    guard let def = specialists.first(where: { $0.name == name }) else { return nil }
                    // Child permission is the parent's floor UNIONed with the file's request → the file can
                    // only ADD restrictions (approval set grows / plan can turn on), never drop the parent's.
                    // A `permissionMode: bypassPermissions` file yields child approval = [] whose union with
                    // parentApproval == parentApproval, so a guarded session stays guarded. (Codex HIGH.)
                    let mode = def.permissionMode.flatMap { PermissionMode.fromClaudeFrontmatter($0) }
                    let childApproval = mode?.approvalTools(sensitive: specSensitive, editTools: specEdit) ?? parentApproval
                    let approval = parentApproval.union(childApproval)
                    let planMode = parentPlan || (mode?.isPlan ?? false)
                    // STRONG-ON-REPAIR: a self-heal repair specialist that INHERITS the model must not
                    // inherit a weak session model (e.g. MiMo, which 400s). Bind inheriting repair agents
                    // to the strongest AVAILABLE provider (claude/codex/deepseek/gemini) so a failed turn
                    // is retried by a heavy hitter. Specialists with an explicit model (critic=deepseek)
                    // resolve that first and are unaffected.
                    var repairRoleDefault = ProviderBinding(providerId: providerId, model: model)
                    if def.source == "captain-self-heal" {
                        // Only escalate to a provider we can actually reach: keyed CLOUD providers plus the
                        // keyless SUBSCRIPTION heavy hitters (claude-cli/codex-cli). Keyless LOCAL providers
                        // (mlx/ollama) are excluded — they outrank mimo but may point at a dead endpoint, so
                        // escalating to them would route a repair to a server that isn't running (Codex P2).
                        let subscriptionHitters: Set<String> = ["claude-cli", "codex-cli"]
                        let available = registry.providers
                            .filter { ($0.requiresAPIKey && registry.hasKey(for: $0)) || subscriptionHitters.contains($0.id) }
                            .map { $0.id }
                        let shVerdicts: [String: ModelVerdict] = opts.noMemory
                            ? [:] : CaptainLearningStore(projectRoot: root).modelVerdicts()
                        let strong = ModelEscalator.pick(tier: .frontier, keyed: available, preferred: providerId,
                                                         verdicts: shVerdicts)
                        if strong != providerId { repairRoleDefault = ProviderBinding(providerId: strong) }
                    }
                    let spawner = SpecialistSpawner(
                        providers: registry, baseTools: tools, context: context,
                        sink: TerminalEventSink(showReasoning: false), interactor: terminalInteractor,
                        aliasTable: [:], roleDefault: repairRoleDefault,
                        defaultMaxIterations: opts.maxIterations, extendedThinking: opts.extendedThinking)
                    return await spawner.run(specialist: def, task: task, approvalTools: approval, planMode: planMode).summary
                }
                // R2a: the drain chain — approval-deferred prompts first, then messages the user
                // TYPED while a turn was running (TurnInputQueue). Each drained line goes through
                // the REPL's full input path (slash commands, intents, routing) as if typed fresh.
                repl.deferredInput = {
                    if let d = await terminalInteractor.takeDeferredInput() { return d }
                    return TurnInputQueue.shared.popQueued()
                }
                repl.setAutopilot = { on in await terminalInteractor.setAutopilot(on) }
                repl.saveTranscript = { transcript, path in
                    try ConversationExporter.writeMarkdown(transcript: transcript, path: path, projectRoot: root)
                }
                let memoryContext = opts.noMemory ? nil : ProjectMemory(root: root).planningContext()
                let personaMatcher = TaskPersonaMatcher(projectRoot: root)
                repl.personaDisplay = { input in
                    TaskPersonaMatcher.display(matches: personaMatcher.matches(for: input, limit: 3))
                }
                // The Cortex: human-readable .md memory of Luke (preferences/projects/journal). Seeded on
                // first run; folded into ProjectMemory so kist knows him; viewable via /cortex.
                let cortex = opts.noMemory ? nil : CortexMemory()
                try? cortex?.seedIfNeeded()
                repl.cortex = cortex
                let projectName = (root as NSString).lastPathComponent
                repl.briefCompiler = { input, roles, mode, transcript, intent in
                    let personaContext = TaskPersonaMatcher.promptContext(
                        matches: personaMatcher.matches(for: input, limit: 3))
                    let reviewContext = ReviewContext.renderIfNeeded(request: input, projectRoot: root)
                    // Cortex (who Luke is) + ProjectMemory (this repo) folded into one memory block.
                    let combinedMemory = [cortex?.context(projectName: projectName), memoryContext]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                    return PromptCompiler.compiledPrompt(input, mode: mode,
                                                         conversationContext: PromptCompiler.conversationContext(from: transcript),
                                                         projectContext: briefContext(memoryContext: combinedMemory.isEmpty ? nil : combinedMemory,
                                                                                      roles: roles,
                                                                                      lessons: lessonStore?.primer(forGoal: input),
                                                                                      specialists: personaContext,
                                                                                      reviewTargets: reviewContext),
                                                         resolvedIntent: intent)
                }
                // Rebuilt on /model (new default provider+model) and /roles (new team). The default
                // binding drives the conversational turn AND the spawn-tool default; roles drive the team.
                repl.loopFactory = { defaultBinding, roles, planMode, showReasoning, extendedThinking in
                    // R2a: same shared constructor as the initial loop (typed-input render + hook).
                    var l = makeLoop(registry: registry, providerId: defaultBinding.providerId, model: defaultBinding.model,
                             context: context,
                             tools: tools, checkpoints: checkpoints, maxIterations: opts.maxIterations,
                                    budget: opts.makeBudget(),
                             interactor: terminalInteractor, approvalTools: opts.yolo ? [] : sensitiveTools,
                             planMode: planMode, extendedThinking: extendedThinking, toolMode: toolMode, roles: roles,
                             delegationDepth: opts.delegationDepth, showReasoning: showReasoning,
                             sinkOverride: makeReplSink(showReasoning: showReasoning),
                             recorder: recorder,
                             traceRecorder: traceRecorder)
                    l.recallLessons = recallInject   // P1: carry the (flag-gated) read-back across /model & /roles rebuilds
                    l.filterSelfToolsByRelevance = surfaceSelfTools   // P2: carry the (flag-gated) surfacing filter too
                    return l
                }
                repl.recorder = recorder
                repl.traceRecorder = traceRecorder
                repl.proofStore = proofStore
                repl.replayRenderer = { id in RunReplayStore.render(projectRoot: root, id: id) }
                repl.replayRunID = runReplay.manifest.runID
                repl.lessonStore = lessonStore
                repl.providerHealth = { probe in
                    let report: ProviderHealthReport
                    if probe {
                        let bindings = registry.providers.map { ProviderBinding(providerId: $0.id, model: $0.defaultModel) }
                        report = await ProviderHealthChecker.liveProbe(registry, bindings: bindings)
                    } else {
                        report = ProviderHealthChecker.catalogReport(registry)
                    }
                    return report.render()
                }
                repl.providerDoctor = { await providerDoctorReport(registry) }
                repl.protocolStatus = { protocolStatusText(projectRoot: root) }
                repl.runBench = { g in
                    _ = await runBench(opts, goal: g, registry: registry, root: root, tools: tools, context: context)
                }
                repl.runEval = { g in
                    _ = await runEval(opts, goal: g, registry: registry, root: root, tools: tools,
                                      context: context, providerId: providerId, model: model)
                }
                repl.runEvalSuite = {
                    _ = await runEvalSuite(opts, registry: registry, root: root, tools: tools,
                                           context: context, providerId: providerId, model: model)
                }
                // Roadmap #3 — auto-capture verified wins into SEMANTIC (vector) memory so a future session
                // can recall them. Same store the `recall` tool reads (`.kist/memory/vectors.json`), so what
                // gets auto-saved is auto-findable. Gated on an embedder (local Ollama / Gemini); fail-soft.
                if let semanticMemory {   // reuse the ONE hoisted service (deposit side of the same store)
                    repl.rememberLesson = { text in try? await semanticMemory.remember(text, metadata: ["kind": "auto-lesson"]) }
                }
                repl.providerAliases = providerAliases
                repl.providerLabels = registry.providers
                    .map { "\($0.id)\(registry.hasKey(for: $0) ? "" : " (missing key)")" }
                    .sorted()
                repl.providerModels = Dictionary(
                    registry.providers.map { ($0.id.lowercased(), $0.availableModels.map(\.id)) },
                    uniquingKeysWith: { first, _ in first })
                // Green/red in the `/model` picker: does this provider have a usable API key right now?
                repl.providerHasKey = { pid in
                    registry.provider(id: pid).map { registry.hasKey(for: $0) } ?? false
                }
                // MULTIMODAL routing: which (provider, model) can see, and which keyed provider to
                // borrow for media turns when the active one can't. Prefer Gemini (video/audio engine).
                repl.projectRoot = root
                repl.providerSupportsVision = { binding in
                    registry.capabilities(providerId: binding.providerId, model: binding.model).vision
                }
                repl.visionProviderId = {
                    if let g = registry.provider(id: "gemini"), registry.hasKey(for: g),
                       g.availableModels.contains(where: { $0.isVision }) { return "gemini" }
                    return registry.providers.first {
                        registry.hasKey(for: $0) && $0.availableModels.contains { $0.isVision }
                    }?.id
                }()
                // Files-API uploader for big/long media (video, >20MB), only when a Gemini key exists.
                if let geminiKey = registry.apiKey(forProviderId: "gemini") {
                    let filesClient = GeminiFilesClient(apiKey: geminiKey)
                    repl.uploadMedia = { uploads in
                        var out: [MediaAttachment] = []
                        for u in uploads {
                            guard let data = MediaResolver.defaultRead(u.path) else {
                                note("upload · couldn't read \(u.displayName)")
                                continue
                            }
                            do {
                                let uri = try await filesClient.upload(data: data, mimeType: u.mimeType, displayName: u.displayName)
                                out.append(MediaAttachment(kind: u.kind, mimeType: u.mimeType,
                                                           payload: .fileURI(uri), sourcePath: u.path))
                                note("upload · \(u.displayName) → ready")
                            } catch {
                                note("upload · \(u.displayName) failed: \(error)")
                            }
                        }
                        return out
                    }
                }
                repl.roleProfiles = RoleProfileStore()
                repl.fleet = { g, n, roles in
                    var o = opts; o.goal = g; o.agents = n; o.fleet = true
                    // Fleet is a long-running sibling of plan/council/research and must share their
                    // exact ESC + type-ahead contract. It was the last heavy route that bypassed the
                    // watcher, leaving the terminal apparently unresponsive during a fleet run.
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    let interrupted = MutableBox<InterruptibleTurn.InterruptReason?>(nil)
                    let exitCode = await InterruptibleTurn.run(onInterrupt: { reason in
                        interrupted.value = reason
                        if reason == .cancel { TurnInputQueue.shared.clearAll() }
                        else { TurnInputQueue.shared.commitPending() }
                        print("\n\u{001B}[33m" + (reason == .cancel ? "⎋⎋ cancelled" : "⎋ interrupted")
                              + " — fleet run stopped\u{001B}[0m")
                    }) {
                        await runFleet(o, registry: registry, root: root, tools: tools,
                                       providerId: providerId, model: model, rolesOverride: roles)
                    }
                    let verification: HeavyRouteResult.Verification
                    if interrupted.value != nil {
                        verification = .unavailable("fleet verification did not finish after interruption")
                    } else if exitCode == 0 {
                        verification = .passed("Foreman signoff completed and signed branches joined the isolated integration branch")
                    } else if exitCode == 1 {
                        verification = .failed("the fleet did not reach its required signoff and integration gate")
                    } else {
                        verification = .unavailable("the fleet was rejected before its verification stage ran")
                    }
                    return HeavyRouteResult(exitCode: exitCode, interruption: interrupted.value,
                                            review: .handledInternally("FleetSupervisor and Foreman own review/signoff"),
                                            verification: verification)
                }
                // CAPTAIN MODEL SELECTION (scoped to /fix): pick the STRONGEST reachable model, never a
                // known-weak/dead one. Same rule as strong-on-repair (self-heal) so it can't diverge:
                // keyed cloud providers + the keyless subscription heavy-hitters, ranked at the frontier
                // tier (which floors out MiMo). Returns nil when the session is already on the strongest —
                // no needless override, and no global routing change (only /fix consults this).
                let strongRegistry = registry
                let scorecardRoot = root
                let scorecardOn = !opts.noMemory
                repl.captainStrongRoles = {
                    // Read the persisted per-model scorecard so the pick avoids models that fail/loop across
                    // runs ("don't burn shit") and prefers proven ones. Empty when memory is off / no data yet.
                    let verdicts: [String: ModelVerdict] = scorecardOn
                        ? CaptainLearningStore(projectRoot: scorecardRoot).modelVerdicts() : [:]
                    let subscriptionHitters: Set<String> = ["claude-cli", "codex-cli"]
                    let available = strongRegistry.providers
                        .filter { ($0.requiresAPIKey && strongRegistry.hasKey(for: $0)) || subscriptionHitters.contains($0.id) }
                        .map { $0.id }
                    let strong = ModelEscalator.pick(tier: .frontier, keyed: available, preferred: providerId,
                                                     verdicts: verdicts)
                    guard strong != providerId else { return nil }
                    return RoleBindings(default: ProviderBinding(providerId: strong))
                }
                repl.planExecute = { g, roles in
                    var o = opts; o.goal = g; o.planExecute = true
                    // R1: ESC works on the plan-execute plane too — previously this plane was a
                    // dead zone (no watcher, no cancellation checks), exactly where big requests
                    // auto-escalate. The watcher cancels the runner task; PlanExecuteLoop and
                    // PlanExecutor stop cooperatively at phase/wave boundaries. Sequential with
                    // the chat turn's watcher (single-watcher invariant preserved).
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    let interrupted = MutableBox<InterruptibleTurn.InterruptReason?>(nil)
                    let exitCode = await InterruptibleTurn.run(onInterrupt: { reason in
                        interrupted.value = reason
                        if reason == .cancel { TurnInputQueue.shared.clearAll() }
                        else { TurnInputQueue.shared.commitPending() }
                        print("\n\u{001B}[33m" + (reason == .cancel ? "⎋⎋ cancelled" : "⎋ interrupted")
                              + " — plan run stopped\u{001B}[0m")
                    }) {
                        await runPlanExecute(o, goal: g, registry: registry, root: root, tools: tools,
                                             context: context, providerId: providerId, model: model,
                                             rolesOverride: roles)
                    }
                    let verification: HeavyRouteResult.Verification
                    if interrupted.value != nil {
                        verification = .unavailable("plan verification did not finish after interruption")
                    } else if exitCode == 0 {
                        verification = .passed("the plan executor's deterministic mutation gate and critic verification completed")
                    } else if exitCode == 1 {
                        verification = .failed("the plan executor did not pass its required critic verification")
                    } else {
                        verification = .unavailable("plan execution was rejected before its verifier ran")
                    }
                    return HeavyRouteResult(exitCode: exitCode, interruption: interrupted.value,
                                            review: .handledInternally("plan→execute owns its planner/coder/critic loop"),
                                            verification: verification)
                }
                repl.council = { g, roles, execute in
                    // R1 sibling: council (and its execute=true hand-off into runPlanExecute) gets
                    // the same ESC watcher — top-level + sequential, single-watcher invariant holds.
                    // Coverage is partial (council's own model calls stop via provider cancellation);
                    // honest partial beats a dead zone.
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    let interrupted = MutableBox<InterruptibleTurn.InterruptReason?>(nil)
                    let exitCode = await InterruptibleTurn.run(onInterrupt: { reason in
                        interrupted.value = reason
                        if reason == .cancel { TurnInputQueue.shared.clearAll() }
                        else { TurnInputQueue.shared.commitPending() }
                        print("\n\u{001B}[33m" + (reason == .cancel ? "⎋⎋ cancelled" : "⎋ interrupted")
                              + " — council run stopped\u{001B}[0m")
                    }) {
                        await runCouncil(opts, goal: g, execute: execute, registry: registry,
                                         root: root, tools: tools, context: context,
                                         providerId: providerId, model: model, rolesOverride: roles)
                    }
                    let verification: HeavyRouteResult.Verification
                    if interrupted.value != nil {
                        verification = .unavailable("council execution stopped before verification")
                    } else if execute, exitCode == 0 {
                        verification = .passed("the council's builder handoff completed plan→execute verification")
                    } else if execute, exitCode == 1 {
                        verification = .failed("the council's builder handoff did not pass plan→execute verification")
                    } else {
                        verification = .unavailable(execute
                            ? "the council was rejected before builder verification ran"
                            : "an advisory council has no deterministic execution oracle")
                    }
                    return HeavyRouteResult(exitCode: exitCode, interruption: interrupted.value,
                                            review: .handledInternally("the role-bound council synthesizes its own critique"),
                                            verification: verification)
                }
                repl.digDeep = { g, roles in
                    // "Dig in deep" / "consult the minds": same ESC watcher as council — top-level, sequential.
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    let interrupted = MutableBox<InterruptibleTurn.InterruptReason?>(nil)
                    let exitCode = await InterruptibleTurn.run(onInterrupt: { reason in
                        interrupted.value = reason
                        if reason == .cancel { TurnInputQueue.shared.clearAll() }
                        else { TurnInputQueue.shared.commitPending() }
                        print("\n\u{001B}[33m" + (reason == .cancel ? "⎋⎋ cancelled" : "⎋ interrupted")
                              + " — dig-in-deep stopped\u{001B}[0m")
                    }) {
                        await runWideCouncil(opts, goal: g, registry: registry, root: root,
                                             providerId: providerId, model: model, rolesOverride: roles)
                    }
                    return HeavyRouteResult(
                        exitCode: exitCode, interruption: interrupted.value,
                        review: .handledInternally("the heterogeneous wide council synthesizes its panel"),
                        verification: .unavailable(interrupted.value == nil
                            ? "advisory consensus has no deterministic execution oracle"
                            : "the wide council was interrupted before completion"))
                }
                repl.research = { g, roles in
                    // R1 sibling: same watcher for the research pipeline.
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    let interrupted = MutableBox<InterruptibleTurn.InterruptReason?>(nil)
                    let exitCode = await InterruptibleTurn.run(onInterrupt: { reason in
                        interrupted.value = reason
                        if reason == .cancel { TurnInputQueue.shared.clearAll() }
                        else { TurnInputQueue.shared.commitPending() }
                        print("\n\u{001B}[33m" + (reason == .cancel ? "⎋⎋ cancelled" : "⎋ interrupted")
                              + " — research run stopped\u{001B}[0m")
                    }) {
                        await runResearch(opts, goal: g, registry: registry, root: root,
                                          tools: tools, context: context,
                                          providerId: providerId, model: model,
                                          rolesOverride: roles)
                    }
                    let verification: HeavyRouteResult.Verification
                    if interrupted.value != nil {
                        verification = .unavailable("research stopped before any execution verification completed")
                    } else if opts.councilExecute, exitCode == 0 {
                        verification = .passed("research handed off through council to verified plan execution")
                    } else if opts.councilExecute, exitCode == 1 {
                        verification = .failed("research's plan-execute handoff did not pass verification")
                    } else {
                        verification = .unavailable(opts.councilExecute
                            ? "research was rejected before builder verification ran"
                            : "evidence synthesis and board seeding have no deterministic execution oracle")
                    }
                    return HeavyRouteResult(exitCode: exitCode, interruption: interrupted.value,
                                            review: .handledInternally("research feeds its evidence dossier through the role-bound council"),
                                            verification: verification)
                }
                repl.dive = { g, roles in
                    // Same ESC/typeahead watcher as research — top-level, sequential. Dive is LOCAL-ONLY:
                    // no web, no cross-repo estate sweep. It reads our code and consults the panel.
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    let interrupted = MutableBox<InterruptibleTurn.InterruptReason?>(nil)
                    let exitCode = await InterruptibleTurn.run(onInterrupt: { reason in
                        interrupted.value = reason
                        if reason == .cancel { TurnInputQueue.shared.clearAll() }
                        else { TurnInputQueue.shared.commitPending() }
                        print("\n\u{001B}[33m" + (reason == .cancel ? "⎋⎋ cancelled" : "⎋ interrupted")
                              + " — codebase dive stopped\u{001B}[0m")
                    }) {
                        await runDive(opts, goal: g, registry: registry, root: root,
                                      tools: tools, context: context,
                                      providerId: providerId, model: model, rolesOverride: roles)
                    }
                    return HeavyRouteResult(
                        exitCode: exitCode, interruption: interrupted.value,
                        review: .handledInternally("the wide panel reads the same grounded code dossier"),
                        verification: .unavailable(interrupted.value == nil
                            ? "a grounded code read has no deterministic execution oracle"
                            : "the dive was interrupted before completion"))
                }
                repl.evolve = { brief in
                    // On-demand, transparent self-evolution proof. Manual only — the autonomous caller
                    // (standing autonomy) is separate and flag-gated OFF.
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    return await runEvolve(opts, brief: brief, registry: registry, root: root,
                                           tools: tools, context: context,   // P3: held-out regression guard
                                           providerId: providerId, model: model,
                                           semantic: semanticMemory)   // P2: grounded auto-lesson deposit on promote
                }
                repl.ablation = { corpus in
                    // Run the ablation oracle (real turns × 2 arms). `recall` → P1's ISOLATED injection A/B
                    // (toolset held constant); otherwise the COLD-vs-WARM program metric on the named corpus.
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    if corpus.lowercased().hasPrefix("recall") {
                        return await runRecallAblation(opts, registry: registry, root: root, tools: tools,
                                                       context: context, providerId: providerId, model: model)
                    }
                    return await runAblation(opts, registry: registry, root: root, tools: tools,
                                             context: context, providerId: providerId, model: model, corpus: corpus)
                }
                repl.forge = { description, roles in
                    // AgentForge: generate a specialist bounded by the loop's tool ceiling, validate, save.
                    let forge = AgentForge(providers: registry, roles: roles)
                    note("forging a specialist from: \(description)")
                    switch await forge.forge(roleDescription: description, ceiling: tools.names) {
                    case .success(let def):
                        do {
                            let path = try SpecialistRegistry(projectRoot: root).save(def)
                            let toolList = def.toolAllowlist.map { $0.joined(separator: ", ") } ?? "inherit all"
                            print("\u{001B}[32mforged\u{001B}[0m \u{001B}[1m\(def.name)\u{001B}[0m — \(def.description)\n  tools: \(toolList)\n  saved: \(path)\n  use: /agents show \(def.name)")
                        } catch {
                            print("\u{001B}[31mforge saved failed:\u{001B}[0m \(error)")
                        }
                    case .failure(let e):
                        print("\u{001B}[31mforge failed:\u{001B}[0m \(e)")
                    }
                }
                let plannerBinding = roleSelection.bindings.binding(for: .planner)
                if registry.provider(id: plannerBinding.providerId) != nil {
                    repl.router = ConversationRouter(providers: registry, binding: plannerBinding, defaultFleetAgents: min(3, opts.agents))
                }
                repl.routerFactory = { binding in
                    guard registry.provider(id: binding.providerId) != nil else { return nil }
                    return ConversationRouter(providers: registry, binding: binding, defaultFleetAgents: min(3, opts.agents))
                }
                await repl.run()
                return 0
            }
            if opts.bench {
                return await runBench(opts, goal: opts.goal ?? "", registry: registry, root: root,
                                      tools: tools, context: context)
            }
            if opts.eval {
                return await runEval(opts, goal: opts.goal ?? "", registry: registry, root: root,
                                     tools: tools, context: context, providerId: providerId, model: model)
            }
            if opts.research {
                return await runResearch(opts, goal: goal, registry: registry, root: root,
                                         tools: tools, context: context,
                                         providerId: providerId, model: model)
            }
            // Council: deep research -> model conference -> decision -> visible kanban board.
            if opts.digDeep {
                return await runWideCouncil(opts, goal: goal, registry: registry, root: root,
                                            providerId: providerId, model: model)
            }
            if opts.council {
                return await runCouncil(opts, goal: goal, execute: opts.councilExecute,
                                        registry: registry, root: root, tools: tools,
                                        context: context, providerId: providerId, model: model)
            }
            // Fleet: split the goal into disjoint subtasks, run a supervised heterogeneous fleet.
            if opts.fleet {
                return await runFleet(opts, registry: registry, root: root, tools: tools,
                                      providerId: providerId, model: model)
            }
            // Evolution lab: improve Mythos itself through isolated, benchmarked candidate branches.
            if opts.evolve {
                return await runEvolution(opts, registry: registry, root: root, tools: tools,
                                          context: context, providerId: providerId, model: model)
            }
            // Plan→execute: planner emits a typed DAG, approve (unless --yolo), then build it.
            if opts.planExecute {
                return await runPlanExecute(opts, goal: goal, registry: registry, root: root, tools: tools,
                                            context: context, providerId: providerId, model: model)
            }
            // Great-loop: the long-horizon runner — self-assess effort per cycle, learn from history, and
            // keep working across cycles until done-and-verified or a SAFETY CAP stops it.
            if opts.greatLoop {
                guard let roles = resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }
                return await runGreatLoop(opts, goal: goal, registry: registry, root: root, tools: tools,
                                          context: context, checkpoints: checkpoints, toolMode: toolMode,
                                          roles: roles, providerId: providerId, model: model)
            }
            // One-shot (non-interactive; safe by default: shell denied + project confinement).
            guard let roles = resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }
            note("kist · \(chosen?.name ?? providerId)\(model.map { " (\($0))" } ?? "") · \(root)\(opts.planMode ? " · plan" : "")\(roles.isHeterogeneous ? " · team" : "")")
            let recorder = TrajectoryRecorder()
            let traceRecorder = TraceRecorder(traceId: TraceID.make())
            let runReplay = RunReplayStore(projectRoot: root, provider: providerId, model: model)
            let proofStore = TurnProofStore(replayStore: runReplay)
            let lessonStore = opts.noMemory ? nil : LessonStore()
            proofStore.startTurn(goal: goal)
            let loop = makeLoop(registry: registry, providerId: providerId, model: model, context: context,
                                tools: tools, checkpoints: checkpoints, maxIterations: opts.maxIterations,
                                budget: opts.makeBudget(),
                                planMode: opts.planMode, extendedThinking: opts.extendedThinking, toolMode: toolMode, roles: roles,
                                delegationDepth: opts.delegationDepth,
                                showReasoning: opts.extendedThinking,   // --think → watch the reasoning inline
                                sinkOverride: TerminalEventSink(showReasoning: opts.extendedThinking, style: .calm, proofStore: proofStore),
                                recorder: recorder,
                                traceRecorder: traceRecorder)
            let memoryContext = Self.sessionMemory(root: root, opts: opts)   // cortex + project memory
            // --fast strips the advisory brief (persona/lessons/review) — keep just memory + the goal,
            // the biggest per-call token lever when you just want a quick dev turn.
            let personaContext = opts.fast ? nil : TaskPersonaMatcher.promptContext(
                matches: TaskPersonaMatcher(projectRoot: root).matches(for: goal, limit: 3))
            let reviewContext = opts.fast ? nil : ReviewContext.renderIfNeeded(request: goal, projectRoot: root)
            let compiledGoal = PromptCompiler.compiledPrompt(goal, mode: opts.planMode ? .plan : .inline,
                                                             projectContext: briefContext(memoryContext: memoryContext, roles: roles,
                                                                                          lessons: opts.fast ? nil : lessonStore?.primer(forGoal: goal),
                                                                                          specialists: personaContext,
                                                                                          reviewTargets: reviewContext))
            let outcome = await loop.run(goal: compiledGoal)
            // --ship: the build ran hands-free in the autopilot sandbox above; now the council of minds
            // reviews the ACTUAL result (diff) and returns GO/NO-GO. Deploy stays a deliberate, confirmed step.
            if opts.ship { await runShipReview(goal: goal, registry: registry, roles: roles, root: root) }
            // Self-monitor: surface reliability issues and learn obstacles (advisory, retrieval-only).
            recordRuntimeLessons(goal: goal, success: outcome.success, recorder: recorder,
                                 lessonStore: lessonStore, maxIterations: opts.maxIterations,
                                 mode: opts.planMode ? .plan : .inline)
            Self.autoJournalRun(goal: goal, success: outcome.success, root: root, enabled: !opts.noMemory)
            print(KistREPL.renderSimpleSummary(projectRoot: root, spans: await traceRecorder.all(), trajectory: recorder.snapshot()))
            let grounding = GroundedReviewValidator.audit(outcome.summary, projectRoot: root)
            if !grounding.isGrounded { print(grounding.render(color: TerminalCapabilities.stdoutIsInteractive)) }
            printUsageDelta(from: [], to: await traceRecorder.all(), label: "usage", projectRoot: root)
            note("replay · kist --replay \(runReplay.manifest.runID)")
            if !outcome.success { note("paused — resume with: kist --resume \(outcome.checkpointId)") }
            return outcome.success ? 0 : 1
        }
    }

    /// Real-TTY diagnostic for Terminal.app. It exercises the production descriptor capture and
    /// panel renderer for ~9 seconds, including fragmented/wrapped stdout, stderr, CR repaint,
    /// type-ahead/queue redraw, and clean DECSTBM teardown.
    static func runStickyBarSelfTest() async -> Int32 {
        guard stdinIsTTY(), isatty(fileno(stdout)) != 0 else {
            err("sticky-bar self-test requires an interactive TTY")
            return 2
        }

        print("sticky-bar diagnostic · 9s · the box must stay fixed while output streams above it")
        // Establish raw stdin ownership before the first DECSTBM activation. Otherwise a key
        // arriving between screen activation/capture and enableForWatch() is kernel-echoed
        // outside the serialized output owner.
        let raw = RawMode()
        raw.enableForWatch()
        guard raw.isActive else {
            err("sticky-bar diagnostic could not enter bounded raw-input mode")
            return 1
        }
        let bar = PinnedBar(enabled: true)
        bar.activate()
        guard bar.active else {
            raw.disable()
            err("sticky-bar diagnostic could not activate the safe coordinator")
            return 1
        }
        let panel = TerminalScreenCoordinator.Panel(
            status: "diagnostic · serialized stdout+stderr · resize the window now",
            pending: "",
            queuedCount: 0,
            hint: "offline self-test · fixed box · no model / MCP / network")
        guard bar.beginStickyTurn(panel: panel) else {
            // Release every screen artifact while stdin is still raw, then restore echo.
            bar.suspend()
            bar.deactivate()
            raw.disable()
            err("sticky-bar diagnostic could not capture process output")
            return 1
        }
        // Exercise the same raw-input state as a real submitted-message session. The tiny watcher
        // converts terminal Ctrl-C/Ctrl-\ bytes back into the corresponding process signal, so the
        // visible diagnostic remains interruptible while the PTY test can prove exact restoration.
        let interruptWatcher = Task.detached {
            while !Task.isCancelled {
                guard let byte = raw.readByteTimed() else { continue }
                if byte == 0x03 {
                    _ = kill(getpid(), SIGINT)
                } else if byte == 0x1C {
                    _ = kill(getpid(), SIGQUIT)
                }
            }
        }
        FileHandle.standardOutput.write(Data("sticky-bar diagnostic ready\n".utf8))

        let pending = ["", "t", "ty", "typ", "type", "typea", "typeahead", "typeahead 中", "typeahead 中🙂"]
        let diagnosticTicks = min(36, max(1,
            Int(ProcessInfo.processInfo.environment["KIST_STICKY_SELF_TEST_TICKS"] ?? "") ?? 36))
        for tick in 0..<diagnosticTicks {
            let word = "fragment-\(tick)"
            let split = max(1, word.utf8.count / 2)
            let bytes = Array(word.utf8)
            FileHandle.standardOutput.write(Data(bytes[..<split]))
            FileHandle.standardOutput.write(Data(bytes[split...]))
            FileHandle.standardOutput.write(Data(" · ordered stdout\n".utf8))
            if tick == 5 {
                FileHandle.standardError.write(Data("[diagnostic stderr] one ordered warning line\n".utf8))
            }
            if tick % 6 == 0 {
                let wrapped = String(repeating: "wrapped-output-🙂-中-", count: 12)
                FileHandle.standardOutput.write(Data((wrapped + "\n").utf8))
            }
            FileHandle.standardOutput.write(
                Data(("\r\u{001B}[K◇ spinner repaint \(tick + 1)/\(diagnosticTicks)").utf8))
            let typed = pending[min(pending.count - 1, tick / 4)]
            bar.updateStickyTypeahead(pending: typed, queuedCount: tick >= 24 ? 2 : (tick >= 16 ? 1 : 0))
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        FileHandle.standardOutput.write(Data("\r\u{001B}[K✓ stream complete\n".utf8))
        // Release capture and DECSTBM while the watcher still owns raw stdin. Continuous
        // typeahead must never become kernel echo until the fixed panel is gone.
        bar.suspend()
        interruptWatcher.cancel()
        _ = await interruptWatcher.value
        raw.disable()
        if let delay = Int(ProcessInfo.processInfo.environment[
            "KIST_STICKY_SELF_TEST_HANDOFF_DELAY_MS"] ?? ""), delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 500)) * 1_000_000)
        }
        bar.endStickyTurn()
        bar.deactivate()
        print("sticky-bar diagnostic complete · if the box stayed fixed and the shell is normal, PASS")
        return 0
    }

    // MARK: - Council (agent conference -> kanban -> optional builder handoff)

    private static func runResearch(_ opts: KistOptions, goal: String,
                                    registry: ProviderRegistry, root: String,
                                    tools: ToolRegistry, context: ToolContext,
                                    providerId: String, model: String?,
                                    rolesOverride: RoleBindings? = nil) async -> Int32 {
        note("kist · research · \(root)")
        // LIVE PROGRESS (Luke 2026-08-02): research used to go dead-silent between blocking tool calls
        // (only terse note() lines), unlike the build path's live "thinking" display. Show a Codex-style
        // checklist instead — each step announces what it's doing NOW, then lights up green (✓) when done
        // or red (✗) if it failed — so the user can see it working rather than staring at a frozen screen.
        let colored = KistREPL.stdoutColorEnabled(projectRoot: root)
        func dim(_ s: String) -> String { colored ? "\u{001B}[2m\(s)\u{001B}[0m" : s }
        func researchStep(_ emoji: String, _ label: String,
                          _ run: () async -> ToolResult) async -> ToolResult {
            note(dim("│ \(emoji) \(label) · working…"))
            let r = await run()
            if r.success {
                note(colored ? "\u{001B}[32m│ ✓ \(label)\u{001B}[0m" : "│ ✓ \(label)")
            } else {
                let why = r.error ?? r.output
                note(colored ? "\u{001B}[31m│ ✗ \(label) · \(why)\u{001B}[0m" : "│ ✗ \(label) · \(why)")
            }
            return r
        }
        note(dim("▤ research · web search → repo context → estate sweep → synthesize"))

        let start = await researchStep("🔎", "start research run") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "start", "goal": goal], context: context)
        }
        guard start.success, let runID = start.metadata["run_id"] else {
            err("research · failed to start: \(start.error ?? start.output)")
            return 1
        }
        note(dim("│   run \(runID)"))

        _ = await researchStep("🌐", "web search") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "search", "run_id": runID,
                                            "query": goal, "limit": 5], context: context)
        }

        _ = await researchStep("📂", "repo context") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "context", "run_id": runID,
                                            "query": goal, "limit": 8], context: context)
        }

        // DEEP ESTATE SWEEP (Luke 2026-07-31): on TOP of the web + current-repo evidence, sweep our OWN
        // system files across ~ and /Volumes IN-PROCESS (bypasses the tool sandbox → reaches our real source
        // at /Volumes/PRO-G40/kist-loops and the rest of the estate). Record the sweep in the SAME durable
        // evidence ledger before synthesis; otherwise a zero-source dossier could be laundered into a
        // successful council artifact, and estate provenance would exist only in transient prompt text.
        let estate = await researchStep("🧠", "estate sweep (our own files)") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "estate", "run_id": runID,
                                            "query": goal], context: context)
        }
        if estate.success {
            note(dim("│   \(estate.metadata["files"] ?? "0") system file(s) recorded"))
        }

        let synth = await researchStep("📝", "synthesize dossier") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "synthesize", "run_id": runID], context: context)
        }
        guard synth.success else {
            err("research · incomplete: \(synth.error ?? synth.output)")
            return 1
        }
        if let report = synth.metadata["report"] { note(dim("│   dossier saved · \(report)")) }
        let dossier = synth.output

        return await runCouncil(opts, goal: goal, execute: opts.councilExecute,
                                registry: registry, root: root, tools: tools, context: context,
                                providerId: providerId, model: model, rolesOverride: rolesOverride,
                                researchDossier: dossier, researchRunID: runID)
    }

    /// `/dive` — a MULTI-AGENT deep-dive of OUR OWN CURRENT repo. `/research` is the wrong tool for "what
    /// does OUR code do": it hits the web and sweeps the whole estate across ~ and /Volumes, which is how
    /// "why does our build queue never change" wandered into an unrelated repo. Dive stays LOCAL and
    /// REPO-SCOPED: it reads the actual files under `root`, grounds a dossier in them, then hands that real
    /// code to every reachable model (wide council) for a synthesized, file-cited truth. No web search, no
    /// cross-repo estate sweep — the answer is grounded in the code we actually shipped.
    private static func runDive(_ opts: KistOptions, goal: String,
                                registry: ProviderRegistry, root: String,
                                tools: ToolRegistry, context: ToolContext,
                                providerId: String, model: String?,
                                rolesOverride: RoleBindings? = nil) async -> Int32 {
        let colored = KistREPL.stdoutColorEnabled(projectRoot: root)
        func dim(_ s: String) -> String { colored ? "\u{001B}[2m\(s)\u{001B}[0m" : s }
        func paint(_ code: String, _ s: String) -> String { colored ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
        func diveStep(_ emoji: String, _ label: String, _ run: () async -> ToolResult) async -> ToolResult {
            note(dim("│ \(emoji) \(label) · working…"))
            let r = await run()
            note(r.success ? paint("32", "│ ✓ \(label)") : paint("31", "│ ✗ \(label) · \(r.error ?? r.output)"))
            return r
        }

        note("kist · dive · reading OUR code · \(root)")
        // Launched from HOME (not a repo) → there is no single codebase to read, so the grounded answer will
        // be thin. Say so plainly; the honest fix is to run /dive from inside the target repo.
        if root == FileManager.default.homeDirectoryForCurrentUser.path {
            note(paint("33", "│ ⚠ this is your HOME dir, not a repo — cd into the project and re-run /dive for a real code read"))
        }
        note(dim("▤ dive · repo map → code read (LOCAL, no web) → multi-model → synthesize"))

        let start = await diveStep("🔎", "start dive run") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "start", "goal": goal], context: context)
        }
        guard start.success, let runID = start.metadata["run_id"] else {
            err("dive · failed to start: \(start.error ?? start.output)")
            return 1
        }

        // REPO CONTEXT ONLY — the current project's own files. Deliberately NO web search and NO /Volumes
        // estate sweep: those two steps are exactly what mis-routed a codebase question into another repo.
        _ = await diveStep("📂", "repo context (our files)") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "context", "run_id": runID,
                                            "query": goal, "limit": 12], context: context)
        }

        let synth = await diveStep("📝", "synthesize from our code") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "synthesize", "run_id": runID], context: context)
        }
        guard synth.success else {
            err("dive · incomplete: \(synth.error ?? synth.output)")
            return 1
        }

        // MULTI-AGENT READ: every reachable model analyzes the SAME grounded code dossier; the panel is
        // synthesized into one file-cited verdict. Wide council = consultation (no build hand-off): dive
        // answers the question, it does not edit.
        let brief = """
        Deep-dive question about OUR OWN codebase (repo root: \(root)): \(goal)

        Answer ONLY from the code evidence below — this is a LOCAL code read, NOT web research. Cite the
        concrete files/paths the evidence names. If the evidence doesn't settle it, say exactly what's
        missing and which file to open next. Do NOT speculate about other repos or the outside world.

        ── CODE EVIDENCE (from our repo) ──
        \(synth.output)
        """
        return await runWideCouncil(opts, goal: brief, registry: registry, root: root,
                                    providerId: providerId, model: model, rolesOverride: rolesOverride)
    }

    private static func runCouncil(_ opts: KistOptions, goal: String, execute: Bool,
                                   registry: ProviderRegistry, root: String,
                                   tools: ToolRegistry, context: ToolContext,
                                   providerId: String, model: String?,
                                   rolesOverride: RoleBindings? = nil,
                                   researchDossier: String? = nil,
                                   researchRunID: String? = nil) async -> Int32 {
        guard let requestedRoles = rolesOverride ?? resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }
        let roles = autoCouncilRoles(requestedRoles, registry: registry)
        let memory = opts.noMemory ? nil : ProjectMemory(root: root)
        let recorder = TraceRecorder(traceId: TraceID.make())
        if roles != requestedRoles {
            note("council · auto-team · \(roles.summary)")
        } else if !roles.isHeterogeneous {
            note("council · single-provider · assign roles with /roles coder deepseek /roles critic gemini, or configure more provider keys")
        }
        note("kist · council · \(roles.summary) · \(root)\(execute ? " · execute" : "")")

        let progress = councilResearchProgress(projectRoot: root, runID: researchRunID)
        // ONE ledger for the whole --budget run: council AND the plan-execute it hands off to draw
        // from the same cap (Codex gate C3#1 — a fresh ledger per stage doubled the effective budget).
        let runBudget = opts.makeBudget()
        let result = await AICouncil(providers: registry, roles: roles,
                                     memoryContext: memory?.planningContext(episodeLimit: 8),
                                     researchDossier: researchDossier,
                                     recorder: recorder,
                                     progress: progress,
                                     budget: runBudget).run(goal: goal)
        let path: String
        do {
            path = try writeCouncilArtifact(result.markdown, goal: goal, root: root)
        } catch {
            err("council · failed to write artifact: \(error)")
            return 1
        }

        note("council · board saved · \(path)")
        // Legible primitive, not a wall of prose (#6/#7): mind gists → decision → next tasks → test plan.
        // The full board stays in the saved artifact (the proof drawer, #8).
        print(CouncilCard.render(result, artifactPath: path, color: TerminalCapabilities.stdoutIsInteractive))
        let projectPlan = seedCouncilProjectBoard(goal: goal, finalPlan: result.finalPlan, artifactPath: path, root: root)
        note("task board seeded · \(projectPlan.tasks.count) tasks · show with /goals")
        memory?.recordEpisode(Episode(goal: "council: \(goal)", success: true,
                                      summary: String(result.finalPlan.prefix(800)), at: Date()))
        for line in await recorder.summary().terminalLines() { note(line) }

        guard execute else { return 0 }
        let builderGoal = result.builderBrief + "\n\nCouncil artifact path: \(path)\nShared task board: .kist/plan.json. Use the tasks tool to start, update, block, and complete tasks."
        note("council · handing builder brief to plan→execute")
        return await runPlanExecute(opts, goal: builderGoal, registry: registry, root: root,
                                    tools: tools, context: context, providerId: providerId,
                                    model: model, rolesOverride: roles, budgetOverride: runBudget,
                                    riskObjective: goal)   // classify risk on the USER's goal, not the council transcript
    }

    /// "Dig in deep" — the WIDE council: every reachable model answers the SAME question, synthesized into
    /// one verdict. Same CouncilCard render; no plan-execute hand-off (it's a consultation, not a build).
    private static func runWideCouncil(_ opts: KistOptions, goal: String,
                                       registry: ProviderRegistry, root: String,
                                       providerId: String, model: String?,
                                       rolesOverride: RoleBindings? = nil) async -> Int32 {
        guard let requestedRoles = rolesOverride ?? resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }
        let roles = autoCouncilRoles(requestedRoles, registry: registry)
        let recorder = TraceRecorder(traceId: TraceID.make())
        let reachable = registry.providers.filter { registry.hasKey(for: $0) }.count
        note("kist · dig in deep · consulting up to \(min(reachable, 5)) model(s) · \(root)")
        let runBudget = opts.makeBudget()
        let result = await AICouncil(providers: registry, roles: roles,
                                     recorder: recorder, budget: runBudget).runWide(goal: goal)
        let path = try? writeCouncilArtifact(result.markdown, goal: goal, root: root)
        if let path { note("dig in deep · panel saved · \(path)") }
        print(CouncilCard.render(result, artifactPath: path, color: TerminalCapabilities.stdoutIsInteractive))
        for line in await recorder.summary().terminalLines() { note(line) }
        return 0
    }

    private static func councilResearchProgress(projectRoot: String, runID: String?) -> AICouncil.ProgressSink? {
        guard let runID, !runID.isEmpty else { return nil }
        return { status, message in
            guard let store = try? ResearchRunStore.open(projectRoot: projectRoot, runID: runID) else { return }
            _ = try? store.heartbeat(status: status, message: message)
        }
    }

    @discardableResult
    static func seedCouncilProjectBoard(goal: String, finalPlan: String, artifactPath: String, root: String) -> Plan {
        let projectPlan = CouncilBoardCompiler.compile(goal: goal, finalPlan: finalPlan, artifactPath: artifactPath)
        PlanStore(projectRoot: root).replace(title: projectPlan.title, tasks: projectPlan.tasks)
        return projectPlan
    }

    /// A council only earns the name if multiple minds can disagree. When the caller has not
    /// assigned a heterogeneous team, form a best-effort one from configured providers while
    /// keeping the planner on the current session model.
    static func autoCouncilRoles(_ roles: RoleBindings, registry: ProviderRegistry) -> RoleBindings {
        guard !roles.isHeterogeneous else { return roles }

        var next = roles
        let fallback = roles.fallback.providerId.lowercased()

        func firstAvailable(_ ids: [String]) -> ProviderBinding? {
            for id in ids {
                guard id.lowercased() != fallback,
                      let provider = registry.provider(id: id),
                      registry.hasKey(for: provider) else { continue }
                return ProviderBinding(providerId: provider.id)
            }
            return nil
        }

        if let worker = firstAvailable(["deepseek", "mimo", "qwen", "zhipu", "moonshot", "ollama", "mlx"]) {
            next = next.binding(.worker, to: worker)
        }
        if let coder = firstAvailable(["deepseek", "mimo", "qwen", "zhipu", "moonshot", "ollama", "mlx"]) {
            next = next.binding(.coder, to: coder)
        }
        if let critic = firstAvailable(["gemini", "grok", "anthropic", "openai", "deepseek"]) {
            next = next.binding(.critic, to: critic)
        }

        return next
    }

    private static func writeCouncilArtifact(_ markdown: String, goal: String, root: String) throws -> String {
        let dir = URL(fileURLWithPath: root).appendingPathComponent(".mythos/council", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = councilTimestamp()
        let slug = councilSlug(goal)
        let url = dir.appendingPathComponent("\(stamp)-\(slug).md")
        try Data(markdown.utf8).write(to: url, options: [.atomic])
        return url.path
    }

    private static func councilTimestamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func councilSlug(_ goal: String) -> String {
        let lower = goal.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
            if out.count >= 48 { break }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "council" : trimmed
    }

    // MARK: - Fleet (supervised parallel, heterogeneous)

    /// Decompose the goal → disjoint subtasks → launch one agent per subtask in its own worktree →
    /// supervise to a forge-proof signoff → join the signed in-lease branches onto a fresh integration
    /// branch (NEVER main). Running this IS the explicit arming; it is bounded and confined.
    private static func runFleet(_ opts: KistOptions, registry: ProviderRegistry, root: String,
                                 tools: ToolRegistry, providerId: String, model: String?,
                                 rolesOverride: RoleBindings? = nil) async -> Int32 {
        guard GitIsolation.isGitRepo(root) else {
            err("error: --fleet needs a git repo at \(root) (isolated branches). Nothing launched."); return 2
        }
        // Build the role team (planner/coder/critic = different vendors), reusing the provider catalog.
        guard let roles = rolesOverride ?? resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }

        let goal = opts.goal ?? ""
        let agents = max(1, opts.agents)
        note("kist · fleet · \(roles.summary) · \(root)\(roles.isHeterogeneous ? " · team" : "") · ≤\(agents) agents")

        // CAPTAIN SAFETY GATES (preserved across the origin/main merge): the domain-learning gate then the
        // simulation gate must BOTH accept the plan before any side effect. Pinned by KistRunnerSafetyTests
        // (preflight-before-side-effects). Fail-closed — a gate that doesn't accept refuses the launch.
        let domainPreflight = CaptainDomainLearningEnforcer.preflight(mode: .fleet,
                                                                      objective: goal,
                                                                      projectRoot: root,
                                                                      evidenceMode: opts.noMemory ? .redacted : .full)
        for line in domainPreflight.terminalLines { note(line) }
        guard domainPreflight.canExecute else {
            err("captain refused to launch: domain-learning gate did not accept this fleet plan.")
            return 1
        }
        let preflight = CaptainSimulationEnforcer.preflight(mode: .fleet,
                                                            objective: goal,
                                                            projectRoot: root,
                                                            evidenceMode: opts.noMemory ? .redacted : .full,
                                                            noMemory: opts.noMemory)
        for line in preflight.terminalLines { note(line) }
        guard preflight.canExecute else {
            err("captain refused to launch: simulation gate did not accept this fleet plan.")
            return 1
        }

        // ONE ledger shared by the planner AND every fleet agent → a single global cap across the
        // whole parallel fleet, planning included (the fleet path doesn't go through makeLoop, so this
        // is where --budget reaches it). Created BEFORE planning so the planner call counts too.
        let fleetBudget = opts.makeBudget()

        // 1. DECOMPOSE — the planner vendor proposes disjoint subtasks from the repo's real dir tree.
        let scopeContext = CaptainOrchestrator.deriveScopeContext(fromFiles: GitIsolation.trackedFiles(repo: root)).snapshot
        let subtasks = await FleetPlanner(providers: registry, binding: roles.binding(for: .planner))
            .plan(goal: goal, scopeContext: scopeContext, maxAgents: agents, budget: fleetBudget)
        guard !subtasks.isEmpty else { err("the planner returned no subtasks for that goal."); return 1 }
        note("planned \(subtasks.count) subtask(s): " + subtasks.map(\.title).joined(separator: ", "))

        // 2. LAUNCH — one heterogeneous in-process agent per subtask, each in its own worktree.
        let fleetRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".mythos/fleet", isDirectory: true)
        let spawner = PlanExecuteFleetSpawner.make(providers: registry, roles: roles, tools: tools,
                                                   budget: fleetBudget,
                                                   externalReadRoots: opts.allowReadPaths)
        let orch = CaptainOrchestrator(spawner: spawner)
        let launch = await orch.launchFleet(goal: goal, repo: root, subtasks: subtasks, maxAgents: agents,
                                            baseDir: fleetRoot, nowEpoch: Date().timeIntervalSince1970)
        for issue in launch.scopeIssues { note("scope · \(issue)") }
        note(launch.summary)
        guard launch.launchedCount > 0 else { return 1 }

        // 3. SUPERVISE — verify each agent's REAL committed work + seal a forge-proof signoff.
        let goalID = launch.fleetID.uuidString
        let board = FleetBlackboardStore(fleetID: launch.fleetID, baseDir: fleetRoot)
        let inbox = FleetUpdateInbox(fleetID: launch.fleetID, baseDir: fleetRoot)
        let ledger = FleetSignoffLedger(baseDir: launch.fleetDir.appendingPathComponent("signoff"))
        let batons = FleetBatonStore(baseDir: launch.fleetDir)
        // MANDATORY LEASE for a multi-agent fleet (Codex HIGH): when >1 agent runs in parallel, an empty
        // lease means the planner's scope was cleared (a collision/hallucination the validator dropped) —
        // such an agent can't be proven disjoint from its crew, so the Foreman REFUSES to sign it
        // (done_needs_lease) rather than laundering it as "no lease ⇒ no escapes ⇒ auto-mergeable". A
        // single-agent fleet has nothing to be disjoint from, so a lease isn't required there.
        // Verifier trust: default OFF ⇒ only a held-out operator oracle (~/.kist/test-command) verifies;
        // a fleet with no oracle fails closed (never a false green). --trust-worktree-tests opts into the
        // in-repo harness tier for your OWN honest agents (a shell harness can transitively run agent code).
        let foreman = Foreman(ledger: ledger, leaseRequired: subtasks.count > 1,
                              claimsRequired: true, acceptanceTestRequired: true,
                              allowWorktreeHarness: opts.trustWorktreeTests)
        let supervisor = FleetSupervisor(board: board, inbox: inbox, ledger: ledger, batons: batons, foreman: foreman)
        let result = await supervisor.supervise(goalID: goalID)
        note(result.summary)

        // COCKPIT (Terminal Captain integration): the whole-picture view — per-agent status, lease,
        // signoff, and HONEST merge-fate (derived from the same trustworthy ledger + rule as the merge
        // gate, so it can never show "merges" for a branch the gate would refuse).
        if let snapshot = board.currentBoard() {
            let chainIntact = ledger.all().isEmpty || !ledger.entries.isEmpty
            note(FleetCockpitModel.picture(goal: snapshot.goal, cells: snapshot.cells,
                                           trustworthyEntries: ledger.entries, chainIntact: chainIntact).render())
        }

        guard result.allSigned else {
            note("merge · skipped — fleet was partial; signed branches remain isolated for review.")
            note("No integration branch was created. Mythos never writes main.")
            return 1
        }

        // 4. MERGE GATE — join ONLY the signed, in-lease branches onto a fresh integration branch (never main).
        let merge = supervisor.joinSignedBranches(goalID: goalID, base: "HEAD")
        note("merge · \(String(describing: merge))")
        switch merge {
        case .merged:
            note("Review the integration branch, then promote it yourself — Mythos never writes main.")
            // The strongest verification we have: every branch reached a forge-proof signoff and joined.
            // Record a PROVEN lesson sourced to the fleet's signoff ledger.
            if !opts.noMemory {
                LessonStore().record(Lesson(kind: .proven,
                    text: "fleet built + verified (\(subtasks.count) agents): \(goal.prefix(110))",
                    source: "fleet-signoff:\(goalID)", at: Date().timeIntervalSince1970))
            }
            return 0
        case .alreadyIntegrated:
            // With a fleetID-unique integration branch this should be unreachable; if it ever fires, the
            // fresh fleet's branches were NOT joined — report honestly, never as success (Codex HIGH).
            note("merge · an integration branch unexpectedly already existed — this fleet's branches were NOT joined. Review manually.")
            return 1
        case .nothingToMerge:
            note("No integration branch was created because no signed in-lease branches were mergeable.")
            return 1
        case .conflict, .failed:
            note("No successful integration branch was created. Mythos never writes main.")
            return 1
        }
    }

    // MARK: - Plan→execute (typed DAG built by the role team)

    static func briefContext(memoryContext: String?, roles: RoleBindings,
                                     lessons: String? = nil, specialists: String? = nil,
                                     reviewTargets: String? = nil) -> String? {
        var parts = ["CURRENT AI TEAM: \(roles.summary)"]
        // Cortex/project memory FIRST — it's the highest-value context ("what kist knows about you,
        // follow these") and must NOT be truncated off the end by the projectContext length cap
        // (that bug dropped it in real runs where persona+lessons filled the budget).
        if let memoryContext, !memoryContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(memoryContext)
        }
        if let specialists, !specialists.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(specialists)                    // task-matched professional persona(s), advisory
        }
        if let reviewTargets, !reviewTargets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(reviewTargets)                  // deterministic changed-file manifest for reviews
        }
        if let lessons, !lessons.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(lessons)                         // advisory lessons from past runs (P3 memory)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Run a plan→execute: the planner emits a typed DAG, you approve it (unless --yolo), then the team
    /// builds it. Shared by the `--plan-execute` one-shot and the REPL's `/plan-execute` escalation.
    private static func runPlanExecute(_ opts: KistOptions, goal: String, registry: ProviderRegistry,
                                       root: String, tools: ToolRegistry, context: ToolContext,
                                       providerId: String, model: String?,
                                       rolesOverride: RoleBindings? = nil,
                                       budgetOverride: BudgetLedger? = nil,
                                       // The string the SAFETY gates keyword-classify for risk. Defaults to the
                                       // executed goal, but council-execute passes the USER'S ORIGINAL goal here
                                       // (dogfood 2026-08-06: the builder brief embeds the whole council markdown
                                       // transcript, so an incidental "auth"/"safety"/"exploit" word — or an
                                       // org-store domain mislabel — flipped a COBOL report tweak to CRITICAL and
                                       // hard-blocked a user-requested build. Risk must reflect what the USER asked).
                                       riskObjective: String? = nil) async -> Int32 {
        guard let roles = rolesOverride ?? resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }
        let memory = opts.noMemory ? nil : ProjectMemory(root: root)
        let memNote = (memory?.hasContent ?? false) ? " · memory \(memory!.recentEpisodes(limit: 100).count) runs" : ""
        note("kist · plan→execute · \(roles.summary) · \(root)\(roles.isHeterogeneous ? " · team" : "")\(opts.budgetTokens.map { " · budget \($0)" } ?? "")\(memNote)")
        // CAPTAIN SAFETY GATES (preserved across the origin/main merge): both must accept before any side
        // effect. Pinned by KistRunnerSafetyTests. Fail-closed. c7 splice: --no-memory is threaded to the
        // simulation gate so it suppresses the .kist disk write while still computing + enforcing the verdict.
        let gateObjective = riskObjective ?? goal
        let domainPreflight = CaptainDomainLearningEnforcer.preflight(mode: .planExecute,
                                                                      objective: gateObjective,
                                                                      projectRoot: root,
                                                                      evidenceMode: opts.noMemory ? .redacted : .full)
        for line in domainPreflight.terminalLines { note(line) }
        guard domainPreflight.canExecute else {
            err("captain refused to execute: domain-learning gate did not accept this plan.")
            return 1
        }
        // Plan-execute is reachable only from EXPLICIT user commands (/build, /pe, --plan-execute,
        // council-execute) — the human already decided, so a sub-threshold estimate is advisory,
        // not a veto. Critical-risk signals and failed evidence writes still hard-block.
        let planPreflight = CaptainSimulationEnforcer.preflight(mode: .planExecute,
                                                                objective: gateObjective,
                                                                projectRoot: root,
                                                                evidenceMode: opts.noMemory ? .redacted : .full,
                                                                noMemory: opts.noMemory,
                                                                initiator: .userRequest)
        for line in planPreflight.terminalLines { note(line) }
        guard planPreflight.canExecute else {
            err("captain refused to execute: simulation gate did not accept this plan.")
            return 1
        }
        let recorder = TraceRecorder(traceId: TraceID.make())
        // Reuse the caller's ledger when handed one (e.g. --council-execute) so the whole run shares a
        // single cap; otherwise create this run's own (Codex gate C3#1).
        let budget = budgetOverride ?? opts.makeBudget()
        let runReplay = RunReplayStore(projectRoot: root, provider: providerId, model: model)
        let proofStore = TurnProofStore(replayStore: runReplay)
        proofStore.startTurn(goal: goal)
        // R2a: plan-execute is the LONGEST-running surface — typing must render there too, not
        // just queue invisibly (review catch: "my typing disappeared" for a 20-minute plan run).
        let planSink = TerminalEventSink(style: .calm, proofStore: proofStore,
                                         typedInput: { TurnInputQueue.shared.preview() })
        TurnInputQueue.shared.addOnChange { planSink.refreshLiveStatus() }
        let pxl = PlanExecuteLoop(providers: registry, roles: roles, tools: tools, context: context,
                                  sink: planSink,
                                  interactor: opts.yolo ? AutoApproveInteractor() : terminalInteractor(for: opts),
                                  requireApproval: !opts.yolo, recorder: recorder, budget: budget, memory: memory)
        // Fold cortex (who Luke is + this project) into the planner's goal so plan→execute (and
        // --council-execute, which routes here) plans WITH your preferences, not just ProjectMemory.
        let planGoal = Self.sessionMemory(root: root, opts: opts).map {
            "MEMORY — what kist knows about you & this project:\n\($0)\n\n---\nGOAL:\n\(goal)"
        } ?? goal
        let pOut = await pxl.run(goal: planGoal)
        for line in await recorder.summary().terminalLines() { note(line) }
        note(pOut.success ? "✓ \(pOut.message)" : "✗ \(pOut.message)")
        note("replay · kist --replay \(runReplay.manifest.runID)")
        // Learn from the VERIFIED outcome: plan-execute success is critic-verified, so it's a PROVEN
        // lesson (with a real source); a failure is an obstacle. Memory stays advisory.
        if !opts.noMemory {
            let store = LessonStore(); let at = Date().timeIntervalSince1970
            if pOut.success {
                store.record(Lesson(kind: .proven, text: "accomplished via plan→execute: \(goal.prefix(120))",
                                    source: "plan-execute", at: at))
            } else if !pOut.interrupted {
                // R1: an ESC'd run must NOT book an obstacle lesson — a user cancel is zero
                // evidence the goal fails, and obstacle lessons outrank proven ones in retrieval.
                store.record(Lesson(kind: .obstacle, text: "plan→execute failed: \(goal.prefix(120))", source: nil, at: at))
            }
        }
        return pOut.success ? 0 : 1
    }

    /// Terminal autopilot policy:
    /// - normal REPL: ask before configured sensitive tools;
    /// - `--yolo`: approve routine action prompts, still ask on dangerous/scope prompts;
    /// - `--auto`: approve even dangerous/scope prompts, relying on forced OS sandbox + runtime gates.
    static func terminalInteractor(for opts: KistOptions) -> TerminalInteractor {
        TerminalInteractor(autoApproveRoutine: opts.yolo || opts.auto,
                           autoApproveDangerous: opts.auto)
    }

    // MARK: - Helpers

    /// Explicit flag > config > strongest-or-cheapest available (per selection policy) > first local.
    /// Nil after an error.
    private static func resolveProvider(_ opts: KistOptions, _ registry: ProviderRegistry, configProvider: String?,
                                        verdicts: [String: ModelVerdict] = [:],
                                        policy: ProviderSelectionPolicy = .power) -> String? {
        if let pid = opts.providerId ?? configProvider {
            guard registry.provider(id: pid) != nil else { err("error: unknown provider '\(pid)'. Try --list-providers."); return nil }
            return pid   // explicit user choice always wins — the scorecard/policy never override it
        }
        // Pick the STRONGEST AVAILABLE provider, not whatever sorts first in the catalog. Two kinds are
        // eligible for the single-model default (Luke 2026-08-06 — "strongest leads", team stays opt-in):
        //   • keyed cloud: requiresAPIKey && a key is present (gemini/deepseek/grok/openai/…). MiMo sorts
        //     first in the catalog but 400s on multi-turn tool history, so "first with a key" silently made
        //     it the default and turns died with 0 tool calls — hence rank, not order.
        //   • subscription CLI (claude-cli/codex-cli): requiresAPIKey == false but auth lives in the CLI.
        //     Previously EXCLUDED from the default entirely, so the two STRONGEST providers could never lead
        //     and gemini always won. Now included WHEN `isLocallyAvailable()` passes — a bounded, non-billable
        //     local probe (binary on a trusted PATH + `auth/login status` succeeds; never sends a prompt).
        // Rank by ModelEscalator strength (claude-cli/codex-cli outrank the cloud APIs), scorecard-adjusted so
        // a chronically-failing provider isn't silently chosen. Local models (ollama/mlx, no auth) stay the
        // last-resort fallback below, never chosen over a keyed/subscription provider.
        let subscriptionReady = registry.providers.filter { p in
            !p.requiresAPIKey && (p as? CLIChatProvider)?.isLocallyAvailable() == true
        }
        let keyedCloud = registry.providers.filter { $0.requiresAPIKey && registry.hasKey(for: $0) }
        let eligible = subscriptionReady + keyedCloud
        if let best = pickByPolicy(eligible, policy: policy, verdicts: verdicts) { return best.id }
        if let local = registry.providers.first(where: { !$0.requiresAPIKey }) { return local.id }
        err("error: no provider has a key. Set one (e.g. export OPENAI_API_KEY=…) or use --provider. See --list-providers.")
        return nil
    }

    /// Pick the default from `eligible` under the selection policy. `.power` → strongest (rank desc).
    /// `.cost` → cheapest marginal $/token (asc), ties broken toward the stronger model so "cheapest"
    /// is never gratuitously the weakest. Pure/testable.
    static func pickByPolicy(_ eligible: [any ChatProvider], policy: ProviderSelectionPolicy,
                             verdicts: [String: ModelVerdict]) -> (any ChatProvider)? {
        switch policy {
        case .power:
            return eligible.max { ModelEscalator.rank($0.id, verdicts: verdicts) < ModelEscalator.rank($1.id, verdicts: verdicts) }
        case .cost:
            return eligible.min { a, b in
                let ca = ProviderCostRank.marginalPerMillion(a.id)
                let cb = ProviderCostRank.marginalPerMillion(b.id)
                if ca != cb { return ca < cb }
                // Equal cost (e.g. two flat-rate/local $0 providers) → prefer the stronger one.
                return ModelEscalator.rank(a.id, verdicts: verdicts) > ModelEscalator.rank(b.id, verdicts: verdicts)
            }
        }
    }

    /// Interactive startup picker for a bare `kist` REPL. It is deliberately TTY-only so piped
    /// commands like `printf '/help\n/exit\n' | kist` still go straight to the REPL.
    private static func pickProvider(_ registry: ProviderRegistry) async -> ProviderPick? {
        guard stdinIsTTY() else { return nil }
        var reg = registry
        while true {
        let choices = reg.providers.filter { !$0.requiresAPIKey || reg.hasKey(for: $0) }
        guard !choices.isEmpty else { return nil }

        note("Select model for this session (Enter = default):")
        for (idx, provider) in choices.enumerated() {
            let model = provider.defaultModel.isEmpty ? "" : " default \(provider.defaultModel)"
            note("  \(idx + 1). \(provider.id) · \(provider.name)\(model)")
        }
        let addIndex = choices.count + 1
        note("  \(addIndex). add · Add a model (any OpenAI-compatible) — auto-tests & configures it")
        FileHandle.standardError.write(Data("provider> ".utf8))
        guard let raw = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        // "Add a model": onboard it (self-heal · self-test · pen-test), then re-render so it's pickable now.
        if raw.lowercased() == "add" || Int(raw) == addIndex {
            _ = await AddModelFlow.run()
            reg = makeRegistry()   // rebuild; the loop re-renders with the new model (bounded, no recursion)
            continue
        }

        let provider: any ChatProvider
        var model: String?
        if let n = Int(raw), choices.indices.contains(n - 1) {
            provider = choices[n - 1]
        } else if let binding = ProviderBinding.parse(raw),
                  let resolved = reg.provider(id: binding.providerId),
                  !resolved.requiresAPIKey || reg.hasKey(for: resolved) {
            provider = resolved
            model = binding.model
        } else {
            err("unknown or unconfigured provider '\(raw)' - using the default.")
            return nil
        }

        if model == nil, !provider.availableModels.isEmpty {
            note("Models for \(provider.id) (Enter = \(provider.defaultModel)):")
            for (idx, candidate) in provider.availableModels.enumerated() {
                note("  \(idx + 1). \(candidate.id)")
            }
            FileHandle.standardError.write(Data("model> ".utf8))
            if let rawModel = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawModel.isEmpty {
                if let n = Int(rawModel), provider.availableModels.indices.contains(n - 1) {
                    model = provider.availableModels[n - 1].id
                } else {
                    model = rawModel
                }
            }
        }

        return ProviderPick(providerId: provider.id, model: model)
        }
    }

    static func stdinIsTTY() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return isatty(fileno(stdin)) != 0
        #else
        return false
        #endif
    }

}
