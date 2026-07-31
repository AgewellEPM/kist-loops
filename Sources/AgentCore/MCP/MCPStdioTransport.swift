import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Low-level descriptor helpers for the long-lived MCP stdio transport.
///
/// Every parent-private descriptor is close-on-exec. Parent read/write endpoints are
/// nonblocking so a peer that stops making progress can never pin an actor or shutdown.
enum MCPDescriptor {
    struct PipePair {
        let read: Int32
        let write: Int32
    }

    static func makePipe(nonBlockingRead: Bool, nonBlockingWrite: Bool) throws -> PipePair {
        var fds: [Int32] = [-1, -1]
        while pipe(&fds) != 0 {
            if errno == EINTR { continue }
            throw MCPStdioTransportError.system("pipe", errno)
        }
        guard configure(fds[0], nonBlocking: nonBlockingRead),
              configure(fds[1], nonBlocking: nonBlockingWrite) else {
            let saved = errno
            closeOnce(fds[0])
            closeOnce(fds[1])
            throw MCPStdioTransportError.system("fcntl", saved)
        }
        return PipePair(read: fds[0], write: fds[1])
    }

    static func configure(_ fd: Int32, nonBlocking: Bool) -> Bool {
        let descriptorFlags = retry { fcntl(fd, F_GETFD) }
        guard descriptorFlags >= 0,
              retry({ fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) }) >= 0 else {
            return false
        }
        guard nonBlocking else { return true }
        let statusFlags = retry { fcntl(fd, F_GETFL) }
        return statusFlags >= 0
            && retry({ fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK) }) >= 0
    }

    static func closeOnce(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = close(fd)
    }

    static func retry(_ operation: () -> Int32) -> Int32 {
        while true {
            let result = operation()
            if result >= 0 || errno != EINTR { return result }
        }
    }
}

enum MCPStdioTransportError: Error, LocalizedError {
    case system(String, Int32)
    case spawn(String, Int32)

    var errorDescription: String? {
        switch self {
        case .system(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .spawn(let command, let code):
            return "could not launch \(command): \(String(cString: strerror(code)))"
        }
    }
}

/// One successful posix_spawn result. The primary is born as the leader of a new
/// process group, atomically before it can fork. Shutdown can therefore signal the
/// ordinary descendant tree without ever targeting Kist's own process group.
///
/// A descendant that deliberately calls setsid()/setpgid() can still escape. Fully
/// containing that case requires a PID namespace/cgroup (Linux) or OS-specific job
/// object; it remains an explicit residual rather than a false process-tree claim.
struct MCPSpawnedStdio {
    let process: MCPStdioProcess
    let stdinWriteFD: Int32
    let stdoutReadFD: Int32
    let stderrReadFD: Int32

    static func spawn(config: MCPServerConfig) throws -> MCPSpawnedStdio {
        let stdinPipe = try MCPDescriptor.makePipe(
            nonBlockingRead: false,
            nonBlockingWrite: true)
        var stdoutPipe: MCPDescriptor.PipePair?
        var stderrPipe: MCPDescriptor.PipePair?
        var childEndsClosed = false
        var succeeded = false
        defer {
            if !succeeded {
                MCPDescriptor.closeOnce(stdinPipe.write)
                if let stdoutPipe {
                    MCPDescriptor.closeOnce(stdoutPipe.read)
                }
                if let stderrPipe {
                    MCPDescriptor.closeOnce(stderrPipe.read)
                }
                if !childEndsClosed {
                    MCPDescriptor.closeOnce(stdinPipe.read)
                    if let stdoutPipe {
                        MCPDescriptor.closeOnce(stdoutPipe.write)
                    }
                    if let stderrPipe {
                        MCPDescriptor.closeOnce(stderrPipe.write)
                    }
                }
            }
        }

        stdoutPipe = try MCPDescriptor.makePipe(
            nonBlockingRead: true,
            nonBlockingWrite: false)
        stderrPipe = try MCPDescriptor.makePipe(
            nonBlockingRead: true,
            nonBlockingWrite: false)
        guard let stdoutPipe, let stderrPipe else {
            throw MCPStdioTransportError.system("pipe", EIO)
        }

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif

        var setupError: Int32 = 0
        func check(_ result: Int32) {
            if setupError == 0, result != 0 { setupError = result }
        }

        let actionsResult = posix_spawn_file_actions_init(&actions)
        let actionsInitialized = actionsResult == 0
        check(actionsResult)
        if actionsInitialized {
            check(posix_spawn_file_actions_adddup2(&actions, stdinPipe.read, STDIN_FILENO))
            check(posix_spawn_file_actions_adddup2(&actions, stdoutPipe.write, STDOUT_FILENO))
            check(posix_spawn_file_actions_adddup2(&actions, stderrPipe.write, STDERR_FILENO))
            #if !canImport(Darwin)
            // glibc 2.34+: close every parent-private descriptor not explicitly
            // installed above. Darwin uses CLOEXEC_DEFAULT below.
            check(posix_spawn_file_actions_addclosefrom_np(&actions, 3))
            #endif
        }

        let attributesResult = posix_spawnattr_init(&attributes)
        let attributesInitialized = attributesResult == 0
        check(attributesResult)
        if attributesInitialized {
            check(posix_spawnattr_setpgroup(&attributes, 0))
            #if canImport(Darwin)
            check(posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)))
            #else
            check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
            #endif
        }

