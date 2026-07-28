import Foundation

/// Run a command — the highest-risk tool. Two modes, structured-first:
///
///   • STRUCTURED (default, safe): `executable` + `args`. Spawned DIRECTLY (no shell),
///     so the safety gate is un-bypassable — deny/allow are enforced on the RESOLVED
///     absolute binary path the OS execs, not on shell text. `rm${IFS}-rf` / `/tmp/git`
///     tricks don't apply because there is no shell to reinterpret tokens.
///
///   • RAW SHELL (opt-in): `command` + `shell: true`. Runs `/bin/sh -c`, enabling
///     pipes/globs/redirects. The deny-list is only ADVISORY here, so a raw shell
///     command can NEVER be auto-approved — a human/approval handler must say yes
///     (refused outright when none is available, e.g. non-interactive `--yolo`).
///
/// Both modes: cwd CONFINED to the project root; env SCRUBBED to an allow-list (no
/// secrets reach the child); output drained on two concurrent threads into a hard byte
/// cap (bounded memory, no full-pipe deadlock). The child is spawned into its OWN process
/// group (`ProcessGroupRunner`), and the WHOLE group is torn down on timeout, output-cap,
/// AND normal return (`killpg` SIGTERM→grace→SIGKILL) — so a forked grandchild can't
/// orphan past the call.
///
/// KNOWN RESIDUAL: a descendant that calls `setsid()`/`daemon()` deliberately leaves the
/// process group and survives `killpg` (acceptable for a shell-exec tool; cgroup-v2 /
/// PID-namespace is the future hardening tier). The earlier residuals — PID-only kill and
/// string-based path confinement — are now closed (group-kill here; `ConfinedRoot`
/// openat/O_NOFOLLOW for file tools).
public struct RunCommandTool: AgentTool {
    public let name = "run_command"
    public let description = "Run a command. Prefer executable+args (safe); use command+shell:true for pipes/globs (needs approval)."
    public let parameters = [
        ToolParameter(name: "executable", type: "string", description: "Program to run (absolute path or bare name resolved on PATH). Preferred.", required: false),
        ToolParameter(name: "args", type: "array", description: "Arguments for `executable` (no shell interpretation)", required: false),
        ToolParameter(name: "command", type: "string", description: "Raw shell command — requires shell:true and approval", required: false),
        ToolParameter(name: "shell", type: "boolean", description: "Run `command` via /bin/sh -c (enables pipes/globs). Default false.", required: false),
        ToolParameter(name: "cwd", type: "string", description: "Working dir relative to project root (default: root)", required: false),
        ToolParameter(name: "timeout", type: "integer", description: "Timeout in seconds (default 120, max 600)", required: false),
        ToolParameter(name: "cpu_limit", type: "integer", description: "CPU seconds before the child is killed (default: timeout, max 600)", required: false),
        ToolParameter(name: "file_size_limit_mb", type: "integer", description: "Max file size the child may create (default 1024 MB, max 4096)", required: false),
        ToolParameter(name: "memory_limit_mb", type: "integer", description: "Optional virtual-memory limit for platforms whose /bin/sh supports `ulimit -v`", required: false),
        ToolParameter(name: "background", type: "boolean", description: "Run detached and return a job id immediately (for long-running servers/watchers). Poll output with the `job` tool. Default false.", required: false),
    ]
    public init() {}

    /// Max bytes retained PER stream. Worst-case memory ~2×; combined output truncated
    /// to this on return.
    static let maxOutputBytes = 100_000
    static let envAllowlist: Set<String> = ["PATH", "HOME", "USER", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "SHELL", "PWD"]

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let cwd = try context.resolvedPath((arguments["cwd"] as? String) ?? ".", mustExist: true)
        let timeout = min(max(optionalInt("timeout", from: arguments) ?? 120, 1), 600)

        // Resolve execution mode + the (executableURL, argv) to spawn.
        let launchPath: String
        let launchArgs: [String]

