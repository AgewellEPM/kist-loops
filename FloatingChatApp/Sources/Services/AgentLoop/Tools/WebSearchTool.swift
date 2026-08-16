import Foundation

/// Disabled legacy adapter. The FloatingChat target has no checked-in AgentCore linkage;
/// public-web access must be provided by AgentCore rather than duplicated here.
final class WebSearchTool: AgentTool {
    let name = "web_search"
    let description = "Unavailable in this legacy target; use the AgentCore public-web tools."
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        ToolResult(success: false, output: "",
                   error: "web_search is disabled: this target is not linked to AgentCore")
    }
}
