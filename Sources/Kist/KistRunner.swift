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

    /// The full extra tool set (media/data/memory/vision + the agent-writable Cortex), built once so
    /// EVERY run path — fresh, goal, and --resume — gets identical capabilities. Cortex is included
    /// unless --no-memory; Gemini/vision/OpenAI tools are added only when their keys/bindings exist.
    static func buildExtraTools(root: String, fetchAllowedHosts: [String],
                                opts: KistOptions, registry: ProviderRegistry) -> [any AgentTool] {
        // --fast: a lean solo dev tool. Keep ONLY the core code tools (headless: read/write/edit/
        // apply_patch/search_code/ast_grep/git/symbols/run_command…) + the cheap Cortex; drop the
        // ~20 media/vision/browse/pentest/research/workflow extras that bloat the prompt and burn
        // tokens when the user just wants quick dev help. Big prompt cut → cheaper + faster.
        if opts.fast { return opts.noMemory ? [] : [CortexTool()] }
        var extraTools: [any AgentTool] = [ReadSpreadsheetTool(), QueryDataTool(), MediaClipTool(),
                                           SecurityAuditTool(), GovernanceReportTool(), WorkflowTool(),
                                           ManageTasksTool(), BrowserTool(allowedHosts: fetchAllowedHosts)]
        // Agent-writable personal memory (the Cortex): the MODEL remembers durable preferences,
        // project facts, and journals its work across sessions — Claude-style memory, more personal.
        if !opts.noMemory { extraTools.append(CortexTool()) }
        if let geminiKey = registry.apiKey(forProviderId: "gemini") {
            extraTools.append(AnalyzeMediaTool(registry: registry, geminiKey: geminiKey))
            extraTools.append(GenerateAudioTool(geminiKey: geminiKey))   // Gemini native TTS → WAV
            extraTools.append(GenerateVideoTool(geminiKey: geminiKey))   // Veo video gen (slow, prototype)
            extraTools.append(LiveAskTool(geminiKey: geminiKey))   // Gemini Live API (prototype)
            extraTools.append(CountTokensTool(geminiKey: geminiKey))   // pre-flight token count
            extraTools.append(GroundedAnswerTool(geminiKey: geminiKey))   // live Google Search grounding
        }
        // Durable semantic memory (file-backed vector store). Embedder: local Ollama when opted in
        // (KIST_EMBEDDER=ollama), else Gemini when its key is present, else off (no silent dependency).
        if let embedder = Self.makeEmbedder(registry: registry) {
            let memory = SemanticMemoryService(
                embedder: embedder,
                store: FileBackedVectorStore(path: root + "/.kist/memory/vectors.json"))
            extraTools.append(RememberTool(service: memory))
            extraTools.append(RecallTool(service: memory))
        }
        // Image generation: prefer Gemini's native "Nano Banana" when its key is present, else OpenAI.
        if let geminiKey = registry.apiKey(forProviderId: "gemini") {
            extraTools.append(GenerateImageTool(geminiKey: geminiKey))
            extraTools.append(EditImageTool(geminiKey: geminiKey))   // Nano Banana image editing
        } else if let openAIKey = registry.apiKey(forProviderId: "openai") {
            extraTools.append(GenerateImageTool(apiKey: openAIKey))
        }
        // COMPUTER-USE — DEFAULT-DENY (council-mandated 2026-07-03). The desktop/screen/perception tools are
        // registered ONLY when explicitly armed with --enable-computer-use. Unarmed, they are ABSENT from the
        // registry entirely, so they cannot fire on ANY surface (one-shot / eval / bench / fleet / spawned
        // sub-agent / coding loop). This closes the unattended-input-injection escalation: an agent running in
        // its normal (unarmed) mode has no desktop tools, and a nested kist has arming refused in KistOptions.
        if opts.enableComputerUse {
            extraTools.append(ComputerControlTool())   // app launcher (open_app/url) — host OS automation, armed-only
            // THE HANDS: real screen capture + mouse/keyboard injection (macOS). Armed-only; approval-gated
            // (sensitiveTools) AND reclassified .dangerous so the approval floor catches it on every surface.
            extraTools.append(DesktopControlTool())
            // Readiness diagnostic — read-only; still only present when computer-use is armed.
            extraTools.append(ComputerUseCheckTool())
            extraTools.append(ComputerUseSelfTestTool.wired())
            // Structured UI grounding via the Accessibility tree — deterministic element bounds. Approval-gated
            // (sensitiveTools) because it can expose focused-app labels/values.
            extraTools.append(UIElementsTool.wired())
            extraTools.append(AXPressTool.wired())   // direct AX press by label — the most reliable action
            // Moondream point-to-click: the AIM for the desktop hands. Wired only when a Moondream cloud key
            // OR a local server URL is configured, so there's no silent network dependency.
            let env = ProcessInfo.processInfo.environment
            if env["MOONDREAM_API_KEY"] != nil || env["MOONDREAM_BASE_URL"] != nil {
                extraTools.append(LocateTool.moondream())
                extraTools.append(PointClickTool.wired())   // the tight loop: capture+locate+click in one call
                extraTools.append(WaitForScreenTool.wired())   // continuous perception: wait until X appears
                extraTools.append(LookTool.wired())   // fast "what's on screen?" — cheap scene understanding
                extraTools.append(WatchScreenTool.wired(monitor: PerceptionMonitor()))   // always-on background watch
            }
        }
        if let vision = firstVisionBinding(registry) {
            extraTools.append(ViewImageTool(registry: registry, binding: vision))
            extraTools.append(WatchVideoTool(registry: registry, binding: vision))
            // LiveScreenWatchTool CAPTURES THE HOST SCREEN (screencapture) — host-control, so it's arming-gated
            // like the other computer-use tools (Codex High, 2026-07-03). ViewImage/WatchVideo/Translate below
            // only process media that's explicitly PROVIDED, not the live desktop, so they stay ungated.
            if opts.enableComputerUse {
                extraTools.append(LiveScreenWatchTool(registry: registry, binding: vision))
            }
            extraTools.append(TranslateDocumentTool(registry: registry, binding: vision,
                                                    geminiKey: registry.apiKey(forProviderId: "gemini")))
            let visualVerify = VisualVerifyTool(registry: registry, binding: vision, allowedHosts: fetchAllowedHosts)
            extraTools.append(visualVerify)
            extraTools.append(ResearchRunTool(allowedHosts: fetchAllowedHosts,
                                              visual: { arguments, context in
                                                  try await visualVerify.execute(arguments: arguments, context: context)
                                              }))
        }
        return extraTools
    }

    /// On --resume, surface the CURRENT cortex memory so the agent starts the resumed turn already
    /// knowing (its toolset includes `cortex` too, so this is a convenience, not the only path).
    /// GUARDED: append only after an ASSISTANT turn so provider message-alternation stays valid;
    /// no-op when memory is off or empty. Pure → unit-tested.
    static func withMemoryRefresh(_ cp: LoopCheckpoint, memory: String, enabled: Bool) -> LoopCheckpoint {
        guard enabled, !memory.isEmpty, cp.messages.last?.role == .assistant else { return cp }
        var out = cp
        out.messages.append(ChatMessage(role: .user, content: "MEMORY REFRESH — what kist knows about you now:\n" + memory))
        return out
    }

    /// The full session memory injected into a run's brief: the Cortex (who Luke is + this project +
    /// recent journal) folded with ProjectMemory (this repo's planning notes). Used by the one-shot
    /// and TUI paths so cortex is injected in EVERY mode, not only the interactive REPL.
    /// Per-cycle token budget: an even share of what REMAINS across the cycles LEFT, floored so a cycle is
    /// never starved below a unit of real work, and capped at the full remaining (the last cycle can use it
    /// all). Adaptive (uses the live remaining), so budget unspent by cheap early cycles flows forward to
    /// finish the task — instead of a rigid total/maxCycles that dies mid-work and forces a fresh restart.
    static func perCycleBudget(remaining: Int, cycleIndex: Int, maxCycles: Int, floor: Int = 60_000) -> Int {
        guard remaining > 0 else { return 0 }
        let cyclesLeft = max(1, maxCycles - cycleIndex)
        let evenShare = remaining / cyclesLeft
        return min(remaining, max(floor, evenShare))
    }

    /// Cross-cycle CONTINUITY note. Each great-loop cycle is a fresh conversation, so without a reminder the
    /// model has amnesia and re-creates work a prior cycle already did (dogfood: built the package at ./ then
    /// re-created it under ./MathKit/ → duplication, never converged). From cycle 1 on, if prior cycles
    /// changed files, tell the model to CONTINUE that work (not restart) and list the files. nil on cycle 0
    /// (nothing done yet) or when no files changed (a read-only/analysis task).
    static func continuityNote(cycleIndex: Int, changedFiles: [String]) -> String? {
        guard cycleIndex > 0, !changedFiles.isEmpty else { return nil }
        return "WORK ALREADY IN PROGRESS (prior cycles) — CONTINUE it; do NOT recreate the project from "
            + "scratch or under a new subdirectory. If a build/manifest file already exists, build and TEST "
            + "what's here. Files changed so far:\n"
            + changedFiles.prefix(60).map { "  - \($0)" }.joined(separator: "\n")
    }

    /// The failure detail of the LAST failed `run_command` in a cycle's trajectory — the concrete
    /// build/test/compiler error to carry into the next cycle. nil when the last run_command succeeded or
    /// none failed (so a cycle that ended green doesn't push a stale error forward).
    static func lastCommandFailure(in trajectory: [ActionRecord]) -> String? {
        guard let last = trajectory.last(where: { $0.tool == "run_command" }) else { return nil }
        guard !last.success, let detail = last.failureDetail else { return nil }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Tools irrelevant to an autonomous CODING loop — dropped so their schemas don't inflate EVERY model
    /// call. Dogfood: the full set was ~70 tools / ~25k schema chars (~6.5k tokens/call), and a coding cycle
    /// spent ~half its budget re-sending schemas for media / app-UI-testing / desktop-control / pentest /
    /// enterprise-reporting tools it never uses — so cycles couldn't converge to a verified done. Kept:
    /// file/shell/edit/lsp/memory/tasks/web/research/symbols (everything a build+test+fix loop needs).
    static func isLoopIrrelevantTool(_ name: String) -> Bool {
        if name.hasPrefix("isolated-tester__") { return true }   // app UI-testing MCP — not code building
        let drop: Set<String> = [
            "computer_control", "desktop_control", "tap", "locate", "look", "wait_for_screen", "watch_screen", "computer_use_check", "computer_use_selftest", "ui_elements", "ax_press",   // desktop/GUI control — not code building
            "pentest", "security_audit", "business_workflow", "governance_report",
            "edit_image", "generate_audio", "analyze_media", "watch_video", "extract_clip", "view_image",
        ]
        return drop.contains(name)
    }

    static func sessionMemory(root: String, opts: KistOptions) -> String? {
        guard !opts.noMemory else { return nil }
        let projectName = (root as NSString).lastPathComponent
        let parts = [CortexMemory().context(projectName: projectName), ProjectMemory(root: root).planningContext()]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Auto-log a completed goal run to the cortex JOURNAL, so the work log fills itself instead of
    /// only when the model remembers to call the cortex tool. One bounded line; no-op under
    /// --no-memory; best-effort (a journal write must never fail the run). Secrets in the goal are
    /// redacted at CortexMemory's write choke point.
    static func autoJournalRun(goal: String, success: Bool, root: String, enabled: Bool) {
        guard enabled, !goal.isEmpty else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
        df.locale = Locale(identifier: "en_US_POSIX")
        let g = goal.split(separator: "\n").first.map(String.init) ?? goal
        try? CortexMemory().logWork("[\(success ? "done" : "paused")] \(g.prefix(100)) · \((root as NSString).lastPathComponent)",
                                    date: df.string(from: Date()))
    }

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
        let shell: ShellPolicy = opts.allowShell ? ShellPolicy(enabled: true, autoApprove: true, deny: shellDeny) : .denied
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
                                     lessonStore: lessonStore, maxIterations: opts.maxIterations)
                Self.autoJournalRun(goal: cp.title, success: outcome.success, root: root, enabled: !opts.noMemory)
                printUsageDelta(from: [], to: await traceRecorder.all(), label: "usage", projectRoot: root)
                if !outcome.success { note("paused — resume with: kist --resume \(outcome.checkpointId)") }
                return outcome.success ? 0 : 1
            }
        }

        // Provider + project root are shared by the REPL and one-shot paths.
        guard let providerId = resolveProvider(opts, registry, configProvider: config.provider) else { return 2 }
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
                let loop = makeLoop(registry: registry, providerId: providerId, model: model, context: context,
                                    tools: tools, checkpoints: checkpoints, maxIterations: opts.maxIterations,
                                    budget: opts.makeBudget(),
                                    interactor: terminalInteractor, approvalTools: opts.yolo ? [] : sensitiveTools,
                                    planMode: opts.planMode, extendedThinking: opts.extendedThinking, toolMode: toolMode,
                                    roles: roleSelection.bindings, delegationDepth: opts.delegationDepth,
                                    showReasoning: opts.extendedThinking,   // --think → watch the reasoning inline
                                    sinkOverride: TerminalEventSink(showReasoning: opts.extendedThinking, style: .calm, proofStore: proofStore),
                                    recorder: recorder, traceRecorder: traceRecorder)
                // CONVERSATIONAL ESCALATION: reach the fleet / plan-DAG from inside the chat, plus an
                // auto-router that PROPOSES (never silently spends) when a plain message looks like a big build.
                var repl = KistREPL(loop: loop, commands: KistCommands.load(projectRoot: root))
                repl.defaultAgents = opts.agents
                repl.autoApproveClipboardVision = opts.auto
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
                    try? await bountyRegistry.complete(
                        providerId: coProvider, model: coModel,
                        messages: [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: user)],
                        settings: ModelSettings(temperature: 0.0, maxTokens: 700))
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
                    let spawner = SpecialistSpawner(
                        providers: registry, baseTools: tools, context: context,
                        sink: TerminalEventSink(showReasoning: false), interactor: terminalInteractor,
                        aliasTable: [:], roleDefault: ProviderBinding(providerId: providerId, model: model),
                        defaultMaxIterations: opts.maxIterations, extendedThinking: opts.extendedThinking)
                    return await spawner.run(specialist: def, task: task, approvalTools: approval, planMode: planMode).summary
                }
                repl.deferredInput = { await terminalInteractor.takeDeferredInput() }
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
                repl.briefCompiler = { input, roles, mode, transcript in
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
                                                                                      reviewTargets: reviewContext))
                }
                // Rebuilt on /model (new default provider+model) and /roles (new team). The default
                // binding drives the conversational turn AND the spawn-tool default; roles drive the team.
                repl.loopFactory = { defaultBinding, roles, planMode, showReasoning, extendedThinking in
                    makeLoop(registry: registry, providerId: defaultBinding.providerId, model: defaultBinding.model,
                             context: context,
                             tools: tools, checkpoints: checkpoints, maxIterations: opts.maxIterations,
                                    budget: opts.makeBudget(),
                             interactor: terminalInteractor, approvalTools: opts.yolo ? [] : sensitiveTools,
                             planMode: planMode, extendedThinking: extendedThinking, toolMode: toolMode, roles: roles,
                             delegationDepth: opts.delegationDepth, showReasoning: showReasoning,
                             sinkOverride: TerminalEventSink(showReasoning: showReasoning, style: .calm, proofStore: proofStore),
                             recorder: recorder,
                             traceRecorder: traceRecorder)
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
                    _ = await runFleet(o, registry: registry, root: root, tools: tools,
                                       providerId: providerId, model: model, rolesOverride: roles)
                }
                repl.planExecute = { g, roles in
                    var o = opts; o.goal = g; o.planExecute = true
                    // R1: ESC works on the plan-execute plane too — previously this plane was a
                    // dead zone (no watcher, no cancellation checks), exactly where big requests
                    // auto-escalate. The watcher cancels the runner task; PlanExecuteLoop and
                    // PlanExecutor stop cooperatively at phase/wave boundaries. Sequential with
                    // the chat turn's watcher (single-watcher invariant preserved).
                    _ = await InterruptibleTurn.run(onInterrupt: { reason in
                        print("\n\u{001B}[33m" + (reason == .cancel ? "⎋⎋ cancelled" : "⎋ interrupted")
                              + " — plan run stopped\u{001B}[0m")
                    }) {
                        await runPlanExecute(o, goal: g, registry: registry, root: root, tools: tools,
                                             context: context, providerId: providerId, model: model,
                                             rolesOverride: roles)
                    }
                }
                repl.council = { g, roles, execute in
                    // R1 sibling: council (and its execute=true hand-off into runPlanExecute) gets
                    // the same ESC watcher — top-level + sequential, single-watcher invariant holds.
                    // Coverage is partial (council's own model calls stop via provider cancellation);
                    // honest partial beats a dead zone.
                    _ = await InterruptibleTurn.run(onInterrupt: { reason in
                        print("\n\u{001B}[33m" + (reason == .cancel ? "⎋⎋ cancelled" : "⎋ interrupted")
                              + " — council run stopped\u{001B}[0m")
                    }) {
                        await runCouncil(opts, goal: g, execute: execute, registry: registry,
                                         root: root, tools: tools, context: context,
                                         providerId: providerId, model: model, rolesOverride: roles)
                    }
                }
                repl.research = { g, roles in
                    // R1 sibling: same watcher for the research pipeline.
                    _ = await InterruptibleTurn.run(onInterrupt: { reason in
                        print("\n\u{001B}[33m" + (reason == .cancel ? "⎋⎋ cancelled" : "⎋ interrupted")
                              + " — research run stopped\u{001B}[0m")
                    }) {
                        await runResearch(opts, goal: g, registry: registry, root: root,
                                          tools: tools, context: context,
                                          providerId: providerId, model: model,
                                          rolesOverride: roles)
                    }
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
                                 lessonStore: lessonStore, maxIterations: opts.maxIterations)
            Self.autoJournalRun(goal: goal, success: outcome.success, root: root, enabled: !opts.noMemory)
            print(KistREPL.renderSimpleSummary(projectRoot: root, spans: await traceRecorder.all(), trajectory: recorder.snapshot()))
            let grounding = GroundedReviewValidator.audit(outcome.summary, projectRoot: root)
            if !grounding.isGrounded { print(grounding.render(color: isatty(fileno(stdout)) != 0)) }
            printUsageDelta(from: [], to: await traceRecorder.all(), label: "usage", projectRoot: root)
            note("replay · kist --replay \(runReplay.manifest.runID)")
            if !outcome.success { note("paused — resume with: kist --resume \(outcome.checkpointId)") }
            return outcome.success ? 0 : 1
        }
    }

    // MARK: - Operator surface (health / bench / eval / protocols)

    private static func replayRun(projectRoot: String, id: String) -> Int32 {
        note(RunReplayStore.render(projectRoot: projectRoot, id: id))
        return 0
    }

    /// Live model-id preflight: GET /models per keyed provider, diff vs the catalog, flag dead ids.
    private static func providerDoctorReport(_ registry: ProviderRegistry) async -> String {
        let reports = await ProviderDoctor.check(
            providers: ProviderCatalog.openAICompatible,
            apiKey: { registry.apiKey(forProviderId: $0.id) },
            fetch: { url, key in await ProviderDoctor.liveFetch(modelsURL: url, apiKey: key) })
        return ProviderDoctor.render(reports)
    }

    private static func providerHealth(_ registry: ProviderRegistry, probe: Bool) async -> Int32 {
        let report: ProviderHealthReport
        if probe {
            let bindings = registry.providers.map { ProviderBinding(providerId: $0.id, model: $0.defaultModel) }
            report = await ProviderHealthChecker.liveProbe(registry, bindings: bindings)
        } else {
            report = ProviderHealthChecker.catalogReport(registry)
        }
        note(report.render())
        if probe, report.rows.contains(where: { $0.state == .staleCatalog }) {
            note("router · stale model detected; fallback is enabled for availability/model/key failures")
        }
        return report.rows.contains(where: { $0.state == .failed || $0.state == .staleCatalog }) ? 1 : 0
    }

    private static func protocolStatus(projectRoot: String) -> Int32 {
        note(protocolStatusText(projectRoot: projectRoot))
        let (_, issues) = MCPClientConfig.load(projectRoot: ToolContext.canonicalize(projectRoot) ?? projectRoot)
        return issues.isEmpty ? 0 : 1
    }

    private static func protocolStatusText(projectRoot: String) -> String {
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        let (servers, issues) = MCPClientConfig.load(projectRoot: root)
        var lines = ["protocols · \(root)"]
        lines.append("MCP · \(servers.count) configured server(s)" + (servers.contains { $0.name == "isolated-tester" } ? " · IsolatedTester app verification present" : ""))
        for server in servers.sorted(by: { $0.name < $1.name }) {
            lines.append("  ✓ \(server.name) · \(server.command) \(server.args.joined(separator: " "))")
        }
        for issue in issues {
            lines.append("  ! \(issue.server): \(issue.reason)")
        }
        lines.append("A2A · native agent-card/task schema ready · endpoint not exposed yet")
        lines.append("browser · first-class browse tool with SSRF entry-host guard")
        lines.append("computer_control · first-class approval-gated desktop/app control tool")
        return lines.joined(separator: "\n")
    }

    private struct BenchRow {
        let provider: String
        let model: String?
        let success: Bool
        let latencyMs: Int
        let toolFailures: Int
        let steps: Int
        let usage: UsageCostSummary
        let summary: String
    }

    private static func runBench(_ opts: KistOptions, goal: String, registry: ProviderRegistry,
                                 root: String, tools: ToolRegistry, context: ToolContext) async -> Int32 {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            err("usage: kist --bench \"<task>\"")
            return 2
        }
        let preferred = ["mimo", "deepseek", "gemini", "openai"]
        let candidates = preferred.compactMap { id -> (any ChatProvider)? in
            guard let p = registry.provider(id: id), registry.hasKey(for: p) else { return nil }
            return p
        }
        guard !candidates.isEmpty else {
            err("bench · no preferred providers have keys (wanted: \(preferred.joined(separator: ", ")))")
            return 2
        }
        note("bench · \(candidates.map(\.id).joined(separator: ", ")) · \(goal)")
        var rows: [BenchRow] = []
        for provider in candidates {
            let trajectory = TrajectoryRecorder()
            let trace = TraceRecorder(traceId: TraceID.make())
            let started = Date()
            let loop = makeLoop(registry: registry, providerId: provider.id, model: nil, context: context,
                                tools: tools, checkpoints: LoopCheckpointStore(), maxIterations: opts.maxIterations,
                                budget: opts.makeBudget(),
                                interactor: AutoApproveInteractor(), approvalTools: [],
                                planMode: opts.planMode, extendedThinking: opts.extendedThinking, toolMode: ToolMode(rawValue: opts.toolMode) ?? .auto,
                                roles: RoleBindings(default: ProviderBinding(providerId: provider.id)),
                                delegationDepth: 0, sinkOverride: NullEventSink(),
                                recorder: trajectory, traceRecorder: trace,
                                traceRole: "bench")
            let outcome = await loop.run(goal: goal)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            let steps = trajectory.snapshot()
            let spans = await trace.all()
            let usage = UsageCost.summarize(spans: spans)
            rows.append(BenchRow(provider: provider.id, model: provider.defaultModel,
                                 success: outcome.success, latencyMs: latency,
                                 toolFailures: steps.filter { !$0.success }.count,
                                 steps: steps.count, usage: usage,
                                 summary: outcome.summary))
        }
        note(renderBench(rows))
        return rows.contains(where: \.success) ? 0 : 1
    }

    private static func renderBench(_ rows: [BenchRow]) -> String {
        var out = "bench result\n"
        out += "| Provider | Result | Latency | Steps | Tool failures | Usage |\n"
        out += "| --- | --- | ---: | ---: | ---: | --- |\n"
        for row in rows {
            let result = row.success ? "pass" : "fail"
            out += "| \(row.provider) | \(result) | \(row.latencyMs)ms | \(row.steps) | \(row.toolFailures) | \(row.usage.render(label: "").trimmingCharacters(in: .whitespaces)) |\n"
        }
        out += "\nproof metrics · success, latency, tool failures, token/cost estimate. Run this across 20 real tasks and 3 role profiles before claiming production maturity."
        return out
    }

    private static func runEval(_ opts: KistOptions, goal: String, registry: ProviderRegistry,
                                root: String, tools: ToolRegistry, context: ToolContext,
                                providerId: String, model: String?) async -> Int32 {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            err("usage: kist --eval \"<task>\"")
            return 2
        }
        let trace = TraceRecorder(traceId: TraceID.make())
        let runner = EvalRunner(maxIterations: opts.maxIterations)
        let report = await runner.run([
            EvalCase(name: "agent-behavior", prompt: goal,
                     assertions: [.trajectoryHealthy, .maxSteps(opts.maxIterations), .noToolFailures])
        ], agent: { prompt in
            let trajectory = TrajectoryRecorder()
            let loop = makeLoop(registry: registry, providerId: providerId, model: model, context: context,
                                tools: tools, checkpoints: LoopCheckpointStore(), maxIterations: opts.maxIterations,
                                budget: opts.makeBudget(),
                                interactor: AutoApproveInteractor(), approvalTools: [],
                                planMode: opts.planMode, extendedThinking: opts.extendedThinking, toolMode: ToolMode(rawValue: opts.toolMode) ?? .auto,
                                roles: RoleBindings(default: ProviderBinding(providerId: providerId, model: model)),
                                delegationDepth: 0, sinkOverride: TerminalEventSink(),
                                recorder: trajectory, traceRecorder: trace,
                                traceRole: "eval")
            let outcome = await loop.run(goal: prompt)
            return EvalRunner.RunOutcome(output: outcome.summary, trajectory: trajectory.snapshot())
        })
        note(report.render())
        printUsageDelta(from: [], to: await trace.all(), label: "eval usage", projectRoot: root)
        return report.allPassed ? 0 : 1
    }

    private static func printUsageDelta(from before: [AgentSpan], to after: [AgentSpan],
                                        label: String, projectRoot: String? = nil) {
        let oldIds = Set(before.map(\.id))
        let delta = after.filter { !oldIds.contains($0.id) }
        if let projectRoot, !UsageLedger.append(projectRoot: projectRoot, spans: delta) {
            note("usage ledger warning · could not persist local usage accounting")
        }
        let summary = UsageCost.summarize(spans: delta)
        guard summary.tokens > 0 else { return }
        note(summary.render(label: label))
    }

    // MARK: - Great-loop (long-horizon: self-assess · learn · escalate · team-review · safety-railed)

    /// Threads a cycle's team-review feedback into the next cycle (locked — the runCycle closure is @Sendable).
    private final class FeedbackBox: @unchecked Sendable {
        private let lock = NSLock(); private var v = ""
        var value: String { lock.lock(); defer { lock.unlock() }; return v }
        func set(_ s: String) { lock.lock(); v = s; lock.unlock() }
    }

    /// Providers that server-faulted — the escalator routes around them (fault tolerance). COOLDOWN, not
    /// permanent: a provider is excluded only for `cooldown` seconds after its last fault, so a transient
    /// blip on cycle 2 of a 20h run doesn't narrow the escalation pool for the remaining 18 hours — the
    /// next cycle after the window IS the half-open probe (a 5-model review flagged permanent exclusion).
    private final class ProviderErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tracker = ProviderCooldownTracker()   // pure cooldown logic (unit-tested in AgentCore)
        func insert(_ p: String, at now: Double) { lock.lock(); tracker.recordFault(p, at: now); lock.unlock() }
        func active(now: Double) -> Set<String> { lock.lock(); defer { lock.unlock() }; return tracker.active(now: now) }
    }

    private static func runGreatLoop(_ opts: KistOptions, goal: String, registry: ProviderRegistry, root: String,
                                     tools: ToolRegistry, context: ToolContext, checkpoints: LoopCheckpointStore,
                                     toolMode: ToolMode, roles: RoleBindings, providerId: String, model: String?) async -> Int32 {
        // LEAN TOOL SET: the full registry can be ~70 tools / ~25k schema chars (~6.5k tokens) — sent on
        // EVERY model call. On a coding loop that's dead weight (media, app-UI-testing, desktop control,
        // pentest, enterprise reporting) that ate ~half a cycle's budget, so cycles couldn't converge.
        // Drop the coding-irrelevant tools; file/shell/lsp/memory/web/research stay.
        let loopTools = ToolRegistry(tools.all().filter { !Self.isLoopIrrelevantTool($0.name) })
        if loopTools.all().count < tools.all().count {
            note("  · lean tool set: \(loopTools.all().count)/\(tools.all().count) tools (dropped coding-irrelevant schemas)")
        }
        let deadline: Double? = opts.loopHours.map { Date().timeIntervalSince1970 + $0 * 3600 }
        // SAFETY: an unattended --loop must ALWAYS have a token/$ ceiling. If --budget wasn't given, default
        // to a bounded cap (panel finding: model escalation with no cap could burn unbounded $ over 20h).
        let defaultTokenCap = 2_000_000
        let caps = GreatLoopCaps(maxCycles: opts.maxCycles ?? 20, maxTokens: opts.budgetTokens ?? defaultTokenCap,
                                 deadlineEpoch: deadline, noProgressLimit: 3,
                                 noDestructive: !opts.yolo, noAutoMerge: true)
        if opts.budgetTokens == nil { note("  · no --budget given → default token ceiling \(defaultTokenCap) (pass --budget to change)") }
        note("kist · great-loop · \(providerId)\(model.map { " (\($0))" } ?? "") · \(root) · caps[cycles:\(caps.maxCycles)"
             + (caps.maxTokens.map { ", tokens:\($0)" } ?? "") + (opts.loopHours.map { ", \($0)h" } ?? "") + "]")
        let memory = EffortMemory(projectRoot: root)
        let traceRecorder = TraceRecorder(traceId: TraceID.make())
        let delegationDepth = opts.delegationDepth
        // Provider ids that actually have a usable key — candidates for model escalation.
        let keyed = registry.providers.filter { registry.hasKey(for: $0) }.map { $0.id }
        let feedback = FeedbackBox()
        // Fault tolerance: providers that server-errored this run get routed around by the escalator, so a
        // single flaky provider (e.g. a 500-storm) can't tank every cycle of a 20h loop (live dogfood: an
        // escalated model 500'd on all 4 cycles and the loop never completed).
        let erroredProviders = ProviderErrorBox()
        // Durable, verification-gated learning across cycles AND runs (Phase 1).
        let lessons: LessonStore? = opts.noMemory ? nil : LessonStore()
        // GEPA-style evolving policy hints, best-per-signature Pareto frontier (Phase 2).
        let policy: PolicyStore? = opts.noMemory ? nil : PolicyStore(projectRoot: root)
        // Gated DGM bridge: proven hints → reviewable promotion queue, NEVER auto-applied (Phase 2.2).
        let promotions: PromotionCandidateStore? = opts.noMemory ? nil : PromotionCandidateStore(projectRoot: root)

        // ONE work cycle: escalate the model when the task is hard, size the budget so it can't starve the
        // loop, run the goal (carrying any prior team-review feedback), then — if not done but progressing and
        // the effort calls for a team — have a SECOND mind review the diff and thread that into the next cycle.
        let runCycle: @Sendable (String, EffortController.Assessment, Int, Int?) async -> CycleResult = { baseGoal, effort, cycleIndex, budgetRemaining in
            let nowEpoch = Date().timeIntervalSince1970
            let cycleProvider = ModelEscalator.pick(tier: effort.modelTier, keyed: keyed, preferred: providerId,
                                                    exclude: erroredProviders.active(now: nowEpoch))
            let cycleModel: String? = cycleProvider == providerId ? model : nil
            if cycleProvider != providerId { note("  ↑ escalating this cycle → \(cycleProvider) (tier \(effort.modelTier.rawValue))") }
            // Snapshot the provider's retry tally so we can measure FLAKINESS over this cycle: a provider
            // whose 5xx are absorbed by catalog retries never surfaces a terminal fault, but if it needed
            // many retries AND the cycle still failed, it's degrading — route around it like a hard fault.
            let retriesBefore = registry.retryCount(providerId: cycleProvider)
            // Per-cycle budget: an even share of what REMAINS among the cycles LEFT — not a rigid
            // total/maxCycles. Cycle 0 still gets ~remaining/maxCycles (so no single early cycle eats
            // everything — the captain over-spend guard), but early cheap cycles leave more for later, and
            // the LAST cycle can spend everything still unspent. The old fixed fair-share STARVED a cycle:
            // it died mid-work (create files, then no budget left to build/test) and the next cycle restarted
            // from scratch — a trivial task never converged. (dogfood: 200k/2-cycle died pre-build every time.)
            let perCycle = budgetRemaining.map { Self.perCycleBudget(remaining: $0, cycleIndex: cycleIndex,
                                                                     maxCycles: caps.maxCycles) }
            // Inject durable lessons (past cycles + past runs) + the evolved policy hint for this task type.
            let sig = EffortController.signature(for: baseGoal)
            let primer = lessons?.primer(forGoal: baseGoal)
            let policyHint = policy?.bestHint(forSignature: sig)
            let repoMap = RepoMap.build(projectRoot: root, goal: baseGoal)   // orientation: files → symbols
            let sessionMem = Self.sessionMemory(root: root, opts: opts)       // cortex + project memory
            let fb = feedback.value
            // FENCE the user's task in the scope-source markers so AuthorizationScopeEngine classifies ONLY
            // the task — NOT the injected memory/repo-map below. (Live-run bug: cortex memory containing
            // "Production" made a plain create-task misfire as read-only serverDiagnostics, blocking all writes.)
            var cycleGoal = PromptCompiler.scopeSourceStart + "\n" + baseGoal + "\n" + PromptCompiler.scopeSourceEnd
            // CONTINUITY across cycles: each cycle is a fresh conversation, so without this the model has
            // amnesia — it re-creates work a prior cycle already did (live dogfood: it built the package at
            // ./ in one cycle, then RE-created it under ./MathKit/ in the next → duplication, never converged).
            // Show the files prior cycles already changed and tell it to CONTINUE, not restart.
            let priorFiles = KistREPL.workingTreeChangedFiles(projectRoot: root)
            if let note = Self.continuityNote(cycleIndex: cycleIndex, changedFiles: priorFiles) {
                cycleGoal += "\n\n" + note
            }
            if let sessionMem, !sessionMem.isEmpty { cycleGoal += "\n\nMEMORY — what kist knows about you & this project:\n" + sessionMem }
            if !repoMap.isEmpty { cycleGoal += "\n\n" + repoMap }
            if let primer, !primer.isEmpty { cycleGoal += "\n\n" + primer }
            if let policyHint, !policyHint.isEmpty { cycleGoal += "\n\nLEARNED POLICY — " + policyHint }
            if !fb.isEmpty { cycleGoal += "\n\nPRIOR CYCLE — fix these before finishing:\n" + fb }

            let recorder = TrajectoryRecorder()
            let think = effort.thinking != .none
            let before = await traceRecorder.all()

            // BEST-OF-N (Phase 3.1 exec): on a HARD cycle with a CLEAN tree, try N independent attempts in
            // ISOLATED worktrees and apply the first VERIFIED winner to the live tree. WorktreeBestOfN never
            // touches the live tree except a clean winner-apply (dry-run --check'd); any failure / no-winner /
            // dirty-tree leaves it untouched → fall through to a normal in-tree cycle.
            if effort.searchWidth > 1, WorktreeBestOfN.isCleanTree(root) {
                note("  ⑃ best-of-\(effort.searchWidth) · isolated worktrees")
                let attemptBudget = perCycle.map { max(20_000, $0 / effort.searchWidth) }
                let won = await WorktreeBestOfN.run(root: root, width: effort.searchWidth, nowEpoch: Date().timeIntervalSince1970) { wtPath, _ in
                    let wtCtx = ToolContext(projectRoot: wtPath, shell: context.shell, sandbox: context.sandbox,
                                            externalReadRoots: context.externalReadRoots)
                    let rec = TrajectoryRecorder()
                    let wtLoop = makeLoop(registry: registry, providerId: cycleProvider, model: cycleModel, context: wtCtx,
                                          tools: loopTools, checkpoints: checkpoints, maxIterations: effort.iterationBudget,
                                          // --max-cost in --loop: SAFE fixed fair-share USD subdivision per
                                          // attempt (maxCostUSD / (maxCycles × searchWidth)) — the total across
                                          // all cycles×attempts can never exceed the cap (Codex: was ignored here).
                                          budget: attemptBudget.map { BudgetLedger(maxTokens: $0, maxUSD: opts.maxCostUSD.map { $0 / Double(max(1, caps.maxCycles * effort.searchWidth)) }) },
                                          interactor: caps.noDestructive ? NonDestructiveInteractor() : AutoApproveInteractor(),
                                          planMode: false, extendedThinking: think, toolMode: toolMode, roles: roles,
                                          delegationDepth: delegationDepth, showReasoning: false,
                                          sinkOverride: TerminalEventSink(showReasoning: false, style: .calm),
                                          recorder: rec, traceRecorder: traceRecorder)
                    let oc = await wtLoop.run(goal: cycleGoal)
                    let traj = rec.snapshot()
                    let v = GreatLoopVerifier.verify(trajectory: traj, canRunCommands: context.shell.enabled,
                                                     changedFiles: KistREPL.workingTreeChangedFiles(projectRoot: wtPath),
                                                     diff: KistREPL.workingTreeDiff(projectRoot: wtPath))
                    let g = GroundedReviewValidator.audit(oc.summary, projectRoot: wtPath).isGrounded
                    return (verified: oc.success && g && v.isVerified,
                            quality: EffortScorer.quality(success: true, verified: true, failureRate: 0,
                                                          iterationsUsed: traj.count, iterationBudget: effort.iterationBudget))
                }
                if won {
                    note("  ✓ best-of-N: a verified independent attempt was applied to the tree")
                    let delta = (await traceRecorder.all()).filter { s in !before.contains(where: { $0.id == s.id }) }
                    lessons?.record(CycleReflection.lesson(goal: baseGoal, done: true, verdictReason: "verified",
                                                           reviewGist: nil, summary: "best-of-N: a verified independent attempt was applied",
                                                           failureRate: 0, at: Date().timeIntervalSince1970))
                    return CycleResult(doneAndVerified: true, tokensSpent: UsageCost.summarize(spans: delta).tokens,
                                       madeProgress: true, signals: EffortController.Signals(),
                                       summary: "best-of-N verified winner applied")
                }
                note("  · no best-of-N winner — running a normal in-tree cycle")
            }

            let loop = makeLoop(registry: registry, providerId: cycleProvider, model: cycleModel, context: context,
                                tools: loopTools, checkpoints: checkpoints, maxIterations: effort.iterationBudget,
                                // --max-cost in --loop: SAFE per-cycle USD fair share (maxCostUSD / maxCycles);
                                // sum across cycles ≤ the cap (Codex: was ignored here).
                                budget: perCycle.map { BudgetLedger(maxTokens: $0, maxUSD: opts.maxCostUSD.map { $0 / Double(max(1, caps.maxCycles)) }) },
                                // ENFORCE noDestructive: an unattended --loop (no --yolo) refuses irreversible
                                // ops (rm -rf/force-push/deploy) while still running build/test/edit.
                                interactor: caps.noDestructive ? NonDestructiveInteractor() : AutoApproveInteractor(),
                                planMode: false, extendedThinking: think, toolMode: toolMode, roles: roles,
                                delegationDepth: delegationDepth, showReasoning: false,
                                sinkOverride: TerminalEventSink(showReasoning: false, style: .calm),
                                recorder: recorder, traceRecorder: traceRecorder)
            let outcome = await loop.run(goal: cycleGoal)
            // Fault detection: if the cycle failed because the PROVIDER faulted server-side, mark it so the
            // escalator routes around it (within the cooldown window). PRIMARY signal is the STRUCTURED flag
            // the loop set from the typed error. FALLBACK (only on a FAILED cycle, where the summary IS the
            // provider error reason — not agent content): the string classifier, for error shapes that don't
            // reach the loop as a typed AIProviderError (live dogfood: a gemini 5xx surfaced this way and the
            // structured flag missed it). No provider==default guard: if the DEFAULT is broken, record it too
            // — pick() falls back to it only when there's no healthy alternative (single-provider not stranded).
            // FLAKINESS: retries this cycle that the catalog absorbed. If the provider needed several AND the
            // cycle didn't complete, treat it as a fault (the live gemini case: intermittent 5xx recovered by
            // retries burned the budget without ever surfacing a terminal fault, so route-around never fired).
            let retriesThisCycle = registry.retryCount(providerId: cycleProvider) - retriesBefore
            let flaky = retriesThisCycle >= 3
            let faulted = outcome.providerFault
                || (!outcome.success && ProviderFault.fromSummary(outcome.summary))
                || (!outcome.success && flaky)
            if faulted {
                erroredProviders.insert(cycleProvider, at: nowEpoch)
                let why = outcome.providerFault ? "server-faulted"
                    : (retriesThisCycle >= 3 ? "flaky (\(retriesThisCycle) retries)" : "server-faulted")
                note("  ⚠ \(cycleProvider) \(why) — routing around it (cooldown)")
            }
            let trajectory = recorder.snapshot()
            let report = TrajectoryAnalyzer.analyze(trajectory)
            let failures = trajectory.filter { !$0.success }.count
            let failureRate = trajectory.isEmpty ? 0 : Double(failures) / Double(trajectory.count)
            let after = await traceRecorder.all()
            let delta = after.filter { s in !before.contains(where: { $0.id == s.id }) }
            let grounded = GroundedReviewValidator.audit(outcome.summary, projectRoot: root).isGrounded
            let workDiff = KistREPL.workingTreeDiff(projectRoot: root)
            let workChanged = KistREPL.workingTreeChangedFiles(projectRoot: root)
            // PHASE 0 — anti-Goodhart done-gate: a claimed done is only real if it's execution-grounded
            // (a real build/test passed after the edits) AND didn't game the verifier (no deleted/skipped
            // tests, no `|| true`). Model say-so is never enough over a 20h run.
            let verdict = GreatLoopVerifier.verify(trajectory: trajectory, canRunCommands: context.shell.enabled,
                                                   changedFiles: workChanged, diff: workDiff)
            let done = outcome.success && grounded && verdict.isVerified
            if outcome.success, !verdict.isVerified { note("  ⨯ done REJECTED by verifier · \(verdict.reason)") }
            let progressed = trajectory.contains { $0.success }

            // Thread forward what the NEXT cycle must fix: the verifier's rejection (if any) + a second-mind
            // team review of the diff. Cleared once the goal is genuinely done+verified.
            var reviewText: String? = nil
            if done {
                feedback.set("")
            } else {
                var notes: [String] = []
                if outcome.success, !verdict.isVerified {
                    notes.append("Your 'done' was REJECTED: \(verdict.reason). A REAL build/test must pass after your edits, and you may NOT weaken/skip/delete tests to make it green.")
                }
                // Carry the LAST build/test error forward so the next cycle fixes THIS error instead of
                // rediscovering it (dogfood: a test naming-collision compile error was lost each cycle).
                if let failure = Self.lastCommandFailure(in: trajectory) {
                    notes.append("The last build/test command FAILED with this error — fix it directly (do NOT "
                        + "assume the tool is broken; run_command works — you ran commands successfully this run):\n" + failure)
                }
                if progressed, effort.team != .solo,
                   !workDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let reviewer = ModelEscalator.pick(tier: .frontier, keyed: keyed, preferred: cycleProvider,
                                                       exclude: erroredProviders.active(now: nowEpoch))
                    note("  ⎇ team review · \(reviewer)")
                    if let review = try? await registry.complete(
                        providerId: reviewer, model: nil,
                        messages: [ChatMessage(role: .system, content: Copilot.reviewSystemPrompt),
                                   ChatMessage(role: .user, content: Copilot.reviewPrompt(task: baseGoal, diff: workDiff))],
                        settings: ModelSettings(temperature: 0.0, maxTokens: 700)),
                       !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        reviewText = review
                        notes.append("Team review of your changes:\n" + review)
                    }
                }
                feedback.set(notes.joined(separator: "\n\n"))
            }

            // LEARN durably: a verification-gated structured lesson (PROVEN only if done+verified).
            let now = Date().timeIntervalSince1970
            lessons?.record(CycleReflection.lesson(goal: baseGoal, done: done, verdictReason: verdict.reason,
                                                   reviewGist: reviewText, summary: outcome.summary,
                                                   failureRate: failureRate, at: now))
            // EVOLVE the policy: score the hint we ran under (win = verified done, grounded by Phase 0) and
            // let this cycle's review seed the next candidate hint for this signature.
            policy?.record(signature: sig, activeHint: policyHint, won: done, review: reviewText, at: now)
            // GATED DGM bridge: once a hint proves itself (enough verified wins at a high rate), QUEUE it for
            // human/DGM review — NEVER auto-applied to Mythos's own prompts (the self-modification line).
            if let best = policy?.bestCandidate(forSignature: sig),
               PromotionGate.qualifies(wins: best.wins, trials: best.trials),
               promotions?.export(PromotionCandidate(signature: sig, hint: best.hint, wins: best.wins,
                                                      trials: best.trials, at: now)) == true {
                note("  ⤴ policy proven (\(best.wins)/\(best.trials)) — queued for review (never auto-applied)")
            }

            return CycleResult(doneAndVerified: done, tokensSpent: UsageCost.summarize(spans: delta).tokens,
                               madeProgress: progressed,
                               signals: .init(failureRate: failureRate, iterationsUsed: trajectory.count, isStuck: !report.healthy),
                               summary: outcome.summary, providerFault: outcome.providerFault)
        }

        let runner = GreatLoopRunner(goal: goal, caps: caps, memory: memory,
                                     clock: { Date().timeIntervalSince1970 },
                                     runCycle: runCycle, emit: { note($0) })
        let decision = await runner.run()
        printUsageDelta(from: [], to: await traceRecorder.all(), label: "great-loop usage", projectRoot: root)
        return decision.succeeded ? 0 : 1
    }

    // MARK: - Council (agent conference -> kanban -> optional builder handoff)

    private static func runResearch(_ opts: KistOptions, goal: String,
                                    registry: ProviderRegistry, root: String,
                                    tools: ToolRegistry, context: ToolContext,
                                    providerId: String, model: String?,
                                    rolesOverride: RoleBindings? = nil) async -> Int32 {
        note("kist · research · \(root)")
        let start = await tools.execute(name: "research_run",
                                        arguments: ["action": "start", "goal": goal],
                                        context: context)
        guard start.success, let runID = start.metadata["run_id"] else {
            err("research · failed to start: \(start.error ?? start.output)")
            return 1
        }
        note("research · run \(runID)")

        let search = await tools.execute(name: "research_run",
                                         arguments: ["action": "search", "run_id": runID,
                                                     "query": goal, "limit": 5],
                                         context: context)
        if !search.success { note("research · web search blocked · \(search.error ?? search.output)") }

        let repo = await tools.execute(name: "research_run",
                                       arguments: ["action": "context", "run_id": runID,
                                                   "query": goal, "limit": 8],
                                       context: context)
        if !repo.success { note("research · repo context blocked · \(repo.error ?? repo.output)") }

        let synth = await tools.execute(name: "research_run",
                                        arguments: ["action": "synthesize", "run_id": runID],
                                        context: context)
        guard synth.success else {
            err("research · failed to synthesize: \(synth.error ?? synth.output)")
            return 1
        }
        if let report = synth.metadata["report"] { note("research · dossier saved · \(report)") }

        return await runCouncil(opts, goal: goal, execute: opts.councilExecute,
                                registry: registry, root: root, tools: tools, context: context,
                                providerId: providerId, model: model, rolesOverride: rolesOverride,
                                researchDossier: synth.output, researchRunID: runID)
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
        print(CouncilCard.render(result, artifactPath: path, color: isatty(fileno(stdout)) != 0))
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
                                    model: model, rolesOverride: roles, budgetOverride: runBudget)
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

    /// Build the role team (planner/coder/critic), falling back to the chosen provider. nil after an error.
    static func resolveRoles(_ opts: KistOptions, _ registry: ProviderRegistry,
                                     providerId: String, model: String?) -> RoleBindings? {
        var selection = KistREPL.RoleSelection(default: ProviderBinding(providerId: providerId, model: model))
        guard applyProfileAndRoleFlags(opts, to: &selection, knownProviders: providerAliases(for: registry)) else { return nil }
        return selection.bindings
    }

    private static func applyProfileAndRoleFlags(_ opts: KistOptions, to selection: inout KistREPL.RoleSelection,
                                                 knownProviders: [String: String]) -> Bool {
        if let profileName = opts.roleProfile {
            do {
                let profile = try RoleProfileStore().profile(named: profileName)
                if let error = selection.apply(profile, knownProviders: knownProviders) {
                    err("error: \(error). Try --list-providers."); return false
                }
            } catch {
                err("error: \(error)"); return false
            }
        }

        for (spec, role): (String?, AgentRole) in [
            (opts.plannerSpec, .planner),
            (opts.workerSpec, .worker),
            (opts.coderSpec, .coder),
            (opts.criticSpec, .critic),
        ] {
            if let error = selection.assignSpec(spec, to: role, knownProviders: knownProviders) {
                err("error: \(error). Try --list-providers."); return false
            }
        }

        if let error = selection.validationError(knownProviders: knownProviders) {
            err("error: \(error). Try --list-providers."); return false
        }
        selection.canonicalizeProviders(knownProviders: knownProviders)
        return true
    }

    private static func providerAliases(for registry: ProviderRegistry) -> [String: String] {
        var aliases: [String: String] = [:]
        for provider in registry.providers {
            aliases[provider.id.lowercased()] = provider.id
            aliases[provider.name.lowercased()] = provider.id
        }
        return aliases
    }

    private static func firstVisionBinding(_ registry: ProviderRegistry) -> ProviderBinding? {
        // Prefer Gemini for image/PDF inspection because it already backs video/audio and files.
        if let g = registry.provider(id: "gemini"), registry.hasKey(for: g),
           let model = g.availableModels.first(where: { $0.isVision })?.id {
            return ProviderBinding(providerId: g.id, model: model)
        }
        for provider in registry.providers where registry.hasKey(for: provider) {
            if let model = provider.availableModels.first(where: { $0.isVision })?.id {
                return ProviderBinding(providerId: provider.id, model: model)
            }
        }
        return nil
    }

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

    private static func recordRuntimeLessons(goal: String, success: Bool, recorder: TrajectoryRecorder,
                                             lessonStore: LessonStore?, maxIterations: Int) {
        let report = TrajectoryAnalyzer.analyze(recorder.snapshot(), maxIterations: maxIterations)
        if !report.healthy { note("⚙ self-check · " + report.issues.map { $0.kind.rawValue }.joined(separator: ", ")) }
        guard let lessonStore else { return }
        let at = Date().timeIntervalSince1970
        for issue in report.issues {
            lessonStore.record(Lesson(kind: .obstacle,
                                      text: "\(issue.kind.rawValue): \(issue.detail) [goal: \(goal.prefix(80))]",
                                      source: nil, at: at))
        }
        if !success {
            lessonStore.record(Lesson(kind: .obstacle, text: "task failed: \(goal.prefix(120))", source: nil, at: at))
        }
    }

    /// Run a plan→execute: the planner emits a typed DAG, you approve it (unless --yolo), then the team
    /// builds it. Shared by the `--plan-execute` one-shot and the REPL's `/plan-execute` escalation.
    private static func runPlanExecute(_ opts: KistOptions, goal: String, registry: ProviderRegistry,
                                       root: String, tools: ToolRegistry, context: ToolContext,
                                       providerId: String, model: String?,
                                       rolesOverride: RoleBindings? = nil,
                                       budgetOverride: BudgetLedger? = nil) async -> Int32 {
        guard let roles = rolesOverride ?? resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }
        let memory = opts.noMemory ? nil : ProjectMemory(root: root)
        let memNote = (memory?.hasContent ?? false) ? " · memory \(memory!.recentEpisodes(limit: 100).count) runs" : ""
        note("kist · plan→execute · \(roles.summary) · \(root)\(roles.isHeterogeneous ? " · team" : "")\(opts.budgetTokens.map { " · budget \($0)" } ?? "")\(memNote)")
        // CAPTAIN SAFETY GATES (preserved across the origin/main merge): both must accept before any side
        // effect. Pinned by KistRunnerSafetyTests. Fail-closed. c7 splice: --no-memory is threaded to the
        // simulation gate so it suppresses the .kist disk write while still computing + enforcing the verdict.
        let domainPreflight = CaptainDomainLearningEnforcer.preflight(mode: .planExecute,
                                                                      objective: goal,
                                                                      projectRoot: root,
                                                                      evidenceMode: opts.noMemory ? .redacted : .full)
        for line in domainPreflight.terminalLines { note(line) }
        guard domainPreflight.canExecute else {
            err("captain refused to execute: domain-learning gate did not accept this plan.")
            return 1
        }
        let planPreflight = CaptainSimulationEnforcer.preflight(mode: .planExecute,
                                                                objective: goal,
                                                                projectRoot: root,
                                                                evidenceMode: opts.noMemory ? .redacted : .full,
                                                                noMemory: opts.noMemory)
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
        let pxl = PlanExecuteLoop(providers: registry, roles: roles, tools: tools, context: context,
                                  sink: TerminalEventSink(style: .calm, proofStore: proofStore),
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

    // MARK: - MCP lifecycle

    /// Build the tool registry = built-in headless tools + any external MCP server tools, run
    /// `body`, then guarantee MCP servers are shut down (no zombies). MCP is opt-in via config
    /// (`~/.mcp.json` etc.); with none configured this is just the headless tool set.
    private static func withTools(projectRoot: String,
                                  fetchAllowedHosts: [String],
                                  extraTools: [any AgentTool] = [],
                                  enableComputerUse: Bool = false,
                                  _ body: (ToolRegistry) async -> Int32) async -> Int32 {
        let mcp = MCPClientManager()
        let discovered = await mcp.discoverAndWrapTools(projectRoot: projectRoot)
        // Gate host-control (desktop actuation / screen capture) MCP tools behind --enable-computer-use, so a
        // user-configured desktop MCP can't drive the machine on an unarmed surface (council 2026-07-03).
        // Targeted by verb, so non-desktop MCP servers (github, db, filesystem) keep working unarmed.
        let mcpTools = enableComputerUse ? discovered
            : discovered.filter { !ReversibilityClassifier.isHostControlMCPTool($0.name) }
        if discovered.count != mcpTools.count {
            note("mcp · dropped \(discovered.count - mcpTools.count) host-control tool(s) — pass --enable-computer-use to allow")
        }
        if !mcpTools.isEmpty, ProcessInfo.processInfo.environment["KIST_VERBOSE"] == "1" {
            note("mcp · \(mcpTools.count) tool(s) from external servers")
        }
        var base: [any AgentTool] = ToolRegistry.headless().all()
        base.append(WebFetchTool(allowedHosts: fetchAllowedHosts))     // SSRF-guarded web read, optional host allowlist
        base.append(WebSearchTool())                                   // source discovery for deep research
        base.append(ResearchRunTool(allowedHosts: fetchAllowedHosts))   // durable evidence-first research dossier
        // ComputerControlTool (app launcher open_app/url — local OS automation that bypasses the sandbox) and
        // DesktopControlTool (THE HANDS — real mouse/keyboard injection) are NOT added here. Both are host-
        // control, registered ONLY under --enable-computer-use via the DEFAULT-DENY block in buildExtraTools
        // (council 2026-07-03), so neither can be present on an unarmed autonomous surface.
        base.append(PentestTool())                                    // authorized security testing (allowlist + approval + audit; REPL-only, not headless/mcp)
        base.append(contentsOf: extraTools)                            // media/data understanding tools
        base.append(contentsOf: mcpTools.map { $0 as any AgentTool })
        let code = await body(ToolRegistry(base))
        await mcp.shutdownAll()
        return code
    }

    // MARK: - Helpers

    private static func makeLoop(registry: ProviderRegistry, providerId: String, model: String?,
                                 context: ToolContext, tools: ToolRegistry, checkpoints: LoopCheckpointStore,
                                 maxIterations: Int,
                                 budget: BudgetLedger? = nil,
                                 interactor: RuntimeInteractor = AutoApproveInteractor(),
                                 approvalTools: Set<String> = [],
                                 planMode: Bool = false,
                                 extendedThinking: Bool = false,
                                 toolMode: ToolMode = .auto,
                                 roles: RoleBindings? = nil,
                                 delegationDepth: Int = 1,
                                 showReasoning: Bool = false,
                                 sinkOverride: RuntimeEventSink? = nil,
                                 recorder: TrajectoryRecorder? = nil,
                                 traceRecorder: TraceRecorder? = nil,
                                 traceRole: String? = "assistant") -> HeadlessAgentLoop {
        // The main agent gets `spawn_agent` for delegation; spawned agents receive it only while
        // the bounded delegation-depth budget remains, so teammates can help without runaway trees.
        // The SAME budget ledger is shared with spawn so the whole delegation tree draws one cap.
        let terminalSink: RuntimeEventSink = sinkOverride ?? TerminalEventSink(showReasoning: showReasoning)
        let spawn = SpawnAgentTool(providers: registry, providerId: providerId, model: model,
                                   roles: roles,
                                   baseTools: tools, sink: terminalSink,
                                   interactor: interactor, approvalTools: approvalTools,
                                   maxIterations: maxIterations,
                                   delegationDepth: delegationDepth,
                                   extendedThinking: extendedThinking,
                                   budget: budget)
        // PROACTIVE specialist delegation: give the main agent `spawn_specialist` so it can hand a
        // matching subtask to a named specialist (Claude-exact — the model reads their descriptions and
        // delegates). Ceiling is `tools` (no spawn_* → a specialist can't recursively fan out). Only added
        // when specialists exist, so the roster is never empty in the tool description.
        let specialists = SpecialistRegistry(projectRoot: context.projectRoot).load()
        var extraTools: [any AgentTool] = [spawn]
        if !specialists.isEmpty {
            let specSpawner = SpecialistSpawner(
                providers: registry, baseTools: tools, context: context,
                sink: terminalSink, interactor: interactor,
                aliasTable: [:], roleDefault: ProviderBinding(providerId: providerId, model: model),
                defaultMaxIterations: maxIterations, extendedThinking: extendedThinking, budget: budget)
            // SECURITY (Codex HIGH): a proactively-spawned specialist is pinned to the canonical NORMAL
            // approval floor (`Self.sensitiveTools`), NOT the loop's `approvalTools` param. The param is []
            // under --yolo and is captured once at construction, so using it would let a --yolo-launched
            // session that later TIGHTENS still spawn guards-off children (escalation). The constant normal
            // floor can never be escalated below: a delegated specialist always re-asserts sensitive-tool
            // approvals — even in --yolo, where the main agent stays guards-off but a spawned sub-agent does
            // not inherit that. Child ≥ parent restrictiveness in every session state.
            extraTools.append(SpawnSpecialistTool(specialists: specialists, spawner: specSpawner,
                                                  approvalTools: Self.sensitiveTools))
        }
        let mainTools = ToolRegistry(tools.all() + extraTools)
        // Lifecycle hooks (kist-modularized security fix): user-level (~/.kist/hooks.json) always load;
        // the WORKSPACE-local <root>/.kist/hooks.json is opt-in (KIST_TRUST_PROJECT_HOOKS=1) because a
        // hostile cloned repo could ship one and hooks run as /bin/sh — auto-loading it is an
        // untrusted-workspace RCE (same guard MCPClientConfig applies to .mcp.json).
        let allowProjectHooks = ProcessInfo.processInfo.environment["KIST_TRUST_PROJECT_HOOKS"] == "1"
        let (hooks, projectHooksRefused) = AgentHooks.loadTrusted(
            projectRoot: context.projectRoot, allowProjectHooks: allowProjectHooks)
        if let hooks, !hooks.isEmpty { note("hooks · \(hooks.specs.count) configured") }
        if projectHooksRefused {
            note("hooks · .kist/hooks.json present but NOT loaded (untrusted workspace) — set KIST_TRUST_PROJECT_HOOKS=1 to trust it")
        }
        return HeadlessAgentLoop(providers: registry, providerId: providerId, model: model,
                                 tools: mainTools, context: context, sink: terminalSink,
                                 interactor: interactor, approvalTools: approvalTools,
                                 planMode: planMode, toolMode: toolMode, hooks: hooks,
                                 checkpoints: checkpoints, maxIterations: maxIterations,
                                 extendedThinking: extendedThinking,
                                 budget: budget,
                                 contextWindow: ContextWindowManager.forModel(
                                    capabilities: registry.capabilities(providerId: providerId, model: model)
                                 ),
                                 recorder: recorder,
                                 traceRecorder: traceRecorder,
                                 traceRole: traceRole,
                                 // Verified local-model stop sequences from Drop-a-Key/Drop-a-Doc onboarding.
                                 modelProfiles: LocalModelProfileStore.default())
    }

    /// Explicit flag > config > first configured cloud provider > first local. Nil after an error.
    private static func resolveProvider(_ opts: KistOptions, _ registry: ProviderRegistry, configProvider: String?) -> String? {
        if let pid = opts.providerId ?? configProvider {
            guard registry.provider(id: pid) != nil else { err("error: unknown provider '\(pid)'. Try --list-providers."); return nil }
            return pid
        }
        if let cloud = registry.providers.first(where: { $0.requiresAPIKey && registry.hasKey(for: $0) }) { return cloud.id }
        if let local = registry.providers.first(where: { !$0.requiresAPIKey }) { return local.id }
        err("error: no provider has a key. Set one (e.g. export OPENAI_API_KEY=…) or use --provider. See --list-providers.")
        return nil
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

    private static func stdinIsTTY() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return isatty(fileno(stdin)) != 0
        #else
        return false
        #endif
    }

    /// `kist mcp auth <server> <metadata-url> [client-id] [scope]` — one-time interactive OAuth authorize
    /// for a remote MCP server. Discovers the auth-server metadata, opens the browser, catches the loopback
    /// redirect, exchanges the code, and persists the token where the client manager reads it.
    private static func runMCPAuth(_ args: [String]) async -> Int32 {
        guard args.count >= 2, let metaURL = URL(string: args[1]) else {
            print("usage: kist mcp auth <server-name> <metadata-url> [client-id] [scope]")
            print("  <metadata-url> is the OAuth authorization-server metadata (RFC 8414), e.g. https://host/.well-known/oauth-authorization-server")
            return 2
        }
        let server = args[0]
        let clientID = args.count >= 3 ? args[2] : nil
        let scope = args.count >= 4 ? args[3] : nil
        do {
            print("· discovering OAuth metadata for '\(server)' …")
            let metadata = try await MCPOAuthFlow.discoverMetadata(metaURL)
            print("· opening your browser to authorize (complete the login there) …")
            try await MCPOAuthFlow.authorize(serverName: server, metadata: metadata, clientID: clientID,
                                             scope: scope, store: OAuthTokenStore())
            print("\u{001B}[32m✓ authorized '\(server)' — token stored. It will be used (and refreshed) automatically.\u{001B}[0m")
            return 0
        } catch {
            print("\u{001B}[31m✗ authorize failed: \(error.localizedDescription)\u{001B}[0m")
            return 1
        }
    }

    private static func listProviders(_ registry: ProviderRegistry) -> Int32 {
        print("Providers (✓ = key configured / no key needed):")
        for p in registry.providers {
            let mark = registry.hasKey(for: p) ? "\u{001B}[32m✓\u{001B}[0m" : "\u{001B}[31m✗\u{001B}[0m"
            let kind = p.requiresAPIKey ? "key: \(p.keyAccount)" : "local"
            print("  \(mark) \(p.id.padding(toLength: 12, withPad: " ", startingAt: 0)) \(p.name)  (\(kind))")
        }
        return 0
    }

    /// `--ship`: the build already ran hands-free in the autopilot sandbox; now the council of minds
    /// reviews the actual result (changed-file manifest + goal) and returns GO/NO-GO. Deploy stays your call.
    private static func runShipReview(goal: String, registry: ProviderRegistry, roles: RoleBindings, root: String) async {
        // Capture a REAL diff the council can judge — including NEW files' content (which `git diff`
        // alone omits until staged). Stage everything, drop kist's own run artifacts, read the staged
        // diff, then fully unstage to leave the working tree exactly as the build left it.
        _ = gitCapture(["-C", root, "add", "-A"])
        _ = gitCapture(["-C", root, "reset", "-q", "--", ".kist"])
        let statSummary = gitCapture(["-C", root, "diff", "--cached", "--stat"])
        let fullDiff = String(gitCapture(["-C", root, "diff", "--cached"]).prefix(14000))
        _ = gitCapture(["-C", root, "reset", "-q"])
        let hadChanges = !statSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let build = ShipPipeline.BuildResult(
            hadChanges: hadChanges,
            diffSummary: hadChanges ? (statSummary + "\n\n" + fullDiff) : "(no changes in the working tree)",
            testsPassed: false,
            testSummary: "no automated test suite was run for this fresh build — judge the CODE itself against the goal (this is a new build, not a regression to an existing tested codebase)",
            signoffSummary: "built hands-free in the autopilot OS sandbox")
        note("")
        note("ship · council of minds reviewing the build…")
        let decision = await ShipPipeline(council: CouncilPromotionJudge(providers: registry, roles: roles)).review(goal: goal, build: build)
        if let v = decision.verdict {
            for vote in v.votes {
                note("  \(vote.shipWorthy ? "\u{001B}[32m✓\u{001B}[0m" : "\u{001B}[31m✗\u{001B}[0m") \(vote.name): \(vote.reason.prefix(140))")
            }
        }
        guard decision.canDeploy else {
            note("ship · \u{001B}[31;1m✗ NO-GO\u{001B}[0m — \(decision.reason)")
            return
        }
        note("ship · \u{001B}[32;1m● GO\u{001B}[0m — the council blessed it. \(decision.reason)")
        // THE CAPTAIN GATE: you are the captain. The council can't deploy alone — it needs your sign-off.
        // (This is the human captain gate; the Ed25519 cryptographic captain in the codebase is for
        // unforgeable multi-party/CI sign-off — overkill for a local single user.) Non-TTY → never deploy.
        guard stdinIsTTY() else {
            note("ship · captain sign-off needed — re-run in your terminal, or commit the build yourself.")
            return
        }
        FileHandle.standardError.write(Data("ship · captain — deploy this build (commit it)? [y/N] ".utf8))
        let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard answer == "y" || answer == "yes" else {
            note("ship · held by the captain — not committed. Ship it yourself when ready.")
            return
        }
        _ = gitCapture(["-C", root, "add", "-A"])
        _ = gitCapture(["-C", root, "reset", "-q", "--", ".kist"])   // don't commit kist's run artifacts
        let safeGoal = goal.replacingOccurrences(of: "\n", with: " ").prefix(72)
        let commit = gitCapture(["-C", root, "commit", "-m", "ship: \(safeGoal)"])
        note("ship · \u{001B}[32;1m● DEPLOYED\u{001B}[0m — committed the build. \(commit.split(separator: "\n").first.map(String.init) ?? "")")
        note("ship · push / host it with your deploy step when ready — kist won't push for you.")
    }

    /// Capture a git command's stdout (best-effort; "" on any failure).
    private static func gitCapture(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func listRuns(_ store: LoopCheckpointStore) -> Int32 {
        let runs = store.resumable()
        if runs.isEmpty { print("no resumable runs."); return 0 }
        print("Resumable runs (newest first):")
        for c in runs {
            print("  \(c.id)  [\(c.status.rawValue)]  iter \(c.iteration)  \(c.providerId)  \(c.title)")
        }
        return 0
    }
}