        defer {
            if actionsInitialized { posix_spawn_file_actions_destroy(&actions) }
            if attributesInitialized { posix_spawnattr_destroy(&attributes) }
        }
        guard setupError == 0 else {
            throw MCPStdioTransportError.system("posix_spawn setup", setupError)
        }

        var argv: [UnsafeMutablePointer<CChar>?] =
            ([config.command] + config.args).map { strdup($0) }
        argv.append(nil)
        let environment = MCPClientConfig.resolvedEnvironment(for: config)
        var envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(
            &pid,
            config.command,
            &actions,
            &attributes,
            argv,
            envp)

        // These endpoints belong only to the child, whether spawn succeeded or not.
        MCPDescriptor.closeOnce(stdinPipe.read)
        MCPDescriptor.closeOnce(stdoutPipe.write)
        MCPDescriptor.closeOnce(stderrPipe.write)
        childEndsClosed = true

        guard spawnResult == 0 else {
            throw MCPStdioTransportError.spawn(config.command, spawnResult)
        }

        succeeded = true
        return MCPSpawnedStdio(
            process: MCPStdioProcess(pid: pid),
            stdinWriteFD: stdinPipe.write,
            stdoutReadFD: stdoutPipe.read,
            stderrReadFD: stderrPipe.read)
    }
}

enum MCPProcessExitObservation: Sendable {
    /// waitid(WNOWAIT) observed exit; the zombie still reserves PID/PGID.
    case exitedUnreaped
    /// Another owner already reaped the child (ECHILD).
    case alreadyReaped
    /// Observation failed unexpectedly. The eventual reaper falls back to waitpid.
    case observerFailed
}

struct MCPStdioProcessOperations: Sendable {
    let observeExit: @Sendable (pid_t) -> MCPProcessExitObservation
    let signalGroup: @Sendable (pid_t, Int32) -> Void
    let reapPrimary: @Sendable (pid_t) -> Bool
    let pauseMicroseconds: @Sendable (useconds_t) -> Void

    static let live = MCPStdioProcessOperations(
        observeExit: { pid in
            var info = siginfo_t()
            while true {
                let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
                if result == 0 { return .exitedUnreaped }
                if errno == EINTR { continue }
                if errno == ECHILD { return .alreadyReaped }
                return .observerFailed
            }
        },
        signalGroup: { pgid, signalNumber in
            _ = killpg(pgid, signalNumber)
        },
        reapPrimary: { pid in
            var status: Int32 = 0
            while true {
                let result = waitpid(pid, &status, 0)
                if result == pid || (result == -1 && errno == ECHILD) {
                    return true
                }
                if result == -1 && errno == EINTR { continue }
                return false
            }
        },
        pauseMicroseconds: { duration in
            usleep(duration)
        })
}

