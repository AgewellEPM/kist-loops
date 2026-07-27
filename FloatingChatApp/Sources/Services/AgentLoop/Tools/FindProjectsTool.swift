import Foundation

/// Find Xcode projects/workspaces and optionally set active project
final class FindProjectsTool: AgentTool {
    let name = "find_projects"
    let description = "Find Xcode projects or workspaces. Params: query (optional string to match path), limit (int), set (bool) to set the first result as active."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "query", type: "string", description: "Substring to match in path (optional)", required: false),
        ToolParameter(name: "limit", type: "integer", description: "Max results (default 20)", required: false),
        ToolParameter(name: "set", type: "boolean", description: "Set the first result as the active project path", required: false)
    ]

    func execute(arguments: [String : Any], projectPath: String) async throws -> ToolResult {
        let query = (arguments["query"] as? String)?.lowercased() ?? ""
        let limit = (arguments["limit"] as? Int) ?? 20
        let shouldSet = (arguments["set"] as? Bool) ?? false

        // Use mdfind for speed; fallback to manual enumeration
        let paths = mdfind(for: query, limit: limit)
        var output = ""
        for (i, p) in paths.enumerated() { output += "\(i+1). \(p)\n" }

        if shouldSet, let first = paths.first {
            let dir = ((first as NSString).deletingLastPathComponent as NSString).standardizingPath
            await MainActor.run {
                AgentSettingsManager.shared.settings.projectPath = dir
            }
            output += "\nActive project set to: \(dir)\n"
        }

        return ToolResult(success: !paths.isEmpty, output: output.isEmpty ? "No projects found" : output, metadata: [
            "results": paths.joined(separator: "\n")
        ])
    }

    private func mdfind(for query: String, limit: Int) -> [String] {
        let cmd = "/usr/bin/mdfind"
        guard FileManager.default.isExecutableFile(atPath: cmd) else { return [] }
        var args = ["(kMDItemFSName == '*.xcodeproj'cd || kMDItemFSName == '*.xcworkspace'cd)"]
        if !query.isEmpty { args.append("&& kMDItemPath == '*\\(query)*'cd") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = [args.joined(separator: " ")]
        let out = Pipe()
        process.standardOutput = out
        do {
            try process.run(); process.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n").map(String.init)
            return Array(lines.prefix(limit))
        } catch { return [] }
    }
}

