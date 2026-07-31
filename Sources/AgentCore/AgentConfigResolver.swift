import Foundation

/// Resolves which single `AGENTS.md` file an agent session should load — the Swift port of the
/// `~/bin/agent-config-loader.sh` scheme (task board #2/#3/#4, 2026-07-29).
///
/// Resolution (NO merging — the resolved file fully REPLACES any other, per the v1 spec):
///   1. If an `AGENTS/` directory exists at the config root:
///        - load `AGENTS/<agent>/AGENTS.md` when that specific file exists,
///        - else fall back to `AGENTS/default/AGENTS.md`.
///   2. If `AGENTS/` does NOT exist, load the root `AGENTS.md`.
///
/// `resolve` is a pure function of the filesystem: it returns the path it WOULD load even when the
/// file is absent, so callers can `test -f`/check existence and a missing config is visible, not
/// silent. `exists` reports whether the resolved file is actually present.
public enum AgentConfigResolver {
    /// The agent name used when a caller doesn't specify one — mirrors the shell loader's default.
    public static let defaultAgent = "default"

    /// The effective `AGENTS.md` path for `agent` under `root`. Never fails; the returned path may
    /// not exist on disk (by design — a missing config should be observable, not swallowed).
    public static func resolve(root: String, agent: String = defaultAgent) -> String {
        let fm = FileManager.default
        let agentsDir = root + "/AGENTS"
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: agentsDir, isDirectory: &isDir), isDir.boolValue {
            let specific = agentsDir + "/\(agent)/AGENTS.md"
            if fm.fileExists(atPath: specific) { return specific }
            return agentsDir + "/default/AGENTS.md"
        }
        return root + "/AGENTS.md"
    }

    /// The resolved path, plus whether it actually exists on disk. `nil` when nothing is loadable
    /// (the resolved file is absent) — lets a caller cleanly skip ingestion of a missing config.
    public static func resolveExisting(root: String, agent: String = defaultAgent) -> String? {
        let path = resolve(root: root, agent: agent)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
