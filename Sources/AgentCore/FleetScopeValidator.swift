import Foundation

/// Turns the planner's PROPOSED per-step file scopes into a TRUSTWORTHY, DISJOINT fleet lease.
///
/// The planner is ASKED to assign each subtask a disjoint set of dir-prefix globs (the LEASE). It is
/// NOT TRUSTED: a model can hallucinate paths or hand two agents the SAME directory (the collision the
/// fan-out discipline forbids). This validator is the deterministic gate between "the model proposed
/// scopes" and "the fleet uses scopes."
///
/// SCOPING MODEL: directory-PREFIX. `Core/Captain/*` OWNS the subtree at `Core/Captain` — the agent may
/// edit existing files AND create NEW files under it. A scope is REAL iff its owned dir exists (or its
/// parent does, allowing a brand-new subdir/file).
///
/// FAIL DIRECTION — toward PERMISSIVE, never blocking legit work: a hallucinated glob is DROPPED; when
/// two steps' scopes OVERLAP, BOTH are cleared to [] (no lease ⇒ permissive). Handing two agents a
/// colliding NON-empty lease is the one outcome we must never produce. Every drop/clear is reported.
///
/// PURE + deterministic + fully unit-tested. No I/O — the caller supplies the real repo directories.
/// Ported from TinkySDR's Captain (Stage 1.1).
public enum FleetScopeValidator {

    /// The outcome of validating one plan's worth of per-step proposed scopes.
    public struct Result: Equatable, Sendable {
        /// Per-step CLEANED scopes, parallel to input order: hallucinated globs dropped, colliding
        /// steps cleared to []. This is what the fleet uses.
        public let scopesPerStep: [[String]]
        /// True iff EVERY input glob was real AND all steps were pairwise disjoint (nothing dropped
        /// or cleared) — a clean bill of health.
        public let clean: Bool
        /// Human-readable problems (hallucinated paths, collisions) — never silent.
        public let issues: [String]
    }

    /// Validate `scopesPerStep` against the repo's real `knownDirs` (repo-relative directory paths;
    /// include "" for the root). Returns cleaned scopes + issues.
    public static func validate(scopesPerStep: [[String]], knownDirs: Set<String>) -> Result {
        var issues: [String] = []

        // PASS 1 — drop hallucinated/malformed globs and CANONICALIZE survivors so the stored lease
        // matches the agent's committed files under the SAME matcher the Foreman uses.
        var droppedAny = false
        var realPerStep: [[String]] = []
        for (i, scopes) in scopesPerStep.enumerated() {
            var kept: [String] = []
            for rawGlob in scopes {
                let glob = normalize(rawGlob)
                // GRAMMAR GATE: accept ONLY an exact path or a "<dir>/*" subtree. A partial-component
                // wildcard ("Core/Capt*") prefix-matches across sibling dirs in the matcher but
                // overlaps() reduces it to a component prefix → would MASK a real collision.
                guard isCanonicalGrammar(glob) else {
                    droppedAny = true
                    issues.append("step \(i): dropped malformed scope \"\(rawGlob)\" (use an exact path or \"<dir>/*\")")
                    continue
                }
                guard isReal(glob, knownDirs: knownDirs) else {
                    droppedAny = true
                    issues.append("step \(i): dropped hallucinated scope \"\(rawGlob)\" (no such directory)")
                    continue
                }
                for c in canonicalScope(glob, knownDirs: knownDirs) where !kept.contains(c) { kept.append(c) }
            }
            realPerStep.append(kept)
        }

        // PASS 2 — pairwise overlaps. A step colliding with ANY other is cleared to [] (permissive).
        var collidingSteps = Set<Int>()
        for a in realPerStep.indices {
            for b in realPerStep.indices where b > a {
                for ga in realPerStep[a] {
                    for gb in realPerStep[b] where overlaps(ga, gb) {
                        collidingSteps.insert(a); collidingSteps.insert(b)
                        issues.append("steps \(a) & \(b): scope collision \"\(ga)\" ⇄ \"\(gb)\" — both cleared (permissive)")
                    }
                }
            }
        }

        var cleaned = realPerStep
        for i in collidingSteps { cleaned[i] = [] }
        // `clean` = nothing dropped + nothing cleared. NOT a count comparison (canonicalization can
        // grow a step's glob count: one dir scope → exact + subtree).
        let clean = !droppedAny && collidingSteps.isEmpty
        return Result(scopesPerStep: cleaned, clean: clean, issues: issues)
    }