/// Exit observer + bounded process-group teardown with an eventual definitive reap.
/// waitid(WNOWAIT) deliberately leaves the primary zombie unreaped until the group
/// sweep is complete, reserving the PGID so no signal can hit a recycled group.
///
/// Normal shutdown observes and reaps within the caller's TERM/KILL grace budget.
/// If the primary remains temporarily uninterruptible beyond that finite budget,
/// the caller returns but a retained reaper waits for the eventual exit and performs
/// the one waitpid. No timeout state is ever mislabeled as fully reaped.
final class MCPStdioProcess: @unchecked Sendable {
    private let pid: pid_t
    private let pgid: pid_t
    private let terminationGraceSeconds: TimeInterval
    private let killGraceSeconds: TimeInterval
    private let operations: MCPStdioProcessOperations
    private let condition = NSCondition()
    private let shutdownQueue = DispatchQueue(
        label: "com.kist.mcp.process-shutdown",
        qos: .userInitiated)
    private let eventualReaperQueue = DispatchQueue(
        label: "com.kist.mcp.process-eventual-reaper",
        qos: .utility)
    private var monitoringStarted = false
    private var exitObserved = false
    private var primaryAlreadyReaped = false
    private var observerFailed = false
    private var reapInProgress = false
    private var reapComplete = false
    private var boundedShutdownComplete = false
    private var eventualReaperStarted = false
    private var terminationSignalSent = false
    private var killSignalSent = false
    private var onExit: (@Sendable () -> Void)?

    init(
        pid: pid_t,
        terminationGraceSeconds: TimeInterval = 2.0,
        killGraceSeconds: TimeInterval = 2.0,
        operations: MCPStdioProcessOperations = .live
    ) {
        precondition(terminationGraceSeconds >= 0)
        precondition(killGraceSeconds >= 0)
        self.pid = pid
        self.pgid = pid
        self.terminationGraceSeconds = terminationGraceSeconds
        self.killGraceSeconds = killGraceSeconds
        self.operations = operations
    }

