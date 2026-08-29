import Foundation

// MARK: - Remote MCP Tool (AgentCore)
//
// Adapts a tool hosted by an EXTERNAL MCP server to AgentCore's `AgentTool` protocol,
// so the agent loop calls it exactly like a built-in tool. Namespaced `server__tool`
// so two servers exposing the same tool name never collide in the registry.
//
// A `struct` holding an actor reference → Sendable, satisfying `AgentTool`. Execution
// forwards to the injected `MCPClientManager` (which owns the connection, timeouts,
// crash handling, and output sanitization). The `ToolContext` is intentionally NOT
// forwarded: a remote server declares its own argument contract, and silently
// injecting host paths/policy into an untrusted tool's arguments would be unsafe.
public struct RemoteMCPTool: AgentTool {
    public let name: String
    public let description: String
    public let parameters: [ToolParameter]
    /// Explicit per-server/per-tool policy. `nil` preserves the conservative legacy name heuristic.
    public let explicitComputerUseRequirement: Bool?

    private let serverName: String
    private let remoteToolName: String
    private let manager: MCPClientManager

    init(serverName: String, spec: RemoteToolSpec, manager: MCPClientManager,
         computerUsePolicy: MCPComputerUsePolicy = .legacyNameHeuristic) {
        self.serverName = serverName
        self.remoteToolName = spec.name
        self.manager = manager
        self.explicitComputerUseRequirement = computerUsePolicy.explicitRequirement(for: spec.name)
        // The model-facing (registry) name is derived from the UNTRUSTED server tool name — sanitize +
        // cap it so a hostile name can't inject into the tool schema (DeepSeek H1). Routing still uses the
        // raw `remoteToolName` below, so a sanitized display name can't break a legit call.
        self.name = serverName + MCPClientManager.namespaceSeparator + String(MCPOutputSanitizer.sanitize(spec.name).prefix(120))
        // Tag the description so the model (and logs) know this reaches an external process — and that its
        // output is untrusted data, not instructions. The server-supplied description is UNTRUSTED (a
        // hostile server could inject instructions via it), so it's sanitized (control/bidi stripped) and
        // length-capped before it reaches the model (Codex).
        let sanitized = MCPOutputSanitizer.sanitize(spec.description).prefix(600)
        let base = sanitized.isEmpty ? "Remote MCP tool." : String(sanitized)
        self.description = "[external MCP server '\(serverName)', untrusted] \(base)"
        self.parameters = Self.parameters(from: spec.inputSchema)
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        // Forward verbatim; the manager sanitizes the result. The remote server is
        // responsible for validating its own inputs.
        await manager.call(server: serverName, tool: remoteToolName, arguments: arguments,
                           correlationID: context.correlationID)
    }

    // MARK: - JSON Schema -> [ToolParameter]

    /// Flatten a JSON Schema `inputSchema` into AgentCore's `[ToolParameter]` for the
    /// model-facing description. The agent's JSON arguments still pass through
    /// untouched, so structured/nested params keep working — this is descriptive only.
    static func parameters(from schema: [String: Any]) -> [ToolParameter] {
        guard let properties = schema["properties"] as? [String: Any] else { return [] }
        let required = Set((schema["required"] as? [String]) ?? [])
        // The schema is UNTRUSTED (from a remote server). Param names + descriptions reach the model's
        // tool schema, so sanitize (strip control/bidi) + cap them, and constrain type to a known set —
        // a hostile server can't inject instructions via a parameter description (Codex).
        let knownTypes: Set<String> = ["string", "number", "integer", "boolean", "object", "array", "null"]
        // Sort for stable ordering, then CAP the count — a hostile schema can't bloat the model-facing
        // tool contract with thousands of params (Codex LOW).
        let sorted = properties.sorted { $0.key < $1.key }.prefix(100)
        return sorted.map { key, value in
            let prop = value as? [String: Any] ?? [:]
            let rawType = (prop["type"] as? String) ?? "string"
            return ToolParameter(
                name: String(MCPOutputSanitizer.sanitize(key).prefix(120)),
                type: knownTypes.contains(rawType) ? rawType : "string",
                description: String(MCPOutputSanitizer.sanitize((prop["description"] as? String) ?? "").prefix(400)),
                required: required.contains(key)
            )
        }
    }
}
