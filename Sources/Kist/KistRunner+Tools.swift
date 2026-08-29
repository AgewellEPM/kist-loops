import Foundation
import AgentCore

/// Tool assembly + loop construction, extracted from KistRunner (RED-zone modular split,
/// behavior-preserving): the full extra tool set (`buildExtraTools`), the MCP-lifecycle registry
/// wrapper (`withTools`), and the headless-loop factory (`makeLoop`). One responsibility: turn a
/// registry + options into the tools and loop every run path shares.
extension KistRunner {

    /// The full extra tool set (media/data/temporal-memory/vision), built once so EVERY run path —
    /// fresh, goal, and --resume — gets identical capabilities. Legacy Cortex Markdown is audit-only;
    /// temporal semantic tools are included when an admitted embedder is available.
    static func buildExtraTools(root: String, fetchAllowedHosts: [String],
                                opts: KistOptions, registry: ProviderRegistry) -> [any AgentTool] {
        // --fast: core code tools plus temporal semantic memory when available. The timeless Cortex
        // compatibility surface is intentionally absent.
        if opts.fast {
            guard let memory = Self.makeSemanticMemory(
                root: root, opts: opts, registry: registry) else { return [] }
            return [RememberTool(service: memory), RecallTool(service: memory)]
        }
        var extraTools: [any AgentTool] = [ReadSpreadsheetTool(), QueryDataTool(), MediaClipTool(),
                                           SecurityAuditTool(), GovernanceReportTool(), WorkflowTool(),
                                           ManageTasksTool(), BrowserTool(allowedHosts: fetchAllowedHosts),
                                           // Offline COBOL specialist: a strong agent DRIVES a COBOL build and
                                           // calls this to generate the actual COBOL via the local cobol-jeeves
                                           // model (it writes COBOL but can't drive the agent loop — see the tool).
                                           CobolGenerateTool(providers: registry)]
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
        if let memory = Self.makeSemanticMemory(root: root, opts: opts, registry: registry) {
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

    // MARK: - MCP lifecycle

    /// Pure admission decision for one discovered MCP tool. Explicit trusted-user configuration wins:
    /// it fixes both neutral-name control tools (`guest_execute`, `vm_control`) and non-control homonyms
    /// (`lsp-swift__hover`). Legacy configs retain the conservative name heuristic as defense in depth.
    static func admitsMCPTool(name: String, explicitComputerUseRequirement: Bool?,
                              enableComputerUse: Bool) -> Bool {
        if enableComputerUse { return true }
        if let explicitComputerUseRequirement { return !explicitComputerUseRequirement }
        return !ReversibilityClassifier.isHostControlMCPTool(name)
    }

    /// Build the tool registry = built-in headless tools + any external MCP server tools, run
    /// `body`, then guarantee MCP servers are shut down (no zombies). MCP is opt-in via config
    /// (`~/.mcp.json` etc.); with none configured this is just the headless tool set.
    static func withTools(projectRoot: String,
                                  fetchAllowedHosts: [String],
                                  extraTools: [any AgentTool] = [],
                                  enableComputerUse: Bool = false,
                                  _ body: (ToolRegistry) async -> Int32) async -> Int32 {
        let mcp = MCPClientManager()
        let discovered = await mcp.discoverAndWrapTools(projectRoot: projectRoot)
        // Gate host-control (desktop actuation / screen capture) MCP tools behind --enable-computer-use, so a
        // user-configured desktop MCP can't drive the machine on an unarmed surface (council 2026-07-03).
        // Targeted by verb, so non-desktop MCP servers (github, db, filesystem) keep working unarmed.
        let mcpTools = discovered.filter {
            Self.admitsMCPTool(name: $0.name,
                               explicitComputerUseRequirement: $0.explicitComputerUseRequirement,
                               enableComputerUse: enableComputerUse)
        }
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
        // Self-authored (self__) tools — capabilities kist GREW for itself via the closed evolution loop,
        // loaded at runtime with no recompile. Every one runs mandatorily-sandboxed via ScriptTool. Fail-soft:
        // a malformed manifest is skipped, never blocks startup. Only the promote path ever writes here.
        let selfAuthored = SelfAuthoredToolStore(projectRoot: projectRoot).load()
        if !selfAuthored.isEmpty {
            note("self-evolved · \(selfAuthored.count) self__ tool(s) loaded · \(selfAuthored.map { $0.name }.joined(separator: ", "))")
            base.append(contentsOf: selfAuthored.map { $0 as any AgentTool })
        }
        let code = await body(ToolRegistry(base))
        await mcp.shutdownAll()
        return code
    }

    // MARK: - Helpers

    static func makeLoop(registry: ProviderRegistry, providerId: String, model: String?,
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
}
