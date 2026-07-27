import Foundation

/// `spawn_specialist` — the PROACTIVE half of Claude-exact delegation. The main agent reads the available
/// specialists' descriptions (listed in this tool's description) and delegates a self-contained subtask to
/// the right one, exactly as Claude Code decides to use a subagent from its `description`. The specialist
/// runs HARD-isolated via `SpecialistSpawner` (own context, scoped tools, own model, maxTurns, permission)
/// and only its summary returns.
///
/// Bounded by construction: the spawned specialist's tool ceiling is `baseTools`, which the caller builds
/// WITHOUT `spawn_specialist`/`spawn_agent` — so a named specialist cannot recursively fan out.
public struct SpawnSpecialistTool: AgentTool {
    public let name = "spawn_specialist"
    public var description: String {
        guard !specialists.isEmpty else {
            return "Delegate a self-contained subtask to a named specialist agent. (No specialists are " +
                   "configured yet — create one with `/agent new` or a .kist/agents file.)"
        }
        let roster = specialists.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        return "Delegate a self-contained subtask to a NAMED specialist agent that is purpose-built for it. " +
               "The specialist runs in its own context with its own tools/model and returns only a summary — " +
               "use it when a task squarely matches one of these. Provide the full subtask in 'task' (the " +
               "specialist cannot see this conversation).\nAvailable specialists:\n\(roster)"
    }
    public let parameters = [
        ToolParameter(name: "agent", type: "string", description: "The specialist's name (exact).", required: true),
        ToolParameter(name: "task", type: "string", description: "The complete, self-contained subtask.", required: true),
    ]

    private let specialists: [SpecialistDefinition]
    private let spawner: SpecialistSpawner
    private let approvalTools: Set<String>   // inherited from the parent — a specialist can't widen consent

    public init(specialists: [SpecialistDefinition], spawner: SpecialistSpawner, approvalTools: Set<String> = []) {
        self.specialists = specialists
        self.spawner = spawner
        self.approvalTools = approvalTools
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let agent = try requireString("agent", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        let task = try requireString("task", from: arguments)
        guard let def = specialists.first(where: { $0.name == agent }) else {
            let names = specialists.map(\.name).joined(separator: ", ")
            return .failure("no specialist named '\(agent)'. Available: \(names.isEmpty ? "(none)" : names)")
        }
        // permissionMode "plan" ⇒ read-only run; other modes keep the inherited approval set (the REPL's
        // explicit `use <agent>` path applies full permissionMode→tier fidelity).
        let planMode = def.permissionMode?.lowercased().replacingOccurrences(of: " ", with: "") == "plan"
        let outcome = await spawner.run(specialist: def, task: task, approvalTools: approvalTools, planMode: planMode)
        return ToolResult(
            success: outcome.success,
            output: outcome.summary,
            error: outcome.success ? nil : outcome.summary,
            metadata: ["specialist": def.name, "specialist_iterations": String(outcome.iterations)])
    }
}
