import XCTest
@testable import AgentCore

/// Phase 1 — structured, verification-gated lessons from a finished cycle.
final class CycleReflectionTests: XCTestCase {

    func testDoneCycleYieldsProvenLesson() {
        let l = CycleReflection.lesson(goal: "build a JSON parser", done: true, verdictReason: "verified",
                                       reviewGist: nil, summary: "wrote parser + tests, swift test green",
                                       failureRate: 0, at: 1)
        XCTAssertEqual(l.kind, .proven)
        XCTAssertTrue(l.text.contains("SOLVED and verified"))
        XCTAssertTrue(l.text.contains("parser"))
    }

    func testRejectedDoneYieldsObstacleNamingTheRejection() {
        let l = CycleReflection.lesson(goal: "add a subtract function", done: false,
                                       verdictReason: "verifier-gaming blocked — test_deleted", reviewGist: nil,
                                       summary: "claimed done", failureRate: 0, at: 1)
        XCTAssertEqual(l.kind, .obstacle)
        XCTAssertTrue(l.text.contains("REJECTED"))
        XCTAssertTrue(l.text.contains("test_deleted"))
    }

    func testReviewFlaggedYieldsObstacle() {
        let l = CycleReflection.lesson(goal: "wire the API", done: false, verdictReason: "verified",
                                       reviewGist: "the error path is unhandled", summary: "x", failureRate: 0.1, at: 1)
        XCTAssertEqual(l.kind, .obstacle)
        XCTAssertTrue(l.text.contains("team review"))
        XCTAssertTrue(l.text.contains("error path"))
    }

    func testHighFailureRateYieldsObstacle() {
        let l = CycleReflection.lesson(goal: "fix the build", done: false, verdictReason: "verified",
                                       reviewGist: nil, summary: "x", failureRate: 0.7, at: 1)
        XCTAssertEqual(l.kind, .obstacle)
        XCTAssertTrue(l.text.contains("70%"))
    }

    func testKeywordsDropStopwordsAndShortTokens() {
        let kw = CycleReflection.keywords(from: "build and integrate the authentication service for the API")
        XCTAssertTrue(kw.contains("build"))
        XCTAssertTrue(kw.contains("authentication"))
        XCTAssertFalse(kw.contains("the"))
        XCTAssertFalse(kw.contains("and"))
        XCTAssertLessThanOrEqual(kw.count, 8)
    }
}
