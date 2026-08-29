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

    /// Resolve the mutable Ollama tag to the immutable manifest digest every time the semantic
    /// service crosses an embedding boundary. The service checks this both before and after vector
    /// generation, so a tag/server change cannot silently enter an existing vector space.
    public func embeddingSpaceID() async throws -> String {
        let endpoint = try canonicalBaseURL()
        guard let url = URL(string: "\(endpoint)/api/tags") else {
            throw EmbeddingError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (body, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let text = String(data: body, encoding: .utf8) ?? ""
            throw EmbeddingError.http(response.statusCode, String(text.prefix(800)))
        }
        let digest = try Self.parseModelDigest(body, requestedModel: model)
        return "ollama:\(endpoint):\(model):sha256:\(digest)"
    }

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

    private func canonicalBaseURL() throws -> String {
        guard let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw EmbeddingError.badURL
        }
        var endpoint = "\(scheme)://\(host)"
        if let port = components.port { endpoint += ":\(port)" }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty { endpoint += "/\(path)" }
        return endpoint
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

    static func parseModelDigest(_ body: Data, requestedModel: String) throws -> String {
        guard !requestedModel.isEmpty, requestedModel.utf8.count <= 256,
              !requestedModel.contains("\0"), !requestedModel.contains("\n"),
              let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw EmbeddingError.badResponse("missing model manifest list")
        }
        let aliases: Set<String> = requestedModel.contains(":")
            ? [requestedModel]
            : [requestedModel, "\(requestedModel):latest"]
        var digests = Set<String>()
        for entry in models {
            let names = [entry["name"] as? String, entry["model"] as? String].compactMap { $0 }
            guard names.contains(where: aliases.contains),
                  var digest = entry["digest"] as? String else { continue }
            digest = digest.lowercased()
            if digest.hasPrefix("sha256:") { digest.removeFirst("sha256:".count) }
            guard digest.count == 64,
                  digest.unicodeScalars.allSatisfy({
                      (48...57).contains($0.value) || (97...102).contains($0.value)
                  }) else {
                throw EmbeddingError.badResponse("invalid model manifest digest")
            }
            digests.insert(digest)
        }
        guard digests.count == 1, let digest = digests.first else {
            throw EmbeddingError.badResponse("missing or ambiguous model manifest digest")
        }
        return digest
    }
}
