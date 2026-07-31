import Foundation

/// Multi-agent delegation as a tool (the Claude-Code "Task" pattern). The agent calls
/// `spawn_agent` with a self-contained subtask; a FRESH `HeadlessAgentLoop` runs it to
/// completion in the SAME project (same confinement/sandbox) with its OWN context window, and
/// only the sub-agent's final summary returns to the parent — keeping the parent's context lean.
///
/// Recursion is bounded by construction: nested sub-agents receive `spawn_agent` only while a
/// caller-supplied delegation-depth budget remains, so a team can ask for help without forking
/// unboundedly.
public struct SpawnAgentTool: AgentTool {
    public let name = "spawn_agent"
    public var description: String {
        "Delegate a focused, SELF-CONTAINED subtask to a fresh sub-agent. " +
        "It has the same file/search tools and the same project, runs independently, and returns " +
        "only its final summary. Use it to isolate or parallelize a chunk of work. " +
        "Provide the full subtask in 'task' — the sub-agent cannot see this conversation. " +
        "Optionally set role to planner, worker/researcher, coder/builder, or critic/reviewer; " +
        "current role bindings: \(roleBindings.summary). You may also set provider/model directly " +
        "to spawn any configured AI for this subtask. " +
        (delegationDepthRemaining > 0
            ? "This sub-agent may delegate \(delegationDepthRemaining) more level(s) to teammates if it gets stuck."
            : "This sub-agent cannot delegate further.")
    }
    public let parameters = [
        ToolParameter(name: "task", type: "string", description: "The complete, self-contained subtask for the sub-agent.", required: true),
        ToolParameter(name: "role", type: "string", description: "Optional specialist role for the sub-agent: planner, worker/researcher, coder/builder, or critic/reviewer.", required: false),
        ToolParameter(name: "provider", type: "string", description: "Optional provider id/name override for this sub-agent, e.g. deepseek, gemini, openai, mimo.", required: false),
        ToolParameter(name: "model", type: "string", description: "Optional model id override for this sub-agent. If provider is omitted, it overrides the selected role/default provider's model.", required: false),
    ]

    private let providers: ProviderRegistry
    private let providerId: String
    private let model: String?
    private let roleBindings: RoleBindings
    private let baseTools: ToolRegistry     // the sub-agent's tools — must NOT contain spawn_agent
    private let sink: RuntimeEventSink
    private let interactor: RuntimeInteractor   // INHERITED from the parent so sub-agents can't
    private let approvalTools: Set<String>      // run sensitive tools without the same consent
    private let maxIterations: Int
    private let delegationDepthRemaining: Int
    private let extendedThinking: Bool   // inherited from the parent loop so sub-agents reason too
    /// Shared token ledger — the SAME instance the parent loop uses, so every delegated/fleet agent
    /// draws from ONE global budget (BudgetLedger is an actor). nil = uncapped.
    private let budget: BudgetLedger?

