import Foundation
import AgentCore

/// LIST observations are local, unsigned context. This bridge has no scheduler, model, capture,
/// task-execution or promotion capability. It borrows the session's existing MCP lifetime.
actor KistListLearning {
    static let observationLimit = 24
    static let lookback: TimeInterval = 7 * 86_400
    static let minimumRefreshInterval: TimeInterval = 60
    typealias Fetch = @Sendable (_ since: String, _ limit: Int) async -> ToolResult

    private let projectRoot: String
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let report: @Sendable (String) -> Void
    private var lastAttempt: Date?
    private var refreshing = false
    private var lastRefreshSucceeded = false

    init(projectRoot: String, fetch: @escaping Fetch,
         now: @escaping @Sendable () -> Date = { Date() },
         report: @escaping @Sendable (String) -> Void = { _ in }) {
        self.projectRoot = ToolContext.canonicalize(projectRoot) ?? projectRoot
        self.fetch = fetch
        self.now = now
        self.report = report
    }

    /// Called only during an operator-started session. An unavailable server never blocks normal work
    /// beyond its configured MCP timeout. A failed refresh retains honestly dated historical context.
    @discardableResult
    func refresh() async -> Bool {
        let instant = now()
        guard !Task.isCancelled, !refreshing,
              lastAttempt.map({ instant.timeIntervalSince($0) >= Self.minimumRefreshInterval }) ?? true
        else { return lastRefreshSucceeded }
        refreshing = true
        lastRefreshSucceeded = false
        lastAttempt = instant
        defer { refreshing = false }
        let result = await fetch(Self.iso(instant.addingTimeInterval(-Self.lookback)), Self.observationLimit)
        guard !Task.isCancelled else { return false }
        guard result.success,
              let observations = Self.decode(result.output, projectRoot: projectRoot, at: instant) else {
            report("LIST · recent observations unavailable; continuing with dated advisory memory")
            return false
        }
        let store = OrganizationalLearningStore(projectRoot: projectRoot, now: now)
        let imported = store.recordListObservations(observations, at: instant)
        guard imported.succeeded else {
            report("LIST · advisory memory persistence failed; observations not confirmed as imported")
            return false
        }
        lastRefreshSucceeded = true
        if imported.imported > 0 {
            report("LIST · imported \(imported.imported) dated observation(s) · advisory")
        }
        return true
    }

    func context() async -> String {
        _ = await refresh()
        return OrganizationalLearningStore(projectRoot: projectRoot, now: now).listLearningContext()
    }

    struct Observation: Codable, Equatable, Sendable {
        let id: String
        let kind: String
        let observed_at: String
        let source_uri: String
        let source_path: String
        let summary: String
        let content_sha256: String
        let actor_attribution: String
        let authority: String
        let executable: Bool
    }

    private struct Envelope: Decodable {
        let schema_version: Int
        let kind: String
        let project_root: String
        let authority: String
        let executable: Bool
        let observations: [Observation]
        let status: Status
        struct Status: Decodable { let available: Bool; let returned: Int }
    }

    static func decode(_ text: String, projectRoot: String, at instant: Date) -> [Observation]? {
        guard text.utf8.count <= 64 * 1_024,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)),
              envelope.schema_version == 1, envelope.kind == "list-kist-observations",
              envelope.project_root == projectRoot,
              envelope.authority == "advisory", !envelope.executable,
              envelope.status.available,
              envelope.status.returned == envelope.observations.count,
              envelope.observations.count <= observationLimit else { return nil }
        var seen = Set<String>()
        // Reject a contaminated page as a whole. Imported timestamps are source event timestamps;
        // neither this fetch nor later retrieval refreshes the evidence/decay anchor.
        for observation in envelope.observations {
            guard valid(observation, projectRoot: projectRoot, at: instant),
                  seen.insert(observation.id).inserted else { return nil }
        }
        return envelope.observations
    }

    static func valid(_ observation: Observation, projectRoot: String, at instant: Date) -> Bool {
        let identityPrefix: String
        let uriPrefix: String
        switch observation.kind {
        case "activity": identityPrefix = "list:activity:"; uriPrefix = "list://activity/"
        case "file_memory": identityPrefix = "list:entry:"; uriPrefix = "list://entries/"
        default: return false
        }
        let identifier = String(observation.id.dropFirst(identityPrefix.count))
        guard observation.id.hasPrefix(identityPrefix), !identifier.isEmpty, identifier.count <= 120,
              identifier.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_" )).contains($0) }),
              observation.source_uri == uriPrefix + identifier,
              observation.source_path.utf8.count <= 4_096,
              (observation.source_path == projectRoot || observation.source_path.hasPrefix(projectRoot + "/")),
              URL(fileURLWithPath: observation.source_path).standardizedFileURL.path == observation.source_path,
              observation.source_path == URL(fileURLWithPath: observation.source_path).resolvingSymlinksInPath().path,
              !observation.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              observation.summary.count <= 1_200,
              observation.summary == MCPOutputSanitizer.sanitize(observation.summary),
              observation.content_sha256 == BuilderEvidenceDigest.sha256(observation.summary),
              observation.actor_attribution == "unknown",
              observation.authority == "advisory", !observation.executable,
              let observed = date(observation.observed_at),
              observed >= instant.addingTimeInterval(-lookback),
              observed <= instant.addingTimeInterval(300) else { return false }
        return true
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(_ string: String) -> Date? {
        guard string.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func json<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
    }
}

extension KistRunner {
    static func makeListLearning(root: String, opts: KistOptions,
                                 tools: ToolRegistry, context: ToolContext) -> KistListLearning? {
        guard !opts.noMemory, !opts.evolve, !opts.evolveSession, !opts.bench, !opts.eval,
              let remote = tools.all().compactMap({ $0 as? RemoteMCPTool }).first(where: {
                  $0.explicitComputerUseRequirement != true
                      && $0.matches(server: "list", tool: "recent_observations")
              }) else { return nil }
        return KistListLearning(projectRoot: root, fetch: { since, limit in
            do {
                return try await remote.execute(arguments: ["project_root": root, "since": since,
                                                            "limit": limit], context: context)
            } catch { return .failure("LIST observations unavailable") }
        }, report: { note($0) })
    }

    static func listRecall(_ list: KistListLearning?,
                           alongside existing: (@Sendable (String) async -> String)? = nil)
    -> (@Sendable (String) async -> String)? {
        guard let list else { return existing }
        return { query in
            let listBlock = await list.context()
            let existingBlock = await existing?(query) ?? ""
            return [existingBlock, listBlock].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }
}
