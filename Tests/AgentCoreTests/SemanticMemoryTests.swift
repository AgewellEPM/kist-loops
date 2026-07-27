import XCTest
@testable import AgentCore

final class SemanticMemoryTests: XCTestCase {

    private func tempFile() -> String {
        NSTemporaryDirectory() + "vec_\(UUID().uuidString)/vectors.json"
    }

    // A deterministic embedder: maps known phrases to fixed vectors so cosine ranking is testable.
    private struct StubEmbedder: EmbeddingProviding {
        let table: [String: [Float]]
        func embeddings(for texts: [String]) async throws -> [[Float]] {
            texts.map { table[$0] ?? [0, 0, 0] }
        }
    }

    func testCosineAndTopKRanking() {
        let store = FileBackedVectorStore(path: tempFile())
        store.upsert(id: "a", vector: [1, 0, 0], text: "cats")
        store.upsert(id: "b", vector: [0, 1, 0], text: "finance")
        store.upsert(id: "c", vector: [0.9, 0.1, 0], text: "kittens")
        let hits = store.query([1, 0, 0], topK: 2)
        XCTAssertEqual(hits.map { $0.id }, ["a", "c"])           // closest two, in order
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
        XCTAssertEqual(FileBackedVectorStore.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(FileBackedVectorStore.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(FileBackedVectorStore.cosine([0, 0], [1, 0]), 0)   // zero-norm → 0, no NaN
    }

    func testPersistenceAcrossInstances() {
        let path = tempFile()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        do {
            let s = FileBackedVectorStore(path: path)
            s.upsert(id: "x", vector: [1, 2, 3], text: "remember me", metadata: ["tag": "fact"])
            XCTAssertEqual(s.count, 1)
        }
        // New instance loads from disk — not in-memory only.
        let reopened = FileBackedVectorStore(path: path)
        XCTAssertEqual(reopened.count, 1)
        let hit = reopened.query([1, 2, 3], topK: 1).first
        XCTAssertEqual(hit?.text, "remember me")
        XCTAssertEqual(hit?.metadata["tag"], "fact")
    }

    func testUpsertDedupesByContentHash() async throws {
        let path = tempFile()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let service = SemanticMemoryService(
            embedder: StubEmbedder(table: ["fact one": [1, 0], "fact two": [0, 1]]),
            store: FileBackedVectorStore(path: path))
        try await service.remember("fact one")
        try await service.remember("fact one")   // same text → same id → no duplicate
        try await service.remember("fact two")
        XCTAssertEqual(service.count, 2)
    }

    func testRememberAndRecallToolsRoundTrip() async throws {
        let path = tempFile()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let service = SemanticMemoryService(
            embedder: StubEmbedder(table: ["luke prefers dark mode": [1, 0, 0],
                                           "the api key rotates monthly": [0, 1, 0],
                                           "what ui theme": [0.95, 0.05, 0]]),
            store: FileBackedVectorStore(path: path))
        let ctx = ToolContext(projectRoot: NSTemporaryDirectory())

        _ = try await RememberTool(service: service).execute(arguments: ["text": "luke prefers dark mode", "tag": "pref"], context: ctx)
        _ = try await RememberTool(service: service).execute(arguments: ["text": "the api key rotates monthly"], context: ctx)

        let recall = try await RecallTool(service: service).execute(arguments: ["query": "what ui theme", "top_k": 1], context: ctx)
        XCTAssertTrue(recall.success)
        XCTAssertTrue(recall.output.contains("luke prefers dark mode"), recall.output)
        XCTAssertFalse(recall.output.contains("api key"), "unrelated note must not rank first")
    }

    func testEmbeddingResponseParsing() throws {
        let body = #"{"embeddings":[{"values":[0.1,0.2,0.3]},{"values":[1.0,2.0]}]}"#.data(using: .utf8)!
        let vecs = try GeminiEmbeddingClient.parse(body, expected: 2)
        XCTAssertEqual(vecs.count, 2)
        XCTAssertEqual(vecs[0], [0.1, 0.2, 0.3])
        // wrong count → error, never a silent short read
        XCTAssertThrowsError(try GeminiEmbeddingClient.parse(body, expected: 3))
    }
}
