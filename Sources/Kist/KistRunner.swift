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
    static func err(_ s: String) {
        BuilderRunAudit.current?.replay.recordEvent(kind: "hostError", success: false, text: s)
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
    static func note(_ s: String) {
        BuilderRunAudit.current?.replay.recordEvent(kind: "hostNote", text: s)
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    /// Built-in providers + any user-added custom providers, behind the default key resolver.
    /// Rebuilt after a model is added so the new one is immediately selectable.
    static func makeRegistry(config: KistConfig) -> ProviderRegistry {
        // The registry's cross-provider fallback chain honors the same combined availability gate
        // as routing (Codex P2, 2026-08-25): a stream retry must not walk into a provider the
        // health daemon already knows is down. Both stores re-read their files per call.
        let cooldowns = ProviderCooldownStore()
        let health = ProviderHealthFileStore()
        return makeRegistry(
            config: config, providers: ProviderCatalog.all + CustomProviderStore.load(),
            keyStore: DefaultKeyStore.make(),
            fallbackProviderIds: ModelRouter.defaultFallbackProviderIds,
            providerUnavailable: { cooldowns.coolingDown($0) || health.down($0) })
    }

    /// One construction seam for production and focused policy tests. Filtering the providers AND
    /// fallback graph here means every registry lookup/readiness probe/route sees the same boundary;
    /// non-allowed implementations remain compiled and can be admitted later (for example Onyx).
    static func makeRegistry(
        config: KistConfig,
        providers: [any ChatProvider],
        keyStore: KeyStore,
        fallbackProviderIds: [String: [String]] = [:],
        retryDelaysNanoseconds: [UInt64] = [250_000_000, 750_000_000],
        providerUnavailable: @escaping @Sendable (String) -> Bool = { _ in false }
    ) -> ProviderRegistry {
        let admitted = providers.filter { config.permitsProvider($0.id) }
        let admittedIDs = Set(admitted.map { $0.id.lowercased() })
        let admittedFallbacks = fallbackProviderIds.reduce(into: [String: [String]]()) { result, entry in
            let primary = entry.key.lowercased()
            guard admittedIDs.contains(primary) else { return }
            result[primary] = entry.value.filter { admittedIDs.contains($0.lowercased()) }
        }
        return ProviderRegistry(
            providers: admitted, keyStore: keyStore,
            fallbackProviderIds: admittedFallbacks,
            retryDelaysNanoseconds: retryDelaysNanoseconds,
            providerUnavailable: providerUnavailable)
    }

    /// Choose the semantic-memory embedder. `KIST_EMBEDDER=ollama` opts into LOCAL embeddings
    /// (offline, free, no key — requires a running Ollama); otherwise Gemini when its key is
    /// present. Returns nil (semantic memory off) when neither applies — no silent local dependency.
    static func makeEmbedder(
        registry: ProviderRegistry,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EmbeddingProviding? {
        let choice = (environment["KIST_EMBEDDER"] ?? "").lowercased()
        if choice == "ollama" {
            // The environment opt-in chooses an implementation but cannot widen the provider
            // policy. This closes the one provider-backed helper that does not call through the
            // chat registry for each request.
            guard registry.provider(id: "ollama") != nil else { return nil }
            let model = environment["KIST_EMBED_MODEL"] ?? OllamaEmbeddingClient.defaultModel
            return OllamaEmbeddingClient(model: model)
        }
        if let geminiKey = registry.apiKey(forProviderId: "gemini") {
            return GeminiEmbeddingClient(apiKey: geminiKey)
        }
        return nil
    }

    static func makeSemanticMemory(
        root: String, opts: KistOptions, registry: ProviderRegistry,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SemanticMemoryService? {
        guard !opts.noMemory,
              let embedder = makeEmbedder(registry: registry, environment: environment) else {
            return nil
        }
        return SemanticMemoryService(
            embedder: embedder,
            store: FileBackedVectorStore(
                path: SemanticMemoryService.defaultStorePath(projectRoot: root),
                confinementRoot: root))
    }
    struct ProviderPick { let providerId: String; let model: String? }

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
        if opts.operatorAction {
            return await runOperatorAction(opts)
        }
        // Route MCP diagnostics through the same terminal owner as stdout/stderr. Before a pinned
        // REPL exists the router preserves ordinary stderr behavior; during a sticky turn it joins
        // the coordinator's serialized transcript stream.
        MCPLog.installDiagnosticSink { TerminalScreenCoordinator.routeDiagnosticLine($0) }
        defer { MCPLog.resetDiagnosticSink() }

        if opts.listLearningSync || opts.listLearningStatus {
            return await runListLearning(opts)
        }

        // Hidden, offline visual verification. Dispatch before registry/tool/MCP construction so this
        // cannot touch a provider, keychain, server, or network.
        if opts.stickyBarSelfTest {
            return await runStickyBarSelfTest()
        }
        if opts.smlOpenAPIImport != nil {
            return runSMLOpenAPIImport(opts)
        }
        if opts.smlStoreAction != nil {
            return await runSMLRuntimeMaintenance(opts)
        }
        if opts.smlRuntimeOpenAPI != nil {
            return await runSMLRuntimeOpenAPI(opts)
        }
        if opts.smlRuntimeModelRouter != nil {
            return await runSMLRuntimeModelRouter(opts)
        }
        if opts.smlRuntimeOnyx != nil {
            return await runSMLRuntimeOnyx(opts)
        }
        if opts.smlRuntimePlanning != nil {
            return await runSMLRuntimePlanning(opts)
        }
        if opts.smlRuntimeCatalog != nil {
            return await runSMLRuntimeCatalog(opts)
        }
        if opts.smlRuntimeMount != nil {
            return await runSMLRuntimeMount(opts)
        }
        if opts.smlRuntimeAgentGuide != nil {
            return await runSMLRuntimeAgentGuide(opts)
        }
        if opts.smlRuntimeHostGuide != nil {
            return await runSMLRuntimeHostGuide(opts)
        }
        if opts.smlRuntimeHostWiring != nil {
            return await runSMLRuntimeHostWiring(opts)
        }
        if opts.smlRuntimeRunbook != nil {
            return await runSMLRuntimeRunbook(opts)
        }
        if opts.smlRuntimeScaffold != nil {
            return await runSMLRuntimeScaffold(opts)
        }
        if opts.smlRuntimeLaunch != nil {
            return await runSMLRuntimeLaunch(opts)
        }
        if opts.smlRuntimeAPI != nil {
            return await runSMLRuntimeAPI(opts)
        }
        if opts.smlRuntimeAPIScript != nil {
            return await runSMLRuntimeAPIScript(opts)
        }
        if opts.smlRuntimeAttachments != nil {
            return await runSMLRuntimeAttachments(opts)
        }
        if opts.smlRuntimeServe != nil {
            return await runSMLRuntimeServe(opts)
        }
        if opts.smlRuntimeREPLScript != nil {
            return await runSMLRuntimeREPLScript(opts)
        }
        if opts.smlRuntimeREPL != nil {
            return await runSMLRuntimeREPL(opts)
        }
        if opts.smlRuntimeExport != nil {
            return await runSMLRuntimeExport(opts)
        }

        let config = KistConfig.load()
        var registry = makeRegistry(config: config)
        let checkpoints = LoopCheckpointStore()
        if let policyError = config.providerPolicyError {
            err("error: provider policy is fail-closed: \(policyError)")
        }
        var model = opts.model ?? config.model       // flags > config > provider default (goal pin may override below)
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
            let noninteractive = makeRegistry(
                config: config, providers: ProviderCatalog.all + CustomProviderStore.load(),
                keyStore: FileKeyStore(),
                fallbackProviderIds: ModelRouter.defaultFallbackProviderIds)
            return await providerHealth(noninteractive, probe: false)
        }
        if opts.probeProviders { return await providerHealth(registry, probe: true) }
        if opts.providersDoctor { print(await providerDoctorReport(registry)); return 0 }
        if let mcpAuthArgs = opts.mcpAuth { return await runMCPAuth(mcpAuthArgs) }
        if opts.protocolStatus { return protocolStatus(projectRoot: opts.project) }
        if opts.hostSnapshot { return opts.hostSnapshotStream ? await runHostSnapshotStream(opts) : await runHostSnapshot(opts) }
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
            guard registry.provider(id: cp.providerId) != nil else {
                err("error: checkpoint provider '\(cp.providerId)' is not permitted or available under the current provider policy")
                return 2
            }
            guard let root = ToolContext.canonicalize(cp.projectRoot) else {
                err("error: the run's project path no longer exists: \(cp.projectRoot)"); return 2
            }
            let auditRunID = "cli-" + UUID().uuidString.lowercased()
            let auditLog = AuditLog.forRun(root: root, runID: auditRunID)
            let sharedMemory: AgentMemoryAccess?
            do { sharedMemory = try Self.sharedAgentMemory(root: root, opts: opts) }
            catch { err("shared agent memory setup failed: \(error)"); return 2 }
            let context = ToolContext(projectRoot: root, shell: shell, sandbox: sandbox,
                                      auditLog: auditLog, externalReadRoots: opts.allowReadPaths,
                                      agentMemory: sharedMemory)
            note("tool audit · \(auditLog.path)")
            note("kist · resuming \(cp.title) · \(cp.providerId) · iter \(cp.iteration)")
            // Resume with the SAME full tool set as a fresh run (previously it lost browse/tasks/etc.).
            let resumeExtraTools = Self.buildExtraTools(root: root, fetchAllowedHosts: fetchAllowedHosts, opts: opts, registry: registry)
            return await withTools(projectRoot: root, fetchAllowedHosts: fetchAllowedHosts, extraTools: resumeExtraTools, enableComputerUse: opts.enableComputerUse) { tools in
                let listLearning = Self.makeListLearning(root: root, opts: opts, tools: tools, context: context)
                _ = await listLearning?.refresh()
                let recorder = TrajectoryRecorder()
                let lessonStore = opts.noMemory ? nil : LessonStore()
                let traceRecorder = TraceRecorder(traceId: TraceID.make())
                let loop = makeLoop(registry: registry, providerId: cp.providerId, model: cp.model, context: context,
                                    tools: tools, checkpoints: checkpoints, maxIterations: opts.maxIterations,
                                    budget: opts.makeBudget(),
                                    extendedThinking: opts.extendedThinking,
                                    toolMode: toolMode, delegationDepth: opts.delegationDepth, recorder: recorder,
                                    traceRecorder: traceRecorder)
                let mem = Self.sessionMemory(root: root, opts: opts) ?? ""
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
        // NL pin: a one-shot goal that OPENS with "use <model>…" pins the provider, exactly as the
        // REPL honors it per-turn. Flags still outrank it; prose merely mentioning a model does not match.
        let goalPin = (opts.providerId == nil)
            ? opts.goal.flatMap { Self.oneShotModelPin(goal: $0, knownProviders: providerAliases(for: registry)) }
            : nil
        if let goalPin { note("router · goal pin honored: \(goalPin.providerId)") }
        guard let providerId = goalPin?.providerId
            ?? resolveProvider(opts, registry, configProvider: config.provider,
                               verdicts: sessionVerdicts, policy: selectionPolicy) else { return 2 }
        model = startupModel(explicit: opts.model, selectedProvider: providerId,
                             configProvider: config.provider, configModel: config.model,
                             goalModel: goalPin?.model)
        guard let root = ToolContext.canonicalize(opts.project) else {
            err("error: project path does not exist: \(opts.project)"); return 2
        }
        if opts.smlRuntimeModel != nil {
            return await runSMLRuntimeModel(
                opts,
                registry: registry,
                providerId: providerId,
                model: model,
                projectRoot: root
            )
        }
        if opts.smlRuntimeModelScript != nil {
            return await runSMLRuntimeModelScript(
                opts,
                registry: registry,
                providerId: providerId,
                model: model,
                projectRoot: root
            )
        }
        let auditRunID = "cli-" + UUID().uuidString.lowercased()
        let auditLog = AuditLog.forRun(root: root, runID: auditRunID)
        let sharedMemory: AgentMemoryAccess?
        do { sharedMemory = try Self.sharedAgentMemory(root: root, opts: opts) }
        catch { err("shared agent memory setup failed: \(error)"); return 2 }
        let context = ToolContext(projectRoot: root, shell: shell, sandbox: sandbox,
                                  auditLog: auditLog, externalReadRoots: opts.allowReadPaths,
                                  agentMemory: sharedMemory)
        note("tool audit · \(auditLog.path)")
        // Full tool set (media/data/temporal-memory/vision). Extracted so the
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
            let listLearning = Self.makeListLearning(root: root, opts: opts, tools: tools, context: context)
            if opts.goal?.isEmpty == false { _ = await listLearning?.refresh() }
            // No goal → interactive REPL (sensitive tools prompt for approval unless --yolo).
            guard let goal = opts.goal, !goal.isEmpty else {
                // DEFAULT = open straight to the prompt with AUTO-ROUTING on (kist picks the best model
                // per request). No forced menu. The legacy picker is still reachable with KIST_PICK_MODEL=1,
                // and any explicit --provider / config default pins a model (auto off).
                let forcePicker = ProcessInfo.processInfo.environment["KIST_PICK_MODEL"] == "1"
                let pick = (forcePicker && opts.providerId == nil && config.provider == nil)
                    ? await pickProvider(registry, config: config) : nil
                if pick != nil { registry = makeRegistry(config: config) }   // pick up an allowed model added during the picker
                let pickedProvider = pick?.providerId ?? providerId
                let model = pick?.model ?? (pickedProvider == providerId ? model : nil)
                let providerId = pickedProvider
                let chosen = registry.provider(id: providerId)
                // Auto-route unless the user pinned a provider. CLI flag / picker always pin; a
                // config default provider pins too UNLESS config says `"autoRouting": true` — then
                // it's only the starting model and the Captain keeps choosing per turn.
                let autoRouting = AutoModelRouter.routingEnabled(
                    pickedInteractively: pick != nil, cliProvider: opts.providerId != nil,
                    configProvider: config.provider != nil, configAutoRouting: config.autoRouting)
                // Cross-process live-failure ledger (~/.kist/runtime/provider-cooldowns.json), shared by
                // every REPL lane that picks a provider: auto-router tiers, Captain assignments, the media
                // reroute, and failed-turn substitution. The one-shot lanes already consult it (0.17.58);
                // before this the REPL neither read nor fed it, so a rate-limited gemini stayed "ready"
                // and every media turn walked into the same wall (2026-08-14 screenshot).
                let liveCooldowns = ProviderCooldownStore()
                // The daemon's health snapshot joins the cooldown ledger in ONE avoid gate used by
                // every routing lane below. provider-health.json was written-but-never-read on the
                // request path, so a provider known-down at startup (ollama, 2026-08-25) was selected
                // every turn and every turn died identically. Both stores re-read their files per
                // call, so a provider the user restarts mid-session comes back without a relaunch.
                let providerHealth = ProviderHealthFileStore()
                let avoidProvider: @Sendable (String) -> Bool = {
                    liveCooldowns.coolingDown($0) || providerHealth.down($0)
                }
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
                    var tuiLoop = makeLoop(registry: registry, providerId: providerId, model: model, context: context,
                                           tools: tools, checkpoints: checkpoints, maxIterations: opts.maxIterations,
                                    budget: opts.makeBudget(),
                                           interactor: TUIInteractor(ui: ui), approvalTools: opts.yolo ? [] : sensitiveTools,
                                           planMode: opts.planMode, extendedThinking: opts.extendedThinking, toolMode: toolMode,
                                           roles: roleSelection.bindings, delegationDepth: opts.delegationDepth,
                                           sinkOverride: tuiSink, recorder: recorder, traceRecorder: traceRecorder)
                    tuiLoop.recallLessons = Self.listRecall(listLearning)
                    let memoryContext = Self.sessionMemory(root: root, opts: opts)
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
                // --no-memory or no embedder) shared by the locally-checked advisory deposit and
                // the P1 recall→plan READ-BACK injection. Same store the `recall` tool reads.
                let semanticMemory = Self.makeSemanticMemory(
                    root: root, opts: opts, registry: registry)
                // P1 injection is OFF by default (zero per-turn cost, no behavior change) until `/ablation
                // recall` proves the wire compounds (advantage>0); opt in with KIST_RECALL_INJECT=1. When on,
                // each turn's system prompt gains an explicitly untrusted data block of locally checked lessons.
                let recallInject: (@Sendable (_ q: String) async -> String)?
                if ProcessInfo.processInfo.environment["KIST_RECALL_INJECT"] == "1", let s = semanticMemory {
                    recallInject = { q in
                        do {
                            let block = try await s.recallBlockChecked(for: q)
                            if let warning = s.lastFailure {
                                Self.err("semantic recall degraded: \(warning)")
                            }
                            return block
                        }
                        catch {
                            Self.err("semantic recall unavailable (fail-closed): \(error)")
                            return ""
                        }
                    }
                } else {
                    recallInject = nil
                }
                // P2 task-targeted self__ surfacing — OFF by default (advertisement-only, fail-open; only
                // trims schema bloat once the self__ population is large). Opt in with KIST_SURFACE_SELFTOOLS=1.
                let surfaceSelfTools = ProcessInfo.processInfo.environment["KIST_SURFACE_SELFTOOLS"] == "1"
                let replBudget = opts.makeBudget()
                var loop = makeLoop(registry: registry, providerId: providerId, model: model, context: context,
                                    tools: tools, checkpoints: checkpoints, maxIterations: opts.maxIterations,
                                    budget: replBudget,
                                    interactor: terminalInteractor, approvalTools: opts.yolo ? [] : sensitiveTools,
                                    planMode: opts.planMode, extendedThinking: opts.extendedThinking, toolMode: toolMode,
                                    roles: roleSelection.bindings, delegationDepth: opts.delegationDepth,
                                    showReasoning: opts.extendedThinking,   // --think → watch the reasoning inline
                                    sinkOverride: makeReplSink(showReasoning: opts.extendedThinking),
                                    recorder: recorder, traceRecorder: traceRecorder)
                loop.recallLessons = Self.listRecall(listLearning, alongside: recallInject)
                loop.filterSelfToolsByRelevance = surfaceSelfTools   // P2: off unless KIST_SURFACE_SELFTOOLS=1
                // CONVERSATIONAL ESCALATION: reach the fleet / plan-DAG from inside the chat, plus an
                // auto-router that PROPOSES (never silently spends) when a plain message looks like a big build.
                let specialistRegistry = registry
                let repl = KistREPL(loop: loop, commands: KistCommands.load(projectRoot: root))
                repl.advisoryMemoryEnabled = !opts.noMemory
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
                        guard !snapshot.providers.isEmpty else {
                            return autoRouter.route(text, hasMedia: false, current: current,
                                                    avoid: avoidProvider)
                        }
                        // Fall back to the CURRENT model (not the startup default): "stay" must mean stay on
                        // whatever we're on now, or a no-signal turn route-flips back after any switch (Codex HIGH).
                        let a = ModelAssignmentEngine.assignInteractive(turn: text, snapshot: snapshot,
                                                                        fallback: current, learning: learning,
                                                                        unavailable: avoidProvider)
                        return AutoModelRouter.captainDecision(a, fallback: current,
                                                               avoid: avoidProvider)
                    }
                } else {
                    repl.autoRoute = { text, hasMedia, current in
                        autoRouter.route(text, hasMedia: hasMedia, current: current,
                                         avoid: avoidProvider)
                    }
                }
                // Model onboarding constructs a temporary registry around an unsaved draft. Keep
                // that intentionally broad setup surface unreachable while an allowlist is active;
                // widening the catalog requires an explicit config edit + restart.
                if config.allowedProviders == nil {
                    repl.addModelFlow = { _ = await AddModelFlow.run() }
                    repl.importModelFlow = { url in await ImportModelWizard.run(url: url) }
                }
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
                        let available = specialistRegistry.providers
                            .filter {
                                ($0.requiresAPIKey && specialistRegistry.hasKey(for: $0))
                                    || (subscriptionHitters.contains($0.id)
                                        && specialistRegistry.hasKey(for: $0))
                            }
                            .map { $0.id }
                        let shVerdicts: [String: ModelVerdict] = opts.noMemory
                            ? [:] : CaptainLearningStore(projectRoot: root).modelVerdicts()
                        let strong = ModelEscalator.pick(tier: .frontier, keyed: available, preferred: providerId,
                                                         verdicts: shVerdicts)
                        if strong != providerId { repairRoleDefault = ProviderBinding(providerId: strong) }
                    }
                    let selectedTeam: AgentTeamTools.ChildFactory = { selected, selectedContext, ceiling, turnCap in
                        AgentTeamTools.make(providers: specialistRegistry, binding: selected,
                            baseTools: tools, context: selectedContext,
                            sink: TerminalEventSink(showReasoning: false), interactor: terminalInteractor,
                            approvalTools: approval, specialistApprovalTools: specSensitive,
                            maxIterations: min(opts.maxIterations, turnCap),
                            spawnLevels: max(0, opts.delegationDepth) + 1,
                            extendedThinking: opts.extendedThinking, budget: replBudget,
                            checkpoints: checkpoints, ceiling: ceiling)
                    }
                    let offered = selectedTeam(repairRoleDefault, context, nil, opts.maxIterations)
                    let selectedTraceID = await traceRecorder.traceId
                    let spawner = SpecialistSpawner(
                        providers: specialistRegistry, baseTools: tools,
                        context: context.withCorrelationID(selectedTraceID, traceRecorder: traceRecorder),
                        sink: TerminalEventSink(showReasoning: false), interactor: terminalInteractor,
                        aliasTable: [:], roleDefault: repairRoleDefault,
                        defaultMaxIterations: opts.maxIterations, extendedThinking: opts.extendedThinking,
                        budget: replBudget, childToolsFactory: selectedTeam,
                        additionalToolNames: offered.names, checkpoints: checkpoints,
                        delegationDepthRemaining: max(0, opts.delegationDepth) + 1)
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
                // Legacy Cortex Markdown remains available through explicit operator audit commands only.
                // It is never seeded, mutated, or folded into a model prompt.
                let cortex = opts.noMemory ? nil : CortexMemory()
                repl.cortex = cortex
                repl.briefCompiler = { input, roles, mode, transcript, outcome in
                    let personaContext = TaskPersonaMatcher.promptContext(
                        matches: personaMatcher.matches(for: input, limit: 3))
                    let reviewContext = ReviewContext.renderIfNeeded(request: input, projectRoot: root)
                    return PromptCompiler.compiledPrompt(input, mode: mode,
                                                         conversationContext: PromptCompiler.conversationContext(from: transcript),
                                                         projectContext: briefContext(memoryContext: memoryContext,
                                                                                      roles: roles,
                                                                                      lessons: lessonStore?.primer(forGoal: input),
                                                                                      specialists: personaContext,
                                                                                      reviewTargets: reviewContext),
                                                         resolvedOutcome: outcome)
                }
                // Rebuilt on /model (new default provider+model) and /roles (new team). The default
                // binding drives the conversational turn AND the spawn-tool default; roles drive the team.
                repl.loopFactory = { defaultBinding, roles, planMode, showReasoning, extendedThinking in
                    // R2a: same shared constructor as the initial loop (typed-input render + hook).
                    var l = makeLoop(registry: registry, providerId: defaultBinding.providerId, model: defaultBinding.model,
                             context: context,
                             tools: tools, checkpoints: checkpoints, maxIterations: opts.maxIterations,
                             budget: replBudget,
                             interactor: terminalInteractor, approvalTools: opts.yolo ? [] : sensitiveTools,
                             planMode: planMode, extendedThinking: extendedThinking, toolMode: toolMode, roles: roles,
                             delegationDepth: opts.delegationDepth, showReasoning: showReasoning,
                             sinkOverride: makeReplSink(showReasoning: showReasoning),
                             recorder: recorder,
                             traceRecorder: traceRecorder)
                    l.recallLessons = Self.listRecall(listLearning, alongside: recallInject)
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
                // Roadmap #3 — capture locally checked wins into advisory semantic memory so a future session
                // can recall them as unsigned advisory context. The typed deposit carries the captured
                // verification clock and replay locator; metadata alone can never manufacture a checked lesson.
                if let semanticMemory {   // reuse the ONE hoisted service (deposit side of the same store)
                    repl.rememberLesson = { deposit in
                        do { _ = try await semanticMemory.rememberLocallyCheckedLesson(deposit) }
                        catch { Self.err("semantic lesson was not persisted: \(error)") }
                    }
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
                repl.visionProviderCandidates = {
                    let keyedVision = registry.providers
                        .filter { registry.hasKey(for: $0) && $0.availableModels.contains { $0.isVision } }
                        .map(\.id)
                    // Gemini first (video/audio engine), then every other keyed vision provider as the
                    // fallback lane the media reroute walks when the preferred engine is rate-limited.
                    return keyedVision.filter { $0.lowercased() == "gemini" }
                         + keyedVision.filter { $0.lowercased() != "gemini" }
                }()
                repl.visionProviderId = repl.visionProviderCandidates.first
                // The REPL both CONSULTS the ledger (media reroute, substitution, auto-route tiers skip
                // cooling providers) and FEEDS it (a transient live failure benches the provider for
                // every kist process — the one-shot lanes previously wrote it alone). The consult side
                // is the COMBINED gate (cooldowns + health daemon) so substitution never lands on a
                // provider the daemon already knows is down.
                repl.providerCoolingDown = avoidProvider
                repl.recordProviderCooldown = { liveCooldowns.record($0) }
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
                        await runBuilderCompatibility(o, goal: g, registry: registry, root: root,
                                                      tools: tools, context: context, checkpoints: checkpoints,
                                                      toolMode: toolMode, providerId: providerId, model: model,
                                                      rolesOverride: roles)
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
                        .filter {
                            ($0.requiresAPIKey && strongRegistry.hasKey(for: $0))
                                || (subscriptionHitters.contains($0.id)
                                    && strongRegistry.hasKey(for: $0))
                        }
                        .map { $0.id }
                    let strong = ModelEscalator.pick(tier: .frontier, keyed: available, preferred: providerId,
                                                     verdicts: verdicts)
                    guard strong != providerId else { return nil }
                    return RoleBindings(default: ProviderBinding(providerId: strong))
                }
                func runPlanExecuteRoute(_ missionID: PlanExecuteMissionID?, _ g: String,
                                         _ roles: RoleBindings,
                                         riskObjective: String? = nil,
                                         priorResultContext: PriorResultContext? = nil) async -> HeavyRouteResult {
                    var o = opts; o.goal = g; o.planExecute = true
                    o.planExecuteResumeID = missionID
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
                        await runBuilderCompatibility(o, goal: g, registry: registry, root: root,
                                                      tools: tools, context: context, checkpoints: checkpoints,
                                                      toolMode: toolMode, providerId: providerId, model: model,
                                                      rolesOverride: roles,
                                                      riskObjective: riskObjective,
                                                      advisoryContext: priorResultContext)
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
                repl.planExecute = { g, roles in
                    await runPlanExecuteRoute(nil, g, roles)
                }
                repl.planExecuteWithContext = { authorityGoal, context, roles in
                    await runPlanExecuteRoute(nil, authorityGoal, roles,
                                              riskObjective: authorityGoal,
                                              priorResultContext: context)
                }
                repl.resumePlanExecute = { missionID, g, roles in
                    await runPlanExecuteRoute(missionID, g, roles)
                }
                repl.council = { g, roles, execute in
                    // R1 sibling: council (and its execute=true hand-off into runPlanExecute) gets
                    // the same ESC watcher — top-level + sequential, single-watcher invariant holds.
                    // Coverage is partial (council's own model calls stop via provider cancellation);
                    // honest partial beats a dead zone.
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    let capture = CouncilPipelineCaptureBox()
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
                                         providerId: providerId, model: model, rolesOverride: roles,
                                         capture: capture)
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
                    let verifiedContext = HeavyRouteResult.verifiedCouncilContext(
                        capture.get(), projectRoot: root)
                    return HeavyRouteResult(
                        exitCode: exitCode, interruption: interrupted.value,
                        review: .handledInternally("the role-bound council synthesizes its own critique"),
                        verification: verification,
                        substantiveSummary: verifiedContext?.substantiveSummary,
                        artifactReferences: verifiedContext?.artifactReferences ?? [])
                }
                repl.digDeep = { g, roles in
                    // "Dig in deep" / "consult the minds": same ESC watcher as council — top-level, sequential.
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    let capture = CouncilPipelineCaptureBox()
                    let interrupted = MutableBox<InterruptibleTurn.InterruptReason?>(nil)
                    let exitCode = await InterruptibleTurn.run(onInterrupt: { reason in
                        interrupted.value = reason
                        if reason == .cancel { TurnInputQueue.shared.clearAll() }
                        else { TurnInputQueue.shared.commitPending() }
                        print("\n\u{001B}[33m" + (reason == .cancel ? "⎋⎋ cancelled" : "⎋ interrupted")
                              + " — dig-in-deep stopped\u{001B}[0m")
                    }) {
                        await runWideCouncil(opts, goal: g, registry: registry, root: root,
                                             providerId: providerId, model: model, rolesOverride: roles,
                                             capture: capture)
                    }
                    let verifiedContext = HeavyRouteResult.verifiedCouncilContext(
                        capture.get(), projectRoot: root)
                    return HeavyRouteResult(
                        exitCode: exitCode, interruption: interrupted.value,
                        review: .handledInternally("the heterogeneous wide council synthesizes its panel"),
                        verification: .unavailable(interrupted.value == nil
                            ? "advisory consensus has no deterministic execution oracle"
                            : "the wide council was interrupted before completion"),
                        substantiveSummary: verifiedContext?.substantiveSummary,
                        artifactReferences: verifiedContext?.artifactReferences ?? [])
                }
                repl.research = { g, roles in
                    // R1 sibling: same watcher for the research pipeline.
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    let researchCapture = ResearchPipelineCaptureBox()
                    let councilCapture = CouncilPipelineCaptureBox()
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
                                          rolesOverride: roles, capture: researchCapture,
                                          councilCapture: councilCapture)
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
                    let verifiedResearch = HeavyRouteResult.verifiedResearchContext(
                        researchCapture.get(), projectRoot: root)
                    let verifiedCouncil = HeavyRouteResult.verifiedCouncilContext(
                        councilCapture.get(), projectRoot: root)
                    let references = (verifiedResearch?.artifactReferences ?? [])
                        + (verifiedCouncil?.artifactReferences ?? [])
                    let substantiveSummary = exitCode == 0 && interrupted.value == nil
                        ? researchHandoffSummary(
                            councilFinalPlan: verifiedCouncil?.substantiveSummary,
                            dossier: verifiedResearch?.substantiveSummary)
                        : nil
                    return HeavyRouteResult(
                        exitCode: exitCode, interruption: interrupted.value,
                        review: .handledInternally("research feeds its evidence dossier through the role-bound council"),
                        verification: verification,
                        substantiveSummary: substantiveSummary,
                        artifactReferences: references)
                }
                repl.dive = { g, roles in
                    // Same ESC/typeahead watcher as research — top-level, sequential. Dive is LOCAL-ONLY:
                    // no web, no cross-repo estate sweep. It reads our code and consults the panel.
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    let researchCapture = ResearchPipelineCaptureBox()
                    let councilCapture = CouncilPipelineCaptureBox()
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
                                      providerId: providerId, model: model, rolesOverride: roles,
                                      capture: researchCapture, councilCapture: councilCapture)
                    }
                    let verifiedResearch = HeavyRouteResult.verifiedResearchContext(
                        researchCapture.get(), projectRoot: root)
                    let verifiedCouncil = HeavyRouteResult.verifiedCouncilContext(
                        councilCapture.get(), projectRoot: root)
                    let references = (verifiedResearch?.artifactReferences ?? [])
                        + (verifiedCouncil?.artifactReferences ?? [])
                    let substantiveSummary = exitCode == 0 && interrupted.value == nil
                        ? researchHandoffSummary(
                            councilFinalPlan: verifiedCouncil?.substantiveSummary,
                            dossier: verifiedResearch?.substantiveSummary)
                        : nil
                    return HeavyRouteResult(
                        exitCode: exitCode, interruption: interrupted.value,
                        review: .handledInternally("the wide panel reads the same grounded code dossier"),
                        verification: .unavailable(interrupted.value == nil
                            ? "a grounded code read has no deterministic execution oracle"
                            : "the dive was interrupted before completion"),
                        substantiveSummary: substantiveSummary,
                        artifactReferences: references)
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
                repl.advise = { task in
                    // /advise — convene the best-matching advisor persona (dynamic-advisor A1.5). READ-ONLY:
                    // the convened expert may research (web/read) but NOT write/exec — advisory, no side effects.
                    TurnInputQueue.shared.begin()
                    defer { TurnInputQueue.shared.end() }
                    // POSITIVE allowlist (fail-safe): only explicitly-safe READ/research tools reach an advisor —
                    // anything not on this list (write/exec/spawn/board-mutation, AND any unknown/MCP tool) is
                    // excluded by default, so /advise can never cause a side effect even as the tool set grows.
                    let safeReadTools: Set<String> = ["read_file", "search_code", "glob_files", "web_search",
                                                      "fetch_url", "browse", "read_spreadsheet", "query_data",
                                                      "view_image", "ask_user"]
                    let readOnlyTools = ToolRegistry(tools.all().filter { safeReadTools.contains($0.name) })
                    let spawner = SpecialistSpawner(providers: registry, baseTools: readOnlyTools, context: context,
                                                    roleDefault: ProviderBinding(providerId: providerId, model: model),
                                                    defaultMaxIterations: opts.maxIterations)
                    let matcher = TaskPersonaMatcher(projectRoot: root)
                    let result = await AdvisorSession.advise(
                        task: task, matcher: matcher, limit: 3,
                        classify: { t, catalog in
                            // A2 — LLM domain classifier: consulted ONLY when keyword matching missed (novel
                            // phrasing/domain). One fast completion; catalog-validated inside the planner; fail-open.
                            await AdvisorPanelPlanner.classify(task: t, catalog: catalog, limit: 2) { system, user in
                                let messages = [ChatMessage(role: .system, content: system),
                                                ChatMessage(role: .user, content: user)]
                                return try? await registry.complete(providerId: providerId, model: model, messages: messages)
                            }
                        }
                    ) { persona, subtask in
                        let outcome = await spawner.run(specialist: persona, task: subtask)
                        return outcome.summary
                    }
                    if let result { print(result) }
                    else { note("no advisor matched — try a more specific task (e.g. 'write me a joke', 'draft marketing copy', 'sync license question'), or just ask normally.") }
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
                // A dead classifier provider must announce itself (routing audit 2026-08-25: it
                // silently disabled every escalation route — plan/fleet/council/research were
                // unreachable and the degrade was indistinguishable from "nothing to escalate").
                let classifierDown: (String) -> Void = { note("router · \($0)") }
                if registry.provider(id: plannerBinding.providerId) != nil {
                    var router = ConversationRouter(providers: registry, binding: plannerBinding, defaultFleetAgents: min(3, opts.agents))
                    router.onClassifierUnavailable = classifierDown
                    repl.router = router
                }
                repl.routerFactory = { binding in
                    guard registry.provider(id: binding.providerId) != nil else { return nil }
                    var router = ConversationRouter(providers: registry, binding: binding, defaultFleetAgents: min(3, opts.agents))
                    router.onClassifierUnavailable = classifierDown
                    return router
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
            // Delegation is its own authority lane. Forced builder/research/fleet flags describe HOW a
            // fresh normal task runs; they must not turn the parent into a mutator or bypass its
            // host-bound child grant. Plan mode is still honored by runReadOnlyOneShot, while a sealed
            // plan-execute resume keeps its mission identity and is never reinterpreted as fresh work.
            if opts.planExecuteResumeID == nil,
               PromptCompiler.inferIntent(goal, mode: .inline) == .delegate {
                return await runReadOnlyOneShot(
                    opts, goal: goal, registry: registry, root: root,
                    tools: tools, context: context, checkpoints: checkpoints,
                    fetchAllowedHosts: fetchAllowedHosts, toolMode: toolMode,
                    providerId: providerId, model: model)
            }
            if opts.cobolo {
                return await runBuilderCompatibility(opts, goal: goal, registry: registry, root: root,
                                                     tools: tools, context: context, checkpoints: checkpoints,
                                                     toolMode: toolMode, providerId: providerId, model: model)
            }
            if opts.mission {
                return await runBuilderCompatibility(opts, goal: goal, registry: registry, root: root,
                                                     tools: tools, context: context, checkpoints: checkpoints,
                                                     toolMode: toolMode, providerId: providerId, model: model)
            }
            if opts.research {
                let status = await runResearch(opts, goal: goal, registry: registry, root: root,
                                               tools: tools, context: context,
                                               providerId: providerId, model: model)
                if opts.autonomyReceipts { emitReadOnlyAutonomyReceipt(status: status) }
                return status
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
                return await runBuilderCompatibility(opts, goal: goal, registry: registry, root: root,
                                                     tools: tools, context: context, checkpoints: checkpoints,
                                                     toolMode: toolMode, providerId: providerId, model: model)
            }
            // Evolution lab: improve Mythos itself through isolated, benchmarked candidate branches.
            if opts.evolve {
                return await runEvolution(opts, registry: registry, root: root, tools: tools,
                                          context: context, providerId: providerId, model: model)
            }
            // Plan→execute: planner emits a typed DAG, approve (unless --yolo), then build it.
            if opts.planExecute {
                if builderRunRequired(for: opts, goal: goal) {
                    return await runBuilderCompatibility(opts, goal: goal, registry: registry, root: root,
                                                         tools: tools, context: context, checkpoints: checkpoints,
                                                         toolMode: toolMode, providerId: providerId, model: model)
                }
                return await runReadOnlyOneShot(opts, goal: goal, registry: registry, root: root,
                                                tools: tools, context: context, checkpoints: checkpoints,
                                                fetchAllowedHosts: fetchAllowedHosts,
                                                toolMode: toolMode, providerId: providerId, model: model)
            }
            // Great-loop: the long-horizon runner — self-assess effort per cycle, learn from history, and
            // keep working across cycles until done-and-verified or a SAFETY CAP stops it.
            if opts.greatLoop {
                return await runBuilderCompatibility(opts, goal: goal, registry: registry, root: root,
                                                     tools: tools, context: context, checkpoints: checkpoints,
                                                     toolMode: toolMode, providerId: providerId, model: model)
            }
            if !builderRunRequired(for: opts, goal: goal) {
                return await runReadOnlyOneShot(opts, goal: goal, registry: registry, root: root,
                                                tools: tools, context: context, checkpoints: checkpoints,
                                                fetchAllowedHosts: fetchAllowedHosts,
                                                toolMode: toolMode, providerId: providerId, model: model)
            }
            // Mutation-capable one-shots use the durable execution -> deterministic verification ->
            // independent review coordinator. Answer/evidence work returned through the read-only path.
            return await runBuilderCompatibility(opts, goal: goal, registry: registry, root: root,
                                                 tools: tools, context: context, checkpoints: checkpoints,
                                                 toolMode: toolMode, providerId: providerId, model: model)
        }
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

    static func stdinIsTTY() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return isatty(fileno(stdin)) != 0
        #else
        return false
        #endif
    }

}
