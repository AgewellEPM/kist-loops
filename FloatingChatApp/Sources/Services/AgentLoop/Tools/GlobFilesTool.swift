import Foundation

/// Tool to find files matching a glob pattern
final class GlobFilesTool: AgentTool {
    let name = "glob_files"
    let description = "Find files matching a glob pattern. Returns list of matching file paths."
    let parameters = [
        ToolParameter(name: "pattern", type: "string", description: "Glob pattern (e.g., '**/*.swift', 'Sources/**/*.swift', '*.{swift,m}')", required: true),
        ToolParameter(name: "max_results", type: "integer", description: "Maximum files to return (default: 100)", required: false),
        ToolParameter(name: "include_size", type: "boolean", description: "Include file sizes in output (default: false)", required: false)
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        guard let pattern = arguments["pattern"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: pattern")
        }

        let maxResults = arguments["max_results"] as? Int ?? 100
        let includeSize = arguments["include_size"] as? Bool ?? false

        var matchingFiles: [(path: String, size: Int64)] = []

        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: projectPath),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        // Pre-compile the regex for performance
        let regexPattern = globToRegex(pattern)
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: []) else {
            return ToolResult(success: false, output: "", error: "Invalid glob pattern: '\(pattern)'")
        }

        while let url = enumerator?.nextObject() as? URL {
            guard matchingFiles.count < maxResults else { break }

            // Skip common non-essential directories
            let pathComponents = url.pathComponents
            if pathComponents.contains("DerivedData") ||
               pathComponents.contains(".build") ||
               pathComponents.contains("Pods") ||
               pathComponents.contains("Carthage") ||
               pathComponents.contains("node_modules") ||
               pathComponents.contains(".git") {
                continue
            }

            // Only match regular files, not directories
            guard let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            let relativePath = url.path.replacingOccurrences(of: projectPath + "/", with: "")

            let range = NSRange(relativePath.startIndex..., in: relativePath)
            if regex.firstMatch(in: relativePath, options: [], range: range) != nil {
                var fileSize: Int64 = 0
                if includeSize {
                    if let sizeValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
                       let size = sizeValues.fileSize {
                        fileSize = Int64(size)
                    }
                }
                matchingFiles.append((path: relativePath, size: fileSize))
            }
        }

        if matchingFiles.isEmpty {
            return ToolResult(
                success: true,
                output: "No files found matching pattern: \(pattern)",
                metadata: ["matches": "0", "pattern": pattern]
            )
        }

        // Sort by path
        matchingFiles.sort { $0.path < $1.path }

        var output = "Found \(matchingFiles.count) file(s):\n\n"
        for file in matchingFiles {
            if includeSize {
                output += "  \(file.path) (\(formatSize(file.size)))\n"
            } else {
                output += "  \(file.path)\n"
            }
        }

        return ToolResult(
            success: true,
            output: output,
            metadata: [
                "pattern": pattern,
                "matches": String(matchingFiles.count)
            ]
        )
    }

    /// Convert a glob pattern to a proper regex pattern
    /// Supports: *, **, ?, {a,b,c}, [abc], [!abc]
    private func globToRegex(_ glob: String) -> String {
        var regex = "^"
        var i = glob.startIndex
        var inBraces = false

        while i < glob.endIndex {
            let char = glob[i]
            let nextIndex = glob.index(after: i)

            switch char {
            case "*":
                // Check for **
                if nextIndex < glob.endIndex && glob[nextIndex] == "*" {
                    let afterDouble = glob.index(after: nextIndex)
                    if afterDouble < glob.endIndex && glob[afterDouble] == "/" {
                        // **/ matches zero or more directory levels
                        regex += "(?:.*/)?"
                        i = afterDouble
                    } else if afterDouble >= glob.endIndex {
                        // ** at end matches everything
                        regex += ".*"
                        i = nextIndex
                    } else {
                        // ** in middle without / - treat as .*
                        regex += ".*"
                        i = nextIndex
                    }
                } else {
                    // Single * matches anything except /
                    regex += "[^/]*"
                }

            case "?":
                // ? matches any single character except /
                regex += "[^/]"

            case ".":
                regex += "\\."

            case "[":
                // Character class
                var classEnd = nextIndex
                // Check for negation
                if classEnd < glob.endIndex && glob[classEnd] == "!" {
                    regex += "[^"
                    classEnd = glob.index(after: classEnd)
                } else {
                    regex += "["
                }
                // Find the closing ]
                while classEnd < glob.endIndex && glob[classEnd] != "]" {
                    regex += String(glob[classEnd])
                    classEnd = glob.index(after: classEnd)
                }
                regex += "]"
                i = classEnd  // Will be incremented at end of loop

            case "{":
                // Brace expansion {a,b,c}
                regex += "(?:"
                inBraces = true

            case "}":
                regex += ")"
                inBraces = false

            case ",":
                if inBraces {
                    regex += "|"
                } else {
                    regex += ","
                }

            case "/":
                regex += "/"

            case "(", ")", "+", "^", "$", "|", "\\":
                // Escape regex special characters
                regex += "\\\(char)"

            default:
                regex += String(char)
            }

            if i < glob.endIndex {
                i = glob.index(after: i)
            }
        }

        regex += "$"
        return regex
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else {
            return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }
}
