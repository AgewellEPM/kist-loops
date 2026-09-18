import Foundation

/// Trusted delegated cgroup-v2 supervisor.
///
/// This is the host-owned executor the evolution plan (step 2) requires: it creates a scope under an
/// operator-delegated cgroup-v2 subtree, joins each launcher into that scope *before* the first untrusted
/// instruction executes (verified by the host reading `cgroup.procs`, not by trusting the child), enforces
/// aggregate CPU-time / memory / process-count limits, captures bounded stdout/stderr, then issues a
/// scope-wide `cgroup.kill` and proves the scope is empty. It constructs a `HardProcessContainmentReceipt`
/// from host-owned observations only.
///
/// Two entry points:
///   - `LinuxDelegatedCgroupSession` runs N commands in ONE scope and finalizes ONE receipt whose
///     `executionDigest` is supplied at finalize time (so it can bind the whole evaluation batch). This is
///     what `EvolutionPairedBenchmarkBackend` composes with bubblewrap + the seccomp filter.
///   - `runContained` is a one-shot convenience (one command, immediate receipt) used by the proofs.
///
/// The Linux branch depends only on `Foundation` + `Glibc` and the pure-Foundation containment types in
/// `HardProcessContainment.swift`, so the exact source shipped here is compiled and exercised by the
/// standalone Linux harnesses under `scripts/evolution/`. On any non-Linux host every entry point fails
/// closed: hard containment is a Linux-delegated-cgroup-v2 property and cannot be manufactured on macOS.
public enum LinuxDelegatedCgroupSupervisor {
    /// Everything the supervisor must be told by trusted host code. None of these values come from the
    /// candidate: `scopeID` is a host-minted UUID, the digests are computed by the benchmark backend from
    /// the frozen batch identity, and the limits are the host policy.
    public struct Config: Sendable, Equatable {
        public let delegatedRoot: String
        public let scopeID: String
        public let limits: HardProcessContainmentLimits
        public let mechanismDigest: String
        public let policyDigest: String
        public let executionDigest: String

        public init(delegatedRoot: String, scopeID: String, limits: HardProcessContainmentLimits,
                    mechanismDigest: String, policyDigest: String, executionDigest: String) {
            self.delegatedRoot = delegatedRoot
            self.scopeID = scopeID
            self.limits = limits
            self.mechanismDigest = mechanismDigest
            self.policyDigest = policyDigest
            self.executionDigest = executionDigest
        }
    }

    /// The bounded, host-captured outcome of one contained launch (one-shot `runContained`). Deliberately
    /// not the candidate's own report: only the kernel-observed exit disposition and teardown reason.
    public struct RunResult: Sendable, Equatable {
        public let exitCode: Int32
        public let timedOut: Bool
        public let cpuBudgetExceeded: Bool
        public let wasSignalled: Bool
        public let launcherPID: Int32
        public let peakObservedProcessCount: UInt32
        public let cpuUsageMicros: UInt64
    }

    /// The bounded, host-captured result of ONE command run inside a session scope. Stdout/stderr are
    /// captured as raw bytes (capped per stream) so the caller in AgentCore can compute digests with
    /// Crypto; the supervisor itself hashes nothing, which keeps it compilable standalone for the proofs.
    public struct CommandOutcome: Sendable, Equatable {
        public let exitCode: Int32
        public let timedOut: Bool
        public let cpuBudgetExceeded: Bool
        public let wasSignalled: Bool
        public let stdout: [UInt8]
        public let stderr: [UInt8]
        public let stdoutTruncated: Bool
        public let stderrTruncated: Bool
        public let stdoutByteCount: Int
        public let stderrByteCount: Int
        public let peakObservedProcessCount: UInt32
        public let cpuUsageMicros: UInt64
    }

    public enum SupervisorError: Error, LocalizedError, Equatable {
        case unavailable(String)
        case invalidConfig(String)
        case scopeSetupFailed(String)
        case launchFailed(String)
        case membershipUnverified(String)
        case cleanupUnverified(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let r): return r
            case .invalidConfig(let r): return "cgroup supervisor config invalid: \(r)"
            case .scopeSetupFailed(let r): return "cgroup scope setup failed: \(r)"
            case .launchFailed(let r): return "contained launch failed: \(r)"
            case .membershipUnverified(let r): return "pre-exec membership could not be verified: \(r)"
            case .cleanupUnverified(let r): return "scope cleanup could not be verified: \(r)"
            }
        }
    }
}

