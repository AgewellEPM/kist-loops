import Foundation

/// Legacy human-readable Cortex archive. Existing Markdown remains available for explicit operator audit,
/// but it has no trustworthy per-entry event clock and therefore never enters operational prompt recall.
/// Runtime mutation is refused; new agent memory uses the temporal semantic-memory V2 tools.
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

    // MARK: - operational boundary

    /// Legacy Markdown has no safe age projection. It is raw audit only, even if a historical file name or
    /// modification time appears date-like; neither is promoted to event evidence.
    public func context(projectName: String? = nil, journalDays: Int = 3, maxBytes: Int = 6000) -> String {
        _ = projectName
        _ = journalDays
        _ = maxBytes
        return ""
    }

    // MARK: - retired mutation API

    /// Kept as a source-compatible refusal so old call sites cannot silently resume timeless writes.
    public func seedIfNeeded() throws {
        throw CortexError.auditOnly
    }

    /// Legacy Cortex Markdown is immutable to the runtime. Use temporal semantic memory V2.
    public func remember(_ fact: String) throws {
        _ = fact
        throw CortexError.auditOnly
    }

    /// Legacy Cortex Markdown is immutable to the runtime. Use temporal semantic memory V2.
    public func rememberProject(_ rawName: String, _ fact: String) throws {
        _ = rawName
        _ = fact
        throw CortexError.auditOnly
    }

    /// A date-like filename is not a structured per-entry event clock; runtime journaling is refused.
    public func logWork(_ entry: String, date: String) throws {
        _ = entry
        _ = date
        throw CortexError.auditOnly
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

    public enum CortexError: Error, CustomStringConvertible {
        case auditOnly
        public var description: String {
            "legacy cortex Markdown is raw audit-only; use temporal semantic memory V2"
        }
    }

    private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    /// A cortex name/date → safe filename component (no path traversal). Fail-closed: strip everything but
    /// ASCII letters/digits/`-`/`_`.
    static func safe(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(s.map { allowed.contains($0) ? $0 : "-" })
        return cleaned.isEmpty ? "untitled" : cleaned
    }

}
