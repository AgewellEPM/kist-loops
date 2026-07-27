import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Turns text into vectors for semantic search. Provider-neutral so the vector store / memory service
/// never depend on a specific vendor.
public protocol EmbeddingProviding: Sendable {
    /// One vector per input text, order-preserving.
    func embeddings(for texts: [String]) async throws -> [[Float]]
}

public extension EmbeddingProviding {
    func embedding(for text: String) async throws -> [Float] {
        try await embeddings(for: [text]).first ?? []
    }
}

/// Gemini embeddings via `:batchEmbedContents` (model `gemini-embedding-001`). Network injectable so
/// tests never spend.
public struct GeminiEmbeddingClient: EmbeddingProviding {
    private let apiKey: String
    private let transport: HTTPTransport
    private let baseURL: String
    private let model: String

    public static let defaultModel = "gemini-embedding-001"

    public init(apiKey: String, model: String = defaultModel,
                transport: HTTPTransport = URLSessionTransport(),
                baseURL: String = "https://generativelanguage.googleapis.com/v1beta/models") {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.baseURL = baseURL
    }

    public enum EmbeddingError: Error, Equatable {
        case badURL
        case http(Int, String)
        case badResponse(String)
    }

    public func embeddings(for texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let url = URL(string: "\(baseURL)/\(model):batchEmbedContents?key=\(apiKey)") else { throw EmbeddingError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requests: [[String: Any]] = texts.map {
            ["model": "models/\(model)", "content": ["parts": [["text": $0]]]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["requests": requests])
        let (body, response) = try await transport.send(req)
        guard (200..<300).contains(response.statusCode) else {
            let t = String(data: body, encoding: .utf8) ?? ""
            throw EmbeddingError.http(response.statusCode, String(t.prefix(800)))
        }
        return try Self.parse(body, expected: texts.count)
    }

    static func parse(_ body: Data, expected: Int) throws -> [[Float]] {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let embeddings = root["embeddings"] as? [[String: Any]] else {
            throw EmbeddingError.badResponse("missing embeddings[]")
        }
        let vectors: [[Float]] = embeddings.map { e in
            (e["values"] as? [Double])?.map { Float($0) }
                ?? (e["values"] as? [NSNumber])?.map { $0.floatValue }
                ?? []
        }
        guard vectors.count == expected, vectors.allSatisfy({ !$0.isEmpty }) else {
            throw EmbeddingError.badResponse("expected \(expected) non-empty vectors, got \(vectors.count)")
        }
        return vectors
    }
}
