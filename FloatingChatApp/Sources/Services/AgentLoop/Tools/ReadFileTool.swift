import Foundation

/// Tool to read file contents
final class ReadFileTool: AgentTool {
    let name = "read_file"
    let description = "Read the contents of a file. Returns the file content as text."
    let parameters = [
        ToolParameter(name: "path", type: "string", description: "File path relative to project root", required: true),
        ToolParameter(name: "start_line", type: "integer", description: "Starting line number (1-indexed)", required: false),
        ToolParameter(name: "end_line", type: "integer", description: "Ending line number (inclusive)", required: false)
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: path")
        }

        let fullPath: String
        if path.hasPrefix("/") {
            fullPath = path
        } else {
            fullPath = projectPath + "/" + path
        }

        guard FileManager.default.fileExists(atPath: fullPath) else {
            return ToolResult(success: false, output: "", error: "File not found: \(path)")
        }

        do {
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            // Handle line range if specified
            let startLine = (arguments["start_line"] as? Int ?? 1) - 1
            let endLine = arguments["end_line"] as? Int ?? lines.count

            let clampedStart = max(0, startLine)
            let clampedEnd = min(lines.count, endLine)

            if clampedStart >= clampedEnd {
                return ToolResult(success: false, output: "", error: "Invalid line range")
            }

            let selectedLines = Array(lines[clampedStart..<clampedEnd])
            let numberedLines = selectedLines.enumerated().map { index, line in
                String(format: "%4d│ %@", clampedStart + index + 1, line)
            }

            let output = numberedLines.joined(separator: "\n")

            return ToolResult(
                success: true,
                output: output,
                metadata: [
                    "path": path,
                    "total_lines": String(lines.count),
                    "shown_lines": "\(clampedStart + 1)-\(clampedEnd)"
                ]
            )
        } catch {
            return ToolResult(success: false, output: "", error: "Failed to read file: \(error.localizedDescription)")
        }
    }
}
