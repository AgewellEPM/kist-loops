import XCTest
@testable import Kist

/// R4 (2026-07-29): natural-language team assignment. Luke describes a team in plain words and the
/// parser maps it to lead (coder) + co (reviewer) — the AIs work together on one goal. Pure, so the
/// role mapping is pinned without a terminal.
final class TeamIntentTests: XCTestCase {

    func testEyesForBindsReviewerAndCoder() {
        // "gemini act as the eyes for deepseek to code this" → Gemini reviews, DeepSeek codes.
        let t = TeamIntent.parse("gemini act as the eyes for deepseek to code this into the terminal")
        XCTAssertEqual(t?.co, "gemini", "the eyes = the reviewer")
        XCTAssertEqual(t?.lead, "deepseek", "the one being watched = the coder")
        XCTAssertEqual(t?.goal, "code this into the terminal")
    }

    func testBeTheEyesPhrasing() {
        let t = TeamIntent.parse("let gemini be the eyes for deepseek")
        XCTAssertEqual(t?.co, "gemini")
        XCTAssertEqual(t?.lead, "deepseek")
    }

    func testCodeReviewVerbAssociation() {
        // "deepseek code the parser, mimo review after and fix it" → DeepSeek leads, MiMo reviews.
        let t = TeamIntent.parse("deepseek code the parser and mimo review after and fix it")
        XCTAssertEqual(t?.lead, "deepseek")
        XCTAssertEqual(t?.co, "mimo")
        // The real task must SURVIVE (the greedy strip pattern used to eat it → "after and fix it").
        XCTAssertTrue(t?.goal.contains("code the parser") == true, "goal must not be eaten: \(t?.goal ?? "nil")")
    }

    // The false-positive class the review caught: an ordinary coding request that NAMES a provider and
    // happens to use a code-verb + a review-word must NOT arm team mode (it silently rebound the model).
    // One assertion per shape (multi-site rule).
    func testSingleProviderPlusCodeAndReviewIsNotATeamDirective() {
        let normals = [
            "write the deepseek client and add a check for nil",
            "build the openai wrapper, then write tests and verify they pass",
            "code the qwen adapter and review the error handling myself",
            "implement the ollama integration and audit the logs",
            "check whether the mistral endpoint is up and build a retry",
            "watch the codex build and verify the artifact",
        ]
        for msg in normals {
            XCTAssertNil(TeamIntent.parse(msg), "normal coding request wrongly armed team mode: \(msg)")
        }
    }

    func testWorkAsATeamWithTwoModels() {
        // Two named models + "work as a team" → first-mentioned leads, second reviews.
        let t = TeamIntent.parse("deepseek and gemini work as a team to build the exporter")
        XCTAssertEqual(t?.lead, "deepseek")
        XCTAssertEqual(t?.co, "gemini")
        XCTAssertTrue(t?.goal.contains("build the exporter") == true, t?.goal ?? "nil")
    }

    func testBringInReviewer() {
        let t = TeamIntent.parse("bring in claude to review the auth change")
        XCTAssertEqual(t?.co, "claude", "bring in X to review ⇒ X is the reviewer")
        XCTAssertNil(t?.lead, "no coder named ⇒ keep the current lead")
    }

    func testProviderAliasCanonicalization() {
        XCTAssertEqual(TeamIntent.parse("have gpt be the eyes for deepseek")?.co, "openai")
        XCTAssertEqual(TeamIntent.parse("anthropic as the eyes for grok")?.co, "claude")
    }

    func testPlainMessageIsNotATeamDirective() {
        // A normal turn must NEVER be reinterpreted as a team setup.
        XCTAssertNil(TeamIntent.parse("write a function to reverse a string"))
        XCTAssertNil(TeamIntent.parse("what does this regex do?"))
        XCTAssertNil(TeamIntent.parse("review my morning schedule"), "review without a team frame ⇒ not a directive")
    }

    func testTeamFrameWithoutAnyProviderStillArmsWithGoal() {
        // "work as a team to X" with no model named: a directive (enable team) with the goal preserved.
        let t = TeamIntent.parse("work as a team to refactor the tokenizer")
        XCTAssertNotNil(t)
        XCTAssertTrue(t?.goal.contains("refactor the tokenizer") == true, t?.goal ?? "nil")
    }

    func testOneModelIsNeverBoundToBothRoles() {
        let t = TeamIntent.parse("deepseek code and review it as a team")
        // Only one model named — it can lead, but must not also be pinned as its own reviewer.
        XCTAssertFalse(t?.lead != nil && t?.lead == t?.co, "a model must not review its own code")
    }

    func testResidualGoalStripsTheTeamFraming() {
        let t = TeamIntent.parse("gemini be the eyes for deepseek to wire the CSV exporter into the CLI")
        XCTAssertEqual(t?.goal, "wire the CSV exporter into the CLI")
    }
}
