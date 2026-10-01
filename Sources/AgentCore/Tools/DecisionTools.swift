import Foundation

public struct DecideTool: ReadOnlyAgentTool {
    public let name = "decide"
    public let description = "Judge a focused state capsule with batched Jev-style choice, noul (boolean probability), or score questions. Use for routing, comparison, rubric grading, or selecting a tool design. Results are advisory; confidence is distribution concentration, not proof or permission. Identical requests reuse a short session cache."
    public let parameters = [
        ToolParameter(name: "state", type: "object", description: "Focused evidence capsule; wrap text as {text: ...} or records as {records: [...]}. Whole request <=64 KiB."),
        ToolParameter(name: "questions", type: "object", description: "1–64 named objects: {type: choice|noul|score, instructions: string, criteria: ...}. choice: 2–26 option names mapped to descriptions/null; noul: optional true/false descriptions; score: 2–26 descriptions lowest first.")
    ]
    let engine: DecisionEngine
    public init(engine: DecisionEngine) { self.engine = engine }
    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        guard let state = arguments["state"], let questions = arguments["questions"] as? [String: Any] else {
            throw ToolError.invalidParameter("decide needs state and questions")
        }
        return try await engine.evaluate(state: state, questions: questions)
    }
}

/// Saving a fixed-path question definition needs no compiler/planner mission.
/// This route exposes only decision operations; it grants no code or shell access.
public enum DecisionToolRequest {
    public static let actionTools: Set<String> = ["decide", "decision_tool", "ask_user"]
    public static func matches(_ request: String) -> Bool {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #"\A(?:please\s+)?(?:(?:can|could|would)\s+you\s+)?(?:create|save|make)\s+(?:(?:a|an|one|new|reusable)\s+){0,3}decision(?:_tool|\s+tool)\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    public static func isDefinitionOnly(_ trajectory: [ActionRecord]) -> Bool {
        let mutations = trajectory.filter { $0.observedEffects.mutation != .none }
        return !mutations.isEmpty && mutations.allSatisfy {
            $0.tool == "decision_tool" && $0.observedEffects.mutation == .nonSource
        }
    }
}

/// Declarative tools designed by the model are immediately callable through this
/// same registry entry. They cannot choose providers, run code or grant authority.
public struct DecisionTool: AgentTool {
    public let name = "decision_tool"
    public let description = "Create, inspect, list, and run reusable project-local decision tools. Design typed questions once, save them under .kist/decision-tools, then run on new state. Uses the same decision engine and session budget as decide. To build executable parsers/converters, use custom_tool; decision results do not activate code or change permissions."
    public let parameters = [
        ToolParameter(name: "action", type: "string", description: "create | get | list | run"),
        ToolParameter(name: "name", type: "string", description: "Identifier for create/get/run", required: false),
        ToolParameter(name: "description", type: "string", description: "Purpose of this decision tool (create)", required: false),
        ToolParameter(name: "questions", type: "object", description: "Same named question schema as decide (create)", required: false),
        ToolParameter(name: "state", type: "object", description: "Focused evidence capsule to judge (run)", required: false)
    ]
    public var supportedActions: [String] { ["create", "get", "list", "run"] }
    let engine: DecisionEngine
    public init(engine: DecisionEngine) { self.engine = engine }
    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let action = try requireString("action", from: arguments)
        let root = try context.confinedRoot()
        let directory = ".kist/decision-tools"
        if action == "list" {
            let entries: [(name: String, isDir: Bool)]
            do { entries = try root.entries(directory) }
            catch ToolError.notFound { entries = [] }
            let names = entries.filter { !$0.isDir && $0.name.hasSuffix(".json") }
                .map { String($0.name.dropLast(5)) }.filter(DecisionQuestion.validName).sorted()
            return ToolResult(success: true, output: try DecisionEngine.json(["tools": names]))
        }
        let toolName = try requireString("name", from: arguments)
        guard DecisionQuestion.validName(toolName) else { throw ToolError.invalidParameter("invalid decision tool name") }
        let path = directory + "/" + toolName + ".json"
        switch action {
        case "create":
            guard let questions = arguments["questions"] as? [String: Any] else { throw ToolError.missingParameter("questions") }
            _ = try DecisionQuestion.parseAll(questions)
            let description = (arguments["description"] as? String) ?? "Reusable decision tool"
            guard description.utf8.count <= 2048 else { throw ToolError.invalidParameter("description too long") }
            let encoded = try DecisionEngine.json(["schema": "kist.decision-tool.v1", "name": toolName,
                                                   "description": description, "questions": questions])
            guard encoded.utf8.count < DecisionEngine.maxRequestBytes else { throw ToolError.invalidParameter("decision tool exceeds 64 KiB") }
            let bytes = encoded + "\n"
            try root.writeString(path, bytes, createParents: true)
            guard try readDefinition(path, root: root) == bytes else {
                throw ToolError.execution("decision tool did not persist as written")
            }
            return ToolResult(success: true, output: try DecisionEngine.json(["name": toolName, "path": path,
                "sha256": DecisionEngine.hash(bytes), "call": "decision_tool(action=run, name=\(toolName), state=...)"]),
                metadata: ["path": path, "sha256": DecisionEngine.hash(bytes),
                           "written": "true", "decision_definition_validated": "true"])
        case "get", "run":
            let text = try readDefinition(path, root: root)
            guard let manifest = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  Set(manifest.keys) == ["schema", "name", "description", "questions"],
                  manifest["schema"] as? String == "kist.decision-tool.v1", manifest["name"] as? String == toolName,
                  let description = manifest["description"] as? String, description.utf8.count <= 2048,
                  let questions = manifest["questions"] as? [String: Any] else { throw ToolError.invalidParameter("invalid decision tool manifest") }
            _ = try DecisionQuestion.parseAll(questions)
            if action == "get" { return ToolResult(success: true, output: text) }
            guard let state = arguments["state"] else { throw ToolError.missingParameter("state") }
            return try await engine.evaluate(state: state, questions: questions)
        default: throw ToolError.invalidParameter("unknown decision_tool action")
        }
    }

    private func readDefinition(_ path: String, root: ConfinedRoot) throws -> String {
        let data = try root.readStableData(path, maxBytes: DecisionEngine.maxRequestBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw ToolError.execution("decision definition is not UTF-8") }
        return text
    }
}
