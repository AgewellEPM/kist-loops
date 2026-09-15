import Foundation

/// `spawn_specialist` — the PROACTIVE half of Claude-exact delegation. The main agent reads the available
/// specialists' descriptions (listed in this tool's description) and delegates a self-contained subtask to
/// the right one, exactly as Claude Code decides to use a subagent from its `description`. The specialist
/// runs HARD-isolated via `SpecialistSpawner` (own context, scoped tools, own model, maxTurns, permission)
/// and only its summary returns.
///
/// Bounded by construction: the host child factory narrows tools, turns and remaining delegation
/// depth on each hop. Legacy callers without that factory do not grant recursive delegation.
public struct SpawnSpecialistTool: AgentTool, DelegationAgentTool, AsyncDelegationRegistryProviding {
    public let name = "spawn_specialist"
    public var description: String {
        let specialists = currentSpecialists()
        guard !specialists.isEmpty else {
            return "Delegate a self-contained subtask to a named specialist agent. (No specialists are " +
                   "configured yet — call create_agent, then spawn_specialist in this same session.)"
        }
        let roster = specialists.prefix(20).map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        return "Delegate a self-contained subtask to a NAMED specialist agent that is purpose-built for it. " +
               "The specialist runs in its own context with its own tools/model and returns only a summary — " +
               "use it when a task squarely matches one of these. Provide the full subtask in 'task' (the " +
               "specialist receives authorized shared recall). Use list_agents to search the complete current registry. " +
               "Join background work before ending your turn; unfinished children are cancelled and drained."
               + "\nAvailable specialists (showing up to 20 of \(specialists.count)):\n\(roster)"
    }
    public let parameters = [
        ToolParameter(name: "agent", type: "string", description: "The specialist's name (exact).", required: true),
        ToolParameter(name: "task", type: "string", description: "The complete, self-contained subtask.", required: true),
        ToolParameter(name: "background", type: "boolean", description: "Run concurrently in a mandatory isolated worktree and return a handle immediately.", required: false),
    ]

    private let specialists: [SpecialistDefinition]
    private let registry: SpecialistRegistry?
    private let spawner: SpecialistSpawner
    private let approvalTools: Set<String>   // inherited from the parent — a specialist can't widen consent
    public let delegationRegistry: AsyncDelegationRegistry

    public init(specialists: [SpecialistDefinition], spawner: SpecialistSpawner,
                approvalTools: Set<String> = [],
                delegationRegistry: AsyncDelegationRegistry = .shared,
                registry: SpecialistRegistry? = nil) {
        self.specialists = specialists
        self.registry = registry
        self.spawner = spawner
        self.approvalTools = approvalTools
        self.delegationRegistry = delegationRegistry
    }

    private func currentSpecialists() -> [SpecialistDefinition] { registry?.load() ?? specialists }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        guard spawner.defaultMaxIterations > 0 else { return .failure("the inherited specialist turn budget is exhausted") }
        let agent = try requireString("agent", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        let task = try requireString("task", from: arguments)
        let specialists = currentSpecialists()
        guard let def = specialists.first(where: { $0.name == agent }) else {
            let names = specialists.prefix(20).map(\.name).joined(separator: ", ")
            return .failure("no specialist named '\(agent)'. Available: \(names.isEmpty ? "(none)" : names)")
        }
        // permissionMode "plan" ⇒ read-only run; other modes keep the inherited approval set (the REPL's
        // explicit `use <agent>` path applies full permissionMode→tier fidelity).
        let planMode = def.permissionMode?.lowercased().replacingOccurrences(of: " ", with: "") == "plan"
        let hostChildIntent = (arguments[DelegationGrant.childIntentArgument] as? String)
            .flatMap(TaskBrief.Intent.init(rawValue:))
        let hostPriorContext = PriorResultContext(
            substantiveSummary: arguments[DelegationGrant.priorSummaryArgument] as? String,
            artifactReferences: arguments[DelegationGrant.priorArtifactsArgument]
                as? [String] ?? [])
            .revalidated(projectRoot: context.projectRoot)
        if planMode, hostChildIntent?.expectsMutation == true {
            return .failure("specialist '\(def.name)' is plan-only and cannot satisfy the host-bound mutation delegation")
        }
        let childIntent = planMode ? TaskBrief.Intent.plan
            : (hostChildIntent ?? PromptCompiler.inferIntent(task, mode: .delegated))
        if optionalBool("background", from: arguments) ?? false {
            return await spawnBackground(definition: def, task: task, childIntent: childIntent,
                                         advisoryContext: hostPriorContext,
                                         planMode: planMode, context: context)
        }
        let outcome = await spawner.run(specialist: def, task: task, resolvedIntent: childIntent,
                                        advisoryContext: hostPriorContext,
                                        approvalTools: approvalTools, planMode: planMode,
                                        parentContext: context)
        var metadata = [
            "specialist": def.name,
            "specialist_iterations": String(outcome.iterations),
            "delegation_status": "completed",
        ]
        let isolated = def.isolation?.lowercased() == "worktree"
        if outcome.success, !planMode, !isolated,
           PromptCompiler.expectedOutcome(intent: childIntent, mode: .delegated) == .mutation {
            metadata["sub_agent_expected_outcome"] = TaskBrief.ExpectedOutcome.mutation.rawValue
            metadata["delegation_scope"] = "parent-workspace"
        }
        return ToolResult(
            success: outcome.success,
            output: outcome.summary,
            error: outcome.success ? nil : outcome.summary,
            metadata: metadata)
    }

