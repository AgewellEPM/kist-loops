import XCTest
@testable import AgentCore

/// The real multi-model review stage: independent reviewers, parsed into fail-closed ReviewReports that the
/// flywheel consensus can act on. A silent/failed reviewer is NOT completed; a "NO BLOCKING ISSUES" is a
/// completed report with no blockers; explicit BLOCK lines become blocking findings.
final class CouncilReviewStageTests: XCTestCase {

    /// Route each reviewer id to a canned response (nil = the model errored / returned nothing).
    func stage(_ responses: [String: String?]) -> CouncilReviewStage {
        CouncilReviewStage(reviewers: Array(responses.keys).sorted()) { reviewer, _, _ in
            responses[reviewer] ?? nil
        }
    }

    func testCleanReviewersProduceCompletedNoBlockerReports() async {
        let s = stage(["a": "NO BLOCKING ISSUES", "b": "NO BLOCKING ISSUES"])
        let reports = await s.review(changeContext: "diff")
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(reports.allSatisfy { $0.completed })
        XCTAssertTrue(reports.allSatisfy { $0.blockingFindings.isEmpty })
        // and the flywheel would ACCEPT this (quorum met, no blockers)
        let v = FlywheelOrchestrator.consensus(build: BuildResult(branch: "b", ok: true),
                                               tests: TestResult(passed: true, summary: "ok"),
                                               reports: reports, minReviewers: 2)
        XCTAssertTrue(v.isAccept)
    }

    func testBlockLineBecomesBlockingFinding() async {
        let s = stage(["a": "BLOCK|critical|SQL injection in merge path",
                       "b": "NIT|low|rename this var"])
        let reports = await s.review(changeContext: "diff")
        let a = reports.first { $0.reviewer == "a" }!
        XCTAssertEqual(a.blockingFindings.count, 1)
        XCTAssertEqual(a.blockingFindings.first?.severity, .critical)
        let b = reports.first { $0.reviewer == "b" }!
        XCTAssertTrue(b.blockingFindings.isEmpty)   // a nit doesn't block
        // consensus rejects because of a's blocker
        let v = FlywheelOrchestrator.consensus(build: BuildResult(branch: "b", ok: true),
                                               tests: TestResult(passed: true, summary: "ok"),
                                               reports: reports, minReviewers: 1)
        XCTAssertFalse(v.isAccept)
    }

    func testFailedReviewerIsNotCompleted() async {
        let s = stage(["a": "NO BLOCKING ISSUES", "b": nil])   // b errored
        let reports = await s.review(changeContext: "diff")
        XCTAssertEqual(reports.first { $0.reviewer == "b" }?.completed, false)
        // with a 2-reviewer quorum this fails closed (b didn't complete)
        let v = FlywheelOrchestrator.consensus(build: BuildResult(branch: "b", ok: true),
                                               tests: TestResult(passed: true, summary: "ok"),
                                               reports: reports, minReviewers: 2)
        XCTAssertFalse(v.isAccept)
    }

    func testBareBlockDefaultsToHighAndParsesMultipleLines() async {
        let s = stage(["a": "BLOCK|nonsense|off-by-one\nNIT|low|spacing\nBLOCK|high|missing auth check"])
        let reports = await s.review(changeContext: "diff")
        let a = reports[0]
        XCTAssertTrue(a.completed)
        XCTAssertEqual(a.blockingFindings.count, 2)          // both BLOCK lines block; the NIT doesn't
        // an unknown severity token on a BLOCK falls back to .high (still blocks)
        XCTAssertTrue(a.blockingFindings.contains { $0.severity == .high })
    }

    func testGarbageLinesAreIgnoredButReviewStillCompletes() async {
        let s = stage(["a": "here is my review:\nlooks fine to me\n(no structured lines)"])
        let reports = await s.review(changeContext: "diff")
        XCTAssertTrue(reports[0].completed)                  // it responded
        XCTAssertTrue(reports[0].findings.isEmpty)           // nothing parseable ⇒ no findings
    }
}
