import Foundation

/// Injectable registry of agent tools.
///
/// Unlike the GUI app's `ToolRegistry.shared` singleton, this is a plain value you
/// construct with exactly the tools a given runtime should have — the GUI gets its
/// macOS desktop tools, Kist/mcp-server get the headless set, tests get a stub set.
/// `Sendable` so it can be handed to concurrent tool calls.
public struct ToolRegistry: Sendable {
    private let tools: [String: AgentTool]

    /// Build a registry from a list of tools. Later entries win on name collision.
    public init(_ tools: [AgentTool]) {
        var map: [String: AgentTool] = [:]
        for tool in tools { map[tool.name] = tool }
        self.tools = map
    }

    /// The portable, Foundation-only tool set shared by Kist and mcp-server. Pure
    /// filesystem + search + (policy-gated) shell — NO AppKit/desktop-automation tools.
    /// Those stay in the GUI app because they cannot exist on Linux headless.
    public static func headless() -> ToolRegistry {
        ToolRegistry([
            ReadFileTool(),
            WriteFileTool(),
            EditFileTool(),
            NotebookEditTool(),
            ApplyPatchTool(),
            MoveFileTool(),
            MakeDirTool(),
            ListFilesTool(),
            GlobFilesTool(),
            SearchCodeTool(),
            AstGrepTool(),
            AstGrepApplyTool(),
            GitTool(),
            SymbolsTool(),
            ContextBrainTool(),
            CustomTool(),
            ResearchRunTool(),
            RunCommandTool(),
            ManageJobsTool(),
        ])
    }

    /// Narrow this registry to a specialist's tool allowlist — the NO-PRIVILEGE-ESCALATION gate (P2).
    /// The result is the INTERSECTION of the requested names with the tools this registry actually has:
    /// a requested tool that ISN'T in this ceiling is DROPPED, never granted. A forged/authored allowlist
    /// can therefore only ever REMOVE tools, never add one the spawner lacks.
    ///
    /// - `nil` allowlist ⇒ inherit the ceiling (returns self unchanged).
    /// - empty / all-unknown allowlist ⇒ EMPTY registry (fail-closed: a specialist that names only tools
    ///   it can't have gets nothing, not everything).
    ///
    /// Because the narrowed registry literally does not contain the dropped tools, `execute(name:)` on it
    /// returns "unknown tool" for anything outside the allowlist — execution-time enforcement is automatic
    /// (belt + suspenders with this construction-time narrowing).
    public func scoped(to allowlist: [String]?) -> ToolRegistry {
        guard let allowlist else { return self }
        let allowed = Set(allowlist)
        return ToolRegistry(all().filter { allowed.contains($0.name) })
    }

    /// A copy of this registry with one more tool (later wins on a name collision). Used to inject a
    /// per-loop tool that needs runtime state the static registry can't hold (e.g. `ask_user` + interactor).
    public func adding(_ tool: AgentTool) -> ToolRegistry { ToolRegistry(all() + [tool]) }

    public func tool(named name: String) -> AgentTool? { tools[name] }

    public func all() -> [AgentTool] { Array(tools.values) }

    public var names: [String] { tools.keys.sorted() }

    /// Neutral tool definitions for NATIVE tool-calling (providers translate to their schema).
    public func toolSpecs() -> [ToolSpec] {
        all().sorted { $0.name < $1.name }
            .map { ToolSpec(name: $0.name, description: $0.description, parameters: $0.parameters) }
    }

    /// Human-readable one-line-per-tool listing for a system prompt.
    public func descriptions() -> String {
        all().sorted { $0.name < $1.name }.map { tool in
            let params = tool.parameters.map { "\($0.name): \($0.type)\($0.required ? "" : "?")" }
                .joined(separator: ", ")
            return "- \(tool.name)(\(params)): \(tool.description)"
        }.joined(separator: "\n")
    }

    /// OpenAI-style `tools` JSON array for function-calling requests.
    public func asJSON() -> [[String: Any]] {
        all().sorted { $0.name < $1.name }.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": [
                        "type": "object",
                        "properties": Dictionary(uniqueKeysWithValues: tool.parameters.map { p in
                            (p.name, ["type": p.type, "description": p.description])
                        }),
                        "required": tool.parameters.filter { $0.required }.map { $0.name },
                    ],
                ],
            ]
        }
    }

    /// Execute a tool by name, never throwing — unknown tools and thrown errors are
    /// normalized into a failed `ToolResult` so the agent loop can observe and recover.
    public func execute(name: String, arguments: [String: Any], context: ToolContext) async -> ToolResult {
        // Audit at THE choke point (council #1): one immutable record per invocation, capturing the
        // tool + an arg DIGEST (values hashed, never logged raw) + the enforcement OUTCOME. Records
        // BLOCKED attempts too — a denied call is exactly what forensics needs to see. Best-effort.
        let (argKeys, argsDigest) = AuditLog.digest(arguments)
        // Read the active scope ONCE — same value drives the audit field AND the block decision, so a
        // concurrent skill-load can't make them disagree (Codex LOW).
        let activeAllowlist = await context.skillTracker?.activeToolAllowlist()
        let activeScope = activeAllowlist.map { $0.sorted() }
        func audit(_ outcome: String, _ success: Bool) async {
            await context.auditLog?.record(AuditEntry(at: Self.now(), tool: name, argKeys: argKeys,
                                                      argsDigest: argsDigest, outcome: outcome,
                                                      success: success, scope: activeScope))
        }

        guard let tool = tools[name] else {
            await audit("unknown_tool", false)
            return .failure("unknown tool: \(name)")
        }
        // Authorization scope (plan-only / needs-approval), skill capability scope, audit, secret-mask,
        // and the run are ALL the SHARED gate (ToolGate) now — the one enforcement site that composite
        // sub-actions also route through, so a research_run sub-action can't skip the action-class gate
        // (Codex HIGH). execute only owns the unknown-tool audit above. Forward the allow-list we ALREADY
        // read so the gate doesn't re-read it (one read drives both audits + the decision; DeepSeek LOW).
        return await ToolGate.run(name: name, arguments: arguments, context: context,
                                  precomputedAllowlist: .some(activeAllowlist)) {
            try await tool.execute(arguments: arguments, context: context)
        }
    }

    /// Epoch seconds without `Date()` ambiguity (kept simple + Sendable).
    private static func now() -> Double { Date().timeIntervalSince1970 }
}
