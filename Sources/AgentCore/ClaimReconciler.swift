import Foundation

/// The anti-hallucination layer. The fleet already stops a fabricated GREEN (GroundedVerdict's private
/// init + the forge-proof ledger). But that never reconciled what an agent NARRATES about its work
/// against what it ACTUALLY did: "I connected the database" with an empty diff, "I added loginUser()"
/// that's nowhere in the commit, "tests pass" when they didn't.
///
/// This reconciler closes that. An agent emits structured CLAIMS (`.fleet-claims.json`); this
/// deterministically checks each against the MEASURED artifacts the Foreman already has (committed
/// file list, committed diff text, test exit code). Any claim the evidence contradicts is a
/// HALLUCINATION finding the Foreman BLOCKS the signoff on (fail-closed).
///
/// PHILOSOPHY: a claim only ever makes the gate STRICTER (catch a lie), never looser — a claim can
/// NEVER substitute for measured evidence or mint trust. An honest agent (claims match reality) is
/// unaffected. Pure + deterministic. Ported from TinkySDR's Captain (Stage 1.2).
public struct AgentClaims: Equatable, Sendable {
    public let files: [String]        // repo-relative files the agent claims it changed
    public let symbols: [String]      // symbols (func/type/property) it claims it added/changed
    public let testsPass: Bool?       // did it CLAIM tests pass? nil = no test claim
    public let actions: [String]      // free-text side-effects — ADVISORY (surfaced, not gated)
    public init(files: [String], symbols: [String], testsPass: Bool?, actions: [String]) {
        self.files = files; self.symbols = symbols; self.testsPass = testsPass; self.actions = actions
    }
    public var isEmpty: Bool { files.isEmpty && symbols.isEmpty && testsPass == nil && actions.isEmpty }
    /// Has at least one claim RECONCILABLE against measured evidence (files/symbols/tests). An
    /// actions-ONLY file is unverifiable.
    public var hasVerifiableClaim: Bool { !files.isEmpty || !symbols.isEmpty || testsPass != nil }
}

/// One claim the MEASURED evidence contradicts.
public struct ClaimFinding: Equatable, Sendable {
    public let kind: String     // file_not_touched | symbol_absent | tests_claim_false
    public let claim: String
    public let detail: String
    public init(kind: String, claim: String, detail: String) {
        self.kind = kind; self.claim = claim; self.detail = detail
    }
}

public enum ClaimReconciler {

    /// Reconcile claims against measured artifacts. Returns the HALLUCINATION findings (empty ⇒ every
    /// claim is supported). committedFiles = `git diff base...HEAD` paths; diffText = the committed
    /// diff; testExitCode = `./test.sh` exit (0 == green).
    public static func reconcile(claims: AgentClaims, committedFiles: [String],
                                 diffText: String, testExitCode: Int32) -> [ClaimFinding] {
        var findings: [ClaimFinding] = []

        // 1. Claimed-but-untouched files. Supported iff a committed path EXACTLY matches or has the
        //    claim as a COMPONENT-suffix ("Foo.swift" supports "Core/Foo.swift"). NOT the reverse.
        for claimed in claims.files {
            let c = claimed.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { continue }
            let supported = committedFiles.contains { actual in actual == c || actual.hasSuffix("/" + c) }
            if !supported {
                findings.append(ClaimFinding(kind: "file_not_touched", claim: c,
                    detail: "claimed changing “\(c)”, but it is not in the committed diff"))
            }
        }

        // 2. Claimed-but-absent symbols. Must appear as a WHOLE TOKEN in ADDED CODE. Comments and
        //    string literals do not count; a TODO or test fixture string cannot prove a symbol exists.
        let added = addedCodeText(diffText)
        for claimed in claims.symbols {
            let s = claimed.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            if !containsToken(added, s) {
                findings.append(ClaimFinding(kind: "symbol_absent", claim: s,
                    detail: "claimed adding/changing “\(s)”, but it is not a code token on any added line of the committed diff"))
            }
        }

        // 3. Claimed tests pass, but they measurably did not.
        if claims.testsPass == true && testExitCode != 0 {
            findings.append(ClaimFinding(kind: "tests_claim_false", claim: "tests pass",
                detail: "claimed the tests pass, but ./test.sh exited \(testExitCode)"))
        }
        return findings
    }

