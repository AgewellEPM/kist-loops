import XCTest
import AgentCore
@testable import Kist

final class CoboloLoopTests: XCTestCase {
    func testCoboloAndLegacyAliasParseWithRequiredContract() {
        for flag in ["--cobolo", "--cobol-loop"] {
            let opts = KistOptions.parse([flag, "--cobol-target", "src/payroll.cbl",
                                          "--cobol-expect", "ALICE GROSS 712.50", "build payroll"])
            XCTAssertTrue(opts.cobolo)
            XCTAssertEqual(opts.cobolTarget, "src/payroll.cbl")
            XCTAssertEqual(opts.cobolExpect, "ALICE GROSS 712.50")
            XCTAssertTrue(opts.optionErrors.isEmpty)
        }
    }

    func testCoboloRequiresTargetAndExpectationAndRejectsRouteConflicts() {
        XCTAssertFalse(KistOptions.parse(["--cobolo", "goal"]).optionErrors.isEmpty)
        for conflict in ["--mission", "--fleet", "--plan-execute", "--loop"] {
            let opts = KistOptions.parse(["--cobolo", "--cobol-target", "x.cbl",
                                          "--cobol-expect", "OK", conflict, "goal"])
            XCTAssertFalse(opts.optionErrors.isEmpty, conflict)
        }
    }

    func testKistOptionsTestsFlagShapedTargetOperandIsNotConsumedAndConflictStillParses() {
        let opts = KistOptions.parse(["--cobolo", "--cobol-target", "--mission",
                                      "--cobol-expect", "OK", "goal"])
        XCTAssertNil(opts.cobolTarget)
        XCTAssertTrue(opts.mission)
        XCTAssertTrue(opts.optionErrors.contains { $0.contains("--cobol-target requires") })
        XCTAssertTrue(opts.optionErrors.contains { $0.contains("conflicts with") })
    }

    func testKistOptionsTestsFlagShapedExpectationOperandIsNotConsumedAndConflictStillParses() {
        let opts = KistOptions.parse(["--cobolo", "--cobol-target", "x.cbl",
                                      "--cobol-expect", "--fleet", "goal"])
        XCTAssertNil(opts.cobolExpect)
        XCTAssertTrue(opts.fleet)
        XCTAssertTrue(opts.optionErrors.contains { $0.contains("--cobol-expect requires") })
        XCTAssertTrue(opts.optionErrors.contains { $0.contains("conflicts with") })
    }

    func testCoboloAdapterPreservesExistingRoutes() {
        XCTAssertEqual(KistRunner.BuilderCompatibilityAdapter.headless.compatibleRoute, .direct)
        XCTAssertEqual(KistRunner.BuilderCompatibilityAdapter.planExecute.compatibleRoute, .planned)
        XCTAssertEqual(KistRunner.BuilderCompatibilityAdapter.fleet.compatibleRoute, .fleet)
        XCTAssertEqual(KistRunner.BuilderCompatibilityAdapter.greatLoop.compatibleRoute, .highAssurance)
        XCTAssertEqual(KistRunner.BuilderCompatibilityAdapter.mission.compatibleRoute, .highAssurance)
        XCTAssertEqual(KistRunner.BuilderCompatibilityAdapter.cobolo.compatibleRoute, .highAssurance)
    }

    func testTargetValidationRejectsEscapesAndWrongExtensions() {
        XCTAssertNil(KistRunner.coboloTargetValidationIssue("src/program.cbl"))
        XCTAssertNotNil(KistRunner.coboloTargetValidationIssue("../program.cbl"))
        XCTAssertNotNil(KistRunner.coboloTargetValidationIssue("/tmp/program.cbl"))
        XCTAssertNotNil(KistRunner.coboloTargetValidationIssue(".kist/program.cbl"))
        XCTAssertNotNil(KistRunner.coboloTargetValidationIssue("src/program.swift"))
    }

    func testOnlyLoopbackOllamaHostIsAccepted() throws {
        XCTAssertEqual(try KistRunner.coboloLocalOllamaEndpoint(environment: [:]),
                       "http://127.0.0.1:11434")
        XCTAssertEqual(try KistRunner.coboloLocalOllamaEndpoint(
            environment: ["OLLAMA_HOST": "http://127.0.0.1:11434"]),
                       "http://127.0.0.1:11434")
        for host in ["http://localhost:11434", "http://192.168.1.4:11434", "http://10.0.0.2:11434",
                     "http://localhost.evil.test:11434", "https://127.0.0.1:11434",
                     "http://user@127.0.0.1:11434"] {
            XCTAssertThrowsError(try KistRunner.coboloLocalOllamaEndpoint(
                environment: ["OLLAMA_HOST": host]), host)
        }
    }

    func testToolProseCannotReplaceTypedSandboxEvidence() {
        XCTAssertThrowsError(try KistRunner.coboloCommandReceipt(
            success: true, output: "compiled, ran, output matched", metadata: [:], stage: "verify",
            executable: "cobc", arguments: []))
    }

    func testExpectedStdoutFollowedByNonzeroExitIsRejected() {
        var metadata = validMetadata(stdout: "EXPECTED\n")
        metadata["exit_code"] = "7"
        metadata["verification_eligible"] = "false"
        XCTAssertThrowsError(try KistRunner.coboloCommandReceipt(
            success: true, metadata: metadata, stage: "run",
            executable: "./program", arguments: [], expectedStdout: "EXPECTED"))
    }

    func testUnsandboxedOrTruncatedEvidenceIsRejected() {
        var unsandboxed = validMetadata(stdout: "OK")
        unsandboxed["sandboxed"] = "false"
        XCTAssertThrowsError(try KistRunner.coboloCommandReceipt(
            success: true, metadata: unsandboxed, stage: "run",
            executable: "./program", arguments: [], expectedStdout: "OK"))
        var truncated = validMetadata(stdout: "OK")
        truncated["output_truncated"] = "true"
        XCTAssertThrowsError(try KistRunner.coboloCommandReceipt(
            success: true, metadata: truncated, stage: "run",
            executable: "./program", arguments: [], expectedStdout: "OK"))
    }

    func testSameModelAcrossProviderAliasesConflicts() {
        XCTAssertTrue(KistRunner.coboloIdentitiesConflict("deepseek:reasoner", "deepseek:reasoner"))
        XCTAssertTrue(KistRunner.coboloIdentitiesConflict("vendor-a:reasoner", "vendor-b:reasoner"))
        XCTAssertFalse(KistRunner.coboloIdentitiesConflict("vendor-a:model-a", "vendor-b:model-b"))
    }

    private func validMetadata(stdout: String) -> [String: String] {
        ["sandboxed": "true", "timed_out": "false", "was_signalled": "false",
         "stdout_truncated": "false", "stderr_truncated": "false", "output_truncated": "false",
         "verification_eligible": "true", "exit_code": "0", "stdout": stdout, "stderr": ""]
    }
}
