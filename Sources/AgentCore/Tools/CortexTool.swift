import Foundation

// The agent's own window into the Cortex — kist's durable, human-readable memory of Luke (how he
// likes to work, per-project facts, and a work journal under ~/.kist/cortex). This is what makes
// kist's memory PERSONAL like Claude's: the MODEL captures what it learns instead of the human
// having to type `/cortex remember`. Every write is plain markdown the user can read/edit/delete
// (audit via `/cortex files`). Low-risk (appends to the user's own memory dir) → not approval-gated.
public struct CortexTool: AgentTool {
    public let name = "cortex"
    public let description = """
    Your durable PERSONAL MEMORY of Luke, persisted across sessions (~/.kist/cortex, human-readable, \
    injected into every session). Capture what lasts:
    - action=remember  a durable PREFERENCE / working rule you learned (e.g. "prefers X over Y", \
    "always commit each increment to its own branch"). Durable facts, not session trivia.
    - action=project   a fact specific to the CURRENT project (architecture, gotcha, decision).
    - action=journal   log what you accomplished this session (one line → the daily work log).
    - action=recall    read back what kist currently knows (preferences + this project + recent journal).
    Use it PROACTIVELY: when Luke states a preference, corrects you, decides something, or you finish \
    meaningful work — remember it so the next session starts already knowing.
    """
    public let parameters = [
        ToolParameter(name: "action", type: "string", description: "remember | project | journal | recall", required: true),
        ToolParameter(name: "text", type: "string", description: "The fact / preference / journal entry to store (omit for recall)", required: false),
        ToolParameter(name: "project", type: "string", description: "Project name for action=project (default: the current project)", required: false),
    ]
    public var supportedActions: [String] { ["remember", "project", "journal", "recall"] }
    public var usageExamples: [String] {
        ["cortex(action=\"remember\", text=\"Luke wants an adversarial review gate before anything is called done\")",
         "cortex(action=\"project\", text=\"kist is Swift/SPM; external MCP servers auto-load from ~/.mcp.json\")",
         "cortex(action=\"journal\", text=\"Wired agent-lsp + added the symbols tool\")",
         "cortex(action=\"recall\")"]
    }
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let action = try requireString("action", from: arguments).lowercased()
        let cortex = CortexMemory()
        switch action {
        case "recall":
            let ctx = cortex.context(projectName: Self.projectName(from: context))
            return ToolResult(success: true, output: ctx.isEmpty ? "(cortex is empty — nothing learned yet)" : ctx,
                              metadata: ["action": "recall"])
        case "remember":
            let text = try requireString("text", from: arguments)
            do { try cortex.remember(text) } catch { return .failure("cortex: could not write preference: \(error)") }
            // Redact the ECHO too — the tool result enters the transcript/logs, so a secret must not
            // survive there even though it was already redacted on disk (DeepSeek HIGH).
            return ToolResult(success: true, output: "remembered (preferences): \(SecretScanner.redactSecrets(in: text))", metadata: ["action": "remember"])
        case "project":
            let text = try requireString("text", from: arguments)
            let name = (arguments["project"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.projectName(from: context)
            do { try cortex.rememberProject(name, text) } catch { return .failure("cortex: could not write project memory: \(error)") }
            return ToolResult(success: true, output: "saved to project \(SecretScanner.redactSecrets(in: name)): \(SecretScanner.redactSecrets(in: text))",
                              metadata: ["action": "project", "project": SecretScanner.redactSecrets(in: name)])
        case "journal":
            let text = try requireString("text", from: arguments)
            do { try cortex.logWork(text, date: Self.today()) } catch { return .failure("cortex: could not write journal: \(error)") }
            return ToolResult(success: true, output: "journaled: \(SecretScanner.redactSecrets(in: text))", metadata: ["action": "journal"])
        default:
            return .failure("cortex: unknown action '\(action)'. Use remember | project | journal | recall.")
        }
    }

    static func projectName(from context: ToolContext) -> String {
        let leaf = (context.projectRoot as NSString).lastPathComponent
        return leaf.isEmpty ? "project" : leaf
    }

    /// Cached formatter (DeepSeek: don't rebuild per call). Local calendar date (yyyy-MM-dd).
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static func today() -> String { dateFormatter.string(from: Date()) }
}
