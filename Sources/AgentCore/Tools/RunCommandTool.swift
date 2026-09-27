import Foundation
import Crypto

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
    public let description = "Run one executable directly. Use executable, args, cwd, stdin or stdin_path, and allowed_exit_codes; never working_directory. stdin_path is a governed regular file relative to cwd/project root and is passed byte-for-byte without a shell. allowed_exit_codes defaults to [0]; allowed nonzero exits are domain statuses, not build/test proof. Raw command is a manual escape hatch requiring shell:true and approval, and is rejected by PlanExecute."
    public let parameters = [
        ToolParameter(name: "executable", type: "string", description: "Program to run (absolute path or bare name resolved on PATH). Preferred.", required: false),
        ToolParameter(name: "args", type: "array", description: "Arguments for `executable` (no shell interpretation)", required: false),
        ToolParameter(name: "stdin", type: "string", description: "Optional UTF-8 stdin payload passed directly, byte-for-byte (max 1 MiB; unavailable for background jobs)", required: false),
        ToolParameter(name: "stdin_path", type: "string", description: "Optional governed regular file relative to cwd/project root, passed byte-for-byte as stdin (max 1 MiB; mutually exclusive with stdin; unavailable for raw shell/background jobs)", required: false),
        ToolParameter(name: "expected_stdin_sha256", type: "string", description: "Replay-only SHA-256 binding for stdin_path; mismatch refuses execution before spawn", required: false),
        ToolParameter(name: "expected_stdin_byte_count", type: "integer", description: "Replay-only byte-count binding for stdin_path; mismatch refuses execution before spawn", required: false),
        ToolParameter(name: "allowed_exit_codes", type: "array", description: "Accepted exit codes: unique integers 0...255, max 32 (default [0]). Accepted nonzero codes never count as build/test verification.", required: false),
        ToolParameter(name: "command", type: "string", description: "Raw shell command — requires shell:true and approval", required: false),
        ToolParameter(name: "shell", type: "boolean", description: "Run `command` via /bin/sh -c (enables pipes/globs). Default false.", required: false),
        ToolParameter(name: "cwd", type: "string", description: "Working dir relative to project root (default: root)", required: false),
        ToolParameter(name: "timeout", type: "integer", description: "Timeout in seconds (foreground: default 120, max 600; background: default 3600, max 86400)", required: false),
        ToolParameter(name: "cpu_limit", type: "integer", description: "CPU seconds before the child is killed (default: timeout, max 600)", required: false),
        ToolParameter(name: "file_size_limit_mb", type: "integer", description: "Max file size the child may create (default 1024 MB, max 4096)", required: false),
        ToolParameter(name: "memory_limit_mb", type: "integer", description: "Optional virtual-memory limit for platforms whose /bin/sh supports `ulimit -v`", required: false),
        ToolParameter(name: "background", type: "boolean", description: "Run detached and return a job id immediately (for long-running servers/watchers). Poll output with the `job` tool. Default false.", required: false),
    ]
    public init() {}

    /// Max bytes retained PER stream. Worst-case memory ~2×; combined output truncated
    /// to this on return.
    static let maxOutputBytes = 100_000
    static let maxStdinBytes = 1_048_576
    static let maxAllowedExitCodes = 32
    static let envAllowlist: Set<String> = ["PATH", "HOME", "USER", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "SHELL", "PWD"]

    private static func integerExitCode(_ value: Any) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let encoding = String(cString: number.objCType)
        guard encoding != "c", encoding != "B" else { return nil } // Bool / JSON boolean
        let numeric = number.doubleValue
        guard numeric.isFinite, numeric.rounded() == numeric, (0...255).contains(numeric) else { return nil }
        return Int(numeric)
    }

    private static func integerValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if value is Bool { return nil }
        if let value = value as? Int { return value }
        guard let number = value as? NSNumber else { return nil }
        let encoding = String(cString: number.objCType)
        guard encoding != "c", encoding != "B" else { return nil }
        let numeric = number.doubleValue
        guard numeric.isFinite, numeric.rounded() == numeric,
              numeric >= Double(Int.min), numeric <= Double(Int.max) else { return nil }
        return Int(numeric)
    }

    /// Shared by PlanExecute preflight and live execution. Plans are intentionally stricter than
    /// direct/manual calls: arbitrary shell text is never repaired by tokenizing it into argv.
    static func argumentValidationIssue(_ arguments: [String: Any], planPreflight: Bool) -> String? {
        if arguments["working_directory"] != nil {
            return "'working_directory' is not supported; use 'cwd'"
        }
        if planPreflight {
            let canonicalKeys: Set<String> = [
                "executable", "args", "cwd", "stdin", "stdin_path", "allowed_exit_codes", "command", "shell",
                "timeout", "cpu_limit", "file_size_limit_mb", "memory_limit_mb", "background",
            ]
            let unsupported = arguments.keys.filter { !canonicalKeys.contains($0) }.sorted()
            if !unsupported.isEmpty {
                return "unsupported run_command argument key(s): \(unsupported.joined(separator: ", ")); aliases and casing variants are rejected; use canonical keys such as executable, args, cwd, stdin_path, and allowed_exit_codes"
            }
        }
        if let cwd = arguments["cwd"], !(cwd is String) {
            return "'cwd' must be a string"
        }
        if let executable = arguments["executable"], !(executable is String) {
            return "'executable' must be a string"
        }
        if let args = arguments["args"], !(args is [String]) {
            return "'args' must be an array of strings"
        }
        if let rawStdin = arguments["stdin"] {
            guard let stdin = rawStdin as? String else { return "'stdin' must be a string" }
            if stdin.utf8.count > maxStdinBytes {
                return "'stdin' exceeds the \(maxStdinBytes)-byte limit"
            }
        }
        if arguments["stdin"] != nil, arguments["stdin_path"] != nil {
            return "'stdin' and 'stdin_path' are mutually exclusive"
        }
        if let rawPath = arguments["stdin_path"] {
            guard let path = rawPath as? String else { return "'stdin_path' must be a string" }
            guard !path.isEmpty else { return "'stdin_path' must not be empty" }
            guard !path.utf8.contains(0) else { return "'stdin_path' must not contain NUL" }
            guard !path.hasPrefix("/") else { return "'stdin_path' must be relative to cwd/project root" }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.contains(where: { $0 == ".." }) {
                return "'stdin_path' must not contain '..' components"
            }
            if arguments["command"] != nil || (arguments["shell"] as? Bool) == true {
                return "'stdin_path' is unavailable for raw shell commands"
            }
        }
        if let rawDigest = arguments["expected_stdin_sha256"] {
            guard arguments["stdin_path"] != nil else { return "'expected_stdin_sha256' requires 'stdin_path'" }
            guard let digest = rawDigest as? String,
                  digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                return "'expected_stdin_sha256' must be a 64-character hexadecimal SHA-256"
            }
        }
        if arguments["expected_stdin_byte_count"] != nil {
            guard arguments["stdin_path"] != nil else { return "'expected_stdin_byte_count' requires 'stdin_path'" }
            guard let count = integerValue(arguments["expected_stdin_byte_count"]),
                  (0...maxStdinBytes).contains(count) else {
                return "'expected_stdin_byte_count' must be an integer from 0 through \(maxStdinBytes)"
            }
        }
        if let rawCodes = arguments["allowed_exit_codes"] {
            guard let values = rawCodes as? [Any] else {
                return "'allowed_exit_codes' must be an array of integers"
            }
            if values.isEmpty { return "'allowed_exit_codes' must not be empty" }
            if values.count > maxAllowedExitCodes {
                return "'allowed_exit_codes' may contain at most \(maxAllowedExitCodes) values"
            }
            var seen = Set<Int>()
            for value in values {
                guard let code = integerExitCode(value) else {
                    return "'allowed_exit_codes' values must be integers"
                }
                guard seen.insert(code).inserted else {
                    return "'allowed_exit_codes' values must be unique"
                }
            }
        }
        if arguments["background"] as? Bool == true {
            if arguments["stdin"] != nil { return "'stdin' is unavailable for background jobs" }
            if arguments["stdin_path"] != nil { return "'stdin_path' is unavailable for background jobs" }
            if arguments["allowed_exit_codes"] != nil {
                return "'allowed_exit_codes' is unavailable for background jobs"
            }
        }
        if planPreflight {
            if arguments["command"] != nil {
                return "raw 'command' is forbidden in plans; use 'executable' and an 'args' array (never working_directory)"
            }
            guard let executable = arguments["executable"] as? String,
                  !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "run_command plans require a non-empty 'executable' and optional 'args' array"
            }
        }
        return nil
    }

    private static func allowedExitCodes(in arguments: [String: Any]) -> Set<Int> {
        guard let values = arguments["allowed_exit_codes"] as? [Any] else { return [0] }
        return Set(values.compactMap(Self.integerExitCode))
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        if let issue = Self.argumentValidationIssue(arguments, planPreflight: false) {
            return .failure("run_command: \(issue)")
        }
        let cwd = try context.resolvedPath((arguments["cwd"] as? String) ?? ".", mustExist: true)
        let timeout = min(max(optionalInt("timeout", from: arguments) ?? 120, 1), 600)
        let allowedExitCodes = Self.allowedExitCodes(in: arguments)

        // One invocation has one execution shape. Accepting both and silently preferring
        // `executable` made audit/proof consumers vulnerable to classifying the unused shell text.
        let requestedExecutable = (arguments["executable"] as? String)?.isEmpty == false
        let requestedCommand = (arguments["command"] as? String)?.isEmpty == false
        if requestedExecutable && requestedCommand {
            return .failure("provide exactly one command form: executable+args OR command, not both")
        }

        // Resolve execution mode + the (executableURL, argv) to spawn.
        let launchPath: String
        let launchArgs: [String]

        if let exe = arguments["executable"] as? String, !exe.isEmpty {
            // STRUCTURED MODE — resolve the binary, gate on the RESOLVED path, no shell.
            let builderEnvironment = try BuilderOSProcessSandboxAttestor.currentExecutionEnvironment()
            let environment = builderEnvironment ?? Self.scrubbedEnvironment()
            guard let resolved = Self.resolveExecutable(exe, env: environment, cwd: cwd) else {
                return .failure("executable not found or not executable: \(exe)")
            }
            let exeArgs = (arguments["args"] as? [String]) ?? []
            if let reason = Self.interpreterRefusalReason(resolvedPath: resolved, args: exeArgs) {
                throw ToolError.shellDenied(reason)
            }
            // Gate on the FULL argv line so argument-bearing deny entries fire.
            let compilerAliases: Set<String> = ["python3", "python", "swift", "swiftc", "clang", "clang++",
                                                "cc", "c++", "gcc", "make", "rustc", "cargo", "javac", "java", "tsc"]
            let alias = builderEnvironment != nil && compilerAliases.contains(exe) ? exe : nil
            if let reason = await context.shell.binaryRefusalReason(
                resolvedPath: resolved, args: exeArgs, trustedToolchainAlias: alias) {
                throw ToolError.shellDenied(reason)
            }
            launchPath = resolved
            launchArgs = exeArgs
        } else if let command = arguments["command"] as? String, !command.isEmpty {
            // RAW SHELL is explicit only. Even simple-looking strings are never split on whitespace and
            // silently promoted to argv: quoting and intent belong to the caller's structured arguments.
            guard (arguments["shell"] as? Bool) == true else {
                return .failure("raw 'command' requires shell:true — use executable+args for structured execution")
            }
            if let reason = await context.shell.shellStringRefusalReason(for: command) {
                throw ToolError.shellDenied(reason)
            }
            if context.shell.sandboxed && !context.sandbox.enabled {
                throw ToolError.shellDenied("raw shell was auto-approved for the OS sandbox, but the sandbox is not active — refusing")
            }
            launchPath = "/bin/sh"
            launchArgs = ["-c", command]
        } else {
            return .failure("provide either 'executable' (+ optional 'args') or 'command' with shell:true")
        }

        // The shared ToolGate has already authorized the COMPLETE argument set before entering this
        // body. Read only now, after command/interpreter policy also accepts the invocation, so a denied
        // call cannot probe or consume stdin_path. The confined primitive opens every component with
        // O_NOFOLLOW and proves the same descriptor stayed stable while reading.
        let standardInput: ResolvedStandardInput
        do {
            standardInput = try Self.resolveStandardInput(arguments: arguments, context: context, cwd: cwd)
        } catch let error as ToolError {
            return .failure(error.description)
        } catch {
            return .failure(error.localizedDescription)
        }

        // OS-level sandbox tier (opt-in). Wraps the resolved command so the KERNEL enforces
        // network egress-deny + write confinement, on top of the in-process gates. Fails
        // CLOSED if a sandbox was requested but is unavailable on this platform — never
        // silently runs unsandboxed when the caller asked for one.
        let finalPath: String
        let finalArgs: [String]
        let sandboxed: Bool
        let invocation = Self.compilerModeLaunch(
            launchPath: launchPath, launchArgs: launchArgs,
            requestedName: arguments["executable"] as? String)
        switch SeatbeltSandbox.wrap(launchPath: invocation.launchPath, args: invocation.launchArgs, root: context.projectRoot, policy: context.sandbox, cwd: cwd) {
        case .passthrough:
            finalPath = invocation.launchPath; finalArgs = invocation.launchArgs; sandboxed = false
        case .wrapped(let p, let a):
            finalPath = p; finalArgs = a; sandboxed = true
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
        // timeout bounds its lifetime too; background jobs default to one hour.
        if (arguments["background"] as? Bool) == true {
            guard context.sandbox.allowBackgroundProcesses else {
                return .failure("background processes are forbidden by this sandbox policy")
            }
            let display = (arguments["executable"] as? String).map { "\($0) \((arguments["args"] as? [String] ?? []).joined(separator: " "))" }
                ?? (arguments["command"] as? String) ?? limited.launchPath
            // Refuse past the concurrent-job cap with a clear message (the store also enforces it as a
            // backstop). Distinguishes "too many jobs" from "process wouldn't launch".
            if BackgroundJobStore.shared.runningCount() >= BackgroundJobStore.maxConcurrentRunning {
                return .failure("background job limit reached (\(BackgroundJobStore.maxConcurrentRunning) running) — stop some with job(action=\"kill\", id=…) before starting more")
            }
            let backgroundTimeout = min(max(optionalInt("timeout", from: arguments)
                ?? BackgroundJobStore.defaultTimeoutSeconds, 1), 86_400)
            guard let id = BackgroundJobStore.shared.start(launchPath: limited.launchPath, args: limited.launchArgs,
                                                           cwd: cwd, env: Self.scrubbedEnvironment(),
                                                           command: display.trimmingCharacters(in: .whitespaces),
                                                           owner: context.projectRoot, timeoutSeconds: backgroundTimeout) else {
                return .failure("could not start background job")
            }
            return ToolResult(success: true,
                              output: "started background job \(id) — poll it with job(action=\"output\", id=\"\(id)\"), stop with job(action=\"kill\", id=\"\(id)\")",
                              metadata: ["job_id": id, "background": "true",
                                         "timeout_seconds": String(backgroundTimeout),
                                         "sandboxed": String(sandboxed),
                                         "builder_os_sandboxed": "false"])
        }

        let collected = await Self.spawnAndCollect(
            launchPath: limited.launchPath, launchArgs: limited.launchArgs, cwd: cwd, timeout: timeout,
            standardInput: standardInput, allowedExitCodes: allowedExitCodes,
            requestedLaunchPath: launchPath, requestedLaunchArgs: launchArgs
        )
        var metadata = collected.metadata
        metadata["sandboxed"] = String(sandboxed)
        return ToolResult(success: collected.success, output: collected.output,
                          error: collected.error, metadata: metadata,
                          trustedCommandReference: collected.trustedCommandReference)
    }

    // MARK: - Spawn + bounded collection

    /// These compiler aliases select driver behavior through argv[0]. Execute the canonical, gated
    /// target while retaining that mode; launching swift-frontend as itself cannot compile a program,
    /// and clang launched instead of clang++ omits the C++ link defaults. The shell text is constant
    /// and every model-supplied value remains a literal positional argument.
    static func compilerModeLaunch(launchPath: String, launchArgs: [String], requestedName: String?)
        -> (launchPath: String, launchArgs: [String]) {
        #if os(macOS)
        if let requestedName {
            let name = (requestedName as NSString).lastPathComponent
            if ["swift", "swiftc", "clang++", "c++", "cc", "gcc"].contains(name),
               name != (launchPath as NSString).lastPathComponent {
                let argv0 = URL(fileURLWithPath: launchPath).deletingLastPathComponent()
                    .appendingPathComponent(name).path
                return ("/bin/sh", ["-c", "exec -a \"$0\" \"$@\"", argv0, launchPath] + launchArgs)
            }
        }
        #endif
        return (launchPath, launchArgs)
    }

    static func spawnAndCollect(launchPath: String, launchArgs: [String], cwd: String, timeout: Int,
                                stdinData: Data? = nil, allowedExitCodes: Set<Int> = [0]) async -> ToolResult {
        let standardInput: ResolvedStandardInput
        if let stdinData {
            standardInput = ResolvedStandardInput(data: stdinData, sourceKind: "inline", relativePath: nil,
                                                  byteCount: stdinData.count, sha256: sha256(stdinData))
        } else {
            standardInput = .none
        }
        return await spawnAndCollect(launchPath: launchPath, launchArgs: launchArgs, cwd: cwd,
                                     timeout: timeout, standardInput: standardInput,
                                     allowedExitCodes: allowedExitCodes)
    }

    static func spawnAndCollect(launchPath: String, launchArgs: [String], cwd: String, timeout: Int,
                                standardInput: ResolvedStandardInput,
                                allowedExitCodes: Set<Int> = [0],
                                requestedLaunchPath: String? = nil,
                                requestedLaunchArgs: [String]? = nil) async -> ToolResult {
        // ProcessGroupRunner.run blocks (posix_spawn + group teardown + reap), so run it on
        // a background queue and await the outcome.
        let telemetrySink = BuilderTrustedTelemetry.captureCommandSink()
        let builderSandboxAuthority: BuilderSandboxExecutionAuthority?
        do {
            builderSandboxAuthority = try BuilderOSProcessSandboxAttestor.currentExecutionAuthority()
        } catch {
            return .failure("Builder OS sandbox activation is invalid: \(error.localizedDescription)")
        }
        let requestedDigest = Self.requestedCommandDigest(
            launchPath: requestedLaunchPath ?? launchPath,
            launchArgs: requestedLaunchArgs ?? launchArgs,
            cwd: cwd, timeout: timeout, standardInput: standardInput,
            allowedExitCodes: allowedExitCodes)
        let outcome = await ProcessGroupRunner.runAsync(
            launchPath: launchPath, launchArgs: launchArgs, cwd: cwd,
            env: scrubbedEnvironment(), timeoutSeconds: timeout, capPerStream: maxOutputBytes,
            stdinData: standardInput.data, stdinByteLimit: maxStdinBytes,
            telemetrySink: telemetrySink, requestedArgumentsDigest: requestedDigest,
            builderSandboxAuthority: builderSandboxAuthority,
            requireBuilderSandbox: builderSandboxAuthority != nil)

        let combined = outcome.combined
        let cleanExit = !outcome.cancelled && !outcome.timedOut && !outcome.wasSignalled && outcome.exitCode >= 0
        let success = cleanExit && allowedExitCodes.contains(Int(outcome.exitCode))
        let verificationEligible = success && outcome.exitCode == 0
        // Never leave the agent blind on failure: if a command failed with NO captured output, say WHY it's
        // empty (sandbox/resource kill, or it wrote nothing) and how to see the real error — instead of a
        // bare "exit code N" that gives nothing to diagnose.
        let failError: String?
        if success { failError = nil }
        else if outcome.cancelled { failError = "command cancelled" }
        else if outcome.timedOut { failError = "command timed out after \(timeout)s" }
        else if outcome.wasSignalled {
            // KILLED BY A SIGNAL (exit is 128+signal) — the real signature of an OS sandbox /
            // resource-limit kill (SIGKILL/SIGXCPU/SIGSEGV/SIGXFSZ), whether or not it wrote output.
            let sig = outcome.exitCode - 128
            failError = "killed by signal \(sig) (exit \(outcome.exitCode))\(combined.isEmpty ? ", no output" : "") — "
                + "likely the OS sandbox or a resource limit (memory/CPU/file-size). If this is a build/test, "
                + "run it DIRECTLY via run_command executable+args (not custom_tool) to see its real output."
        }
        else if outcome.exitCode < 0 {
            failError = combined.isEmpty ? "the command could not be launched (internal error)" : combined
        }
        else if cleanExit && combined.isEmpty {
            // A CLEAN non-zero exit with no output is a NORMAL result for many tools — `which`/`type`
            // (not found), `grep`/`rg` (no match), `test`/`[`/`cmp`/`diff` (false/differ), `find` (none).
            // Report it plainly and let the agent read the exit code; do NOT cry "sandbox/resource kill"
            // (a plain exit 1 is not a termination). Codex/Luke fix 2026-08-01.
            failError = "exit code \(outcome.exitCode), no output — commonly a NORMAL non-zero result "
                + "(e.g. `which`/`grep`/`test` when nothing matched or a file was absent), not necessarily an error."
        }
        else if cleanExit {
            // Carry the diagnosis IN the error string: the plan executor's replan steering and the
            // sealed verification failure only relay `error`, so a planner that saw just
            // "exit code 1" regenerated correct files instead of fixing its runner (live
            // 2026-09-27: `python3 -m pytest` printed "No module named pytest" and nobody saw it).
            failError = "exit code \(outcome.exitCode); allowed exit codes: \(allowedExitCodes.sorted())"
                + " — output tail: " + Self.outputTail(combined)
        }
        else { failError = "command failed with exit code \(outcome.exitCode)" }
        var metadata = [
            "exit_code": String(outcome.exitCode),
            "timed_out": String(outcome.timedOut),
            "cancelled": String(outcome.cancelled),
            "was_signalled": String(outcome.wasSignalled),
            "stdout": outcome.stdout,
            "stderr": outcome.stderr,
            "stdout_truncated": String(outcome.stdoutTruncated),
            "stderr_truncated": String(outcome.stderrTruncated),
            "output_truncated": String(outcome.outputTruncated),
            "allowed_exit_codes": allowedExitCodes.sorted().map(String.init).joined(separator: ","),
            "exit_code_allowed": String(success),
            "verification_eligible": String(verificationEligible),
            "builder_os_sandboxed": String(
                outcome.sandboxProfileDigest?.isEmpty == false
                    && !outcome.effectiveEnvironmentDigest.isEmpty),
        ]
        if success && outcome.exitCode != 0 {
            metadata["semantic_status"] = "expected_domain_status"
        } else if verificationEligible {
            metadata["semantic_status"] = "clean_exit"
        }
        metadata["stdin_source_kind"] = standardInput.sourceKind
        metadata["stdin_byte_count"] = String(standardInput.byteCount)
        if let digest = standardInput.sha256 { metadata["stdin_sha256"] = digest }
        if let relativePath = standardInput.relativePath {
            metadata["stdin_relative_path"] = relativePath
        }
        return ToolResult(
            success: success,
            output: combined.isEmpty ? (success ? "(no output)" : "(no output, exit \(outcome.exitCode))") : combined,
            error: failError,
            metadata: metadata,
            trustedCommandReference: outcome.trustedCommandReference
        )
    }

    private static func requestedCommandDigest(
        launchPath: String, launchArgs: [String], cwd: String, timeout: Int,
        standardInput: ResolvedStandardInput, allowedExitCodes: Set<Int>
    ) -> String {
        BuilderEvidenceDigest.sha256(
            (["kist.builder.requested-command.v1", launchPath] + launchArgs
             + [cwd, String(timeout), standardInput.sourceKind,
                standardInput.relativePath ?? "-", standardInput.sha256 ?? "-",
                String(standardInput.byteCount),
                allowedExitCodes.sorted().map(String.init).joined(separator: ",")])
                .joined(separator: "\u{0}"))
    }

    struct ResolvedStandardInput: Sendable, Equatable {
        let data: Data?
        let sourceKind: String
        let relativePath: String?
        let byteCount: Int
        let sha256: String?

        static let none = ResolvedStandardInput(data: nil, sourceKind: "none", relativePath: nil,
                                                byteCount: 0, sha256: nil)
    }

    static func resolveStandardInput(arguments: [String: Any], context: ToolContext,
                                     cwd: String) throws -> ResolvedStandardInput {
        if let inline = arguments["stdin"] as? String {
            let data = Data(inline.utf8)
            return ResolvedStandardInput(data: data, sourceKind: "inline", relativePath: nil,
                                         byteCount: data.count, sha256: sha256(data))
        }
        guard let requested = arguments["stdin_path"] as? String else { return .none }

        let confined = try context.confinedRoot()
        let relativePath = try normalizedGovernedStdinPath(requested, cwd: cwd,
                                                           projectRoot: confined.rootPath)
        let data = try confined.readStableData(relativePath, maxBytes: maxStdinBytes)
        let digest = sha256(data)
        if let expected = arguments["expected_stdin_sha256"] as? String,
           expected.lowercased() != digest {
            throw ToolError.execution("stdin_path changed since validation (SHA-256 mismatch): \(relativePath)")
        }
        if let expected = integerValue(arguments["expected_stdin_byte_count"]),
           expected != data.count {
            throw ToolError.execution("stdin_path changed since validation (byte-count mismatch): \(relativePath)")
        }
        return ResolvedStandardInput(data: data, sourceKind: "governed_path",
                                     relativePath: relativePath, byteCount: data.count, sha256: digest)
    }

    static func normalizedGovernedStdinPath(_ requested: String, cwd: String,
                                            projectRoot: String) throws -> String {
        guard !requested.isEmpty, !requested.hasPrefix("/"), !requested.utf8.contains(0) else {
            throw ToolError.invalidParameter("stdin_path must be a nonempty relative path without NUL")
        }
        let requestedParts = requested.split(separator: "/", omittingEmptySubsequences: false)
        guard !requestedParts.contains(where: { $0 == ".." }) else {
            throw ToolError.pathEscape(path: requested, root: projectRoot)
        }
        let rootPrefix = projectRoot == "/" ? "/" : projectRoot + "/"
        let cwdRelative: String
        if cwd == projectRoot {
            cwdRelative = ""
        } else if cwd.hasPrefix(rootPrefix) {
            cwdRelative = String(cwd.dropFirst(rootPrefix.count))
        } else {
            throw ToolError.pathEscape(path: cwd, root: projectRoot)
        }
        let parts = (cwdRelative.split(separator: "/") + requestedParts)
            .filter { !$0.isEmpty && $0 != "." }
        guard !parts.isEmpty else {
            throw ToolError.invalidParameter("stdin_path must name a regular file")
        }
        return parts.map(String.init).joined(separator: "/")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
            #if !canImport(Darwin)
            lines.append("ulimit -v \(memoryMB * 1024)")
            #endif
        }
        lines.append("exec \"$@\"")
        return ("/bin/sh", ["-c", lines.joined(separator: "\n"), "agentcore-resource-limits", launchPath] + launchArgs)
    }

    /// The last `maxBytes` of a command's combined output, single-line, for embedding in an error
    /// string. Bounded so a chatty failure cannot flood a replan prompt or a receipt.
    static func outputTail(_ combined: String, maxBytes: Int = 600) -> String {
        let flat = combined.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        guard flat.utf8.count > maxBytes else { return flat }
        return "…" + String(decoding: Array(flat.utf8.suffix(maxBytes)), as: UTF8.self)
    }

    /// Resolve an executable name to an absolute, canonicalized, executable path.
    /// Absolute paths are canonicalized directly; bare names are looked up on the
    /// (scrubbed) PATH; relative-with-slash names (`./payroll_report`, `build/tool`) resolve
    /// against `cwd` when provided (the tool call's CONFINED cwd). Returns nil if nothing
    /// executable is found. Resolving relative names adds NO capability — the same binary was
    /// always reachable by absolute path, and the deny gate fires on the RESOLVED path — it
    /// just unblocks the natural compile-then-`./run` loop (dogfood find 2026-08-06: the agent
    /// built a COBOL binary it then "couldn't" run, burning the whole iteration budget).
    static func resolveExecutable(_ exe: String, env: [String: String], cwd: String? = nil) -> String? {
        func canonicalExecutable(_ path: String) -> String? {
            guard let real = ToolContext.canonicalize(path) else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), !isDir.boolValue,
                  FileManager.default.isExecutableFile(atPath: real) else { return nil }
            return real
        }
        if exe.hasPrefix("/") { return canonicalExecutable(exe) }
        if exe.contains("/") {   // cwd-relative — resolve against the confined cwd, else reject
            guard let cwd, !cwd.isEmpty else { return nil }
            return canonicalExecutable((cwd as NSString).appendingPathComponent(exe))
        }
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            if let resolved = canonicalExecutable(String(dir) + "/" + exe) { return resolved }
        }
        // Well-known toolchain dirs, tried ONLY after the env PATH walk fails. A launcher that
        // scrubs PATH to the system dirs (the ~/bin/kist wrapper did until 2026-08-03) made every
        // Homebrew tool "executable not found" even though `brew`/`nasm`/`dosbox-x` were installed.
        // APPEND, never prepend: env PATH keeps precedence so a user-writable /opt/homebrew/bin can
        // never shadow a system binary. (This adds no capability — absolute paths already worked.)
        for dir in wellKnownFallbackDirs where !path.split(separator: ":").contains(Substring(dir)) {
            if let resolved = canonicalExecutable(dir + "/" + exe) { return resolved }
        }
        return nil
    }

    /// Searched after the env PATH, in this order. macOS arm64 Homebrew first, then the Intel/
    /// manual-install prefix. Deliberately NOT ~/bin: exposing a user's private bridges to
    /// unattended runs is the launcher's call (the wrapper adds it to PATH), not a baked-in default.
    static let wellKnownFallbackDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Structured argv is normally literal, but an interpreter's command/eval switch creates a second
    /// parser and recreates raw-shell injection. Block those shapes before the ordinary substring policy.
    /// `env` is blocked entirely because it is an indirect executable launcher that would otherwise make
    /// the resolved-binary allowlist describe `/usr/bin/env`, not the program that actually runs.
    static func interpreterRefusalReason(resolvedPath: String, args: [String]) -> String? {
        let base = (resolvedPath as NSString).lastPathComponent.lowercased()
        if base == "env" {
            return "the env command launcher is not permitted in structured execution; invoke the resolved executable directly"
        }

        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh"]
        if shells.contains(base) {
            let hasCommandString = args.contains { argument in
                let flag = argument.lowercased()
                if flag == "--command" || flag.hasPrefix("--command=") { return true }
                return flag.hasPrefix("-") && !flag.hasPrefix("--") && flag.dropFirst().contains("c")
            }
            if hasCommandString {
                return "shell interpreter '\(base)' with a command-string flag must use the raw-shell approval path"
            }
        }

        let isPython = base == "python" || base.hasPrefix("python2") || base.hasPrefix("python3")
        let evalFlags: Set<String>
        if isPython { evalFlags = ["-c"] }
        else if ["node", "nodejs", "ruby", "perl", "swift", "deno", "bun", "osascript"].contains(base) {
            evalFlags = ["-e", "--eval"]
        } else if ["powershell", "pwsh"].contains(base) {
            evalFlags = ["-c", "-command", "-encodedcommand"]
        } else if base == "php" {
            evalFlags = ["-r"]
        } else {
            return nil
        }
        if args.contains(where: { argument in
            let lower = argument.lowercased()
            return evalFlags.contains(lower) || evalFlags.contains(where: { flag in
                lower.hasPrefix(flag + "=")
                    || (flag.count == 2 && lower.hasPrefix(flag) && lower.count > flag.count)
            })
        }) {
            return "interpreter '\(base)' command/eval mode is not permitted in structured execution"
        }
        return nil
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
    private var outTruncated = false
    private var errTruncated = false
    private var outHasher = SHA256()
    private var errHasher = SHA256()
    private var outByteCount = 0
    private var errByteCount = 0
    private let cap: Int
    private var capFired = false
    private let onCapExceeded: () -> Void

    init(capPerStream: Int, onCapExceeded: @escaping () -> Void) {
        self.cap = capPerStream
        self.onCapExceeded = onCapExceeded
    }

    func appendOut(_ data: Data) {
        append(data, to: \.out, truncated: \.outTruncated, hasher: \.outHasher,
               byteCount: \.outByteCount)
    }
    func appendErr(_ data: Data) {
        append(data, to: \.err, truncated: \.errTruncated, hasher: \.errHasher,
               byteCount: \.errByteCount)
    }

    private func append(_ data: Data,
                        to keyPath: ReferenceWritableKeyPath<BoundedOutputCollector, Data>,
                        truncated truncatedKeyPath: ReferenceWritableKeyPath<BoundedOutputCollector, Bool>,
                        hasher hasherKeyPath: ReferenceWritableKeyPath<BoundedOutputCollector, SHA256>,
                        byteCount byteCountKeyPath: ReferenceWritableKeyPath<BoundedOutputCollector, Int>) {
        guard !data.isEmpty else { return }
        var fire = false
        lock.lock()
        self[keyPath: hasherKeyPath].update(data: data)
        self[keyPath: byteCountKeyPath] += data.count
        let current = self[keyPath: keyPath]
        if current.count < cap {
            let remaining = cap - current.count
            self[keyPath: keyPath].append(data.prefix(remaining))
            if data.count >= remaining { self[keyPath: truncatedKeyPath] = true }
        } else {
            self[keyPath: truncatedKeyPath] = true
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

    func truncationState() -> (stdout: Bool, stderr: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (outTruncated, errTruncated)
    }

    func byteCounts() -> (stdout: Int, stderr: Int) {
        lock.lock(); defer { lock.unlock() }
        return (outByteCount, errByteCount)
    }

    func fullDigests() -> (stdout: String, stderr: String) {
        lock.lock(); defer { lock.unlock() }
        let outCopy = outHasher
        let errCopy = errHasher
        return (
            outCopy.finalize().map { String(format: "%02x", $0) }.joined(),
            errCopy.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
