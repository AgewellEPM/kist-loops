import Foundation

/// One self-reported progress event a fleet worker appends to `.fleet-progress.jsonl` in its worktree.
/// ADVISORY only — never proof (the supervisor verifies real completion via forge-proof signoff). This
/// is the live-visibility channel the cockpit reads; it can NEVER mint trust.
public struct FleetProgressEvent: Sendable, Codable, Equatable {
    public let step: Int
    public let action: String
    public let file: String?
    public let at: Double          // caller-supplied epoch (kept out of pure code so it stays testable)
    public let note: String?
    public init(step: Int, action: String, file: String? = nil, at: Double, note: String? = nil) {
        self.step = step; self.action = action; self.file = file; self.at = at; self.note = note
    }
}

/// The worker↔supervisor file contract inside a worktree: an append-only progress log + a done marker.
/// The supervisor POLLS these, so the same supervision logic works for an in-process worker today OR a
/// subprocess/remote worker later. Foundation-only, fail-soft (a lost progress line never breaks a run).
public enum FleetSentinel {
    public static let progressFileName = ".fleet-progress.jsonl"
    public static let doneFileName = ".fleet-done"

    private static func path(_ worktree: String, _ name: String) -> String { worktree + "/" + name }

    /// Append a progress event to the worktree's log (creating it on first write). Fail-soft.
    public static func appendProgress(_ event: FleetProgressEvent, inWorktree worktree: String) {
        guard let data = try? JSONEncoder().encode(event),
              let line = String(data: data, encoding: .utf8) else { return }
        let file = path(worktree, progressFileName)
        let entry = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: file) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(entry)
        } else {
            try? entry.write(to: URL(fileURLWithPath: file))
        }
    }

    /// All progress events (newest last), or [] if none. Fail-soft: malformed lines are skipped.
    public static func readProgress(inWorktree worktree: String) -> [FleetProgressEvent] {
        guard let data = FileManager.default.contents(atPath: path(worktree, progressFileName)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(FleetProgressEvent.self, from: d)
        }
    }

    /// Write the done marker (with a short summary) — the worker's surrender signal.
    public static func markDone(inWorktree worktree: String, summary: String) {
        try? Data(summary.utf8).write(to: URL(fileURLWithPath: path(worktree, doneFileName)))
    }

    /// True iff the worker has surrendered (the marker exists). Advisory — the supervisor still
    /// VERIFIES the work before trusting it; a done marker is a claim, not proof.
    public static func isDone(inWorktree worktree: String) -> Bool {
        FileManager.default.fileExists(atPath: path(worktree, doneFileName))
    }

    /// The summary the worker wrote alongside its done marker (nil if not done).
    public static func doneSummary(inWorktree worktree: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path(worktree, doneFileName)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A rejected surrender must not be inspected again as if it were fresh work. Move the marker aside
    /// so the worker must produce a new `.fleet-done` after repairing the branch.
    @discardableResult
    public static func archiveRejectedDone(inWorktree worktree: String, atEpoch: Double) -> Bool {
        let source = path(worktree, doneFileName)
        guard FileManager.default.fileExists(atPath: source) else { return true }
        let destination = path(worktree, ".fleet-done.rejected-\(Int(atEpoch))-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.moveItem(atPath: source, toPath: destination)
            return true
        } catch {
            do {
                try FileManager.default.removeItem(atPath: source)
                return true
            } catch {
                return false
            }
        }
    }
}

/// How the fleet supervisor LAUNCHES a worker into a worktree. Injectable, so the spawn mechanism is
/// pluggable: **in-process** (Mythos's own cross-vendor loop — the upgrade over Claude-only `cu`
/// subprocesses), or a future subprocess/remote. The supervisor (Stage 2) calls `spawn` and polls the
/// sentinels — it never assumes HOW the worker runs. A spawner should mark `.fleet-done` only after the
/// worker has actually exited.
public protocol AgentSpawner: Sendable {
    /// Launch a worker for `task` inside `worktree`. Returns whether the LAUNCH succeeded — NOT whether
    /// the work succeeded (that's the supervisor's signoff verdict). On completion the spawner writes
    /// `.fleet-done`.
    func spawn(task: String, worktree: GitWorktree) async -> Bool
}

/// Optional upgrade for spawners that can honor the Captain's per-task model assignment.
/// Older spawners still conform to `AgentSpawner`; the orchestrator falls back to the
/// legacy two-argument spawn when this protocol is absent.
public protocol AssignedAgentSpawner: AgentSpawner {
    func spawn(task: String, worktree: GitWorktree, assignment: ModelAssignmentDecision) async -> Bool
}

/// The default: launches an injected agent `work` closure (handed the worktree so it operates inside it),
/// returns once the worker has started, then writes the done sentinel when that background work completes.
/// This keeps `spawn` as a launch-status API: the orchestrator can start the whole fleet quickly, and the
/// supervisor polls the sentinel contract for completion. Stage 2 injects a Mythos role-bound
/// `PlanExecuteLoop` (any vendor) as `work` — that's the heterogeneous fleet.
public struct InProcessAgentSpawner: AgentSpawner {
    private let work: @Sendable (_ task: String, _ worktree: GitWorktree) async -> String
    public init(work: @escaping @Sendable (_ task: String, _ worktree: GitWorktree) async -> String) {
        self.work = work
    }
    public func spawn(task: String, worktree: GitWorktree) async -> Bool {
        let work = self.work
        let parent = AgentExecutionScope.current
        Task.detached(priority: .userInitiated) {
            let summary = await AgentExecutionScope.$current.withValue(parent) { await work(task, worktree) }
            FleetSentinel.markDone(inWorktree: worktree.path, summary: summary)
        }
        return true
    }
}