        if let exe = arguments["executable"] as? String, !exe.isEmpty {
            // STRUCTURED MODE — resolve the binary, gate on the RESOLVED path, no shell.
            guard let resolved = Self.resolveExecutable(exe, env: Self.scrubbedEnvironment()) else {
                return .failure("executable not found or not executable: \(exe)")
            }
            let exeArgs = (arguments["args"] as? [String]) ?? []
            // Gate on the FULL argv line so argument-bearing deny entries fire.
            if let reason = await context.shell.binaryRefusalReason(resolvedPath: resolved, args: exeArgs) {
                throw ToolError.shellDenied(reason)
            }
            launchPath = resolved
            launchArgs = exeArgs
        } else if let command = arguments["command"] as? String, !command.isEmpty {
            // SAFE PROMOTION: a `command` with NO shell metacharacters needs no shell, so run it as
            // STRUCTURED executable+args — identical safety to the `executable` path (nothing for /bin/sh
            // to reinterpret), and it needs no interactive approval. This unblocks a headless loop that
            // typed `swift build` / `git status` as a raw command: without this, the no-approval refusal
            // ("raw shell requires interactive approval") kills every such cycle and burns the budget.
            if let (exe, exeArgs) = Self.promoteRawToStructured(command) {
                guard let resolved = Self.resolveExecutable(exe, env: Self.scrubbedEnvironment()) else {
                    return .failure("executable not found or not executable: \(exe)")
                }
                if let reason = await context.shell.binaryRefusalReason(resolvedPath: resolved, args: exeArgs) {
                    throw ToolError.shellDenied(reason)
                }
                launchPath = resolved
                launchArgs = exeArgs
            } else {
                // GENUINE RAW SHELL — the command uses shell operators (| && ; > $ ` glob …). Only when
                // explicitly opted in, and only with approval (the deny-list is advisory against arbitrary
                // shell text, so this path can never auto-approve).
                guard (arguments["shell"] as? Bool) == true else {
                    return .failure("raw 'command' with shell operators requires shell:true — or split it into "
                        + "separate run_command calls using executable+args (e.g. run `swift build`, then `swift test`).")
                }
                if let reason = await context.shell.shellStringRefusalReason(for: command) {
                    throw ToolError.shellDenied(reason)
                }
                launchPath = "/bin/sh"
                launchArgs = ["-c", command]
            }
        } else {
            return .failure("provide either 'executable' (+ optional 'args') or 'command' with shell:true")
        }

        // OS-level sandbox tier (opt-in). Wraps the resolved command so the KERNEL enforces
        // network egress-deny + write confinement, on top of the in-process gates. Fails
        // CLOSED if a sandbox was requested but is unavailable on this platform — never
        // silently runs unsandboxed when the caller asked for one.
        let finalPath: String
        let finalArgs: [String]
        switch SeatbeltSandbox.wrap(launchPath: launchPath, args: launchArgs, root: context.projectRoot, policy: context.sandbox, cwd: cwd) {
        case .passthrough:
            finalPath = launchPath; finalArgs = launchArgs
        case .wrapped(let p, let a):
            finalPath = p; finalArgs = a
        case .unavailable(let reason):
            return .failure("OS sandbox required but unavailable: \(reason)")
        }

        let limits = ResourceLimits(
            cpuSeconds: min(max(optionalInt("cpu_limit", from: arguments) ?? timeout, 1), 600),
            fileSizeMB: min(max(optionalInt("file_size_limit_mb", from: arguments) ?? 1024, 1), 4096),
            memoryMB: optionalInt("memory_limit_mb", from: arguments).map { min(max($0, 16), 65_536) }
        )
        let limited = Self.resourceLimitedLaunch(launchPath: finalPath, launchArgs: finalArgs, limits: limits)

