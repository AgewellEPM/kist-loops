import Foundation

/// Set the active project path used by tools and builds
final class SetProjectPathTool: AgentTool {
    let name = "set_project_path"
    let description = "Set the working project path. Params: path (absolute or relative). Validates existence and stores in AgentSettings."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "path", type: "string", description: "Absolute path to the project folder (or relative to current project)", required: true)
    ]

    func execute(arguments: [String : Any], projectPath: String) async throws -> ToolResult {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            return ToolResult(success: false, output: "", error: "Missing path")
        }
        let resolved: String
        if path.hasPrefix("/") {
            resolved = (path as NSString).standardizingPath
        } else {
            resolved = ((projectPath as NSString).appendingPathComponent(path) as NSString).standardizingPath
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult(success: false, output: "", error: "Directory not found: \(resolved)")
        }
        await MainActor.run {
            AgentSettingsManager.shared.settings.projectPath = resolved
        }
        return ToolResult(success: true, output: "Set project path to \(resolved)", metadata: ["project_path": resolved])
    }
}

