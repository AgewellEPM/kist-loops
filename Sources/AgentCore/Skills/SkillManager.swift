import Foundation

/// The per-workspace skill set: discovered, deduplicated, filtered, and ready to project into
/// the system prompt. Immutable + `Sendable` — built once at loop start. (Live re-discovery on
/// file change is a later increment; the headless server will own a manager per workspace, which
/// is why this is workspace-scoped state, not a process global.)
public struct SkillManager: Sendable {
    /// All discovered skills, deduplicated (pre-filter, includes disabled). Builtins first,
    /// then project-local; last-wins on name so a project skill OVERRIDES a builtin.
    public let allSkills: [Skill]
    /// Post-filter: `allSkills` minus the configured `disabled` names. This is what the model sees.
    public let activeSkills: [Skill]
    public let states: [SkillState]
    /// Builtin skill names that a PROJECT-LOCAL skill shadowed (last-wins). A repo overriding a
    /// trusted builtin is a supply-chain surface — surfaced here (not silent) so a host/`/skills`
    /// command can warn. Precedence is unchanged (project wins); only visibility is added.
    public let overriddenBuiltins: [String]

    public init(allSkills: [Skill], activeSkills: [Skill], states: [SkillState],
                overriddenBuiltins: [String] = []) {
        self.allSkills = allSkills
        self.activeSkills = activeSkills
        self.states = states
        self.overriddenBuiltins = overriddenBuiltins
    }

    /// An empty manager — the safe default for runtimes that don't opt into skills.
    public static let empty = SkillManager(allSkills: [], activeSkills: [], states: [])

    /// Discover from builtins + project-local skills under `confined`'s root.
    /// - Parameter disabled: skill names to exclude from the active set.
    public static func discover(confined: ConfinedRoot, disabled: Set<String> = [],
                                trustStorePath: String? = nil) -> SkillManager {
        let (builtins, builtinStates) = SkillDiscovery.discoverBuiltins()
        let trustStore = SkillTrustStore.load(root: confined.rootPath, storePath: trustStorePath)
        let (local, localStates) = SkillDiscovery.discoverProjectLocal(confined: confined, trustStore: trustStore)

        // Builtins first so project-local entries win the last-wins dedup.
        let deduped = dedup(builtins + local)
        let active = deduped.filter { !disabled.contains($0.name) }
        let states = dedupStates(builtinStates + localStates)
        // A project-local skill whose name matches a builtin shadows it — record which, for warnings.
        let builtinNames = Set(builtins.map(\.name))
        let overridden = local.map(\.name).filter { builtinNames.contains($0) }.sorted()
        return SkillManager(allSkills: deduped, activeSkills: active, states: states,
                            overriddenBuiltins: overridden)
    }

    /// Convenience: build a `ConfinedRoot` for `projectRoot` and discover. Returns `.empty`
    /// (never throws) if the root can't be confined — skills are best-effort, never fatal.
    public static func discover(projectRoot: String, disabled: Set<String> = []) -> SkillManager {
        guard let confined = try? ConfinedRoot(root: projectRoot) else {
            let (builtins, builtinStates) = SkillDiscovery.discoverBuiltins()
            let deduped = dedup(builtins)
            return SkillManager(allSkills: deduped,
                                activeSkills: deduped.filter { !disabled.contains($0.name) },
                                states: builtinStates)
        }
        return discover(confined: confined, disabled: disabled)
    }

    // MARK: Prompt projection (Tier 1)

    /// The `<available_skills>` menu for the system prompt — name/description/location only.
    /// Empty string when there are no model-invocable skills (so callers can append unconditionally).
    public func promptXML() -> String {
        let entries = activeSkills.compactMap { $0.promptEntry() }
        guard !entries.isEmpty else { return "" }
        return "<available_skills>\n" + entries.joined(separator: "\n") + "\n</available_skills>"
    }

    /// Map of `location` → skill name for the `read_file` load hook. Only MODEL-INVOCABLE skills
    /// with a non-empty location are included: a skill the model was never offered must not get
    /// whole-file/tracked treatment if the model guesses its path. (User-only skills load via the
    /// slash-command path, not read_file.)
    public func locationIndex() -> [String: String] {
        var map: [String: String] = [:]
        for s in activeSkills where !s.disableModelInvocation && !s.skillFilePath.isEmpty {
            map[s.skillFilePath] = s.name
        }
        return map
    }

    /// The skill matching a user-invoked id (by name), if it's active. Used for slash commands.
    public func findActive(_ name: String) -> Skill? {
        activeSkills.first { $0.name == name }
    }

    /// Active, user-invocable skills — the set a TUI exposes as slash commands.
    public func userInvocable() -> [Skill] {
        activeSkills.filter { $0.userInvocable }
    }

    // MARK: Dedup helpers (last-wins)

    static func dedup(_ all: [Skill]) -> [Skill] {
        var lastIndex: [String: Int] = [:]
        for (i, s) in all.enumerated() { lastIndex[s.name] = i }
        return all.enumerated().filter { lastIndex[$0.element.name] == $0.offset }.map(\.element)
    }

    static func dedupStates(_ all: [SkillState]) -> [SkillState] {
        var lastIndex: [String: Int] = [:]
        for (i, s) in all.enumerated() where !s.name.isEmpty { lastIndex[s.name] = i }
        return all.enumerated().filter { s in
            s.element.name.isEmpty || lastIndex[s.element.name] == s.offset
        }.map(\.element)
    }
}
