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

    func testPromisedMutationRejectsZeroToolAndReadOnlyNoOps() {
        for trajectory in [[], [rec("read_file"), rec("search_code")]] {
            guard case .needsVerification(let reason) = v.check(
                trajectory: trajectory, canRunCommands: true, expectedOutcome: .mutation
            ) else { return XCTFail("a build/fleet contract cannot complete without a mutation") }
            XCTAssertTrue(reason.contains("no successful mutation"), reason)
            XCTAssertTrue(CompletionVerifier.steering(reason: reason).contains("Perform the requested workspace change"),
                          "a no-op must be steered to do the promised work, not merely run tests")
        }
    }

    func testPromisedResearchRequiresObservedEvidence() {
        guard case .needsVerification(let reason) = v.check(
            trajectory: [], canRunCommands: true, expectedOutcome: .evidence, taskIntent: .research
        ) else { return XCTFail("research cannot finish without gathering evidence") }
        XCTAssertTrue(reason.contains("evidence"), reason)
        let steering = CompletionVerifier.steering(reason: reason)
        XCTAssertTrue(steering.contains("Gather concrete evidence"), steering)
        XCTAssertFalse(steering.contains("Run the project's REAL build"), steering)

        let fetched = ActionRecord(
            tool: "fetch_url", argsFingerprint: "url=https://example.com", success: true,
            effectObservation: ToolEffectObservation(progress: .evidence))
        XCTAssertTrue(v.check(trajectory: [fetched], canRunCommands: true,
                              expectedOutcome: .evidence, taskIntent: .research).isAccept)
        let searched = ActionRecord(
            tool: "jeeves_research", argsFingerprint: "query=facts", success: true,
            effectObservation: ToolEffectObservation(progress: .research))
        XCTAssertTrue(v.check(trajectory: [searched], canRunCommands: true,
                              expectedOutcome: .evidence, taskIntent: .research).isAccept)
        let symbolic = ActionRecord(
            tool: "jeeves-floor__symbolic_query", argsFingerprint: "query=facts", success: true,
            effectObservation: ToolEffectCatalog.observe(
                tool: "jeeves-floor__symbolic_query", arguments: ["query": "facts"]))
        XCTAssertEqual(symbolic.observedEffects.progress, .evidence)
        XCTAssertTrue(v.check(trajectory: [symbolic], canRunCommands: true,
                              expectedOutcome: .evidence, taskIntent: .research).isAccept)
        let failedFetch = ActionRecord(
            tool: "fetch_url", argsFingerprint: "url=https://example.com", success: false,
            effectObservation: ToolEffectObservation(progress: .evidence))
        XCTAssertFalse(v.check(trajectory: [failedFetch], canRunCommands: true,
                               expectedOutcome: .evidence, taskIntent: .research).isAccept)
    }

    func testPromisedDesktopActionRequiresSuccessfulExternalStateChange() {
        XCTAssertFalse(v.check(trajectory: [], canRunCommands: true,
                               expectedOutcome: .externalAction, taskIntent: .desktop).isAccept)
        let inspection = ActionRecord(
            tool: "desktop_control", argsFingerprint: "action=screenshot", success: true,
            effectObservation: ToolEffectObservation.none)
        guard case .needsVerification(let reason) = v.check(
            trajectory: [inspection], canRunCommands: true,
            expectedOutcome: .externalAction, taskIntent: .desktop
        ) else { return XCTFail("inspection alone cannot fulfill an external action") }
        let steering = CompletionVerifier.steering(reason: reason)
        XCTAssertTrue(steering.contains("Perform the requested external action"), steering)
        XCTAssertFalse(steering.contains("Run the project's REAL build"), steering)
        let opened = ActionRecord(
            tool: "computer_control", argsFingerprint: "action=open_app", success: true,
            effectObservation: ToolEffectObservation(progress: .externalState))
        XCTAssertTrue(v.check(trajectory: [opened], canRunCommands: true,
                              expectedOutcome: .externalAction, taskIntent: .desktop).isAccept)
        let failedOpen = ActionRecord(
            tool: "computer_control", argsFingerprint: "action=open_app", success: false,
            effectObservation: ToolEffectObservation(progress: .externalState))
        XCTAssertFalse(v.check(trajectory: [failedOpen], canRunCommands: true,
                               expectedOutcome: .externalAction, taskIntent: .desktop).isAccept)
    }

    func testDesktopToolEffectsOnlyCreditConfirmedActuation() {
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "computer_control", arguments: ["action": "open_app"]
        ).progress, .externalState)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "computer_control", arguments: ["action": "clean_desktop", "dry_run": true],
            outcomeMetadata: ["count": "3", "dry_run": "true"]
        ).progress, .none)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "desktop_control", arguments: ["action": "screenshot"]
        ).progress, .none)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "desktop_control", arguments: ["action": "click"]
        ).progress, .externalState)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "ax_press", arguments: [:], outcomeMetadata: ["pressed": "false"]
        ).progress, .none)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "tap", arguments: [:], outcomeMetadata: ["found": "1"]
        ).progress, .externalState)
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
        ActionRecord(
            tool: "edit_file", argsFingerprint: "content=x&path=\(path)", success: true,
            effectObservation: ToolEffectCatalog.observe(
                tool: "edit_file", arguments: ["path": path], outcomeMetadata: ["changed": "true"])
        )
    }

    func testPromisedMutationAcceptsSuccessfulNonSourceMutationWithoutBuild() {
        XCTAssertTrue(v.check(trajectory: [edit("README.md")], canRunCommands: true,
                              expectedOutcome: .mutation).isAccept)
    }

    func testFleetDelegationFulfillsFleetProgressWithoutBecomingMutationVerification() {
        let delegated = ActionRecord(
            tool: "spawn_agent", argsFingerprint: "task=worker", success: true,
            effectObservation: ToolEffectObservation(progress: .delegation)
        )
        XCTAssertTrue(v.check(trajectory: [delegated], canRunCommands: true,
                              expectedOutcome: .mutation, taskIntent: .fleet).isAccept)
        XCTAssertFalse(v.check(trajectory: [delegated], canRunCommands: true,
                               expectedOutcome: .mutation, taskIntent: .build).isAccept)
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

    func testShellUnavailableIsDisclosedAsUnverified() {
        guard case .needsVerification(let why) = v.check(
            trajectory: [rec("edit_file")], canRunCommands: false
        ) else { return XCTFail("absence of a shell is not verification") }
        XCTAssertTrue(why.contains("shell/build execution is unavailable"), why)
        XCTAssertTrue(why.contains("unverified"), why)
    }

    func testWriteAndPatchAlsoCountAsMutations() {
        XCTAssertFalse(v.check(trajectory: [rec("write_file")], canRunCommands: true).isAccept)
        XCTAssertFalse(v.check(trajectory: [rec("apply_patch")], canRunCommands: true).isAccept)
    }

    func testFailedMutationCannotBeLaunderedByPassingBuild() {
        let trajectory = [rec("edit_file", false), cmd("swift test")]
        guard case .needsVerification(let why) = v.check(trajectory: trajectory, canRunCommands: true) else {
            return XCTFail("a failed mutation is incomplete even if a later test passes")
        }
        XCTAssertTrue(why.contains("mutation failed"), why)
    }

    func testLaterSuccessfulMutationAndTestRecoverFromEarlierFailure() {
        let trajectory = [rec("edit_file", false), rec("edit_file"), cmd("swift test")]
        XCTAssertTrue(v.check(trajectory: trajectory, canRunCommands: true).isAccept)
    }

    func testFailedNonSourceMutationIsStillIncomplete() {
        let failedReadme = ActionRecord(
            tool: "edit_file", argsFingerprint: "path=README.md", success: false
        )
        XCTAssertFalse(v.check(trajectory: [failedReadme], canRunCommands: true).isAccept)
    }

    func testExplicitEffectObservationSupportsFutureToolsWithoutVerifierNameChanges() {
        let mutation = ActionRecord(
            tool: "future_refactor_tool", argsFingerprint: "opaque", success: true,
            effectObservation: ToolEffectObservation(mutation: .source)
        )
        let verification = ActionRecord(
            tool: "future_ci_tool", argsFingerprint: "opaque", success: true,
            effectObservation: ToolEffectObservation(verification: .buildOrTest)
        )
        XCTAssertTrue(v.check(trajectory: [mutation, verification], canRunCommands: true).isAccept)
    }

    func testPathNamedVerifierCannotProveAConfirmedSourceMutation() {
        let spoofedCommand = "/repo/swift test"
        let spoofedEffect = ToolEffectCatalog.observe(
            tool: "run_command", arguments: ["command": spoofedCommand]
        )
        XCTAssertEqual(spoofedEffect.verification, .nonVerifyingCommand)

        let spoofedSuccess = ActionRecord(
            tool: "run_command", argsFingerprint: "command=\(spoofedCommand)", success: true,
            effectObservation: spoofedEffect
        )
        guard case .needsVerification(let reason) = v.check(
            trajectory: [edit("Sources/App.swift"), spoofedSuccess], canRunCommands: true
        ) else {
            return XCTFail("an arbitrary path named `swift` cannot verify a confirmed source mutation")
        }
        XCTAssertTrue(reason.contains("build/test"), reason)
    }

    // MARK: CommandClassifier — what actually counts as a build/test/lint

    func testClassifierAcceptsRealBuildTestCommands() {
        for c in ["swift build", "swift test", "npm test", "pytest -q", "cargo test", "go test ./...",
                  "make", "xcodebuild -scheme X test", "tsc --noEmit", "eslint .", "cd sub && swift test"] {
            XCTAssertTrue(CommandClassifier.isBuildOrTest("command=\(c)"), "\(c) should verify")
        }
    }

    // 2026-08-04 dogfood: the EXACT plan-execute trajectory (write .asm → nasm build → strings) that
    // kept reporting "unverified" even though the .COM was correct. Built the way verifyTrajectory does:
    // explicit effectObservation from ToolEffectCatalog.observe on the real args.
    func testDOSBuildTrajectoryVerifiesEndToEnd() {
        let writeAsm = ActionRecord(
            tool: "write_file", argsFingerprint: "path=hello.asm", success: true,
            effectObservation: ToolEffectCatalog.observe(
                tool: "write_file", arguments: ["path": "hello.asm", "content": "org 100h"],
                outcomeMetadata: ["changed": "true"]))
        XCTAssertTrue(writeAsm.observedEffects.requiresBuildVerification,
                      "writing a .asm source must be a build-requiring mutation (else the whole gate is moot)")
        let nasm = ActionRecord(
            tool: "run_command", argsFingerprint: #"args=["-f","bin","hello.asm","-o","hello.com"]&executable=nasm"#,
            success: true,
            effectObservation: ToolEffectCatalog.observe(
                tool: "run_command", arguments: ["executable": "nasm", "args": ["-f", "bin", "hello.asm", "-o", "hello.com"]],
                outcomeMetadata: [:]))
        XCTAssertEqual(nasm.observedEffects.verification, .buildOrTest,
                       "the recorded nasm effect must be buildOrTest")
        let strings = ActionRecord(
            tool: "run_command", argsFingerprint: "command=strings hello.com", success: true,
            effectObservation: ToolEffectCatalog.observe(
                tool: "run_command", arguments: ["command": "strings hello.com"], outcomeMetadata: [:]))
        XCTAssertEqual(strings.observedEffects.mutation, .none,
                       "`strings` is read-only — it must not be misread as the 'last edit'")
        let outcome = v.check(trajectory: [writeAsm, nasm, strings],
                              canRunCommands: true, expectedOutcome: .mutation, taskIntent: .build)
        XCTAssertTrue(outcome.isAccept, "write→nasm→strings must verify; got: \(outcome)")
    }

    // 2026-08-04 dogfood: assembling a DOS .COM IS the build; `nasm hello.asm` must count so a correct
    // artifact isn't reported "unverified — ran no build/test."
    func testClassifierAcceptsAssemblersBuildingASource() {
        for c in ["nasm -f bin hello.asm -o hello.com", "yasm -f elf32 boot.s", "as boot.s -o boot.o"] {
            XCTAssertTrue(CommandClassifier.isBuildOrTest("command=\(c)"), "\(c) should verify (assembling a source)")
        }
        // A bare version/help query assembles nothing → not a build.
        for c in ["nasm -v", "nasm --version", "as --help"] {
            XCTAssertFalse(CommandClassifier.isBuildOrTest("command=\(c)"), "\(c) must NOT count (no source input)")
        }
        // STRUCTURED form (executable+args) — the shape plan-execute actually records.
        XCTAssertTrue(CommandClassifier.isBuildOrTest(#"args=["-f","bin","hello.asm","-o","hello.com"]&executable=nasm"#),
                      "structured nasm assemble must verify")
        // And via observe(arguments:) directly (the live plan-execute path).
        XCTAssertTrue(CommandClassifier.observe(arguments: ["executable": "nasm", "args": ["-f", "bin", "hello.asm", "-o", "hello.com"]]).verification == .buildOrTest,
                      "observe(arguments:) must classify structured nasm as build")
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
