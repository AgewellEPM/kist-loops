import Foundation
import Crypto

/// Ties an embedder to a durable vector store: remember text, recall the most similar past notes.
/// Embedding only happens on explicit remember/recall (via the tools) — no silent per-turn cost.
public final class SemanticMemoryService: @unchecked Sendable {
    private let embedder: EmbeddingProviding
    private let store: FileBackedVectorStore

    public init(embedder: EmbeddingProviding, store: FileBackedVectorStore) {
        self.embedder = embedder
        self.store = store
    }

    public var count: Int { store.count }

    /// Embed + upsert. Id is a content hash, so re-remembering the same text updates, never duplicates.
    public func remember(_ text: String, metadata: [String: String] = [:]) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let vector = try await embedder.embedding(for: trimmed)
        store.upsert(id: Self.id(for: trimmed), vector: vector, text: trimmed, metadata: metadata)
    }

    /// Embed the query, return the top-k most similar remembered notes.
    public func recall(_ query: String, topK: Int = 5) async throws -> [VectorHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let vector = try await embedder.embedding(for: trimmed)
        return store.query(vector, topK: topK)
    }

    static func id(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Agent tool: save a fact/preference/note to durable semantic memory.
public struct RememberTool: AgentTool {
    public let name = "remember"
    public let description = """
    Save a fact, preference, decision, or note to durable semantic memory so it can be recalled later \
    by meaning. Use when the user states a lasting preference or an important project fact.
    """
    public let parameters = [
        ToolParameter(name: "text", type: "string", description: "The fact/note to remember.", required: true),
        ToolParameter(name: "tag", type: "string", description: "Optional category tag.", required: false),
    ]
    private let service: SemanticMemoryService
    public init(service: SemanticMemoryService) { self.service = service }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let text = try requireString("text", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure("nothing to remember") }
        var meta: [String: String] = [:]
        if let tag = (arguments["tag"] as? String)?.trimmingCharacters(in: .whitespaces), !tag.isEmpty { meta["tag"] = tag }
        try await service.remember(text, metadata: meta)
        return ToolResult(success: true, output: "remembered (\(service.count) notes in memory)", metadata: meta)
    }
}

/// Agent tool: recall the most relevant remembered notes for a query (semantic search).
public struct RecallTool: AgentTool {
    public let name = "recall"
    public let description = """
    Search durable semantic memory for notes most relevant to a query (by meaning, not keywords). Use \
    to retrieve past facts, preferences, or decisions before answering.
    """
    public let parameters = [
        ToolParameter(name: "query", type: "string", description: "What to recall.", required: true),
        ToolParameter(name: "top_k", type: "integer", description: "How many notes to return (default 5).", required: false),
    ]
    private let service: SemanticMemoryService
    public init(service: SemanticMemoryService) { self.service = service }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let query = try requireString("query", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .failure("empty query") }
        let topK = (arguments["top_k"] as? Int) ?? 5
        let hits = try await service.recall(query, topK: max(1, topK))
        guard !hits.isEmpty else { return ToolResult(success: true, output: "no relevant memories found") }
        let body = hits.map { "• [\(String(format: "%.2f", $0.score))] \($0.text)" }.joined(separator: "\n")
        return ToolResult(success: true, output: "Recalled \(hits.count):\n\(body)")
    }
}
