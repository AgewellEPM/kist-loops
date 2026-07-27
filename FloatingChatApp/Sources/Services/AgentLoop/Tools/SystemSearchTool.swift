import Foundation

/// Tool to search the entire system for files, content, and applications
/// Uses mdfind (Spotlight) for fast system-wide search
final class SystemSearchTool: AgentTool {
    let name = "system_search"
    let description = "Search the entire computer for files, folders, or content. Uses Spotlight indexing for fast results. Can search by filename, content, file type, or application."
    let parameters = [
        ToolParameter(name: "query", type: "string", description: "Search query - can be filename, content text, or file type", required: true),
        ToolParameter(name: "type", type: "string", description: "Type of search: 'name' (filename), 'content' (file contents), 'kind' (file type like 'image', 'document', 'code'), 'app' (applications). Defaults to general search.", required: false),
        ToolParameter(name: "path", type: "string", description: "Limit search to a specific directory path. Defaults to entire system.", required: false),
        ToolParameter(name: "limit", type: "integer", description: "Maximum number of results (default: 50)", required: false)
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: query")
        }

        let searchType = arguments["type"] as? String ?? "general"
        let searchPath = arguments["path"] as? String
        let limit = arguments["limit"] as? Int ?? 50

        // Build mdfind query based on type
        var mdfindQuery: String

        switch searchType.lowercased() {
        case "name":
            // Search by filename
            mdfindQuery = "kMDItemFSName == '*\(query)*'cd"

        case "content":
            // Search file contents
            mdfindQuery = "kMDItemTextContent == '*\(query)*'cd"

        case "kind":
            // Search by file type
            let kindMapping: [String: String] = [
                "image": "kMDItemContentTypeTree == 'public.image'",
                "video": "kMDItemContentTypeTree == 'public.movie'",
                "audio": "kMDItemContentTypeTree == 'public.audio'",
                "document": "kMDItemContentTypeTree == 'public.document'",
                "pdf": "kMDItemContentType == 'com.adobe.pdf'",
                "code": "kMDItemContentTypeTree == 'public.source-code'",
                "swift": "kMDItemContentType == 'public.swift-source'",
                "text": "kMDItemContentTypeTree == 'public.text'",
                "folder": "kMDItemContentType == 'public.folder'",
                "app": "kMDItemContentType == 'com.apple.application-bundle'",
                "archive": "kMDItemContentTypeTree == 'public.archive'"
            ]

            if let kindQuery = kindMapping[query.lowercased()] {
                mdfindQuery = kindQuery
            } else {
                // Try as a raw kind query
                mdfindQuery = "kMDItemKind == '*\(query)*'cd"
            }

        case "app":
            // Search for applications
            mdfindQuery = "kMDItemContentType == 'com.apple.application-bundle' && kMDItemFSName == '*\(query)*'cd"

        default:
            // General search - combines name and content
            mdfindQuery = "(kMDItemFSName == '*\(query)*'cd || kMDItemTextContent == '*\(query)*'cd)"
        }

        // Build mdfind command
        var command = ["mdfind"]

        if let path = searchPath {
            command.append("-onlyin")
            command.append(path)
        }

        command.append(mdfindQuery)

        // Execute mdfind
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = Array(command.dropFirst()) // Remove "mdfind" from args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if process.terminationStatus != 0 {
                let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                return ToolResult(success: false, output: "", error: "Search failed: \(errorOutput)")
            }

            guard let output = String(data: outputData, encoding: .utf8) else {
                return ToolResult(success: false, output: "", error: "Could not decode search results")
            }

            // Parse results
            let allResults = output.components(separatedBy: "\n").filter { !$0.isEmpty }
            let limitedResults = Array(allResults.prefix(limit))

            if limitedResults.isEmpty {
                return ToolResult(
                    success: true,
                    output: "No files found matching: \(query)",
                    metadata: ["query": query, "type": searchType, "result_count": "0"]
                )
            }

            // Format results with file info
            var formattedResults: [String] = []

            for (index, path) in limitedResults.enumerated() {
                var info = "\(index + 1). \(path)"

                // Get file info
                let fileURL = URL(fileURLWithPath: path)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                    if let size = attrs[.size] as? Int64 {
                        info += " (\(formatFileSize(size)))"
                    }
                    if let modDate = attrs[.modificationDate] as? Date {
                        let formatter = DateFormatter()
                        formatter.dateStyle = .short
                        formatter.timeStyle = .short
                        info += " - Modified: \(formatter.string(from: modDate))"
                    }
                }

                // Add file type indicator
                let ext = fileURL.pathExtension.lowercased()
                let typeEmoji = getFileTypeEmoji(ext)
                info = typeEmoji + " " + info

                formattedResults.append(info)
            }

            let totalCount = allResults.count
            var resultText = formattedResults.joined(separator: "\n")

            if totalCount > limit {
                resultText += "\n\n... and \(totalCount - limit) more results (showing \(limit) of \(totalCount))"
            }

            return ToolResult(
                success: true,
                output: resultText,
                metadata: [
                    "query": query,
                    "type": searchType,
                    "result_count": String(limitedResults.count),
                    "total_count": String(totalCount)
                ]
            )

        } catch {
            return ToolResult(success: false, output: "", error: "Failed to execute search: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func getFileTypeEmoji(_ ext: String) -> String {
        switch ext {
        case "swift", "m", "h", "c", "cpp", "py", "js", "ts", "rb", "go", "rs":
            return "💻"
        case "md", "txt", "rtf":
            return "📝"
        case "pdf":
            return "📕"
        case "doc", "docx":
            return "📄"
        case "xls", "xlsx", "csv":
            return "📊"
        case "ppt", "pptx", "key":
            return "📽️"
        case "png", "jpg", "jpeg", "gif", "svg", "heic":
            return "🖼️"
        case "mp4", "mov", "avi", "mkv":
            return "🎬"
        case "mp3", "wav", "aac", "m4a":
            return "🎵"
        case "zip", "tar", "gz", "rar":
            return "📦"
        case "app":
            return "📱"
        case "xcodeproj", "xcworkspace":
            return "🔨"
        case "json", "yaml", "yml", "xml", "plist":
            return "⚙️"
        default:
            return "📁"
        }
    }
}
