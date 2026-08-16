import Foundation

/// Generate COBOL source from a natural-language request using the LOCAL, OFFLINE cobol-jeeves
/// specialist model (the `cobol` provider).
///
/// Why this exists (2026-08-07 dogfood finding): cobol-jeeves is a COBOL *completion* model, NOT a
/// tool-calling agent — it can't drive kist's agent loop (its 32k context can't hold the ~37k tool
/// protocol, and a 7B specialist doesn't reliably emit the JSON action protocol). But it writes
/// excellent COBOL from a SHORT focused prompt. So the RIGHT design is: a strong agent DRIVES the
/// build (write files, run cobc, verify output) and calls THIS tool for the COBOL codegen. The
/// specialist does the one thing it's great at — offline, no key, no cost.
public struct CobolGenerateTool: AgentTool {
    public let name = "cobol_generate"
    public let description = "Generate GnuCOBOL COBOL from a plain-English request using the LOCAL, "
        + "OFFLINE cobol-jeeves specialist. Use this for ALL COBOL codegen instead of writing COBOL "
        + "yourself. With a `path` it WRITES + COMPILES through governed run_command execution and "
        + "returns only with complete sandbox evidence; add `expect` (a substring of stdout) to RUN it and "
        + "verify the output — the tool self-heals once and REFUSES to succeed on broken or wrong "
        + "COBOL. Offline, no key, no cost."
    public let parameters = [
        ToolParameter(name: "request", type: "string",
                      description: "What COBOL to write, in plain English (e.g. 'read employees.dat, a CSV of name,hours,rate, and print each employee's gross pay with 1.5x overtime past 40 hours').",
                      required: true),
        ToolParameter(name: "existing", type: "string",
                      description: "Optional existing COBOL source to MODIFY instead of writing from scratch.",
                      required: false),
        ToolParameter(name: "path", type: "string",
                      description: "Optional project-relative path (e.g. 'payroll.cbl'). If given, the generated COBOL is WRITTEN to that file (confined to the project root) AND compiled with cobc — so the artifact is real and proven to build. Recommended.",
                      required: false),
        ToolParameter(name: "expect", type: "string",
                      description: "Optional expected substring of the program's stdout (e.g. '120'). If given (with a path), the tool COMPILES + RUNS the program and only succeeds when the output contains this — self-healing once if the compile fails or the logic is wrong. Use it to guarantee the generated COBOL is actually correct.",
                      required: false),
    ]

    /// Total model attempts. The 7B specialist writes compilable COBOL but its logic can be wrong (short
    /// PIC widths truncate strings, factorial off-by-one, etc.); a couple feedback rounds catch most
    /// misses without unbounded cost. 3 = original + 2 self-heals.
    static let maxAttempts = 3

    struct GovernedCommand: Sendable, Equatable {
        let executable: String
        let arguments: [String]
        let timeout: Int
    }

    typealias CommandExecutor = @Sendable (GovernedCommand, ToolContext) async -> ToolResult
    typealias SourceGenerator = @Sendable (_ request: String, _ existing: String,
                                           _ feedback: String, _ model: String) async throws -> String

    private let providers: ProviderRegistry
    private let environment: @Sendable () -> [String: String]
    private let commandExecutor: CommandExecutor
    private let sourceGenerator: SourceGenerator?

    public init(providers: ProviderRegistry) {
        self.init(providers: providers,
                  environment: { ProcessInfo.processInfo.environment },
                  commandExecutor: nil, sourceGenerator: nil)
    }

