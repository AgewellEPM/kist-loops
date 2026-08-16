import Foundation

// MARK: Path confinement (fail-closed)

/// Confines model-authored / on-disk path components to a sandbox root BEFORE any file is written,
/// loaded, or executed.
///
/// A `--evolve` reply — and the `manifest.json` it leaves on disk — is UNTRUSTED: its `manifest.name`
/// and `scriptFile` flow straight into `appendingPathComponent`. Checking only the `self__` name prefix
/// does NOT make the path safe — a name like `self__x/../../etc/passwd` or a `scriptFile` of `../../foo`
/// would escape the candidates / tool-home root and let a hostile (or tampered) manifest overwrite a
/// write site or later re-execute an arbitrary Kist-writable file. This helper is the single gate every
/// author/save/load/execute site passes through, and it is fail-closed: anything it cannot prove safe is
/// rejected and NOTHING is written or run.
///
/// Shared by `LiveEvolutionOrgans` (author write + adversary execute), `SelfAuthoredToolStore` (the real
/// activation write), and `SelfAuthoredManifest.loadFrom` / `ScriptTool.execute` (the activation load +
/// execute). Keeping it in one place means every site enforces the identical invariant.
enum PathConfinement {
    /// A single, safe path SEGMENT. Rejects anything that is not exactly one benign component:
    /// empty, absolute (`/…`), a path separator (`/` or `\`), a `..` traversal, or a dot-leading
    /// (hidden / `.`/`..`) name. Returns the component only when it is provably a plain filename.
    static func safeComponent(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }                       // empty → reject
        guard !raw.contains("/"), !raw.contains("\\") else { return nil } // any separator → reject
        guard raw != "." , raw != ".." else { return nil }           // current/parent dir → reject
        guard !raw.hasPrefix(".") else { return nil }                // hidden / dot-leading (incl. absolute-after-sep) → reject
        // Defense-in-depth: after normalization the component must be unchanged and single-segment.
        let normalized = (raw as NSString).standardizingPath
        guard normalized == raw, !normalized.contains("/") else { return nil }
        return raw
    }

    /// Build `root/<components…>` from UNTRUSTED components, then PROVE the resolved destination is still a
    /// descendant of the resolved root. Every component must pass `safeComponent`; the final URL is
    /// standardized + symlink-resolved and its path must be `root` or strictly under `root/`. Returns nil
    /// (write/load/run nothing) on any violation.
    static func confinedDestination(root: String, components: [String]) -> URL? {
        // Resolve the root itself so a symlinked candidates dir can't be used to smuggle the check.
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        var dest = rootURL
        for raw in components {
            guard let comp = safeComponent(raw) else { return nil }   // fail-closed on the first bad segment
            dest = dest.appendingPathComponent(comp)
        }
        let resolved = dest.standardizedFileURL.resolvingSymlinksInPath()
        // The resolved destination must equal the root or sit strictly beneath `root/` — never escape it.
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard resolved.path == rootURL.path || resolved.path.hasPrefix(rootPath) else { return nil }
        return resolved
    }
}