    /// The text of ADDED diff lines (start with "+", excluding the "+++" header).
    public static func addedLines(_ diff: String) -> String {
        diff.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
            .joined(separator: "\n")
    }

    /// Added code text with comments and string literals removed. This is intentionally lexical, not a
    /// Swift parser: it strips enough non-code surface to prevent obvious proof laundering through
    /// comments, TODOs, and fixture strings while keeping the reconciler pure and language-light.
    public static func addedCodeText(_ diff: String) -> String {
        let addedBodies = diff.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { raw -> String? in
                guard raw.hasPrefix("+"), !raw.hasPrefix("+++") else { return nil }
                return String(raw.dropFirst())
            }
            .joined(separator: "\n")
        return stripCommentsAndStringLiterals(addedBodies)
    }

    /// G2 (TDD): true iff the committed diff ADDS a test — a real `func test…(` DECLARATION on an
    /// ADDED line (anchored after optional access modifiers, requires "("). A comment "// func testFoo()"
    /// or a string literal does NOT count.
    public static func addsATest(committedDiff: String) -> Bool {
        let decl = #"^(override\s+|open\s+|public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|static\s+)*func\s+test\w*\s*\("#
        for raw in committedDiff.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard line.hasPrefix("+"), !line.hasPrefix("+++") else { continue }
            let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            if body.range(of: decl, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// True iff `token` appears in `haystack` bounded by non-identifier chars (Swift ident = letter |
    /// digit | "_"), so "loginUser" is NOT satisfied by "loginUserSession" or by "login" inside it.
    public static func containsToken(_ haystack: String, _ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let h = Array(haystack), t = Array(token)
        guard t.count <= h.count else { return false }
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var i = 0
        while i + t.count <= h.count {
            if Array(h[i..<i + t.count]) == t {
                let before = i > 0 ? h[i - 1] : " "
                let after = (i + t.count) < h.count ? h[i + t.count] : " "
                if !isIdent(before) && !isIdent(after) { return true }
            }
            i += 1
        }
        return false
    }

    /// Remove Swift-style line comments, block comments, and normal string literals while preserving
    /// whitespace/newline boundaries for token matching.
    private static func stripCommentsAndStringLiterals(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        var inBlockComment = false
        var inString = false

        func nextIs(_ c: Character) -> Bool {
            i + 1 < chars.count && chars[i + 1] == c
        }

        while i < chars.count {
            let c = chars[i]

            if inBlockComment {
                if c == "\n" { out.append("\n") }
                if c == "*", nextIs("/") {
                    inBlockComment = false
                    out.append(" ")
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            if inString {
                if c == "\n" { out.append("\n") }
                if c == "\\" {
                    i += 2
                    continue
                }
                if c == "\"" {
                    inString = false
                    out.append(" ")
                    i += 1
                    continue
                }
                i += 1
                continue
            }

            if c == "/", nextIs("/") {
                out.append(" ")
                i += 2
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }

            if c == "/", nextIs("*") {
                inBlockComment = true
                out.append(" ")
                i += 2
                continue
            }

            if c == "\"" {
                inString = true
                out.append(" ")
                i += 1
                continue
            }

            out.append(c)
            i += 1
        }

        return out
    }

    // MARK: - Tolerant parse of `.fleet-claims.json`

    /// Parse an agent's claims file. Fail-soft: missing/garbage ⇒ nil (no claims = nothing to
    /// reconcile, not an error). Tolerates absent fields + snake_case + string bools.
    public static func parse(_ json: String) -> AgentClaims? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let files = stringArray(obj["files"])
        let symbols = stringArray(obj["symbols"])
        let actions = stringArray(obj["actions"])
        let testsPass = boolish(obj["testsPass"]) ?? boolish(obj["tests_pass"])
        let claims = AgentClaims(files: files, symbols: symbols, testsPass: testsPass, actions: actions)
        return claims.isEmpty ? nil : claims
    }

    private static func stringArray(_ v: Any?) -> [String] {
        guard let arr = v as? [Any] else { return [] }
        return arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func boolish(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "yes", "pass", "passed", "green": return true
            case "false", "no", "fail", "failed", "red": return false
            default: return nil
            }
        default: return nil
        }
    }
}
