import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A `ChatProvider` backed by a local, subscription-authenticated CLI (Claude Code, Codex) instead of an
/// HTTP API — so kist can borrow a Claude **Max** / ChatGPT subscription for inference at no per-token
/// API cost. The prompt goes to the CLI on stdin; the model's text answer comes back on stdout.
///
/// Ported from the integrate-all lineage (CLIChatProvider @ bc41bf1a) onto the kist-loops captain
/// baseline: same provider surface, adapted to this tree's single-signature `ChatProvider.stream`
/// (no `ProviderExecutionContext` here) and its `ProcessGroupRunner` (staged-stdin support added
/// alongside this port).
///
/// - No API key: the CLI already holds the auth (`requiresAPIKey == false`).
/// - Text-protocol only (`supportsNativeTools == false`): kist sends its own tool contract in the prompt
///   and parses the model's TEXT reply, exactly as for any non-native provider.
/// - Claude runs as a pure completion: `--safe-mode` + `--tools ""` disable its agent surfaces. Codex
///   uses its strongest documented reduced posture (read-only sandbox, features disabled).
///
/// Security: this resolves a FIXED, user-installed, trusted binary once from trusted absolute PATH
/// entries, then launches that absolute path with the prompt on stdin and all other args as a literal
/// argv array — no shell, no launch-time PATH lookup, no interpolation, and no injection surface. It is
/// a call to a local tool, NOT the LLM-generated-code exec plane; it runs no model-authored program.
public struct CLIChatProvider: ChatProvider {
    public let id: String
    public let name: String
    public let iconName: String
    public let keyAccount: String
    public let defaultModel: String
    public let availableModels: [AIModel]

    /// Binary name resolved on PATH (e.g. "claude", "codex").
    let binaryName: String
    /// Build the argv (excluding the binary name) for a one-shot completion of the given model. The prompt
    /// is always delivered on stdin, never as an argument (avoids ARG_MAX on large contexts).
    let argsForModel: @Sendable (_ model: String) -> [String]
    /// Extract the assistant text from the CLI's raw stdout (claude = identity; codex = strip transcript).
    let parseOutput: @Sendable (_ stdout: String) -> String

    public var requiresAPIKey: Bool { false }
    public var supportsNativeTools: Bool { false }
    public var modelsListEndpoint: String? { nil }

    public func capabilities(forModel model: String) -> ModelCapabilities {
        ModelCapabilities(nativeTools: false, reasoning: true,
                          contextWindowTokens: 200_000, structuredOutput: false)
    }

