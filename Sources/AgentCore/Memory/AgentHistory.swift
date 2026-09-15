import Foundation

/// Host-created lineage. A checkpoint restores these identifiers, never tool/model permissions.
public struct AgentRunIdentity: Codable, Sendable, Equatable {
    public let runID: String
    public let parentRunID: String?
    public let rootRunID: String
    public let sessionID: String
    public let role: String
    public let project: BuilderWorkspaceRootIdentity
    public let executionRoot: String
}

public enum AgentExecutionScope {
    @TaskLocal public static var current: AgentRunIdentity?
}

/// An operational event, not a verified lesson or an accepted completion receipt.
public struct AgentHistoryEvent: Codable, Sendable, Equatable {
    public let id: String
    public let at: Date
    public let agent: AgentRunIdentity
    public let kind: String
    public let detail: String
    public let originalBytes: Int
    public let detailSHA256: String
    public let clipped: Bool

    public var relativePath: String { AgentHistoryStore.directory + "/" + id + ".json" }
    public var locator: String { agent.project.canonicalPath + "/" + relativePath }
}

/// Immutable, independently published records avoid a shared JSONL rewrite or tail truncation.
/// Publication uses the existing fsync + no-replace confined primitive. Concurrent writers cannot
/// overwrite each other. Ordering is event time with a stable UUID tie-break, not fabricated causality.
public struct AgentHistoryStore: Sendable {
    public static let directory = ".kist/runs/agent-history/v1"
    public let project: BuilderWorkspaceRootIdentity

    public init(project: BuilderWorkspaceRootIdentity) { self.project = project }

    public struct Page: Sendable {
        public let events: [AgentHistoryEvent]
        public let nextCursor: String?
        public let scanned: Int
        public let rejected: Int
        public let total: Int
    }

    private func confined() throws -> ConfinedRoot {
        guard try BuilderWorkspaceRootIdentity.capture(rootPath: project.canonicalPath) == project else {
            throw ToolError.configuration("agent history project identity changed")
        }
        return try ConfinedRoot(root: project.canonicalPath)
    }

    @discardableResult
    public func append(agent: AgentRunIdentity, kind: String, detail: String,
                       at: Date = Date()) throws -> AgentHistoryEvent {
        guard agent.project == project, at.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(at.timeIntervalSince1970) else {
            throw ToolError.configuration("invalid agent history identity or event time")
        }
        let safe = SecretMasker.mask(detail)
        let event = AgentHistoryEvent(
            id: String(format: "%020.0f", floor(at.timeIntervalSince1970 * 1_000_000))
                + "-" + UUID().uuidString.lowercased(),
            at: at, agent: agent, kind: String(kind.prefix(80)),
            detail: String(safe.prefix(32_000)), originalBytes: detail.utf8.count,
            detailSHA256: BuilderEvidenceDigest.sha256(detail), clipped: safe.count > 32_000)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)
        guard data.count <= 256_000 else { throw ToolError.execution("agent event exceeds archive size limit") }
        _ = try confined().createDataIfMissing(event.relativePath, data, createParents: true)
        return event
    }

    /// Cursor addresses physical records, so rejected data never hides a later page. Reading does
    /// not create files, touch clocks, or delete old events. Raw history deliberately does not decay.
    public func page(before cursor: String? = nil, limit: Int = 100,
                     runID: String? = nil, rootRunID: String? = nil) throws -> Page {
        let root = try confined()
        let state: (exists: Bool, isDir: Bool)
        do { state = try root.fileType(Self.directory) }
        catch ToolError.notFound {
            return Page(events: [], nextCursor: nil, scanned: 0, rejected: 0, total: 0)
        }
        guard state.exists else { return Page(events: [], nextCursor: nil, scanned: 0, rejected: 0, total: 0) }
        guard state.isDir else { throw ToolError.execution("agent history is not a directory") }
        let names = try root.entries(Self.directory).filter {
            !$0.isDir && $0.name.hasSuffix(".json")
        }.map { String($0.name.dropLast(5)) }.sorted(by: >)
        let selected = names.filter { cursor == nil || $0 < cursor! }.prefix(min(5_000, max(1, limit)))
        var events: [AgentHistoryEvent] = [], rejected = 0
        for id in selected {
            do {
                let event = try read(id: id, root: root).event
                if let runID, event.agent.runID != runID { continue }
                if let rootRunID, event.agent.rootRunID != rootRunID { continue }
                events.append(event)
            } catch { rejected += 1 }
        }
        let next = selected.last.flatMap { last in names.contains(where: { $0 < last }) ? last : nil }
        return Page(events: events.reversed(), nextCursor: next,
                    scanned: selected.count, rejected: rejected, total: names.count)
    }

    /// Shared validation for chronological reads and revalidation of advisory index hits.
    func read(id: String, root: ConfinedRoot) throws -> (event: AgentHistoryEvent, data: Data) {
        guard id.count == 57, id.prefix(20).allSatisfy(\.isNumber),
              id.dropFirst(20).first == "-", UUID(uuidString: String(id.suffix(36))) != nil else {
            throw ToolError.execution("invalid agent history record name")
        }
        let data = try root.readStableOwnerOnlyData(Self.directory + "/" + id + ".json", maxBytes: 256_000)
        let event = try JSONDecoder().decode(AgentHistoryEvent.self, from: data)
        guard event.id == id, event.agent.project == project,
              event.at.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(event.at.timeIntervalSince1970),
              String(format: "%020.0f", floor(event.at.timeIntervalSince1970 * 1_000_000)) == String(id.prefix(20)),
              event.kind.count <= 80, event.detail.count <= 32_000 else {
            throw ToolError.execution("agent history record identity or timestamp mismatch")
        }
        return (event, data)
    }
}

