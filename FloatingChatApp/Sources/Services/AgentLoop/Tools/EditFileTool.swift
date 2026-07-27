import Foundation

/// Tool to make targeted edits to files (like Claude Code's Edit)
final class EditFileTool: AgentTool {
    let name = "edit_file"
    let description = "Make a targeted edit to a file by replacing old text with new text. The old_text must match exactly."
    let parameters = [
        ToolParameter(name: "path", type: "string", description: "File path relative to project root", required: true),
        ToolParameter(name: "old_text", type: "string", description: "Exact text to find and replace", required: true),
        ToolParameter(name: "new_text", type: "string", description: "Text to replace with", required: true)
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: path")
        }

        guard let oldText = arguments["old_text"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: old_text")
        }

        guard let newText = arguments["new_text"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: new_text")
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
            var content = try String(contentsOfFile: fullPath, encoding: .utf8)

            // Check if old_text exists
            guard content.contains(oldText) else {
                // Try to find similar text for helpful error
                let suggestion = findSimilarText(in: content, to: oldText)
                var errorMsg = "old_text not found in file"
                if let suggestion = suggestion {
                    errorMsg += ". Did you mean:\n\(suggestion)"
                }
                return ToolResult(success: false, output: "", error: errorMsg)
            }

            // Count occurrences
            let occurrences = content.components(separatedBy: oldText).count - 1
            if occurrences > 1 {
                return ToolResult(
                    success: false,
                    output: "",
                    error: "old_text appears \(occurrences) times in file. Please provide more context to make it unique."
                )
            }

            // Make the replacement
            content = content.replacingOccurrences(of: oldText, with: newText)
            try content.write(toFile: fullPath, atomically: true, encoding: .utf8)

            // Calculate diff stats
            let oldLines = oldText.components(separatedBy: .newlines).count
            let newLines = newText.components(separatedBy: .newlines).count
            let lineDiff = newLines - oldLines

            var summary = "Edited \(path)"
            if lineDiff > 0 {
                summary += " (+\(lineDiff) lines)"
            } else if lineDiff < 0 {
                summary += " (\(lineDiff) lines)"
            }

            // Log change for synopsis
            await MainActor.run {
                ChangeLogStore.shared.logEdit(path: path, lineDiff: lineDiff)
            }

            return ToolResult(
                success: true,
                output: summary,
                metadata: [
                    "path": path,
                    "old_lines": String(oldLines),
                    "new_lines": String(newLines),
                    "line_diff": String(lineDiff)
                ]
            )
        } catch {
            return ToolResult(success: false, output: "", error: "Failed to edit file: \(error.localizedDescription)")
        }
    }

    /// Try to find similar text in the file for helpful error messages
    private func findSimilarText(in content: String, to target: String) -> String? {
        let targetLines = target.components(separatedBy: .newlines)
        guard let firstLine = targetLines.first?.trimmingCharacters(in: .whitespaces),
              !firstLine.isEmpty else {
            return nil
        }

        let contentLines = content.components(separatedBy: .newlines)

        // Find lines that start similarly
        for (index, line) in contentLines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(firstLine.prefix(20)) || firstLine.hasPrefix(trimmed.prefix(20)) {
                // Return surrounding context
                let start = max(0, index - 1)
                let end = min(contentLines.count, index + targetLines.count + 1)
                return contentLines[start..<end].joined(separator: "\n")
            }
        }

        return nil
    }
}
