import Foundation

/// Records which skills the model actually LOADED (read the body of) during a session.
/// Used for telemetry — "which skills did this run use" — and to drive the no-fabrication
/// spine later (a skill claimed-but-never-loaded is a signal). Name-based, restricted to the
/// active set so a builtin overridden by a user skill of the same name isn't misattributed.
///
/// An `actor`: the loop marks loads from tool execution while diagnostics read concurrently.
public actor SkillTracker {
    /// Read-only tools that a skill allow-list can NEVER remove: the agent must always be able to
    /// investigate and to LOAD MORE SKILLS (read_file is how a skill body is loaded), or a single
    /// scoped skill would brick the session. Scoping only ever restricts mutating/powerful tools.
    public static let alwaysSafe: Set<String> = [
        "read_file", "read_files", "list_files", "glob_files", "search_code", "context_brain", "ask_user",
        "shared_memory", "list_agents",
    ]

    /// The capability scope proven from a skill's LOAD-TIME verified bytes. TRI-STATE so an absent
    /// `allowed-tools` field (→ `.unrestricted`) is not conflated with an empty restriction (which would
    /// wrongly cap a no-scope skill to read-only). A name with no entry means "load path supplied no
    /// scope" (e.g. a builtin) → fall back to the discovery snapshot.
    enum LoadScope: Equatable { case unrestricted; case restricted([String]) }

    private var loaded: Set<String> = []
    /// Names loaded as UNTRUSTED, decided at LOAD time from the actual bytes (not the discovery-time
    /// cache) — this is the TOCTOU fix: a benign-at-pin / malicious-at-load swap loads as untrusted.
    private var loadedUntrusted: Set<String> = []
    /// name → LOAD-TIME verified scope (tri-state). The authority for capability scope — NOT
    /// `restrictiveTools`, which is a discovery-time snapshot. `allowed-tools` lives in the (hashed,
    /// signed) frontmatter, so a broad discovery-time scope must not survive a load proven on other bytes.
    private var loadedScope: [String: LoadScope] = [:]
    private let activeNames: Set<String>
    /// name → discovery-time declared allowed-tools. FALLBACK ONLY — used for a builtin (embedded, so
    /// discovery == shipped bytes, no swap risk) or any trusted load that didn't pass a load-time scope.
    private let restrictiveTools: [String: [String]]

    public init(activeSkills: [Skill]) {
        self.activeNames = Set(activeSkills.map(\.name))
        var restrictive: [String: [String]] = [:]
        for s in activeSkills where !s.allowedTools.isEmpty { restrictive[s.name] = s.allowedTools }
        self.restrictiveTools = restrictive
    }

    /// Mark a skill loaded, recording the LOAD-TIME trust verdict (decided by the caller from the exact
    /// bytes being loaded). No-op if the name isn't active (overridden/disabled). `trusted` defaults true
    /// for builtins; the project-skill load path passes the re-derived verdict. `allowedTools`, when
    /// provided, is the scope parsed from THOSE SAME verified bytes — it becomes the enforced scope so a
    /// stale discovery-time allow-list can't outlive a load proven on different content.
    public func markLoaded(_ name: String, trusted: Bool = true, allowedTools: [String]? = nil) {
        guard activeNames.contains(name) else { return }
        loaded.insert(name)
        if trusted {
            loadedUntrusted.remove(name)
            // Tri-state: an EMPTY (or absent-at-parse ⇒ empty) allowed-tools list means the verified bytes
            // impose NO restriction (.unrestricted) — distinct from `.restricted([...])`. A nil argument
            // (builtin / no load-time scope) leaves no entry → discovery fallback.
            if let allowedTools {
                loadedScope[name] = allowedTools.isEmpty ? .unrestricted : .restricted(allowedTools)
            }
        } else {
            loadedUntrusted.insert(name)
            loadedScope[name] = nil   // an untrusted (re)load surrenders any previously granted scope
        }
    }

    public func isLoaded(_ name: String) -> Bool { loaded.contains(name) }
    public func loadedNames() -> [String] { loaded.sorted() }
    public func loadedCount() -> Int { loaded.count }

    /// The capability scope in force right now. nil = unrestricted (no untrusted skill loaded AND no
    /// trusted restrictive skill loaded — the common case, zero behavior change). Otherwise the
    /// always-safe read-only set PLUS the union of declared tools across loaded TRUSTED restrictive
    /// skills. An untrusted loaded skill contributes nothing → it forces the session to read-only
    /// (its self-declared allow-list is ignored), which is the security boundary: a malicious skill
    /// can't grant itself run_command. A trusted skill that grants a tool can still lift it.
    public func activeToolAllowlist() -> Set<String>? {
        // UNTRUSTED DOMINATES (Codex gate): if ANY skill loaded as untrusted is in play, the session
        // is read-only — no trusted skill may lift it. Contaminated context ⇒ least privilege.
        if !loadedUntrusted.isEmpty { return Self.alwaysSafe }
        // No untrusted skill loaded. The scope for each loaded skill comes from its LOAD-TIME verified
        // bytes (`loadedScope`, tri-state) — trust was proven on THOSE bytes, so THOSE are the authorized
        // tools. A `.unrestricted` skill contributes nothing (doesn't force a restriction, doesn't lift a
        // co-loaded restrictive one). `restrictiveTools` (discovery) is the fallback only when the load
        // path supplied no scope (builtins). Once ANY restrictive skill is loaded, the session caps to the
        // union of restrictive tools + always-safe (most-restrictive-wins, unchanged semantics).
        var restricted = Self.alwaysSafe
        var sawRestrictive = false
        for name in loaded {
            switch effectiveScope(name) {
            case .restricted(let tools): restricted.formUnion(tools); sawRestrictive = true
            case .unrestricted, nil: continue
            }
        }
        return sawRestrictive ? restricted : nil
    }

    /// A skill's effective scope: its LOAD-TIME verified tri-state if present, else the discovery-time
    /// declared tools (fallback for builtins / no-load-scope loads), else nil (no restriction known).
    private func effectiveScope(_ name: String) -> LoadScope? {
        if let s = loadedScope[name] { return s }
        if let disc = restrictiveTools[name], !disc.isEmpty { return .restricted(disc) }
        return nil
    }

    /// The allowed-tools a given active skill declared (for surfacing the scope on load). Empty when the
    /// skill is unrestricted / not active. Prefers the LOAD-TIME verified scope over the discovery snapshot.
    public func declaredTools(for name: String) -> [String] {
        switch effectiveScope(name) {
        case .restricted(let tools): return tools
        case .unrestricted, nil: return []
        }
    }
}
