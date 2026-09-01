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

    func testPlainFleetDelegationDoesNotFulfillMutationContract() {
        let delegated = ActionRecord(
            tool: "spawn_agent", argsFingerprint: "task=worker", success: true,
            effectObservation: ToolEffectObservation(progress: .delegation)
        )
        XCTAssertFalse(v.check(trajectory: [delegated], canRunCommands: true,
                               expectedOutcome: .mutation, taskIntent: .fleet).isAccept)
        XCTAssertFalse(v.check(trajectory: [delegated], canRunCommands: true,
                               expectedOutcome: .mutation, taskIntent: .build).isAccept)
        XCTAssertTrue(v.check(trajectory: [delegated], canRunCommands: true,
                              expectedOutcome: .delegation, taskIntent: .delegate).isAccept)

        let started = ActionRecord(
            tool: "spawn_agent", argsFingerprint: "background=true", success: true,
            effectObservation: ToolEffectObservation(progress: .delegationStarted))
        XCTAssertFalse(v.check(trajectory: [started], canRunCommands: true,
                               expectedOutcome: .delegation, taskIntent: .delegate).isAccept)
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

    // Doctrine pin (both failure gates): a later PASSING build/test deliberately does NOT excuse
    // a failed final edit on a build/mutation turn — a planted always-green test would launder a
    // failed change. Only external proof (external-action turns, delivered-before) excuses.
    func testFailedLastEditNotExcusedByLaterPassingBuildOnBuildTurns() {
        let wrote = ActionRecord(
            tool: "write_file", argsFingerprint: "path=Sources/App/main.swift", success: true,
            effectObservation: ToolEffectCatalog.observe(tool: "write_file",
                                                         arguments: ["path": "Sources/App/main.swift"]))
        let failedEdit = ActionRecord(
            tool: "edit_file", argsFingerprint: "path=Sources/App/main.swift", success: false,
            effectObservation: ToolEffectCatalog.observe(tool: "edit_file",
                                                         arguments: ["path": "Sources/App/main.swift"]))
        XCTAssertFalse(v.check(trajectory: [wrote, cmd("make"), failedEdit, cmd("make")],
                               canRunCommands: true).isAccept,
                       "a later green build must not launder a failed edit (planted-test attack)")
        XCTAssertFalse(v.check(trajectory: [wrote, cmd("make"), failedEdit, cmd("ls -la")],
                               canRunCommands: true).isAccept,
                       "a trivial later command cannot excuse a failed edit")
        XCTAssertFalse(v.check(trajectory: [wrote, cmd("make"), failedEdit],
                               canRunCommands: true).isAccept,
                       "a failed final edit with nothing after it still sinks the turn")
    }

    // perslis vm dos-exec --expect = a verification (dogfood 2026-08-06 round 3): it exits 0
    // only when OCR proves the expected text on the guest screen — that IS the test.
    func testPerslisDosExecWithExpectClassifiesAsVerification() {
        XCTAssertTrue(CommandClassifier.isBuildOrTest(
            #"perslis vm dos-exec --qmp /tmp/legacy-win98.sock --line C:\HELLO.BAT --capture out.png --expect HELLO"#))
        XCTAssertFalse(CommandClassifier.isBuildOrTest(
            #"perslis vm dos-exec --qmp /tmp/x.sock --line DIR --capture out.png"#),
            "without --expect it proves nothing")
        XCTAssertFalse(CommandClassifier.isBuildOrTest("perslis doctor"),
                       "other perslis verbs are not builds/tests")
    }

    // cobc = a build (dogfood 2026-08-06 — the nasm lesson, one compiler later): a clean
    // `cobc -x -o PAYROLL PAYROLL.CBL` after the final edit must satisfy verify-before-done.
    func testCobcCompileClassifiesAsBuild() {
        XCTAssertTrue(CommandClassifier.isBuildOrTest("cobc -x -o PAYROLL PAYROLL.CBL"))
        XCTAssertTrue(CommandClassifier.isBuildOrTest("cobc -x -o payroll_report payroll_report.cbl"))
        XCTAssertFalse(CommandClassifier.isBuildOrTest("cobc --version"), "introspection is not a build")
        XCTAssertFalse(CommandClassifier.isBuildOrTest("cobc"), "compiling nothing proves nothing")
        XCTAssertFalse(CommandClassifier.isBuildOrTest("cobc -x -o out /etc/passwd"),
                       "non-project non-source input is not a build")
    }

    func testClassifierRejectsStructuredTrivialFingerprints() {
        for fp in [#"args=["swift"]&executable=which"#, #"args=["-la"]&executable=ls"#, #"executable=pwd"#] {
            XCTAssertFalse(CommandClassifier.isBuildOrTest(fp), "structured trivial must NOT verify: \(fp)")
        }
    }

    // EXTERNAL-ACTION carve-out (dogfood 2026-08-06, win98 round): a script the agent wrote for
    // ANOTHER system (guest VM BAT/VBS) verifies by EXECUTING there — grounded vm-tool evidence —
    // not by a host build/test that cannot exist for it. kist had vm_type + vm_ocr proof of
    // "HELLO FROM KIST" on the VM screen and still failed on a build demand nothing could satisfy.
    func testExternalActionScriptVerifiesByExternalExecution() {
        let wroteScript = ActionRecord(
            tool: "write_file", argsFingerprint: "path=runhello.bat", success: true,
            effectObservation: ToolEffectCatalog.observe(tool: "write_file", arguments: ["path": "runhello.bat"]))
        let ranInGuest = ActionRecord(
            tool: "perslis__vm_type", argsFingerprint: "text=RUNHELLO.BAT", success: true,
            effectObservation: ToolEffectObservation(progress: .externalState))

        // Guest execution AFTER the write → accept: the external run IS the verification.
        XCTAssertTrue(v.check(trajectory: [wroteScript, ranInGuest], canRunCommands: true,
                              expectedOutcome: .externalAction, taskIntent: .desktop).isAccept)

        // External evidence only BEFORE the last write → still unverified (the final edit never ran).
        XCTAssertFalse(v.check(trajectory: [ranInGuest, wroteScript], canRunCommands: true,
                               expectedOutcome: .externalAction, taskIntent: .desktop).isAccept)

        // A non-external turn with the same shape keeps the strict build/test demand.
        guard case .needsVerification(let reason) = v.check(
            trajectory: [wroteScript, ranInGuest], canRunCommands: true
        ) else { return XCTFail("non-external turns must still demand a build/test after a source edit") }
        XCTAssertTrue(reason.contains("build"), reason)
    }

    // Gate-1 external-action exception (dogfood 2026-08-06, round 3): a FAILED maybe-mutating
    // command followed by successful external-state proof must not sink an external-action turn —
    // the DOS run had OCR proof of the app running AFTER a failed host command and still failed.
    func testFailedSpeculativeMutationOutrankedByLaterExternalProof() {
        let wroteScript = ActionRecord(
            tool: "write_file", argsFingerprint: "path=hello.bat", success: true,
            effectObservation: ToolEffectCatalog.observe(tool: "write_file", arguments: ["path": "hello.bat"]))
        let failedCommand = ActionRecord(
            tool: "run_command", argsFingerprint: "command=perslis vm dos-exec --qmp /tmp/x.sock",
            success: false,
            effectObservation: ToolEffectObservation(mutation: .unknownTarget, mutationEvidence: .mayMutate))
        let ranInGuest = ActionRecord(
            tool: "perslis__vm_type", argsFingerprint: "text=HELLO.BAT", success: true,
            effectObservation: ToolEffectObservation(progress: .externalState))

        // External proof AFTER the failed speculative step → accept.
        XCTAssertTrue(v.check(trajectory: [wroteScript, failedCommand, ranInGuest], canRunCommands: true,
                              expectedOutcome: .externalAction, taskIntent: .desktop).isAccept)

        // No later external proof → the failed last mutation still sinks the turn.
        XCTAssertFalse(v.check(trajectory: [wroteScript, ranInGuest, failedCommand], canRunCommands: true,
                               expectedOutcome: .externalAction, taskIntent: .desktop).isAccept)

        // Non-external turns keep the strict gate regardless of external evidence.
        XCTAssertFalse(v.check(trajectory: [wroteScript, failedCommand, ranInGuest],
                               canRunCommands: true).isAccept)
    }

    func testReceiptLedgerHelperMutationNamesAndInvalidatesEarlierChecks() {
        let source = ActionRecord(
            tool: "write_file", argsFingerprint: "path=Sources/ReceiptLedger/Parser.swift", success: true,
            effectObservation: ToolEffectObservation(mutation: .source))
        let tests = ActionRecord(
            tool: "run_command", argsFingerprint: "command=swift test", success: true,
            effectObservation: CommandClassifier.observe("command=swift test"))
        let build = ActionRecord(
            tool: "run_command", argsFingerprint: "command=swift build", success: true,
            effectObservation: CommandClassifier.observe("command=swift build"))
        let validFixture = ActionRecord(
            tool: "run_command", argsFingerprint: "command=.build/debug/receipt-ledger --input valid.ndjson", success: true,
            effectObservation: ToolEffectObservation(verification: .nonVerifyingCommand))
        let expectedInvalidFixture = ActionRecord(
            tool: "run_command", argsFingerprint: "command=.build/debug/receipt-ledger --input negative.ndjson", success: false,
            failureDetail: "exit code 1\nline 1: negative amount rejected as expected",
            effectObservation: ToolEffectObservation(verification: .nonVerifyingCommand))
        let helper = ActionRecord(
            tool: "write_file", argsFingerprint: "path=stdin-helper.swift", success: true,
            effectObservation: ToolEffectObservation(mutation: .source))
        let helperRun = ActionRecord(
            tool: "run_command", argsFingerprint: "command=swift stdin-helper.swift", success: true,
            effectObservation: ToolEffectObservation(verification: .nonVerifyingCommand))
        let trajectory = [source, tests, build, validFixture, expectedInvalidFixture, helper, helperRun]

        let invalidated = v.invalidatedVerification(in: trajectory)
        XCTAssertEqual(invalidated?.invalidatingStep, 6)
        XCTAssertTrue(invalidated?.invalidatingMutation.contains("stdin-helper.swift") == true)
        XCTAssertTrue(invalidated?.lastPassedCheck.contains("swift build") == true)
        guard case .needsVerification(let reason) = v.check(
            trajectory: trajectory, canRunCommands: true,
            expectedOutcome: .mutation, taskIntent: .build) else {
            return XCTFail("post-proof helper mutation must invalidate prior checks")
        }
        XCTAssertTrue(reason.contains("stdin-helper.swift"), reason)
        XCTAssertTrue(reason.contains("swift build"), reason)
        XCTAssertTrue(CompletionVerifier.steering(reason: reason).contains("exact last passed"))

        let freshBuild = ActionRecord(
            tool: "run_command", argsFingerprint: "command=swift build", success: true,
            effectObservation: CommandClassifier.observe("command=swift build"))
        XCTAssertTrue(v.check(trajectory: trajectory + [freshBuild], canRunCommands: true,
                              expectedOutcome: .mutation, taskIntent: .build).isAccept,
                      "fresh proof after the helper mutation must bind the final revision; expected fixture exit stays domain evidence")
    }
}
