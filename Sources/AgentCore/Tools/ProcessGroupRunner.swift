import Foundation
import Crypto   // apple/swift-crypto — cross-platform CryptoKit API (BoringSSL-backed on Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Spawn a child in its OWN process group and tear down the WHOLE group on timeout, output
/// cap, or normal return — so a forked grandchild (`sh -c "sleep 30 &"`) can't orphan past
/// the tool call. This closes the RunCommandTool KNOWN RESIDUAL where `terminate()` signalled
/// only the direct child PID.
///
/// How: `posix_spawn` with `POSIX_SPAWN_SETPGROUP` + pgroup `0` makes the child the leader of
/// a new group whose PGID == its PID, set atomically pre-exec (no setpgid race). Teardown is
/// `killpg(pgid, SIGTERM)` → grace → `killpg(pgid, SIGKILL)`, which reaches every descendant
/// still in the group. stdout/stderr are drained on two concurrent threads (no full-pipe
/// deadlock) into a byte-capped collector.
///
/// Cross-platform: Darwin and Glibc expose the same `<spawn.h>`/`<signal.h>` surface; the only
/// platform seam is the import above and the `Int16(...)` flags cast (Darwin's `setflags` arg
/// is a `short`). `WIFEXITED`/`WEXITSTATUS`/`WTERMSIG` are C macros not imported into Swift, so
/// the status bit math is reimplemented below.
///
/// KNOWN RESIDUAL (documented, not papered over): a descendant that calls `setsid()`/`daemon()`
/// deliberately leaves the process group and survives `killpg`. Acceptable for a shell-exec
/// tool; the race-free upgrade for untrusted/fork-heavy workloads is a cgroup-v2 `cgroup.kill`
/// or a PID-namespace whose PID 1 is reaped (future hardening tier).
enum ProcessGroupRunner {

    struct Outcome: Sendable {
        let combined: String     // stdout then stderr, each capped per-stream
        let exitCode: Int32      // process exit code, or 128+signal if signalled
        let timedOut: Bool
        // Separated streams (same capped bytes the combined text is built from). Defaulted so
        // the many pre-existing error-path `Outcome(combined:exitCode:timedOut:)` returns keep
        // compiling unchanged; only the success path fills them in.
        var stdout: String = ""
        var stderr: String = ""
        /// Raw captured counts survive invalid UTF-8 conversion.
        var stdoutByteCount: Int = 0
        var stderrByteCount: Int = 0
        /// True when the child was terminated BY A SIGNAL (WIFSIGNALED) — `exitCode` is then 128+signal.
        /// This is the real signature of an OS-sandbox / resource-limit kill (SIGKILL/SIGXCPU/SIGSEGV/…),
        /// distinct from a clean non-zero exit like `which`/`grep`/`test` returning 1 with no output.
        var wasSignalled: Bool = false
        /// Per-stream capture truth. Reaching a stream cap is reported conservatively as truncation,
        /// even when the cap callback tears the process group down before another byte is observed.
        var stdoutTruncated: Bool = false
        var stderrTruncated: Bool = false
        /// True when either stream reached its cap or the joined stdout+stderr view exceeded the
        /// aggregate output budget and was shortened.
        var outputTruncated: Bool = false
        var stdoutDigest: String = BuilderEvidenceDigest.sha256("")
        var stderrDigest: String = BuilderEvidenceDigest.sha256("")
        var effectiveLauncherDigest: String = BuilderEvidenceDigest.sha256("")
        var effectiveEnvironmentDigest: String = BuilderEvidenceDigest.sha256("")
        var sandboxProfileDigest: String? = nil
        var trustedCommandReference: BuilderTrustedCommandReference? = nil
        /// The caller revoked the invocation while it was running. Distinct from a wall timeout.
        var cancelled: Bool = false
    }

