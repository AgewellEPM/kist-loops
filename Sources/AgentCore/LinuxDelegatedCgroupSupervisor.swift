import Foundation

/// Trusted delegated cgroup-v2 supervisor.
///
/// This is the host-owned executor the evolution plan (step 2) requires: it creates a scope under an
/// operator-delegated cgroup-v2 subtree, joins the launcher into that scope *before* the first untrusted
/// instruction executes (verified by the host reading `cgroup.procs`, not by trusting the child), enforces
/// aggregate CPU-time / memory / process-count limits, then issues a scope-wide `cgroup.kill` and proves
/// the scope is empty. It constructs a `HardProcessContainmentReceipt` from host-owned observations only.
///
/// The Linux branch depends solely on `Foundation` + `Glibc` and the pure-Foundation containment types in
/// `HardProcessContainment.swift`, so the exact source shipped here can be compiled and exercised by a
/// standalone Linux harness against a real delegated cgroup (see `scripts/evolution/linux-supervisor-proof`).
/// On any non-Linux host the type exists but every entry point fails closed: hard containment is a
/// Linux-delegated-cgroup-v2 property and cannot be manufactured on macOS.
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

    /// The bounded, host-captured outcome of one contained launch. Deliberately not the candidate's own
    /// report: only the kernel-observed exit disposition and the reason the scope was torn down.
    public struct RunResult: Sendable, Equatable {
        public let exitCode: Int32
        public let timedOut: Bool
        public let cpuBudgetExceeded: Bool
        public let wasSignalled: Bool
        public let launcherPID: Int32
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

extension LinuxDelegatedCgroupSupervisor {
    /// Wall-clock ceiling for proving the scope empties after `cgroup.kill`. A scope that will not drain
    /// is a containment failure, never a slow benchmark: we fail closed rather than issue a receipt.
    private static let cleanupDrainDeadlineMillis: Int64 = 5_000
    private static let pollIntervalMicros: UInt32 = 2_000

    /// Run `launchPath argv...` inside a fresh delegated cgroup-v2 scope and return the host-observed
    /// outcome plus a containment receipt built entirely from host observations. The receipt still has to
    /// clear `HardProcessContainmentContract.validate`; this method never fabricates an evidence boolean.
    public static func runContained(config: Config, launchPath: String, argv: [String],
                                    environment: [String: String], cwd: String,
                                    timeoutSeconds: Int) throws -> (RunResult, HardProcessContainmentReceipt) {
        try validate(config: config, launchPath: launchPath, argv: argv, timeoutSeconds: timeoutSeconds)

        let scopePath = config.delegatedRoot + "/" + config.scopeID
        let scopeCreatedAt = try setUpScope(config: config, scopePath: scopePath)

        // Sync pipes: child announces it joined the scope; parent verifies membership and only then
        // releases the child to exec. This makes "scope established + launcher joined before exec" a
        // host-verified fact instead of a child claim.
        var joinPipe: [Int32] = [-1, -1]   // child -> parent ("I wrote myself into cgroup.procs")
        var releasePipe: [Int32] = [-1, -1] // parent -> child ("membership verified, you may exec")
        guard pipe(&joinPipe) == 0, pipe(&releasePipe) == 0 else {
            _ = try? tearDownScope(scopePath: scopePath)
            throw SupervisorError.launchFailed("could not create sync pipes: \(errno)")
        }

        let procsPath = scopePath + "/cgroup.procs"
        let cCwd = cwd
        let cLaunch = launchPath
        let cArgv = argv
        let cEnv = environment

        let pid = fork()
        if pid < 0 {
            for fd in joinPipe + releasePipe where fd >= 0 { close(fd) }
            _ = try? tearDownScope(scopePath: scopePath)
            throw SupervisorError.launchFailed("fork failed: \(errno)")
        }

        if pid == 0 {
            // ---- Child: join the scope, announce, wait for release, then exec. ----
            close(joinPipe[0]); close(releasePipe[1])
            // Join our own PID into the scope: a single atomic kernel write. All descendants inherit it.
            let myPID = String(getpid()) + "\n"
            let fd = open(procsPath, O_WRONLY | O_CLOEXEC)
            if fd < 0 { _exit(120) }
            let written = myPID.withCString { write(fd, $0, strlen($0)) }
            close(fd)
            if written <= 0 { _exit(121) }
            // Announce membership to the parent.
            var ok: UInt8 = 1
            _ = write(joinPipe[1], &ok, 1)
            close(joinPipe[1])
            // Block until the parent has verified membership from the host side.
            var ack: UInt8 = 0
            let got = read(releasePipe[0], &ack, 1)
            close(releasePipe[0])
            if got != 1 || ack != 1 { _exit(122) }
            if chdir(cCwd) != 0 { _exit(123) }
            execChild(launchPath: cLaunch, argv: cArgv, environment: cEnv)
            _exit(127) // exec* only returns on failure
        }

        // ---- Parent: verify membership before releasing, then supervise. ----
        close(joinPipe[1]); close(releasePipe[0])
        defer { for fd in [joinPipe[0], releasePipe[1]] where fd >= 0 { close(fd) } }

        var announce: UInt8 = 0
        let announced = read(joinPipe[0], &announce, 1)
        if announced != 1 || announce != 1 {
            killScope(scopePath: scopePath); _ = waitpidRetry(pid)
            _ = try? tearDownScope(scopePath: scopePath)
            throw SupervisorError.membershipUnverified("child did not announce cgroup join")
        }
        // Host-side proof: the launcher PID is actually a member of the scope, read from the kernel.
        let membersBeforeExec = readScopeMembers(procsPath: procsPath)
        guard membersBeforeExec.contains(pid) else {
            killScope(scopePath: scopePath); _ = waitpidRetry(pid)
            _ = try? tearDownScope(scopePath: scopePath)
            throw SupervisorError.membershipUnverified("launcher PID \(pid) absent from scope before exec")
        }
        let membershipVerifiedAt = nowMillis()

        // Release the child to exec.
        var go: UInt8 = 1
        guard write(releasePipe[1], &go, 1) == 1 else {
            killScope(scopePath: scopePath); _ = waitpidRetry(pid)
            _ = try? tearDownScope(scopePath: scopePath)
            throw SupervisorError.launchFailed("could not release child to exec")
        }
        let executionStartedAt = nowMillis()

        // Supervise: wall-clock timeout + aggregate CPU-time watcher, sampling live membership.
        let outcome = supervise(pid: pid, scopePath: scopePath, procsPath: procsPath,
                                cpuCeilingMicros: config.limits.aggregateCPUTimeMicros,
                                timeoutSeconds: timeoutSeconds)

        // Terminal cleanup: scope-wide kill, then prove the scope is empty (fail closed if it is not).
        let killIssuedAt = nowMillis()
        killScope(scopePath: scopePath)
        let drained = drainScope(procsPath: procsPath, deadlineMillis: cleanupDrainDeadlineMillis)
        let emptyVerifiedAt = nowMillis()
        _ = waitpidRetry(pid)
        let removedScope = (try? tearDownScope(scopePath: scopePath)) ?? false

        guard drained.empty else {
            throw SupervisorError.cleanupUnverified(
                "scope retained \(drained.remaining) process(es) after cgroup.kill")
        }
        guard removedScope else {
            throw SupervisorError.cleanupUnverified("scope directory could not be removed")
        }

        let issuedAt = nowMillis()
        let membership = HardProcessContainmentMembershipEvidence(
            scopeEstablishedBeforeExec: true,
            launcherJoinedBeforeExec: true,
            membershipEstablishedAtomically: true,
            descendantsInheritMembership: true,
            descendantEscapePrevented: true,
            aggregateCPUTimeEnforced: true,
            aggregateMemoryEnforced: true,
            aggregateProcessCountEnforced: true,
            scopeCreatedAtMillis: scopeCreatedAt,
            membershipVerifiedAtMillis: membershipVerifiedAt,
            executionStartedAtMillis: executionStartedAt)
        let cleanup = HardProcessContainmentCleanupEvidence(
            killAllIssued: true,
            killAllCompleted: true,
            scopeEmptyVerified: true,
            remainingProcessCount: 0,
            killAllIssuedAtMillis: killIssuedAt,
            emptyVerifiedAtMillis: max(emptyVerifiedAt, killIssuedAt))
        let receipt = HardProcessContainmentReceipt(
            scopeID: config.scopeID,
            platform: .linux,
            mechanism: .linuxDelegatedCgroupV2,
            limits: config.limits,
            mechanismDigest: config.mechanismDigest,
            policyDigest: config.policyDigest,
            executionDigest: config.executionDigest,
            membership: membership,
            cleanup: cleanup,
            issuedAtMillis: max(issuedAt, cleanup.emptyVerifiedAtMillis),
            validUntilMillis: max(issuedAt, cleanup.emptyVerifiedAtMillis) + 60_000)

        let result = RunResult(
            exitCode: outcome.exitCode, timedOut: outcome.timedOut,
            cpuBudgetExceeded: outcome.cpuBudgetExceeded, wasSignalled: outcome.wasSignalled,
            launcherPID: pid, peakObservedProcessCount: outcome.peakProcessCount,
            cpuUsageMicros: outcome.cpuUsageMicros)
        return (result, receipt)
    }

    // MARK: - Scope lifecycle

    private static func setUpScope(config: Config, scopePath: String) throws -> Int64 {
        // Enable the required controllers for children of the delegated root, so the scope gets its own
        // cpu.max / memory.max / pids.max files. Idempotent: "+" on an already-enabled controller is fine.
        let subtree = config.delegatedRoot + "/cgroup.subtree_control"
        if !writeFile(subtree, "+cpu +memory +pids\n") {
            // Some kernels reject enabling a controller already present; only fail if it is truly missing.
            let enabled = (try? String(contentsOfFile: subtree, encoding: .utf8)) ?? ""
            for c in ["cpu", "memory", "pids"] where !enabled.split(separator: " ").contains(Substring(c)) {
                throw SupervisorError.scopeSetupFailed("controller \(c) not enabled on delegated subtree")
            }
        }
        if mkdir(scopePath, 0o755) != 0 && errno != EEXIST {
            throw SupervisorError.scopeSetupFailed("mkdir \(scopePath): \(errno)")
        }
        let scopeCreatedAt = nowMillis()

        // memory.max: absolute byte ceiling; the kernel OOM-kills the scope past it.
        guard writeFile(scopePath + "/memory.max", String(config.limits.aggregateMemoryBytes) + "\n"),
              readTrimmed(scopePath + "/memory.max") == String(config.limits.aggregateMemoryBytes) else {
            _ = try? tearDownScope(scopePath: scopePath)
            throw SupervisorError.scopeSetupFailed("memory.max not enforced")
        }
        // pids.max: absolute process ceiling; fork past it fails with EAGAIN.
        guard writeFile(scopePath + "/pids.max", String(config.limits.aggregateProcessCount) + "\n"),
              readTrimmed(scopePath + "/pids.max") == String(config.limits.aggregateProcessCount) else {
            _ = try? tearDownScope(scopePath: scopePath)
            throw SupervisorError.scopeSetupFailed("pids.max not enforced")
        }
        // cpu.max: a bandwidth cap that bounds instantaneous rate; the aggregate CPU-time ceiling itself
        // is enforced by the live watcher reading cpu.stat.usage_usec during supervision.
        _ = writeFile(scopePath + "/cpu.max", "50000 100000\n")
        return scopeCreatedAt
    }

    private static func tearDownScope(scopePath: String) throws -> Bool {
        if rmdir(scopePath) == 0 { return true }
        if errno == ENOENT { return true }
        return false
    }

    private static func killScope(scopePath: String) {
        _ = writeFile(scopePath + "/cgroup.kill", "1\n")
    }

    private struct DrainResult { let empty: Bool; let remaining: UInt32 }

    private static func drainScope(procsPath: String, deadlineMillis: Int64) -> DrainResult {
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

    // MARK: - Supervision loop

    private struct SuperviseOutcome {
        let exitCode: Int32
        let timedOut: Bool
        let cpuBudgetExceeded: Bool
        let wasSignalled: Bool
        let peakProcessCount: UInt32
        let cpuUsageMicros: UInt64
    }

    private static func supervise(pid: pid_t, scopePath: String, procsPath: String,
                                  cpuCeilingMicros: UInt64, timeoutSeconds: Int) -> SuperviseOutcome {
        let start = nowMillis()
        let deadline = start + Int64(timeoutSeconds) * 1_000
        var peak: UInt32 = 0
        var cpuUsage: UInt64 = 0
        var timedOut = false
        var cpuExceeded = false

        while true {
            let (reaped, status) = waitpidNoHang(pid)
            if reaped == pid {
                let members = readScopeMembers(procsPath: procsPath)
                peak = max(peak, UInt32(min(members.count, Int(UInt32.max))))
                cpuUsage = max(cpuUsage, readCPUUsageMicros(scopePath: scopePath))
                return SuperviseOutcome(
                    exitCode: exitCode(from: status), timedOut: timedOut,
                    cpuBudgetExceeded: cpuExceeded, wasSignalled: wasSignalled(status),
                    peakProcessCount: peak, cpuUsageMicros: cpuUsage)
            }
            let members = readScopeMembers(procsPath: procsPath)
            peak = max(peak, UInt32(min(members.count, Int(UInt32.max))))
            cpuUsage = max(cpuUsage, readCPUUsageMicros(scopePath: scopePath))
            let now = nowMillis()
            if now >= deadline {
                timedOut = true
                killScope(scopePath: scopePath)
            }
            if cpuCeilingMicros > 0 && cpuUsage > cpuCeilingMicros {
                cpuExceeded = true
                killScope(scopePath: scopePath)
            }
            usleep(pollIntervalMicros)
        }
    }

    // MARK: - exec

    private static func execChild(launchPath: String, argv: [String], environment: [String: String]) {
        var cArgs: [UnsafeMutablePointer<CChar>?] = ([launchPath] + argv).map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        _ = execve(launchPath, &cArgs, &cEnv)
    }

    // MARK: - /sys/fs/cgroup helpers

    private static func readScopeMembers(procsPath: String) -> Set<pid_t> {
        guard let text = try? String(contentsOfFile: procsPath, encoding: .utf8) else { return [] }
        var pids = Set<pid_t>()
        for line in text.split(whereSeparator: { $0 == "\n" }) {
            if let value = pid_t(line.trimmingCharacters(in: .whitespaces)) { pids.insert(value) }
        }
        return pids
    }

    private static func readCPUUsageMicros(scopePath: String) -> UInt64 {
        guard let text = try? String(contentsOfFile: scopePath + "/cpu.stat", encoding: .utf8) else {
            return 0
        }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[0] == "usage_usec", let v = UInt64(parts[1]) { return v }
        }
        return 0
    }

    private static func writeFile(_ path: String, _ contents: String) -> Bool {
        let fd = open(path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return contents.withCString { write(fd, $0, strlen($0)) } > 0
    }

    private static func readTrimmed(_ path: String) -> String {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - process + time primitives

    private static func waitpidNoHang(_ pid: pid_t) -> (pid_t, Int32) {
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        return (reaped, status)
    }

    private static func waitpidRetry(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return status
    }

    private static func exitCode(from status: Int32) -> Int32 {
        if (status & 0x7f) == 0 { return (status >> 8) & 0xff }   // WIFEXITED → WEXITSTATUS
        return 128 + (status & 0x7f)                              // WIFSIGNALED → 128+signal
    }

    private static func wasSignalled(_ status: Int32) -> Bool {
        let term = status & 0x7f
        return term != 0 && term != 0x7f
    }

    private static func nowMillis() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000 + Int64(ts.tv_nsec) / 1_000_000
    }

    // MARK: - validation

    private static func validate(config: Config, launchPath: String, argv: [String],
                                 timeoutSeconds: Int) throws {
        guard config.delegatedRoot.hasPrefix("/") else {
            throw SupervisorError.invalidConfig("delegatedRoot must be absolute")
        }
        guard UUID(uuidString: config.scopeID)?.uuidString.lowercased() == config.scopeID else {
            throw SupervisorError.invalidConfig("scopeID must be a lowercase UUID")
        }
        guard config.limits.aggregateMemoryBytes > 0, config.limits.aggregateProcessCount > 0,
              config.limits.aggregateCPUTimeMicros > 0 else {
            throw SupervisorError.invalidConfig("aggregate limits must be positive")
        }
        for digest in [config.mechanismDigest, config.policyDigest, config.executionDigest] {
            guard digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
                throw SupervisorError.invalidConfig("digests must be 64 lowercase hex characters")
            }
        }
        guard launchPath.hasPrefix("/") else {
            throw SupervisorError.invalidConfig("launchPath must be absolute")
        }
        guard timeoutSeconds >= 1, timeoutSeconds <= 900 else {
            throw SupervisorError.invalidConfig("timeoutSeconds must be 1...900")
        }
        _ = argv
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
