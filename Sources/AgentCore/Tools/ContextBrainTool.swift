import Foundation

/// Read-only project context brain. It indexes the repository into stable shards, retrieves
/// focused chunks on demand, and emits coverage batches so agents can audit every file by
/// chaining smaller model calls instead of overflowing one context window.
public struct ContextBrainTool: AgentTool {
    public let name = "context_brain"
    public let description = """
    Build and query a project-local context index. Use this before large audits or repo-wide \
    work: index every file, search relevant shards, get exact file chunks, or create a coverage \
    plan that walks all chunks in batches sized for the current model context.
    """
    public let parameters = [
        ToolParameter(name: "action", type: "string", description: "index | search | get | coverage", required: true),
        ToolParameter(name: "query", type: "string", description: "Search query for action=search.", required: false),
        ToolParameter(name: "id", type: "string", description: "Chunk id such as Sources/A.swift:L1-L120 for action=get.", required: false),
        ToolParameter(name: "path", type: "string", description: "Project-relative file path for action=get.", required: false),
        ToolParameter(name: "start_line", type: "integer", description: "First line for path-based get.", required: false),
        ToolParameter(name: "end_line", type: "integer", description: "Last line for path-based get.", required: false),
        ToolParameter(name: "limit", type: "integer", description: "Result limit for index/search.", required: false),
        ToolParameter(name: "chunk_chars", type: "integer", description: "Approximate characters per shard. Default 12000.", required: false),
        ToolParameter(name: "max_chars", type: "integer", description: "Coverage batch or get output budget.", required: false),
        ToolParameter(name: "max_file_bytes", type: "integer", description: "Max file bytes to inline into the index. Default 2000000.", required: false),
        ToolParameter(name: "max_total_bytes", type: "integer", description: "Max aggregate text bytes to inline into the index. Default 64000000.", required: false),
    ]

    public var supportedActions: [String] { ["index", "search", "get", "coverage"] }
    public var unsupportedActions: [String] { ["write", "edit", "execute", "delete", "summarize_without_sources"] }
    public var capabilityNote: String? {
        "Read-only context/RAG layer. For exhaustive reviews, call coverage, then get each batch's chunk ids across chained turns."
    }
    public var usageExamples: [String] {
        [
            "context_brain(action=\"coverage\", max_chars=120000)",
            "context_brain(action=\"search\", query=\"RunReplayStore concurrency append\", limit=8)",
            "context_brain(action=\"get\", id=\"Sources/Kist/UX/RunReplayStore.swift:L1-L120\")",
        ]
    }

    private let cache: IndexCache

    public init() {
        self.cache = IndexCache()
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let action = try requireString("action", from: arguments).lowercased()
        switch action {
        case "index":
            let index = try buildIndex(arguments: arguments, context: context)
            let limit = min(max(optionalInt("limit", from: arguments) ?? 120, 1), 1_000)
            return ToolResult(success: true, output: index.renderMap(limit: limit),
                              metadata: metadata(index))
        case "search":
            let query = try requireString("query", from: arguments)
            let index = try buildIndex(arguments: arguments, context: context)
            let limit = min(max(optionalInt("limit", from: arguments) ?? 12, 1), 50)
            return ToolResult(success: true, output: renderSearch(index.search(query, limit: limit), query: query),
                              metadata: metadata(index))
        case "get":
            return try get(arguments: arguments, context: context)
        case "coverage":
            let index = try buildIndex(arguments: arguments, context: context)
            let maxChars = min(max(optionalInt("max_chars", from: arguments) ?? 120_000, 8_000), 800_000)
            return ToolResult(success: true, output: renderCoverage(index: index, maxChars: maxChars),
                              metadata: metadata(index))
        default:
            return .failure("unknown context_brain action '\(action)'; use index, search, get, or coverage")
        }
    }

