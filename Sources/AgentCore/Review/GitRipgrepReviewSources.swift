import Foundation

/// Real `ReviewSources` backed by git (changed files) + ripgrep (symbol/glob), confined to a project root.
/// Read-only: it only inspects the tree. Reuses `SearchCodeTool`'s bounded process runner. When a tool is
/// absent it degrades (empty result) rather than throwing — the resolver just falls back to another route.
public struct GitRipgrepReviewSources: ReviewSources {
    private let root: String
    public init(projectRoot: String) { self.root = ToolContext.canonicalize(projectRoot) ?? projectRoot }

    public func changedFiles() -> [String] {
        guard let git = Self.toolPath("git") else { return [] }
        // changed-vs-HEAD ∪ untracked-but-not-ignored
        let tracked = run(git, ["-C", root, "diff", "--name-only", "HEAD"])
        let untracked = run(git, ["-C", root, "ls-files", "--others", "--exclude-standard"])
        var seen = Set<String>(); var out: [String] = []
        for f in (tracked + untracked) where !f.isEmpty && !seen.contains(f) { seen.insert(f); out.append(f) }
        return out
    }

    public func filesMatchingGlob(_ pattern: String) -> [String] {
        if let rg = SearchCodeTool.ripgrepPath() {
            return run(rg, ["--files", "-g", pattern], cwd: root)
        }
        return Self.fallbackGlob(pattern, root: root)
    }

    public func filesContainingSymbol(_ symbol: String) -> [String] {
        guard let rg = SearchCodeTool.ripgrepPath() else { return [] }
        // Fixed-string, whole-word-ish; files-with-matches only.
        return run(rg, ["--color=never", "--files-with-matches", "--fixed-strings", "--", symbol, "."], cwd: root)
    }

    // MARK: - internals

    private func run(_ launch: String, _ args: [String], cwd: String? = nil) -> [String] {
        let (out, _) = SearchCodeTool.runProcess(launch, args, cwd: cwd ?? root, maxBytes: 200_000, timeout: 15)
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func toolPath(_ name: String) -> String? {
        let candidates = ["/usr/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/bin/\(name)"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = String(dir) + "/" + name
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// Pure-Foundation glob fallback when ripgrep isn't present (supports a `**/...ext` / `*.ext` shape).
    static func fallbackGlob(_ pattern: String, root: String) -> [String] {
        let ext = (pattern as NSString).pathExtension
        guard let en = FileManager.default.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        let skip = ["/.git/", "/.build/", "/node_modules/"]
        for case let rel as String in en {
            if skip.contains(where: { ("/" + rel).contains($0) }) { continue }
            if ext.isEmpty || rel.hasSuffix("." + ext) { out.append(rel) }
        }
        return out.sorted()
    }
}