        // BACKGROUND: detach and return a job id immediately (dev servers, watchers, long tails). The
        // agent polls output / kills it via the `job` tool. Same resolved+gated+sandboxed command; the
        // timeout doesn't apply (a background job runs until it exits or is killed).
        if (arguments["background"] as? Bool) == true {
            let display = (arguments["executable"] as? String).map { "\($0) \((arguments["args"] as? [String] ?? []).joined(separator: " "))" }
                ?? (arguments["command"] as? String) ?? limited.launchPath
            // Refuse past the concurrent-job cap with a clear message (the store also enforces it as a
            // backstop). Distinguishes "too many jobs" from "process wouldn't launch".
            if BackgroundJobStore.shared.runningCount() >= BackgroundJobStore.maxConcurrentRunning {
                return .failure("background job limit reached (\(BackgroundJobStore.maxConcurrentRunning) running) — stop some with job(action=\"kill\", id=…) before starting more")
            }
            guard let id = BackgroundJobStore.shared.start(launchPath: limited.launchPath, args: limited.launchArgs,
                                                           cwd: cwd, env: Self.scrubbedEnvironment(),
                                                           command: display.trimmingCharacters(in: .whitespaces),
                                                           owner: context.projectRoot) else {
                return .failure("could not start background job")
            }
            return ToolResult(success: true,
                              output: "started background job \(id) — poll it with job(action=\"output\", id=\"\(id)\"), stop with job(action=\"kill\", id=\"\(id)\")",
                              metadata: ["job_id": id, "background": "true"])
        }

        return await Self.spawnAndCollect(
            launchPath: limited.launchPath, launchArgs: limited.launchArgs, cwd: cwd, timeout: timeout
        )
    }

    // MARK: - Spawn + bounded collection

    static func spawnAndCollect(launchPath: String, launchArgs: [String], cwd: String, timeout: Int) async -> ToolResult {
        // ProcessGroupRunner.run blocks (posix_spawn + group teardown + reap), so run it on
        // a background queue and await the outcome.
        let outcome: ProcessGroupRunner.Outcome = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let o = ProcessGroupRunner.run(
                    launchPath: launchPath, launchArgs: launchArgs, cwd: cwd,
                    env: scrubbedEnvironment(), timeoutSeconds: timeout, capPerStream: maxOutputBytes
                )
                cont.resume(returning: o)
            }
        }

        let combined = outcome.combined
        let success = !outcome.timedOut && outcome.exitCode == 0
        // Never leave the agent blind on failure: if a command failed with NO captured output, say WHY it's
        // empty (sandbox/resource kill, or it wrote nothing) and how to see the real error — instead of a
        // bare "exit code N" that gives nothing to diagnose.
        let failError: String?
        if success { failError = nil }
        else if outcome.timedOut { failError = "command timed out after \(timeout)s" }
        else if combined.isEmpty {
            failError = "exit code \(outcome.exitCode) with NO output captured — the process was likely "
                + "terminated by the OS sandbox or a resource limit, or it wrote nothing. If this is a "
                + "build/test, run it DIRECTLY via run_command executable+args (not custom_tool) to see its "
                + "real output."
        } else { failError = "exit code \(outcome.exitCode)" }
        return ToolResult(
            success: success,
            output: combined.isEmpty ? (success ? "(no output)" : "(no output, exit \(outcome.exitCode))") : combined,
            error: failError,
            metadata: ["exit_code": String(outcome.exitCode), "timed_out": String(outcome.timedOut)]
        )
    }

    struct ResourceLimits: Sendable, Equatable {
        let cpuSeconds: Int
        let fileSizeMB: Int
        let memoryMB: Int?
    }

    /// Apply child-only POSIX resource limits without interpolating user-controlled text into
    /// a shell command. The shell script is constant; the checked executable and its args are
    /// passed as argv and reached through `exec "$@"`.
    static func resourceLimitedLaunch(launchPath: String, launchArgs: [String], limits: ResourceLimits) -> (launchPath: String, launchArgs: [String]) {
        var lines = [
            "set -e",
            "ulimit -t \(limits.cpuSeconds)",
            // POSIX sh `ulimit -f` uses 512-byte blocks. Round up from MiB.
            "ulimit -f \(limits.fileSizeMB * 2048)",
        ]
        if let memoryMB = limits.memoryMB {
            // `ulimit -v` is supported by Linux `/bin/sh`; some Darwin shells ignore/refuse it.
            // When the user explicitly requests it, fail closed if the platform cannot apply it.
            lines.append("ulimit -v \(memoryMB * 1024)")
        }
        lines.append("exec \"$@\"")
        return ("/bin/sh", ["-c", lines.joined(separator: "\n"), "agentcore-resource-limits", launchPath] + launchArgs)
    }

    /// Resolve an executable name to an absolute, canonicalized, executable path.
    /// Absolute paths are canonicalized directly; bare names are looked up on the
    /// (scrubbed) PATH. Returns nil if nothing executable is found. Names containing a
    /// relative "/" are rejected (ambiguous; use an absolute path or a bare name).
    static func resolveExecutable(_ exe: String, env: [String: String]) -> String? {
        func canonicalExecutable(_ path: String) -> String? {
            guard let real = ToolContext.canonicalize(path) else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), !isDir.boolValue,
                  FileManager.default.isExecutableFile(atPath: real) else { return nil }
            return real
        }
        if exe.hasPrefix("/") { return canonicalExecutable(exe) }
        if exe.contains("/") { return nil }   // reject relative-with-slash
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            if let resolved = canonicalExecutable(String(dir) + "/" + exe) { return resolved }
        }
        return nil
    }

    /// Shell metacharacters whose presence means the command NEEDS a real shell (so it can't be safely
    /// promoted to structured execution): pipes, redirects, sequencing, subshells, expansion, quoting,
    /// globs, home/expansion, comments, and newlines. NOTE: `=` is deliberately NOT here — it's not a
    /// shell operator inside an argument (`--filter=X`, `--configuration=release` are common build flags),
    /// and env-assignment (`FOO=bar cmd`) is handled separately by rejecting a first token that contains `=`.
    static let shellMetacharacters = CharacterSet(charactersIn: "|&;<>()$`\\\"'*?[]{}~#!\n\r")

    /// If `command` has NO shell metacharacters, tokenize it on whitespace into (executable, args) so it
    /// can run DIRECTLY (no /bin/sh). Returns nil when a real shell is required — the caller then keeps
    /// the raw-shell path (opt-in + approval). Whitespace-splitting is exactly correct here precisely
    /// BECAUSE there are no quotes/metacharacters to honor.
    static func promoteRawToStructured(_ command: String) -> (String, [String])? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.rangeOfCharacter(from: shellMetacharacters) == nil else { return nil }
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let exe = tokens.first else { return nil }
        // `FOO=bar cmd` is a shell env-assignment prefix — the first token isn't an executable. Keep it on
        // the raw-shell path (needs a real shell to apply the assignment) rather than trying to exec `FOO=bar`.
        guard !exe.contains("=") else { return nil }
        return (exe, Array(tokens.dropFirst()))
    }

    static func scrubbedEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in envAllowlist where parent[key] != nil { env[key] = parent[key] }
        return env
    }
}

