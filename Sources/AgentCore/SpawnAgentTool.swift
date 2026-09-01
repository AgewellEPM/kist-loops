import Foundation

/// Multi-agent delegation as a tool (the Claude-Code "Task" pattern). The agent calls
/// `spawn_agent` with a self-contained subtask; a FRESH `HeadlessAgentLoop` runs it to
/// completion in the SAME project (same confinement/sandbox) with its OWN context window, and
/// only the sub-agent's final summary returns to the parent — keeping the parent's context lean.
///
/// Recursion is bounded by construction: nested sub-agents receive `spawn_agent` only while a
/// caller-supplied delegation-depth budget remains, so a team can ask for help without forking
/// unboundedly.
public struct SpawnAgentTool: AgentTool, DelegationAgentTool, AsyncDelegationRegistryProviding {
    public let name = "spawn_agent"
    public var description: String {
        "Delegate a focused, SELF-CONTAINED subtask to a fresh sub-agent. " +
        "It has the same file/search tools and the same project, runs independently, and returns " +
        "only its final summary. Use it to isolate or parallelize a chunk of work. " +
        "Provide the full subtask in 'task' — the sub-agent cannot see this conversation. " +
        "Optionally set role to planner, worker/researcher, coder/builder, or critic/reviewer; " +
        "current role bindings: \(roleBindings.summary). You may also set provider/model directly " +
        "to spawn any configured AI for this subtask. " +
        "Set background=true to receive a typed handle immediately; use join_agent, steer_agent, " +
        "or cancel_agent to control that isolated run. " +
        (delegationDepthRemaining > 0
            ? "This sub-agent may delegate \(delegationDepthRemaining) more level(s) to teammates if it gets stuck."
            : "This sub-agent cannot delegate further.")
    }
    public let parameters = [
        ToolParameter(name: "task", type: "string", description: "The complete, self-contained subtask for the sub-agent.", required: true),
        ToolParameter(name: "role", type: "string", description: "Optional specialist role for the sub-agent: planner, worker/researcher, coder/builder, or critic/reviewer.", required: false),
        ToolParameter(name: "provider", type: "string", description: "Optional provider id/name override for this sub-agent, e.g. deepseek, gemini, openai, mimo.", required: false),
        ToolParameter(name: "model", type: "string", description: "Optional model id override for this sub-agent. If provider is omitted, it overrides the selected role/default provider's model.", required: false),
        ToolParameter(name: "background", type: "boolean", description: "Run concurrently in a mandatory isolated worktree and return a handle immediately.", required: false),
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
    public let delegationRegistry: AsyncDelegationRegistry

    public init(providers: ProviderRegistry, providerId: String, model: String?,
                roles: RoleBindings? = nil,
                baseTools: ToolRegistry, sink: RuntimeEventSink = NullEventSink(),
                interactor: RuntimeInteractor = AutoApproveInteractor(), approvalTools: Set<String> = [],
                maxIterations: Int = 10,
                delegationDepth: Int = 0,
                extendedThinking: Bool = false,
                budget: BudgetLedger? = nil,
                delegationRegistry: AsyncDelegationRegistry = .shared) {
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
        self.delegationRegistry = delegationRegistry
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
        let hostChildIntent = optionalString(DelegationGrant.childIntentArgument, from: arguments)
            .flatMap(TaskBrief.Intent.init(rawValue:))
        let taskBrief = PromptCompiler.compile(task, role: role, mode: .delegated,
                                               resolvedIntent: hostChildIntent)
        let hostPriorContext = PriorResultContext(
            substantiveSummary: optionalString(
                DelegationGrant.priorSummaryArgument, from: arguments),
            artifactReferences: arguments[DelegationGrant.priorArtifactsArgument]
                as? [String] ?? [])
            .revalidated(projectRoot: context.projectRoot)
        let compiledTask = taskBrief.prompt
            + (hostPriorContext.isEmpty ? "" : "\n\n" + hostPriorContext.promptBlock)
        // CAPABILITY CEILING (Codex gate S1#2): if a loaded skill scoped the PARENT to a tool
        // allow-list, the child must NOT escape it. A spawned agent rediscovers skills with a fresh
        // tracker, so without this a parent scoped to e.g. [read_file spawn_agent] could spawn a child
        // that writes. Scope the child's tools to the parent's active allow-list (intersection-only,
        // so the child can only ever be narrower).
        let parentCeiling = await context.skillTracker?.activeToolAllowlist()
        let childTools = parentCeiling.map { subTools(for: selected).scoped(to: Array($0)) } ?? subTools(for: selected)
        let background = optionalBool("background", from: arguments) ?? false
        if background {
            return await spawnBackground(task: task, compiledTask: compiledTask, role: role,
                                         intent: taskBrief.intent,
                                         selected: selected, childTools: childTools, context: context)
        }
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
        let outcome = await sub.run(goal: compiledTask, rawRequest: task,
                                    resolvedIntent: taskBrief.intent)
        var metadata = [
            "sub_agent_iterations": String(outcome.iterations),
            "sub_agent_provider": selected.providerId,
            "delegation_status": "completed",
            "delegation_scope": "parent-workspace",
        ]
        if let model = selected.model { metadata["sub_agent_model"] = model }
        if let role { metadata["sub_agent_role"] = role.rawValue }
        if outcome.success {
            metadata["sub_agent_expected_outcome"] = taskBrief.expectedOutcome.rawValue
        }
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
            budget: budget,   // propagate the shared ledger down the whole delegation tree
            delegationRegistry: delegationRegistry
        )
        return ToolRegistry(baseTools.all() + [nestedSpawn])
    }

