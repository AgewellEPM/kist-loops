import Foundation

/// Lazy descendants avoid eager recursive registries. Every hop intersects its parent's actual
/// capability set and decrements depth; definitions can narrow tools, never replenish depth/budget.
public enum AgentTeamTools {
    public typealias ChildFactory = @Sendable (ProviderBinding, ToolContext, [String]?, Int) -> ToolRegistry

    /// Explicit metadata destinations of fixed-path host tools. General child file writes remain
    /// confined to the worktree; the recorded envelope also names persistent agent registration.
    static func registryDirectories(in tools: ToolRegistry) -> [String] {
        tools.all().compactMap { ($0 as? CreateAgentTool)?.registryDirectory }
    }

    public static func make(
        providers: ProviderRegistry, binding: ProviderBinding, roles: RoleBindings? = nil,
        baseTools: ToolRegistry, context: ToolContext, sink: RuntimeEventSink = NullEventSink(),
        interactor: RuntimeInteractor = AutoApproveInteractor(), approvalTools: Set<String> = [],
        specialistApprovalTools: Set<String> = [], maxIterations: Int = 50,
        spawnLevels: Int = 2, extendedThinking: Bool = false, budget: BudgetLedger? = nil,
        checkpoints: LoopCheckpointStore? = nil,
        ceiling: [String]? = nil, registryProject: BuilderWorkspaceRootIdentity? = nil,
        delegationRegistry: AsyncDelegationRegistry = .shared
    ) -> ToolRegistry {
        let project = registryProject ?? context.agentMemory?.project
            ?? (try? BuilderWorkspaceRootIdentity.capture(rootPath: context.projectRoot))
        let registryRoot = project?.canonicalPath ?? context.projectRoot
        let controlNames = delegationRegistry.controlTools().map(\.name)
        let delegationNames = ["spawn_agent", "spawn_specialist"] + controlNames
        let foundation = baseTools.all().filter { !delegationNames.contains($0.name) && !["create_agent", "list_agents"].contains($0.name) }
        let memoryTools: [any AgentTool] = context.agentMemory == nil ? [] : [SharedAgentMemoryTool()]
        let offered = Set(foundation.map(\.name) + memoryTools.map(\.name)
                          + ["create_agent", "list_agents", "ask_user"]
                          + (spawnLevels > 0 ? delegationNames : []))
        let allowed = offered.intersection(ceiling.map(Set.init) ?? offered)
        let common = ToolRegistry(foundation + memoryTools + [
            ListAgentsTool(registryRoot: registryRoot),
            CreateAgentTool(ceiling: allowed.sorted(), maxIterations: maxIterations,
                            providers: providers, registryProject: project),
            AskUserTool(interactor: interactor),
        ]).scoped(to: allowed.sorted())
        guard spawnLevels > 0 else { return common }
        func childFactory(approvalFloor: Set<String>) -> ChildFactory {
            { selected, childContext, childCeiling, childTurnCap in
                make(providers: providers, binding: selected, roles: roles, baseTools: baseTools,
                     context: childContext, sink: sink, interactor: interactor,
                     approvalTools: approvalFloor, specialistApprovalTools: specialistApprovalTools,
                     maxIterations: min(maxIterations, childTurnCap), spawnLevels: spawnLevels - 1,
                     extendedThinking: extendedThinking, budget: budget, checkpoints: checkpoints,
                     ceiling: allowed.intersection(childCeiling.map(Set.init) ?? allowed).sorted(),
                     registryProject: project, delegationRegistry: delegationRegistry)
            }
        }
        let generic = SpawnAgentTool(
            providers: providers, providerId: binding.providerId, model: binding.model, roles: roles,
            baseTools: common, sink: sink, interactor: interactor, approvalTools: approvalTools,
            maxIterations: maxIterations, delegationDepth: spawnLevels - 1,
            extendedThinking: extendedThinking, budget: budget, delegationRegistry: delegationRegistry,
            childToolsFactory: childFactory(approvalFloor: approvalTools), checkpoints: checkpoints)
        let specialistSpawner = SpecialistSpawner(
            providers: providers, baseTools: common, context: context, sink: sink, interactor: interactor,
            roleDefault: binding, defaultMaxIterations: maxIterations,
            extendedThinking: extendedThinking, budget: budget,
            childToolsFactory: childFactory(approvalFloor: approvalTools.union(specialistApprovalTools)),
            additionalToolNames: Array(allowed.intersection(delegationNames)), checkpoints: checkpoints,
            delegationDepthRemaining: spawnLevels - 1)
        let specialists = SpawnSpecialistTool(
            specialists: [], spawner: specialistSpawner,
            approvalTools: approvalTools.union(specialistApprovalTools), delegationRegistry: delegationRegistry,
            registry: SpecialistRegistry(projectRoot: registryRoot))
        return ToolRegistry(common.all() + [generic, specialists]).scoped(to: allowed.sorted())
    }
}
