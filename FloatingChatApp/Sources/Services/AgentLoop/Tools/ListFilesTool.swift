import Foundation

/// Tool to list files in a directory
final class ListFilesTool: AgentTool {
    let name = "list_files"
    let description = "List files and directories in a given path. Returns a tree-like structure."
    let parameters = [
        ToolParameter(name: "path", type: "string", description: "Directory path relative to project root", required: true),
        ToolParameter(name: "max_depth", type: "integer", description: "Maximum depth to traverse (default: 3)", required: false),
        ToolParameter(name: "include_hidden", type: "boolean", description: "Include hidden files (default: false)", required: false)
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        let path = arguments["path"] as? String ?? "."
        let maxDepth = arguments["max_depth"] as? Int ?? 3
        let includeHidden = arguments["include_hidden"] as? Bool ?? false

        let fullPath: String
        if path.hasPrefix("/") {
            fullPath = path
        } else if path == "." {
            fullPath = projectPath
        } else {
            fullPath = projectPath + "/" + path
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return ToolResult(success: false, output: "", error: "Not a directory: \(path)")
        }

        var output = ""
        var fileCount = 0
        var dirCount = 0

        func listDirectory(at dirPath: String, prefix: String, depth: Int) {
            guard depth <= maxDepth else { return }

            let contents: [String]
            do {
                contents = try FileManager.default.contentsOfDirectory(atPath: dirPath).sorted()
            } catch {
                return
            }

            let filtered = contents.filter { item in
                if !includeHidden && item.hasPrefix(".") { return false }
                // Skip common non-essential directories
                if ["DerivedData", "build", ".build", "Pods", "Carthage", "xcuserdata", "node_modules"].contains(item) {
                    return false
                }
                return true
            }

            for (index, item) in filtered.enumerated() {
                let isLast = index == filtered.count - 1
                let connector = isLast ? "└── " : "├── "
                let childPrefix = isLast ? "    " : "│   "

                let itemPath = dirPath + "/" + item
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir)

                if isDir.boolValue {
                    output += "\(prefix)\(connector)📁 \(item)/\n"
                    dirCount += 1
                    listDirectory(at: itemPath, prefix: prefix + childPrefix, depth: depth + 1)
                } else {
                    let icon = fileIcon(for: item)
                    output += "\(prefix)\(connector)\(icon) \(item)\n"
                    fileCount += 1
                }
            }
        }

        let dirName = (fullPath as NSString).lastPathComponent
        output = "📁 \(dirName)/\n"
        listDirectory(at: fullPath, prefix: "", depth: 1)

        return ToolResult(
            success: true,
            output: output,
            metadata: [
                "path": path,
                "files": String(fileCount),
                "directories": String(dirCount)
            ]
        )
    }

    private func fileIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "🔶"
        case "m", "mm", "h": return "📘"
        case "json": return "📋"
        case "md", "markdown": return "📝"
        case "yml", "yaml": return "⚙️"
        case "png", "jpg", "jpeg", "gif", "svg": return "🖼️"
        case "xcodeproj", "xcworkspace": return "🔧"
        case "plist": return "📄"
        case "storyboard", "xib": return "🎨"
        default: return "📄"
        }
    }
}