    // MARK: - Pure helpers (unit-tested)

    /// True iff `glob` is the ONLY grammar whose matcher semantics equal `overlaps()`'s component-
    /// prefix semantics: an exact path (no "*"), or a full-component subtree "<path>/*" (one "*",
    /// trailing). A partial-component wildcard is rejected.
    public static func isCanonicalGrammar(_ glob: String) -> Bool {
        let g = glob.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty else { return false }
        let stars = g.reduce(0) { $1 == "*" ? $0 + 1 : $0 }
        if stars == 0 { return true }
        return stars == 1 && g.hasSuffix("/*")
    }

    /// Rewrite one canonical-grammar glob into the form(s) the matcher consumes, so the stored lease
    /// matches the files the agent legitimately owns and none it shouldn't. A "<dir>/*" is kept; a
    /// bare path becomes its exact self always; the subtree "<path>/*" is added when the owned path is
    /// a KNOWN directory (authoritative — a dotted dir like Assets.xcassets still gets its subtree) OR,
    /// for a new/unknown path, when its last component is dotless (looks like a dir). A FILE owns only itself.
    public static func canonicalScope(_ glob: String, knownDirs: Set<String>) -> [String] {
        let g = collapseSlashes(glob.trimmingCharacters(in: .whitespaces))
        guard !g.isEmpty else { return [] }
        if g.hasSuffix("/*") { return [g] }
        let owned = ownedPrefix(g)
        guard !owned.isEmpty else { return [] }
        let last = owned.split(separator: "/").last.map(String.init) ?? owned
        let isDir = knownDirs.contains(owned) || !last.contains(".")
        return isDir ? [owned, owned + "/*"] : [owned]
    }

    /// Collapse repeated slashes ("a//b" → "a/b").
    public static func collapseSlashes(_ s: String) -> String {
        var out = s
        while out.contains("//") { out = out.replacingOccurrences(of: "//", with: "/") }
        return out
    }

    /// Canonicalize a glob to repo-relative clean-path form: trim, strip leading "./" + "/", collapse
    /// "//". A "../" segment is intentionally NOT stripped (it's dropped by isReal → permissive).
    public static func normalize(_ glob: String) -> String {
        var s = glob.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasPrefix("/") { s.removeFirst() }
        return collapseSlashes(s)
    }

    /// The OWNED directory path of a glob: strip a trailing "/*" or "*" and trailing "/".
    public static func ownedPrefix(_ glob: String) -> String {
        var s = glob.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("*") { s.removeLast() }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// True iff the glob names a REAL place to work: its owned dir exists, OR its parent dir does (so
    /// a brand-new file/subdir under a known dir is allowed). An empty owned prefix ("*"/root) is
    /// REFUSED. A brand-new TOP-LEVEL dir (parent == root) is refused (indistinguishable from a
    /// hallucination); the parent must be a known, NON-root directory.
    public static func isReal(_ glob: String, knownDirs: Set<String>) -> Bool {
        let owned = ownedPrefix(glob)
        guard !owned.isEmpty else { return false }
        if knownDirs.contains(owned) { return true }
        let parent = parentDir(owned)
        return !parent.isEmpty && knownDirs.contains(parent)
    }

    /// Path-COMPONENT prefix test: two owned paths overlap when one is the other, or one is an
    /// ancestor of the other. Component-wise so "Core/Cap" does NOT overlap "Core/Captain".
    public static func overlaps(_ a: String, _ b: String) -> Bool {
        let pa = components(ownedPrefix(a))
        let pb = components(ownedPrefix(b))
        guard !pa.isEmpty, !pb.isEmpty else { return true }
        let n = min(pa.count, pb.count)
        for i in 0..<n where pa[i] != pb[i] { return false }
        return true
    }

    /// Parent directory ("Core/Captain/Foo.swift" → "Core/Captain"; a single component → "").
    public static func parentDir(_ path: String) -> String {
        var comps = components(path)
        guard !comps.isEmpty else { return "" }
        comps.removeLast()
        return comps.joined(separator: "/")
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }
}
