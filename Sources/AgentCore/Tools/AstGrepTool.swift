import Foundation

// Structural (AST-aware) code search & rewrite via the `ast-grep` binary (MIT).
//
// ast-grep matches by code STRUCTURE, not text, so a single pattern reliably hits
// EVERY call site — the exact failure mode behind kist's recurring multi-site bugs
// (a `replace_all` that missed the one site with different indentation). Two tools,
// split along the codebase's read-only-vs-sensitive line:
//
//   • `ast_grep`       — read-only search, and rewrite PREVIEW (a diff; writes nothing).
//                        Spawned directly, works with shell OFF, exactly like search_code.
//   • `ast_grep_apply` — applies a structural rewrite IN PLACE. Mutating, so it is
//                        shell-gated (structured binaryRefusalReason) AND approval-gated
//                        (listed in KistRunner.sensitiveTools).
//
// Both degrade gracefully when ast-grep isn't installed: a clear install hint, never a crash.

enum AstGrep {
    /// Canonical binary name. We deliberately do NOT fall back to the `sg` alias — `sg`
    /// collides with unrelated system binaries and we must never spawn the wrong one.
    static let binaryName = "ast-grep"

    static let installHint =
        "ast_grep unavailable: the `ast-grep` binary is not installed. Install it "
        + "(macOS: `brew install ast-grep`; or `npm i -g @ast-grep/cli`) and retry."

    /// Resolve ast-grep from a FIXED set of standard absolute install dirs only. We do NOT
    /// fall through to $PATH: a mutating tool must never spawn a binary whose location an
    /// attacker-controlled PATH entry could shadow. brew / npm-global land ast-grep in these.
    static let binaryDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static func binaryPath() -> String? {
        for dir in binaryDirs {
            let p = dir + "/" + binaryName
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Resolve `relPath` to a real filesystem path and REFUSE if it escapes `rootPath` via
    /// ANY symlink. `relativeComponents` is only a lexical check — a repo-contained symlink
    /// pointing outside root would otherwise be scanned (read leak) or rewritten (worse).
    /// Returns the canonical path, or nil when it doesn't exist yet (ast-grep then finds
    /// nothing — no escape possible). Throws `.pathEscape` on a real out-of-root target.
    static func assertConfined(relPath: String, rootPath: String) throws {
        let abs = relPath == "." ? rootPath : rootPath + "/" + relPath
        guard let real = ToolContext.canonicalize(abs) else { return }   // missing target: safe no-op
        guard real == rootPath || real.hasPrefix(rootPath + "/") else {
            throw ToolError.pathEscape(path: relPath, root: rootPath)
        }
    }

    /// Pure argv builder for `ast-grep run` — unit-tested without spawning anything.
    /// `--` terminates flag parsing so a hostile pattern/path is argv, never a flag or
    /// shell token (the process is spawned directly, no shell to reinterpret it).
    static func runArgs(pattern: String, rewrite: String?, lang: String?, relPath: String, apply: Bool) -> [String] {
        var args = ["run", "--color", "never", "--pattern", pattern]
        if let rewrite { args += ["--rewrite", rewrite] }
        if let lang, !lang.isEmpty { args += ["--lang", lang] }
        if apply { args.append("--update-all") }
        args += ["--", relPath]
        return args
    }
}

/// Read-only structural search + rewrite preview. Not approval-gated (mirrors search_code).
public struct AstGrepTool: AgentTool {
    public let name = "ast_grep"
    public let description = "Structural (AST-aware) code search, and rewrite PREVIEW. Matches by code structure, not text — the reliable way to find EVERY site of a pattern. Set `rewrite` to preview a structural replacement as a diff (writes NOTHING; use ast_grep_apply to write). Read-only, works without shell. Needs the ast-grep binary."
    public let parameters = [
        ToolParameter(name: "pattern", type: "string", description: "ast-grep structural pattern, e.g. \"console.log($A)\" or \"foo($$$ARGS)\"", required: true),
        ToolParameter(name: "rewrite", type: "string", description: "Optional replacement pattern; when set, returns a DIFF PREVIEW (no files changed)", required: false),
        ToolParameter(name: "lang", type: "string", description: "Language: swift, js, ts, tsx, py, rust, go, java, c, cpp… (inferred from file extensions if omitted)", required: false),
        ToolParameter(name: "path", type: "string", description: "File or directory under the project root to scan (default: whole project)", required: false),
        ToolParameter(name: "limit", type: "integer", description: "Max output lines (default 300)", required: false),
    ]
    public var usageExamples: [String] {
        ["ast_grep(pattern=\"orderBy: { createdAt: $DIR }\", lang=\"ts\")",
         "ast_grep(pattern=\"print($A)\", rewrite=\"logger.debug($A)\", lang=\"swift\")"]
    }
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let pattern = try requireString("pattern", from: arguments)
        let rewrite = arguments["rewrite"] as? String
        let lang = arguments["lang"] as? String
        let limit = max(1, optionalInt("limit", from: arguments) ?? 300)

        let confined = try context.confinedRoot()
        let base = (arguments["path"] as? String) ?? "."
        let comps = try confined.relativeComponents(base)     // lexical: rejects ../ and absolute escapes
        let relPath = comps.isEmpty ? "." : comps.joined(separator: "/")
        try AstGrep.assertConfined(relPath: relPath, rootPath: confined.rootPath)   // symlink-escape guard

        guard let bin = AstGrep.binaryPath() else { return .failure(AstGrep.installHint) }
        let args = AstGrep.runArgs(pattern: pattern, rewrite: rewrite, lang: lang, relPath: relPath, apply: false)
        let (out, timedOut) = SearchCodeTool.runProcess(bin, args, cwd: confined.rootPath, maxBytes: 300_000, timeout: 30)

        var lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        let truncated = lines.count > limit || timedOut
        if lines.count > limit { lines = Array(lines.prefix(limit)) }
        let body = lines.isEmpty ? "(no matches)" : lines.joined(separator: "\n")
        return ToolResult(success: true,
                          output: timedOut ? body + "\n… (ast-grep timed out; narrow the path or pattern)" : body,
                          metadata: ["engine": "ast-grep", "mode": rewrite == nil ? "search" : "preview",
                                     "lines": String(lines.count), "truncated": String(truncated)])
    }
}

/// Applies a structural rewrite in place across every matching site. MUTATING → gated.
public struct AstGrepApplyTool: AgentTool {
    public let name = "ast_grep_apply"
    public let description = "Apply a structural (AST-aware) rewrite IN PLACE across every matching site in one shot — the safe way to fix a pattern everywhere at once. Mutating: requires shell enabled + approval. Preview first with ast_grep."
    public let parameters = [
        ToolParameter(name: "pattern", type: "string", description: "ast-grep structural pattern to match", required: true),
        ToolParameter(name: "rewrite", type: "string", description: "Replacement pattern applied to every match", required: true),
        ToolParameter(name: "lang", type: "string", description: "Language: swift, js, ts, tsx, py, rust, go, java, c, cpp… (inferred if omitted)", required: false),
        ToolParameter(name: "path", type: "string", description: "File or directory under the project root to rewrite (default: whole project)", required: false),
    ]
    public var usageExamples: [String] {
        ["ast_grep_apply(pattern=\"orderBy: { createdAt: asc }\", rewrite=\"orderBy: { createdAt: desc }\", lang=\"ts\")"]
    }
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let pattern = try requireString("pattern", from: arguments)
        let rewrite = try requireString("rewrite", from: arguments)
        let lang = arguments["lang"] as? String

