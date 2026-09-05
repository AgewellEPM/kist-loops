import Foundation

/// Retrieval-source bindings for the `RETRIEVE` driver, loaded from
/// `<projectRoot>/.kist/sml/retrieval.json`. Each admitted source names a vector store path, the
/// embedding space queries must match, and a clamped top-K ceiling.
public struct SMLRetrievalSourceBindings: Sendable {
    public struct Binding: Sendable {
        public let storePath: String
        public let embeddingSpace: String
        public let topK: Int

        public init(storePath: String, embeddingSpace: String, topK: Int = 5) {
            self.storePath = storePath
            self.embeddingSpace = embeddingSpace
            self.topK = min(max(topK, 1), 50)
        }
    }

    public static let schemaVersion = 1
    public static let relativePath = ".kist/sml/retrieval.json"

    public let sources: [String: Binding]

    public init(sources: [String: Binding]) {
        self.sources = sources
    }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case missing(path: String)
        case unreadable(path: String, reason: String)
        case malformed(path: String, reason: String)
        case unsupportedSchemaVersion(Int)

        public var description: String {
            switch self {
            case .missing(let path):
                return "SML retrieval bindings are missing: \(path) — RETRIEVE steps need "
                    + "source→store bindings (\"sources\": {\"<source>\": {\"store_path\": ..., "
                    + "\"embedding_space\": ...}})"
            case .unreadable(let path, let reason):
                return "SML retrieval bindings are unsafe or unreadable: \(path) (\(reason))"
            case .malformed(let path, let reason):
                return "SML retrieval bindings are malformed: \(path) (\(reason))"
            case .unsupportedSchemaVersion(let version):
                return "SML retrieval bindings schema_version \(version) is unsupported "
                    + "(expected \(schemaVersion))"
            }
        }
    }

    public static func load(projectRoot: String) throws -> SMLRetrievalSourceBindings {
        let url = URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
        let data: Data
        do {
            data = try SMLHostConfigurationFile.read(
                projectRoot: projectRoot,
                relativePath: relativePath
            )
        } catch SMLHostConfigurationFile.ReadError.missing {
            throw LoadError.missing(path: url.path)
        } catch {
            throw LoadError.unreadable(path: url.path, reason: String(describing: error))
        }

        do {
            let root = try SMLHostConfigurationFile.decodeRoot(from: data)
            try SMLHostConfigurationFile.requireOnlyKeys(
                root,
                allowed: ["schema_version", "sources"],
                path: "retrieval"
            )
            let version = try SMLHostConfigurationFile.requiredInteger(
                root["schema_version"], path: "retrieval.schema_version")
            guard version == schemaVersion else {
                throw LoadError.unsupportedSchemaVersion(version)
            }
            let rawSources = try SMLHostConfigurationFile.requiredObject(
                root["sources"], path: "retrieval.sources")
            guard rawSources.count <= SMLHostConfigurationFile.maximumBindings else {
                throw SMLHostConfigurationFile.SchemaError(
                    reason: "retrieval.sources exceeds "
                        + "\(SMLHostConfigurationFile.maximumBindings) entries")
            }

            var sources: [String: Binding] = [:]
            for source in rawSources.keys.sorted() {
                _ = try SMLHostConfigurationFile.reference(
                    source, path: "retrieval.sources key")
                let entryPath = "retrieval.sources.\(source)"
                let entry = try SMLHostConfigurationFile.requiredObject(
                    rawSources[source], path: entryPath)
                try SMLHostConfigurationFile.requireOnlyKeys(
                    entry,
                    allowed: ["store_path", "embedding_space", "top_k"],
                    path: entryPath
                )
                let storePath = try SMLHostConfigurationFile.boundedText(
                    try SMLHostConfigurationFile.requiredString(
                        entry["store_path"], path: "\(entryPath).store_path"),
                    path: "\(entryPath).store_path",
                    maximumBytes: SMLHostConfigurationFile.maximumReferenceBytes
                )
                let embeddingSpace = try SMLHostConfigurationFile.boundedText(
                    try SMLHostConfigurationFile.requiredString(
                        entry["embedding_space"], path: "\(entryPath).embedding_space"),
                    path: "\(entryPath).embedding_space",
                    maximumBytes: SMLHostConfigurationFile.maximumShortStringBytes
                )
                let topK = try SMLHostConfigurationFile.optionalInteger(
                    entry["top_k"], path: "\(entryPath).top_k") ?? 5
                guard (1...50).contains(topK) else {
                    throw SMLHostConfigurationFile.SchemaError(
                        reason: "\(entryPath).top_k must be within 1...50")
                }
                sources[source] = Binding(
                    storePath: storePath,
                    embeddingSpace: embeddingSpace,
                    topK: topK
                )
            }
            return SMLRetrievalSourceBindings(sources: sources)
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.malformed(path: url.path, reason: String(describing: error))
        }
    }
}

