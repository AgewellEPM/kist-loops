import Foundation

/// Phase 3.2 — a lightweight repo map: an orientation layer that tells the agent WHAT's in the codebase
/// (files → their top-level symbols), ranked by relevance to the goal, token-budgeted. aider's repo-map
/// (+RepoGraph +2.66 SWE-bench-Lite) proved this cheap symbol map beats stuffing files into context, and
/// it fixes the "keyword misses semantics / embeddings miss identifiers" gap for a long-horizon run.
///
/// No tree-sitter dependency — lightweight per-language regex for top-level declarations. Pure over
/// (files, goal) so extraction + ranking + budgeting are unit-tested; a thin reader walks the repo.
public enum RepoMap {
    public struct Entry: Equatable, Sendable {
        public let file: String
        public let symbols: [String]
        public init(file: String, symbols: [String]) { self.file = file; self.symbols = symbols }
    }

    /// Top-level symbol names declared in `source` (Swift / Python / JS-TS / Go / Rust / Java-ish). Best
    /// effort — names only, deduped, capped. Comments/strings aren't fully excluded (lightweight by design).
    public static func symbols(in source: String, path: String, max: Int = 24) -> [String] {
        let patterns = [
            #"(?m)^\s*(?:public |private |internal |fileprivate |open |final |static |override |@\w+\s+)*(?:func|class|struct|enum|protocol|actor|extension)\s+([A-Za-z_]\w*)"#, // Swift
            #"(?m)^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)"#,                    // Python def
            #"(?m)^\s*class\s+([A-Za-z_]\w*)"#,                               // Python/JS class
            #"(?m)^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_]\w*)"#, // JS/TS function
            #"(?m)^\s*(?:export\s+)?(?:type|interface)\s+([A-Za-z_]\w*)"#,    // TS type/interface
            #"(?m)^\s*func\s+(?:\([^)]*\)\s+)?([A-Za-z_]\w*)"#,               // Go func / method
            #"(?m)^\s*(?:pub\s+)?fn\s+([A-Za-z_]\w*)"#,                       // Rust fn
        ]
        var seen = Set<String>(), out: [String] = []
        for pat in patterns {
            guard let re = try? NSRegularExpression(pattern: pat) else { continue }
            let ns = source as NSString
            for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let name = ns.substring(with: m.range(at: 1))
                guard name.count >= 2, seen.insert(name).inserted else { continue }
                out.append(name)
                if out.count >= max { return out }
            }
        }
        return out
    }

    /// Rank files by relevance to the goal (keyword overlap on path + symbol names) and render a compact,
    /// token-budgeted map. Files with no symbols are dropped. Deterministic (stable tie-break on path).
    public static func render(files: [(path: String, source: String)], goal: String,
                              maxFiles: Int = 12, maxSymbolsPerFile: Int = 10) -> String {
        let goalTerms = terms(goal)
        let entries: [(entry: Entry, score: Int)] = files.compactMap { f in
            let syms = symbols(in: f.source, path: f.path)
            guard !syms.isEmpty else { return nil }
            let hay = (f.path + " " + syms.joined(separator: " ")).lowercased()
            let score = goalTerms.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
            return (Entry(file: f.path, symbols: Array(syms.prefix(maxSymbolsPerFile))), score)
        }
        guard !entries.isEmpty else { return "" }
        // Score DESC, then file ASC (stable) — the earlier cross-term comparator was a real bug (panel).
        let ranked = entries.sorted { a, b in a.score != b.score ? a.score > b.score : a.entry.file < b.entry.file }.prefix(maxFiles)
        var lines = ["Repo map (relevant files → symbols):"]
        for r in ranked { lines.append("  \(r.entry.file): \(r.entry.symbols.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    /// Walk the repo (bounded) and render its map for a goal. Skips build/vcs/dep dirs and big/binary
    /// files. Best-effort — returns "" on any trouble (never blocks a run).
    public static func build(projectRoot: String, goal: String, fileLimit: Int = 400, maxFileBytes: Int = 200_000) -> String {
        let exts: Set<String> = ["swift", "py", "js", "ts", "jsx", "tsx", "go", "rs", "java", "rb", "kt", "c", "cpp", "cc", "h", "hpp", "m"]
        let skip = [".build/", ".git/", "node_modules/", ".kist/", ".mythos/", "Pods/", "/dist/", "/vendor/", ".swiftpm/"]
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: projectRoot) else { return "" }
        var files: [(path: String, source: String)] = []
        for case let rel as String in en {
            if files.count >= fileLimit { break }
            if skip.contains(where: { rel.contains($0) }) { continue }
            guard let dot = rel.lastIndex(of: "."),
                  exts.contains(String(rel[rel.index(after: dot)...]).lowercased()) else { continue }
            let full = projectRoot + "/" + rel
            guard let data = fm.contents(atPath: full), data.count <= maxFileBytes,
                  let src = String(data: data, encoding: .utf8) else { continue }
            files.append((rel, src))
        }
        return render(files: files, goal: goal)
    }

    static func terms(_ goal: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in goal.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let w = String(raw)
            guard w.count >= 4, seen.insert(w).inserted else { continue }
            out.append(w)
        }
        return out
    }
}
