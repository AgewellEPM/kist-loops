import Foundation

/// Tool to search code using grep-like functionality
/// Supports both substring and regex searching
final class SearchCodeTool: AgentTool {
    let name = "search_code"
    let description = "Search for text patterns in code files. Returns matching lines with file paths and line numbers."
    let parameters = [
        ToolParameter(name: "pattern", type: "string", description: "Text or regex pattern to search for", required: true),
        ToolParameter(name: "glob", type: "string", description: "File pattern to search in (e.g., '*.swift', '**/*.ts')", required: false),
        ToolParameter(name: "regex", type: "boolean", description: "Treat pattern as regex (default: false, uses substring match)", required: false),
        ToolParameter(name: "case_sensitive", type: "boolean", description: "Case sensitive search (default: false)", required: false),
        ToolParameter(name: "max_results", type: "integer", description: "Maximum results to return (default: 50)", required: false),
        ToolParameter(name: "context_lines", type: "integer", description: "Lines of context before/after match (default: 0)", required: false)
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        guard let pattern = arguments["pattern"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: pattern")
        }

        let glob = arguments["glob"] as? String ?? "*.swift"
        let useRegex = arguments["regex"] as? Bool ?? false
        let caseSensitive = arguments["case_sensitive"] as? Bool ?? false
        let maxResults = arguments["max_results"] as? Int ?? 50
        let contextLines = arguments["context_lines"] as? Int ?? 0

        // Prepare the matcher
        let matcher: LineMatcher
        if useRegex {
            var options: NSRegularExpression.Options = []
            if !caseSensitive {
                options.insert(.caseInsensitive)
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return ToolResult(success: false, output: "", error: "Invalid regex pattern: '\(pattern)'")
            }
            matcher = RegexMatcher(regex: regex)
        } else {
            matcher = SubstringMatcher(pattern: pattern, caseSensitive: caseSensitive)
        }

        var results: [SearchMatch] = []

        // Find all matching files
        let files = findFiles(matching: glob, in: projectPath)

        for file in files {
            guard results.count < maxResults else { break }

            let fullPath = projectPath + "/" + file
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }

            let lines = content.components(separatedBy: .newlines)

            for (index, line) in lines.enumerated() {
                guard results.count < maxResults else { break }

                if matcher.matches(line) {
                    // Gather context if requested
                    var contextBefore: [String] = []
                    var contextAfter: [String] = []

                    if contextLines > 0 {
                        let startContext = max(0, index - contextLines)
                        let endContext = min(lines.count - 1, index + contextLines)

                        for i in startContext..<index {
                            contextBefore.append(lines[i])
                        }
                        for i in (index + 1)...endContext {
                            contextAfter.append(lines[i])
                        }
                    }

                    results.append(SearchMatch(
                        file: file,
                        line: index + 1,
                        content: line.trimmingCharacters(in: .whitespaces),
                        contextBefore: contextBefore,
                        contextAfter: contextAfter
                    ))
                }
            }
        }

        if results.isEmpty {
            return ToolResult(
                success: true,
                output: "No matches found for '\(pattern)' in \(glob)",
                metadata: ["matches": "0"]
            )
        }

        var output = "Found \(results.count) match(es):\n\n"
        for result in results {
            // Show context before
            for (i, ctx) in result.contextBefore.enumerated() {
                let lineNum = result.line - result.contextBefore.count + i
                output += "  \(result.file):\(lineNum):   \(ctx)\n"
            }

            // Show the match
            output += "\(result.file):\(result.line): \(result.content)\n"

            // Show context after
            for (i, ctx) in result.contextAfter.enumerated() {
                output += "  \(result.file):\(result.line + 1 + i):   \(ctx)\n"
            }

            if contextLines > 0 {
                output += "\n"
            }
        }

        return ToolResult(
            success: true,
            output: output,
            metadata: [
                "pattern": pattern,
                "glob": glob,
                "regex": String(useRegex),
                "matches": String(results.count)
            ]
        )
    }

    // MARK: - Search Match

    private struct SearchMatch {
        let file: String
        let line: Int
        let content: String
        let contextBefore: [String]
        let contextAfter: [String]
    }

    // MARK: - Line Matchers

    private protocol LineMatcher {
        func matches(_ line: String) -> Bool
    }

    private struct SubstringMatcher: LineMatcher {
        let pattern: String
        let caseSensitive: Bool

        func matches(_ line: String) -> Bool {
            if caseSensitive {
                return line.contains(pattern)
            } else {
                return line.lowercased().contains(pattern.lowercased())
            }
        }
    }

    private struct RegexMatcher: LineMatcher {
        let regex: NSRegularExpression

        func matches(_ line: String) -> Bool {
            let range = NSRange(line.startIndex..., in: line)
            return regex.firstMatch(in: line, options: [], range: range) != nil
        }
    }

    // MARK: - File Finding

    private func findFiles(matching glob: String, in directory: String) -> [String] {
        var files: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let url = enumerator?.nextObject() as? URL {
            // Skip common non-essential directories
            let pathComponents = url.pathComponents
            if pathComponents.contains("DerivedData") ||
               pathComponents.contains(".build") ||
               pathComponents.contains("Pods") ||
               pathComponents.contains("node_modules") ||
               pathComponents.contains(".git") {
                continue
            }

            let relativePath = url.path.replacingOccurrences(of: directory + "/", with: "")

            if matchesGlob(relativePath, glob: glob) {
                files.append(relativePath)
            }
        }

        return files
    }

    private func matchesGlob(_ path: String, glob: String) -> Bool {
        let regexPattern = globToRegex(glob)
        let regex = try? NSRegularExpression(pattern: regexPattern, options: [])
        let range = NSRange(path.startIndex..., in: path)
        return regex?.firstMatch(in: path, options: [], range: range) != nil
    }

    /// Convert a glob pattern to a proper regex pattern
    private func globToRegex(_ glob: String) -> String {
        var regex = "^"
        var i = glob.startIndex

        while i < glob.endIndex {
            let char = glob[i]
            let nextIndex = glob.index(after: i)

            switch char {
            case "*":
                // Check for **
                if nextIndex < glob.endIndex && glob[nextIndex] == "*" {
                    // ** matches any path including /
                    let afterDouble = glob.index(after: nextIndex)
                    if afterDouble < glob.endIndex && glob[afterDouble] == "/" {
                        // **/ matches any directory depth
                        regex += "(?:.*/)?"
                        i = afterDouble
                    } else {
                        regex += ".*"
                        i = nextIndex
                    }
                } else {
                    // * matches anything except /
                    regex += "[^/]*"
                }
            case "?":
                regex += "[^/]"
            case ".":
                regex += "\\."
            case "[":
                regex += "["
            case "]":
                regex += "]"
            case "{":
                // Handle {a,b,c} patterns
                regex += "(?:"
            case "}":
                regex += ")"
            case ",":
                // Inside braces, comma becomes |
                regex += "|"
            case "(", ")", "+", "^", "$", "|", "\\":
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
}
