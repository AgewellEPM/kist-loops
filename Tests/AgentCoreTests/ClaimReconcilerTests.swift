import XCTest
@testable import AgentCore

/// The anti-hallucination layer catches claims the MEASURED evidence contradicts, while an HONEST
/// agent (claims match) is untouched. A claim only ever makes the gate stricter, never looser.
final class ClaimReconcilerTests: XCTestCase {

    // MARK: honest claims pass

    func testHonestClaimsProduceNoFindings() {
        let claims = AgentClaims(files: ["Core/Foo.swift"], symbols: ["loginUser"],
                                 testsPass: true, actions: ["wired the button"])
        let findings = ClaimReconciler.reconcile(
            claims: claims, committedFiles: ["Core/Foo.swift"],
            diffText: "+ func loginUser() {\n+   // ...\n+ }", testExitCode: 0)
        XCTAssertTrue(findings.isEmpty, "claims that match the evidence are clean")
    }

    func testSuffixPathMatchSupportsAClaim() {
        let claims = AgentClaims(files: ["Foo.swift"], symbols: [], testsPass: nil, actions: [])
        let f = ClaimReconciler.reconcile(claims: claims, committedFiles: ["Core/Foo.swift"],
                                          diffText: "", testExitCode: 0)
        XCTAssertTrue(f.isEmpty)
    }

    // MARK: hallucinations are caught