/// Lock-guarded, byte-capped accumulator for a process's stdout/stderr, fed from
/// `readabilityHandler` callbacks on a background queue. Once either stream hits its
/// cap, further bytes are dropped and `onCapExceeded` fires once (to kill the process).
final class BoundedOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private let cap: Int
    private var capFired = false
    private let onCapExceeded: () -> Void

    init(capPerStream: Int, onCapExceeded: @escaping () -> Void) {
        self.cap = capPerStream
        self.onCapExceeded = onCapExceeded
    }

    func appendOut(_ data: Data) { append(data, to: \.out) }
    func appendErr(_ data: Data) { append(data, to: \.err) }

    private func append(_ data: Data, to keyPath: ReferenceWritableKeyPath<BoundedOutputCollector, Data>) {
        guard !data.isEmpty else { return }
        var fire = false
        lock.lock()
        let current = self[keyPath: keyPath]
        if current.count < cap {
            self[keyPath: keyPath].append(data.prefix(cap - current.count))
        }
        if (out.count >= cap || err.count >= cap), !capFired {
            capFired = true
            fire = true
        }
        lock.unlock()
        if fire { onCapExceeded() }   // outside the lock — never call out under lock
    }

    func combinedText() -> String {
        lock.lock(); defer { lock.unlock() }
        var s = String(data: out, encoding: .utf8) ?? ""
        let e = String(data: err, encoding: .utf8) ?? ""
        if !e.isEmpty { s += (s.isEmpty ? "" : "\n") + e }
        return s
    }

    func stdoutText() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: out, encoding: .utf8) ?? ""
    }

    func stderrText() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: err, encoding: .utf8) ?? ""
    }
}
