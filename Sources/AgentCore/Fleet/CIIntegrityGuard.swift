import Foundation

/// Fail-closed checks over the committed test surface — ported from TinkySDR's Captain (C1). A green
/// test exit is not enough if the agent made the suite EASIER: deleted a failing test, added an
/// XCTSkip, focused a JS suite (`.only`/`fdescribe`/`fit`), or made the runner ignore failures
/// (`|| true`, `set +e`, `exit 0`). It reads ONLY the committed diff that will merge; any finding
/// blocks fleet signoff upstream in the Foreman. PURE + deterministic. No git, no shell, no clocks.
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
        for raw in committedDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let path = diffPath(from: line) { currentFile = path; continue }
            if line.hasPrefix("new file mode"), let f = currentFile { newFiles.insert(f) }
            if line == "--- /dev/null", let f = currentFile { newFiles.insert(f) }
            guard let file = currentFile else { continue }

            if line.hasPrefix("-"), !line.hasPrefix("---") {
                let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if isTestPath(file), isSwiftTestDeclaration(body) {
                    findings.append(CIIntegrityFinding(kind: "test_deleted", claim: body,
                        detail: "committed diff removes a Swift test in \(file); test count must not go down"))
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
            }
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
