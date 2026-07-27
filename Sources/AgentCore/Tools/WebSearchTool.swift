import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WebSearchResult: Sendable, Equatable {
    public let title: String
    public let url: String
    public let snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public enum WebSearchBackend: String, Sendable, Equatable {
    case brave = "brave_search"
    case duckDuckGoHTML = "duckduckgo_html"
    case duckDuckGoLite = "duckduckgo_lite"
}

/// Search the public web for research/deep-dive tasks.
///
/// This complements `fetch_url`: search discovers candidate sources, fetch reads a chosen source.
/// It deliberately uses a fixed public search endpoint rather than arbitrary URLs, and returns a
/// compact source list for the agent to inspect further.
public struct WebSearchTool: AgentTool {
    public typealias Fetcher = @Sendable (_ url: URL) async throws -> String

    public let name = "web_search"
    public let description = "Search the public web and return candidate source URLs with titles/snippets. " +
        "Use for research, latest information, comparisons, and source discovery; use fetch_url to read a specific result."
    public let parameters = [
        ToolParameter(name: "query", type: "string", description: "The web search query.", required: true),
        ToolParameter(name: "limit", type: "integer", description: "Maximum results to return, 1...10. Default 5.", required: false),
        ToolParameter(name: "site", type: "string", description: "Optional domain constraint, e.g. docs.swift.org.", required: false),
    ]

    public static let maxBytes = 512_000
    private let fetcher: Fetcher
    private let backends: [WebSearchBackend]?

    public init(fetcher: Fetcher? = nil, backends: [WebSearchBackend]? = nil) {
        self.fetcher = fetcher ?? { url in try await Self.defaultFetcher(url: url) }
        self.backends = backends
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let rawQuery = try requireString("query", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuery.isEmpty else { return .failure("query is required") }
        let limit = Self.clampedLimit(arguments["limit"])
        let site = (arguments["site"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = (site?.isEmpty == false) ? "site:\(site!) \(rawQuery)" : rawQuery
        var diagnostics: [String] = []
        for backend in backends ?? Self.defaultBackends() {
            guard let url = Self.searchURL(query: query, backend: backend, limit: limit) else { continue }
            do {
                let body = try await fetcher(url)
                let results = Self.parse(body, backend: backend, limit: limit)
                guard !results.isEmpty else {
                    diagnostics.append("\(backend.rawValue): no results parsed")
                    continue
                }
                return Self.render(results, rawQuery: rawQuery, engine: backend.rawValue)
            } catch {
                diagnostics.append("\(backend.rawValue): \(error.localizedDescription)")
            }
        }

        return .failure("search failed: \(diagnostics.joined(separator: "; "))")
    }

    private static func render(_ results: [WebSearchResult], rawQuery: String, engine: String) -> ToolResult {
        let body = results.enumerated().map { index, result in
            var lines = [
                "\(index + 1). \(result.title)",
                "   URL: \(result.url)",
            ]
            if !result.snippet.isEmpty { lines.append("   Snippet: \(result.snippet)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        // Lead with the actual query (so the agent — and the terminal source trail — show what was searched).
        let output = "Searched: \(rawQuery) · via \(engine)\n\n" + body

        return ToolResult(success: true, output: output,
                          metadata: ["query": rawQuery, "count": String(results.count), "engine": engine])
    }

    static func defaultBackends() -> [WebSearchBackend] {
        var ordered: [WebSearchBackend] = []
        if braveAPIKey() != nil { ordered.append(.brave) }
        ordered.append(contentsOf: [.duckDuckGoHTML, .duckDuckGoLite])
        return ordered
    }

    static func searchURL(query: String, backend: WebSearchBackend = .duckDuckGoHTML, limit: Int = 5) -> URL? {
        let base: String
        switch backend {
        case .brave:
            base = "https://api.search.brave.com/res/v1/web/search"
        case .duckDuckGoHTML:
            base = "https://duckduckgo.com/html/"
        case .duckDuckGoLite:
            base = "https://lite.duckduckgo.com/lite/"
        }
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        if backend == .brave {
            components?.queryItems?.append(URLQueryItem(name: "count", value: String(limit)))
        }
        return components?.url
    }

    static func clampedLimit(_ raw: Any?) -> Int {
        let value: Int
        switch raw {
        case let n as Int: value = n
        case let n as Double: value = Int(n)
        case let s as String: value = Int(s) ?? 5
        default: value = 5
        }
        return min(10, max(1, value))
    }

    static func parse(_ body: String, backend: WebSearchBackend, limit: Int) -> [WebSearchResult] {
        switch backend {
        case .brave: return parseBraveJSON(body, limit: limit)
        case .duckDuckGoHTML: return parseDuckDuckGoHTML(body, limit: limit)
        case .duckDuckGoLite: return parseDuckDuckGoLiteHTML(body, limit: limit)
        }
    }

    static func parseBraveJSON(_ json: String, limit: Int) -> [WebSearchResult] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let web = root["web"] as? [String: Any],
              let rawResults = web["results"] as? [[String: Any]] else { return [] }
        var seen: Set<String> = []
        var results: [WebSearchResult] = []
        for item in rawResults {
            guard let rawURL = item["url"] as? String,
                  let url = normalizeResultURL(rawURL),
                  !seen.contains(url) else { continue }
            seen.insert(url)
            let title = WebFetchTool.htmlToText(item["title"] as? String ?? "")
            guard !title.isEmpty else { continue }
            let snippet = WebFetchTool.htmlToText(item["description"] as? String ?? "")
            results.append(WebSearchResult(title: title, url: url, snippet: snippet))
            if results.count >= max(1, limit) { break }
        }
        return results
    }

    static func parseDuckDuckGoHTML(_ html: String, limit: Int) -> [WebSearchResult] {
        let titlePattern = #"(?is)<a[^>]+class=["'][^"']*result__a[^"']*["'][^>]+href=["']([^"']+)["'][^>]*>(.*?)</a>"#
        let snippetPattern = #"(?is)<(?:a|div)[^>]+class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)</(?:a|div)>"#
        let titleMatches = captures(pattern: titlePattern, in: html, groups: 2)
        let snippets = captures(pattern: snippetPattern, in: html, groups: 1).map { match in
            WebFetchTool.htmlToText(match[0])
        }

        var seen: Set<String> = []
        var results: [WebSearchResult] = []
        for (index, match) in titleMatches.enumerated() {
            guard match.count == 2,
                  let url = normalizeResultURL(match[0]),
                  !seen.contains(url) else { continue }
            seen.insert(url)
            let title = WebFetchTool.htmlToText(match[1])
            guard !title.isEmpty else { continue }
            let snippet = index < snippets.count ? snippets[index] : ""
            results.append(WebSearchResult(title: title, url: url, snippet: snippet))
            if results.count >= max(1, limit) { break }
        }
        return results
    }

    static func parseDuckDuckGoLiteHTML(_ html: String, limit: Int) -> [WebSearchResult] {
        let linkPattern = #"(?is)<a[^>]+href=["']([^"']+)["'][^>]*>(.*?)</a>"#
        let snippetPattern = #"(?is)<[^>]+class=["'][^"']*result-snippet[^"']*["'][^>]*>(.*?)</[^>]+>"#
        let links = captures(pattern: linkPattern, in: html, groups: 2)
        let snippets = captures(pattern: snippetPattern, in: html, groups: 1).map { WebFetchTool.htmlToText($0[0]) }
        var seen: Set<String> = []
        var results: [WebSearchResult] = []

        for (index, match) in links.enumerated() {
            guard match.count == 2,
                  let url = normalizeResultURL(match[0]),
                  !url.contains("duckduckgo.com"),
                  !seen.contains(url) else { continue }
            seen.insert(url)
            let title = WebFetchTool.htmlToText(match[1])
            guard !title.isEmpty else { continue }
            let snippet = index < snippets.count ? snippets[index] : ""
            results.append(WebSearchResult(title: title, url: url, snippet: snippet))
            if results.count >= max(1, limit) { break }
        }
        return results
    }

    static func normalizeResultURL(_ raw: String) -> String? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("//") { candidate = "https:" + candidate }
        if candidate.hasPrefix("/") { candidate = "https://duckduckgo.com" + candidate }

        if let components = URLComponents(string: candidate),
           components.host?.lowercased().contains("duckduckgo.com") == true,
           let extracted = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            candidate = extracted
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url.absoluteString
    }

    private static func captures(pattern: String, in text: String, groups: Int) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { match in
            (1...groups).compactMap { group in
                guard let r = Range(match.range(at: group), in: text) else { return nil }
                return String(text[r])
            }
        }
    }

    private static func defaultFetcher(url: URL) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 MythosKist/1.0", forHTTPHeaderField: "User-Agent")
        if url.host?.lowercased() == "api.search.brave.com", let key = braveAPIKey() {
            request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AIProviderError.http(status: http.statusCode, body: "web search failed")
        }
        return String(decoding: data.prefix(Self.maxBytes), as: UTF8.self)
    }

    private static func braveAPIKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        return ["BRAVE_SEARCH_API_KEY", "BRAVE_API_KEY"]
            .compactMap { env[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
