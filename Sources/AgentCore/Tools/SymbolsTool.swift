import Foundation

// Structural code navigation — closes kist's "lexical index, no structure" gap vs the
// frontier's AST knowledge-graphs, in-house and offline. Two read-only actions:
//   • outline — a file's declarations (types/functions) with line numbers, so the model
//               understands a file's shape WITHOUT reading the whole thing (token savings).
//   • find    — where a symbol is DEFINED across the repo, so the model jumps straight to a
//               definition instead of grepping+reading candidates.
// Complements search_code (text), ast_grep (structural patterns), and context_brain (shards).
// Read-only, confined to the project root, not approval-gated.
public struct SymbolsTool: AgentTool {
    public let name = "symbols"
    public let description = "Structural code navigation (read-only). action=outline lists the declarations (types/functions) with line numbers of a FILE — or of a whole DIRECTORY/module (outlines every supported source file inside it); action=find locates where a symbol is DEFINED across the repo. Use it to understand structure or jump to a definition without reading whole files."
    public let parameters = [
        ToolParameter(name: "action", type: "string", description: "outline | find", required: true),
        ToolParameter(name: "path", type: "string", description: "File OR directory to outline (a directory outlines every supported source file inside it), or a directory to scope find (default: whole project). Absolute paths under a session-armed read-only root (--allow-read) also work.", required: false),
        ToolParameter(name: "name", type: "string", description: "Symbol name to locate (action=find). Exact by default; set contains=true for substring.", required: false),
        ToolParameter(name: "contains", type: "boolean", description: "find: match names CONTAINING `name` instead of exact (default false)", required: false),
        ToolParameter(name: "limit", type: "integer", description: "Max results (default 200)", required: false),
    ]
    public var supportedActions: [String] { ["outline", "find"] }
    public var usageExamples: [String] {
        ["symbols(action=\"outline\", path=\"Sources/App.swift\")",
         "symbols(action=\"find\", name=\"toolOutputEnvelope\")",
         "symbols(action=\"find\", name=\"Store\", contains=true, path=\"Sources\")"]
    }
    public init() {}

