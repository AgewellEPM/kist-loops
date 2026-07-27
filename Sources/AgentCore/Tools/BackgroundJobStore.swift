import Foundation

/// Runs a command in the BACKGROUND and lets the agent poll its output / kill it by id — the
/// equivalent of Claude Code's `run_in_background` + `BashOutput` + `KillShell`. `run_command` with
/// `background:true` starts a job here and returns immediately; the `job` tool reads new output, checks
/// status, and stops it. This closes the "start the dev server, run tests against it, watch logs" gap:
/// `run_command` alone is synchronous fire-and-timeout.
///
/// Each job streams stdout+stderr into a lock-protected buffer via a readability handler; a read returns
/// only the bytes since the previous read (a cursor), so polling is incremental. Process lifecycle is
/// Foundation `Process` (terminate on kill / on store shutdown).
public final class BackgroundJobStore: @unchecked Sendable {
    public static let shared = BackgroundJobStore()

    public final class Job: @unchecked Sendable {
        let id: String
        let command: String
        let process: Process
        /// The workspace (projectRoot) that launched this job — the ownership key. In a fleet each
        /// agent runs in its own worktree, so scoping visibility/kill by owner stops one agent from
        /// reading or killing another's jobs. Empty = unowned (visible to unowned queries only).
        let owner: String
        private let lock = NSLock()
        private var buffer = Data()
        private var cursor = 0
        private(set) var exitCode: Int32?
        private(set) var finished = false

        init(id: String, command: String, process: Process, owner: String) {
            self.id = id; self.command = command; self.process = process; self.owner = owner
        }
        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        func markExit(_ code: Int32) { lock.lock(); exitCode = code; finished = true; lock.unlock() }
        /// New output since the last read (advances the cursor). Bounded to `maxBytes` per read.
        func readNew(maxBytes: Int = 60_000) -> String {
            lock.lock(); defer { lock.unlock() }
            guard cursor < buffer.count else { return "" }
            let end = min(buffer.count, cursor + maxBytes)
            let slice = buffer.subdata(in: cursor..<end)
            cursor = end
            return String(decoding: slice, as: UTF8.self)
        }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !finished }
    }

    /// Hard ceiling on concurrently-RUNNING background jobs. A hijacked agent could otherwise spawn
    /// unbounded processes (resource-exhaustion / fork-bomb-lite); refusing past this cap bounds the
    /// blast radius. Finished jobs don't count — the agent can always kill one to make room.
    public static let maxConcurrentRunning = 16

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var counter = 0
    /// Slots RESERVED for currently-live jobs. Incremented under `lock` at reservation time (BEFORE
    /// spawn) and decremented in the termination handler (or on launch failure). This is the single
    /// source of truth for the cap — an explicit integer avoids counting via each job's own lock
    /// (no nested locking) and makes the check-and-reserve ATOMIC, so N concurrent `start` calls
    /// (e.g. a plan executor's task group) can never collectively exceed the ceiling.
    private var activeCount = 0

    /// Number of live (reserved/running) jobs. Authoritative — read straight off `activeCount`.
    public func runningCount() -> Int { lock.lock(); defer { lock.unlock() }; return activeCount }

    /// Start a background job. `launchPath`+`args` are already resolved (no shell unless caller wrapped it).
    /// `owner` is the launching workspace (projectRoot) — the ownership key for later job/kill/list scoping.
    /// Returns the job id, or nil if the process couldn't launch OR the concurrent-job cap is reached.
    public func start(launchPath: String, args: [String], cwd: String, env: [String: String], command: String,
                      owner: String = "") -> String? {
        // ATOMIC reserve-or-refuse: the cap check AND the reservation happen under one lock hold, so
        // concurrent starts can't all observe "< cap" and then all spawn (Codex-caught race).
        lock.lock()
        guard activeCount < Self.maxConcurrentRunning else { lock.unlock(); return nil }
        activeCount += 1                                  // reserve the slot before spawning
        counter += 1; let id = "job_\(counter)"
        lock.unlock()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let job = Job(id: id, command: command, process: proc, owner: owner)

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty { handle.readabilityHandler = nil } else { job.append(d) }
        }
        proc.terminationHandler = { [weak self] p in
            job.markExit(p.terminationStatus)
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.releaseSlot()                            // free the reservation exactly once
        }
        do { try proc.run() } catch {
            releaseSlot()                                  // roll back the reservation on launch failure
            return nil
        }
        lock.lock(); jobs[id] = job; lock.unlock()
        return id
    }

    /// Release one reserved slot (never below zero). Called from the termination handler or on a
    /// launch failure.
    private func releaseSlot() {
        lock.lock(); if activeCount > 0 { activeCount -= 1 }; lock.unlock()
    }

    /// Fetch a job by id, scoped to `owner`: a job launched by a different workspace is invisible
    /// (returns nil) so one agent can't read another's output. `owner: nil` = unscoped (internal use).
    public func job(_ id: String, owner: String? = nil) -> Job? {
        lock.lock(); defer { lock.unlock() }
        guard let j = jobs[id] else { return nil }
        if let owner, j.owner != owner { return nil }   // cross-owner access denied
        return j
    }

    /// Kill a job by id, scoped to `owner` (a mismatched owner can't kill someone else's job).
    public func kill(_ id: String, owner: String? = nil) -> Bool {
        guard let job = job(id, owner: owner) else { return false }
        if job.isRunning { job.process.terminate() }
        return true
    }

    /// One-line status per job: id · running|exit N · command. Scoped to `owner` (nil = all jobs).
    public func list(owner: String? = nil) -> [String] {
        lock.lock()
        let snapshot = jobs.values.filter { owner == nil || $0.owner == owner }.sorted { $0.id < $1.id }
        lock.unlock()
        return snapshot.map { j in
            let state = j.isRunning ? "running" : "exit \(j.exitCode ?? -1)"
            return "\(j.id) · \(state) · \(j.command.prefix(80))"
        }
    }

    /// Terminate every still-running job — call on process shutdown so background jobs don't orphan.
    /// ESCALATES: SIGTERM first (graceful), then, for any job that ignores it (e.g. a child that traps
    /// TERM), SIGKILL after a short bounded grace. Bounded so the exit path stays fast when jobs die
    /// promptly (the common case), but a stubborn child can't survive to be reparented/orphaned.
    public func killAll(graceSeconds: Double = 0.3) {
        lock.lock(); let all = Array(jobs.values); lock.unlock()
        let running = all.filter { $0.isRunning }
        guard !running.isEmpty else { return }
        for j in running { j.process.terminate() }                    // SIGTERM
        // Poll briefly; exit as soon as everything is gone.
        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline && running.contains(where: { $0.isRunning }) { usleep(20_000) }
        for j in running where j.isRunning {                          // SIGKILL survivors
            let pid = j.process.processIdentifier
            if pid > 0 { posixKill(pid, SIGKILL) }
        }
    }
}

/// Free-function wrapper for the POSIX `kill(2)` — avoids colliding with `BackgroundJobStore.kill(_:)`
/// (the by-id method) when resolving the name inside the type.
private func posixKill(_ pid: pid_t, _ signal: Int32) { _ = kill(pid, signal) }
