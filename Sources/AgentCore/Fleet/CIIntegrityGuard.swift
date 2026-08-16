import Foundation

/// Fail-closed checks over the committed test surface — ported from TinkySDR's Captain (C1). A green
/// test exit is not enough if the agent made the suite EASIER: deleted a failing test, added an
/// XCTSkip, focused a JS suite (`.only`/`fdescribe`/`fit`), made the runner ignore failures
/// (`|| true`, `set +e`, `exit 0`), or dropped/disabled a test target in the MANIFEST. It reads ONLY the
/// committed diff that will merge; any finding blocks fleet signoff upstream in the Foreman. PURE +
/// deterministic. No git, no shell, no clocks.
///
/// HONEST LIMIT (do not overclaim): this is a surface diff scanner. It catches NAMED weakenings only. It
/// CANNOT catch: hardcoding the expected value in the IMPL so a test passes without any test/manifest edit
/// (a green `swift test` with an empty diff-finding set); a test-target `path:` retargeted to a directory
/// whose name carries no `Tests` token; or a wholesale manifest rewrite. An EMPTY findings array does NOT
/// mean an honest candidate — it means no NAMED weakening was seen. The real backstops for the unseeable
/// classes are the held-out / moving-target suite + the regression organ (audit 2026-08-15 P1/P3) and
/// no-auto-promote (a human reviews every promotion).
public struct CIIntegrityFinding: Equatable, Sendable {
    public let kind: String
    public let claim: String
    public let detail: String
    public init(kind: String, claim: String, detail: String) { self.kind = kind; self.claim = claim; self.detail = detail }
}

public enum CIIntegrityGuard {