    func startMonitoring(onExit: @escaping @Sendable () -> Void) {
        condition.lock()
        precondition(!monitoringStarted, "MCP process exit monitor started twice")
        monitoringStarted = true
        self.onExit = onExit
        condition.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let observation = operations.observeExit(pid)

            condition.lock()
            switch observation {
            case .exitedUnreaped:
                exitObserved = true
            case .alreadyReaped:
                primaryAlreadyReaped = true
                reapComplete = true
            case .observerFailed:
                observerFailed = true
            }
            let callback = self.onExit
            self.onExit = nil
            condition.broadcast()
            condition.unlock()
            callback?()
        }
    }

    func requestTermination() {
        signalGroupSafely(SIGTERM)
    }

    func shutdown() async {
        await withCheckedContinuation { continuation in
            shutdownQueue.async { [self] in
                shutdownBlocking()
                continuation.resume()
            }
        }
    }

    private func shutdownBlocking() {
        condition.lock()
        if boundedShutdownComplete {
            condition.unlock()
            return
        }
        condition.unlock()

        requestTermination()
        if !waitForExit(seconds: terminationGraceSeconds) {
            // The live primary still reserves the group id.
            signalGroupSafely(SIGKILL)
            _ = waitForExit(seconds: killGraceSeconds)
        }

        _ = reapIfReady()

        condition.lock()
        let shouldStartEventualReaper = !reapComplete && !eventualReaperStarted
        if shouldStartEventualReaper { eventualReaperStarted = true }
        boundedShutdownComplete = true
        condition.broadcast()
        condition.unlock()
        if shouldStartEventualReaper {
            eventualReaperQueue.async { [self] in eventualReap() }
        }
    }

    private func waitForExit(seconds: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if exitObserved || primaryAlreadyReaped || reapComplete { return true }
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !exitObserved && !primaryAlreadyReaped && !reapComplete {
            if !condition.wait(until: deadline) {
                return exitObserved || primaryAlreadyReaped || reapComplete
            }
        }
        return true
    }

    /// Claim the one reap operation. Signals are emitted while the condition lock
    /// protects the unreaped PID/PGID reservation; once claimed, concurrent shutdown
    /// calls cannot signal a descriptor that waitpid has allowed the OS to recycle.
    private func reapIfReady(allowObserverFailure: Bool = false) -> Bool {
        condition.lock()
        if reapComplete {
            condition.unlock()
            return true
        }
        if primaryAlreadyReaped {
            reapComplete = true
            condition.broadcast()
            condition.unlock()
            return true
        }
        guard !reapInProgress,
              exitObserved || (allowObserverFailure && observerFailed) else {
            condition.unlock()
            return false
        }
        reapInProgress = true
        let sweepReservedGroup = exitObserved
        if sweepReservedGroup, !killSignalSent {
            killSignalSent = true
            operations.signalGroup(pgid, SIGKILL)
        }
        condition.unlock()

        if sweepReservedGroup {
            operations.pauseMicroseconds(50_000)
        }
        let reaped = operations.reapPrimary(pid)

        condition.lock()
        reapInProgress = false
        if reaped { reapComplete = true }
        condition.broadcast()
        condition.unlock()
        return reaped
    }

    private func eventualReap() {
        condition.lock()
        while !reapComplete,
              !exitObserved,
              !primaryAlreadyReaped,
              !observerFailed {
            condition.wait()
        }
        condition.unlock()

        while !reapIfReady(allowObserverFailure: true) {
            condition.lock()
            let complete = reapComplete
            condition.unlock()
            if complete { return }
            operations.pauseMicroseconds(50_000)
        }
    }

    private func signalGroupSafely(_ signalNumber: Int32) {
        condition.lock()
        guard !reapComplete, !primaryAlreadyReaped, !reapInProgress else {
            condition.unlock()
            return
        }
        if signalNumber == SIGTERM {
            guard !terminationSignalSent else {
                condition.unlock()
                return
            }
            terminationSignalSent = true
        } else if signalNumber == SIGKILL {
            guard !killSignalSent else {
                condition.unlock()
                return
            }
            killSignalSent = true
        }
        operations.signalGroup(pgid, signalNumber)
        condition.unlock()
    }

    var reapCompleteForTesting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return reapComplete
    }

    var boundedShutdownCompleteForTesting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return boundedShutdownComplete
    }
}

/// Serial, bounded, nonblocking writes to the server's stdin. No actor ever calls
/// write(2). Cancellation and shutdown wake poll immediately through a self-pipe,
/// and waitUntilStopped is a real queue barrier.
final class MCPNonblockingPipeWriter: @unchecked Sendable {
    enum Outcome {
        case success
        /// Whether part of the newline-delimited frame reached the peer before
        /// cancellation. A partial frame makes the connection unusable.
        case cancelled(partialWrite: Bool)
        /// Whether part of the newline-delimited frame reached the peer before
        /// the deadline. A partial frame makes the connection unusable.
        case timedOut(partialWrite: Bool)
        case closed
        case overflow
    }

    typealias Completion = @Sendable (Outcome) -> Void

    private struct Registration {
        let byteCount: Int
        let completion: Completion
        let deadlineWorkItem: DispatchWorkItem?
    }

    private let descriptor: Int32
    private let wakeReadFD: Int32
    private let wakeWriteFD: Int32
    private let byteLimit: Int
    private let eventLimit: Int
    private let queue: DispatchQueue
    private let deadlineQueue: DispatchQueue
    private let lock = NSLock()
    private var registrations: [UUID: Registration] = [:]
    /// Frames captured by serial queue closures. A promptly cancelled/expired
    /// registration remains charged here until its no-op closure reaches the head,
    /// so repeated cancellation cannot bypass the hard memory/event bounds.
    private var scheduledByteCounts: [UUID: Int] = [:]
    private var admissionOrder: [UUID] = []
    private var activeToken: UUID?
    private var cancelledTokens: Set<UUID> = []
    private var timedOutTokens: Set<UUID> = []
    private var retainedBytes = 0
    private var stopping = false
    private var descriptorsClosed = false