    /// Blocking — call OFF the main actor (RunCommandTool wraps it in a continuation on a
    /// background queue). `env` is the already-scrubbed child environment.
    /// `stdinData`: optional bytes for the child's stdin. Staged pre-spawn into an unlinked
    /// owner-private 0600 file (never a pipe), so a slow/non-reading child can't wedge the
    /// parent on a pipe write and there is no SIGPIPE surface. nil → stdin ← /dev/null (the
    /// previous behavior for every existing call site).
    static func run(launchPath: String,
                    launchArgs: [String],
                    cwd: String,
                    env: [String: String],
                    timeoutSeconds: Int,
                    capPerStream: Int,
                    graceSeconds: Int = 2,
                    stdinData: Data? = nil,
                    stdinByteLimit: Int = 16 * 1_024 * 1_024,
                    telemetrySink: BuilderTrustedCommandSink? = nil,
                    requestedArgumentsDigest: String? = nil,
                    cancellationCheck: @Sendable () -> Bool = { false }) -> Outcome {

        let telemetryStarted = DispatchTime.now().uptimeNanoseconds
        let inputDigest = stdinData.map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        } ?? SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let requestedDigest = requestedArgumentsDigest ?? BuilderEvidenceDigest.sha256(
            ([launchPath] + launchArgs + [cwd, inputDigest, String(stdinData?.count ?? 0)])
                .joined(separator: "\u{0}"))
        var effectiveLaunchPath = launchPath
        var effectiveLaunchArgs = launchArgs
        var effectiveCWD = cwd
        var effectiveEnvironment = env
        var effectiveEnvironmentDigest = environmentDigest(env)
        var sandboxProfileDigest: String?
        func launcherDigest() -> String {
            return BuilderEvidenceDigest.sha256(
                (["kist.builder.effective-launch.v1", effectiveLaunchPath]
                 + effectiveLaunchArgs
                 + [effectiveCWD, effectiveEnvironmentDigest,
                    sandboxProfileDigest ?? "unsandboxed", String(timeoutSeconds),
                    String(capPerStream), String(graceSeconds), String(stdinByteLimit)])
                    .joined(separator: "\u{0}"))
        }
        func observed(_ original: Outcome) -> Outcome {
            var outcome = original
            let elapsed = DispatchTime.now().uptimeNanoseconds &- telemetryStarted
            outcome.effectiveLauncherDigest = launcherDigest()
            outcome.effectiveEnvironmentDigest = effectiveEnvironmentDigest
            outcome.sandboxProfileDigest = sandboxProfileDigest
            outcome.trustedCommandReference = BuilderTrustedTelemetry.recordCommand(
                sink: telemetrySink, requestedArgumentsDigest: requestedDigest,
                outcome: outcome, elapsedMilliseconds: max(1, Int(elapsed / 1_000_000)))
            return outcome
        }

        let prepared: BuilderSandboxPreparedLaunch?
        do {
            prepared = try BuilderOSProcessSandboxAttestor.preparedLaunch(
                launchPath: launchPath, launchArgs: launchArgs, cwd: cwd,
                environment: env)
        } catch {
            return observed(Outcome(combined: "Builder OS sandbox refused subprocess: \(error.localizedDescription)",
                                    exitCode: -1, timedOut: false))
        }
        effectiveLaunchPath = prepared?.launchPath ?? launchPath
        effectiveLaunchArgs = prepared?.launchArgs ?? launchArgs
        effectiveCWD = prepared?.cwd ?? cwd
        effectiveEnvironment = prepared?.environment ?? env
        effectiveEnvironmentDigest = prepared?.environmentDigest
            ?? environmentDigest(effectiveEnvironment)
        sandboxProfileDigest = prepared?.sandboxProfileDigest

        // --- staged stdin (before any pipe so one defer covers every exit path) ---
        guard let stdinFD = Self.stagedInputDescriptor(stdinData, byteLimit: stdinByteLimit) else {
            return observed(Outcome(combined: "stdin exceeds its byte limit or could not be staged",
                                    exitCode: -1, timedOut: false))
        }
        defer { if stdinFD >= 0 { close(stdinFD) } }