    public static func inspect(committedFiles: [String], committedDiff: String) -> [CIIntegrityFinding] {
        var findings: [CIIntegrityFinding] = []

        // Track newly-CREATED files: creating a verifier (a fresh test.sh) is legitimate; only
        // MODIFYING an existing harness is suspect. New files are excluded from the blanket flag below,
        // while the per-line bypass detection still catches real weakening in either case.
        var newFiles = Set<String>()
        var currentFile: String?
        // MOVE/REORDER RECONCILIATION (P2): git renders a MOVED `.testTarget(` / test-source line as a `-` at the
        // old position AND a `+` with the IDENTICAL content at the new one. A reorder is churn, not a REDUCTION.
        // Hold each removed test-surface line as PENDING keyed on its exact trimmed content, collect the trimmed
        // content of test-surface `+` lines, and emit a removal finding ONLY for content that does NOT reappear.
        // Keying on FULL content (not just a name token) is the safe direction: only an EXACT move nets out — a
        // rename / path-retarget / any real reduction changes the line and is therefore still flagged.
        var addedManifestLines = Set<String>()
        var pendingRemovals: [(body: String, finding: CIIntegrityFinding)] = []
        // A test target wrapped in an ADDED `#if <gate>` block is compiled OUT of `swift test` while its
        // `.testTarget(` line stays as unchanged diff CONTEXT (invisible to the `-` rule). Track whether we are
        // inside such a freshly-added gate so we can flag a `.testTarget(` that falls within it.
        var insideAddedManifestGate = false

        for raw in committedDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let path = diffPath(from: line) { currentFile = path; insideAddedManifestGate = false; continue }
            if line.hasPrefix("new file mode"), let f = currentFile { newFiles.insert(f) }
            if line == "--- /dev/null", let f = currentFile { newFiles.insert(f) }
            guard let file = currentFile else { continue }

            if line.hasPrefix("-"), !line.hasPrefix("---") {
                let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if isTestPath(file), isSwiftTestDeclaration(body) {
                    findings.append(CIIntegrityFinding(kind: "test_deleted", claim: body,
                        detail: "committed diff removes a Swift test in \(file); test count must not go down"))
                }
                // P2 — a candidate scored by `swift test` in its OWN worktree can go green by dropping the FAILING
                // test target from the MANIFEST (no test file changes ⇒ the per-test-file checks never see it).
                // Held as PENDING so a genuine MOVE (identical line re-added below) does not read as a reduction.
                if isManifestPath(file), referencesTestSurface(body) {
                    pendingRemovals.append((body,
                        CIIntegrityFinding(kind: "test_target_removed", claim: body,
                            detail: "committed diff removes a test target / test-source reference from \(file); this shrinks `swift test` with no test file appearing in the diff")))
                }
            }
            // The "+"-line weakening checks apply only to MODIFIED files — a newly-created test/harness
            // is the agent DEFINING its verifier (e.g. a fresh `test.sh` ending in `exit 0`), not
            // weakening an existing one. `-`-line deletion is inherently modification-only already.
            if line.hasPrefix("+"), !line.hasPrefix("+++"), !newFiles.contains(file) {
                let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if isTestPath(file), addsSkipOrDisable(body) {
                    findings.append(CIIntegrityFinding(kind: "test_skip_added", claim: body,
                        detail: "committed diff adds a skip/disable marker in \(file); a worker may not reduce test coverage"))
                }
                if isTestHarnessPath(file), addsRunnerBypass(body) {
                    findings.append(CIIntegrityFinding(kind: "test_runner_bypass", claim: body,
                        detail: "committed diff adds a test-runner bypass in \(file)"))
                }
                if isTestPath(file) || isJSTestPath(file), addsTestFocus(body) {
                    findings.append(CIIntegrityFinding(kind: "test_focused", claim: body,
                        detail: "committed diff focuses the suite to a single test in \(file) (.only/fdescribe/fit) — every other test is silently skipped"))
                }
                if isManifestPath(file), excludesTestSurface(body) {
                    findings.append(CIIntegrityFinding(kind: "test_target_excluded", claim: body,
                        detail: "committed diff adds an exclude over test source(s) in \(file); excluded tests drop out of the run"))
                }
                if isManifestPath(file), referencesTestSurface(body) { addedManifestLines.insert(body) }
            }

            // Manifest `#if`-gate tracking (spans context lines, so it runs OUTSIDE the +/- branches). An ADDED
            // conditional opener starts a gate; a `.testTarget(` on ANY line (added, or unchanged context that the
            // gate now wraps) inside it is compiled out; an `#endif` closes it. Only fires when a gate genuinely
            // wraps a test target, so a legitimate platform gate around non-test targets is NOT flagged.
            if isManifestPath(file) {
                let stripped = (line.hasPrefix("+") || line.hasPrefix("-")) ? String(line.dropFirst()) : line
                let content = stripped.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("+"), !line.hasPrefix("+++"), !newFiles.contains(file),
                   content.range(of: #"^#if(\s|$)"#, options: .regularExpression) != nil {
                    insideAddedManifestGate = true
                }
                if insideAddedManifestGate, content.contains(".testTarget(") {
                    findings.append(CIIntegrityFinding(kind: "test_target_disabled", claim: content,
                        detail: "committed diff wraps a test target in an added #if gate in \(file); a conditionally-compiled-out test target runs zero tests"))
                    insideAddedManifestGate = false
                }
                if content.hasPrefix("#endif") { insideAddedManifestGate = false }
            }
        }

        // Emit only the removals whose exact content did NOT reappear as an addition (a real reduction, not a move).
        for pending in pendingRemovals where !addedManifestLines.contains(pending.body) {
            findings.append(pending.finding)
        }

