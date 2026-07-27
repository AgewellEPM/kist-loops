import Foundation

/// THE CORTEX — a persistent, human-readable memory of YOU: how you like to work, your code style, your
/// projects, and a running daily journal of what we worked on. Stored as plain `.md` files under
/// `~/.kist/cortex/` so you can READ and EDIT everything it knows (no opaque vector blob). Loaded into every
/// session's context so kist knows you the way Claude does — and it grows each time you work together.
///
/// Layout:
///   ~/.kist/cortex/preferences.md          — working style + code preferences (+ a Learned section)
///   ~/.kist/cortex/projects/<name>.md      — one file per project
///   ~/.kist/cortex/journal/YYYY-MM-DD.md   — daily work log
public struct CortexMemory: Sendable {
    public let root: String

    public init(root: String = CortexMemory.defaultRoot()) { self.root = root }

    public static func defaultRoot() -> String {
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? (NSHomeDirectory() + "/.kist")
        return base + "/cortex"
    }

    private var preferencesPath: String { root + "/preferences.md" }
    private func projectPath(_ name: String) -> String { root + "/projects/" + Self.safe(name) + ".md" }
    private func journalPath(_ date: String) -> String { root + "/journal/" + Self.safe(date) + ".md" }

    // MARK: - context assembly (what gets injected so kist "knows you")

    /// The memory block injected into a session: your preferences + the active project + the last few days
    /// of journal. Bounded so it enriches context without flooding it.
    public func context(projectName: String? = nil, journalDays: Int = 3, maxBytes: Int = 6000) -> String {
        var parts: [String] = []
        if let prefs = read(preferencesPath), !prefs.isEmpty {
            parts.append("WHAT KIST KNOWS ABOUT YOU (preferences — follow these):\n" + cap(prefs, 3000))
        }
        if let name = projectName, let proj = read(projectPath(name)), !proj.isEmpty {
            parts.append("PROJECT MEMORY (\(name)):\n" + cap(proj, 2000))
        }
        let recent = recentJournal(days: journalDays)
        if !recent.isEmpty { parts.append("RECENT WORK (journal):\n" + cap(recent, 1500)) }
        guard !parts.isEmpty else { return "" }
        // Proactive nudge so kist MAINTAINS its own memory (like Claude), not just reads it.
        parts.append("Keep this current: when Luke states a preference, corrects you, decides something, "
            + "or you finish meaningful work, save it with the `cortex` tool (remember / project / journal) "
            + "so the next session starts already knowing.")
        return cap(parts.joined(separator: "\n\n"), maxBytes)
    }

    // MARK: - writes (it learns)

    /// Seed a starter preferences file the first time, so kist begins knowing the basics about Luke.
    public func seedIfNeeded() throws {
        guard read(preferencesPath) == nil else { return }
        try ensureDir(root)
        try append(preferencesPath, Self.starterPreferences)   // through the redact/lock/cap choke point
    }