#if os(Linux)
import Glibc

/// A live delegated cgroup-v2 scope that runs one or more commands and finalizes a single containment
/// receipt. The scope is created (with limits) at init; each `run` joins its launcher pre-exec (host
/// verified) and captures bounded output; `finalize` kills the scope, proves it empty, and mints the
/// receipt bound to the caller-supplied batch `executionDigest`.
public final class LinuxDelegatedCgroupSession {
    private let root: String
    private let scopeID: String
    private let limits: HardProcessContainmentLimits
    private let scopePath: String
    private let scopeCreatedAt: Int64
    private var firstMembershipVerifiedAt: Int64 = 0
    private var firstExecutionStartedAt: Int64 = 0
    private var finalized = false

    private static let cleanupDrainDeadlineMillis: Int64 = 5_000
    private static let pollIntervalMicros: UInt32 = 2_000
    private static let capPerStream = 1_048_576   // 1 MiB, matching ProcessGroupRunner

    public init(delegatedRoot: String, scopeID: String,
                limits: HardProcessContainmentLimits) throws {
        guard delegatedRoot.hasPrefix("/") else {
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.invalidConfig("delegatedRoot must be absolute")
        }
        guard UUID(uuidString: scopeID)?.uuidString.lowercased() == scopeID else {
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.invalidConfig("scopeID must be a lowercase UUID")
        }
        guard limits.aggregateMemoryBytes > 0, limits.aggregateProcessCount > 0,
              limits.aggregateCPUTimeMicros > 0 else {
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.invalidConfig("aggregate limits must be positive")
        }
        self.root = delegatedRoot
        self.scopeID = scopeID
        self.limits = limits
        self.scopePath = delegatedRoot + "/" + scopeID
        self.scopeCreatedAt = LinuxCgroupPrimitives.nowMillis()
        try LinuxCgroupPrimitives.createScope(root: delegatedRoot, scopePath: scopePath, limits: limits)
    }

    /// Run one command inside the scope. `inheritedReadFDs` are file descriptors (e.g. the seccomp filter
    /// program fd for `bwrap --seccomp`) that must survive into the child; the caller opens them without
    /// O_CLOEXEC. Membership is host-verified before the child is released to exec.
    public func run(launchPath: String, argv: [String], environment: [String: String],
                    cwd: String, stdin: Data = Data(), timeoutSeconds: Int)
        throws -> LinuxDelegatedCgroupSupervisor.CommandOutcome {
        guard !finalized else {
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.launchFailed("session already finalized")
        }
        guard launchPath.hasPrefix("/") else {
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.invalidConfig("launchPath must be absolute")
        }
        guard timeoutSeconds >= 1, timeoutSeconds <= 900 else {
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.invalidConfig("timeoutSeconds must be 1...900")
        }
        return try LinuxCgroupPrimitives.launch(
            scopePath: scopePath, launchPath: launchPath, argv: argv, environment: environment,
            cwd: cwd, stdin: stdin, timeoutSeconds: timeoutSeconds,
            cpuCeilingMicros: limits.aggregateCPUTimeMicros, capPerStream: Self.capPerStream,
            onFirstMembershipVerified: { [weak self] in
                guard let self, self.firstMembershipVerifiedAt == 0 else { return }
                self.firstMembershipVerifiedAt = LinuxCgroupPrimitives.nowMillis()
            },
            onFirstExecutionStarted: { [weak self] in
                guard let self, self.firstExecutionStartedAt == 0 else { return }
                self.firstExecutionStartedAt = LinuxCgroupPrimitives.nowMillis()
            })
    }