    private func spawnBackground(definition def: SpecialistDefinition, task: String,
                                 childIntent: TaskBrief.Intent,
                                 advisoryContext: PriorResultContext,
                                 planMode: Bool, context: ToolContext) async -> ToolResult {
        guard let worktree = GitIsolation.makeWorktree(
            repo: context.projectRoot, label: def.name,
            nowEpoch: Date().timeIntervalSince1970) else {
            return .failure("background specialist requires worktree isolation, but no worktree could be created; refusing live-tree execution")
        }
        let available = SpecialistSpawner.mcpScopedCeiling(
            spawner.baseTools.names + spawner.additionalToolNames + ["ask_user"], mcpServers: def.mcpServers)
        let active = await context.skillTracker?.activeToolAllowlist()
        let inherited = active.map { allowed in available.filter { allowed.contains($0) } } ?? available
        let requestedNames = def.resolvedTools(ceiling: inherited)
        let binding = def.resolvedModel(aliasTable: spawner.aliasTable, roleDefault: spawner.roleDefault)
            ?? spawner.roleDefault ?? ProviderBinding(providerId: "")
        let preview = spawner.childToolsFactory?(binding, context, requestedNames,
                                                min(def.maxTurns ?? spawner.defaultMaxIterations, spawner.defaultMaxIterations))
            ?? spawner.baseTools.scoped(to: requestedNames)
        let childNames = Set(preview.names + (requestedNames.contains("ask_user") ? ["ask_user"] : []) + ["delegation_updates"])
        let parentNames = Set(inherited + ["delegation_updates"])
        func servers(_ names: Set<String>) -> Set<String> {
            Set(names.compactMap { name -> String? in
                guard ReversibilityClassifier.isMCPTool(name) else { return nil }
                return name.components(separatedBy: MCPClientManager.namespaceSeparator).first
            })
        }
        let iterations = max(1, min(def.maxTurns ?? spawner.defaultMaxIterations,
                                    spawner.defaultMaxIterations))
        let remainingTokens = await spawner.budget?.remaining()
        let metadataPaths = AgentTeamTools.registryDirectories(in: preview)
        let childCeiling = DelegationCapabilityCeiling(
            allowedToolNames: childNames, allowedMCPServers: servers(childNames),
            allowedProjectPaths: [worktree.path] + metadataPaths, maxIterations: iterations,
            maxTokens: remainingTokens, maxDelegationDepth: spawner.delegationDepthRemaining,
            requiresMutationApproval: true)
        let parentCeiling = DelegationCapabilityCeiling(
            allowedToolNames: parentNames, allowedMCPServers: servers(parentNames),
            allowedProjectPaths: [context.projectRoot, worktree.path] + metadataPaths,
            maxIterations: spawner.defaultMaxIterations, maxTokens: remainingTokens,
            maxDelegationDepth: spawner.delegationDepthRemaining,
            requiresMutationApproval: true)
        let request = DelegationRequest(role: def.name, task: task, capabilityCeiling: childCeiling)
        do {
            let handle = try await delegationRegistry.spawn(request, parentCeiling: parentCeiling) { execution in
                let before = await spawner.budget?.spentTokens() ?? 0
                let outcome = await spawner.run(
                    specialist: def, task: task, resolvedIntent: childIntent,
                    advisoryContext: advisoryContext,
                    approvalTools: approvalTools, planMode: planMode,
                    forceWorktreeIsolation: true, preparedWorktree: worktree,
                    steeringMailbox: execution.steering, parentContext: context)
                let evidence = ReasoningEvidenceReference(
                    id: execution.handle.id + ":summary", kind: .delegation,
                    locator: def.name, summary: outcome.summary)
                let check = ReasoningCheckReceipt(
                    id: execution.handle.id + ":completion", name: "specialist completion",
                    state: outcome.success ? .passed : .failed, evidenceID: evidence.id)
                let progress = ReasoningProgressReceipt(
                    evidence: .delegationCompleted(effectID: execution.handle.id,
                                                   childID: outcome.checkpointId,
                                                   artifactIDs: []))
                let risks = outcome.success ? [] : [ReasoningRiskReceipt(
                    level: .high, summary: "background specialist did not complete successfully")]
                guard outcome.success else {
                    throw DelegationRegistryError.failed(outcome.summary)
                }
                let after = await spawner.budget?.spentTokens() ?? before
                return DelegationResult(
                    handleID: execution.handle.id, summary: outcome.summary,
                    artifacts: [], checks: [check], evidence: [evidence], risks: risks,
                    progress: [progress],
                    childCheckpointID: outcome.checkpointId.isEmpty ? nil : outcome.checkpointId,
                    tokensSpent: max(0, after - before))
            }
            return ToolResult(
                success: true, output: try DelegationProjection.encode(handle),
                metadata: ["delegation_handle": handle.id, "delegation_status": "running",
                           "specialist": def.name])
        } catch {
            GitIsolation.discard(worktree)
            return .failure("could not start background specialist: \(error)")
        }
    }
}
