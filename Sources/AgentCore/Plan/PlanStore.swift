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
            if let status { plan.tasks[idx].status = status }
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
        let maxId = tasks.map(\.id).max() ?? 0
        save(Plan(title: title, tasks: tasks, nextId: maxId + 1))
    }

    public func clear() { save(Plan()) }

    /// Mark the lowest todo task in progress and return it (drives "start the next task").
    @discardableResult
    public func startNext() -> PlanTask? {
        let plan = load()
        guard let n = plan.next else { return nil }
        return update(id: n.id, status: .inProgress)
    }

    /// The self-advancing loop Luke asked for (2026-07-31): mark a task DONE and, if nothing else is in
    /// progress, immediately promote the next actionable (non-research) todo to inProgress — so completing
    /// a task auto-advances the board to "the next request it needs" instead of the human/agent having to
    /// re-select. Returns what was completed and what's now active (either may be nil). One locked RMW.
    @discardableResult
    public func completeAndAdvance(id: Int) -> (completed: PlanTask?, nowActive: PlanTask?) {
        withLock {
            var plan = load()
            guard let idx = plan.tasks.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
            plan.tasks[idx].status = .done
            let completed = plan.tasks[idx]
            var nowActive = plan.active                       // keep an already-running task if there is one
            if nowActive == nil, let next = plan.nextActionable,
               let ni = plan.tasks.firstIndex(where: { $0.id == next.id }) {
                plan.tasks[ni].status = .inProgress
                nowActive = plan.tasks[ni]
            }
            save(plan)
            return (completed, nowActive)
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
