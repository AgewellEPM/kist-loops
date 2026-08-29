import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct SemanticMemoryAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

public enum SemanticMemoryProvenanceKind: String, Codable, Sendable, Equatable {
    case manualObservation = "manual-observation"
    case locallyCheckedLesson = "locally-checked-lesson"
    case promotedToolLesson = "promoted-tool-lesson"
    case lifecycleRetirement = "lifecycle-retirement"
    case lifecycleSupersession = "lifecycle-supersession"
}

/// Advisory provenance only. A source locator makes a later audit possible; it is never a receipt,
/// signature, or authority grant.
public struct SemanticMemoryProvenance: Codable, Sendable, Equatable {
    public let kind: SemanticMemoryProvenanceKind
    public let sourceLocator: String?
    /// SHA-256 of the exact stored text. This binds the advisory provenance label to content and
    /// makes later store edits fail closed; it is not a signature or receipt.
    public let contentDigest: String?

    public init(kind: SemanticMemoryProvenanceKind, sourceLocator: String? = nil,
                contentDigest: String? = nil) {
        self.kind = kind
        self.sourceLocator = sourceLocator
        self.contentDigest = contentDigest
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, sourceLocator, contentDigest
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: SemanticMemoryAnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        let unknown = raw.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown semantic-memory provenance fields: \(unknown.joined(separator: ", "))"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(SemanticMemoryProvenanceKind.self, forKey: .kind)
        sourceLocator = try values.decodeIfPresent(String.self, forKey: .sourceLocator)
        contentDigest = try values.decodeIfPresent(String.self, forKey: .contentDigest)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(sourceLocator, forKey: .sourceLocator)
        try values.encodeIfPresent(contentDigest, forKey: .contentDigest)
    }
}

public struct VectorHit: Sendable, Equatable {
    public var id: String
    public var text: String
    /// Composite retrieval score: non-negative cosine similarity × temporal salience.
    public var score: Float
    public var metadata: [String: String]
    /// Raw embedding similarity retained for diagnostics; it is not authority.
    public var semanticScore: Float?
    public var temporalSalience: Double?
    public var temporalState: TemporalMemoryState?
    public var inSeason: Bool?
    public var provenance: SemanticMemoryProvenance?
    public var embeddingSpace: String?

    public init(id: String, text: String, score: Float, metadata: [String: String],
                semanticScore: Float? = nil, temporalSalience: Double? = nil,
                temporalState: TemporalMemoryState? = nil, inSeason: Bool? = nil,
                provenance: SemanticMemoryProvenance? = nil, embeddingSpace: String? = nil) {
        self.id = id
        self.text = text
        self.score = score
        self.metadata = metadata
        self.semanticScore = semanticScore
        self.temporalSalience = temporalSalience
        self.temporalState = temporalState
        self.inSeason = inSeason
        self.provenance = provenance
        self.embeddingSpace = embeddingSpace
    }
}

public enum VectorStoreError: Error, Sendable, Equatable, LocalizedError {
    case unsafeStore(String)
    case malformedStore(String)
    case invalidRecord(String)
    case persistence(String)
    case missingRecord(String)
    case incompatibleEmbeddingSpace(expected: String, found: String)

    public var errorDescription: String? {
        switch self {
        case .unsafeStore(let detail): return "unsafe semantic-memory store: \(detail)"
        case .malformedStore(let detail): return "malformed semantic-memory store: \(detail)"
        case .invalidRecord(let detail): return "invalid semantic-memory record: \(detail)"
        case .persistence(let detail): return "semantic-memory persistence failed: \(detail)"
        case .missingRecord(let id): return "semantic-memory record not found: \(id)"
        case .incompatibleEmbeddingSpace(let expected, let found):
            return "semantic-memory embedding space mismatch: expected \(expected), found \(found)"
        }
    }
}

