import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Persists a project's plan to `<root>/.kist/plan.json` — the native kist runbook. Load → mutate →
/// save on every op (simple + crash-safe). Shared by the `/tasks` REPL commands (human) and the
/// `tasks` agent tool (agent), so both see one task list. Pure aside from the file I/O; injectable
/// path makes it unit-testable.
public struct PlanStore: Sendable {
    private let path: String

    public init(projectRoot: String) {
        self.path = (projectRoot as NSString).appendingPathComponent(".kist/plan.json")
    }
    public init(path: String) { self.path = path }

    public func load() -> Plan {
        guard let data = FileManager.default.contents(atPath: path),
              let plan = try? JSONDecoder().decode(Plan.self, from: data) else { return Plan() }
        return plan
    }

    /// When the plan file was last written, or nil if it doesn't exist yet. Used to decide whether a
    /// persisted plan belongs to the CURRENT session (written at/after session start) or is a stale
    /// leftover from a prior session that must not greet a cold start as `next:`.
    public func modifiedAt() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    /// Run a read-modify-write under an exclusive advisory file lock so two concurrent writers (the
    /// REPL and the agent, or two processes) can't allocate the same id and clobber each other.
    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        #if canImport(Darwin) || canImport(Glibc)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return body()
        #else
        return body()
        #endif
    }

    @discardableResult
    public func add(title: String, detail: String = "", owner: String? = nil, link: String? = nil,
                    kind: PlanTask.Kind? = nil, acceptance: String = "",
                    verification: String = "", evidence: [String] = []) -> PlanTask {
        withLock {
            var plan = load()
            let task = PlanTask(id: plan.nextId, title: title, detail: detail,
                                kind: kind, acceptance: acceptance, verification: verification,
                                evidence: evidence, owner: owner, link: link)
            plan.tasks.append(task)
            plan.nextId += 1
            save(plan)
            return task
        }
    }

    /// Update a task's contract. Returns the updated task, or nil if id unknown.
    @discardableResult
    public func update(id: Int, status: PlanTask.Status? = nil, detail: String? = nil,
                       kind: PlanTask.Kind? = nil, acceptance: String? = nil,
                       verification: String? = nil, evidence: [String]? = nil,
                       appendEvidence: [String] = []) -> PlanTask? {
        withLock {
            var plan = load()
            guard let idx = plan.tasks.firstIndex(where: { $0.id == id }) else { return nil }
            if let status {
                plan.tasks[idx].status = status
                // Passing `.inProgress` is an explicit start/resume action, including resuming a task
                // that a prior session left in that state. Refresh ownership every time.
                if status == .inProgress { plan.tasks[idx].startedAt = Date().timeIntervalSince1970 }
            }
            if let detail { plan.tasks[idx].detail = detail }
            if let kind { plan.tasks[idx].kind = kind }
            if let acceptance { plan.tasks[idx].acceptance = acceptance }
            if let verification { plan.tasks[idx].verification = verification }
            if let evidence { plan.tasks[idx].evidence = evidence }
            if !appendEvidence.isEmpty { plan.tasks[idx].evidence.append(contentsOf: appendEvidence) }
            save(plan)
            return plan.tasks[idx]
        }
    }

    /// Replace the whole plan (e.g. seeding from a runbook). Re-bases nextId past the max id.
    public func replace(title: String, tasks: [PlanTask]) {
        withLock {
            let maxId = tasks.map(\.id).max() ?? 0
            save(Plan(title: title, tasks: tasks, nextId: maxId + 1))
        }
    }

    public func clear() { withLock { save(Plan()) } }

    /// Mark the lowest todo task in progress and return it (drives "start the next task").
    @discardableResult
    public func startNext() -> PlanTask? {
        withLock {
            var plan = load()
            guard let next = plan.nextActionable ?? plan.next,
                  let index = plan.tasks.firstIndex(where: { $0.id == next.id }) else {
                return nil
            }
            plan.tasks[index].status = .inProgress
            plan.tasks[index].startedAt = Date().timeIntervalSince1970
            save(plan)
            return plan.tasks[index]
        }
    }

    /// The self-advancing loop Luke asked for (2026-07-31): mark a task DONE and, if nothing else is in
    /// progress, immediately promote the next actionable (non-research) todo to inProgress — so completing
    /// a task auto-advances the board to "the next request it needs" instead of the human/agent having to
    /// re-select. A retry of an already-completed task is idempotent and never advances again.
    /// Returns what was completed, what's now active, and whether this call performed the promotion.
    @discardableResult
    public func completeAndAdvance(id: Int, sessionStartedAt: Date? = nil)
        -> (completed: PlanTask?, nowActive: PlanTask?, didAdvance: Bool) {
        withLock {
            var plan = load()
            func liveActive(in plan: Plan, since ownershipStart: Date?) -> PlanTask? {
                ownershipStart.map { plan.active(since: $0) } ?? plan.active
            }
            guard let idx = plan.tasks.firstIndex(where: { $0.id == id }) else {
                return (nil, liveActive(in: plan, since: sessionStartedAt), false)
            }
            // The REPL supplies its exact session boundary. Tool callers do not have that boundary, but a
            // task explicitly started/resumed for this run carries a fresh `startedAt`; use that as the
            // ownership floor so an older zombie cannot block `tasks done` from advancing the live board.
            let ownershipStart = sessionStartedAt
                ?? plan.tasks[idx].startedAt.map { Date(timeIntervalSince1970: $0) }
            if plan.tasks[idx].status == .done {
                return (plan.tasks[idx], liveActive(in: plan, since: ownershipStart), false)
            }
            plan.tasks[idx].status = .done
            let completed = plan.tasks[idx]
            // A zombie `inProgress` task from an earlier session must not block advancement forever.
            // Keep only a task explicitly claimed by this live session; stale status remains visible and
            // recoverable on disk, but it has no routing ownership until the user explicitly resumes it.
            var nowActive = liveActive(in: plan, since: ownershipStart)
            var didAdvance = false
            if nowActive == nil, let next = plan.nextActionable,
               let ni = plan.tasks.firstIndex(where: { $0.id == next.id }) {
                plan.tasks[ni].status = .inProgress
                plan.tasks[ni].startedAt = Date().timeIntervalSince1970
                nowActive = plan.tasks[ni]
                didAdvance = true
            }
            save(plan)
            return (completed, nowActive, didAdvance)
        }
    }

    public func save(_ plan: Plan) {
        var plan = plan
        let minNextID = (plan.tasks.map(\.id).max() ?? 0) + 1
        if plan.nextId < minNextID { plan.nextId = minNextID }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(plan) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