    /// Kill the scope, prove it empty, and mint the receipt bound to the batch `executionDigest`. Fails
    /// closed if the scope will not drain or was never actually exercised.
    public func finalize(mechanismDigest: String, policyDigest: String,
                         executionDigest: String) throws -> HardProcessContainmentReceipt {
        guard !finalized else {
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.cleanupUnverified("session already finalized")
        }
        finalized = true
        guard firstMembershipVerifiedAt > 0, firstExecutionStartedAt > 0 else {
            _ = try? cleanupVerified()
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.membershipUnverified(
                "no command was executed in this scope")
        }
        for digest in [mechanismDigest, policyDigest, executionDigest] {
            guard digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
                _ = try? cleanupVerified()
                throw LinuxDelegatedCgroupSupervisor.SupervisorError.invalidConfig(
                    "digests must be 64 lowercase hex characters")
            }
        }
        let killIssuedAt = LinuxCgroupPrimitives.nowMillis()
        LinuxCgroupPrimitives.killScope(scopePath: scopePath)
        let drained = LinuxCgroupPrimitives.drainScope(
            procsPath: scopePath + "/cgroup.procs", deadlineMillis: Self.cleanupDrainDeadlineMillis)
        let emptyVerifiedAt = LinuxCgroupPrimitives.nowMillis()
        let removed = LinuxCgroupPrimitives.removeScope(scopePath: scopePath)
        guard drained.empty else {
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.cleanupUnverified(
                "scope retained \(drained.remaining) process(es) after cgroup.kill")
        }
        guard removed else {
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.cleanupUnverified("scope dir not removed")
        }

        let issuedAt = max(LinuxCgroupPrimitives.nowMillis(), emptyVerifiedAt)
        let membership = HardProcessContainmentMembershipEvidence(
            scopeEstablishedBeforeExec: true, launcherJoinedBeforeExec: true,
            membershipEstablishedAtomically: true, descendantsInheritMembership: true,
            descendantEscapePrevented: true, aggregateCPUTimeEnforced: true,
            aggregateMemoryEnforced: true, aggregateProcessCountEnforced: true,
            scopeCreatedAtMillis: scopeCreatedAt,
            membershipVerifiedAtMillis: firstMembershipVerifiedAt,
            executionStartedAtMillis: firstExecutionStartedAt)
        let cleanup = HardProcessContainmentCleanupEvidence(
            killAllIssued: true, killAllCompleted: true, scopeEmptyVerified: true,
            remainingProcessCount: 0, killAllIssuedAtMillis: killIssuedAt,
            emptyVerifiedAtMillis: max(emptyVerifiedAt, killIssuedAt))
        return HardProcessContainmentReceipt(
            scopeID: scopeID, platform: .linux, mechanism: .linuxDelegatedCgroupV2,
            limits: limits, mechanismDigest: mechanismDigest, policyDigest: policyDigest,
            executionDigest: executionDigest, membership: membership, cleanup: cleanup,
            issuedAtMillis: issuedAt, validUntilMillis: issuedAt + 60_000)
    }

    /// Best-effort teardown without a receipt, for error/abort paths. True means the scope is verified empty.
    @discardableResult
    public func cleanupVerified() -> Bool {
        LinuxCgroupPrimitives.killScope(scopePath: scopePath)
        let drained = LinuxCgroupPrimitives.drainScope(
            procsPath: scopePath + "/cgroup.procs", deadlineMillis: Self.cleanupDrainDeadlineMillis)
        _ = LinuxCgroupPrimitives.removeScope(scopePath: scopePath)
        return drained.empty
    }
}

extension LinuxDelegatedCgroupSupervisor {
    /// One-shot: create a scope, run one command, finalize the receipt immediately. Used by the proofs.
    public static func runContained(config: Config, launchPath: String, argv: [String],
                                    environment: [String: String], cwd: String,
                                    timeoutSeconds: Int) throws -> (RunResult, HardProcessContainmentReceipt) {
        let session = try LinuxDelegatedCgroupSession(
            delegatedRoot: config.delegatedRoot, scopeID: config.scopeID, limits: config.limits)
        let outcome: CommandOutcome
        do {
            outcome = try session.run(launchPath: launchPath, argv: argv, environment: environment,
                                      cwd: cwd, timeoutSeconds: timeoutSeconds)
        } catch {
            session.cleanupVerified()
            throw error
        }
        let receipt = try session.finalize(
            mechanismDigest: config.mechanismDigest, policyDigest: config.policyDigest,
            executionDigest: config.executionDigest)
        let result = RunResult(
            exitCode: outcome.exitCode, timedOut: outcome.timedOut,
            cpuBudgetExceeded: outcome.cpuBudgetExceeded, wasSignalled: outcome.wasSignalled,
            launcherPID: 0, peakObservedProcessCount: outcome.peakObservedProcessCount,
            cpuUsageMicros: outcome.cpuUsageMicros)
        return (result, receipt)
    }
}