/// Production `RETRIEVE` driver: embeds the query with the host's embedder and searches the bound
/// `VectorStore` with real-clock temporal salience. Results land in the declared output field as
/// a JSON array of {text, score} objects. An unbound source or embedding failure is a FAILED
/// outcome; zero hits is a PASSED outcome with an empty array — "nothing relevant" is a valid,
/// honest retrieval result.
public struct SMLRetrievalCapabilityDriver: SMLInstructionDriver {
    public let id = "kist-retrieval-driver"

    private let bindings: SMLRetrievalSourceBindings
    private let embed: @Sendable (String) async throws -> [Float]
    private let clock: @Sendable () -> Double

    public init(
        bindings: SMLRetrievalSourceBindings,
        embed: @escaping @Sendable (String) async throws -> [Float],
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.bindings = bindings
        self.embed = embed
        self.clock = clock
    }

    public func supports(_ request: SMLCapabilityRequest) -> Bool {
        request.operation == .retrieve && bindings.sources[request.reference] != nil
    }

    public func execute(
        _ invocation: SMLCapabilityInvocation
    ) async throws -> SMLCapabilityOutcome {
        let request = invocation.request
        guard let binding = bindings.sources[request.reference] else {
            throw SMLCapabilityDriverConfigurationError.unknownRetrievalSource(request.reference)
        }
        let outputField = try SMLCapabilityDriverSupport.outputField(of: request)
        let query = Self.query(for: request)

        var hits: [VectorHit] = []
        var failure: String?
        do {
            let vector = try await embed(query)
            let store = FileBackedVectorStore(path: binding.storePath)
            hits = try store.query(
                vector,
                embeddingSpace: binding.embeddingSpace,
                topK: binding.topK,
                at: Date(timeIntervalSince1970: clock())
            )
        } catch {
            failure = String(describing: error)
        }

        let succeeded = failure == nil
        let hitObjects: [SMLValue] = hits.map {
            .object(["text": .string($0.text), "score": .number(Decimal(Double($0.score)))])
        }
        var statePatch: SMLObject = [:]
        if succeeded, let outputField {
            statePatch[outputField] = .array(hitObjects)
        }
        return SMLCapabilityDriverSupport.outcome(
            for: invocation,
            driverID: id,
            status: succeeded ? .passed : .failed,
            statePatch: statePatch,
            evidencePayload: [
                "source": .string(request.reference),
                "embedding_space": .string(binding.embeddingSpace),
                "query": .string(query),
                "hit_count": .number(Decimal(hits.count)),
                "hits": .array(hitObjects),
                "error": failure.map { .string($0) } ?? .null,
            ],
            receiptID: "retrieve.\(request.reference).\(succeeded ? "passed" : "failed")",
            observedAtEpoch: clock()
        )
    }

    /// The query text: the instruction's `query` argument, else the string value of the state
    /// field named by `query_field`, else the source name. Deterministic, host-visible.
    static func query(for request: SMLCapabilityRequest) -> String {
        if case .string(let explicit)? = request.arguments["query"], !explicit.isEmpty {
            return explicit
        }
        if case .string(let field)? = request.arguments["query_field"],
           case .string(let value)? = request.state[field], !value.isEmpty {
            return value
        }
        return request.reference
    }
}