        // --- pipes (parent reads [0], child writes [1]) ---
        // Split so a failure of the 2nd/3rd pipe() closes the already-opened fds (no leak).
        var outFds: [Int32] = [-1, -1]
        var errFds: [Int32] = [-1, -1]
        var stopFds: [Int32] = [-1, -1]   // self-pipe to wake drain poll() on shutdown
        func pipeFailure() -> Outcome { observed(Outcome(
            combined: "could not create pipe: \(Self.strerr())",
            exitCode: -1, timedOut: false)) }
        guard pipe(&outFds) == 0 else { return pipeFailure() }
        guard pipe(&errFds) == 0 else {
            close(outFds[0]); close(outFds[1]); return pipeFailure()
        }
        guard pipe(&stopFds) == 0 else {
            close(outFds[0]); close(outFds[1]); close(errFds[0]); close(errFds[1]); return pipeFailure()
        }

        // --- file actions: dup write ends onto child stdout/stderr; close all inherited copies ---
        // Darwin imports these opaque types as optional pointers; Glibc as structs.
        #if canImport(Darwin)
        var fa: posix_spawn_file_actions_t? = nil
        #else
        var fa = posix_spawn_file_actions_t()
        #endif
        // Accumulate the first failure of any spawn-setup call. If ANY fails we must NOT
        // launch — a silently-dropped fd-lockdown or process-group action would run the child
        // unconfined / un-killable, defeating the security guarantees.
        var setupErr: Int32 = 0
        func chk(_ rc: Int32) { if setupErr == 0 && rc != 0 { setupErr = rc } }

        // Gate every add*/set* on a SUCCESSFUL *_init — calling them on an uninitialized
        // object is undefined behavior. The defer below only destroys what was initialized.
        let faInitRC = posix_spawn_file_actions_init(&fa)
        let faInited = faInitRC == 0
        chk(faInitRC)
        if faInited {
            // Lock down the child's fd table so NOTHING the long-lived parent has open (a log
            // file, a provider socket, any other writable fd) leaks into the spawned command —
            // an inherited fd would BYPASS the Seatbelt sandbox, whose kernel enforcement is
            // acquisition-time (a pre-opened fd/socket stays usable). Actions run in order:
            // stdin ← staged bytes or /dev/null, stdout/stderr → our pipes, then close everything ≥ 3
            // (which also closes our own pipe read/write ends and the stop self-pipe in the child).
            if stdinFD >= 0 {
                chk(posix_spawn_file_actions_adddup2(&fa, stdinFD, 0))
            } else {
                chk("/dev/null".withCString { posix_spawn_file_actions_addopen(&fa, 0, $0, O_RDONLY, 0) })
            }
            chk(posix_spawn_file_actions_adddup2(&fa, outFds[1], 1))
            chk(posix_spawn_file_actions_adddup2(&fa, errFds[1], 2))
            #if !canImport(Darwin)
            // Linux/glibc (2.34+): explicitly close every inherited fd ≥ 3. (Darwin uses the
            // POSIX_SPAWN_CLOEXEC_DEFAULT attr flag below instead — addclosefrom_np isn't on its SDK.)
            chk(posix_spawn_file_actions_addclosefrom_np(&fa, 3))
            #endif
            // Confined cwd (validated by the caller). addchdir_np: macOS 10.15+, glibc 2.29+.
            chk(effectiveCWD.withCString { posix_spawn_file_actions_addchdir_np(&fa, $0) })
        }