/// Records only public operational events. Hidden reasoning and token fragments are excluded;
/// tool outputs, usage, errors, compaction, approval waits and terminal states retain provenance.
struct AgentHistoryEventSink: RuntimeEventSink {
    let downstream: RuntimeEventSink
    let access: AgentMemoryAccess
    let health: AgentHistoryHealth

    func emit(_ event: RuntimeEvent) {
        downstream.emit(event)
        guard let agent = AgentExecutionScope.current else { return }
        let entry: (String, String)?
        switch event {
        case .tokenDelta, .reasoningDelta: entry = nil
        case .stateChanged(let state): entry = (state == .cancelled ? "cancelled" : "state", state.rawValue)
        case .intentResolved(let intent, let confidence): entry = ("intent", "\(intent); confidence=\(confidence)")
        case .planReady(let summary, let count): entry = ("plan", "steps=\(count)\n\(summary)")
        case .usage(let prompt, let completion, let estimated):
            entry = ("usage", "prompt=\(prompt); completion=\(completion); estimated=\(estimated)")
        case .stepWave(let wave, let steps): entry = ("wave", "\(wave): \(steps.joined(separator: ", "))")
        case .actionStarted(let index, let tool, let description):
            health.recordTool(runID: agent.runID, index: index, name: tool)
            entry = ("tool_started", "index=\(index); tool=\(tool ?? "unknown")\n\(description)")
        case .actionFinished(let index, let success, let output, let error):
            let read = health.isRead(runID: agent.runID, index: index)
            entry = (read ? "read_observation" : "tool_finished", "index=\(index); success=\(success)\n\(output)\n\(error ?? "")")
        case .replanStarted(let reason): entry = ("replan", reason)
        case .contextCompacted(let omitted): entry = ("compacted", "messages=\(omitted)")
        case .checkpointSaved(let id, let iteration): entry = ("checkpoint", "\(id); iteration=\(iteration)")
        case .checkpointFailed(let reason): entry = ("checkpoint_failed", reason)
        case .awaitingApproval(let summary): entry = ("approval_wait", summary)
        case .awaitingInput(let question): entry = ("input_wait", question)
        case .completed(let summary): entry = ("completed_advisory", summary)
        case .failed(let reason): entry = ("failed", reason)
        case .cancelled: entry = ("cancelled", "Operator or runtime cancellation")
        }
        guard let entry else { return }
        do { try access.history.append(agent: agent, kind: entry.0, detail: entry.1) }
        catch {
            if health.recordFailure(String(describing: error)) {
                downstream.emit(.checkpointFailed("agent history: \(error)"))
            }
        }
    }
}

final class AgentHistoryHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?
    private var readActions = Set<String>()
    func recordTool(runID: String, index: Int, name: String?) {
        lock.lock(); defer { lock.unlock() }
        let key = "\(runID):\(index)"
        if let name, ReversibilityClassifier.readOnlyTools.contains(name) || name == "recall" {
            readActions.insert(key)
        } else { readActions.remove(key) }
    }
    func isRead(runID: String, index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return readActions.contains("\(runID):\(index)")
    }
    func recordFailure(_ reason: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return false }
        failure = reason; return true
    }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
}
