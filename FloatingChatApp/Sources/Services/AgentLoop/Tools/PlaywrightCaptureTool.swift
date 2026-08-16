import Foundation

/// Disabled legacy adapter. Browser networking must use AgentCore BrowserTool and its
/// credentialed pinned SOCKS boundary; this target cannot safely reproduce that policy.
final class PlaywrightCaptureTool: AgentTool {
    let name = "web_capture"
    let description = "Unavailable in this legacy target; use AgentCore BrowserTool."
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        ToolResult(success: false, output: "",
                   error: "web_capture is disabled: this target is not linked to AgentCore")
    }
}
