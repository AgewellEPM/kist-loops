import Foundation

public struct VectorHit: Sendable, Equatable {
    public var id: String
    public var text: String
    public var score: Float
    public var metadata: [String: String]
}

/// A durable, file-backed vector store: upsert text+vector, query by cosine similarity (top-k),
/// persisted as JSON. NOT in-memory-only — survives across sessions (the council's explicit
/// requirement). Records are kept in memory for fast query and flushed to disk on each upsert.
public final class FileBackedVectorStore: @unchecked Sendable {
    public struct Record: Codable, Equatable {
        public var id: String
        public var vector: [Float]
        public var text: String
        public var metadata: [String: String]
    }

    private let path: String
    private let lock = NSLock()
    private var records: [String: Record]   // id → record

    public init(path: String) {
        self.path = path
        self.records = Self.load(path)
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }

    public func upsert(id: String, vector: [Float], text: String, metadata: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        records[id] = Record(id: id, vector: vector, text: text, metadata: metadata)
        persist()
    }

    /// Top-k by cosine similarity (descending). Zero-norm vectors score 0. Empty store → [].
    public func query(_ vector: [Float], topK: Int = 5) -> [VectorHit] {
        lock.lock(); let snapshot = records; lock.unlock()
        guard !snapshot.isEmpty, topK > 0, !vector.isEmpty else { return [] }
        let qn = Self.norm(vector)
        guard qn > 0 else { return [] }
        let scored = snapshot.values.map { r -> VectorHit in
            let score = Self.cosine(vector, r.vector, normA: qn)
            return VectorHit(id: r.id, text: r.text, score: score, metadata: r.metadata)
        }
        return scored.sorted { $0.score > $1.score }.prefix(topK).map { $0 }
    }

    // MARK: cosine

    static func norm(_ v: [Float]) -> Float { (v.reduce(0) { $0 + $1 * $1 }).squareRoot() }

    static func cosine(_ a: [Float], _ b: [Float], normA: Float? = nil) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        let na = normA ?? norm(a)
        let nb = norm(b)
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na * nb)
    }

    // MARK: persistence

    private func persist() {
        let all = Array(records.values).sorted { $0.id < $1.id }   // stable on disk
        guard let data = try? JSONEncoder().encode(all) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func load(_ path: String) -> [String: Record] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let arr = try? JSONDecoder().decode([Record].self, from: data) else { return [:] }
        return Dictionary(arr.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    }
}
