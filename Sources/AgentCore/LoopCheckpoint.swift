import Foundation

/// Durable state of a headless run, so a crashed/interrupted/paused loop can resume EXACTLY
/// where it left off. Because the loop is message-based (the text protocol), its entire state
/// is the conversation + cursor — trivially `Codable` (no DTO mirroring needed, unlike the GUI
/// monolith's plan-object checkpoint). Persisted after every iteration.
/// A tool action recorded as "about to run", persisted BEFORE its side effect so that if the
/// process dies mid-tool, resume can RECONCILE (verify state, don't blindly replay) instead of
/// risking a double write/command.
public struct PendingAction: Codable, Sendable {
    public let tool: String
    public let argsSummary: String
    public let iteration: Int
    /// Pre-execution effect classification. Optional so checkpoints written before this field existed
    /// still decode; reconciliation falls back to the conservative legacy classifier when it is absent.
    public let predictedEffects: ToolEffectObservation?
    public init(tool: String, argsSummary: String, iteration: Int,
                predictedEffects: ToolEffectObservation? = nil) {
        self.tool = tool; self.argsSummary = argsSummary; self.iteration = iteration
        self.predictedEffects = predictedEffects
    }
}

public struct LoopCheckpoint: Codable, Sendable {
    /// `abandoned` (R1, 2026-07-28): the user double-ESC'd the turn. Excluded from resumable()
    /// so it never clutters --list, but the file is KEPT — an explicit `--resume <id>` can still
    /// revive it (panic ESC-hammering must never destroy work irreversibly).
    public enum Status: String, Codable, Sendable { case running, completed, failed, paused, abandoned }

    public let id: String
    public var goal: String
    /// The raw operator request, separate from any compiled Captain prompt in `goal`.
    /// Optional for backward compatibility with checkpoints written before the turn contract existed.
    public var rawRequest: String?
    /// One semantic decision for the whole turn. Downstream systems consume this value rather than
    /// independently guessing whether the turn is chat, research, planning, or a state-changing build.
    public var intent: TaskBrief.Intent?
    public var expectedOutcome: TaskBrief.ExpectedOutcome?
    public var providerId: String
    public var model: String?
    public var projectRoot: String
    public var messages: [ChatMessage]   // full conversation = the resumable state
    public var iteration: Int            // last COMPLETED iteration (resume continues at +1)
    public var status: Status
    public var summary: String?
    public var pendingAction: PendingAction?   // set before a tool runs; nil once it completed
    /// The complete, ordered tool-evidence ledger for this run. Optional only for checkpoints written
    /// before trajectory persistence shipped; new checkpoints always initialize it to an empty ledger.
    /// Completion verification reconstructs its recorder from this field on resume, so a pause cannot
    /// erase an unverified mutation; execution proof is then deliberately invalidated at the unbound
    /// workspace resume boundary until a fresh build/test succeeds.
    public var trajectory: [ActionRecord]?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, goal: String, rawRequest: String? = nil,
                intent: TaskBrief.Intent? = nil,
                expectedOutcome: TaskBrief.ExpectedOutcome? = nil,
                providerId: String, model: String?,
                projectRoot: String, messages: [ChatMessage], iteration: Int = 0,
                status: Status = .running, summary: String? = nil, pendingAction: PendingAction? = nil,
                trajectory: [ActionRecord]? = [],
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.goal = goal; self.rawRequest = rawRequest
        self.intent = intent; self.expectedOutcome = expectedOutcome
        self.providerId = providerId; self.model = model
        self.projectRoot = projectRoot; self.messages = messages; self.iteration = iteration
        self.status = status; self.summary = summary; self.pendingAction = pendingAction
        self.trajectory = trajectory
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Short, human-friendly one-liner for `kist --list`.
    public var title: String {
        let g = goal.split(separator: "\n").first.map(String.init) ?? goal
        return String(g.prefix(60))
    }
}

/// JSON-file-per-run checkpoint store (cross-platform). Fail-closed: callers treat a thrown
/// save as lost durability (the loop surfaces `.checkpointFailed` and can pause).
public struct LoopCheckpointStore: Sendable {
    public let directory: String

    public init(directory: String = LoopCheckpointStore.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory() -> String {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        return base + "/Mythos/checkpoints"
        #else
        let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"] ?? (NSHomeDirectory() + "/.local/state")
        return xdg + "/kist/checkpoints"
        #endif
    }

    /// Reject any id that isn't a safe slug — no path separators, no `..` — so a user-supplied
    /// `--resume <id>` can't read or write files outside the checkpoint directory. Fresh ids are
    /// UUIDs (hex + dashes), which pass.
    private func safePath(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 128,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { throw ToolError.configuration("invalid checkpoint id: \(id)") }
        return directory + "/" + id + ".json"
    }

    public func save(_ cp: LoopCheckpoint) throws {
        let p = try safePath(cp.id)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(cp)
        // Atomic write so a crash mid-write can't corrupt a checkpoint.
        try data.write(to: URL(fileURLWithPath: p), options: .atomic)
    }

    public func load(id: String) throws -> LoopCheckpoint {
        let data = try Data(contentsOf: URL(fileURLWithPath: try safePath(id)))
        return try JSONDecoder().decode(LoopCheckpoint.self, from: data)
    }

    public func delete(id: String) {
        guard let p = try? safePath(id) else { return }
        try? FileManager.default.removeItem(atPath: p)
    }

    /// Mark a checkpoint abandoned (double-ESC): hidden from resumable(), file kept so an explicit
    /// `--resume <id>` can still revive it. A misread double-ESC must never be irreversible.
    public func abandon(id: String) {
        guard var cp = try? load(id: id) else { return }
        cp.status = .abandoned
        try? save(cp)
    }

    /// All checkpoints (any status), newest first.
    public func all() -> [LoopCheckpoint] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let dec = JSONDecoder()
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { try? dec.decode(LoopCheckpoint.self, from: Data(contentsOf: URL(fileURLWithPath: directory + "/" + $0))) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Runs that can be resumed (not completed) — newest first.
    public func resumable() -> [LoopCheckpoint] {
        all().filter { $0.status == .running || $0.status == .paused || $0.status == .failed }
    }
}
