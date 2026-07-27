import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// LOCAL embeddings via Ollama (`POST /api/embed`) — frees semantic memory / code index from
/// the Gemini API: offline, free, no key, no data leaving the machine. Same `EmbeddingProviding`
/// contract as the Gemini client, so the vector store / SemanticMemory swap in without changes.
/// Network injectable so tests never touch a real server. Default model `nomic-embed-text`
/// (fast, 768-dim); any Ollama embedding model works.
public struct OllamaEmbeddingClient: EmbeddingProviding {
    private let transport: HTTPTransport
    private let baseURL: String
    private let model: String

    public static let defaultModel = "nomic-embed-text"

    public init(model: String = defaultModel,
                transport: HTTPTransport = URLSessionTransport(),
                baseURL: String = OllamaEmbeddingClient.defaultBaseURL()) {
        self.model = model
        self.transport = transport
        self.baseURL = baseURL
    }

    /// Honor OLLAMA_HOST (the standard Ollama env) so a non-default host/port works.
    public static func defaultBaseURL() -> String {
        if let host = ProcessInfo.processInfo.environment["OLLAMA_HOST"], !host.isEmpty {
            return host.contains("://") ? host : "http://" + host
        }
        return "http://127.0.0.1:11434"
    }

    public enum EmbeddingError: Error, Equatable {
        case badURL
        case http(Int, String)
        case badResponse(String)
    }

    public func embeddings(for texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let url = URL(string: "\(baseURL)/api/embed") else { throw EmbeddingError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": texts])
        let (body, response) = try await transport.send(req)
        guard (200..<300).contains(response.statusCode) else {
            let t = String(data: body, encoding: .utf8) ?? ""
            throw EmbeddingError.http(response.statusCode, String(t.prefix(800)))
        }
        return try Self.parse(body, expected: texts.count)
    }

    /// Ollama `/api/embed` returns `{ "embeddings": [[...], ...] }` (batch, order-preserving).
    static func parse(_ body: Data, expected: Int) throws -> [[Float]] {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let embeddings = root["embeddings"] as? [[Any]] else {
            throw EmbeddingError.badResponse("missing embeddings[]")
        }
        let vectors: [[Float]] = embeddings.map { row in
            (row as? [Double])?.map { Float($0) }
                ?? (row as? [NSNumber])?.map { $0.floatValue }
                ?? []
        }
        guard vectors.count == expected, vectors.allSatisfy({ !$0.isEmpty }) else {
            throw EmbeddingError.badResponse("expected \(expected) non-empty vectors, got \(vectors.count)")
        }
        return vectors
    }
}