    static let skipDirs: Set<String> = [".git", ".build", "node_modules", ".swiftpm", "dist", "build", "vendor", ".venv"]
    /// Resource caps (Codex review): bound results, files walked, and per-file bytes read.
    static let maxLimit = 2000
    static let maxFilesScanned = 20_000
    static let maxFileBytes = 2_000_000

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let action = try requireString("action", from: arguments).lowercased()
        let limit = clampedLimit(optionalInt("limit", from: arguments))
        // Both actions are READ-ONLY → resolve the caller's path through the reading resolver so
        // absolute paths under an armed external read root (--allow-read) also work.
        let base = (arguments["path"] as? String) ?? "."
        let (confined, resolvedBase) = try context.confinedRootForReading(base)
        switch action {
        case "outline": return try outline(arguments: arguments, path: resolvedBase, confined: confined, limit: limit)
        case "find":    return try find(arguments: arguments, base: resolvedBase, confined: confined, limit: limit)
        default:        return .failure("symbols: unknown action '\(action)'. Use outline | find.")
        }
    }

    func clampedLimit(_ v: Int?) -> Int { min(max(v ?? 200, 1), Self.maxLimit) }

    // MARK: - outline one file

    private func outline(arguments: [String: Any], path: String, confined: ConfinedRoot, limit: Int) throws -> ToolResult {
        guard arguments["path"] is String else { throw ToolError.missingParameter("path") }
        guard let lang = SymbolExtractor.language(forPath: path) else {
            // No file-extension match ⇒ likely a DIRECTORY (the model often passes a module dir,
            // e.g. Sources/AgentCore). Outline every supported source file inside it. If the walk
            // fails because it ISN'T a directory, fall back to the honest unsupported-file error.
            do {
                return try outlineDirectory(path: path, confined: confined, limit: limit)
            } catch {
                return .failure("symbols: unsupported file type for \(path). Supported: swift, ts/js, py, rust, go, java, kotlin, ruby, c/c++.")
            }
        }
        guard let source = try? confined.readString(path) else { return .failure("symbols: could not read \(path)") }
        let syms = SymbolExtractor.outline(source, language: lang)
        guard !syms.isEmpty else {
            return ToolResult(success: true, output: "(no top-level symbols found in \(path))",
                              metadata: ["action": "outline", "path": path, "count": "0"])
        }
        let shown = syms.prefix(limit)
        let body = shown.map { "\($0.line)\t\($0.kind) \($0.name)" }.joined(separator: "\n")
        let header = "[outline \(path) — \(syms.count) symbol(s)\(syms.count > limit ? ", showing \(limit)" : "")]"
        return ToolResult(success: true, output: header + "\n" + body,
                          metadata: ["action": "outline", "path": path, "count": String(syms.count)])
    }

    // MARK: - outline a whole directory (every supported source file inside it)

    /// Per-directory-outline caps so a big module stays readable and bounded.
    static let maxDirFiles = 80
    static let maxDirSymbolsPerFile = 30

    private func outlineDirectory(path: String, confined: ConfinedRoot, limit: Int) throws -> ToolResult {
        // Mirror `find`'s base-prefix handling so paths resolve under both the project root and an
        // armed external read root (--allow-read).
        let basePrefixComps = try confined.relativeComponents(path)
        let basePrefix = confined.readOnly
            ? confined.rootPath + "/" + (basePrefixComps.isEmpty ? "" : basePrefixComps.joined(separator: "/") + "/")
            : (basePrefixComps.isEmpty ? "" : basePrefixComps.joined(separator: "/") + "/")

        var sections: [String] = []
        var files = 0, totalSymbols = 0, truncated = false
        struct Stop: Error {}
        do {
            try confined.walk(path, skipDirs: Self.skipDirs) { rel, isDir in
                if isDir { return }
                let rootRel = basePrefix + rel
                guard let lang = SymbolExtractor.language(forPath: rootRel) else { return }
                if let meta = try? confined.fileMetadata(rootRel), meta.bytes > Self.maxFileBytes { return }
                guard let source = try? confined.readString(rootRel) else { return }
                let syms = SymbolExtractor.outline(source, language: lang)
                guard !syms.isEmpty else { return }
                if files >= Self.maxDirFiles { truncated = true; throw Stop() }
                files += 1
                totalSymbols += syms.count
                let shown = syms.prefix(Self.maxDirSymbolsPerFile)
                sections.append("\(rel) — \(syms.count) symbol(s)"
                    + (syms.count > Self.maxDirSymbolsPerFile ? ", showing \(Self.maxDirSymbolsPerFile)" : "") + ":")
                sections.append(shown.map { "  \($0.line)\t\($0.kind) \($0.name)" }.joined(separator: "\n"))
            }
        } catch is Stop { /* hit the file cap */ }

        guard files > 0 else {
            return ToolResult(success: true, output: "(no supported source files with symbols under \(path))",
                              metadata: ["action": "outline", "path": path, "count": "0", "files": "0"])
        }
        let header = "[outline \(path) — \(files) file(s), \(totalSymbols) symbol(s)"
            + (truncated ? ", truncated at \(Self.maxDirFiles) files" : "") + "]"
        return ToolResult(success: true, output: header + "\n" + sections.joined(separator: "\n"),
                          metadata: ["action": "outline", "path": path, "count": String(totalSymbols),
                                     "files": String(files)])
    }

    // MARK: - find a definition repo-wide

    private func find(arguments: [String: Any], base: String, confined: ConfinedRoot, limit: Int) throws -> ToolResult {
        let name = try requireString("name", from: arguments)
        let contains = optionalBool("contains", from: arguments) ?? false

        var hits: [String] = []
        var filesScanned = 0
        var filesCapped = false
        struct Stop: Error {}
        let basePrefixComps = try confined.relativeComponents(base)
        // External base → emit ABSOLUTE hit paths so follow-up read_file calls resolve to the
        // right root (relative would silently resolve against the PROJECT root).
        let basePrefix = confined.readOnly
            ? confined.rootPath + "/" + (basePrefixComps.isEmpty ? "" : basePrefixComps.joined(separator: "/") + "/")
            : (basePrefixComps.isEmpty ? "" : basePrefixComps.joined(separator: "/") + "/")
        do {
            try confined.walk(base, skipDirs: Self.skipDirs) { rel, isDir in
                if isDir { return }
                let rootRel = basePrefix + rel
                guard let lang = SymbolExtractor.language(forPath: rootRel) else { return }
                // Bound the walk: stop after too many files, and skip oversized files before reading.
                if filesScanned >= Self.maxFilesScanned { filesCapped = true; throw Stop() }
                if let meta = try? confined.fileMetadata(rootRel), meta.bytes > Self.maxFileBytes { return }
                guard let source = try? confined.readString(rootRel) else { return }
                filesScanned += 1
                for s in SymbolExtractor.outline(source, language: lang) {
                    let match = contains ? s.name.localizedCaseInsensitiveContains(name) : (s.name == name)
                    guard match else { continue }
                    hits.append("\(rootRel):\(s.line): \(s.kind) \(s.name)")
                    if hits.count >= limit { throw Stop() }
                }
            }
        } catch is Stop { /* hit a cap */ }
        let truncated = hits.count >= limit || filesCapped
        let body = hits.isEmpty ? "(no definition of \"\(name)\" found)" : hits.joined(separator: "\n")
        return ToolResult(success: true, output: body,
                          metadata: ["action": "find", "name": name, "matches": String(hits.count),
                                     "files_scanned": String(filesScanned), "truncated": String(truncated)])
    }
}
