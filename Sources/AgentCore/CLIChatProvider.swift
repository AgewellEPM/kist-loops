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
/// - Normal chat remains text-protocol (`supportsNativeTools == false`): kist sends its own tool contract
///   in the prompt. Schema-bearing subcalls use each CLI's native structured-output surface instead.
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
                          contextWindowTokens: 200_000,
                          structuredOutput: id == "claude-cli" || id == "codex-cli")
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
        return Self.authenticationStatusIsUsable(
            providerID: id, exitCode: outcome.exitCode,
            timedOut: outcome.timedOut, stdout: outcome.stdout)
    }

    /// Claude's `auth status` exits zero even when its JSON says `loggedIn:false`, so process status
    /// alone is not authentication evidence. Codex currently signals logout through a non-zero status;
    /// keep that documented contract while parsing Claude's machine-readable result fail-closed.
    static func authenticationStatusIsUsable(
        providerID: String, exitCode: Int32, timedOut: Bool, stdout: String
    ) -> Bool {
        guard exitCode == 0, !timedOut else { return false }
        guard providerID == "claude-cli" else { return true }
        guard let data = stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let status = object as? [String: Any] else { return false }
        return status["loggedIn"] as? Bool == true
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
        let prompt = Self.flatten(messages, systemPrompt: settings.systemPrompt)
        let resolvedModel = model.isEmpty ? defaultModel : model
        let bin = binaryName
        let parse = parseOutput
        let providerID = id
        let baseArgs = argsForModel(resolvedModel)
        let canonicalSchema = settings.jsonOutput
            ? Self.canonicalSchema(settings.jsonSchema) : nil
        // Task.detached does not provide an evidence boundary. Capture the host-minted telemetry
        // session explicitly so only this concrete CLI invocation can append a CLI route receipt.
        let trustedTelemetrySession = BuilderTrustedTelemetry.session
        return AsyncThrowingStream { continuation in
            let cancellation = CLIProviderCancellation()
            let work = Task.detached {
                do {
                    try Task.checkCancellation()
                    let invocationStarted = DispatchTime.now().uptimeNanoseconds
                    let result: CLIStructuredResult
                    let executedArguments: [String]
                    let route: String
                    if let canonicalSchema, providerID == "claude-cli" {
                        let args = try Self.structuredArguments(
                            providerID: providerID, baseArguments: baseArgs,
                            canonicalSchema: canonicalSchema,
                            schemaPath: nil, resultPath: nil)
                        executedArguments = args
                        route = "native-structured"
                        let raw = try Self.runToCompletion(
                            binaryName: bin, args: args, stdin: prompt,
                            cancellationCheck: { cancellation.isCancelled })
                        result = try Self.parseClaudeStructuredResult(raw)
                    } else if let canonicalSchema, providerID == "codex-cli" {
                        let files = try CLIStructuredRequestFiles(
                            canonicalSchema: canonicalSchema, needsResultFile: true)
                        defer { files.cleanup() }
                        let args = try Self.structuredArguments(
                            providerID: providerID, baseArguments: baseArgs,
                            canonicalSchema: canonicalSchema,
                            schemaPath: files.schemaPath,
                            resultPath: files.resultPath)
                        executedArguments = args
                        route = "native-structured"
                        let eventOutput = try Self.runToCompletion(
                            binaryName: bin, args: args, stdin: prompt,
                            cancellationCheck: { cancellation.isCancelled })
                        result = try Self.parseCodexStructuredResult(
                            try files.readResult(), eventOutput: eventOutput)
                    } else if providerID == "codex-cli" {
                        let args = baseArgs + ["--json"]
                        executedArguments = args
                        route = "text-protocol"
                        let eventOutput = try Self.runToCompletion(
                            binaryName: bin, args: args, stdin: prompt,
                            cancellationCheck: { cancellation.isCancelled })
                        result = try Self.parseCodexTextResult(eventOutput)
                    } else {
                        executedArguments = baseArgs
                        route = "text-protocol"
                        let raw = try Self.runToCompletion(
                            binaryName: bin, args: baseArgs, stdin: prompt,
                            cancellationCheck: { cancellation.isCancelled })
                        result = CLIStructuredResult(
                            // Text-protocol output is the model payload, not presentation text. Preserve
                            // its exact bytes so a coder response can safely flow through `generate` into
                            // a file without losing indentation or a required terminal newline. Explicit
                            // structured protocols are parsed in their provider-specific branches above.
                            text: parse(raw),
                            usage: .zero, usageReported: false)
                    }
                    let text = result.text
                    let elapsed = max(1, Int((DispatchTime.now().uptimeNanoseconds
                        - invocationStarted) / 1_000_000))
                    BuilderTrustedTelemetry.recordCLIProviderInvocation(
                        session: trustedTelemetrySession,
                        providerID: providerID, modelID: resolvedModel, route: route,
                        inputTokens: result.usage.promptTokens,
                        outputTokens: result.usage.completionTokens,
                        usageReported: result.usageReported,
                        elapsedMilliseconds: elapsed,
                        requestFingerprint: Self.requestFingerprint(
                            providerID: providerID, modelID: resolvedModel, route: route,
                            prompt: prompt, arguments: executedArguments,
                            canonicalSchema: canonicalSchema),
                        responseFingerprint: BuilderEvidenceDigest.sha256(text))
                    if !text.isEmpty { continuation.yield(.delta(text)) }
                    if result.usageReported {
                        continuation.yield(.usage(
                            promptTokens: result.usage.promptTokens,
                            completionTokens: result.usage.completionTokens))
                    }
                    continuation.yield(.finish(reason: "stop"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                cancellation.cancel()
                work.cancel()
            }
        }
    }

    static func canonicalSchema(_ raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8), data.count <= 256_000,
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any], JSONSerialization.isValidJSONObject(object),
              let canonical = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: canonical, as: UTF8.self)
    }

    static func requestFingerprint(
        providerID: String, modelID: String, route: String, prompt: String,
        arguments: [String], canonicalSchema: String?
    ) -> String {
        struct RequestIdentity: Codable {
            let providerID: String
            let modelID: String
            let route: String
            let prompt: String
            let arguments: [String]
            let canonicalSchema: String?
        }
        let identity = RequestIdentity(
            providerID: providerID, modelID: modelID, route: route,
            prompt: prompt, arguments: arguments, canonicalSchema: canonicalSchema)
        guard let data = try? BuilderDurableIO.canonicalData(identity) else {
            return BuilderEvidenceDigest.sha256("invalid-cli-request-identity")
        }
        return BuilderEvidenceDigest.sha256(String(decoding: data, as: UTF8.self))
    }

    static func structuredArguments(
        providerID: String,
        baseArguments: [String],
        canonicalSchema: String,
        schemaPath: String?,
        resultPath: String?
    ) throws -> [String] {
        switch providerID {
        case "claude-cli":
            var arguments = baseArguments
            if let format = arguments.firstIndex(of: "--output-format"),
               arguments.indices.contains(format + 1) {
                arguments[format + 1] = "json"
            } else {
                arguments += ["--output-format", "json"]
            }
            arguments += ["--json-schema", canonicalSchema]
            return arguments
        case "codex-cli":
            guard let schemaPath, let resultPath else {
                throw CLIProviderError.notRunnable(
                    binary: "codex", detail: "structured request files are unavailable")
            }
            return baseArguments + [
                "--output-schema", schemaPath,
                "--output-last-message", resultPath,
                "--json",
            ]
        default:
            throw CLIProviderError.notRunnable(
                binary: providerID, detail: "native structured output is unsupported")
        }
    }

    static func parseClaudeStructuredResult(_ stdout: String) throws -> CLIStructuredResult {
        let data = stdout.data(using: .utf8)
        let envelope: [String: Any]? = data.flatMap { bytes in
            guard bytes.count <= 4 * 1_024 * 1_024 else { return nil }
            return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        }
        guard let envelope,
              envelope["type"] as? String == "result",
              envelope["subtype"] as? String == "success",
              envelope["is_error"] as? Bool == false,
              let structured = envelope["structured_output"] else {
            throw CLIProviderError.invalidStructuredOutput(
                binary: "claude", detail: claudeStructuredFailureDetail(envelope))
        }
        let text = try canonicalJSONString(structured, binary: "claude")
        let usage = envelope["usage"] as? [String: Any]
        let prompt = nonnegativeInt(usage?["input_tokens"])
            + nonnegativeInt(usage?["cache_creation_input_tokens"])
            + nonnegativeInt(usage?["cache_read_input_tokens"])
        let completion = nonnegativeInt(usage?["output_tokens"])
        return CLIStructuredResult(
            text: text,
            usage: TokenUsage(promptTokens: prompt, completionTokens: completion),
            usageReported: usage != nil)
    }

    static func claudeStructuredFailureDetail(_ envelope: [String: Any]?) -> String {
        let base = "missing successful structured_output envelope"
        guard let envelope else { return base }
        var fields: [String] = []
        if let subtype = envelope["subtype"] as? String {
            fields.append("subtype=\(boundedRedactedDiagnostic(subtype, maxBytes: 64))")
        }
        if let isError = envelope["is_error"] as? Bool {
            fields.append("is_error=\(isError)")
        }
        if let stopReason = envelope["stop_reason"] as? String {
            fields.append("stop_reason=\(boundedRedactedDiagnostic(stopReason, maxBytes: 64))")
        }
        if let errors = envelope["errors"] as? [Any] {
            for (index, item) in errors.prefix(2).enumerated() {
                if let message = item as? String {
                    fields.append(
                        "error[\(index)].message=\(boundedRedactedDiagnostic(message, maxBytes: 192))")
                } else if let object = item as? [String: Any] {
                    if let code = object["code"] as? String {
                        fields.append(
                            "error[\(index)].code=\(boundedRedactedDiagnostic(code, maxBytes: 64))")
                    }
                    if let message = object["message"] as? String {
                        fields.append(
                            "error[\(index)].message=\(boundedRedactedDiagnostic(message, maxBytes: 192))")
                    }
                }
            }
        }
        guard !fields.isEmpty else { return base }
        return boundedRedactedDiagnostic(
            base + " (" + fields.joined(separator: "; ") + ")", maxBytes: 768)
    }

    static func boundedRedactedDiagnostic(_ raw: String, maxBytes: Int) -> String {
        var text = raw.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        for pattern in [
            #"(?i)\b(?:sk|rk|pk)-[A-Za-z0-9_-]{6,}"#,
            #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{6,}"#,
            #"(?i)\b(?:api[_-]?key|access[_-]?token|token|secret|password|credential|authorization)\b\s*[:=]\s*[^,\s;]+"#,
            #"(?i)\bprompt\b\s*[:=]\s*[^,;]+"#,
        ] {
            text = text.replacingOccurrences(
                of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        guard text.utf8.count > maxBytes else { return text }
        let contentLimit = max(0, maxBytes - 3)
        var output = ""
        var byteCount = 0
        for character in text {
            let value = String(character)
            guard byteCount + value.utf8.count <= contentLimit else { break }
            output.append(character)
            byteCount += value.utf8.count
        }
        return output + "..."
    }

    static func parseCodexStructuredResult(
        _ data: Data,
        eventOutput: String
    ) throws -> CLIStructuredResult {
        guard data.count <= 4 * 1_024 * 1_024,
              let value = try? JSONSerialization.jsonObject(with: data) else {
            throw CLIProviderError.invalidStructuredOutput(
                binary: "codex", detail: "final response file is not one JSON value")
        }
        let text = try canonicalJSONString(value, binary: "codex")
        let metering = codexUsage(eventOutput)
        return CLIStructuredResult(text: text, usage: metering.usage, usageReported: metering.reported)
    }

    static func parseCodexTextResult(_ eventOutput: String) throws -> CLIStructuredResult {
        var answer: String?
        var completed = false
        for event in codexEvents(eventOutput) {
            if event["type"] as? String == "turn.completed" { completed = true }
            if event["type"] as? String == "turn.failed" { completed = false }
            if event["type"] as? String == "item.completed",
               let item = event["item"] as? [String: Any],
               item["type"] as? String == "agent_message", let text = item["text"] as? String {
                answer = text
            }
        }
        guard completed, let answer else {
            throw CLIProviderError.invalidStructuredOutput(
                binary: "codex", detail: "no completed turn with a final agent message")
        }
        let metering = codexUsage(eventOutput)
        return CLIStructuredResult(text: answer, usage: metering.usage, usageReported: metering.reported)
    }

    private static func codexEvents(_ eventOutput: String) -> [[String: Any]] {
        eventOutput.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard line.utf8.count <= 4 * 1_024 * 1_024 else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    private static func codexUsage(_ eventOutput: String) -> (usage: TokenUsage, reported: Bool) {
        var usage = TokenUsage.zero
        var usageReported = false
        for event in codexEvents(eventOutput) {
            guard event["type"] as? String == "turn.completed",
                  let rawUsage = event["usage"] as? [String: Any],
                  let input = rawUsage["input_tokens"] as? NSNumber,
                  let output = rawUsage["output_tokens"] as? NSNumber,
                  let inputTokens = Int(input.stringValue), inputTokens >= 0,
                  let outputTokens = Int(output.stringValue), outputTokens >= 0 else { continue }
            usageReported = true
            // Codex input_tokens is the total input; cached_input_tokens is a subset, not extra work.
            // output_tokens likewise already includes reasoning output. Never add either subset twice.
            usage = TokenUsage(
                promptTokens: inputTokens, completionTokens: outputTokens)
        }
        return (usage, usageReported)
    }

    static func processFailureDiagnostic(stdout: String, stderr: String) -> String {
        var messages: [String] = []
        for event in codexEvents(stdout) {
            if let error = event["error"] as? [String: Any], let message = error["message"] as? String {
                messages.append(message)
            } else if event["type"] as? String == "error", let message = event["message"] as? String {
                messages.append(message)
            }
        }
        let stderrLines = stderr.split(whereSeparator: { $0.isNewline }).filter {
            !$0.hasPrefix("Reading prompt from stdin")
        }.suffix(4).joined(separator: "\n")
        if !stderrLines.isEmpty { messages.append(stderrLines) }
        let detail = messages.suffix(5).joined(separator: " | ")
        return boundedRedactedDiagnostic(detail.isEmpty ? "no provider error details" : detail, maxBytes: 1_200)
    }

    private static func canonicalJSONString(_ value: Any, binary: String) throws -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys]) else {
            throw CLIProviderError.invalidStructuredOutput(
                binary: binary, detail: "structured response is not a JSON object or array")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func nonnegativeInt(_ value: Any?) -> Int {
        guard let number = value as? NSNumber else { return 0 }
        return max(0, number.intValue)
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
        outputByteLimit: Int = 4 * 1_024 * 1_024,
        cancellationCheck: @escaping @Sendable () -> Bool = { false }
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
            stdinData: Data(stdin.utf8),
            cancellationCheck: cancellationCheck)
        if outcome.cancelled { throw CancellationError() }
        if outcome.timedOut {
            throw CLIProviderError.timedOut(binary: binaryName, seconds: TimeInterval(timeoutSeconds))
        }
        guard outcome.exitCode >= 0 else {
            throw CLIProviderError.notRunnable(binary: binaryName, detail: outcome.combined)
        }
        guard outcome.exitCode == 0 else {
            throw CLIProviderError.exited(binary: binaryName, code: outcome.exitCode,
                                          stderr: processFailureDiagnostic(
                                            stdout: outcome.stdout, stderr: outcome.stderr))
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
            keyAccount: "", defaultModel: "gpt-5.6-sol",
            availableModels: [AIModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol (subscription)")],
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
                // Keep the reported provider identity honest: Codex CLI accepts explicit subscription
                // model selection, while omission silently delegates to a mutable account default.
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
    case invalidStructuredOutput(binary: String, detail: String)

    public var description: String {
        switch self {
        case .notRunnable(let binary, let detail):
            return "CLI provider '\(binary)' could not start (is it installed and on PATH?): \(detail)"
        case .exited(let binary, let code, let stderr):
            return "CLI provider '\(binary)' exited \(code): \(stderr.isEmpty ? "no stderr" : stderr)"
        case .timedOut(let binary, let seconds):
            return "CLI provider '\(binary)' exceeded its \(seconds)s deadline"
        case .invalidStructuredOutput(let binary, let detail):
            return "CLI provider '\(binary)' returned invalid structured output: \(detail)"
        }
    }

    /// `Error.localizedDescription` is what failure capsules and routing diagnostics surface. Without
    /// `LocalizedError`, Swift bridges this enum as an opaque `CLIProviderError error N` and discards the
    /// exit code/stderr evidence needed to diagnose provider availability.
    public var errorDescription: String? { description }
}

struct CLIStructuredResult: Sendable, Equatable {
    let text: String
    let usage: TokenUsage
    let usageReported: Bool
}

private final class CLIProviderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Owner-private structured request material for Codex CLI. Files are created with openat/O_EXCL,
/// never follow links, and are unlinked before the private directory is fsynced and removed.
final class CLIStructuredRequestFiles: @unchecked Sendable {
    let directoryPath: String
    let schemaPath: String
    let resultPath: String?
    private let directoryFD: Int32
    private let lock = NSLock()
    private var cleaned = false

    init(canonicalSchema: String, needsResultFile: Bool) throws {
        var template = Array("/tmp/kist-cli-structured.XXXXXX".utf8CString)
        guard template.withUnsafeMutableBufferPointer({ buffer in
            buffer.baseAddress.flatMap { mkdtemp($0) }
        }) != nil else {
            throw CLIProviderError.notRunnable(
                binary: "codex", detail: "could not create private structured-output directory")
        }
        let directory = String(cString: template)
        guard chmod(directory, S_IRWXU) == 0 else {
            _ = rmdir(directory)
            throw CLIProviderError.notRunnable(
                binary: "codex", detail: "could not protect structured-output directory")
        }
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            _ = rmdir(directory)
            throw CLIProviderError.notRunnable(
                binary: "codex", detail: "could not open structured-output directory")
        }
        directoryPath = directory
        directoryFD = fd
        schemaPath = directory + "/schema.json"
        resultPath = needsResultFile ? directory + "/result.json" : nil
        do {
            try Self.createFile(
                directoryFD: fd, name: "schema.json", data: Data(canonicalSchema.utf8))
            if needsResultFile {
                try Self.createFile(directoryFD: fd, name: "result.json", data: Data())
            }
            guard fsync(fd) == 0 else {
                throw CLIProviderError.notRunnable(
                    binary: "codex", detail: "could not sync structured-output directory")
            }
        } catch {
            if needsResultFile { _ = unlinkat(fd, "result.json", 0) }
            _ = unlinkat(fd, "schema.json", 0)
            _ = fsync(fd)
            close(fd)
            _ = rmdir(directory)
            throw error
        }
    }

    deinit { cleanup() }

    func readResult(maxBytes: Int = 4 * 1_024 * 1_024) throws -> Data {
        guard resultPath != nil else {
            throw CLIProviderError.invalidStructuredOutput(
                binary: "codex", detail: "final response file was not configured")
        }
        let fd = openat(directoryFD, "result.json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw CLIProviderError.invalidStructuredOutput(
                binary: "codex", detail: "final response file is unavailable")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              (info.st_mode & (S_IRWXG | S_IRWXO)) == 0 else {
            throw CLIProviderError.invalidStructuredOutput(
                binary: "codex", detail: "final response file identity or permissions drifted")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maxBytes else {
                    throw CLIProviderError.invalidStructuredOutput(
                        binary: "codex", detail: "final response exceeds byte limit")
                }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            guard count == 0 else {
                throw CLIProviderError.invalidStructuredOutput(
                    binary: "codex", detail: "could not read final response")
            }
            return data
        }
    }

    func cleanup() {
        lock.lock()
        guard !cleaned else { lock.unlock(); return }
        cleaned = true
        lock.unlock()
        if resultPath != nil { _ = unlinkat(directoryFD, "result.json", 0) }
        _ = unlinkat(directoryFD, "schema.json", 0)
        _ = fsync(directoryFD)
        close(directoryFD)
        _ = rmdir(directoryPath)
    }

    private static func createFile(
        directoryFD: Int32, name: String, data: Data
    ) throws {
        let fd = openat(
            directoryFD, name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CLIProviderError.notRunnable(
                binary: "codex", detail: "could not create private \(name)")
        }
        defer { close(fd) }
        var offset = 0
        let wrote = data.withUnsafeBytes { bytes -> Bool in
            while offset < bytes.count {
                let count = write(
                    fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
        guard wrote, fchmod(fd, S_IRUSR | S_IWUSR) == 0, fsync(fd) == 0 else {
            throw CLIProviderError.notRunnable(
                binary: "codex", detail: "could not persist private \(name)")
        }
    }
}
