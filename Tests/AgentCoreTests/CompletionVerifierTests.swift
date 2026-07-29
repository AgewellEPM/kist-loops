import XCTest
@testable import AgentCore

/// Verify-before-done kills "it said done but wasn't": a code change with no PASSING build/test after it
/// cannot be accepted as complete — and (teeth) a trivial command like `ls` does not count as a build/test.
final class CompletionVerifierTests: XCTestCase {
    let v = CompletionVerifier()
    func rec(_ tool: String, _ ok: Bool = true) -> ActionRecord { ActionRecord(tool: tool, argsFingerprint: "x", success: ok) }
    /// A run_command whose fingerprint carries the actual command (as the trajectory records it).
    func cmd(_ command: String, _ ok: Bool = true) -> ActionRecord {
        ActionRecord(tool: "run_command", argsFingerprint: "command=\(command)", success: ok)
    }

    func testNoCodeChangeIsAccepted() {
        XCTAssertTrue(v.check(trajectory: [rec("read_file"), rec("search_code")], canRunCommands: true).isAccept)
    }

    func testEditThenPassingBuildIsAccepted() {
        let t = [rec("read_file"), rec("edit_file"), cmd("swift build")]
        XCTAssertTrue(v.check(trajectory: t, canRunCommands: true).isAccept)
    }

    func testEditWithNoVerificationIsRejected() {
        let t = [rec("read_file"), rec("edit_file")]
        if case .needsVerification = v.check(trajectory: t, canRunCommands: true) {} else { XCTFail("must require verification") }
    }

    /// R7: a mutation whose PATH fingerprint carries a file extension.
    private func edit(_ path: String) -> ActionRecord {
        ActionRecord(tool: "edit_file", argsFingerprint: "content=x&path=\(path)", success: true)
    }

    // R7 over-block fix: editing a DOC/CONFIG file needs no build/test — demanding one was the review-
    // caught regression that hard-failed legitimate "edit the README / tweak the YAML" turns.
    func testDocAndConfigOnlyEditsNeedNoBuild() {
        XCTAssertTrue(v.check(trajectory: [edit("README.md")], canRunCommands: true).isAccept)
        XCTAssertTrue(v.check(trajectory: [edit("docs/guide.rst")], canRunCommands: true).isAccept)
        XCTAssertTrue(v.check(trajectory: [edit("config/app.yaml")], canRunCommands: true).isAccept)
        XCTAssertTrue(v.check(trajectory: [edit("deps.lock")], canRunCommands: true).isAccept)
    }

    // …but a SOURCE-code edit still requires a passing build/test (symbolic-first intact).
    func testSourceEditStillRequiresBuild() {
        for src in ["Sources/App/Main.swift", "src/index.ts", "lib/thing.py", "pkg/main.go"] {
            guard case .needsVerification = v.check(trajectory: [edit(src)], canRunCommands: true) else {
                return XCTFail("a source edit (\(src)) must still require a build/test")
            }
        }
    }

    // A doc edit AND a source edit together ⇒ the source edit still forces verification.
    func testMixedDocAndSourceStillRequiresBuild() {
        let t = [edit("README.md"), edit("Sources/App/Main.swift")]
        if case .needsVerification = v.check(trajectory: t, canRunCommands: true) {} else {
            XCTFail("a source edit alongside a doc edit must still require a build")
        }
    }

    func testEditThenFailedBuildIsRejected() {
        let t = [rec("edit_file"), cmd("swift build", false)]
        if case .needsVerification = v.check(trajectory: t, canRunCommands: true) {} else { XCTFail("failed build ≠ done") }
    }

    // TEETH: a passing but TRIVIAL command (ls/echo) must NOT count as verification.
    func testTrivialSuccessfulCommandDoesNotVerify() {
        let t = [rec("edit_file"), cmd("ls -la")]
        guard case .needsVerification(let why) = v.check(trajectory: t, canRunCommands: true) else {
            return XCTFail("`ls` passing proves nothing — must still require a real build/test")
        }
        XCTAssertTrue(why.contains("wasn't a build/test"), "the steer names the real problem: \(why)")
    }

    func testBuildBeforeLastEditDoesNotCount() {
        let t = [rec("edit_file"), cmd("swift test"), rec("edit_file")]
        if case .needsVerification = v.check(trajectory: t, canRunCommands: true) {} else { XCTFail("must re-verify after the new edit") }
    }

    func testShellOffCannotBeBlocked() {
        XCTAssertTrue(v.check(trajectory: [rec("edit_file")], canRunCommands: false).isAccept)
    }

    func testWriteAndPatchAlsoCountAsMutations() {
        XCTAssertFalse(v.check(trajectory: [rec("write_file")], canRunCommands: true).isAccept)
        XCTAssertFalse(v.check(trajectory: [rec("apply_patch")], canRunCommands: true).isAccept)
    }

    // MARK: CommandClassifier — what actually counts as a build/test/lint

    func testClassifierAcceptsRealBuildTestCommands() {
        for c in ["swift build", "swift test", "npm test", "pytest -q", "cargo test", "go test ./...",
                  "make", "xcodebuild -scheme X test", "tsc --noEmit", "eslint .", "cd sub && swift test"] {
            XCTAssertTrue(CommandClassifier.isBuildOrTest("command=\(c)"), "\(c) should verify")
        }
    }

    func testClassifierRejectsTrivialCommands() {
        for c in ["ls -la", "echo done", "cat file.txt", "pwd", "git status", "mkdir foo", "which swift"] {
            XCTAssertFalse(CommandClassifier.isBuildOrTest("command=\(c)"), "\(c) must NOT count as verification")
        }
    }

    // The STRUCTURED run_command fingerprint (executable+args, as the safe-promotion + cwd param steer
    // models toward, e.g. building a package in a subdir). The verb and its args are SEPARATED in the
    // fingerprint — a real dogfood bug: a genuine `swift test` in a subdir was rejected → the loop never
    // completed. These pin that the structured form is recognized exactly like the raw form.
    func testClassifierAcceptsStructuredBuildTestFingerprints() {
        let fps = [
            #"args=["test"]&cwd=MathKit&executable=swift"#,      // swift test in a subdir
            #"args=["build"]&executable=swift"#,                  // swift build
            #"args=["test","./..."]&executable=go"#,             // go test ./...
            #"args=["--noEmit"]&executable=tsc"#,                 // tsc (bare-verb after rebuild)
        ]
        for fp in fps {
            XCTAssertTrue(CommandClassifier.isBuildOrTest(fp), "structured build/test must verify: \(fp)")
        }
    }

    func testClassifierRejectsStructuredTrivialFingerprints() {
        for fp in [#"args=["swift"]&executable=which"#, #"args=["-la"]&executable=ls"#, #"executable=pwd"#] {
            XCTAssertFalse(CommandClassifier.isBuildOrTest(fp), "structured trivial must NOT verify: \(fp)")
        }
    }
}