    private func buildIndex(arguments: [String: Any], context: ToolContext) throws -> ContextBrainIndex {
        let chunkChars = min(max(optionalInt("chunk_chars", from: arguments) ?? 12_000, 1_000), 80_000)
        let maxFileBytes = min(max(optionalInt("max_file_bytes", from: arguments) ?? 2_000_000, 1_000), 20_000_000)
        let maxTotalBytes = min(max(optionalInt("max_total_bytes", from: arguments) ?? 64_000_000, 1_000), 512_000_000)
        let root = ToolContext.canonicalize(context.projectRoot) ?? context.projectRoot
        let key = IndexKey(root: root, chunkCharacters: chunkChars, maxFileBytes: maxFileBytes,
                           maxTotalBytes: maxTotalBytes)
        let signature = try ContextBrainIndex.sourceSignature(root: root)
        if let cached = cache.lookup(key: key, signature: signature) { return cached }
        let index = try ContextBrainIndex.build(root: root,
                                                chunkCharacters: chunkChars,
                                                maxFileBytes: maxFileBytes,
                                                maxTotalTextBytes: maxTotalBytes)
        cache.store(index, key: key, signature: signature)
        return index
    }

    private func get(arguments: [String: Any], context: ToolContext) throws -> ToolResult {
        let maxChars = min(max(optionalInt("max_chars", from: arguments) ?? 80_000, 1_000), 800_000)
        let index = try buildIndex(arguments: arguments, context: context)
        if let rawID = (arguments["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawID.isEmpty {
            guard ContextBrainIndex.parseChunkID(rawID) != nil else {
                return .failure("invalid context chunk id: \(rawID)")
            }
            guard let chunk = index.chunk(id: rawID) else {
                return .failure("chunk id is not in the current context index: \(rawID)")
            }
            return renderChunk(chunk, maxChars: maxChars)
        }

        let path = normalizePathForIndex(try requireString("path", from: arguments), index: index)
        let start = max(optionalInt("start_line", from: arguments) ?? 1, 1)
        let end = optionalInt("end_line", from: arguments)
        return renderPath(path: path, start: start, end: end, maxChars: maxChars, index: index)
    }

    private func renderChunk(_ chunk: ContextBrainIndex.Chunk, maxChars: Int) -> ToolResult {
        var body = chunk.text
        var truncated = false
        if body.count > maxChars {
            body = String(body.prefix(maxChars))
            truncated = true
        }
        let header = "\(chunk.id)\(truncated ? " · truncated to \(maxChars) chars" : "")"
        return ToolResult(success: true, output: header + "\n\n" + body,
                          metadata: ["path": chunk.path,
                                     "start_line": "\(chunk.startLine)",
                                     "end_line": "\(chunk.endLine)"])
    }

    private func renderPath(path: String, start: Int, end: Int?, maxChars: Int,
                            index: ContextBrainIndex) -> ToolResult {
        let chunks = index.chunks(forPath: path)
        guard !chunks.isEmpty else {
            if let file = index.files.first(where: { $0.path == path }) {
                if file.note == "empty_text_file" {
                    return ToolResult(success: true, output: "\(path): empty file", metadata: ["path": path])
                }
                return .failure("\(path) is not indexed as text\(file.note.map { ": \($0)" } ?? "")")
            }
            return .failure("path is not in the current context index: \(path)")
        }
        let lines = chunks.flatMap {
            $0.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        guard !lines.isEmpty else {
            return ToolResult(success: true, output: "\(path): empty file", metadata: ["path": path])
        }
        let finalEnd = min(max(end ?? min(lines.count, start + 219), start), lines.count)
        guard start <= lines.count else { return .failure("start_line \(start) is past end of \(path) (\(lines.count) lines)") }
        var body = lines[(start - 1)..<finalEnd].joined(separator: "\n")
        var truncated = false
        if body.count > maxChars {
            body = String(body.prefix(maxChars))
            truncated = true
        }
        let header = "\(path):L\(start)-L\(finalEnd)\(truncated ? " · truncated to \(maxChars) chars" : "")"
        return ToolResult(success: true, output: header + "\n\n" + body,
                          metadata: ["path": path, "start_line": "\(start)", "end_line": "\(finalEnd)"])
    }

    private func renderSearch(_ chunks: [ContextBrainIndex.Chunk], query: String) -> String {
        guard !chunks.isEmpty else { return "No context chunks matched query: \(query)" }
        var lines = ["Context search: \(query)", "Matches: \(chunks.count)", ""]
        for chunk in chunks {
            lines.append("- \(chunk.id) · \(chunk.characters) chars")
            lines.append("  \(preview(chunk.text))")
        }
        lines.append("")
        lines.append("Use context_brain(action=\"get\", id=\"...\") to hot-load an exact chunk.")
        return lines.joined(separator: "\n")
    }

    private func renderCoverage(index: ContextBrainIndex, maxChars: Int) -> String {
        let batches = index.coverageBatches(maxCharacters: maxChars)
        var lines: [String] = [
            "Context coverage plan",
            "Root: \(index.root)",
            "Files: \(index.files.count) · chunks: \(index.chunks.count) · binary/large metadata-only: \(index.binaryOrLargeCount)",
            "Batch budget: \(maxChars) chars · batches: \(batches.count)",
            "",
            "Procedure:",
            "1. For each batch, call context_brain(action=\"get\", id=\"...\") for every listed chunk.",
            "2. Review only that batch, record findings with file paths and line ranges.",
            "3. Carry forward only the stable audit ledger: covered chunk ids, findings, open questions.",
            "4. Continue until every batch is marked covered; do not claim full coverage before then.",
            "",
        ]
        for (idx, batch) in batches.enumerated() {
            let chars = batch.reduce(0) { $0 + $1.characters }
            lines.append("Batch \(idx + 1) · \(batch.count) chunk(s) · ~\(chars) chars")
            for chunk in batch {
                lines.append("- \(chunk.id)")
                lines.append("  get: context_brain(action=\"get\", id=\"\(chunk.id)\")")
            }
        }
        if index.binaryOrLargeCount > 0 {
            lines.append("")
            lines.append("Metadata-only files still require explicit handling:")
            for file in index.files where !file.isText {
                lines.append("- \(file.path) · \(file.bytes) bytes · \(file.note ?? "not indexed as text")")
            }
        }
        lines.append("")
        lines.append("VERIFICATION: \(batches.count) batch(es), \(index.chunks.count) retrievable chunk(s), \(index.binaryOrLargeCount) metadata-only file(s). This coverage output is only the plan; call context_brain(action=\"get\", id=\"...\") for each chunk before claiming full source coverage.")
        return lines.joined(separator: "\n")
    }

    private func preview(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard compact.count > 220 else { return compact.isEmpty ? "(empty)" : compact }
        return String(compact.prefix(219)) + "..."
    }

    private func metadata(_ index: ContextBrainIndex) -> [String: String] {
        [
            "files": "\(index.files.count)",
            "chunks": "\(index.chunks.count)",
            "bytes": "\(index.totalBytes)",
            "indexed_text_bytes": "\(index.indexedTextBytes)",
        ]
    }

    private func normalizePathForIndex(_ raw: String, index: ContextBrainIndex) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootSlash = index.root == "/" ? "/" : index.root + "/"
        if trimmed.hasPrefix(rootSlash) { return String(trimmed.dropFirst(rootSlash.count)) }
        return trimmed
    }
}

private struct IndexKey: Hashable {
    let root: String
    let chunkCharacters: Int
    let maxFileBytes: Int
    let maxTotalBytes: Int
}

private final class IndexCache: @unchecked Sendable {
    private struct Entry {
        let signature: String
        let index: ContextBrainIndex
    }

    private let lock = NSLock()
    private let maxEntries: Int
    private var entries: [IndexKey: Entry] = [:]
    private var order: [IndexKey] = []

    init(maxEntries: Int = 4) {
        self.maxEntries = max(1, maxEntries)
    }

    func lookup(key: IndexKey, signature: String) -> ContextBrainIndex? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.signature == signature else { return nil }
        return entry.index
    }

    func store(_ index: ContextBrainIndex, key: IndexKey, signature: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = Entry(signature: signature, index: index)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > maxEntries {
            let removed = order.removeFirst()
            entries.removeValue(forKey: removed)
        }
    }
}