    init(
        descriptor: Int32,
        label: String,
        byteLimit: Int = 4 * 1024 * 1024,
        eventLimit: Int = 256
    ) throws {
        precondition(byteLimit > 0)
        precondition(eventLimit > 0)
        self.descriptor = descriptor
        self.byteLimit = byteLimit
        self.eventLimit = eventLimit
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.deadlineQueue = DispatchQueue(
            label: "\(label).deadlines",
            qos: .userInitiated,
            attributes: .concurrent)
        let wake = try MCPDescriptor.makePipe(
            nonBlockingRead: true,
            nonBlockingWrite: true)
        self.wakeReadFD = wake.read
        self.wakeWriteFD = wake.write

        #if canImport(Darwin)
        guard MCPDescriptor.retry({
            fcntl(descriptor, F_SETNOSIGPIPE, 1)
        }) >= 0 else {
            let saved = errno
            MCPDescriptor.closeOnce(wake.read)
            MCPDescriptor.closeOnce(wake.write)
            throw MCPStdioTransportError.system("F_SETNOSIGPIPE", saved)
        }
        #elseif canImport(Glibc)
        MCPBrokenPipePolicy.install()
        #endif
    }

    func enqueue(
        token: UUID,
        data: Data,
        deadlineNanoseconds: UInt64,
        completion: @escaping Completion
    ) {
        let deadlineWorkItem: DispatchWorkItem? =
            deadlineNanoseconds == UInt64.max
            ? nil
            : DispatchWorkItem { [weak self] in
                self?.deadlineReached(token)
            }
        lock.lock()
        guard !stopping,
              data.count <= byteLimit - retainedBytes,
              scheduledByteCounts.count < eventLimit,
              scheduledByteCounts[token] == nil else {
            let outcome: Outcome = stopping ? .closed : .overflow
            lock.unlock()
            completion(outcome)
            return
        }
        registrations[token] = Registration(
            byteCount: data.count,
            completion: completion,
            deadlineWorkItem: deadlineWorkItem)
        scheduledByteCounts[token] = data.count
        admissionOrder.append(token)
        retainedBytes += data.count
        // Queue while holding the state lock: a concurrent stop barrier cannot
        // overtake a write that was accepted into the bounded accounting.
        queue.async { [self] in
            guard beginWrite(token) else { return }
            let outcome = performWrite(
                token: token,
                data: data,
                deadlineNanoseconds: deadlineNanoseconds)
            finish(
                token: token,
                outcome: outcome)
        }
        if let deadlineWorkItem {
            deadlineQueue.asyncAfter(
                deadline: DispatchTime(uptimeNanoseconds: deadlineNanoseconds),
                execute: deadlineWorkItem)
        }
        lock.unlock()
    }

    func cancel(_ token: UUID) {
        var queuedCompletion: Completion?
        lock.lock()
        guard let registration = registrations[token], !descriptorsClosed else {
            lock.unlock()
            return
        }
        if activeToken == token {
            cancelledTokens.insert(token)
        } else {
            registrations.removeValue(forKey: token)
            removeFromAdmissionOrder(token)
            registration.deadlineWorkItem?.cancel()
            queuedCompletion = registration.completion
        }
        // Keep descriptor lifetime and wake atomic. The stop barrier cannot close
        // and recycle this fd between the state check and write(2).
        wakePoll(wakeWriteFD)
        lock.unlock()
        queuedCompletion?(.cancelled(partialWrite: false))
    }

    func requestStop() {
        var queuedCompletions: [Completion] = []
        lock.lock()
        guard !stopping else {
            lock.unlock()
            return
        }
        stopping = true
        queuedCompletions = removeQueuedRegistrations()
        wakePoll(wakeWriteFD)
        lock.unlock()
        for completion in queuedCompletions {
            completion(.closed)
        }
    }

