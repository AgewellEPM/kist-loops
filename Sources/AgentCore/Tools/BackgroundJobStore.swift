import Foundation

/// Background commands share the foreground process-group lifecycle. Output is a bounded queue of
/// unread bytes; a slow reader sees an explicit dropped-byte notice and the newest retained output.
public final class BackgroundJobStore: @unchecked Sendable {
    public static let shared = BackgroundJobStore()
    public static let maxConcurrentRunning = 16
    public static let maxOutputBytes = 256 * 1_024
    public static let maxFinishedJobs = 64
    public static let defaultTimeoutSeconds = 3_600

    public final class Job: @unchecked Sendable {
        let id: String
        let command: String
        let owner: String
        let cancellation = ProcessCancellationToken()
        let launchReady = DispatchSemaphore(value: 0)
        let completion = DispatchGroup()
        private let lock = NSLock()
        private var buffer = Data()
        private var droppedBytes: UInt64 = 0
        private var didStart = false
        private var didFinish = false
        private var code: Int32?

        init(id: String, command: String, owner: String) {
            self.id = id; self.command = command; self.owner = owner
            completion.enter()
        }

        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            let limit = BackgroundJobStore.maxOutputBytes
            let overflow = max(0, buffer.count + data.count - limit)
            if overflow > 0 {
                let (sum, wrapped) = droppedBytes.addingReportingOverflow(UInt64(overflow))
                droppedBytes = wrapped ? UInt64.max : sum
            }
            if data.count >= limit {
                buffer = Data(data.suffix(limit))
            } else {
                if overflow > 0 { buffer = Data(buffer.dropFirst(overflow)) }
                buffer.append(data)
            }
        }

        func markStarted() {
            lock.lock(); didStart = true; lock.unlock()
            launchReady.signal()
        }

        func markExit(_ exitCode: Int32) {
            lock.lock()
            code = exitCode; didFinish = true
            let failedBeforeLaunch = !didStart
            lock.unlock()
            if failedBeforeLaunch { launchReady.signal() }
        }

        /// Read and release consumed bytes. The notice is part of the returned byte budget.
        func readNew(maxBytes: Int = 60_000) -> String {
            guard maxBytes > 0 else { return "" }
            lock.lock(); defer { lock.unlock() }
            let notice = droppedBytes > 0 ? "[background output truncated: \(droppedBytes) unread bytes dropped]\n" : ""
            droppedBytes = 0
            let boundedNotice = ProcessGroupRunner.truncateUTF8(notice, toByteBudget: maxBytes, marker: "")
            let count = min(buffer.count, max(0, maxBytes - boundedNotice.utf8.count))
            let data = buffer.prefix(count)
            let output = boundedNotice + String(decoding: data, as: UTF8.self)
            buffer = Data(buffer.dropFirst(count))
            return ProcessGroupRunner.truncateUTF8(output, toByteBudget: maxBytes, marker: "")
        }

        var started: Bool { lock.lock(); defer { lock.unlock() }; return didStart }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !didFinish }
        var finished: Bool { !isRunning }
        var exitCode: Int32? { lock.lock(); defer { lock.unlock() }; return code }
        var retainedOutputBytes: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var completed: [String] = []
    private var counter = 0
    private var activeCount = 0
    private var drainsInProgress = 0

    public init() {}

    public func runningCount() -> Int { lock.lock(); defer { lock.unlock() }; return activeCount }

    /// Reserve and publish before dispatch so shutdown can also cancel a pending launch. Return only
    /// once posix_spawn succeeds; failed launches release their reservation and return nil.
    public func start(launchPath: String, args: [String], cwd: String, env: [String: String],
                      command: String, owner: String = "",
                      timeoutSeconds: Int = BackgroundJobStore.defaultTimeoutSeconds) -> String? {
        guard (1...86_400).contains(timeoutSeconds) else { return nil }
        lock.lock()
        guard drainsInProgress == 0, activeCount < Self.maxConcurrentRunning else {
            lock.unlock(); return nil
        }
        activeCount += 1
        counter += 1
        let id = "job_\(counter)"
        let job = Job(id: id, command: String(command.prefix(4_096)), owner: owner)
        jobs[id] = job
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let outcome = ProcessGroupRunner.run(
                launchPath: launchPath, launchArgs: args, cwd: cwd, env: env,
                timeoutSeconds: timeoutSeconds, capPerStream: 1_024, graceSeconds: 1,
                cancellationCheck: { job.cancellation.isCancelled },
                terminateOnOutputCap: false,
                onSpawn: { job.markStarted() },
                onOutput: { job.append($0) })
            if !job.started, !outcome.combined.isEmpty { job.append(Data(outcome.combined.utf8)) }
            if outcome.timedOut {
                job.append(Data("\n[background job timed out after \(timeoutSeconds)s]\n".utf8))
            } else if outcome.cancelled {
                job.append(Data("\n[background job cancelled]\n".utf8))
            }
            job.markExit(outcome.exitCode)
            finish(id)
            job.completion.leave()
        }

        guard job.launchReady.wait(timeout: .now() + .seconds(10)) == .success, job.started else {
            job.cancellation.cancel()
            // Keep a launch still pending on the worker queue visible to killAll until it finishes.
            if job.completion.wait(timeout: .now()) == .success {
                lock.lock(); jobs.removeValue(forKey: id); completed.removeAll { $0 == id }; lock.unlock()
            }
            return nil
        }
        return id
    }

    private func finish(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        activeCount -= 1
        guard jobs[id] != nil else { return }
        completed.append(id)
        while completed.count > Self.maxFinishedJobs {
            jobs.removeValue(forKey: completed.removeFirst())
        }
    }

    public func job(_ id: String, owner: String? = nil) -> Job? {
        lock.lock(); defer { lock.unlock() }
        guard let job = jobs[id], owner == nil || job.owner == owner else { return nil }
        return job
    }

    /// A successful stop means the runner has completed its group sweep and reaped the leader.
    public func kill(_ id: String, owner: String? = nil) -> Bool {
        guard let job = job(id, owner: owner) else { return false }
        job.cancellation.cancel()
        return job.completion.wait(timeout: .now() + .seconds(8)) == .success
    }

    public func list(owner: String? = nil) -> [String] {
        lock.lock()
        let snapshot = jobs.values.filter { owner == nil || $0.owner == owner }.sorted { $0.id < $1.id }
        lock.unlock()
        return snapshot.map { job in
            let state = job.isRunning ? "running" : "exit \(job.exitCode ?? -1)"
            return "\(job.id) · \(state) · \(job.command.prefix(80))"
        }
    }

    /// Reject launches during the drain, cancel every published job, and join cleanup with one common
    /// deadline. Descendants that deliberately leave their process group remain a documented limit.
    @discardableResult
    public func killAll(graceSeconds: Double = 0.3) -> Bool {
        lock.lock(); drainsInProgress += 1; let snapshot = Array(jobs.values); lock.unlock()
        defer { lock.lock(); drainsInProgress -= 1; lock.unlock() }
        for job in snapshot { job.cancellation.cancel() }
        let extraGrace = graceSeconds.isFinite ? min(max(0, graceSeconds), 10) : 0
        let deadline = DispatchTime.now() + .milliseconds(Int((8 + extraGrace) * 1_000))
        var drained = true
        for job in snapshot where job.completion.wait(timeout: deadline) != .success { drained = false }
        return drained
    }
}