    private func spawnBackground(task: String, compiledTask: String, role: AgentRole?,
                                 intent: TaskBrief.Intent,
                                 selected: ProviderBinding, childTools: ToolRegistry,
                                 context: ToolContext) async -> ToolResult {
        guard let worktree = GitIsolation.makeWorktree(
            repo: context.projectRoot, label: "background-agent",
            nowEpoch: Date().timeIntervalSince1970) else {
            return .failure("background delegation requires worktree isolation, but no worktree could be created; refusing live-tree execution")
        }
        let sandbox = context.sandbox.confineWrites ? context.sandbox
            : SandboxPolicy.confined(denyNetwork: false, confineWrites: true)
        let runContext = ToolContext(
            projectRoot: worktree.path, shell: context.shell, sandbox: sandbox,
            authorizationScope: context.authorizationScope,
            scopeOverrideApproved: context.scopeOverrideApproved,
            skillLocations: context.skillLocations, skillTracker: context.skillTracker,
            auditLog: context.auditLog, externalReadRoots: context.externalReadRoots,
            correlationID: context.correlationID, traceRecorder: context.traceRecorder)
        let inboxName = DelegationInboxTool(mailbox: DelegationSteeringMailbox()).name
        let childNames = Set(childTools.names + [inboxName])
        let mcpServers = Set(childNames.compactMap { name -> String? in
            guard ReversibilityClassifier.isMCPTool(name) else { return nil }
            return name.components(separatedBy: MCPClientManager.namespaceSeparator).first
        })
        let remainingTokens = await budget?.remaining()
        let childCeiling = DelegationCapabilityCeiling(
            allowedToolNames: childNames, allowedMCPServers: mcpServers,
            allowedProjectPaths: [worktree.path], maxIterations: maxIterations,
            maxTokens: remainingTokens, maxDelegationDepth: delegationDepthRemaining,
            requiresMutationApproval: true)
        let parentCapability = DelegationCapabilityCeiling(
            allowedToolNames: childNames, allowedMCPServers: mcpServers,
            allowedProjectPaths: [context.projectRoot, worktree.path], maxIterations: maxIterations,
            maxTokens: remainingTokens, maxDelegationDepth: delegationDepthRemaining,
            requiresMutationApproval: true)
        let request = DelegationRequest(role: role?.rawValue ?? "worker", task: task,
                                        capabilityCeiling: childCeiling)
        do {
            let handle = try await delegationRegistry.spawn(request, parentCeiling: parentCapability) { execution in
                let before = await self.budget?.spentTokens() ?? 0
                let tools = childTools.adding(DelegationInboxTool(mailbox: execution.steering))
                let backgroundGoal = compiledTask + """


                BACKGROUND CONTROL: call delegation_updates before each major phase and before your
                final response; incorporate every returned parent message without widening scope.
                """
                let loop = HeadlessAgentLoop(
                    providers: self.providers, providerId: selected.providerId, model: selected.model,
                    tools: tools, context: runContext, sink: self.sink,
                    interactor: self.interactor, approvalTools: self.approvalTools,
                    maxIterations: self.maxIterations, extendedThinking: self.extendedThinking,
                    budget: self.budget,
                    contextWindow: ContextWindowManager.forModel(
                        capabilities: self.providers.capabilities(providerId: selected.providerId,
                                                                  model: selected.model)))
                let outcome = await loop.run(goal: backgroundGoal, rawRequest: task,
                                             resolvedIntent: intent)
                let committed = GitIsolation.commit(worktree, message: "background agent: \(task.prefix(60))")
                let changed = GitIsolation.committedChangedPaths(worktree)
                if changed.isEmpty { GitIsolation.discard(worktree) }
                let artifacts = changed.map {
                    ReasoningArtifactReference(
                        id: execution.handle.id + ":" + $0, path: $0,
                        revision: worktree.branch + (committed ? ":committed" : ":uncommitted"))
                }
                let evidence = ReasoningEvidenceReference(
                    id: execution.handle.id + ":summary", kind: .delegation,
                    locator: worktree.branch, summary: outcome.summary)
                let check = ReasoningCheckReceipt(
                    id: execution.handle.id + ":completion", name: "delegated task completion",
                    state: outcome.success ? .passed : .failed, evidenceID: evidence.id)
                var progress = artifacts.map {
                    ReasoningProgressReceipt(evidence: .artifact($0))
                }
                progress.append(ReasoningProgressReceipt(
                    evidence: .delegationCompleted(effectID: execution.handle.id,
                                                   childID: outcome.checkpointId,
                                                   artifactIDs: artifacts.map(\.id))))
                var risks: [ReasoningRiskReceipt] = []
                if !outcome.success {
                    risks.append(ReasoningRiskReceipt(level: .high,
                                                       summary: "background delegation did not complete successfully"))
                }
                if !changed.isEmpty && !committed {
                    risks.append(ReasoningRiskReceipt(level: .high,
                                                       summary: "isolated changes remain uncommitted"))
                }
                guard outcome.success else {
                    throw DelegationRegistryError.failed(outcome.summary)
                }
                let after = await self.budget?.spentTokens() ?? before
                return DelegationResult(
                    handleID: execution.handle.id, summary: outcome.summary,
                    artifacts: artifacts, checks: [check], evidence: [evidence], risks: risks,
                    progress: progress,
                    childCheckpointID: outcome.checkpointId.isEmpty ? nil : outcome.checkpointId,
                    tokensSpent: max(0, after - before))
            }
            return ToolResult(
                success: true, output: try DelegationProjection.encode(handle),
                metadata: ["delegation_handle": handle.id, "delegation_status": "running",
                           "sub_agent_provider": selected.providerId])
        } catch {
            GitIsolation.discard(worktree)
            return .failure("could not start background delegation: \(error)")
        }
    }

    private func optionalString(_ key: String, from arguments: [String: Any]) -> String? {
        guard let raw = arguments[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parseRole(_ raw: String?) -> AgentRole? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "planner", "plan": return .planner
        case "worker", "research", "researcher", "analyst", "worker/researcher":
            return .worker
        case "coder", "code", "builder", "build", "developer", "dev", "coder/builder":
            return .coder
        case "critic", "review", "reviewer", "verify", "verifier", "judge", "critic/reviewer":
            return .critic
        default: return nil
        }
    }
}