        let confined = try context.confinedRoot()
        let base = (arguments["path"] as? String) ?? "."
        let comps = try confined.relativeComponents(base)     // lexical confinement
        let relPath = comps.isEmpty ? "." : comps.joined(separator: "/")
        try AstGrep.assertConfined(relPath: relPath, rootPath: confined.rootPath)   // symlink-escape guard (writes stay in root)

        guard let bin = AstGrep.binaryPath() else { return .failure(AstGrep.installHint) }
        let args = AstGrep.runArgs(pattern: pattern, rewrite: rewrite, lang: lang, relPath: relPath, apply: true)

        // A mutating structural rewrite spawns a process → gate on the shell policy's
        // un-bypassable STRUCTURED path (binary basename allow-list + full-argv deny +
        // interactive approval). Shell-disabled contexts refuse it outright.
        if let reason = await context.shell.binaryRefusalReason(resolvedPath: bin, args: args) {
            return .failure("ast_grep_apply refused: \(reason)")
        }
        let (out, timedOut) = SearchCodeTool.runProcess(bin, args, cwd: confined.rootPath, maxBytes: 300_000, timeout: 60)
        if timedOut { return .failure("ast_grep_apply timed out — narrow the path or pattern and retry") }
        return ToolResult(success: true, output: out.isEmpty ? "ast-grep: rewrite applied" : out,
                          metadata: ["engine": "ast-grep", "mode": "apply"])
    }
}