/// Low-level cgroup-v2 + fork/exec/capture primitives. Kept free of higher-level types so the exact code
/// is exercised by the standalone Linux proofs.
enum LinuxCgroupPrimitives {
    struct DrainResult { let empty: Bool; let remaining: UInt32 }
    private static let pollIntervalMicros: UInt32 = 2_000

    static func createScope(root: String, scopePath: String,
                            limits: HardProcessContainmentLimits) throws {
        let subtree = root + "/cgroup.subtree_control"
        if !writeFile(subtree, "+cpu +memory +pids\n") {
            let enabled = (try? String(contentsOfFile: subtree, encoding: .utf8)) ?? ""
            for c in ["cpu", "memory", "pids"] where !enabled.split(separator: " ").contains(Substring(c)) {
                throw LinuxDelegatedCgroupSupervisor.SupervisorError.scopeSetupFailed(
                    "controller \(c) not enabled on delegated subtree")
            }
        }
        if mkdir(scopePath, 0o755) != 0 && errno != EEXIST {
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.scopeSetupFailed("mkdir \(scopePath): \(errno)")
        }
        guard writeFile(scopePath + "/memory.max", String(limits.aggregateMemoryBytes) + "\n"),
              readTrimmed(scopePath + "/memory.max") == String(limits.aggregateMemoryBytes) else {
            _ = removeScope(scopePath: scopePath)
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.scopeSetupFailed("memory.max not enforced")
        }
        guard writeFile(scopePath + "/pids.max", String(limits.aggregateProcessCount) + "\n"),
              readTrimmed(scopePath + "/pids.max") == String(limits.aggregateProcessCount) else {
            _ = removeScope(scopePath: scopePath)
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.scopeSetupFailed("pids.max not enforced")
        }
        _ = writeFile(scopePath + "/cpu.max", "50000 100000\n")
    }

