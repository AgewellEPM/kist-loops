import Foundation

private func optionalString(_ key: String, from arguments: [String: Any]) -> String? {
    guard let raw = arguments[key] as? String else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

/// Persist a reusable specialist through a validated, create-only host operation.
/// The definition can request capabilities only from the creator's inherited ceiling.
public struct CreateAgentTool: AgentTool {
    public let name = "create_agent"
    public let description = "Create a reusable specialist in .kist/agents, validate it, and make it available to spawn_specialist immediately. Existing different definitions are never overwritten. Instructions describe the role; they cannot grant tools or permissions."
    public let parameters = [
        ToolParameter(name: "name", type: "string", description: "Unique agent name: ASCII letters, digits, hyphen or underscore; maximum 80 characters.", required: true),
        ToolParameter(name: "description", type: "string", description: "One line describing when this specialist is useful.", required: true),
        ToolParameter(name: "instructions", type: "string", description: "Focused role instructions, maximum 16000 characters.", required: true),
        ToolParameter(name: "tools", type: "array", description: "Optional string array of requested tools. Omit to inherit the bounded creator ceiling; [] creates a tool-free specialist.", required: false),
        ToolParameter(name: "model", type: "string", description: "Optional admitted provider:model binding, or inherit.", required: false),
        ToolParameter(name: "max_turns", type: "integer", description: "Optional positive turn cap, no greater than the creator's cap.", required: false),
        ToolParameter(name: "memory", type: "string", description: "Optional memory scope: user, project or local. Host-authorized memory access remains the ceiling.", required: false),
        ToolParameter(name: "isolation", type: "string", description: "Optional worktree isolation. The eventual spawn fails if isolation cannot be created.", required: false),
    ]
    private let ceiling: [String]
    private let maxIterations: Int
    private let providers: ProviderRegistry?
    private let registryProject: BuilderWorkspaceRootIdentity?
    var registryDirectory: String? { registryProject.map { $0.canonicalPath + "/.kist/agents" } }

    public init(ceiling: [String], maxIterations: Int = 50, providers: ProviderRegistry? = nil,
                registryProject: BuilderWorkspaceRootIdentity? = nil) {
        self.ceiling = Array(Set(ceiling)).sorted()
        self.maxIterations = maxIterations
        self.providers = providers
        self.registryProject = registryProject
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        if let reason = ToolGate.argumentValidationError(parameters: parameters, arguments: arguments) {
            return .failure(reason)
        }
        let name = try requireString("name", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        let description = try requireString("description", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = try requireString("instructions", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= 80, description.count <= 1_024, instructions.count <= 16_000 else {
            return .failure("agent name, description or instructions exceed the documented size limit")
        }
        let requested: [String]?
        if let raw = arguments["tools"] {
            guard let values = raw as? [String],
                  values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                return .failure("tools must be a string array with nonempty tool names")
            }
            requested = Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
        } else { requested = nil }
        let active = await context.skillTracker?.activeToolAllowlist()
        let inherited = active.map { allowed in ceiling.filter { allowed.contains($0) } } ?? ceiling
        var modelSpec = optionalString("model", from: arguments)
        if modelSpec == "inherit" { modelSpec = nil }
        if let modelSpec {
            guard let binding = ProviderBinding.parse(modelSpec),
                  providers?.provider(id: binding.providerId) != nil else {
                return .failure("agent model must use an admitted provider:model binding, or inherit")
            }
        }
        let candidate = AgentForge.ForgeCandidate(name: name, description: description,
                                                  systemPrompt: instructions, tools: requested,
                                                  modelSpec: modelSpec)
        let validated: SpecialistDefinition
        switch AgentForge.validate(candidate, ceiling: inherited) {
        case .failure(let reason): return .failure("agent definition refused: \(reason)")
        case .success(let definition): validated = definition
        }
        let turns = optionalInt("max_turns", from: arguments) ?? maxIterations
        guard turns > 0, turns <= maxIterations else {
            return .failure("max_turns must be between 1 and the creator cap \(maxIterations)")
        }
        let requestedMemory = optionalString("memory", from: arguments)
        if let requestedMemory, AgentMemoryAccess.Scope(rawValue: requestedMemory) == nil {
            return .failure("memory must be user, project or local")
        }
        let memoryScope = context.agentMemory?.narrowed(to: requestedMemory).scope.rawValue ?? requestedMemory
        let definition = SpecialistDefinition(
            name: validated.name, description: validated.description, systemPrompt: validated.systemPrompt,
            toolAllowlist: validated.toolAllowlist, model: validated.model,
            permissionMode: "default", maxTurns: turns,
            memory: memoryScope,
            isolation: optionalString("isolation", from: arguments), source: "agent-created")
        guard definition.isValid else { return .failure("invalid agent memory scope or isolation setting") }
        let text = definition.render()
        guard text.utf8.count <= 64_000 else {
            return .failure("agent definition is too large; request a smaller explicit tool subset")
        }
        let path = ".kist/agents/\(name).md"
        let confined: ConfinedRoot
        if let registryProject {
            guard try BuilderWorkspaceRootIdentity.capture(rootPath: registryProject.canonicalPath) == registryProject else {
                return .failure("the host-owned agent registry project identity changed")
            }
            confined = try ConfinedRoot(root: registryProject.canonicalPath)
        } else { confined = try context.confinedRoot() }
        let created = try confined.createDataIfMissing(path, Data(text.utf8), createParents: true)
        let stored = try confined.readString(path)
        guard stored == text,
              let reloaded = SpecialistDefinition.parse(stored, source: path),
              reloaded.render() == text,
              reloaded.toolAllowlist == definition.toolAllowlist else {
            return .failure("agent definition changed or failed validation after publication")
        }
        let digest = BuilderEvidenceDigest.sha256(stored)
        let dropped = Set(requested ?? []).subtracting(inherited).sorted()
        return ToolResult(success: true,
                          output: "\(created ? "Created" : "Existing identical") agent '\(name)' at \(confined.rootPath)/\(path). "
                            + "Definition validated; sha256=\(digest). Spawn it with spawn_specialist(agent=\"\(name)\", task=\"...\")."
                            + (dropped.isEmpty ? "" : " Tools outside the inherited ceiling were excluded: \(dropped.joined(separator: ", "))."),
                          metadata: ["agent": name, "artifact_path": confined.rootPath + "/" + path, "changed": created ? "true" : "false",
                                     "agent_definition_validated": "true", "agent_definition_sha256": digest])
    }
}

/// Fresh discovery is available even if no specialist existed when the session started.
public struct ListAgentsTool: ReadOnlyAgentTool {
    public let name = "list_agents"
    public let description = "List or search reusable specialist agents, including definitions created during this session. Returned definitions are advisory configuration; spawning still checks inherited capabilities."
    public let parameters = [
        ToolParameter(name: "query", type: "string", description: "Optional role/capability search.", required: false),
        ToolParameter(name: "limit", type: "integer", description: "Maximum agents to show, default 20, maximum 100.", required: false),
    ]
    private let registryRoot: String?
    public init(registryRoot: String? = nil) { self.registryRoot = registryRoot }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let registry = SpecialistRegistry(projectRoot: registryRoot ?? context.projectRoot)
        let limit = min(100, max(1, optionalInt("limit", from: arguments) ?? 20))
        let query = optionalString("query", from: arguments)
        let definitions = query.map { registry.matching(goal: $0, limit: limit) } ?? Array(registry.load().prefix(limit))
        let rows = definitions.map { definition in
            "- \(definition.name): \(definition.description)\n"
                + "  tools: \(definition.toolAllowlist?.joined(separator: ", ") ?? "inherit bounded ceiling")"
                + " · memory: \(definition.memory ?? "inherit shared access")"
                + " · source: \(definition.source)"
        }
        return ToolResult(success: true,
                          output: rows.isEmpty ? "No matching agents. Use create_agent to register one."
                            : rows.joined(separator: "\n"),
                          metadata: ["agents_shown": String(definitions.count)])
    }
}