    func waitUntilStopped() async {
        requestStop()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closeDescriptorsIfNeeded()
                continuation.resume()
            }
        }
    }

    var descriptorForTesting: Int32 { descriptor }

    private func performWrite(
        token: UUID,
        data: Data,
        deadlineNanoseconds: UInt64
    ) -> Outcome {
        var offset = 0
        while offset < data.count {
            let status = tokenStatus(token)
            if status.stopping { return .closed }
            if status.cancelled {
                return .cancelled(partialWrite: offset > 0)
            }
            if status.timedOut {
                return .timedOut(partialWrite: offset > 0)
            }

            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadlineNanoseconds {
                return .timedOut(partialWrite: offset > 0)
            }
            let remaining = deadlineNanoseconds - now
            // Ceil-divide without `remaining + 999_999`, which traps when a
            // caller's timeout deliberately saturates the deadline to UInt64.max.
            let wholeMilliseconds = remaining / 1_000_000
            let roundedMilliseconds = wholeMilliseconds
                + (remaining % 1_000_000 == 0 ? 0 : 1)
            let milliseconds = max(
                1,
                min(
                    UInt64(Int32.max),
                    roundedMilliseconds))

            var polls = [
                pollfd(fd: descriptor, events: Int16(POLLOUT | POLLERR | POLLHUP), revents: 0),
                pollfd(fd: wakeReadFD, events: Int16(POLLIN), revents: 0),
            ]
            let ready = polls.withUnsafeMutableBufferPointer {
                platformPoll(
                    $0.baseAddress,
                    count: nfds_t($0.count),
                    timeoutMilliseconds: Int32(milliseconds))
            }
            if ready < 0 {
                if errno == EINTR { continue }
                return .closed
            }
            if ready == 0 {
                return .timedOut(partialWrite: offset > 0)
            }
            if (polls[1].revents & Int16(POLLIN)) != 0 {
                drainWakePipe()
                continue
            }
            if (polls[0].revents & Int16(POLLERR | POLLHUP)) != 0,
               (polls[0].revents & Int16(POLLOUT)) == 0 {
                return .closed
            }

            let written: Int = data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return 0 }
                return platformWrite(
                    descriptor,
                    buffer: base.advanced(by: offset),
                    byteCount: bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written == 0 {
                return .closed
            } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                return .closed
            }
        }
        return .success
    }

    private func finish(
        token: UUID,
        outcome: Outcome
    ) {
        var queuedCompletions: [Completion] = []
        lock.lock()
        guard let registration = registrations.removeValue(forKey: token) else {
            activeToken = nil
            lock.unlock()
            return
        }
        precondition(activeToken == token)
        activeToken = nil
        removeFromAdmissionOrder(token)
        cancelledTokens.remove(token)
        timedOutTokens.remove(token)
        registration.deadlineWorkItem?.cancel()
        releaseScheduledFrame(token, expectedByteCount: registration.byteCount)
        if Self.mustPoisonConnection(after: outcome) {
            // A partial newline-delimited frame makes every later frame ambiguous,
            // and a closed pipe cannot recover. Poison admission and remove all
            // accepted-but-not-started frames before their serial queue blocks run.
            stopping = true
            queuedCompletions = removeQueuedRegistrations()
        }
        assert(retainedBytes >= 0)
        lock.unlock()
        registration.completion(outcome)
        for completion in queuedCompletions {
            completion(.closed)
        }
    }

    private func beginWrite(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard registrations[token] != nil else {
            releaseScheduledFrame(token)
            return false
        }
        precondition(activeToken == nil)
        activeToken = token
        return true
    }

    private func tokenStatus(
        _ token: UUID
    ) -> (stopping: Bool, cancelled: Bool, timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (
            stopping,
            cancelledTokens.contains(token),
            timedOutTokens.contains(token))
    }

    private func deadlineReached(_ token: UUID) {
        var queuedCompletion: Completion?
        lock.lock()
        guard let registration = registrations[token], !descriptorsClosed else {
            lock.unlock()
            return
        }
        if activeToken == token {
            timedOutTokens.insert(token)
        } else {
            registrations.removeValue(forKey: token)
            removeFromAdmissionOrder(token)
            queuedCompletion = registration.completion
        }
        wakePoll(wakeWriteFD)
        lock.unlock()
        queuedCompletion?(.timedOut(partialWrite: false))
    }

    /// Remove every accepted registration except the one currently executing.
    /// Returned completions preserve admission order.
    private func removeQueuedRegistrations() -> [Completion] {
        var completions: [Completion] = []
        var retained: [UUID] = []
        retained.reserveCapacity(activeToken == nil ? 0 : 1)
        for token in admissionOrder {
            if token == activeToken {
                retained.append(token)
                continue
            }
            guard let registration = registrations.removeValue(forKey: token) else {
                continue
            }
            registration.deadlineWorkItem?.cancel()
            cancelledTokens.remove(token)
            timedOutTokens.remove(token)
            completions.append(registration.completion)
        }
        admissionOrder = retained
        return completions
    }

    private func removeFromAdmissionOrder(_ token: UUID) {
        if let index = admissionOrder.firstIndex(of: token) {
            admissionOrder.remove(at: index)
        }
    }

    /// Called only while `lock` is held, when the serial closure that captures the
    /// frame is finishing or has reached the queue after an early removal.
    private func releaseScheduledFrame(
        _ token: UUID,
        expectedByteCount: Int? = nil
    ) {
        guard let byteCount = scheduledByteCounts.removeValue(forKey: token) else {
            assertionFailure("MCP stdin frame released twice")
            return
        }
        if let expectedByteCount {
            assert(byteCount == expectedByteCount)
        }
        retainedBytes -= byteCount
        assert(retainedBytes >= 0)
    }

    private static func mustPoisonConnection(after outcome: Outcome) -> Bool {
        switch outcome {
        case .cancelled(partialWrite: true),
             .timedOut(partialWrite: true),
             .closed:
            return true
        case .success,
             .cancelled(partialWrite: false),
             .timedOut(partialWrite: false),
             .overflow:
            return false
        }
    }

    private func wakePoll(_ fd: Int32) {
        var byte: UInt8 = 1
        _ = platformWrite(fd, buffer: &byte, byteCount: 1)
    }

    private func drainWakePipe() {
        var bytes = [UInt8](repeating: 0, count: 128)
        while true {
            let count = bytes.withUnsafeMutableBytes {
                platformRead(
                    wakeReadFD,
                    buffer: $0.baseAddress!,
                    byteCount: $0.count)
            }
            if count > 0 { continue }
            if count < 0, errno == EINTR { continue }
            break
        }
    }

    private func closeDescriptorsIfNeeded() {
        lock.lock()
        guard !descriptorsClosed else {
            lock.unlock()
            return
        }
        descriptorsClosed = true
        assert(scheduledByteCounts.isEmpty)
        assert(retainedBytes == 0)
        lock.unlock()
        MCPDescriptor.closeOnce(descriptor)
        MCPDescriptor.closeOnce(wakeReadFD)
        MCPDescriptor.closeOnce(wakeWriteFD)
    }

    private func platformPoll(
        _ descriptors: UnsafeMutablePointer<pollfd>?,
        count: nfds_t,
        timeoutMilliseconds: Int32
    ) -> Int32 {
        #if canImport(Darwin)
        Darwin.poll(descriptors, count, timeoutMilliseconds)
        #elseif canImport(Glibc)
        Glibc.poll(descriptors, count, timeoutMilliseconds)
        #else
        -1
        #endif
    }

    private func platformRead(
        _ fd: Int32,
        buffer: UnsafeMutableRawPointer,
        byteCount: Int
    ) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, buffer, byteCount)
        #elseif canImport(Glibc)
        Glibc.read(fd, buffer, byteCount)
        #else
        -1
        #endif
    }

    private func platformWrite(
        _ fd: Int32,
        buffer: UnsafeRawPointer,
        byteCount: Int
    ) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buffer, byteCount)
        #elseif canImport(Glibc)
        Glibc.write(fd, buffer, byteCount)
        #else
        -1
        #endif
    }
}

