import XCTest
@testable import AgentCore

/// Proof-carrying patches: an agent's machine-checkable claims about its own diff, evaluated deterministically.
/// A true claim passes; a false one fails (so a lying patch can't produce a passing receipt); an unknown kind
/// fails closed.
final class ProofCarryingPatchTests: XCTestCase {
    private let diff = """
    diff --git a/code.swift b/code.swift
    +func parseFoo() { let x = compute() }
    +let y = 2
    """
    private let files = ["code.swift"]

    private func check(_ kind: String, _ value: String) -> ReceiptCheck {
        ProofChecker.evaluate(diff: diff, changedFiles: files,
                              claims: [ProofClaim(kind: kind, value: value)]).first!
    }

    func testAddedMatchesTrueAndFalse() {
        XCTAssertTrue(check("added-matches", "func parseFoo").passed)
        XCTAssertFalse(check("added-matches", "func doesNotExist").passed)
    }

    func testAddedAbsentCatchesForbiddenPattern() {
        XCTAssertTrue(check("added-absent", "TODO").passed, "no added line has TODO → absent claim holds")
        XCTAssertFalse(check("added-absent", "func parseFoo").passed, "the pattern IS present → absent claim fails")
    }

    func testFileTouchedAndAbsent() {
        XCTAssertTrue(check("file-touched", "code.swift").passed)
        XCTAssertFalse(check("file-touched", "Tests/FooTests.swift").passed, "a lying 'added a test' claim fails")
        XCTAssertTrue(check("file-absent", "secrets.env").passed)
        XCTAssertFalse(check("file-absent", "code.swift").passed)
    }

    func testMaxAddedLines() {
        XCTAssertTrue(check("max-added-lines", "5").passed)     // 2 added lines ≤ 5
        XCTAssertFalse(check("max-added-lines", "1").passed)    // 2 > 1
        XCTAssertFalse(check("max-added-lines", "notanint").passed, "a non-integer bound fails, not crashes")
    }

    func testScope() {
        XCTAssertTrue(check("scope", "code.swift").passed)
        XCTAssertTrue(check("scope", "src/;code.swift").passed)
        XCTAssertFalse(ProofChecker.evaluate(diff: diff, changedFiles: ["code.swift", "prod/secret.txt"],
                                             claims: [ProofClaim(kind: "scope", value: "code.swift")]).first!.passed)
    }

    /// Self-review finding: `scope` must be PATH-COMPONENT aware — `scope=src` must NOT match a sibling dir
    /// `src2/`, else an out-of-scope change could falsely claim it stayed in scope.
    func testScopeIsComponentAwareNotRawPrefix() {
        let ev: ([String], String) -> Bool = { files, scope in
            ProofChecker.evaluate(diff: self.diff, changedFiles: files,
                                  claims: [ProofClaim(kind: "scope", value: scope)]).first!.passed
        }
        XCTAssertFalse(ev(["src2/evil.swift"], "src"), "scope=src must not match sibling dir src2/")
        XCTAssertTrue(ev(["src/ok.swift"], "src"), "scope=src matches src/… at a component boundary")
        XCTAssertTrue(ev(["src/ok.swift"], "src/"), "trailing slash also works")
        XCTAssertTrue(ev(["src"], "src"), "an exact-path match is in scope")
        XCTAssertFalse(ev(["srcfoo"], "src"), "scope=src must not match srcfoo")
    }

    func testUnknownKindFailsClosed() {
        let c = check("teleport", "anything")
        XCTAssertFalse(c.passed)
        XCTAssertTrue(c.detail.contains("unknown proof kind"))
    }

    /// Codex gate9 LOW: an INVALID regex must FAIL the check (not silently pass an `added-absent` claim because
    /// Foundation returns "no match" for a malformed pattern).
    func testInvalidRegexFailsClosed() {
        XCTAssertFalse(check("added-absent", "(").passed, "a malformed absence pattern can't certify absence")
        XCTAssertFalse(check("added-matches", "(").passed)
        XCTAssertTrue(check("added-absent", "(").detail.contains("fail-closed"))
    }

    func testTooManyClaimsFailsClosed() {
        let many = (0...ProofChecker.maxClaims).map { ProofClaim(kind: "file-touched", value: "f\($0)") }
        let checks = ProofChecker.evaluate(diff: diff, changedFiles: files, claims: many)
        XCTAssertEqual(checks.count, 1)
        XCTAssertFalse(checks[0].passed)
        XCTAssertTrue(checks[0].detail.contains("too many claims"))
    }

    func testRequiredFlagFlows() {
        let checks = ProofChecker.evaluate(diff: diff, changedFiles: files,
            claims: [ProofClaim(kind: "file-touched", value: "x", required: false)])
        XCTAssertFalse(checks[0].required, "an advisory claim is recorded but doesn't gate the verdict")
    }
}
