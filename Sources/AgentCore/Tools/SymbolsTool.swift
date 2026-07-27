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
    public let description = "Structural code navigation (read-only). action=outline lists a file's declarations (types/functions) with line numbers; action=find locates where a symbol is DEFINED across the repo. Use it to understand structure or jump to a definition without reading whole files."
    public let parameters = [
        ToolParameter(name: "action", type: "string", description: "outline | find", required: true),
        ToolParameter(name: "path", type: "string", description: "File to outline (action=outline), or a directory to scope find (default: whole project)", required: false),
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
        let confined = try context.confinedRoot()
        let limit = clampedLimit(optionalInt("limit", from: arguments))
        switch action {
        case "outline": return try outline(arguments: arguments, confined: confined, limit: limit)
        case "find":    return try find(arguments: arguments, confined: confined, limit: limit)
        default:        return .failure("symbols: unknown action '\(action)'. Use outline | find.")
        }
    }

    func clampedLimit(_ v: Int?) -> Int { min(max(v ?? 200, 1), Self.maxLimit) }

    // MARK: - outline one file

    private func outline(arguments: [String: Any], confined: ConfinedRoot, limit: Int) throws -> ToolResult {
        let path = try requireString("path", from: arguments)
        guard let lang = SymbolExtractor.language(forPath: path) else {
            return .failure("symbols: unsupported file type for \(path). Supported: swift, ts/js, py, rust, go, java, kotlin, ruby, c/c++.")
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

    // MARK: - find a definition repo-wide

    private func find(arguments: [String: Any], confined: ConfinedRoot, limit: Int) throws -> ToolResult {
        let name = try requireString("name", from: arguments)
        let contains = optionalBool("contains", from: arguments) ?? false
        let base = (arguments["path"] as? String) ?? "."

        var hits: [String] = []
        var filesScanned = 0
        var filesCapped = false
        struct Stop: Error {}
        let basePrefixComps = try confined.relativeComponents(base)
        let basePrefix = basePrefixComps.isEmpty ? "" : basePrefixComps.joined(separator: "/") + "/"
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