/// Foundation's JSON decoders accept duplicate object members and keep one value. Persistence must
/// reject that ambiguity before decoding, otherwise a later mutation can silently normalize away a
/// conflicting lifecycle, logical identity, or provenance field.
private struct SemanticMemoryJSONScanner {
    private static let maximumDepth = 128
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func validateUniqueObjectKeys() throws {
        skipWhitespace()
        try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw VectorStoreError.malformedStore("JSON structure")
        }
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth <= Self.maximumDepth, index < bytes.count else {
            throw VectorStoreError.malformedStore("JSON structure")
        }
        switch bytes[index] {
        case 0x7B: try parseObject(depth: depth + 1) // {
        case 0x5B: try parseArray(depth: depth + 1) // [
        case 0x22: _ = try parseString()
        default: try parsePrimitive()
        }
    }

    private mutating func parseObject(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return } // }
        var keys = Set<String>()
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw VectorStoreError.malformedStore("JSON structure")
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw VectorStoreError.malformedStore("duplicate JSON object key")
            }
            skipWhitespace()
            guard consume(0x3A) else { // :
                throw VectorStoreError.malformedStore("JSON structure")
            }
            skipWhitespace()
            try parseValue(depth: depth)
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { // ,
                throw VectorStoreError.malformedStore("JSON structure")
            }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return } // ]
        while true {
            try parseValue(depth: depth)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { // ,
                throw VectorStoreError.malformedStore("JSON structure")
            }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 { // "
                index += 1
                do {
                    return try JSONDecoder().decode(
                        String.self, from: Data(bytes[start..<index]))
                } catch {
                    throw VectorStoreError.malformedStore("JSON string")
                }
            }
            guard byte >= 0x20 else {
                throw VectorStoreError.malformedStore("JSON string")
            }
            if byte == 0x5C { // backslash escape
                index += 1
                guard index < bytes.count else {
                    throw VectorStoreError.malformedStore("JSON string")
                }
                if bytes[index] == 0x75 { // uXXXX
                    guard index + 4 < bytes.count else {
                        throw VectorStoreError.malformedStore("JSON string")
                    }
                    index += 5
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        throw VectorStoreError.malformedStore("JSON string")
    }

    private mutating func parsePrimitive() throws {
        let start = index
        while index < bytes.count {
            let byte = bytes[index]
            if Self.isWhitespace(byte) || byte == 0x2C || byte == 0x5D || byte == 0x7D
                || byte == 0x3A {
                break
            }
            index += 1
        }
        guard index > start else {
            throw VectorStoreError.malformedStore("JSON structure")
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, Self.isWhitespace(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

/// A durable vector store with explicit bitemporal revisions. Legacy rows remain readable for audit,
/// but a row without `temporal` is never eligible for operational recall. Every mutation reloads under
/// an owner-owned sidecar `flock`, merges, and atomically publishes a 0600 file; every query reloads under
/// a shared lock so long-running Kist processes see each other's writes.
public final class FileBackedVectorStore: @unchecked Sendable {
    public struct Record: Codable, Equatable, Sendable {
        /// Physical revision identity. Legacy rows used their logical content hash here.
        public var id: String
        /// Stable content identity shared by all physical revisions. Nil means legacy `id` is the key.
        public var logicalID: String?
        public var vector: [Float]
        public var text: String
        public var metadata: [String: String]
        public var temporal: MemoryTemporalEnvelope?
        public var provenance: SemanticMemoryProvenance?
        public var embeddingSpace: String?

        public init(id: String, logicalID: String? = nil, vector: [Float], text: String,
                    metadata: [String: String] = [:], temporal: MemoryTemporalEnvelope? = nil,
                    provenance: SemanticMemoryProvenance? = nil, embeddingSpace: String? = nil) {
            self.id = id
            self.logicalID = logicalID
            self.vector = vector
            self.text = text
            self.metadata = metadata
            self.temporal = temporal
            self.provenance = provenance
            self.embeddingSpace = embeddingSpace
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, logicalID, vector, text, metadata, temporal, provenance, embeddingSpace
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.container(keyedBy: SemanticMemoryAnyCodingKey.self)
            let allowed = Set(CodingKeys.allCases.map(\.rawValue))
            let unknown = raw.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
            guard unknown.isEmpty else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown semantic-memory record fields: \(unknown.joined(separator: ", "))"))
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            logicalID = try values.decodeIfPresent(String.self, forKey: .logicalID)
            vector = try values.decode([Float].self, forKey: .vector)
            text = try values.decode(String.self, forKey: .text)
            metadata = try values.decode([String: String].self, forKey: .metadata)
            temporal = try values.decodeIfPresent(MemoryTemporalEnvelope.self, forKey: .temporal)
            provenance = try values.decodeIfPresent(
                SemanticMemoryProvenance.self, forKey: .provenance)
            embeddingSpace = try values.decodeIfPresent(String.self, forKey: .embeddingSpace)
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encodeIfPresent(logicalID, forKey: .logicalID)
            try values.encode(vector, forKey: .vector)
            try values.encode(text, forKey: .text)
            try values.encode(metadata, forKey: .metadata)
            try values.encodeIfPresent(temporal, forKey: .temporal)
            try values.encodeIfPresent(provenance, forKey: .provenance)
            try values.encodeIfPresent(embeddingSpace, forKey: .embeddingSpace)
        }

        fileprivate var logicalKey: String { logicalID ?? id }
    }

    private static let maximumStoreBytes = 64 * 1_024 * 1_024
    private static let maximumRecords = 20_000
    private static let maximumVectorDimensions = 32_768
    private static let maximumTextBytes = 262_144
    private static let maximumMetadataEntries = 64
    private static let maximumMetadataFieldBytes = 4_096
    private static let maximumIdentityBytes = 512
    private static let maximumTopK = 100

    private enum DirectUpsertAdmission {
        case auditCompatibility
        case operationalFixture
    }

    private let path: String
    private let confinementRoot: String?
    /// `flock` is the cross-process boundary; this also serializes separate store instances inside one
    /// process so their lock-file create/open sequence cannot race on platforms with process-scoped flock.
    private static let processLock = NSLock()

    /// `confinementRoot` is the trusted project boundary. Semantic V2 paths also infer it from the
    /// `/.kist/` component so callers cannot accidentally re-enable intermediate-symlink traversal.
    public init(path: String, confinementRoot: String? = nil) {
        self.path = path
        self.confinementRoot = confinementRoot
    }

    /// Number of distinct logical memories, including legacy audit-only memories.
    public var count: Int {
        get throws { try logicalCount() }
    }

    public func logicalCount() throws -> Int {
        Set(try auditRecords().map(\.logicalKey)).count
    }

    /// Public compatibility upsert is deliberately audit-only. Operational temporal rows can enter
    /// only through the constrained semantic service paths below.
    @discardableResult
    public func upsert(id: String, vector: [Float], text: String,
                       metadata: [String: String] = [:]) throws -> Int {
        let record = Record(id: id, vector: vector, text: text, metadata: metadata)
        return try directUpsert(record, admission: .auditCompatibility)
    }

    /// Internal fixture/migration seam; the record-policy validator still applies in full.
    @discardableResult
    func upsertOperational(id: String, logicalID: String? = nil,
                           vector: [Float], text: String,
                           metadata: [String: String] = [:],
                           temporal: MemoryTemporalEnvelope?,
                           provenance: SemanticMemoryProvenance?,
                           embeddingSpace: String?) throws -> Int {
        let record = Record(id: id, logicalID: logicalID,
                            vector: vector, text: text, metadata: metadata,
                            temporal: temporal, provenance: provenance,
                            embeddingSpace: embeddingSpace)
        return try directUpsert(record, admission: .operationalFixture)
    }

    private func directUpsert(_ record: Record,
                              admission: DirectUpsertAdmission) throws -> Int {
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        return try withLockedStore(exclusive: true, createDirectory: true) { directoryFD in
            var records = try readStrict(directoryFD: directoryFD)
            try Self.validate(record)
            switch admission {
            case .auditCompatibility:
                // The compatibility API may update a purely timeless V1-style store, but it cannot
                // enter or alter a V2 operational history. Otherwise an exposed physical revision
                // ID could be replaced by an undated row and resurrect an older active revision.
                guard !records.contains(where: Self.isOperationalRecord) else {
                    throw VectorStoreError.invalidRecord(
                        "audit-only upsert refused for operational store")
                }
                records.removeAll { $0.id == record.id }
            case .operationalFixture:
                // Operational history is append-only. Even this internal fixture seam cannot
                // rewrite a physical revision in place.
                guard !records.contains(where: { $0.id == record.id }) else {
                    throw VectorStoreError.invalidRecord("physical revision id collision")
                }
                try Self.validateOperationalSignature(record, against: records)
            }
            records.append(record)
            try Self.validateCollection(records)
            try write(records, directoryFD: directoryFD)
            return Set(records.map(\.logicalKey)).count
        } ?? 0
    }

    private static func isOperationalRecord(_ record: Record) -> Bool {
        record.temporal != nil || record.provenance != nil || record.embeddingSpace != nil
            || record.logicalID != nil
    }

    /// Append a physical revision for a genuine observation. If a clocked revision already exists,
    /// an ordinary duplicate advances only transaction time. A legacy row is never rewritten or
    /// retroactively assigned a clock; the new observation is appended beside it.
    @discardableResult
    func rememberRevision(logicalID: String, vector: [Float], text: String,
                          metadata: [String: String],
                          initialTemporal: MemoryTemporalEnvelope,
                          provenance: SemanticMemoryProvenance,
                          embeddingSpace: String, transactionAt: Date) throws -> Int {
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        return try withLockedStore(exclusive: true, createDirectory: true) { directoryFD in
            var records = try readStrict(directoryFD: directoryFD)
            let physicalID = Self.revisionID(logicalID: logicalID, at: transactionAt)
            let proposed = Record(
                id: physicalID, logicalID: logicalID, vector: vector, text: text,
                metadata: metadata, temporal: initialTemporal,
                provenance: provenance, embeddingSpace: embeddingSpace)
            // Validate the actual observation before duplicate preservation can discard any of its
            // fields. A broken embedder must never be laundered into a successful transaction-only
            // revision merely because an older vector is retained.
            try Self.validate(proposed)
            try Self.validateOperationalSignature(proposed, against: records)
            let matches = records.enumerated().filter { $0.element.logicalKey == logicalID }
            let latestClocked = matches
                .filter { $0.element.temporal != nil }
                .max { lhs, rhs in
                    let left = lhs.element.temporal!.updatedAt
                    let right = rhs.element.temporal!.updatedAt
                    return left == right ? lhs.offset < rhs.offset : left < right
                }
            var temporal = initialTemporal
            var revisionVector = vector
            var revisionText = text
            var revisionMetadata = metadata
            var revisionProvenance = provenance
            var revisionEmbeddingSpace = embeddingSpace
            if let latest = latestClocked, var existing = latest.element.temporal {
                guard latest.element.embeddingSpace == embeddingSpace else {
                    throw VectorStoreError.incompatibleEmbeddingSpace(
                        expected: embeddingSpace,
                        found: latest.element.embeddingSpace ?? "missing")
                }
                guard latest.element.vector.count == vector.count else {
                    throw VectorStoreError.incompatibleEmbeddingSpace(
                        expected: "\(embeddingSpace)/\(latest.element.vector.count)d",
                        found: "\(embeddingSpace)/\(vector.count)d")
                }
                try existing.recordTransaction(at: transactionAt)
                temporal = existing
                // An ordinary duplicate is transaction-only. It must not replace a prior checked
                // vector, metadata, or provenance with fresh unsigned input.
                revisionVector = latest.element.vector
                revisionText = latest.element.text
                revisionMetadata = latest.element.metadata
                revisionProvenance = latest.element.provenance ?? provenance
                revisionEmbeddingSpace = latest.element.embeddingSpace ?? embeddingSpace
            }
            let record = Record(
                id: physicalID,
                logicalID: logicalID, vector: revisionVector, text: revisionText,
                metadata: revisionMetadata, temporal: temporal,
                provenance: revisionProvenance, embeddingSpace: revisionEmbeddingSpace)
            try Self.validate(record)
            try Self.validateOperationalSignature(record, against: records)
            records.append(record)
            try Self.validateCollection(records)
            try write(records, directoryFD: directoryFD)
            return Set(records.map(\.logicalKey)).count
        } ?? 0
    }

    /// Append a revision backed by newly checked evidence. Unlike an ordinary duplicate remember,
    /// this path is allowed to reinforce truth. Existing active memory keeps its original event,
    /// validity, access, and recurrence history while the checked lesson policy is normalized to a
    /// bounded, unpinned slow-decay envelope.
    @discardableResult
    func rememberVerifiedRevision(
        logicalID: String, vector: [Float], text: String,
        metadata: [String: String], initialTemporal: MemoryTemporalEnvelope,
        provenance: SemanticMemoryProvenance, embeddingSpace: String,
        evidenceAt: Date, transactionAt: Date
    ) throws -> Int {
        guard provenance.kind == .locallyCheckedLesson || provenance.kind == .promotedToolLesson,
              provenance.sourceLocator != nil else {
            throw VectorStoreError.invalidRecord("verified provenance")
        }
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        return try withLockedStore(exclusive: true, createDirectory: true) { directoryFD in
            var records = try readStrict(directoryFD: directoryFD)
            let latestClocked = records.enumerated()
                .filter { $0.element.logicalKey == logicalID && $0.element.temporal != nil }
                .max { lhs, rhs in
                    let left = lhs.element.temporal!.updatedAt
                    let right = rhs.element.temporal!.updatedAt
                    return left == right ? lhs.offset < rhs.offset : left < right
                }
            var temporal = initialTemporal
            if let latestClocked, var existing = latestClocked.element.temporal {
                guard latestClocked.element.embeddingSpace == embeddingSpace else {
                    throw VectorStoreError.incompatibleEmbeddingSpace(
                        expected: embeddingSpace,
                        found: latestClocked.element.embeddingSpace ?? "missing")
                }
                try existing.reinforce(verified: true, confirmedAt: evidenceAt, now: transactionAt)
                temporal = try Self.checkedLessonEnvelope(from: existing)
            }
            let record = Record(
                id: Self.revisionID(logicalID: logicalID, at: transactionAt),
                logicalID: logicalID, vector: vector, text: text, metadata: metadata,
                temporal: temporal, provenance: provenance, embeddingSpace: embeddingSpace)
            try Self.validate(record)
            try Self.validateOperationalSignature(record, against: records)
            records.append(record)
            try Self.validateCollection(records)
            try write(records, directoryFD: directoryFD)
            return Set(records.map(\.logicalKey)).count
        } ?? 0
    }

    /// Append a verified-evidence reinforcement revision. The caller must supply typed, bounded
    /// provenance; ordinary remember/recall paths cannot reach this operation.
    @discardableResult
    func reinforce(logicalID: String, evidenceAt: Date, now: Date,
                   provenance: SemanticMemoryProvenance) throws -> Int {
        guard provenance.kind == .locallyCheckedLesson || provenance.kind == .promotedToolLesson else {
            throw VectorStoreError.invalidRecord("verified provenance")
        }
        return try mutateLatest(logicalID: logicalID, at: now, provenance: provenance) { temporal in
            try temporal.reinforce(verified: true, confirmedAt: evidenceAt, now: now)
            temporal = try Self.checkedLessonEnvelope(from: temporal)
        }
    }

    @discardableResult
    func retire(logicalID: String, reason: String, now: Date,
                provenance: SemanticMemoryProvenance) throws -> Int {
        guard provenance.kind == .lifecycleRetirement else {
            throw VectorStoreError.invalidRecord("retirement provenance")
        }
        return try mutateLatest(logicalID: logicalID, at: now, provenance: provenance) { temporal in
            try temporal.retire(reason: reason, now: now)
        }
    }

    @discardableResult
    func supersede(logicalID: String, by replacementID: String, now: Date,
                   provenance: SemanticMemoryProvenance) throws -> Int {
        guard provenance.kind == .lifecycleSupersession else {
            throw VectorStoreError.invalidRecord("supersession provenance")
        }
        return try mutateLatest(logicalID: logicalID, at: now, provenance: provenance) { temporal in
            try temporal.markSuperseded(by: replacementID, now: now)
        }
    }

    /// Temporal semantic query. It considers exactly the newest clocked transaction for each logical
    /// memory, evaluates lifecycle/validity/decay/season before similarity, and performs no mutation.
    public func query(_ vector: [Float], embeddingSpace: String,
                      topK: Int = 5, at now: Date = Date()) throws -> [VectorHit] {
        try queryWithDiagnostics(
            vector, embeddingSpace: embeddingSpace, topK: topK, at: now).hits
    }

    /// The service consumes the degradation count so a successful partial recall cannot clear store
    /// health. Public callers retain the compact hit-only API above.
    func queryWithDiagnostics(
        _ vector: [Float], embeddingSpace: String,
        topK: Int = 5, at now: Date = Date()
    ) throws -> (hits: [VectorHit], quarantinedLogicalMemories: Int) {
        guard topK > 0 else { return ([], 0) }
        try Self.validateVector(vector, field: "query")
        try Self.validateEmbeddingSpace(embeddingSpace)
        let recovered = try recallRecords(
            embeddingSpace: embeddingSpace, dimensions: vector.count)
        let records = recovered.records
        let qn = Self.norm(vector)
        guard qn > 0 else { return ([], recovered.quarantinedLogicalMemories) }

        var newest: [String: (ordinal: Int, record: Record)] = [:]
        for (ordinal, record) in records.enumerated() {
            guard let temporal = record.temporal else { continue }
            guard record.embeddingSpace == embeddingSpace else {
                throw VectorStoreError.incompatibleEmbeddingSpace(
                    expected: embeddingSpace, found: record.embeddingSpace ?? "missing")
            }
            guard record.vector.count == vector.count else {
                throw VectorStoreError.incompatibleEmbeddingSpace(
                    expected: "\(embeddingSpace)/\(vector.count)d",
                    found: "\(embeddingSpace)/\(record.vector.count)d")
            }
            let key = record.logicalKey
            if let prior = newest[key], let priorTemporal = prior.record.temporal {
                if temporal.updatedAt < priorTemporal.updatedAt { continue }
                if temporal.updatedAt == priorTemporal.updatedAt, ordinal < prior.ordinal { continue }
            }
            newest[key] = (ordinal, record)
        }

        var scored: [(ordinal: Int, transaction: Date, hit: VectorHit)] = []
        for (logicalID, selected) in newest {
            guard let temporal = selected.record.temporal else { continue }
            let evaluation = temporal.evaluate(at: now)
            guard evaluation.isRetrievalEligible,
                  evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor else { continue }
            let raw = max(0, Self.cosine(vector, selected.record.vector, normA: qn))
            let composite = raw * Float(evaluation.salience)
            guard composite.isFinite, composite > 0 else { continue }
            scored.append((
                ordinal: selected.ordinal,
                transaction: temporal.updatedAt,
                hit: VectorHit(
                    id: logicalID, text: selected.record.text, score: composite,
                    metadata: selected.record.metadata, semanticScore: raw,
                    temporalSalience: evaluation.salience, temporalState: evaluation.state,
                    inSeason: evaluation.inSeason, provenance: selected.record.provenance,
                    embeddingSpace: selected.record.embeddingSpace)))
        }
        scored.sort { lhs, rhs in
            if lhs.hit.score != rhs.hit.score { return lhs.hit.score > rhs.hit.score }
            if lhs.hit.semanticScore != rhs.hit.semanticScore {
                return (lhs.hit.semanticScore ?? 0) > (rhs.hit.semanticScore ?? 0)
            }
            if lhs.transaction != rhs.transaction { return lhs.transaction > rhs.transaction }
            if lhs.ordinal != rhs.ordinal { return lhs.ordinal > rhs.ordinal }
            return lhs.hit.id < rhs.hit.id
        }
        return (
            scored.prefix(min(topK, Self.maximumTopK)).map(\.hit),
            recovered.quarantinedLogicalMemories)
    }

    /// Complete physical history for audit/tests. This is not a retrieval API and confers no authority.
    public func auditRecords() throws -> [Record] {
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        return try withLockedStore(exclusive: false, createDirectory: false) { directoryFD in
            try readStrict(directoryFD: directoryFD)
        } ?? []
    }

    /// Query may salvage individually valid, unambiguous logical histories from a syntactically valid
    /// array. A malformed revision poisons its whole logical memory so dropping a bad retirement can
    /// never resurrect an older active row. Strict audit and every mutation still reject the file.
    private func recallRecords(
        embeddingSpace: String, dimensions: Int
    ) throws -> (records: [Record], quarantinedLogicalMemories: Int) {
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        return try withLockedStore(exclusive: false, createDirectory: false) { directoryFD in
            try readRecoverableForQuery(
                directoryFD: directoryFD,
                embeddingSpace: embeddingSpace, dimensions: dimensions)
        } ?? ([], 0)
    }

    // MARK: cosine

    static func norm(_ value: [Float]) -> Float {
        guard let norm = stableNorm(value), norm <= Double(Float.greatestFiniteMagnitude) else {
            return .infinity
        }
        return Float(norm)
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float], normA: Float? = nil) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let leftNorm = normA.map(Double.init) ?? stableNorm(lhs) ?? 0
        let rightNorm = stableNorm(rhs) ?? 0
        guard leftNorm > 0, rightNorm > 0,
              leftNorm.isFinite, rightNorm.isFinite else { return 0 }
        let dot = zip(lhs, rhs).reduce(0.0) {
            $0 + Double($1.0) * Double($1.1)
        }
        let result = dot / (leftNorm * rightNorm)
        return result.isFinite ? Float(result) : 0
    }

    private static func stableNorm(_ vector: [Float]) -> Double? {
        let scale = vector.reduce(0.0) { max($0, abs(Double($1))) }
        guard scale > 0, scale.isFinite else { return nil }
        let scaledSquares = vector.reduce(0.0) {
            let value = Double($1) / scale
            return $0 + value * value
        }
        let result = scale * scaledSquares.squareRoot()
        return result.isFinite && result > 0 ? result : nil
    }

    // MARK: revision mutation

    private func mutateLatest(logicalID: String, at now: Date,
                              provenance: SemanticMemoryProvenance,
                              mutation: (inout MemoryTemporalEnvelope) throws -> Void) throws -> Int {
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        return try withLockedStore(exclusive: true, createDirectory: false) { directoryFD in
            var records = try readStrict(directoryFD: directoryFD)
            let latest = records.enumerated()
                .filter { $0.element.logicalKey == logicalID && $0.element.temporal != nil }
                .max { lhs, rhs in
                    let left = lhs.element.temporal!.updatedAt
                    let right = rhs.element.temporal!.updatedAt
                    return left == right ? lhs.offset < rhs.offset : left < right
                }
            guard let latest, var temporal = latest.element.temporal else {
                throw VectorStoreError.missingRecord(logicalID)
            }
            try mutation(&temporal)
            let revision = Record(
                id: Self.revisionID(logicalID: logicalID, at: now), logicalID: logicalID,
                vector: latest.element.vector, text: latest.element.text,
                metadata: latest.element.metadata, temporal: temporal, provenance: provenance,
                embeddingSpace: latest.element.embeddingSpace)
            try Self.validate(revision)
            records.append(revision)
            try Self.validateCollection(records)
            try write(records, directoryFD: directoryFD)
            return Set(records.map(\.logicalKey)).count
        } ?? { throw VectorStoreError.missingRecord(logicalID) }()
    }

    private static func revisionID(logicalID: String, at instant: Date) -> String {
        let micros = Int64((instant.timeIntervalSince1970 * 1_000_000).rounded(.towardZero))
        return "\(logicalID):\(micros):\(UUID().uuidString.lowercased())"
    }

    private static func checkedLessonEnvelope(
        from existing: MemoryTemporalEnvelope
    ) throws -> MemoryTemporalEnvelope {
        try MemoryTemporalEnvelope(
            createdAt: existing.createdAt, updatedAt: existing.updatedAt,
            accessedAt: existing.accessedAt, validFrom: existing.validFrom,
            validUntil: existing.validUntil, lastConfirmedAt: existing.lastConfirmedAt,
            seasonalWindow: existing.seasonalWindow, accessCount: existing.accessCount,
            reinforcementCount: existing.reinforcementCount, decayRate: .slow,
            baseSalience: min(existing.baseSalience, 0.8), pinned: false,
            status: existing.status, retiredAt: existing.retiredAt,
            retiredReason: existing.retiredReason, supersededBy: existing.supersededBy,
            supersedes: existing.supersedes)
    }

    // MARK: locked persistence

    private func withLockedStore<T>(exclusive: Bool, createDirectory: Bool,
                                    _ body: (Int32) throws -> T) throws -> T? {
        let fileURL = URL(fileURLWithPath: path)
        let directory = fileURL.deletingLastPathComponent().path
        let basename = fileURL.lastPathComponent
        guard !basename.isEmpty, basename != ".", basename != "..", !basename.contains("/") else {
            throw VectorStoreError.unsafeStore("invalid filename")
        }
        guard let directoryFD = try openStoreDirectory(
            directory, createDirectory: createDirectory) else { return nil }
        defer { _ = close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & mode_t(0o022)) == 0 else {
            throw VectorStoreError.unsafeStore("directory is not owner-controlled")
        }

        let lockName = ".\(basename).lock"
        var lockFlags = O_RDWR | O_CLOEXEC | O_NOFOLLOW
        #if canImport(Darwin)
        // Acquire the advisory lock atomically with open. This avoids an unprotected descriptor
        // window and is explicitly supported for O_CREAT on Darwin filesystems.
        lockFlags |= exclusive ? O_EXLOCK : O_SHLOCK
        #endif
        let lockFD = Self.openOrCreateLock(
            directoryFD: directoryFD, name: lockName, flags: lockFlags)
        guard lockFD >= 0 else {
            throw VectorStoreError.unsafeStore("open lock (errno \(errno))")
        }
        defer { _ = close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0,
              (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              lockInfo.st_uid == geteuid(), lockInfo.st_nlink == 1,
              fchmod(lockFD, mode_t(0o600)) == 0 else {
            throw VectorStoreError.unsafeStore("lock is not an owner-only regular file")
        }
        #if !canImport(Darwin)
        guard flock(lockFD, exclusive ? LOCK_EX : LOCK_SH) == 0 else {
            throw VectorStoreError.unsafeStore("lock acquisition failed")
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        #endif
        return try body(directoryFD)
    }

    private func openStoreDirectory(_ directory: String,
                                    createDirectory: Bool) throws -> Int32? {
        guard let root = effectiveConfinementRoot(for: directory) else {
            if createDirectory {
                do {
                    try FileManager.default.createDirectory(
                        atPath: directory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
                } catch {
                    throw VectorStoreError.persistence("create directory")
                }
            }
            let descriptor = Self.openDirectoryRetryingInterrupts(directory)
            if descriptor < 0 {
                if !createDirectory, errno == ENOENT { return nil }
                throw VectorStoreError.unsafeStore("open directory")
            }
            return descriptor
        }

        let normalizedDirectory = URL(fileURLWithPath: directory).standardizedFileURL.path
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        let prefix = normalizedRoot == "/" ? "/" : normalizedRoot + "/"
        guard normalizedDirectory == normalizedRoot || normalizedDirectory.hasPrefix(prefix) else {
            throw VectorStoreError.unsafeStore("store escapes confinement root")
        }
        let relative = normalizedDirectory == normalizedRoot
            ? ""
            : String(normalizedDirectory.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw VectorStoreError.unsafeStore("invalid directory component")
        }

        var currentFD = Self.openDirectoryRetryingInterrupts(normalizedRoot)
        if currentFD < 0 {
            if !createDirectory, errno == ENOENT { return nil }
            throw VectorStoreError.unsafeStore("open confinement root")
        }
        for componentSlice in components {
            let component = String(componentSlice)
            var nextFD = Self.openDirectoryAtRetryingInterrupts(
                directoryFD: currentFD, name: component)
            if nextFD < 0, errno == ENOENT, createDirectory {
                var mkdirResult: Int32
                repeat { mkdirResult = mkdirat(currentFD, component, mode_t(0o700)) }
                while mkdirResult < 0 && errno == EINTR
                if mkdirResult < 0 && errno != EEXIST {
                    _ = close(currentFD)
                    throw VectorStoreError.persistence("create confined directory")
                }
                nextFD = Self.openDirectoryAtRetryingInterrupts(
                    directoryFD: currentFD, name: component)
            }
            if nextFD < 0 {
                let missing = errno == ENOENT
                _ = close(currentFD)
                if missing, !createDirectory { return nil }
                throw VectorStoreError.unsafeStore("open confined directory component")
            }
            var info = stat()
            guard fstat(nextFD, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  info.st_uid == geteuid(),
                  (info.st_mode & mode_t(0o022)) == 0 else {
                _ = close(nextFD)
                _ = close(currentFD)
                throw VectorStoreError.unsafeStore(
                    "confined directory component is not owner-controlled")
            }
            _ = close(currentFD)
            currentFD = nextFD
        }
        return currentFD
    }

    private func effectiveConfinementRoot(for directory: String) -> String? {
        if let confinementRoot, !confinementRoot.isEmpty { return confinementRoot }
        let normalized = URL(fileURLWithPath: directory).standardizedFileURL.path
        guard let marker = normalized.range(of: "/.kist/") else { return nil }
        let prefix = String(normalized[..<marker.lowerBound])
        return prefix.isEmpty ? "/" : prefix
    }

    private static func openDirectoryRetryingInterrupts(_ directory: String) -> Int32 {
        var descriptor: Int32
        repeat {
            descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        } while descriptor < 0 && errno == EINTR
        return descriptor
    }

    private static func openDirectoryAtRetryingInterrupts(directoryFD: Int32,
                                                           name: String) -> Int32 {
        var descriptor: Int32
        repeat {
            descriptor = openat(
                directoryFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        } while descriptor < 0 && errno == EINTR
        return descriptor
    }

    private static func openAtRetryingInterrupts(directoryFD: Int32, name: String,
                                                  flags: Int32, mode: mode_t) -> Int32 {
        var descriptor: Int32
        repeat { descriptor = openat(directoryFD, name, flags, mode) }
        while descriptor < 0 && errno == EINTR
        return descriptor
    }

    /// Some APFS/noowners volumes return a transient ENOENT when several processes issue a bare
    /// O_CREAT openat for the same new lock. Resolve creation explicitly: open existing first, then
    /// race an exclusive create, and retry the EEXIST/ENOENT handoff without ever following a link.
    private static func openOrCreateLock(directoryFD: Int32, name: String,
                                         flags: Int32) -> Int32 {
        for _ in 0..<128 {
            let existing = openAtRetryingInterrupts(
                directoryFD: directoryFD, name: name, flags: flags, mode: mode_t(0))
            if existing >= 0 { return existing }
            let openError = errno
            guard openError == ENOENT else { return -1 }

            let created = openAtRetryingInterrupts(
                directoryFD: directoryFD, name: name,
                flags: flags | O_CREAT | O_EXCL, mode: mode_t(0o600))
            if created >= 0 { return created }
            let createError = errno
            if createError == EEXIST || createError == ENOENT { continue }
            errno = createError
            return -1
        }
        errno = EAGAIN
        return -1
    }

    private func readStrict(directoryFD: Int32) throws -> [Record] {
        guard let bytes = try readStoreBytes(directoryFD: directoryFD) else { return [] }
        var scanner = SemanticMemoryJSONScanner(bytes)
        try scanner.validateUniqueObjectKeys()
        let records: [Record]
        do { records = try JSONDecoder().decode([Record].self, from: bytes) }
        catch { throw VectorStoreError.malformedStore("JSON decode") }
        try Self.validateCollection(records)
        return records
    }

    private func readRecoverableForQuery(directoryFD: Int32, embeddingSpace: String,
                                         dimensions: Int) throws
        -> (records: [Record], quarantinedLogicalMemories: Int) {
        guard let bytes = try readStoreBytes(directoryFD: directoryFD) else { return ([], 0) }
        var scanner = SemanticMemoryJSONScanner(bytes)
        try scanner.validateUniqueObjectKeys()
        let rawRecords: [Any]
        do {
            guard let array = try JSONSerialization.jsonObject(with: bytes) as? [Any] else {
                throw VectorStoreError.malformedStore("JSON root")
            }
            rawRecords = array
        } catch let error as VectorStoreError {
            throw error
        } catch {
            throw VectorStoreError.malformedStore("JSON decode")
        }
        guard rawRecords.count <= Self.maximumRecords else {
            throw VectorStoreError.malformedStore("record count limit")
        }

        var rawPhysicalIDs = Set<String>()
        for raw in rawRecords {
            guard let dictionary = raw as? [String: Any],
                  let id = dictionary["id"] as? String,
                  dictionary["logical_id"] == nil,
                  (try? Self.validateIdentity(id, field: "id")) != nil else {
                throw VectorStoreError.malformedStore("unassignable record identity")
            }
            guard rawPhysicalIDs.insert(id).inserted else {
                throw VectorStoreError.malformedStore("duplicate physical identity")
            }
        }

        var candidates: [Record] = []
        var poisonedLogicalKeys = Set<String>()
        for raw in rawRecords {
            let rawKey = Self.rawCanonicalLogicalKey(raw)
            do {
                let data = try JSONSerialization.data(withJSONObject: raw)
                let record = try JSONDecoder().decode(Record.self, from: data)
                try Self.validate(record)
                candidates.append(record)
            } catch {
                guard let rawKey else {
                    // Without an explicit logical identity, dropping a malformed newest lifecycle
                    // revision could expose an older active row. Refuse the whole reading.
                    throw VectorStoreError.malformedStore(
                        "malformed revision lacks logical identity")
                }
                poisonedLogicalKeys.insert(rawKey)
            }
        }

        let physicalGroups = Dictionary(grouping: candidates, by: \.id)
        for group in physicalGroups.values where group.count > 1 {
            poisonedLogicalKeys.formUnion(group.map(\.logicalKey))
        }
        try Self.validateAuditPrefix(candidates)
        poisonedLogicalKeys.formUnion(Self.nonMonotonicLogicalKeys(in: candidates))
        poisonedLogicalKeys.formUnion(Self.invalidLifecycleTransitionKeys(in: candidates))

        let operational = candidates.filter { $0.temporal != nil }
        let signatures = Set(operational.compactMap { record -> String? in
            guard let space = record.embeddingSpace else { return nil }
            return "\(space)\u{0}\(record.vector.count)"
        })
        guard signatures.count <= 1 else {
            throw VectorStoreError.malformedStore("mixed operational embedding signature")
        }
        if let found = operational.first,
           found.embeddingSpace != embeddingSpace || found.vector.count != dimensions {
            throw VectorStoreError.incompatibleEmbeddingSpace(
                expected: "\(embeddingSpace)/\(dimensions)d",
                found: "\(found.embeddingSpace ?? "missing")/\(found.vector.count)d")
        }
        let eligibleRecords = candidates.filter { record in
            record.temporal != nil
                && !poisonedLogicalKeys.contains(record.logicalKey)
                && physicalGroups[record.id]?.count == 1
        }
        return (eligibleRecords, poisonedLogicalKeys.count)
    }

    private static func rawCanonicalLogicalKey(_ raw: Any) -> String? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        guard dictionary["logical_id"] == nil,
              let text = dictionary["text"] as? String,
              let logicalID = dictionary["logicalID"] as? String,
              let provenance = dictionary["provenance"] as? [String: Any],
              let digest = provenance["contentDigest"] as? String,
              digest == contentDigest(for: text), logicalID == digest,
              (try? validateIdentity(logicalID, field: "logicalID")) != nil else { return nil }
        return logicalID
    }

    private func readStoreBytes(directoryFD: Int32) throws -> Data? {
        let basename = URL(fileURLWithPath: path).lastPathComponent
        let descriptor = openat(directoryFD, basename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw VectorStoreError.unsafeStore("open data file")
        }
        defer { _ = close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == geteuid(), before.st_nlink == 1,
              (before.st_mode & mode_t(0o022)) == 0,
              before.st_size >= 0, before.st_size <= off_t(Self.maximumStoreBytes) else {
            throw VectorStoreError.unsafeStore("data file is not a bounded owner-owned regular file")
        }
        var bytes = Data()
        bytes.reserveCapacity(Int(before.st_size))
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let amount = chunk.withUnsafeMutableBytes { buffer -> Int in
                #if canImport(Darwin)
                return Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                #else
                return Glibc.read(descriptor, buffer.baseAddress, buffer.count)
                #endif
            }
            if amount < 0 {
                if errno == EINTR { continue }
                throw VectorStoreError.persistence("read data file")
            }
            if amount == 0 { break }
            bytes.append(contentsOf: chunk[0..<amount])
            guard bytes.count <= Self.maximumStoreBytes else {
                throw VectorStoreError.unsafeStore("data file grew beyond limit")
            }
        }
        var after = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &after) == 0,
              fstatat(directoryFD, basename, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              (after.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              after.st_uid == geteuid(), pathInfo.st_uid == geteuid(),
              after.st_nlink == 1, pathInfo.st_nlink == 1,
              (after.st_mode & mode_t(0o022)) == 0,
              (pathInfo.st_mode & mode_t(0o022)) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_dev == pathInfo.st_dev, before.st_ino == pathInfo.st_ino,
              before.st_size == pathInfo.st_size,
              bytes.count == Int(before.st_size) else {
            throw VectorStoreError.unsafeStore("data file changed while reading")
        }
        // A missing file is a new store; an existing zero-byte file is a truncated store. Treating
        // both as `[]` would let the next mutation silently launder lost history.
        guard !bytes.isEmpty else {
            throw VectorStoreError.malformedStore("empty data file")
        }
        return bytes
    }

    private func write(_ records: [Record], directoryFD: Int32) throws {
        try Self.validateCollection(records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(records) }
        catch { throw VectorStoreError.persistence("encode") }
        guard data.count <= Self.maximumStoreBytes else {
            throw VectorStoreError.persistence("store size limit")
        }

        let basename = URL(fileURLWithPath: path).lastPathComponent
        let temporary = ".\(basename).\(UUID().uuidString.lowercased()).tmp"
        var descriptor = openat(directoryFD, temporary,
                                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                                mode_t(0o600))
        guard descriptor >= 0 else { throw VectorStoreError.persistence("create temporary") }
        var published = false
        defer {
            if descriptor >= 0 { _ = close(descriptor) }
            if !published { _ = unlinkat(directoryFD, temporary, 0) }
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let amount = DarwinOrGlibc.write(
                    descriptor, base.advanced(by: offset), raw.count - offset)
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw VectorStoreError.persistence("write temporary")
                }
                guard amount > 0 else { throw VectorStoreError.persistence("short write") }
                offset += amount
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
            throw VectorStoreError.persistence("sync temporary")
        }
        guard close(descriptor) == 0 else {
            descriptor = -1
            throw VectorStoreError.persistence("close temporary")
        }
        descriptor = -1
        guard renameat(directoryFD, temporary, directoryFD, basename) == 0 else {
            throw VectorStoreError.persistence("publish")
        }
        published = true
        guard fsync(directoryFD) == 0 else {
            throw VectorStoreError.persistence("sync directory")
        }
    }

    // MARK: validation

    private static func validateCollection(_ records: [Record]) throws {
        guard records.count <= maximumRecords else {
            throw VectorStoreError.malformedStore("record count limit")
        }
        try validateAuditPrefix(records)
        guard nonMonotonicLogicalKeys(in: records).isEmpty else {
            throw VectorStoreError.malformedStore(
                "operational transaction time moves backward")
        }
        guard invalidLifecycleTransitionKeys(in: records).isEmpty else {
            throw VectorStoreError.malformedStore(
                "operational lifecycle transition is not append-safe")
        }
        var physicalIDs = Set<String>()
        var operationalSignature: (space: String, dimensions: Int)?
        for record in records {
            try validate(record)
            guard physicalIDs.insert(record.id).inserted else {
                throw VectorStoreError.malformedStore("duplicate physical identity")
            }
            if record.temporal != nil {
                guard let space = record.embeddingSpace else {
                    throw VectorStoreError.invalidRecord("operational embedding space")
                }
                let signature = (space: space, dimensions: record.vector.count)
                if let existing = operationalSignature {
                    guard existing.space == signature.space,
                          existing.dimensions == signature.dimensions else {
                        throw VectorStoreError.malformedStore(
                            "mixed operational embedding signature")
                    }
                } else {
                    operationalSignature = signature
                }
            }
        }
    }

    /// V1 audit rows may precede a genuine V2 re-observation, but append-only writers never place a
    /// timeless row after operational history begins. Enforcing that order prevents a newest retirement
    /// from being field-stripped into an ignored legacy row that resurrects an older active revision.
    private static func validateAuditPrefix(_ records: [Record]) throws {
        var sawOperational = false
        for record in records {
            if isOperationalRecord(record) {
                sawOperational = true
            } else if sawOperational {
                throw VectorStoreError.malformedStore(
                    "audit-only record appears after operational history")
            }
        }
    }

    /// Physical append order is the durable transaction sequence. A backdated later revision must
    /// never lose newest-selection to an older active row; strict reads reject it, while recoverable
    /// query quarantines that entire logical history.
    private static func nonMonotonicLogicalKeys(in records: [Record]) -> Set<String> {
        var latestByLogicalKey: [String: Date] = [:]
        var poisoned = Set<String>()
        for record in records {
            guard let temporal = record.temporal else { continue }
            let key = record.logicalKey
            if let latest = latestByLogicalKey[key], temporal.updatedAt < latest {
                poisoned.insert(key)
                continue
            }
            latestByLogicalKey[key] = temporal.updatedAt
        }
        return poisoned
    }

    /// Retirement and supersession are terminal for a logical content identity. Later transaction-only
    /// revisions may preserve that terminal marker, but no ordinary append may reactivate or rewrite it.
    private static func invalidLifecycleTransitionKeys(in records: [Record]) -> Set<String> {
        typealias Terminal = (
            status: MemoryLifecycleStatus,
            retiredAt: Date?,
            reason: String?,
            supersededBy: String?
        )
        var terminalByLogicalKey: [String: Terminal] = [:]
        var poisoned = Set<String>()
        for record in records {
            guard let temporal = record.temporal else { continue }
            let key = record.logicalKey
            if let terminal = terminalByLogicalKey[key] {
                guard temporal.status == terminal.status,
                      temporal.retiredAt == terminal.retiredAt,
                      temporal.retiredReason == terminal.reason,
                      temporal.supersededBy == terminal.supersededBy else {
                    poisoned.insert(key)
                    continue
                }
            } else if temporal.status != .active {
                terminalByLogicalKey[key] = (
                    temporal.status, temporal.retiredAt,
                    temporal.retiredReason, temporal.supersededBy)
            }
        }
        return poisoned
    }

    private static func validateOperationalSignature(_ incoming: Record,
                                                     against records: [Record]) throws {
        guard incoming.temporal != nil, let incomingSpace = incoming.embeddingSpace,
              let existing = records.first(where: { $0.temporal != nil }),
              let existingSpace = existing.embeddingSpace else { return }
        guard existingSpace == incomingSpace else {
            throw VectorStoreError.incompatibleEmbeddingSpace(
                expected: existingSpace, found: incomingSpace)
        }
        guard existing.vector.count == incoming.vector.count else {
            throw VectorStoreError.incompatibleEmbeddingSpace(
                expected: "\(existingSpace)/\(existing.vector.count)d",
                found: "\(incomingSpace)/\(incoming.vector.count)d")
        }
    }

    private static func validate(_ record: Record) throws {
        try validateIdentity(record.id, field: "id")
        if let logicalID = record.logicalID { try validateIdentity(logicalID, field: "logical_id") }
        try validateVector(record.vector, field: "vector")
        guard !record.text.isEmpty, record.text.utf8.count <= maximumTextBytes,
              !record.text.contains("\0") else {
            throw VectorStoreError.invalidRecord("text")
        }
        guard record.metadata.count <= maximumMetadataEntries else {
            throw VectorStoreError.invalidRecord("metadata count")
        }
        for (key, value) in record.metadata {
            guard !key.isEmpty, !key.contains("\0"), !value.contains("\0"),
                  key.utf8.count <= maximumMetadataFieldBytes,
                  value.utf8.count <= maximumMetadataFieldBytes else {
                throw VectorStoreError.invalidRecord("metadata field")
            }
        }
        if let temporal = record.temporal,
           temporal.evaluate(at: temporal.updatedAt).state == .invalid {
            throw VectorStoreError.invalidRecord("temporal envelope")
        }
        try validateOperationalPolicy(record)
        if let provenance = record.provenance {
            let locator = provenance.sourceLocator
            if provenance.kind != .manualObservation {
                guard let locator else {
                    throw VectorStoreError.invalidRecord("source locator")
                }
                try validateSourceLocator(locator)
            } else if let locator {
                try validateSourceLocator(locator)
            }
        }
    }

    private static func validateOperationalPolicy(_ record: Record) throws {
        guard let temporal = record.temporal else {
            guard record.logicalID == nil, record.provenance == nil,
                  record.embeddingSpace == nil else {
                throw VectorStoreError.invalidRecord("audit-only provenance")
            }
            return
        }
        guard let provenance = record.provenance, let embeddingSpace = record.embeddingSpace else {
            throw VectorStoreError.invalidRecord("operational provenance")
        }
        try validateEmbeddingSpace(embeddingSpace)
        guard !temporal.pinned, temporal.baseSalience <= 0.8,
              let digest = provenance.contentDigest,
              digest == contentDigest(for: record.text),
              record.logicalID == digest else {
            throw VectorStoreError.invalidRecord("operational policy")
        }
        switch provenance.kind {
        case .manualObservation:
            guard provenance.sourceLocator == nil,
                  temporal.status == .active,
                  temporal.decayRate == .medium,
                  temporal.lastConfirmedAt == nil,
                  temporal.reinforcementCount == 0,
                  temporal.accessCount == 0,
                  temporal.accessedAt == temporal.createdAt else {
                throw VectorStoreError.invalidRecord("manual observation policy")
            }
        case .locallyCheckedLesson, .promotedToolLesson:
            guard temporal.status == .active,
                  temporal.decayRate == .slow,
                  temporal.lastConfirmedAt != nil,
                  temporal.reinforcementCount > 0 else {
                throw VectorStoreError.invalidRecord("checked lesson policy")
            }
        case .lifecycleRetirement:
            guard temporal.status == .retired else {
                throw VectorStoreError.invalidRecord("retirement policy")
            }
        case .lifecycleSupersession:
            guard temporal.status == .superseded else {
                throw VectorStoreError.invalidRecord("supersession policy")
            }
        }
    }

    private static func contentDigest(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateSourceLocator(_ locator: String) throws {
        guard !locator.isEmpty, !locator.contains("\0"),
              locator.utf8.count <= maximumIdentityBytes else {
            throw VectorStoreError.invalidRecord("source locator")
        }
    }

    private static func validateEmbeddingSpace(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= maximumIdentityBytes,
              !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
            throw VectorStoreError.invalidRecord("embedding space")
        }
    }

    private static func validateIdentity(_ value: String, field: String) throws {
        guard !value.isEmpty, value.utf8.count <= maximumIdentityBytes,
              !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
            throw VectorStoreError.invalidRecord(field)
        }
    }

    private static func validateVector(_ vector: [Float], field: String) throws {
        guard !vector.isEmpty, vector.count <= maximumVectorDimensions,
              vector.allSatisfy(\.isFinite), stableNorm(vector) != nil else {
            throw VectorStoreError.invalidRecord(field)
        }
    }
}

/// Cross-platform indirection keeps the write call unambiguous when Foundation is imported.
private enum DarwinOrGlibc {
    static func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(descriptor, buffer, count)
        #else
        return Glibc.write(descriptor, buffer, count)
        #endif
    }
}