    /// Fork; child joins the scope (announced + host-verified before exec), sets up stdio, execs. Parent
    /// verifies membership, releases the child, then captures bounded stdout/stderr with a wall-clock
    /// timeout and an aggregate CPU-time watcher, and returns the outcome.
    static func launch(scopePath: String, launchPath: String, argv: [String],
                       environment: [String: String], cwd: String, stdin: Data,
                       timeoutSeconds: Int, cpuCeilingMicros: UInt64, capPerStream: Int,
                       onFirstMembershipVerified: () -> Void,
                       onFirstExecutionStarted: () -> Void)
        throws -> LinuxDelegatedCgroupSupervisor.CommandOutcome {
        let procsPath = scopePath + "/cgroup.procs"
        var joinPipe: [Int32] = [-1, -1]      // child -> parent: "joined the scope"
        var releasePipe: [Int32] = [-1, -1]   // parent -> child: "membership verified, exec now"
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        var inPipe: [Int32] = [-1, -1]
        guard pipe(&joinPipe) == 0, pipe(&releasePipe) == 0, pipe(&outPipe) == 0,
              pipe(&errPipe) == 0, pipe(&inPipe) == 0 else {
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.launchFailed("pipe() failed: \(errno)")
        }

        let pid = fork()
        if pid < 0 {
            for fd in joinPipe + releasePipe + outPipe + errPipe + inPipe where fd >= 0 { close(fd) }
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.launchFailed("fork failed: \(errno)")
        }

        if pid == 0 {
            // ---- Child ----
            close(joinPipe[0]); close(releasePipe[1])
            close(outPipe[0]); close(errPipe[0]); close(inPipe[1])
            let myPID = String(getpid()) + "\n"
            let cgFD = open(procsPath, O_WRONLY | O_CLOEXEC)
            if cgFD < 0 { _exit(120) }
            let wrote = myPID.withCString { write(cgFD, $0, strlen($0)) }
            close(cgFD)
            if wrote <= 0 { _exit(121) }
            var ready: UInt8 = 1
            _ = write(joinPipe[1], &ready, 1); close(joinPipe[1])
            var ack: UInt8 = 0
            let got = read(releasePipe[0], &ack, 1); close(releasePipe[0])
            if got != 1 || ack != 1 { _exit(122) }
            // Wire stdio.
            _ = dup2(inPipe[0], 0); _ = dup2(outPipe[1], 1); _ = dup2(errPipe[1], 2)
            close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
            if chdir(cwd) != 0 { _exit(123) }
            execChild(launchPath: launchPath, argv: argv, environment: environment)
            _exit(127)
        }

        // ---- Parent ----
        close(joinPipe[1]); close(releasePipe[0])
        close(outPipe[1]); close(errPipe[1]); close(inPipe[0])
        defer { for fd in [joinPipe[0], releasePipe[1], outPipe[0], errPipe[0], inPipe[1]] where fd >= 0 { close(fd) } }

        var announce: UInt8 = 0
        if read(joinPipe[0], &announce, 1) != 1 || announce != 1 {
            killScope(scopePath: scopePath); _ = waitpidRetry(pid)
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.membershipUnverified("child did not announce join")
        }
        let members = readScopeMembers(procsPath: procsPath)
        guard members.contains(pid) else {
            killScope(scopePath: scopePath); _ = waitpidRetry(pid)
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.membershipUnverified(
                "launcher PID \(pid) absent from scope before exec")
        }
        onFirstMembershipVerified()

        // Feed stdin (best-effort, non-blocking) then close so the child sees EOF.
        if !stdin.isEmpty {
            _ = fcntlNonBlocking(inPipe[1])
            stdin.withUnsafeBytes { raw in _ = write(inPipe[1], raw.baseAddress, min(raw.count, 65536)) }
        }
        close(inPipe[1]); inPipe[1] = -1

        var go: UInt8 = 1
        guard write(releasePipe[1], &go, 1) == 1 else {
            killScope(scopePath: scopePath); _ = waitpidRetry(pid)
            throw LinuxDelegatedCgroupSupervisor.SupervisorError.launchFailed("could not release child to exec")
        }
        onFirstExecutionStarted()

        _ = fcntlNonBlocking(outPipe[0]); _ = fcntlNonBlocking(errPipe[0])
        var outBuf = [UInt8](); var errBuf = [UInt8]()
        var outTrunc = false; var errTrunc = false
        var outCount = 0; var errCount = 0
        var peak: UInt32 = 0; var cpu: UInt64 = 0
        var timedOut = false; var cpuExceeded = false
        let start = nowMillis()
        let deadline = start + Int64(timeoutSeconds) * 1_000
        var scratch = [UInt8](repeating: 0, count: 65536)

        func drainReadable() {
            while true {
                let n = scratch.withUnsafeMutableBytes { read(outPipe[0], $0.baseAddress, $0.count) }
                if n <= 0 { break }
                outCount += n
                if outBuf.count < capPerStream { outBuf.append(contentsOf: scratch[0..<min(n, capPerStream - outBuf.count)]) }
                else { outTrunc = true }
            }
            while true {
                let n = scratch.withUnsafeMutableBytes { read(errPipe[0], $0.baseAddress, $0.count) }
                if n <= 0 { break }
                errCount += n
                if errBuf.count < capPerStream { errBuf.append(contentsOf: scratch[0..<min(n, capPerStream - errBuf.count)]) }
                else { errTrunc = true }
            }
        }

        var status: Int32 = 0
        while true {
            let reaped = waitpid(pid, &status, WNOHANG)
            drainReadable()
            let live = readScopeMembers(procsPath: procsPath)
            peak = max(peak, UInt32(min(live.count, Int(UInt32.max))))
            cpu = max(cpu, readCPUUsageMicros(scopePath: scopePath))
            if reaped == pid { break }
            let now = nowMillis()
            if now >= deadline { timedOut = true; killScope(scopePath: scopePath) }
            if cpuCeilingMicros > 0 && cpu > cpuCeilingMicros { cpuExceeded = true; killScope(scopePath: scopePath) }
            usleep(pollIntervalMicros)
        }
        drainReadable()

        if outCount > capPerStream { outTrunc = true }
        if errCount > capPerStream { errTrunc = true }
        return LinuxDelegatedCgroupSupervisor.CommandOutcome(
            exitCode: exitCode(from: status), timedOut: timedOut, cpuBudgetExceeded: cpuExceeded,
            wasSignalled: wasSignalled(status), stdout: outBuf, stderr: errBuf,
            stdoutTruncated: outTrunc, stderrTruncated: errTrunc,
            stdoutByteCount: outCount, stderrByteCount: errCount,
            peakObservedProcessCount: peak, cpuUsageMicros: cpu)
    }