        // Blanket: an EXISTING harness file was modified (creating a new one is fine). The per-line
        // checks above already catch the specific weakenings; this catches any other harness edit.
        for file in committedFiles.filter({ isTestHarnessPath($0) && !newFiles.contains($0) }).sorted() {
            findings.append(CIIntegrityFinding(
                kind: "test_harness_mutated", claim: file,
                detail: "test runner or CI harness changed (\(file)); a fleet worker may not make the verifier easier"))
        }
        return findings
    }

    static func isTestPath(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.hasPrefix("Tests/") || p.contains("/Tests/") || p.hasPrefix("UITests/")
            || p.contains("/UITests/") || p.hasSuffix("Tests.swift") || p.hasSuffix("UITests.swift")
    }
    static func isJSTestPath(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.contains("__tests__/") || p.hasSuffix(".test.js") || p.hasSuffix(".spec.js")
            || p.hasSuffix(".test.ts") || p.hasSuffix(".spec.ts") || p.hasSuffix(".test.mjs")
            || p.hasSuffix(".spec.mjs") || p.hasSuffix(".test.jsx") || p.hasSuffix(".test.tsx")
    }
    static func addsTestFocus(_ body: String) -> Bool {
        guard !body.hasPrefix("//"), !body.hasPrefix("*") else { return false }
        if body.range(of: #"\.only\s*\("#, options: .regularExpression) != nil { return true }
        return body.range(of: #"(^|[^A-Za-z0-9_$.])(fdescribe|fit)\s*\("#, options: .regularExpression) != nil
    }
    static func isTestHarnessPath(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return p == "test.sh" || p.hasSuffix("/test.sh") || p.hasPrefix(".github/workflows/")
            || p.hasPrefix(".buildkite/") || p.hasPrefix("ci/") || p.hasPrefix("CI/")
    }
    static func isManifestPath(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return p == "Package.swift" || p.hasSuffix("/Package.swift")
    }
    /// Does a manifest diff-line REFERENCE a test target / test source? Used for BOTH the removal finding and the
    /// move-reconciliation. Comment lines are ignored — a commented-out `.testTarget(` is already out of the run,
    /// so deleting the comment cannot change the test surface (mirrors the sibling comment guards).
    static func referencesTestSurface(_ body: String) -> Bool {
        guard !body.hasPrefix("//"), !body.hasPrefix("*") else { return false }
        if body.contains(".testTarget(") { return true }
        // `Tests/` (no leading slash needed) covers a `path:`/`sources:` value pointing at a test directory,
        // e.g. `path: "Tests/AppTests"` — the retarget-to-empty-dir case.
        if body.contains("Tests.swift") || body.contains("Tests/") { return true }
        // a quoted test-target name being removed from a dependencies/sources list, e.g. `"PaymentsTests",`
        if body.range(of: #"["][A-Za-z0-9_]*Tests["]"#, options: .regularExpression) != nil { return true }
        return false
    }
    /// An ADDED manifest `exclude:` that references a test source — the excluded tests silently drop out of the
    /// run even though every test file is untouched. Comment lines are ignored.
    static func excludesTestSurface(_ body: String) -> Bool {
        guard !body.hasPrefix("//"), !body.hasPrefix("*") else { return false }
        guard body.contains("exclude") else { return false }
        if body.contains("Tests.swift") || body.contains("Tests/") { return true }
        return body.range(of: #"["][^"]*Tests[^"]*["]"#, options: .regularExpression) != nil
    }
    static func isSwiftTestDeclaration(_ body: String) -> Bool {
        guard !body.hasPrefix("//"), !body.hasPrefix("*") else { return false }
        let decl = #"^(override\s+|open\s+|public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|static\s+)*func\s+test\w*\s*\("#
        return body.range(of: decl, options: .regularExpression) != nil
    }
    static func addsSkipOrDisable(_ body: String) -> Bool {
        if body.contains("XCTSkip") { return true }
        if body.range(of: #"^\s*#if\s+false\b"#, options: .regularExpression) != nil { return true }
        if body.range(of: #"^\s*return\s*$"#, options: .regularExpression) != nil { return true }
        return false
    }
    static func addsRunnerBypass(_ body: String) -> Bool {
        if body.contains("|| true") { return true }
        if body.range(of: #"(^|[;&|])\s*set\s+\+e\b"#, options: .regularExpression) != nil { return true }
        if body.range(of: #"(^|[;&|])\s*exit\s+0\b"#, options: .regularExpression) != nil { return true }
        if body.range(of: #"(^|[;&|])\s*return\s+0\b"#, options: .regularExpression) != nil { return true }
        return false
    }
    static func diffPath(from line: String) -> String? {
        guard line.hasPrefix("diff --git ") else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4 else { return nil }
        let a = stripDiffPrefix(parts[2]), b = stripDiffPrefix(parts[3])
        if b != "/dev/null" { return b }
        return a == "/dev/null" ? nil : a
    }
    private static func stripDiffPrefix(_ s: String) -> String {
        (s.hasPrefix("a/") || s.hasPrefix("b/")) ? String(s.dropFirst(2)) : s
    }
}
