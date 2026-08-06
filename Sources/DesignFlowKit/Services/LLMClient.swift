import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The narrow contract agents depend on. Kept text-only and provider-agnostic so
/// the runtime can be driven by a real model or a deterministic stub in tests.
public protocol LLMClient: Sendable {
    func complete(system: String, user: String) async throws -> String
}

public enum LLMError: Error, CustomStringConvertible {
    case badResponse(status: Int, body: String)
    case emptyCompletion
    case transport(String)
    case budgetExceeded(limit: Int)

    public var description: String {
        switch self {
        case let .badResponse(status, body): return "LLM HTTP \(status): \(body.prefix(300))"
        case .emptyCompletion: return "LLM returned an empty completion"
        case let .transport(m): return "LLM transport error: \(m)"
        case let .budgetExceeded(limit): return "LLM call budget exhausted (limit \(limit)) — refusing further calls"
        }
    }
}

/// Real OpenAI Chat Completions client. Fails fast and loud — no silent fallbacks,
/// no swallowed errors. An empty completion is an error, not a valid result.
public struct OpenAIClient: LLMClient {
    private let apiKey: String
    private let model: String
    /// Chat Completions endpoint — override the host with `OPENAI_BASE_URL` (Azure/proxy/compatible servers).
    private let endpoint: URL

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        let base = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"] ?? "https://api.openai.com"
        guard let url = URL(string: base.hasSuffix("/")
                ? base + "v1/chat/completions"
                : base + "/v1/chat/completions") else {
            fatalError("OPENAI_BASE_URL is not a valid URL: \(base)")
        }
        self.endpoint = url
    }

    public func complete(system: String, user: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ],
            temperature: 0.4
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.badResponse(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw LLMError.emptyCompletion }
        return text
    }

    // MARK: Wire types
    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let temperature: Double
    }
    private struct ChatResponse: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg }
        let choices: [Choice]
    }
}

/// Deterministic stub for dry-run and tests. Produces clearly-labelled placeholder
/// text so the loop's mechanics can be exercised offline. It NEVER pretends to be
/// real output — every completion is stamped as DRY-RUN.
public struct StubLLMClient: LLMClient {
    public init() {}
    public func complete(system: String, user: String) async throws -> String {
        // Emit VALID Swift (comment lines + one decl) so a dry run's generated code
        // honestly passes `swiftc -parse` — the build gate is real, not bypassed. For
        // non-code stages (design/spec) this is harmless dry-run marker text.
        let seed = user.prefix(100).replacingOccurrences(of: "\n", with: " ")
        return """
        // [DRY-RUN PLACEHOLDER] — deterministic stub, no model was called.
        // system: \(system.prefix(60).replacingOccurrences(of: "\n", with: " "))
        // context: \(seed)
        let dryRunPlaceholder = true
        """
    }
}