#if canImport(Glibc)
private enum MCPBrokenPipePolicy {
    private static let installed: Void = {
        // Linux pipes have no per-descriptor F_SETNOSIGPIPE. Ignoring SIGPIPE is
        // the standard client-process policy; every write still receives EPIPE.
        _ = Glibc.signal(SIGPIPE, SIG_IGN)
    }()

    static func install() { _ = installed }
}
#endif

/// Joined stderr reader. Live data is reduced immediately into MCPStderrTail and
/// optional bounded diagnostics. Once connection/process shutdown begins, it drains
/// until EOF subject to an aggregate byte and absolute-time ceiling, then closes its
/// descriptor before its queue barrier completes.
final class MCPStderrPipePump: @unchecked Sendable {
    private static let pollMilliseconds: Int32 = 50
    private static let chunkBytes = 16 * 1024

    private let queue: DispatchQueue
    private let lock = NSLock()
    private let tail: MCPStderrTail
    private let serverName: String
    private let finalDrainByteLimit: Int
    private let finalDrainNanoseconds: UInt64
    private var active = false
    private var descriptor: Int32 = -1
    private var immediateStop = false
    private var finalDrainStartedAt: UInt64?

    init(
        label: String,
        tail: MCPStderrTail,
        serverName: String,
        finalDrainByteLimit: Int = 256 * 1024,
        finalDrainNanoseconds: UInt64 = 500_000_000
    ) {
        precondition(finalDrainByteLimit > 0)
        precondition(finalDrainNanoseconds > 0)
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.tail = tail
        self.serverName = serverName
        self.finalDrainByteLimit = finalDrainByteLimit
        self.finalDrainNanoseconds = finalDrainNanoseconds
    }