    public init(providers: ProviderRegistry, providerId: String, model: String?,
                roles: RoleBindings? = nil,
                baseTools: ToolRegistry, sink: RuntimeEventSink = NullEventSink(),
                interactor: RuntimeInteractor = AutoApproveInteractor(), approvalTools: Set<String> = [],
                maxIterations: Int = 10,
                delegationDepth: Int = 0,
                extendedThinking: Bool = false,
                budget: BudgetLedger? = nil) {
        self.providers = providers
        self.providerId = providerId
        self.model = model
        self.roleBindings = roles ?? RoleBindings(default: ProviderBinding(providerId: providerId, model: model))
        self.baseTools = baseTools
        self.sink = sink
        self.interactor = interactor
        self.approvalTools = approvalTools
        self.maxIterations = maxIterations
        self.delegationDepthRemaining = max(0, delegationDepth)
        self.extendedThinking = extendedThinking
        self.budget = budget
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let task = try requireString("task", from: arguments)
        let role = Self.parseRole(arguments["role"] as? String)
        if arguments["role"] != nil, role == nil {
            return .failure("unknown sub-agent role '\(arguments["role"] ?? "")'. Use planner, worker/researcher, coder/builder, or critic/reviewer.")
        }

        var binding = selectedBinding(role: role)
        if let provider = optionalString("provider", from: arguments) {
            binding = ProviderBinding(providerId: provider, model: optionalString("model", from: arguments) ?? binding.model)
        } else if let model = optionalString("model", from: arguments) {
            binding = ProviderBinding(providerId: binding.providerId, model: model)
        }

        guard let provider = providers.provider(id: binding.providerId) else {
            return .failure("unknown sub-agent provider '\(binding.providerId)'")
        }
        let selected = ProviderBinding(providerId: provider.id, model: binding.model)
        let compiledTask = PromptCompiler.compiledPrompt(task, role: role, mode: .delegated)
        // CAPABILITY CEILING (Codex gate S1#2): if a loaded skill scoped the PARENT to a tool
        // allow-list, the child must NOT escape it. A spawned agent rediscovers skills with a fresh
        // tracker, so without this a parent scoped to e.g. [read_file spawn_agent] could spawn a child
        // that writes. Scope the child's tools to the parent's active allow-list (intersection-only,
        // so the child can only ever be narrower).
        let parentCeiling = await context.skillTracker?.activeToolAllowlist()
        let childTools = parentCeiling.map { subTools(for: selected).scoped(to: Array($0)) } ?? subTools(for: selected)
        let sub = HeadlessAgentLoop(
            providers: providers, providerId: selected.providerId, model: selected.model,
            tools: childTools, context: context, sink: sink,
            interactor: interactor, approvalTools: approvalTools,
            maxIterations: maxIterations,
            extendedThinking: extendedThinking,
            budget: budget,   // SAME ledger as the parent → one global cap across the whole agent tree
            contextWindow: ContextWindowManager.forModel(
                capabilities: providers.capabilities(providerId: selected.providerId, model: selected.model)
            )
        )
        let outcome = await sub.run(goal: compiledTask)
        var metadata = [
            "sub_agent_iterations": String(outcome.iterations),
            "sub_agent_provider": selected.providerId,
        ]
        if let model = selected.model { metadata["sub_agent_model"] = model }
        if let role { metadata["sub_agent_role"] = role.rawValue }
        return ToolResult(
            success: outcome.success,
            output: outcome.summary,
            error: outcome.success ? nil : outcome.summary,
            metadata: metadata
        )
    }

    private func selectedBinding(role: AgentRole?) -> ProviderBinding {
        guard let role else { return ProviderBinding(providerId: providerId, model: model) }
        return roleBindings.binding(for: role)
    }

    private func subTools(for selected: ProviderBinding) -> ToolRegistry {
        guard delegationDepthRemaining > 0 else { return baseTools }
        let nestedSpawn = SpawnAgentTool(
            providers: providers,
            providerId: selected.providerId,
            model: selected.model,
            roles: roleBindings,
            baseTools: baseTools,
            sink: sink,
            interactor: interactor,
            approvalTools: approvalTools,
            maxIterations: maxIterations,
            delegationDepth: delegationDepthRemaining - 1,
            extendedThinking: extendedThinking,
            budget: budget   // propagate the shared ledger down the whole delegation tree
        )
        return ToolRegistry(baseTools.all() + [nestedSpawn])
    }

    private func optionalString(_ key: String, from arguments: [String: Any]) -> String? {
        guard let raw = arguments[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parseRole(_ raw: String?) -> AgentRole? {   // internal for tests (composite-role regression)
        guard let raw else { return nil }
        let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func match(_ tok: String) -> AgentRole? {
            switch tok {
            case "planner", "plan": return .planner
            case "worker", "research", "researcher", "analyst": return .worker
            case "coder", "code", "builder", "build", "developer", "dev": return .coder
            case "critic", "review", "reviewer", "verify", "verifier", "judge": return .critic
            default: return nil
            }
        }
        // Accept the COMPOSITE names we advertise ("worker/researcher", "coder/builder", "critic/reviewer")
        // — the tool description + error message tell the model to use those exact slash forms, so the parser
        // MUST honor them. Try the whole string, then each token split on / space - , so any advertised or
        // single-synonym form resolves instead of being rejected (the "unknown sub-agent role" bug).
        if let r = match(norm) { return r }
        for tok in norm.split(whereSeparator: { "/ -,".contains($0) }).map(String.init) {
            if let r = match(tok) { return r }
        }
        return nil
    }
}
