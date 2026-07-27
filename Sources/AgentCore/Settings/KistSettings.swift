import Foundation

/// Persisted, BYOK-adapted session settings — kist's answer to Claude Code's `settings.json`. Stored at
/// `<root>/.kist/settings.json` (project) and `~/.kist/settings.json` (user); project overrides user
/// field-by-field. Every field is optional so an absent key never clobbers a value set at another scope,
/// and forward/unknown keys are ignored rather than fatal. The `/config` panel reads/writes this; other
/// features (theme, compaction, effort) read their slice.
///
/// This is the MODEL + persistence + the string `key=value` interface only — rendering lives in the REPL
/// layer (ConfigPanel). Kept pure and dependency-free so the merge/validation logic is unit-tested.
public struct KistSettings: Codable, Equatable, Sendable {
    public var model: String?            // default binding, e.g. "gemini:gemini-3.1-pro"  (⟶ /model)
    public var effort: String?           // low | medium | high | xhigh                    (⟶ /think, /effort)
    public var reasoning: Bool?          // show provider reasoning streams
    public var sandbox: String?          // off | confined | strict
    public var autoCompact: Bool?        // summarize the transcript near the window limit
    public var theme: String?            // auto | dark | light | daltonized | high-contrast | mono  (⟶ /theme)
    public var editor: String?           // emacs | vim
    public var includeCoAuthored: Bool?  // add Co-Authored-By trailer on commits
    public var roles: [String: String]?  // role → provider[:model]                        (⟶ /roles)

    public init(model: String? = nil, effort: String? = nil, reasoning: Bool? = nil,
                sandbox: String? = nil, autoCompact: Bool? = nil, theme: String? = nil,
                editor: String? = nil, includeCoAuthored: Bool? = nil, roles: [String: String]? = nil) {
        self.model = model; self.effort = effort; self.reasoning = reasoning
        self.sandbox = sandbox; self.autoCompact = autoCompact; self.theme = theme
        self.editor = editor; self.includeCoAuthored = includeCoAuthored; self.roles = roles
    }

    // MARK: - Precedence merge

    /// Overlay `other` onto `self`: any non-nil field in `other` wins. Used to layer project over user.
    public func merged(over base: KistSettings) -> KistSettings {
        KistSettings(
            model: model ?? base.model,
            effort: effort ?? base.effort,
            reasoning: reasoning ?? base.reasoning,
            sandbox: sandbox ?? base.sandbox,
            autoCompact: autoCompact ?? base.autoCompact,
            theme: theme ?? base.theme,
            editor: editor ?? base.editor,
            includeCoAuthored: includeCoAuthored ?? base.includeCoAuthored,
            roles: roles ?? base.roles)
    }

    // MARK: - key=value interface (for `/config key=value` — pure + testable)

    /// The settable keys with their allowed values (nil ⇒ free-form). Drives validation + the panel's help.
    public static let schema: [(key: String, values: [String]?)] = [
        ("model", nil),
        ("effort", ["low", "medium", "high", "xhigh"]),
        ("reasoning", ["on", "off"]),
        ("sandbox", ["off", "confined", "strict"]),
        ("autoCompact", ["on", "off"]),
        ("theme", ["auto", "dark", "light", "daltonized", "high-contrast", "mono"]),
        ("editor", ["emacs", "vim"]),
        ("includeCoAuthored", ["on", "off"]),
    ]

    public enum ApplyResult: Equatable {
        case updated(KistSettings, key: String, value: String)
        case unknownKey(String)
        case invalidValue(key: String, value: String, allowed: [String])
    }

