import XCTest
@testable import TagTeamKit

final class ReviewClassifierTests: XCTestCase {
    func testNoShipOrBlockerMeansMustFix() {
        XCTAssertEqual(ReviewClassifier.classify(reviewer: "x", text: "Looks good. SHIP").verdict, .ship)
        XCTAssertEqual(ReviewClassifier.classify(reviewer: "x", text: "Found issues. NO-SHIP").verdict, .mustFix)
        // A BLOCKER outweighs a stray "ship" word.
        let mixed = ReviewClassifier.classify(reviewer: "x", text: "BLOCKER: bad thing. otherwise ship it")
        XCTAssertEqual(mixed.verdict, .mustFix)
        XCTAssertEqual(mixed.blockers, 1)
    }

    func testUnclearWhenNoSignal() {
        XCTAssertEqual(ReviewClassifier.classify(reviewer: "x", text: "some notes, nothing conclusive").verdict, .unclear)
    }

    func testCountsSeverities() {
        let r = ReviewClassifier.classify(reviewer: "x", text: "BLOCKER a\nHIGH b\nHIGH c\nNO-SHIP")
        XCTAssertEqual(r.blockers, 1)
        XCTAssertEqual(r.highs, 2)
    }

    func testSingleObjectorForcesFix() {
        let results = [
            ReviewResult(reviewer: "a", text: "SHIP", verdict: .ship, blockers: 0, highs: 0),
            ReviewResult(reviewer: "b", text: "NO-SHIP", verdict: .mustFix, blockers: 1, highs: 0),
        ]
        let v = ReviewClassifier.summarize(results)
        XCTAssertTrue(v.mustFix, "one objector forces a fix")
        XCTAssertEqual(v.objectors, ["b"])
    }

    func testAllShipShips() {
        let results = [
            ReviewResult(reviewer: "a", text: "SHIP", verdict: .ship, blockers: 0, highs: 0),
            ReviewResult(reviewer: "b", text: "SHIP", verdict: .ship, blockers: 0, highs: 0),
        ]
        let v = ReviewClassifier.summarize(results)
        XCTAssertFalse(v.mustFix)
        XCTAssertEqual(v.verdict, .ship)
    }

    func testEmptyIsNotAShip() {
        XCTAssertEqual(ReviewClassifier.summarize([]).verdict, .unclear)
    }
}

/// End-to-end panel with stub reviewers — no network, proves parallel aggregation +
/// that a reviewer that throws degrades to "unclear" without sinking the panel.
final class ReviewPanelTests: XCTestCase {
    struct StubReviewer: Reviewer {
        let name: String
        let text: String
        func review(diff: String) async throws -> String { text }
    }
    struct ExplodingReviewer: Reviewer {
        let name = "boom"
        func review(diff: String) async throws -> String { throw ReviewerError.tool("boom") }
    }

    func testPanelAggregatesAndOneMustFixWins() async {
        let reviewers: [Reviewer] = [
            StubReviewer(name: "a", text: "all good, SHIP"),
            StubReviewer(name: "b", text: "BLOCKER: nope. NO-SHIP"),
        ]
        let (results, verdict) = await ReviewPanel().run(diff: "some diff", reviewers: reviewers)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(verdict.mustFix)
        XCTAssertEqual(verdict.objectors, ["b"])
    }

    func testFailingReviewerBecomesUnclearNotACrash() async {
        let (results, verdict) = await ReviewPanel().run(
            diff: "d", reviewers: [ExplodingReviewer(), StubReviewer(name: "ok", text: "SHIP")])
        XCTAssertEqual(results.count, 2)
        XCTAssertFalse(verdict.mustFix, "an errored reviewer is unclear, not a blocker")
        XCTAssertEqual(results.first { $0.reviewer == "boom" }?.verdict, .unclear)
    }
}

final class ReviewerFactoryTests: XCTestCase {
    func testKnownReviewers() {
        XCTAssertEqual(ReviewerFactory.make("deepseek")?.name, "deepseek")
        XCTAssertEqual(ReviewerFactory.make("codex")?.name, "codex")
        XCTAssertNil(ReviewerFactory.make("nope"))
    }
}