    func start(descriptor: Int32) {
        lock.lock()
        precondition(!active, "MCP stderr pump started twice")
        active = true
        self.descriptor = descriptor
        immediateStop = false
        finalDrainStartedAt = nil
        lock.unlock()
        queue.async { [self] in run(descriptor: descriptor) }
    }

    func requestFinalDrain() {
        lock.lock()
        if active, finalDrainStartedAt == nil {
            finalDrainStartedAt = DispatchTime.now().uptimeNanoseconds
        }
        lock.unlock()
    }

    func requestImmediateStop() {
        lock.lock()
        immediateStop = true
        lock.unlock()
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    var descriptorForTesting: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    private func run(descriptor: Int32) {
        defer {
            MCPDescriptor.closeOnce(descriptor)
            lock.lock()
            active = false
            self.descriptor = -1
            lock.unlock()
        }

        var bytesAfterFinalDrain = 0
        while true {
            let state = snapshot()
            if state.immediateStop { return }
            if let started = state.finalDrainStartedAt {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= started,
                   now - started >= finalDrainNanoseconds {
                    return
                }
                if bytesAfterFinalDrain >= finalDrainByteLimit { return }
            }

            var pollState = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0)
            let ready = platformPoll(
                &pollState,
                timeoutMilliseconds: Self.pollMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }

            var buffer = [UInt8](repeating: 0, count: Self.chunkBytes)
            let count = buffer.withUnsafeMutableBytes {
                platformRead(
                    descriptor,
                    buffer: $0.baseAddress!,
                    byteCount: $0.count)
            }
            if count > 0 {
                let data = Data(buffer.prefix(count))
                let text = String(decoding: data, as: UTF8.self)
                tail.append(text)
                MCPLog.serverStderr(server: serverName, text: text)
                if snapshot().finalDrainStartedAt != nil {
                    bytesAfterFinalDrain += count
                }
                continue
            }
            if count == 0 { return }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            return
        }
    }

    private func snapshot() -> (
        immediateStop: Bool,
        finalDrainStartedAt: UInt64?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (immediateStop, finalDrainStartedAt)
    }

    private func platformPoll(
        _ descriptor: UnsafeMutablePointer<pollfd>,
        timeoutMilliseconds: Int32
    ) -> Int32 {
        #if canImport(Darwin)
        Darwin.poll(descriptor, 1, timeoutMilliseconds)
        #elseif canImport(Glibc)
        Glibc.poll(descriptor, 1, timeoutMilliseconds)
        #else
        -1
        #endif
    }

    private func platformRead(
        _ descriptor: Int32,
        buffer: UnsafeMutableRawPointer,
        byteCount: Int
    ) -> Int {
        #if canImport(Darwin)
        Darwin.read(descriptor, buffer, byteCount)
        #elseif canImport(Glibc)
        Glibc.read(descriptor, buffer, byteCount)
        #else
        -1
        #endif
    }
}
