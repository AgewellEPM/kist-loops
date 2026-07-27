import Foundation

/// Turns a VAGUE review target ("the persona matcher", "recent changes", "the security layer",
/// "AuthorizationScope") into a CONCRETE set of files to read — so a model can review WITHOUT being handed
/// exact paths. This is the fix for the MiMo failure: finding *what* to review is a planning/navigation
/// task weak models can't do, so we do it deterministically and hand them the file set; they just read +
/// reason (their strength). The IO (git/ripgrep/glob) is injected so the resolve logic is pure + testable.
public struct ReviewPlan: Equatable, Sendable {
    public let files: [String]
    public let strategy: String      // which route resolved it (changed-files / symbol / subsystem / path)
    public let rationale: String     // human-readable why these files
    public init(files: [String], strategy: String, rationale: String) {
        self.files = files; self.strategy = strategy; self.rationale = rationale
    }
    public var isEmpty: Bool { files.isEmpty }
}

/// Injected capabilities the resolver needs (real impl wraps git + ripgrep + the confined FS).
public protocol ReviewSources: Sendable {
    func changedFiles() -> [String]                    // git: changed + untracked vs HEAD
    func filesMatchingGlob(_ pattern: String) -> [String]
    func filesContainingSymbol(_ symbol: String) -> [String]   // ripgrep --files-with-matches
}

public enum ReviewTargetResolver {

    /// Map a subsystem word in the target → a directory glob, so "the security layer" finds the Security dir.
    static let subsystems: [(word: String, glob: String)] = [
        ("security", "**/Security/**/*.swift"), ("safety", "**/Safety/**/*.swift"),
        ("tool", "**/Tools/**/*.swift"), ("fleet", "**/Fleet*/**/*.swift"),
        ("persona", "**/Specialist/**/*.swift"), ("specialist", "**/Specialist/**/*.swift"),
        ("agentforge", "**/Specialist/**/*.swift"), ("forge", "**/Specialist/**/*.swift"),
        ("mcp", "**/MCP/**/*.swift"), ("provider", "**/Providers/**/*.swift"),
        ("eval", "**/Eval/**/*.swift"), ("memory", "**/Memory/**/*.swift"),
        ("prompt", "**/Prompts*.swift"), ("ux", "**/UX/**/*.swift"), ("review", "**/Review/**/*.swift"),
    ]
    static let changeWords: Set<String> = ["recent", "recently", "changes", "changed", "diff", "edits",
                                           "edited", "last", "commit", "modified", "new", "latest", "uncommitted"]
    static let stopWords: Set<String> = ["the", "a", "an", "review", "our", "this", "that", "code", "for",
                                         "of", "in", "and", "please", "look", "at", "check", "files", "file",
                                         "system", "layer", "module", "all", "everything", "do", "read"]

    public static func resolve(target: String, sources: ReviewSources, limit: Int = 12) -> ReviewPlan {
        let raw = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        func tokenize(_ s: String) -> [String] {
            s.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "/" && $0 != "." }.map(String.init)
        }
        let rawTokens = tokenize(raw)          // ORIGINAL case — paths/globs are case-sensitive
        let tokens = tokenize(lower)           // lowercased — for keyword/subsystem matching

        // 1) Explicit path or glob in the target → use it directly (original case preserved).
        if let pathy = rawTokens.first(where: { $0.contains("/") || $0.hasSuffix(".swift") || $0.contains("*") }) {
            let files = sources.filesMatchingGlob(pathy.contains("*") || pathy.contains("/") ? pathy : "**/\(pathy)")
            if !files.isEmpty {
                return ReviewPlan(files: cap(files, limit), strategy: "path",
                                  rationale: "matched the path/glob '\(pathy)' in the request")
            }
        }

        // 2) "recent / changes / diff" → the git-changed set (review what just changed).
        if tokens.contains(where: { changeWords.contains($0) }) {
            let changed = sources.changedFiles().filter { $0.hasSuffix(".swift") }
            if !changed.isEmpty {
                return ReviewPlan(files: cap(changed, limit), strategy: "changed-files",
                                  rationale: "the request asks about recent changes — reviewing the git-changed set")
            }
        }

        // 3) Subsystem word → that directory. Match as a WHOLE TOKEN (not substring) so "tool" doesn't
        //    fire on "toolbar" and "eval" doesn't fire on "revaluation".
        let tokenSet = Set(tokens)
        for sub in subsystems where tokenSet.contains(sub.word) {
            let files = sources.filesMatchingGlob(sub.glob)
            if !files.isEmpty {
                return ReviewPlan(files: cap(rankBySymbol(files, tokens: meaningful(tokens)), limit),
                                  strategy: "subsystem",
                                  rationale: "matched subsystem '\(sub.word)' → its source directory")
            }
        }

        // 4) Symbol/keyword search — the general case. Union files that mention the meaningful tokens,
        //    ranked by how many distinct tokens each file hits.
        let keys = meaningful(tokens)
        if !keys.isEmpty {
            var score: [String: Int] = [:]
            for k in keys {
                for f in sources.filesContainingSymbol(k) where f.hasSuffix(".swift") { score[f, default: 0] += 1 }
            }
            if !score.isEmpty {
                let ranked = score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { $0.key }
                return ReviewPlan(files: cap(ranked, limit), strategy: "symbol",
                                  rationale: "matched symbols/keywords [\(keys.joined(separator: ", "))] across the repo")
            }
        }

        return ReviewPlan(files: [], strategy: "unresolved",
                          rationale: "couldn't resolve '\(raw)' to files — ask the user to name a file, symbol, or 'recent changes'")
    }

    static func meaningful(_ tokens: [String]) -> [String] {
        var seen = Set<String>()
        return tokens.filter { t in
            guard t.count > 2, !stopWords.contains(t), !changeWords.contains(t), !seen.contains(t) else { return false }
            seen.insert(t); return true
        }
    }

    /// Rank a candidate file list by how many of the meaningful tokens appear in the FILENAME (cheap relevance).
    static func rankBySymbol(_ files: [String], tokens: [String]) -> [String] {
        guard !tokens.isEmpty else { return files.sorted() }
        return files.sorted { a, b in
            let sa = tokens.filter { a.lowercased().contains($0) }.count
            let sb = tokens.filter { b.lowercased().contains($0) }.count
            return sa != sb ? sa > sb : a < b
        }
    }

    static func cap(_ files: [String], _ limit: Int) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for f in files where !seen.contains(f) { seen.insert(f); out.append(f); if out.count >= limit { break } }
        return out
    }
}

/// Splits a large review into PASSES so a model (especially a weak one) can review every target file across
/// pass 1, 2, 3, … WITHOUT a human re-prompting between them — the runner loops the passes and accumulates
/// findings. Per-pass file budget is tier-aware: weak models get fewer files per pass (they can't hold
/// many), strong models get more.
public enum ReviewBatcher {
    public static func filesPerPass(_ tier: ModelTier) -> Int { tier == .weak ? 3 : 8 }

    public static func passes(_ plan: ReviewPlan, tier: ModelTier) -> [ReviewPlan] {
        let per = filesPerPass(tier)
        guard plan.files.count > per else { return plan.files.isEmpty ? [] : [plan] }
        let chunks = stride(from: 0, to: plan.files.count, by: per).map {
            Array(plan.files[$0..<min($0 + per, plan.files.count)])
        }
        return chunks.enumerated().map { i, chunk in
            ReviewPlan(files: chunk, strategy: plan.strategy,
                       rationale: "\(plan.rationale) — pass \(i + 1) of \(chunks.count)")
        }
    }
}
