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
        + "yourself. With a `path` it WRITES + COMPILES the file (cobc) and returns only on a clean "
        + "build; add `expect` (a substring of the program's stdout, e.g. '120') to also RUN it and "
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

    private let providers: ProviderRegistry
    public init(providers: ProviderRegistry) { self.providers = providers }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        guard let request = (arguments["request"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !request.isEmpty else {
            return .failure("cobol_generate needs a 'request' describing what COBOL to write")
        }
        let existing = (arguments["existing"] as? String) ?? ""
        let rawPath = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expect = (arguments["expect"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // FEEDBACK-DRIVEN generation: on a compile error or wrong output we regenerate ONCE with the
        // failure described, so the specialist self-corrects instead of shipping broken/wrong COBOL.
        var feedback = ""
        var lastCobol = ""
        var lastDetail = ""
        for attempt in 1...Self.maxAttempts {
            let cobol: String
            do {
                cobol = try await generate(request: request, existing: existing, feedback: feedback)
            } catch {
                return .failure("cobol_generate failed — the offline cobol model is unavailable "
                    + "(start Ollama and `ollama pull cobol-jeeves-ft`): \(error)")
            }
            guard !cobol.isEmpty else {
                return .failure("cobol_generate: the offline model returned no source — is Ollama running and `cobol-jeeves-ft` pulled?")
            }
            lastCobol = cobol

            // No path ⇒ pure codegen (no artifact, no verification). Return the source.
            guard !rawPath.isEmpty else {
                return ToolResult(success: true, output: cobol,
                                  metadata: ["provider": "cobol", "offline": "true"])
            }

            // Persist to the confined path (same ConfinedRoot boundary the file tools use).
            let abs: String
            do { abs = try context.resolvedPath(rawPath, mustExist: false) }
            catch { return .failure("cobol_generate produced COBOL but could not resolve \(rawPath): \(error)") }
            do { try (cobol + "\n").write(toFile: abs, atomically: true, encoding: .utf8) }
            catch { return .failure("cobol_generate produced COBOL but could not write it to \(rawPath): \(error)") }
            let lines = cobol.split(separator: "\n", omittingEmptySubsequences: false).count

            // SELF-VERIFY: compile it. cobc absent ⇒ fail-soft (can't verify here; the file is real).
            let env = RunCommandTool.scrubbedEnvironment()
            guard let cobc = RunCommandTool.resolveExecutable("cobc", env: env, cwd: context.projectRoot) else {
                return ToolResult(success: true,
                                  output: "wrote \(lines) lines of COBOL to \(rawPath). (cobc not found — compile it yourself to verify.)\n\n" + cobol,
                                  metadata: ["provider": "cobol", "offline": "true", "path": rawPath, "wrote": "true", "changed": "true"])
            }
            let stem = ((rawPath as NSString).lastPathComponent as NSString).deletingPathExtension
            let binName = stem.isEmpty ? "a.out" : stem
            let compile = await RunCommandTool.spawnAndCollect(
                launchPath: cobc, launchArgs: ["-x", "-o", binName, rawPath],
                cwd: context.projectRoot, timeout: 60)
            if !compile.success {
                lastDetail = "compile failed: " + (compile.error ?? compile.output)
                feedback = "The previous COBOL FAILED to compile with `cobc -x`. Fix it. Compiler output:\n"
                    + String((compile.error ?? compile.output).prefix(1500))
                if attempt < Self.maxAttempts { continue }
                return .failure("cobol_generate: the generated COBOL does not compile after \(attempt) attempts.\n\(lastDetail)\n\n(last source written to \(rawPath))")
            }

            // Compiled. If no `expect`, that's a real, grounded success — the source builds.
            guard !expect.isEmpty else {
                return ToolResult(success: true,
                                  output: "wrote \(lines) lines of COBOL to \(rawPath) and it COMPILED clean with cobc.\n\n" + cobol,
                                  metadata: ["provider": "cobol", "offline": "true", "path": rawPath, "wrote": "true", "changed": "true", "compiled": "true"])
            }

            // RUN it and check the output contains the expected text.
            guard let binAbs = RunCommandTool.resolveExecutable("./" + binName, env: env, cwd: context.projectRoot) else {
                return .failure("cobol_generate compiled \(rawPath) but the binary \(binName) is missing — cannot verify output")
            }
            let run = await RunCommandTool.spawnAndCollect(
                launchPath: binAbs, launchArgs: [], cwd: context.projectRoot, timeout: 30)
            let ran = run.output
            if ran.contains(expect) {
                return ToolResult(success: true,
                                  output: "wrote \(lines) lines to \(rawPath), COMPILED, and RAN — output contains \"\(expect)\" ✓\n\nprogram output:\n\(ran)\n\nsource:\n\(cobol)",
                                  metadata: ["provider": "cobol", "offline": "true", "path": rawPath, "wrote": "true", "changed": "true", "compiled": "true", "ran": "true", "expect_met": "true"])
            }
            lastDetail = "compiled + ran, but output \"\(ran.prefix(120))\" does not contain expected \"\(expect)\""
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
            return .failure("cobol_generate: after \(attempt) attempts the program compiles+runs but is LOGICALLY WRONG — \(lastDetail). Not claiming success on wrong output. (last source at \(rawPath))")
        }
        // Unreachable in practice (the loop returns), but keep the compiler happy + honest.
        return .failure("cobol_generate exhausted its attempts. Last detail: \(lastDetail.isEmpty ? "no source produced" : lastDetail)\n\(lastCobol)")
    }

    /// One model call to the OFFLINE cobol provider. `allowFallback:false` keeps it local (never a
    /// cloud model). `feedback` (compiler error / wrong-output note) is appended so it self-corrects.
    private func generate(request: String, existing: String, feedback: String) async throws -> String {
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
            providerId: "cobol", model: nil,
            messages: [ChatMessage(role: .user, content: user)],
            settings: ModelSettings(temperature: 0.2, maxTokens: 2048, systemPrompt: system),
            allowFallback: false)
        return Self.stripCodeFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
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
