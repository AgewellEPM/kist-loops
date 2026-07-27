import Foundation

/// Tool to search the web or fetch URL content
/// Uses DuckDuckGo HTML API (no API key required)
final class WebSearchTool: AgentTool {
    let name = "web_search"
    let description = "Search the web for information or fetch content from a URL. Use type='search' for web searches, type='fetch' for retrieving URL content."
    let parameters = [
        ToolParameter(name: "query", type: "string", description: "Search query or URL to fetch", required: true),
        ToolParameter(name: "type", type: "string", description: "Type of operation: 'search' for web search, 'fetch' for URL content. Defaults to 'search', but auto-detects URLs.", required: false)
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        guard let query = arguments["query"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: query")
        }

        let type = arguments["type"] as? String ?? "search"

        // Auto-detect URLs
        if type == "fetch" || query.hasPrefix("http://") || query.hasPrefix("https://") {
            return await fetchURL(query)
        } else {
            return await searchWeb(query)
        }
    }

    // MARK: - URL Fetching

    private func fetchURL(_ urlString: String) async -> ToolResult {
        guard let url = URL(string: urlString) else {
            return ToolResult(success: false, output: "", error: "Invalid URL: \(urlString)")
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return ToolResult(success: false, output: "", error: "Invalid response type")
            }

            guard httpResponse.statusCode == 200 else {
                return ToolResult(success: false, output: "", error: "HTTP error: \(httpResponse.statusCode)")
            }

            guard let content = String(data: data, encoding: .utf8) else {
                return ToolResult(success: false, output: "", error: "Could not decode response as UTF-8")
            }

            // Strip HTML tags for readability
            let cleanContent = stripHTML(content)
            let truncatedContent = String(cleanContent.prefix(15000))

            return ToolResult(
                success: true,
                output: truncatedContent,
                metadata: [
                    "url": urlString,
                    "content_length": String(cleanContent.count),
                    "truncated": cleanContent.count > 15000 ? "true" : "false"
                ]
            )
        } catch {
            return ToolResult(success: false, output: "", error: "Failed to fetch URL: \(error.localizedDescription)")
        }
    }

    // MARK: - Web Search

    private func searchWeb(_ query: String) async -> ToolResult {
        // Use DuckDuckGo HTML API (no API key required)
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return ToolResult(success: false, output: "", error: "Failed to encode query")
        }

        let searchURL = "https://html.duckduckgo.com/html/?q=\(encodedQuery)"

        guard let url = URL(string: searchURL) else {
            return ToolResult(success: false, output: "", error: "Invalid search URL")
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30

            let (data, _) = try await URLSession.shared.data(for: request)

            guard let html = String(data: data, encoding: .utf8) else {
                return ToolResult(success: false, output: "", error: "Could not decode search response")
            }

            // Parse search results
            let results = parseSearchResults(html)

            if results.isEmpty {
                return ToolResult(
                    success: true,
                    output: "No results found for: \(query)",
                    metadata: ["query": query, "source": "duckduckgo", "result_count": "0"]
                )
            }

            return ToolResult(
                success: true,
                output: results,
                metadata: ["query": query, "source": "duckduckgo"]
            )
        } catch {
            return ToolResult(success: false, output: "", error: "Search failed: \(error.localizedDescription)")
        }
    }

    // MARK: - HTML Parsing

    private func parseSearchResults(_ html: String) -> String {
        var results: [String] = []

        // Extract result links and snippets from DuckDuckGo HTML
        // Pattern for result links
        let linkPattern = #"<a rel="nofollow" class="result__a" href="([^"]+)"[^>]*>([^<]+)</a>"#
        let snippetPattern = #"<a class="result__snippet"[^>]*>([^<]+)</a>"#

        // Find all result blocks
        let resultBlockPattern = #"<div class="result results_links results_links_deep web-result[^"]*">([\s\S]*?)</div>\s*</div>"#

        if let blockRegex = try? NSRegularExpression(pattern: resultBlockPattern, options: []) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = blockRegex.matches(in: html, options: [], range: range)

            for (index, match) in matches.prefix(8).enumerated() {
                if let blockRange = Range(match.range(at: 0), in: html) {
                    let block = String(html[blockRange])

                    var title = ""
                    var url = ""
                    var snippet = ""

                    // Extract link and title
                    if let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: []),
                       let linkMatch = linkRegex.firstMatch(in: block, options: [], range: NSRange(block.startIndex..., in: block)) {
                        if let urlRange = Range(linkMatch.range(at: 1), in: block) {
                            url = String(block[urlRange])
                        }
                        if let titleRange = Range(linkMatch.range(at: 2), in: block) {
                            title = String(block[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }

                    // Extract snippet
                    if let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: []),
                       let snippetMatch = snippetRegex.firstMatch(in: block, options: [], range: NSRange(block.startIndex..., in: block)) {
                        if let snippetRange = Range(snippetMatch.range(at: 1), in: block) {
                            snippet = String(block[snippetRange])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: "&amp;", with: "&")
                                .replacingOccurrences(of: "&lt;", with: "<")
                                .replacingOccurrences(of: "&gt;", with: ">")
                                .replacingOccurrences(of: "&quot;", with: "\"")
                                .replacingOccurrences(of: "&#39;", with: "'")
                        }
                    }

                    if !title.isEmpty {
                        var result = "\(index + 1). \(title)"
                        if !url.isEmpty {
                            result += "\n   URL: \(url)"
                        }
                        if !snippet.isEmpty {
                            result += "\n   \(snippet)"
                        }
                        results.append(result)
                    }
                }
            }
        }

        // Fallback: simpler pattern if the above doesn't work
        if results.isEmpty {
            let simplePattern = #"<a class="result__a"[^>]*href="([^"]+)"[^>]*>([^<]+)</a>"#
            if let regex = try? NSRegularExpression(pattern: simplePattern, options: []) {
                let range = NSRange(html.startIndex..., in: html)
                let matches = regex.matches(in: html, options: [], range: range)

                for (index, match) in matches.prefix(8).enumerated() {
                    if let urlRange = Range(match.range(at: 1), in: html),
                       let titleRange = Range(match.range(at: 2), in: html) {
                        let url = String(html[urlRange])
                        let title = String(html[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        results.append("\(index + 1). \(title)\n   URL: \(url)")
                    }
                }
            }
        }

        return results.isEmpty ? "No results could be parsed" : results.joined(separator: "\n\n")
    }

    private func stripHTML(_ html: String) -> String {
        // Remove script and style tags with their content
        var result = html
        let scriptPattern = #"<script[^>]*>[\s\S]*?</script>"#
        let stylePattern = #"<style[^>]*>[\s\S]*?</style>"#

        if let scriptRegex = try? NSRegularExpression(pattern: scriptPattern, options: .caseInsensitive) {
            result = scriptRegex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        if let styleRegex = try? NSRegularExpression(pattern: stylePattern, options: .caseInsensitive) {
            result = styleRegex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // Remove all other HTML tags
        let tagPattern = #"<[^>]+>"#
        if let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: []) {
            result = tagRegex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        }

        // Decode HTML entities
        result = result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")

        // Collapse multiple whitespace into single spaces
        let whitespacePattern = #"\s+"#
        if let whitespaceRegex = try? NSRegularExpression(pattern: whitespacePattern, options: []) {
            result = whitespaceRegex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