        // --- attributes: new process group, leader == child PID ---
        #if canImport(Darwin)
        var attr: posix_spawnattr_t? = nil
        #else
        var attr = posix_spawnattr_t()
        #endif
        let attrInitRC = posix_spawnattr_init(&attr)
        let attrInited = attrInitRC == 0
        chk(attrInitRC)
        if attrInited {
            chk(posix_spawnattr_setpgroup(&attr, 0))
            #if canImport(Darwin)
            // POSIX_SPAWN_CLOEXEC_DEFAULT (Darwin): every inherited fd is closed at exec except
            // those set by file actions (our /dev/null stdin + stdout/stderr pipes) — the fd
            // lockdown that stops a parent fd/socket from bypassing the Seatbelt sandbox.
            chk(posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)))
            #else
            chk(posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP)))
            #endif
        }

        // --- argv / envp (NULL-terminated C arrays) ---
        var argv: [UnsafeMutablePointer<CChar>?] = ([effectiveLaunchPath] + effectiveLaunchArgs).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = effectiveEnvironment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
            if faInited { posix_spawn_file_actions_destroy(&fa) }
            if attrInited { posix_spawnattr_destroy(&attr) }
        }

        // Fail CLOSED if any setup action failed — never launch a partially-configured child.
        guard setupErr == 0 else {
            close(outFds[0]); close(outFds[1]); close(errFds[0]); close(errFds[1])
            close(stopFds[0]); close(stopFds[1])
            return observed(Outcome(combined: "spawn setup failed: \(String(cString: strerror(setupErr)))",
                                    exitCode: -1, timedOut: false))
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, effectiveLaunchPath, &fa, &attr, argv, envp)   // returns errno DIRECTLY
        // Parent must close its copy of the write ends or reads never see EOF.
        close(outFds[1]); close(errFds[1])
        guard rc == 0 else {
            close(outFds[0]); close(errFds[0]); close(stopFds[0]); close(stopFds[1])
            return observed(Outcome(combined: "could not launch \(effectiveLaunchPath): \(String(cString: strerror(rc)))",
                                    exitCode: -1, timedOut: false))
        }
        let pgid = pid   // we made the child its own group leader

        // --- concurrent drains (main owns the read fds) feeding the capped collector ---
        // GroupKiller guards every killpg behind a "still ours" flag so no signal can ever
        // target a recycled PGID (the leader's PGID is reusable the instant it is reaped).
        let killer = GroupKiller(pgid)
        let collector = BoundedOutputCollector(capPerStream: capPerStream) {
            killer.kill(SIGTERM)   // runaway output → tear the group down
        }
        let drains = DispatchGroup()
        Self.drain(outFds[0], stop: stopFds[0], into: { collector.appendOut($0) }, group: drains)
        Self.drain(errFds[0], stop: stopFds[0], into: { collector.appendErr($0) }, group: drains)

        // --- detect leader exit WITHOUT reaping (waitid + WNOWAIT): the un-reaped zombie
        //     keeps the PGID RESERVED through teardown, so the group sweep below is
        //     guaranteed to hit only our group, never a recycled PGID. We record waitid's
        //     result — if it FAILED (e.g. ECHILD because a host SIGCHLD=SIG_IGN/SA_NOCLDWAIT
        //     auto-reaped the child), there is NO zombie reserving the PGID. ---
        let exited = DispatchSemaphore(value: 0)
        let detect = DetectBox()
        DispatchQueue.global(qos: .userInitiated).async {
            var info = siginfo_t()
            var r: Int32
            repeat { r = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while r == -1 && errno == EINTR
            detect.set(r)
            exited.signal()
        }

        // True while the leader is still alive OR an un-reaped zombie — i.e. it still RESERVES
        // the PGID, so `killpg` is guaranteed to hit only our group. False only if the leader
        // is gone/auto-reaped (ECHILD), where the PGID may be recycled. (Non-reaping probe.)
        func leaderReservesPGID() -> Bool {
            var info = siginfo_t()
            let r = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG)
            return !(r == -1 && errno == ECHILD)
        }

        var timedOut = false
        var cancelled = false
        let wallDeadline = DispatchTime.now() + .seconds(timeoutSeconds)
        while true {
            if exited.wait(timeout: .now() + .milliseconds(50)) == .success { break }
            if cancellationCheck() {
                cancelled = true
                break
            }
            if DispatchTime.now() >= wallDeadline {
                timedOut = true
                break
            }
        }
        if timedOut || cancelled {
            // Gate each kill on the leader still reserving the PGID. For a normal host this is
            // always true here (the un-detected child is alive); the guard only matters under a
            // SIGCHLD=SIG_IGN auto-reap racing the timeout, where it avoids a recycled-PGID kill.
            if leaderReservesPGID() { killer.kill(SIGTERM) }
            if exited.wait(timeout: .now() + .seconds(graceSeconds)) == .timedOut {
                if leaderReservesPGID() { killer.kill(SIGKILL) }
                exited.wait()                                     // leader now a zombie (or ECHILD)
            }
        }

        // Give legitimate late-flushing children (e.g. the swiftc processes under `swift test`) a
        // bounded grace to FINISH WRITING before the runaway-reaping SIGKILL. Otherwise their stderr —
        // the compile errors — is lost to the group teardown, which blinded the agent to build/test
        // FAILURES while it still saw successes on stdout (dogfood finding). If the drains reach EOF
        // within the grace, every group member has exited and closed its pipe end → nothing to reap.
        // Only a child STILL holding the pipe past the grace is a real lingering member → THEN SIGKILL to
        // reap it. Adds ZERO latency to the normal case (all children exit with the leader → instant EOF);
        // the timeout path above already killed hard. Gated on detect.rc == 0 (a real zombie reserves the
        // PGID) exactly as before, so no signal can hit a recycled PGID.
        let drainedCleanly = drains.wait(timeout: .now() + .seconds(graceSeconds)) == .success
        if !drainedCleanly, detect.rc == 0 {
            killer.kill(SIGKILL)
        }

        // DISARM BEFORE reaping. The un-reaped zombie still reserves the PGID right now, so
        // disarming here closes the window where a late output-cap callback (on a drain
        // thread) could `killpg` the PGID AFTER waitpid frees it for reuse. After disarm no
        // signal can fire; the reap then frees the PGID with nothing left to target it.
        killer.disarm()

        // Reap the leader (consumes the zombie, yields the wait status). Track whether we
        // actually reaped: under a host SIGCHLD=SIG_IGN/SA_NOCLDWAIT the child is auto-reaped
        // and waitpid returns -1/ECHILD — in that case we have NO status and must not report
        // a fabricated exit 0.
        var status: Int32 = 0
        var reaped = false
        while true {
            let w = waitpid(pid, &status, 0)
            if w == pid { reaped = true; break }
            if w == -1 && errno == EINTR { continue }
            break   // -1 / ECHILD (auto-reaped) or other — no usable status
        }

        // Flush the drains. On normal/timeout teardown the group is dead, write ends are
        // closed, and poll() returns EOF promptly. If a setsid-escaped orphan still holds a
        // write end past the bounded wait, signal the self-pipe so the drains' poll() wakes
        // and the threads exit (a portable wakeup — cross-thread close() is NOT reliable on
        // Linux). Main is the sole owner of all read fds.
        if drains.wait(timeout: .now() + .seconds(graceSeconds + 1)) == .timedOut {
            _ = write(stopFds[1], [UInt8(0)], 1)
            drains.wait()
        }
        close(outFds[0]); close(errFds[0]); close(stopFds[0]); close(stopFds[1])

        let streamTruncation = collector.truncationState()
        let streamBytes = collector.byteCounts()
        let streamDigests = collector.fullDigests()
        var combined = collector.combinedText()
        let aggregateTruncated = combined.utf8.count > capPerStream
        if aggregateTruncated {
            // BYTE-accurate truncation. `prefix(capPerStream)` counts Characters (grapheme
            // clusters), NOT bytes — so emoji/multibyte output could retain up to ~4×+ the byte
            // budget while still being flagged truncated, violating the aggregate byte boundary.
            // Truncate the UTF-8 byte view at a valid Unicode scalar boundary and RESERVE the
            // marker's bytes, so the total EMITTED bytes never exceed capPerStream.
            combined = Self.truncateUTF8(combined, toByteBudget: capPerStream, marker: "\n…[output truncated]")
        }
        // If we couldn't reap (auto-reap host config), the exit status is unknown — report a
        // non-zero/unknown code rather than a fabricated success.
        let code: Int32 = reaped ? Self.exitCode(from: status) : -1
        let signalled = reaped && (status & 0x7f) != 0    // WIFSIGNALED (matches exitCode's 128+signal path)
        return observed(Outcome(combined: combined, exitCode: code, timedOut: timedOut,
                       stdout: collector.stdoutText(), stderr: collector.stderrText(),
                       stdoutByteCount: streamBytes.stdout,
                       stderrByteCount: streamBytes.stderr,
                       wasSignalled: signalled,
                       stdoutTruncated: streamTruncation.stdout,
                       stderrTruncated: streamTruncation.stderr,
                       outputTruncated: streamTruncation.stdout || streamTruncation.stderr
                            || aggregateTruncated,
                       stdoutDigest: streamDigests.stdout,
                       stderrDigest: streamDigests.stderr,
                       cancelled: cancelled))
    }

    // MARK: - Internals

    /// Read a pipe fd to EOF on a background thread into `sink`, multiplexed with a `stop`
    /// self-pipe via `poll()` so the thread can be woken reliably on BOTH Darwin and Linux
    /// (cross-thread `close()` is not a portable wakeup for a blocked `read`). The CALLER
    /// owns and closes every fd; this thread closes nothing.
    private static func drain(_ fd: Int32, stop: Int32, into sink: @escaping (Data) -> Void, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            var buf = [UInt8](repeating: 0, count: 65_536)
            while true {
                var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: stop, events: Int16(POLLIN), revents: 0)]
                let pr = poll(&fds, nfds_t(2), -1)
                if pr < 0 { if errno == EINTR { continue }; break }
                if (fds[1].revents & Int16(POLLIN)) != 0 { break }   // shutdown requested
                let rev = fds[0].revents
                if (rev & Int16(POLLIN)) != 0 {
                    let n = read(fd, &buf, buf.count)
                    if n > 0 { sink(buf.withUnsafeBytes { Data($0.prefix(n)) }); continue }
                    if n < 0 && errno == EINTR { continue }
                    break                                           // EOF (0) or error
                }
                if (rev & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                    let n = read(fd, &buf, buf.count)               // drain any final bytes
                    if n > 0 { sink(buf.withUnsafeBytes { Data($0.prefix(n)) }); continue }
                    break
                }
            }
        }
    }

    /// Truncate `text` so the returned string's UTF-8 byte count is `<= byteBudget`, ending in
    /// `marker`. Byte-accurate (NOT `prefix(_:)`, which counts grapheme clusters) and cut on a
    /// valid Unicode scalar boundary so the result is always well-formed UTF-8 — an emoji is
    /// kept whole or dropped whole, never split mid-scalar. The marker's own bytes are reserved
    /// out of the budget, so `content + marker` still fits under `byteBudget`.
    ///
    /// Fail-safe edges:
    /// - If `byteBudget` is smaller than the marker itself, we return a byte-bounded prefix of
    ///   the marker (never exceed the budget) — the caller only reaches here when the raw output
    ///   already blew the (much larger) per-stream cap, so a tiny budget is a degenerate input.
    /// - The empty-content path still emits the marker (subject to the same byte bound).
    static func truncateUTF8(_ text: String, toByteBudget byteBudget: Int, marker: String) -> String {
        let markerBytes = Array(marker.utf8)
        // Degenerate: no room for even the marker → return a byte-bounded marker prefix.
        guard byteBudget >= markerBytes.count else {
            let clamped = max(0, byteBudget)
            return decodeScalarBounded(Array(markerBytes.prefix(clamped)))
        }
        let contentBudget = byteBudget - markerBytes.count
        let contentBytes = Array(text.utf8.prefix(contentBudget))
        return decodeScalarBounded(contentBytes) + marker
    }

    /// Decode a UTF-8 byte prefix, backing off to the last VALID scalar boundary if the prefix
    /// sliced through a multibyte scalar. A UTF-8 continuation byte matches `0b10xxxxxx`; a
    /// scalar's LEAD byte does not — so we drop trailing continuation bytes (and their lead)
    /// until the remaining bytes decode cleanly. Bounded: at most 3 back-offs (max UTF-8 scalar
    /// is 4 bytes) since we only ever cut inside a single scalar.
    private static func decodeScalarBounded(_ bytes: [UInt8]) -> String {
        var slice = bytes[...]
        while !slice.isEmpty {
            if let s = String(bytes: slice, encoding: .utf8) { return s }
            slice = slice.dropLast()   // shed the split scalar one byte at a time
        }
        return ""
    }

    /// Reimplement the `<sys/wait.h>` macros (not imported into Swift): exited → exit code;
    /// signalled → 128 + signal (shell convention).
    private static func exitCode(from status: Int32) -> Int32 {
        if (status & 0x7f) == 0 {            // WIFEXITED
            return (status >> 8) & 0xff      // WEXITSTATUS
        }
        return 128 + (status & 0x7f)         // 128 + WTERMSIG
    }

    private static func environmentDigest(_ environment: [String: String]) -> String {
        BuilderEvidenceDigest.sha256(environment.keys.sorted().map {
            "\($0)=\(environment[$0] ?? "")"
        }.joined(separator: "\u{0}"))
    }

    private static func strerr() -> String { String(cString: strerror(errno)) }

    /// `nil` input means the child gets `/dev/null` and is represented by descriptor -1. Non-nil
    /// input is written before spawn to an unlinked 0600 file, so neither a slow/non-reading child
    /// nor a descendant holding fd 0 open can wedge the parent on a pipe write.
    private static func stagedInputDescriptor(_ data: Data?, byteLimit: Int) -> Int32? {
        guard let data else { return -1 }
        guard byteLimit >= 0, data.count <= byteLimit else { return nil }
        var template = Array("/tmp/kist-process-stdin.XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            let descriptor = mkstemp(base)
            if descriptor >= 0 { _ = unlink(base) }
            return descriptor
        }
        guard fd >= 0 else { return nil }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else { close(fd); return nil }
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            close(fd); return nil
        }
        var offset = 0
        let wroteAll = data.withUnsafeBytes { raw -> Bool in
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
        guard wroteAll, lseek(fd, 0, SEEK_SET) == 0 else { close(fd); return nil }
        return fd
    }
}

/// Serializes `killpg` against reaping: every group signal is gated on `live`, which is
/// cleared (`disarm`) immediately after the leader is reaped. This guarantees no signal is
/// ever sent to the leader's PGID once it becomes reusable — closing the PGID-reuse window
/// for the timeout path, the final sweep, AND a late output-cap callback alike.
private final class GroupKiller: @unchecked Sendable {
    private let pgid: pid_t
    private let lock = NSLock()
    private var live = true
    init(_ pgid: pid_t) { self.pgid = pgid }
    func kill(_ sig: Int32) { lock.lock(); defer { lock.unlock() }; if live { killpg(pgid, sig) } }
    func disarm() { lock.lock(); live = false; lock.unlock() }
}

/// Carries the detector thread's `waitid` return value across the semaphore handoff. The
/// `exited` semaphore provides the happens-before ordering; the lock guards the read/write.
private final class DetectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _rc: Int32 = -1
    func set(_ v: Int32) { lock.lock(); _rc = v; lock.unlock() }
    var rc: Int32 { lock.lock(); defer { lock.unlock() }; return _rc }
}
