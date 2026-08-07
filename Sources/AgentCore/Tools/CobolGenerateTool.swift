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
    public let description = "Generate GnuCOBOL-compatible COBOL source from a plain-English request "
        + "using the LOCAL, OFFLINE cobol-jeeves specialist model. Returns COBOL source only. Use this "
        + "for ALL COBOL codegen (writing or modifying a program) instead of writing COBOL yourself — "
        + "it is a fine-tuned COBOL expert. Then write the result to a .cbl file and compile with `cobc "
        + "-x`. Offline, no key, no cost."
    public let parameters = [
        ToolParameter(name: "request", type: "string",
                      description: "What COBOL to write, in plain English (e.g. 'read employees.dat, a CSV of name,hours,rate, and print each employee's gross pay with 1.5x overtime past 40 hours').",
                      required: true),
        ToolParameter(name: "existing", type: "string",
                      description: "Optional existing COBOL source to MODIFY instead of writing from scratch.",
                      required: false),
        ToolParameter(name: "path", type: "string",
                      description: "Optional project-relative path (e.g. 'payroll.cbl'). If given, the generated COBOL is WRITTEN to that file (confined to the project root) so the artifact is real — then just compile it with cobc. Recommended.",
                      required: false),
    ]

    private let providers: ProviderRegistry
    public init(providers: ProviderRegistry) { self.providers = providers }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        guard let request = (arguments["request"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !request.isEmpty else {
            return .failure("cobol_generate needs a 'request' describing what COBOL to write")
        }
        let existing = (arguments["existing"] as? String) ?? ""
        let system = "You are an expert GnuCOBOL programmer. Output ONLY valid, complete, compilable "
            + "COBOL source — no prose, no explanation, no markdown code fences. Target `cobc -x`. "
            + "Include the IDENTIFICATION / DATA / PROCEDURE divisions as needed and end with STOP RUN."
        let user = existing.isEmpty
            ? "Write COBOL for: \(request)"
            : "Modify this COBOL as requested; output the FULL updated source only.\n\nRequest: \(request)\n\nExisting source:\n\(existing)"

        do {
            // allowFallback:false — MUST stay on the offline COBOL specialist. The whole point is a
            // local, no-cost COBOL expert; silently falling back to a cloud model would defeat it (and
            // spend money/keys the caller didn't ask for).
            let (text, _) = try await providers.completeWithUsage(
                providerId: "cobol", model: nil,
                messages: [ChatMessage(role: .user, content: user)],
                settings: ModelSettings(temperature: 0.2, maxTokens: 2048, systemPrompt: system),
                allowFallback: false)
            let cobol = Self.stripCodeFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cobol.isEmpty else {
                return .failure("cobol_generate: the offline model returned no source — is Ollama running and `cobol-jeeves-ft` pulled?")
            }
            // If a path was given, PERSIST the source (confined to the project root) so the artifact is
            // real and can't be fabricated downstream — the caller then only has to `cobc` it. Reuses the
            // same ConfinedRoot boundary the file tools use (no escape, no symlink follow).
            if let rawPath = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawPath.isEmpty {
                do {
                    let abs = try context.resolvedPath(rawPath, mustExist: false)
                    try (cobol + "\n").write(toFile: abs, atomically: true, encoding: .utf8)
                    let lines = cobol.split(separator: "\n", omittingEmptySubsequences: false).count
                    return ToolResult(success: true,
                                      output: "wrote \(lines) lines of COBOL to \(rawPath) — now compile it with `cobc -x -o <bin> \(rawPath)` and run it.\n\n" + cobol,
                                      metadata: ["provider": "cobol", "offline": "true", "path": rawPath, "wrote": "true"])
                } catch {
                    return .failure("cobol_generate produced COBOL but could not write it to \(rawPath): \(error)")
                }
            }
            return ToolResult(success: true, output: cobol,
                              metadata: ["provider": "cobol", "offline": "true"])
        } catch {
            return .failure("cobol_generate failed — the offline cobol model is unavailable "
                + "(start Ollama and `ollama pull cobol-jeeves-ft`): \(error)")
        }
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
