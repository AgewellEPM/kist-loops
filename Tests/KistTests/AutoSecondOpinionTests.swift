import XCTest
import AgentCore
@testable import Kist

/// The default-on "second opinion" (2026-07-29): after a substantive DIRECT turn, a DIFFERENT model
/// reviews the work (diff for coding turns, answer text otherwise). Pure logic + source pins for the
/// per-turn wiring (the review path writes to stdout, so behaviour is asserted at the source).
final class AutoSecondOpinionTests: XCTestCase {

    // MARK: pure logic

    func testAutoSecondOpinionDefaultsOn() {
        XCTAssertTrue(CopilotConfig().autoSecondOpinion, "the second opinion must be ON by default — that IS the feature")
        XCTAssertFalse(CopilotConfig().enabled, "team review→fix stays OFF by default (advisory only)")
    }

    func testSubstantiveAnswerGate() {
        XCTAssertFalse(Copilot.isSubstantiveAnswer("ok"), "chit-chat must NOT trigger a paid second-opinion call")
        XCTAssertFalse(Copilot.isSubstantiveAnswer(String(repeating: "x", count: 399)))
        XCTAssertTrue(Copilot.isSubstantiveAnswer(String(repeating: "x", count: 400)), "a substantive answer is worth a second opinion")
    }

    func testAnswerReviewPromptCarriesTaskAndAnswerAndIsBounded() {
        let p = Copilot.answerReviewPrompt(task: "what is X", answer: String(repeating: "A", count: 9000), maxChars: 8000)
        XCTAssertTrue(p.contains("what is X"))
        XCTAssertTrue(p.contains("[answer truncated]"), "a huge answer must be clipped so it can't blow the reviewer's context")
        XCTAssertLessThan(p.count, 8600)
    }

    func testCopilotOffSilencesTheSecondOpinion() {
        // Source pin: `/copilot off` must clear autoSecondOpinion, not just team mode — else "off" leaves
        // the per-turn second-opinion call running and the user can't quiet it.
        let repl = try! String(contentsOf: repoFile("Sources/Kist/KistREPL.swift"), encoding: .utf8)
        XCTAssertTrue(repl.contains("copilot.autoSecondOpinion = false"),
                      "/copilot off must set autoSecondOpinion = false to fully silence the review")
    }

    // MARK: wiring source pins

    func testDirectTurnRequestsAdvisoryReviewWithTheAnswer() {
        let repl = try! String(contentsOf: repoFile("Sources/Kist/KistREPL.swift"), encoding: .utf8)
        XCTAssertTrue(repl.contains("runCopilotReview(task: messageText, answer: oc.summary, allowAdvisory: true)"),
                      "the direct-turn call must pass the answer AND allow the advisory second opinion")
    }

    func testReviewerMustBeADistinctModel() {
        // The whole point: consult ANOTHER model, never let a model grade its own work.
        let repl = try! String(contentsOf: repoFile("Sources/Kist/KistREPL.swift"), encoding: .utf8)
        XCTAssertTrue(repl.contains("func autoReviewer(answeredBy:"),
                      "there must be a reviewer picker that selects a DIFFERENT model than the one that answered")
        XCTAssertTrue(repl.contains("co.providerId != answeredBy.providerId"),
                      "the picker must reject the answering model (no self-review)")
    }

    private func repoFile(_ rel: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(rel)
    }
}