    func testClaimedFileNotInDiffIsCaught() {
        let claims = AgentClaims(files: ["Core/Database.swift"], symbols: [], testsPass: nil, actions: [])
        let f = ClaimReconciler.reconcile(claims: claims, committedFiles: ["Core/Foo.swift"],
                                          diffText: "+ x", testExitCode: 0)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f.first?.kind, "file_not_touched")
        XCTAssertEqual(f.first?.claim, "Core/Database.swift")
    }

    func testClaimedSymbolAbsentFromDiffIsCaught() {
        let claims = AgentClaims(files: [], symbols: ["loginUser"], testsPass: nil, actions: [])
        let f = ClaimReconciler.reconcile(claims: claims, committedFiles: [],
                                          diffText: "+ func logout() {}", testExitCode: 0)
        XCTAssertEqual(f.first?.kind, "symbol_absent")
        XCTAssertEqual(f.first?.claim, "loginUser")
    }

    func testSymbolMatchIsSubstringExactInDiff() {
        let present = ClaimReconciler.reconcile(
            claims: AgentClaims(files: [], symbols: ["loginUser"], testsPass: nil, actions: []),
            committedFiles: [], diffText: "+ func loginUser(id: Int)", testExitCode: 0)
        XCTAssertTrue(present.isEmpty)
        let absent = ClaimReconciler.reconcile(
            claims: AgentClaims(files: [], symbols: ["loginUserSession"], testsPass: nil, actions: []),
            committedFiles: [], diffText: "+ func loginUser()", testExitCode: 0)
        XCTAssertEqual(absent.first?.kind, "symbol_absent")
    }

    func testClaimedSymbolInLineCommentIsRejected() {
        let f = ClaimReconciler.reconcile(
            claims: AgentClaims(files: [], symbols: ["loginUser"], testsPass: nil, actions: []),
            committedFiles: [], diffText: "+ // TODO: add loginUser soon", testExitCode: 0)
        XCTAssertEqual(f.first?.kind, "symbol_absent",
                       "a comment cannot prove the symbol was added")
    }

    func testClaimedSymbolInBlockCommentIsRejected() {
        let f = ClaimReconciler.reconcile(
            claims: AgentClaims(files: [], symbols: ["loginUser"], testsPass: nil, actions: []),
            committedFiles: [],
            diffText: "+ /* loginUser is discussed here */\n+ let untouched = 1",
            testExitCode: 0)
        XCTAssertEqual(f.first?.kind, "symbol_absent",
                       "a block comment cannot prove the symbol was added")
    }

    func testClaimedSymbolInStringLiteralIsRejected() {
        let f = ClaimReconciler.reconcile(
            claims: AgentClaims(files: [], symbols: ["loginUser"], testsPass: nil, actions: []),
            committedFiles: [], diffText: #"+ let message = "loginUser""#, testExitCode: 0)
        XCTAssertEqual(f.first?.kind, "symbol_absent",
                       "a fixture/log string cannot prove the symbol was added")
    }

    func testClaimedSymbolInRealCodeStillPassesAfterSanitizing() {
        let f = ClaimReconciler.reconcile(
            claims: AgentClaims(files: [], symbols: ["loginUser"], testsPass: nil, actions: []),
            committedFiles: [],
            diffText: #"+ func loginUser() { print("loginUser") } // loginUser"#,
            testExitCode: 0)
        XCTAssertTrue(f.isEmpty, "real added code still satisfies the symbol claim")
    }

    func testClaimedTestsPassButTheyFailedIsCaught() {
        let claims = AgentClaims(files: [], symbols: [], testsPass: true, actions: [])
        let f = ClaimReconciler.reconcile(claims: claims, committedFiles: [], diffText: "", testExitCode: 1)
        XCTAssertEqual(f.first?.kind, "tests_claim_false")
    }

    func testNoTestClaimIsNotCheckedEvenIfTestsFailed() {
        let claims = AgentClaims(files: [], symbols: [], testsPass: nil, actions: [])
        let f = ClaimReconciler.reconcile(claims: claims, committedFiles: [], diffText: "", testExitCode: 1)
        XCTAssertTrue(f.isEmpty)
    }

    func testMultipleHallucinationsAllReported() {
        let claims = AgentClaims(files: ["Ghost.swift"], symbols: ["phantom"], testsPass: true, actions: [])
        let f = ClaimReconciler.reconcile(claims: claims, committedFiles: ["Real.swift"],
                                          diffText: "+ real", testExitCode: 1)
        XCTAssertEqual(Set(f.map(\.kind)), ["file_not_touched", "symbol_absent", "tests_claim_false"])
    }

    // MARK: parse

    func testParsesClaimsFile() {
        let c = ClaimReconciler.parse(#"{"files":["A.swift"],"symbols":["foo"],"testsPass":true,"actions":["x"]}"#)
        XCTAssertEqual(c?.files, ["A.swift"])
        XCTAssertEqual(c?.symbols, ["foo"])
        XCTAssertEqual(c?.testsPass, true)
        XCTAssertEqual(c?.actions, ["x"])
    }

    func testParseToleratesMissingFieldsAndStringBool() {
        let c = ClaimReconciler.parse(#"{"files":["A.swift"],"tests_pass":"fail"}"#)
        XCTAssertEqual(c?.files, ["A.swift"])
        XCTAssertEqual(c?.symbols, [])
        XCTAssertEqual(c?.testsPass, false, "snake_case + string bool tolerated")
    }

    // MARK: G2 — adds-a-test (acceptance criterion proven, not just inspected)

    func testAddsATestDetectsNewTestFunctionOnAddedLine() {
        XCTAssertTrue(ClaimReconciler.addsATest(committedDiff: "+    func testLeaseHonored() {\n+      // ...\n+    }"))
        XCTAssertTrue(ClaimReconciler.addsATest(committedDiff: "diff\n+func test_render() {}"))
    }

    func testAddsATestFalseWhenNoTestAdded() {
        XCTAssertFalse(ClaimReconciler.addsATest(committedDiff: "+ func render() {}  // not a test"))
        XCTAssertFalse(ClaimReconciler.addsATest(committedDiff: "- func testOld() {}"), "a REMOVED test doesn't count")
        XCTAssertFalse(ClaimReconciler.addsATest(committedDiff: "  func testContext() {}"), "a context line doesn't count")
        XCTAssertFalse(ClaimReconciler.addsATest(committedDiff: ""))
    }

    func testAddsATestRejectsCommentAndStringFalsePositives() {
        XCTAssertFalse(ClaimReconciler.addsATest(committedDiff: "+ // func testFoo() {}"), "a comment is not a test")
        XCTAssertFalse(ClaimReconciler.addsATest(committedDiff: #"+ let s = "func testBar() {""#), "a string literal is not a test")
        XCTAssertFalse(ClaimReconciler.addsATest(committedDiff: "+ // we should add func testBaz later"))
        XCTAssertTrue(ClaimReconciler.addsATest(committedDiff: "+    func testReal() {"))
        XCTAssertTrue(ClaimReconciler.addsATest(committedDiff: "+ private func testPrivate() throws {"))
    }

    func testHasVerifiableClaimExcludesActionsOnly() {
        XCTAssertFalse(AgentClaims(files: [], symbols: [], testsPass: nil, actions: ["did stuff"]).hasVerifiableClaim)
        XCTAssertTrue(AgentClaims(files: ["A.swift"], symbols: [], testsPass: nil, actions: []).hasVerifiableClaim)
        XCTAssertTrue(AgentClaims(files: [], symbols: [], testsPass: false, actions: []).hasVerifiableClaim)
    }

    func testEmptyOrGarbageClaimsReturnNil() {
        XCTAssertNil(ClaimReconciler.parse("not json"))
        XCTAssertNil(ClaimReconciler.parse("{}"), "no fields ⇒ no claims ⇒ nothing to reconcile")
        XCTAssertNil(ClaimReconciler.parse(#"{"files":[],"symbols":[]}"#))
    }
}