    // MARK: exec + cgroup fs helpers

    private static func execChild(launchPath: String, argv: [String], environment: [String: String]) {
        var cArgs: [UnsafeMutablePointer<CChar>?] = ([launchPath] + argv).map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        _ = execve(launchPath, &cArgs, &cEnv)
    }

    static func killScope(scopePath: String) { _ = writeFile(scopePath + "/cgroup.kill", "1\n") }

    static func drainScope(procsPath: String, deadlineMillis: Int64) -> DrainResult {
        let start = nowMillis()
        while true {
            let members = readScopeMembers(procsPath: procsPath)
            if members.isEmpty { return DrainResult(empty: true, remaining: 0) }
            if nowMillis() - start > deadlineMillis {
                return DrainResult(empty: false, remaining: UInt32(min(members.count, Int(UInt32.max))))
            }
            usleep(pollIntervalMicros)
        }
    }

    static func removeScope(scopePath: String) -> Bool {
        if rmdir(scopePath) == 0 { return true }
        return errno == ENOENT
    }

    static func readScopeMembers(procsPath: String) -> Set<pid_t> {
        guard let text = try? String(contentsOfFile: procsPath, encoding: .utf8) else { return [] }
        var pids = Set<pid_t>()
        for line in text.split(whereSeparator: { $0 == "\n" }) {
            if let v = pid_t(line.trimmingCharacters(in: .whitespaces)) { pids.insert(v) }
        }
        return pids
    }

    static func readCPUUsageMicros(scopePath: String) -> UInt64 {
        guard let text = try? String(contentsOfFile: scopePath + "/cpu.stat", encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[0] == "usage_usec", let v = UInt64(parts[1]) { return v }
        }
        return 0
    }

    static func writeFile(_ path: String, _ contents: String) -> Bool {
        let fd = open(path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return contents.withCString { write(fd, $0, strlen($0)) } > 0
    }

    static func readTrimmed(_ path: String) -> String {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fcntlNonBlocking(_ fd: Int32) -> Int32 {
        let flags = fcntl(fd, F_GETFL, 0)
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    static func waitpidRetry(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return status
    }

    static func exitCode(from status: Int32) -> Int32 {
        if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }

    static func wasSignalled(_ status: Int32) -> Bool {
        let t = status & 0x7f
        return t != 0 && t != 0x7f
    }

    static func nowMillis() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000 + Int64(ts.tv_nsec) / 1_000_000
    }
}
#else

extension LinuxDelegatedCgroupSupervisor {
    /// Non-Linux hosts have no delegated cgroup-v2 authority. This fails closed by design: relabeling an
    /// advisory macOS boundary as hard containment is exactly the forgery this architecture prevents.
    public static func runContained(config: Config, launchPath: String, argv: [String],
                                    environment: [String: String], cwd: String,
                                    timeoutSeconds: Int) throws -> (RunResult, HardProcessContainmentReceipt) {
        throw SupervisorError.unavailable(
            "delegated cgroup-v2 containment is unavailable off Linux; hard containment cannot be manufactured on this host")
    }
}
#endif