    /// Apply a single `key=value` to a copy of `settings`, validating against `schema`. Booleans accept
    /// on/off/true/false/1/0. Returns the new settings + a normalized value, or a typed error.
    public static func apply(_ settings: KistSettings, key rawKey: String, value rawValue: String) -> ApplyResult {
        let key = rawKey.trimmingCharacters(in: .whitespaces)
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard let entry = schema.first(where: { $0.key.lowercased() == key.lowercased() }) else {
            return .unknownKey(key)
        }
        let canonicalKey = entry.key
        // Booleans: normalize a range of truthy/falsey spellings to on/off.
        func boolNorm(_ v: String) -> String? {
            switch v.lowercased() {
            case "on", "true", "1", "yes": return "on"
            case "off", "false", "0", "no": return "off"
            default: return nil
            }
        }
        if let allowed = entry.values {
            // A field whose allowed set is exactly on/off is boolean-shaped.
            if allowed == ["on", "off"], let b = boolNorm(value) {
                return .updated(setBool(settings, key: canonicalKey, on: b == "on"), key: canonicalKey, value: b)
            }
            guard allowed.contains(value.lowercased()) else {
                return .invalidValue(key: canonicalKey, value: value, allowed: allowed)
            }
            return .updated(setString(settings, key: canonicalKey, value: value.lowercased()), key: canonicalKey, value: value.lowercased())
        }
        // Free-form (e.g. model).
        return .updated(setString(settings, key: canonicalKey, value: value), key: canonicalKey, value: value)
    }

    private static func setString(_ s: KistSettings, key: String, value: String) -> KistSettings {
        var s = s
        switch key {
        case "model": s.model = value
        case "effort": s.effort = value
        case "sandbox": s.sandbox = value
        case "theme": s.theme = value
        case "editor": s.editor = value
        default: break
        }
        return s
    }

    private static func setBool(_ s: KistSettings, key: String, on: Bool) -> KistSettings {
        var s = s
        switch key {
        case "reasoning": s.reasoning = on
        case "autoCompact": s.autoCompact = on
        case "includeCoAuthored": s.includeCoAuthored = on
        default: break
        }
        return s
    }

    /// One display value per settable key (for the panel), reading the live settings. "—" when unset.
    public func displayValue(forKey key: String) -> String {
        func b(_ v: Bool?) -> String { v.map { $0 ? "on" : "off" } ?? "—" }
        switch key {
        case "model": return model ?? "—"
        case "effort": return effort ?? "—"
        case "reasoning": return b(reasoning)
        case "sandbox": return sandbox ?? "—"
        case "autoCompact": return b(autoCompact)
        case "theme": return theme ?? "—"
        case "editor": return editor ?? "—"
        case "includeCoAuthored": return b(includeCoAuthored)
        default: return "—"
        }
    }
}

/// Disk persistence for `KistSettings`: load (with project-over-user precedence) and save to a scope.
/// Separated from the model so the model stays pure/testable and the IO is swappable.
public struct KistSettingsStore {
    public enum Scope { case project, user }
    let projectRoot: String

    public init(projectRoot: String) { self.projectRoot = projectRoot }

    public static func userPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kist/settings.json")
    }
    public func projectPath() -> String {
        (projectRoot as NSString).appendingPathComponent(".kist/settings.json")
    }

    /// Effective settings: user scope as the base, project scope overlaid on top. A missing or corrupt
    /// file at either scope degrades to empty for that scope (never throws — settings are best-effort).
    public func load() -> KistSettings {
        let user = Self.read(Self.userPath()) ?? KistSettings()
        let project = Self.read(projectPath()) ?? KistSettings()
        return project.merged(over: user)
    }

    /// The raw settings at ONE scope (for editing without flattening precedence).
    public func loadScope(_ scope: Scope) -> KistSettings {
        Self.read(scope == .user ? Self.userPath() : projectPath()) ?? KistSettings()
    }

    @discardableResult
    public func save(_ settings: KistSettings, to scope: Scope) -> Bool {
        let path = scope == .user ? Self.userPath() : projectPath()
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(settings)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch { return false }
    }

    private static func read(_ path: String) -> KistSettings? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(KistSettings.self, from: data)
    }
}
