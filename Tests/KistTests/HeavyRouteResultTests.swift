import XCTest
@testable import Kist

final class HeavyRouteResultTests: XCTestCase {
    func testInterruptionOverridesZeroExitCode() {
        let result = HeavyRouteResult(
            exitCode: 0,
            interruption: .interject,
            review: .notApplicable("no external review was requested"),
            verification: .unavailable("execution was interrupted"))

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.finalText, "interrupted — heavy route stopped before completion")
        XCTAssertNil(result.verification.proofSuccess)
    }

    func testVerifiedFailureStaysDistinctFromUnavailableVerification() {
        let failed = HeavyRouteResult(
            exitCode: 1,
            interruption: nil,
            review: .handledInternally("the route owns its critic stage"),
            verification: .failed("the route's deterministic gate did not pass"))
        let advisory = HeavyRouteResult(
            exitCode: 0,
            interruption: nil,
            review: .handledInternally("the council synthesized its own review"),
            verification: .unavailable("this advisory route has no deterministic oracle"))

        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.verification.proofSuccess, false)
        XCTAssertTrue(advisory.succeeded)
        XCTAssertNil(advisory.verification.proofSuccess)
        XCTAssertTrue(advisory.verification.proofText.hasPrefix("unavailable"))
    }

    func testHeavyRouteProofHasOneTypedDecisionAndOneCanonicalFinal() {
        let result = HeavyRouteResult(
            exitCode: 0,
            interruption: nil,
            review: .handledInternally("the council owns critique"),
            verification: .unavailable("advisory route has no deterministic oracle"))

        let entries = [HeavyRouteProof.routeEntry(intent: .review, mode: .inline,
                                                  execution: "council")]
            + HeavyRouteProof.completionEntries(result: result, intent: .review,
                                                mode: .inline, execution: "council")

        XCTAssertEqual(entries.map(\.kind), [.routeSelected, .reviewAssessment,
                                              .verificationAssessment, .turnFinalized])
        XCTAssertEqual(entries.filter { $0.kind == .routeSelected }.count, 1)
        XCTAssertEqual(entries.filter { $0.kind == .turnFinalized }.count, 1)
        XCTAssertNil(entries[2].success, "unavailable verification must never be recorded as passing")
        XCTAssertEqual(entries[3].success, true, "the route itself completed even though no oracle exists")
    }

    func testHeavyRouteProofFinalizesInterruptedRunAsFailure() {
        let result = HeavyRouteResult(
            exitCode: 0,
            interruption: .cancel,
            review: .notApplicable("the route was cancelled"),
            verification: .unavailable("the route was cancelled"))

        let entries = HeavyRouteProof.completionEntries(result: result, intent: .fleet,
                                                        mode: .fleet, execution: "fleet(3)")

        XCTAssertEqual(entries.last?.kind, .turnFinalized)
        XCTAssertEqual(entries.last?.success, false)
        XCTAssertTrue(entries.last?.text.contains("cancelled") == true)
    }

    func testMutationRouteCannotFinalizeSuccessWhenVerificationIsUnavailable() {
        let result = HeavyRouteResult(
            exitCode: 0,
            interruption: nil,
            review: .handledInternally("review finished"),
            verification: .unavailable("no deterministic oracle ran"))

        let entries = HeavyRouteProof.completionEntries(result: result, intent: .build,
                                                        mode: .planExecute, execution: "plan-execute")
        XCTAssertEqual(entries.last?.kind, .turnFinalized)
        XCTAssertEqual(entries.last?.success, false)
    }

    func testExistingREPLHeavyRoutesReturnAndRecordTheirActualResults() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repl = try String(contentsOf: root.appendingPathComponent("Sources/Kist/KistREPL.swift"),
                              encoding: .utf8)
        let runner = try String(contentsOf: root.appendingPathComponent("Sources/Kist/KistRunner.swift"),
                                encoding: .utf8)

        XCTAssertTrue(repl.contains("async -> HeavyRouteResult"),
                      "heavy routes must return evidence instead of Void")
        XCTAssertTrue(repl.contains("HeavyRouteProof.routeEntry"))
        XCTAssertTrue(repl.contains("HeavyRouteProof.completionEntries"))
        XCTAssertFalse(repl.contains("handed off to \\(execution)"),
                       "accepted auto-routing must not synthesize an unknown handoff result")
        XCTAssertTrue(runner.contains("let exitCode = await InterruptibleTurn.run"),
                      "the runner must carry its existing exit code back to the REPL")
        XCTAssertTrue(runner.contains("interrupted.value = reason"),
                      "ESC must be distinguished from an ordinary route failure")
    }
}
