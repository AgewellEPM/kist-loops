import Foundation

// Compatibility shell for the retired agent-writable Cortex surface. The Markdown archive lacks
// trustworthy per-entry event clocks, so direct use fails closed. Production tool assembly omits
// this tool and exposes temporal `remember` / `recall` separately when semantic V2 is available.
public struct CortexTool: AgentTool {
    public let name = "cortex"
    public let description = """
    Retired compatibility surface. Legacy Cortex Markdown is raw audit-only and cannot be written or \
    recalled by an agent. Use the temporal semantic-memory `remember` and `recall` tools instead.
    """
    public let parameters = [
        ToolParameter(name: "action", type: "string", description: "Retired compatibility action", required: true),
        ToolParameter(name: "text", type: "string", description: "Ignored; raw writes are refused", required: false),
        ToolParameter(name: "project", type: "string", description: "Ignored; raw writes are refused", required: false),
    ]
    public var supportedActions: [String] { ["remember", "project", "journal", "recall"] }
    public var usageExamples: [String] {
        ["Use temporal remember/recall; legacy cortex actions fail closed."]
    }
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let action = try requireString("action", from: arguments).lowercased()
        guard supportedActions.contains(action) else {
            return .failure("cortex: unknown action '\(action)'. Use remember | project | journal | recall.")
        }
        _ = context
        return .failure(
            "legacy cortex Markdown is raw audit-only; use temporal semantic-memory remember/recall")
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
