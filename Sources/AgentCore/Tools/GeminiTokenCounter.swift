import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Gemini `:countTokens` — a pre-flight token count for a piece of text (for cost/size estimates).
/// Network injectable so tests never spend.
public struct GeminiTokenCounter: Sendable {
    private let apiKey: String
    private let model: String
    private let transport: HTTPTransport
    private let baseURL: String

    public init(apiKey: String, model: String = "gemini-2.5-flash",
                transport: HTTPTransport = URLSessionTransport(),
                baseURL: String = "https://generativelanguage.googleapis.com/v1beta/models") {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.baseURL = baseURL
    }

    public enum CountError: Error, Equatable { case badURL, http(Int, String), badResponse(String) }

    public func count(text: String) async throws -> Int {
        guard let url = URL(string: "\(baseURL)/\(model):countTokens?key=\(apiKey)") else { throw CountError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["contents": [["parts": [["text": text]]]]])
        let (body, response) = try await transport.send(req)
        guard (200..<300).contains(response.statusCode) else {
            throw CountError.http(response.statusCode, String((String(data: body, encoding: .utf8) ?? "").prefix(400)))
        }
        return try Self.parse(body)
    }

    static func parse(_ body: Data) throws -> Int {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let total = (root["totalTokens"] as? Int) ?? (root["totalTokens"] as? NSNumber)?.intValue else {
            throw CountError.badResponse("missing totalTokens")
        }
        return total
    }
}

/// Agent tool: count the Gemini tokens in some text (optionally read from a project file) — a
/// pre-flight size/cost estimate before a big call.
public struct CountTokensTool: AgentTool {
    public let name = "count_tokens"
    public let description = """
    Count how many Gemini tokens a piece of text (or a project text file) uses — a pre-flight \
    size/cost estimate. Provide `text`, or a `path` to a text file in the project.
    """
    public let parameters = [
        ToolParameter(name: "text", type: "string", description: "Text to count (or use path).", required: false),
        ToolParameter(name: "path", type: "string", description: "Project-relative text file to count.", required: false),
    ]
    private let counter: @Sendable (_ text: String) async throws -> Int
    public init(geminiKey: String) {
        let c = GeminiTokenCounter(apiKey: geminiKey)
        self.counter = { try await c.count(text: $0) }
    }
    public init(counter: @escaping @Sendable (_ text: String) async throws -> Int) { self.counter = counter }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        var text = (arguments["text"] as? String) ?? ""
        if text.isEmpty, let path = arguments["path"] as? String {
            text = (try? context.confinedRoot().readString(path)) ?? ""   // confined, TOCTOU-safe
        }
        guard !text.isEmpty else { return .failure("provide text or a readable text file path") }
        let n = try await counter(text)
        return ToolResult(success: true, output: "\(n) tokens", metadata: ["tokens": String(n)])
    }
}