    /// A subscription CLI is usable only when its executable is on a trusted absolute PATH entry and its
    /// non-interactive auth-status command succeeds. This is deliberately a local, bounded probe: it never
    /// sends a prompt or makes a billable model request.
    public func isLocallyAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        authTimeout: TimeInterval = 2.0
    ) -> Bool {
        guard let executable = Self.executableURL(binaryName: binaryName, environment: environment) else {
            return false
        }
        let authArguments: [String]?
        switch id {
        case "claude-cli": authArguments = ["auth", "status"]
        case "codex-cli": authArguments = ["login", "status"]
        default: authArguments = nil
        }
        guard let authArguments else { return true }
        let outcome = ProcessGroupRunner.run(
            launchPath: executable.path,
            launchArgs: authArguments,
            cwd: "/",
            env: Self.scrubbedCLIEnvironment(environment),
            timeoutSeconds: max(1, Int(authTimeout.rounded(.up))),
            capPerStream: 8 * 1_024,
            graceSeconds: 1)
        return outcome.exitCode == 0 && !outcome.timedOut
    }

    /// Whether the backing CLI binary exists at all (pure file checks — no subprocess, safe to call
    /// at catalog construction). Distinct from `isLocallyAvailable`, which additionally proves the
    /// cached subscription login with a bounded subprocess probe.
    public func isInstalled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        Self.executableURL(binaryName: binaryName, environment: environment) != nil
    }

    /// Well-known install directories tried BEFORE the PATH walk (Codex review 532fa03 issue 2): an
    /// entry injected ahead of the real install location in a less-controlled environment (CI, shell
    /// wrapper) must not be able to impersonate a trusted CLI. PATH remains only the fallback for
    /// unconventional installs.
    private static func wellKnownDirectories(environment: [String: String]) -> [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        if let home = environment["HOME"], (home as NSString).isAbsolutePath {
            // Claude Code's default user install location, then generic user bins.
            dirs = ["\(home)/.local/bin", "\(home)/bin"] + dirs
        }
        return dirs
    }

    private static func executableURL(binaryName: String, environment: [String: String]) -> URL? {
        let fm = FileManager.default
        if (binaryName as NSString).isAbsolutePath {
            guard fm.isExecutableFile(atPath: binaryName) else { return nil }
            return URL(fileURLWithPath: binaryName).resolvingSymlinksInPath()
        }
        guard !binaryName.contains("/") else { return nil }
        let path = environment["PATH"] ?? ""
        // Allowlisted install locations first; PATH order only breaks ties among unknown dirs.
        let pathDirs = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        for directory in wellKnownDirectories(environment: environment) + pathDirs {
            // Ignore relative/empty PATH components. The environment launcher would honor them, but doing
            // so would let a project-local executable impersonate a trusted CLI during auto-routing.
            guard (directory as NSString).isAbsolutePath else { continue }
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(binaryName).path
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
            }
        }
        return nil
    }

    public func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                       apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        // This tree's runner has no cooperative mid-run cancellation hook: a cancelled turn stops
        // consuming the stream immediately, but the CLI child runs on until it finishes or hits the
        // deadline (the runner then tears down the whole process group). Bounded, documented residual.
        let prompt = Self.flatten(messages, systemPrompt: settings.systemPrompt)
        let resolvedModel = model.isEmpty ? defaultModel : model
        let args = argsForModel(resolvedModel)
        let bin = binaryName
        let parse = parseOutput
        return AsyncThrowingStream { continuation in
            let work = Task.detached {
                do {
                    try Task.checkCancellation()
                    let raw = try Self.runToCompletion(binaryName: bin, args: args, stdin: prompt)
                    let text = parse(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { continuation.yield(.delta(text)) }
                    continuation.yield(.finish(reason: "stop"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Flatten kist's message array into one prompt (the CLIs take a single prompt, not a message list).
    static func flatten(_ messages: [ChatMessage], systemPrompt: String = "") -> String {
        var effective = messages
        if !systemPrompt.isEmpty {
            // Match the HTTP adapters' authoritative settings-level prompt and avoid conflicting
            // duplicate system roles when a compatibility caller supplied both forms.
            effective.removeAll { $0.role == .system }
            effective.insert(ChatMessage(role: .system, content: systemPrompt), at: 0)
        }
        return effective.map { m in
            switch m.role {
            case .system:    return "[System]\n\(m.content)"
            case .user:      return "[User]\n\(m.content)"
            case .assistant: return "[Assistant]\n\(m.content)"
            case .tool:      return "[Tool result]\n\(m.content)"
            }
        }.joined(separator: "\n\n")
    }

    /// Execute a one-shot subscription CLI with a hard deadline, capped output, staged stdin,
    /// process-group teardown, and an allowlisted environment.
    static func runToCompletion(
        binaryName: String,
        args: [String],
        stdin: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: Int = 600,
        outputByteLimit: Int = 4 * 1_024 * 1_024
    ) throws -> String {
        guard let executable = executableURL(binaryName: binaryName, environment: environment) else {
            throw CLIProviderError.notRunnable(binary: binaryName,
                                               detail: "executable not found on trusted absolute PATH")
        }
        guard timeoutSeconds > 0 else {
            throw CLIProviderError.notRunnable(binary: binaryName,
                                               detail: "completion deadline must be positive")
        }
        let outcome = ProcessGroupRunner.run(
            launchPath: executable.path,
            launchArgs: args,
            cwd: "/",
            env: scrubbedCLIEnvironment(environment),
            timeoutSeconds: timeoutSeconds,
            capPerStream: max(1, min(outputByteLimit, 16 * 1_024 * 1_024)),
            graceSeconds: 2,
            stdinData: Data(stdin.utf8))
        if outcome.timedOut {
            throw CLIProviderError.timedOut(binary: binaryName, seconds: TimeInterval(timeoutSeconds))
        }
        guard outcome.exitCode >= 0 else {
            throw CLIProviderError.notRunnable(binary: binaryName, detail: outcome.combined)
        }
        guard outcome.exitCode == 0 else {
            let err = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIProviderError.exited(binary: binaryName, code: outcome.exitCode,
                                          stderr: String(err.prefix(400)))
        }
        return outcome.stdout
    }

    /// Keep cached-subscription discovery paths and benign locale/terminal state, but never forward API
    /// keys, cloud credentials, proxy credentials, askpass hooks, or dynamic-loader injection variables.
    static func scrubbedCLIEnvironment(_ parent: [String: String]) -> [String: String] {
        func bounded(_ key: String, maxBytes: Int = 4_096) -> String? {
            guard let value = parent[key], !value.contains("\0"), value.utf8.count <= maxBytes else { return nil }
            return value
        }
        let rawPath = bounded("PATH") ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var seen = Set<String>()
        let path = rawPath.split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { ($0 as NSString).isAbsolutePath && seen.insert($0).inserted }
        var child: [String: String] = [
            "PATH": (path.isEmpty ? ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] : path).joined(separator: ":"),
            "HOME": bounded("HOME").flatMap { ($0 as NSString).isAbsolutePath ? $0 : nil } ?? "/var/empty",
            "LANG": bounded("LANG") ?? "C",
            "LC_ALL": bounded("LC_ALL") ?? "C",
        ]
        for key in ["USER", "LOGNAME", "LC_CTYPE", "TERM", "SHELL", "NO_COLOR"] {
            if let value = bounded(key) { child[key] = value }
        }
        if let tmp = bounded("TMPDIR"), (tmp as NSString).isAbsolutePath { child["TMPDIR"] = tmp }
        if let codexHome = bounded("CODEX_HOME"), (codexHome as NSString).isAbsolutePath {
            child["CODEX_HOME"] = codexHome
        }
        return child
    }

    // MARK: - Built-in CLI providers

    /// Claude Code in headless print mode with its agent surfaces disabled → a pure Claude completion via
    /// the user's Max/Pro subscription. `--safe-mode` preserves subscription auth while suppressing
    /// CLAUDE.md, skills, plugins, hooks, MCP, and agents; `--tools ""` is Claude's actual no-tools switch.
    public static func claudeCode() -> CLIChatProvider {
        CLIChatProvider(
            id: "claude-cli", name: "Claude (Max subscription)", iconName: "sparkle",
            keyAccount: "", defaultModel: "sonnet",
            availableModels: [AIModel(id: "sonnet", displayName: "Claude Sonnet (subscription)"),
                              AIModel(id: "opus", displayName: "Claude Opus (subscription)"),
                              AIModel(id: "haiku", displayName: "Claude Haiku (subscription)")],
            binaryName: "claude",
            argsForModel: { model in
                var a = [
                    "-p",
                    "--safe-mode",
                    "--strict-mcp-config",
                    "--tools", "",
                    "--allowedTools", "",
                    "--disable-slash-commands",
                    "--no-session-persistence",
                    "--no-chrome",
                    "--permission-mode", "dontAsk",
                    "--output-format", "text",
                ]
                if !model.isEmpty { a += ["--model", model] }
                return a
            },
            parseOutput: { $0 }   // claude --output-format text prints only the answer
        )
    }

    /// Codex CLI non-interactive exec via the user's ChatGPT subscription, in its strongest documented
    /// reduced posture: ephemeral state, ignored user config, zero project-document bytes, disabled
    /// agent/tool features, read-only sandbox, and disabled web search.
    public static func codexCLI() -> CLIChatProvider {
        CLIChatProvider(
            id: "codex-cli", name: "Codex (ChatGPT subscription)",
            iconName: "chevron.left.forwardslash.chevron.right",
            keyAccount: "", defaultModel: "gpt-5.5-codex",
            availableModels: [AIModel(id: "gpt-5.5-codex", displayName: "GPT-5.5 Codex (subscription)")],
            binaryName: "codex",
            argsForModel: { model in
                var a = [
                    "exec",
                    "--ephemeral",
                    "--ignore-user-config",
                    "--ignore-rules",
                    "--skip-git-repo-check",
                    "--sandbox", "read-only",
                    "--config", "web_search=\"disabled\"",
                    "--config", "project_doc_max_bytes=0",
                    "--disable", "apps",
                    "--disable", "goals",
                    "--disable", "hooks",
                    "--disable", "multi_agent",
                    "--disable", "remote_plugin",
                    "--disable", "shell_snapshot",
                    "--disable", "shell_tool",
                    "--disable", "unified_exec",
                ]
                if !model.isEmpty { a += ["--model", model] }
                return a
            },
            parseOutput: { raw in Self.extractCodexAnswer(raw) }
        )
    }

    /// Pull the assistant text out of `codex exec` output. The transcript looks like:
    /// `… \ncodex\n<answer>\ntokens used\n<n>`. Take the text after the last `codex` marker line up to the
    /// `tokens used` footer; fall back to the raw output if the markers aren't present (format drift).
    static func extractCodexAnswer(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard let codexIdx = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "codex" }) else {
            return raw
        }
        var out: [String] = []
        for line in lines[(codexIdx + 1)...] {
            if line.trimmingCharacters(in: .whitespaces) == "tokens used" { break }
            out.append(line)
        }
        let answer = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? raw : answer
    }
}

public enum CLIProviderError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case notRunnable(binary: String, detail: String)
    case exited(binary: String, code: Int32, stderr: String)
    case timedOut(binary: String, seconds: TimeInterval)

    public var description: String {
        switch self {
        case .notRunnable(let binary, let detail):
            return "CLI provider '\(binary)' could not start (is it installed and on PATH?): \(detail)"
        case .exited(let binary, let code, let stderr):
            return "CLI provider '\(binary)' exited \(code): \(stderr.isEmpty ? "no stderr" : stderr)"
        case .timedOut(let binary, let seconds):
            return "CLI provider '\(binary)' exceeded its \(seconds)s deadline"
        }
    }

    /// `Error.localizedDescription` is what failure capsules and routing diagnostics surface. Without
    /// `LocalizedError`, Swift bridges this enum as an opaque `CLIProviderError error N` and discards the
    /// exit code/stderr evidence needed to diagnose provider availability.
    public var errorDescription: String? { description }
}
