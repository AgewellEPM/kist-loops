import Foundation

/// Tool to write/create files - SECURITY HARDENED
final class WriteFileTool: AgentTool {
    let name = "write_file"
    let description = "Write content to a file. Creates the file if it doesn't exist. Set overwrite=true to replace existing files."
    let parameters = [
        ToolParameter(name: "path", type: "string", description: "File path relative to project root", required: true),
        ToolParameter(name: "content", type: "string", description: "Content to write to the file", required: true),
        ToolParameter(name: "overwrite", type: "boolean", description: "Allow overwriting existing files (default: false)", required: false)
    ]

    // SECURITY: Directories that should never be written to
    private let blockedPaths = [
        "/etc", "/System", "/Library/Preferences", "/usr", "/bin", "/sbin",
        "/var", "/tmp", "/private", "/.ssh", "/.gnupg"
    ]

    // SECURITY: File extensions that are potentially dangerous
    private let blockedExtensions = [
        "sh", "bash", "zsh", "command",  // Scripts
        "plist", "scpt", "scptd",         // macOS system files
        "app", "pkg", "dmg",              // Executables
        "kext", "bundle"                  // Kernel extensions
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: path")
        }

        guard let content = arguments["content"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: content")
        }

        let overwrite = arguments["overwrite"] as? Bool ?? false

        // SECURITY: Construct and resolve the full path
        let fullPath: String
        if path.hasPrefix("/") {
            fullPath = path
        } else {
            fullPath = (projectPath as NSString).appendingPathComponent(path)
        }

        // SECURITY: Resolve symlinks and normalize the path
        let resolvedPath = (fullPath as NSString).standardizingPath
        let resolvedProjectPath = (projectPath as NSString).standardizingPath

        // SECURITY: Ensure the resolved path is within the project directory
        guard resolvedPath.hasPrefix(resolvedProjectPath + "/") || resolvedPath == resolvedProjectPath else {
            return ToolResult(
                success: false,
                output: "",
                error: "Security: Cannot write outside project directory. Path '\(path)' resolves to '\(resolvedPath)' which is outside '\(resolvedProjectPath)'"
            )
        }

        // SECURITY: Check for blocked system paths
        for blocked in blockedPaths {
            if resolvedPath.contains(blocked) {
                return ToolResult(
                    success: false,
                    output: "",
                    error: "Security: Cannot write to system directory containing '\(blocked)'"
                )
            }
        }

        // SECURITY: Check file extension
        let fileExtension = (path as NSString).pathExtension.lowercased()
        if blockedExtensions.contains(fileExtension) {
            return ToolResult(
                success: false,
                output: "",
                error: "Security: Cannot create files with extension '.\(fileExtension)' - potentially dangerous file type"
            )
        }

        // SECURITY: Check if file exists and require explicit overwrite
        let fileExists = FileManager.default.fileExists(atPath: resolvedPath)
        if fileExists && !overwrite {
            return ToolResult(
                success: false,
                output: "",
                error: "File already exists at '\(path)'. Set overwrite=true to replace it."
            )
        }

        // Create directory if needed
        let directory = (resolvedPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            return ToolResult(success: false, output: "", error: "Failed to create directory: \(error.localizedDescription)")
        }

        // SECURITY: Check content size to prevent disk filling attacks
        let maxSize = 10 * 1024 * 1024  // 10 MB max
        if content.utf8.count > maxSize {
            return ToolResult(
                success: false,
                output: "",
                error: "Security: Content too large (\(content.utf8.count) bytes). Maximum allowed is \(maxSize) bytes."
            )
        }

        do {
            try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

            let lineCount = content.components(separatedBy: .newlines).count

            // Log change for synopsis
            await MainActor.run {
                ChangeLogStore.shared.logWrite(path: path, resolved: resolvedPath, action: fileExists ? "updated" : "created", lines: lineCount, bytes: content.utf8.count)
            }

            return ToolResult(
                success: true,
                output: fileExists ? "Updated file: \(path)" : "Created new file: \(path)",
                metadata: [
                    "path": path,
                    "resolved_path": resolvedPath,
                    "action": fileExists ? "updated" : "created",
                    "lines": String(lineCount),
                    "bytes": String(content.utf8.count)
                ]
            )
        } catch {
            return ToolResult(success: false, output: "", error: "Failed to write file: \(error.localizedDescription)")
        }
    }
}