    init(providers: ProviderRegistry,
         environment: @escaping @Sendable () -> [String: String],
         commandExecutor: CommandExecutor?, sourceGenerator: SourceGenerator?) {
        self.providers = providers
        self.environment = environment
        self.commandExecutor = commandExecutor ?? { command, context in
            await ToolRegistry([RunCommandTool()]).execute(name: "run_command", arguments: [
                "executable": command.executable,
                "args": command.arguments,
                "cwd": ".",
                "timeout": command.timeout,
                "allowed_exit_codes": [0],
            ], context: context)
        }
        self.sourceGenerator = sourceGenerator
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        guard let request = (arguments["request"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !request.isEmpty else {
            return .failure("cobol_generate needs a 'request' describing what COBOL to write")
        }
        let existing = (arguments["existing"] as? String) ?? ""
        let rawPath = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expect = (arguments["expect"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let endpoint: String
        do { endpoint = try Self.normalizedLoopbackEndpoint(environment: environment()) }
        catch { return .failure("cobol_generate refused non-loopback Ollama endpoint: \(error.localizedDescription)") }
        guard let provider = providers.provider(id: "cobol") else {
            return .failure("cobol_generate: the local cobol provider is not registered")
        }
        let concreteModel = provider.resolvedModel(nil)
        let provenance: [String: String] = [
            "provider": "cobol", "model": concreteModel, "offline": "true", "endpoint": endpoint,
            "compiled": "false", "ran": "false", "expect_met": "false",
            "verification_eligible": "false",
        ]

        // Path mode is a mutation/verification request. Preflight through the same governed,
        // sandbox-required run_command path before spending a model call or touching the target.
        if !rawPath.isEmpty {
            guard context.sandbox.enabled else {
                return Self.failure("cobol_generate path mode requires the OS sandbox", metadata: provenance)
            }
            let preflight = await commandExecutor(
                GovernedCommand(executable: "cobc", arguments: ["--version"], timeout: 30), context)
            if let issue = Self.governedCommandIssue(preflight) {
                return Self.failure("cobol_generate cannot verify path mode because cobc preflight failed: \(issue)",
                                    metadata: provenance)
            }
        }

        // FEEDBACK-DRIVEN generation: on a compile error or wrong output we regenerate ONCE with the
        // failure described, so the specialist self-corrects instead of shipping broken/wrong COBOL.
        var feedback = ""
        var lastCobol = ""
        var lastDetail = ""
        for attempt in 1...Self.maxAttempts {
            let cobol: String
            do {
                if let sourceGenerator {
                    cobol = try await sourceGenerator(request, existing, feedback, concreteModel)
                } else {
                    cobol = try await generate(request: request, existing: existing,
                                               feedback: feedback, model: concreteModel)
                }
            } catch {
                return Self.failure("cobol_generate failed - the offline cobol model is unavailable "
                    + "(start Ollama and `ollama pull cobol-jeeves-ft`): \(error)", metadata: provenance)
            }
            guard !cobol.isEmpty else {
                return Self.failure("cobol_generate: the offline model returned no source - is Ollama running and `cobol-jeeves-ft` pulled?",
                                    metadata: provenance)
            }
            lastCobol = cobol
            let sourceDigest = Self.sha256Hex(Data(cobol.utf8))
            var sourceMetadata = provenance
            sourceMetadata["source_sha256"] = sourceDigest

            // No path ⇒ pure codegen (no artifact, no verification). Return the source.
            guard !rawPath.isEmpty else {
                return ToolResult(success: true, output: cobol,
                                  metadata: sourceMetadata)
            }

            // Descriptor-confined atomic write; never resolve then reopen a pathname.
            let confined: ConfinedRoot
            do {
                confined = try context.confinedRoot()
                try confined.writeString(rawPath, cobol, createParents: true)
            } catch {
                return Self.failure("cobol_generate produced COBOL but could not write it to \(rawPath): \(error)",
                                    metadata: sourceMetadata)
            }
            let lines = cobol.split(separator: "\n", omittingEmptySubsequences: false).count

            let buildDirectory = ".kist/cobol-generate/\(sourceDigest.prefix(16))"
            let binaryPath = "\(buildDirectory)/program"
            do {
                try confined.makeDirectory(buildDirectory)
                if try confined.fileType(binaryPath).exists { try confined.removeFile(binaryPath) }
            } catch {
                return Self.failure("cobol_generate could not prepare isolated build output: \(error)",
                                    metadata: sourceMetadata)
            }
            let compileArgs = ["-x", "-o", binaryPath, rawPath]
            let compile = await commandExecutor(
                GovernedCommand(executable: "cobc", arguments: compileArgs, timeout: 60), context)
            if let issue = Self.governedCommandIssue(compile) {
                lastDetail = "compile failed: " + issue
                feedback = "The previous COBOL FAILED to compile with `cobc -x`. Fix it. Compiler output:\n"
                    + String(issue.prefix(1500))
                if attempt < Self.maxAttempts { continue }
                return Self.failure("cobol_generate: the generated COBOL does not compile after \(attempt) attempts.\n\(lastDetail)\n\n(last source written to \(rawPath))",
                                    metadata: sourceMetadata.merging(["path": rawPath, "wrote": "true", "changed": "true"]) { _, new in new })
            }

            var compiledMetadata = sourceMetadata
            compiledMetadata.merge(["path": rawPath, "wrote": "true", "changed": "true",
                                    "compiled": "true", "sandboxed": "true",
                                    "verification_eligible": "true"]) { _, new in new }

            // Compiled. If no `expect`, this proves only sandboxed compilation.
            guard !expect.isEmpty else {
                return ToolResult(success: true,
                                  output: "wrote \(lines) lines of COBOL to \(rawPath) and verified a sandboxed cobc compile.\n\n" + cobol,
                                  metadata: compiledMetadata)
            }

            // RUN through governed execution. Only clean stdout from an exit-0, sandboxed,
            // non-truncated process can satisfy the assertion.
            let executable = "./\(binaryPath)"
            let run = await commandExecutor(
                GovernedCommand(executable: executable, arguments: [], timeout: 30), context)
            if Self.governedCommandIssue(run, expectedStdout: expect) == nil,
               let ran = run.metadata["stdout"] {
                var runMetadata = compiledMetadata
                runMetadata.merge(["ran": "true", "expect_met": "true"]) { _, new in new }
                return ToolResult(success: true,
                                  output: "wrote \(lines) lines to \(rawPath), compiled and ran in the sandbox; stdout contains \"\(expect)\".\n\nprogram stdout:\n\(ran)\n\nsource:\n\(cobol)",
                                  metadata: runMetadata)
            }
            let issue = Self.governedCommandIssue(run, expectedStdout: expect)
                ?? "runtime evidence was incomplete"
            let ran = run.metadata["stdout"] ?? ""
            lastDetail = "runtime verification failed: \(issue)"
            // Diagnostic feedback: name the LIKELY GnuCOBOL cause so the small model can actually fix it.
            let gotOut = ran.trimmingCharacters(in: .whitespacesAndNewlines)
            var hint = "Fix the LOGIC so the output contains it."
            if expect.contains(gotOut) && !gotOut.isEmpty {
                hint = "The output looks TRUNCATED (a prefix of the expected text) — a PIC X(n) field is "
                    + "too NARROW; widen it to at least \(expect.count) characters, or DISPLAY the literal directly."
            } else if gotOut.contains(where: { $0 == "0" }) && expect.first(where: { $0.isNumber }) != nil
                        && gotOut.hasPrefix("0") {
                hint = "The number shows LEADING ZEROS — DISPLAY it through an edited PIC like Z(9)9 instead of a raw 9(n)."
            }
            feedback = "The previous COBOL compiled and RAN but produced the WRONG output. It printed:\n"
                + String(ran.prefix(500)) + "\nExpected the output to contain: \(expect)\n" + hint
            if attempt < Self.maxAttempts { continue }
            return Self.failure("cobol_generate: after \(attempt) attempts runtime verification failed - \(lastDetail). Not claiming success. (last source at \(rawPath))",
                                metadata: compiledMetadata)
        }
        // Unreachable in practice (the loop returns), but keep the compiler happy + honest.
        return .failure("cobol_generate exhausted its attempts. Last detail: \(lastDetail.isEmpty ? "no source produced" : lastDetail)\n\(lastCobol)")
    }

    /// One model call to the OFFLINE cobol provider. `allowFallback:false` keeps it local (never a
    /// cloud model). `feedback` (compiler error / wrong-output note) is appended so it self-corrects.
    private func generate(request: String, existing: String, feedback: String,
                          model: String) async throws -> String {
        // Curated GnuCOBOL guidance — steers the small specialist away from the bugs it actually makes
        // (dogfood 2026-08-08): the USING-clause non-executable, PIC-width string truncation, and
        // leading-zero numeric display. This "grounding" targets real observed failures.
        let system = "You are an expert GnuCOBOL programmer. Output ONLY valid, complete, compilable "
            + "COBOL source — no prose, no explanation, no markdown code fences. Rules:\n"
            + "• Write a STANDALONE EXECUTABLE for `cobc -x`: NO LINKAGE SECTION, NO `USING` clause on "
            + "PROCEDURE DIVISION, NO GOBACK. Compute in WORKING-STORAGE, end with STOP RUN.\n"
            + "• Size PIC clauses to fit: an alphanumeric field must be PIC X(n) with n ≥ the LONGEST "
            + "text it will hold (too-short X(n) SILENTLY TRUNCATES). Prefer DISPLAYing string literals "
            + "directly when possible.\n"
            + "• For numbers: do ALL arithmetic in a PLAIN numeric field (PIC 9(n) or S9(n), wide enough "
            + "for the result). To DISPLAY without leading zeros, declare a SEPARATE edited field (PIC "
            + "Z(9)9), MOVE the numeric result INTO it, and DISPLAY that field. NEVER use an edited "
            + "(Z/comma/$) field in COMPUTE/MULTIPLY/ADD — it is not numeric.\n"
            + "• Include the IDENTIFICATION / DATA / PROCEDURE divisions as needed."
        var user = existing.isEmpty
            ? "Write COBOL for: \(request)"
            : "Modify this COBOL as requested; output the FULL updated source only.\n\nRequest: \(request)\n\nExisting source:\n\(existing)"
        if !feedback.isEmpty { user += "\n\n" + feedback }
        let (text, _) = try await providers.completeWithUsage(
            providerId: "cobol", model: model,
            messages: [ChatMessage(role: .user, content: user)],
            settings: ModelSettings(temperature: 0.2, maxTokens: 2048, systemPrompt: system),
            allowFallback: false)
        let source = Self.stripCodeFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? source : source + "\n"
    }

    static func normalizedLoopbackEndpoint(environment: [String: String]) throws -> String {
        guard let rawValue = environment["OLLAMA_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return "http://127.0.0.1:11434" }
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "http",
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              let parsedHost = components.host?.lowercased() else {
            throw CobolGenerateContractError.invalidEndpoint
        }
        let host = parsedHost.hasPrefix("[") && parsedHost.hasSuffix("]")
            ? String(parsedHost.dropFirst().dropLast()) : parsedHost
        guard host == "127.0.0.1" || host == "::1" else {
            throw CobolGenerateContractError.invalidEndpoint
        }
        let port = components.port ?? 11434
        guard (1...65_535).contains(port) else { throw CobolGenerateContractError.invalidEndpoint }
        return host == "::1" ? "http://[::1]:\(port)" : "http://127.0.0.1:\(port)"
    }

    static func governedCommandIssue(_ result: ToolResult, expectedStdout: String? = nil) -> String? {
        guard result.success else { return result.error ?? result.output }
        let metadata = result.metadata
        guard metadata["sandboxed"] == "true",
              metadata["timed_out"] == "false",
              metadata["was_signalled"] == "false",
              metadata["stdout_truncated"] == "false",
              metadata["stderr_truncated"] == "false",
              metadata["output_truncated"] == "false",
              metadata["verification_eligible"] == "true",
              metadata["exit_code"] == "0",
              metadata["stdout"] != nil, metadata["stderr"] != nil else {
            return "missing complete sandboxed exit-0 command evidence"
        }
        if let expectedStdout, metadata["stdout"]?.contains(expectedStdout) != true {
            return "stdout did not contain the required expectation"
        }
        return nil
    }

    private static func sha256Hex(_ data: Data) -> String {
        MythosCrypto.sha256(data).map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(_ message: String, metadata: [String: String]) -> ToolResult {
        ToolResult(success: false, output: "", error: message, metadata: metadata)
    }

    /// The model is told not to, but small models still sometimes wrap output in ``` fences — strip a
    /// single leading fence (+ optional language tag) and a trailing fence so callers get raw COBOL.
    static func stripCodeFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = t.range(of: "```") else { return t }
        t = String(t[open.upperBound...])
        // Drop a short language tag on the fence's first line (e.g. "cobol").
        if let nl = t.firstIndex(of: "\n") {
            let firstLine = t[..<nl].trimmingCharacters(in: .whitespaces)
            if firstLine.count <= 8 && !firstLine.isEmpty {
                t = String(t[t.index(after: nl)...])
            }
        }
        if let close = t.range(of: "```") { t = String(t[..<close.lowerBound]) }
        return t
    }
}

private enum CobolGenerateContractError: LocalizedError {
    case invalidEndpoint
    var errorDescription: String? {
        "OLLAMA_HOST must be unset or an http URL using numeric 127.0.0.1/::1 only, with no credentials, path, query, or fragment"
    }
}
