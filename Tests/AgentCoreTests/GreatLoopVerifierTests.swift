import XCTest
@testable import AgentCore

/// Phase 0 — the anti-Goodhart done-gate. A cycle's "done" must be execution-grounded AND un-gamed.
final class GreatLoopVerifierTests: XCTestCase {
    private func edit() -> ActionRecord { ActionRecord(tool: "edit_file", argsFingerprint: "x", success: true) }
    private func test(_ ok: Bool = true) -> ActionRecord { ActionRecord(tool: "run_command", argsFingerprint: "command=swift test", success: ok) }

    func testGroundedAndCleanIsVerified() {
        let v = GreatLoopVerifier.verify(trajectory: [edit(), test(true)], canRunCommands: true,
                                         changedFiles: ["Sources/Foo.swift"], diff: "diff --git a/Sources/Foo.swift b/Sources/Foo.swift\n+let x = 1")
        XCTAssertEqual(v, .verified)
    }

    func testCodeChangedButNoBuildTestIsUnverified() {
        let v = GreatLoopVerifier.verify(trajectory: [edit()], canRunCommands: true,
                                         changedFiles: ["Sources/Foo.swift"], diff: "")
        guard case .unverified = v else { return XCTFail("no build/test after an edit ⇒ unverified: \(v)") }
    }

    func testDeletingATestIsGamedEvenIfGreen() {
        // The diff removes a test AND a build "passed" — anti-Goodhart must still HARD-block.
        let diff = "diff --git a/Tests/FooTests.swift b/Tests/FooTests.swift\n-    func testBar() {\n"
        let v = GreatLoopVerifier.verify(trajectory: [edit(), test(true)], canRunCommands: true,
                                         changedFiles: ["Tests/FooTests.swift"], diff: diff)
        guard case .gamed(let findings) = v else { return XCTFail("deleting a test must be blocked: \(v)") }
        XCTAssertTrue(findings.contains { $0.contains("test_deleted") })
    }

    func testAddingXCTSkipIsGamed() {
        let diff = "diff --git a/Tests/FooTests.swift b/Tests/FooTests.swift\n+        throw XCTSkip(\"later\")\n"
        let v = GreatLoopVerifier.verify(trajectory: [edit(), test(true)], canRunCommands: true,
                                         changedFiles: ["Tests/FooTests.swift"], diff: diff)
        guard case .gamed = v else { return XCTFail("adding XCTSkip must be blocked: \(v)") }
    }

    func testRunnerBypassIsGamed() {
        let diff = "diff --git a/test.sh b/test.sh\n+swift test || true\n"
        let v = GreatLoopVerifier.verify(trajectory: [edit(), test(true)], canRunCommands: true,
                                         changedFiles: ["test.sh"], diff: diff)
        guard case .gamed = v else { return XCTFail("a `|| true` runner bypass must be blocked: \(v)") }
    }

    func testShellOffReportsCodeChangeAsUnverified() {
        // No shell means there is no execution evidence. Preserve the change, but never label it verified.
        let v = GreatLoopVerifier.verify(trajectory: [edit()], canRunCommands: false,
                                         changedFiles: ["Sources/Foo.swift"], diff: "+ok")
        guard case .unverified(let why) = v else { return XCTFail("shell-off source change must be unverified") }
        XCTAssertTrue(why.contains("shell/build execution is unavailable"), why)
    }
}