    /// Record a learned fact/preference (appended under the Learned section of preferences.md).
    public func remember(_ fact: String) throws {
        let f = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return }
        try seedIfNeeded()
        try append(preferencesPath, "- " + f + "\n")
    }

    /// Append an entry to a specific project's memory.
    public func rememberProject(_ rawName: String, _ fact: String) throws {
        let f = fact.trimmingCharacters(in: .whitespacesAndNewlines); guard !f.isEmpty else { return }
        // Redact the NAME too — it becomes both a filename and a header, neither of which may carry a secret.
        let name = SecretScanner.redactSecrets(in: rawName)
        try ensureDir(root + "/projects")
        if read(projectPath(name)) == nil {
            try append(projectPath(name), "# \(name)\n\n")     // header through the same redact/lock/cap path
        }
        try append(projectPath(name), "- " + f + "\n")
    }

    /// Append to the daily journal. `date` is injected (e.g. "2026-06-29") so callers control the clock.
    public func logWork(_ entry: String, date: String) throws {
        let e = entry.trimmingCharacters(in: .whitespacesAndNewlines); guard !e.isEmpty else { return }
        try ensureDir(root + "/journal")
        if read(journalPath(date)) == nil {
            try append(journalPath(date), "# \(date)\n\n")     // header through the same redact/lock/cap path
        }
        try append(journalPath(date), "- " + e + "\n")
    }

    // MARK: - visibility (see the .md files)

    /// All cortex .md files (relative to root), so the user can audit exactly what kist knows.
    public func files() -> [String] {
        guard let en = FileManager.default.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        for case let p as String in en where p.hasSuffix(".md") { out.append(p) }
        return out.sorted()
    }

    /// Read a cortex file by its root-relative path (for `/cortex show <file>`). Containment-checked:
    /// a `..`/absolute/symlinked path that escapes the cortex root is refused (Codex — user-side traversal).
    public func show(_ relativePath: String) -> String? {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else { return nil }
        let full = root + "/" + relativePath
        guard let canonRoot = ToolContext.canonicalize(root),
              let canon = ToolContext.canonicalize(full),
              canon == canonRoot || canon.hasPrefix(canonRoot + "/") else { return nil }
        return read(canon)   // read the RESOLVED path (closes the symlink-swap TOCTOU window)
    }

    // MARK: - internals

    /// Caps + a process-wide write lock so cortex can't grow unbounded or lose an append under
    /// concurrent (plan/fleet) writes (Codex MED/LOW).
    static let maxEntryChars = 4000
    static let maxFileBytes = 512_000
    private static let writeLock = NSLock()

    public enum CortexError: Error, CustomStringConvertible {
        case full(String)
        public var description: String {
            switch self { case .full(let p): return "cortex file is full (>\(CortexMemory.maxFileBytes) bytes): \(p) — prune it" }
        }
    }

    private func recentJournal(days: Int) -> String {
        let dir = root + "/journal"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return "" }
        let recent = names.filter { $0.hasSuffix(".md") }.sorted().suffix(max(1, days))
        return recent.compactMap { read(dir + "/" + $0) }.joined(separator: "\n")
    }

    private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    private func ensureDir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    /// THE single write choke point for every cortex file (facts, headers, seed) — so redaction,
    /// the size caps, and the lock can't be bypassed (Codex). BOUND before redaction (regex on
    /// unbounded input is a DoS), then redact so no plaintext secret is ever persisted.
    private func append(_ path: String, _ text: String) throws {
        var bounded = text
        if bounded.count > Self.maxEntryChars { bounded = String(bounded.prefix(Self.maxEntryChars)) + "…\n" }
        let safe = SecretScanner.redactSecrets(in: bounded)
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        let existing = read(path) ?? ""
        // Bound the FINAL size, not just the pre-existing size (no overshoot by one entry).
        guard existing.utf8.count + safe.utf8.count <= Self.maxFileBytes else { throw CortexError.full(path) }
        try (existing + safe).write(toFile: path, atomically: true, encoding: .utf8)
    }
    private func cap(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) + "\n…(truncated)" }

    /// A cortex name/date → safe filename component (no path traversal). Fail-closed: strip everything but
    /// ASCII letters/digits/`-`/`_`.
    static func safe(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(s.map { allowed.contains($0) ? $0 : "-" })
        return cleaned.isEmpty ? "untitled" : cleaned
    }

    static let starterPreferences = """
    # Luke — Working Style & Preferences

    Kist reads this every session so it knows you. It grows over time — edit it freely, or add with
    `/cortex remember <fact>`. Everything here is plain markdown you control.

    ## How I like to work
    - Direct, concise, zero fluff. Advanced — skip the basics.
    - Production-grade, not prototypes. "Works if you squint" is not done.
    - Honest labels: PROTOTYPE / PILOT-READY / PRODUCTION-READY / ENTERPRISE-READY — never claim a tier not earned.
    - Challenge me when something's off; honest correction beats agreement.

    ## Code style
    - MODULAR. One responsibility per file. Extract early, not late.
    - File size: ≤1000 lines is the target; ~1200 is the ceiling; split before it gets bigger.
    - Fail-fast error handling. Clean, well-commented code.
    - Commit each tested increment to its own branch; isolated worktree when sessions run in parallel.

    ## Process
    - Verify the work (build, test, trace the paths) before calling it done.
    - Adversarial review gate before "done" — the verifier the agent can't game.
    - Scope + verification + a human on the irreversible button.

    ## Learned
    (Facts kist picks up about you go here.)
    """
}
