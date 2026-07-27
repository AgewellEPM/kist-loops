import Foundation

/// Discovers + persists `SpecialistDefinition`s on disk, mirroring Claude Code's `.claude/agents/` and
/// kist's own `.kist/commands/` loader. Two scopes: a USER dir (`~/.config/kist/agents/`, shared across
/// projects) and a PROJECT dir (`<root>/.kist/agents/`). Project wins on a name collision — same
/// precedence as custom commands.
///
/// Fail-soft on read (an unparseable file is skipped, never crashes discovery) and fail-CLOSED on write
/// (a name that isn't command-shaped is refused — the name is a filename, so this blocks path traversal).
public struct SpecialistRegistry: Sendable {
    private let userDir: String?         // ~/.config/kist/agents (kist native, user scope)
    private let claudeUserDir: String?   // ~/.claude/agents (Claude Code compat, user scope)
    private let projectDir: String       // <root>/.kist/agents (kist native, project scope)
    private let projectRoot: String

    /// `projectRoot` is the confined project root. Specialists load from FOUR disk scopes so a real Claude
    /// Code `.claude/agents` file works unchanged AND kist's own `.kist/agents` takes precedence.
    /// `userDir`/`claudeUserDir` default to the standard locations; pass explicit dirs (or nil) in tests.
    public init(projectRoot: String,
                userDir: String? = SpecialistRegistry.defaultUserDir(),
                claudeUserDir: String? = SpecialistRegistry.defaultClaudeUserDir()) {
        self.projectRoot = projectRoot
        self.projectDir = projectRoot + "/.kist/agents"
        self.userDir = userDir
        self.claudeUserDir = claudeUserDir
    }

    public static func defaultUserDir() -> String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? (NSHomeDirectory() + "/.config")
        return base + "/kist/agents"
    }
    public static func defaultClaudeUserDir() -> String { NSHomeDirectory() + "/.claude/agents" }

    /// All specialists across scopes. Precedence (highest wins on a name collision):
    /// `.kist project > .claude project > .kist user > .claude user`. kist-native always beats Claude-compat
    /// at the same scope, and project always beats user — matching custom-command precedence. Loaded
    /// lowest-first so later writes override. Unparseable files are skipped. PROJECT dirs read through
    /// `ConfinedRoot` (kernel `O_NOFOLLOW` — TOCTOU-safe against a symlinked agents dir/leaf); user dirs are
    /// trusted locations.
    public func load() -> [SpecialistDefinition] {
        var byName: [String: SpecialistDefinition] = [:]
        if let claudeUserDir { for def in Self.readPlain(dir: claudeUserDir) { byName[def.name] = def } }
        if let userDir { for def in Self.readPlain(dir: userDir) { byName[def.name] = def } }
        for def in readProjectConfined(relDir: ".claude/agents") { byName[def.name] = def }
        for def in readProjectConfined(relDir: ".kist/agents") { byName[def.name] = def }   // kist-native project wins
        return byName.values.sorted { $0.name < $1.name }
    }

    public func named(_ name: String) -> SpecialistDefinition? {
        load().first { $0.name == name }
    }

    /// Keyword-ranked candidates whose name/description best overlap the goal (retrieval only — never a
    /// verdict). Ties break alphabetically for determinism. Returns at most `limit`.
    public func matching(goal: String, limit: Int = 3) -> [SpecialistDefinition] {
        let needles = Self.tokens(goal)
        guard !needles.isEmpty else { return [] }
        let scored = load().map { def -> (SpecialistDefinition, Int) in
            let hay = Self.tokens(def.name + " " + def.description)
            return (def, needles.intersection(hay).count)
        }.filter { $0.1 > 0 }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
                     .prefix(limit).map { $0.0 }
    }

    /// Persist a specialist to the PROJECT dir as `<name>.md`. FAIL-CLOSED: refuses an invalid definition
    /// (bad name / empty description or body) so a malformed identity never lands on disk. Returns the path.
    @discardableResult
    public func save(_ def: SpecialistDefinition) throws -> String {
        guard def.isValid else {
            throw SpecialistRegistryError.invalid("specialist '\(def.name)' is not valid (name/description/body)")
        }
        // H5: write through ConfinedRoot — every path component is opened O_NOFOLLOW relative to a trusted
        // root fd, so a symlinked `.kist/agents` (or leaf) is refused at the syscall (ELOOP), with no
        // canonicalize→write race. Atomic temp-then-renameat inside the confined dir.
        let confined = try ConfinedRoot(root: projectRoot)
        try confined.writeString(".kist/agents/" + def.name + ".md", def.render(), createParents: true)
        return projectDir + "/" + def.name + ".md"
    }

    // MARK: - internals

    /// Project-dir read under `relDir` (e.g. `.kist/agents` or `.claude/agents`), confined by `ConfinedRoot`
    /// (O_NOFOLLOW throughout): a symlinked agents dir yields no entries; a symlinked leaf throws on read and
    /// is skipped. Unparseable files are skipped — so a stray/malformed `.claude/agents` file can't break
    /// discovery of the rest.
    private func readProjectConfined(relDir: String) -> [SpecialistDefinition] {
        guard let confined = try? ConfinedRoot(root: projectRoot),
              let entries = try? confined.entries(relDir) else { return [] }
        return entries.filter { !$0.isDir && $0.name.hasSuffix(".md") }.sorted { $0.name < $1.name }.compactMap { e in
            guard let text = try? confined.readString(relDir + "/" + e.name) else { return nil }
            return SpecialistDefinition.parse(text, source: projectRoot + "/" + relDir + "/" + e.name)
        }
    }

    /// Trusted-dir read (user scope) — plain FileManager, no confinement.
    private static func readPlain(dir: String) -> [SpecialistDefinition] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.sorted().compactMap { file in
            let path = dir + "/" + file
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return SpecialistDefinition.parse(text, source: path)
        }
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }
}

public enum SpecialistRegistryError: Error, Equatable {
    case invalid(String)
}
