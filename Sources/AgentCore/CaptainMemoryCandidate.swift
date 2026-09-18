import Foundation

public struct CaptainMemoryCandidate: Codable, Sendable, Equatable {
    public let layerID: CaptainMemoryLayerID
    public let recordID: String
    public let title: String
    public let excerpt: String
    public let sourcePath: String
    public let baseRelevance: Int
    /// Original temporal identity for admission after host projection. Audit-only candidates
    /// may omit it; host-projected shared recall requires the full envelope.
    public let temporal: MemoryTemporalEnvelope?

    public init(layerID: CaptainMemoryLayerID, recordID: String, title: String,
                excerpt: String, sourcePath: String, baseRelevance: Int = 0,
                temporal: MemoryTemporalEnvelope? = nil) {
        self.layerID = layerID
        self.recordID = recordID
        self.title = title
        self.excerpt = excerpt
        self.sourcePath = sourcePath
        self.baseRelevance = min(100, max(0, baseRelevance))
        self.temporal = temporal
    }
}

public struct CaptainRetrievedMemory: Codable, Sendable, Equatable {
    public let layerID: CaptainMemoryLayerID
    public let recordID: String
    public let title: String
    public let excerpt: String
    public let sourcePath: String
    public let relevance: Int
    public let reason: String

    public init(layerID: CaptainMemoryLayerID, recordID: String, title: String,
                excerpt: String, sourcePath: String, relevance: Int, reason: String) {
        self.layerID = layerID
        self.recordID = recordID
        self.title = title
        self.excerpt = excerpt
        self.sourcePath = sourcePath
        self.relevance = min(100, max(0, relevance))
        self.reason = reason
    }

    public var evidenceID: String {
        "\(layerID.rawValue):\(recordID)"
    }
}
