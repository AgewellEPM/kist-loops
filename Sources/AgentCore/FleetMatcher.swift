import Foundation

/// The canonical glob matcher for fleet leases. A scope glob is either an exact path (no `*`) or a
/// subtree `<dir>/*`. This is the SINGLE source of matcher semantics that `FleetScopeValidator`
/// canonicalizes its output to AND that the Foreman (Stage 1.6) enforces at the merge gate — so the
/// validator's component-prefix `overlaps()` and the foreman's `matches()` can never diverge (the
/// cross-component seam a raw-glob lease silently broke). Pure; fully testable.
public enum FleetMatcher {
    public static func matches(path: String, glob: String) -> Bool {
        let g = glob.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty else { return false }
        if g == path { return true }
        guard g.hasSuffix("/*") else { return false }
        let dir = String(g.dropLast(1))   // keep trailing "/" so "Core/*" matches "Core/A", not "CoreA"
        guard !dir.isEmpty, !dir.contains("*") else { return false }
        return path.hasPrefix(dir)
    }
}
