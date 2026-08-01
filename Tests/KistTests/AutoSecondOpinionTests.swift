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

    // THE FIX: the reviewer was context-blind (no idea what "Kist" is) → answered "can't verify these claims"
    // instead of reviewing. Passing projectContext must inject a labeled BACKGROUND block carrying that
    // grounding, for BOTH the answer-review and the diff-review paths.
    func testProjectContextGroundsBothReviewPrompts() {
        let ctx = "You are Kist: an autonomous coding + research Captain. Source at /Volumes/PRO-G40/kist-loops."
        let answerP = Copilot.answerReviewPrompt(task: "what happens when agents finish",
                                                 answer: String(repeating: "A", count: 500), projectContext: ctx)
        XCTAssertTrue(answerP.contains("BACKGROUND"), "the reviewer must receive a labeled background block")
        XCTAssertTrue(answerP.contains("autonomous coding + research Captain"),
                      "the actual grounding text must be present so the reviewer knows what Kist is")
        XCTAssertTrue(answerP.contains("NOT as the answer you are reviewing"),
                      "background must be fenced off from the answer under review")

        let diffP = Copilot.reviewPrompt(task: "add a flag", diff: "diff --git a b", projectContext: ctx)
        XCTAssertTrue(diffP.contains("BACKGROUND"))
        XCTAssertTrue(diffP.contains("autonomous coding + research Captain"))
    }

    // AUTO-FIX BY DEFAULT (Luke 2026-08-01): a non-clean review must make the lead JUMP IN and fix it —
    // the fix loop can no longer be gated behind team mode (`copilot.enabled`). Pinned at the source so a
    // revert to advisory-only is caught.
    func testNonCleanReviewAutoFixesWithoutTeamMode() {
        let repl = try! String(contentsOf: repoFile("Sources/Kist/KistREPL.swift"), encoding: .utf8)
        XCTAssertTrue(repl.contains("guard let loopFactory, !Copilot.reviewIsClean(review) else { return }"),
                      "the fix loop must fire on ANY non-clean review with a lead loop — not only in team mode")
        XCTAssertFalse(repl.contains("guard copilot.enabled, copilot.autoFix, let loopFactory else { return }"),
                      "the old team-mode-only gate must be gone")
        // The REVIEWER (Claude, the one that found the problem) goes in and fixes — LAST, after the review —
        // not the primary model that produced the bad work.
        XCTAssertTrue(repl.contains("let fixer = autoReviewer(answeredBy: activeBinding) ?? copilot.lead ?? roleSelection.fallback"),
                      "the fixer must be the reviewer (found the problem), falling back to lead/session only")
        XCTAssertTrue(repl.contains("loopFactory(fixer,"), "the fix turn must run on the reviewer/fixer, not the primary")
    }

    // ULTRA MODE (Luke 2026-08-01): /mode ultra runs a CONSENSUS chain — every reachable mind reviews→fixes
    // in turn until flawless. Pinned at the source (the chain lives in the REPL run loop, not unit-reachable).
    func testUltraModeConsensusChainWired() {
        let repl = try! String(contentsOf: repoFile("Sources/Kist/KistREPL.swift"), encoding: .utf8)
        XCTAssertTrue(repl.contains("if copilot.ultra { await runUltraReview(task: task, answer: answer); return }"),
                      "ultra mode must route to the consensus chain instead of the single second opinion")
        XCTAssertTrue(repl.contains("func runUltraReview(") && repl.contains("func ultraRoster("),
                      "the consensus chain + capability-ordered roster must exist")
        XCTAssertTrue(repl.contains("reviewer: mind") && repl.contains("loopFactory(mind,"),
                      "each mind must both REVIEW (as reviewer) and FIX (as the fix loop's model)")
        XCTAssertTrue(repl.contains("case \"ultra\", \"consensus\", \"flawless\":"), "the /ultra command must exist")
        XCTAssertTrue(CopilotConfig().ultra == false, "ultra is off by default")
    }

    // The fix ask must work for ANSWER critiques too (Luke's case: the answer dodged / never ran it), not
    // just code edits — otherwise a harsh answer-review is still a dead end.
    func testFixPromptHandlesAnswerCritiquesNotJustCode() {
        let p = Copilot.fixPrompt(task: "did it open in the VM", review: "The answer dodged with 'next step'")
        XCTAssertTrue(p.contains("ANSWER"), "the fix ask must cover answer/analysis turns")
        XCTAssertTrue(p.lowercased().contains("run it") || p.lowercased().contains("verify"),
                      "an answer-fix must tell the lead to actually DO/verify the work, not restate")
    }

    // Backward-compat: an empty projectContext builds the SAME prompt as before (no stray background block),
    // so ungrounded callers/tests are unaffected.
    func testEmptyProjectContextAddsNoGrounding() {
        XCTAssertEqual(Copilot.groundingBlock(""), "")
        XCTAssertEqual(Copilot.groundingBlock("   \n  "), "", "whitespace-only context adds nothing")
        let p = Copilot.answerReviewPrompt(task: "q", answer: String(repeating: "A", count: 500))
        XCTAssertFalse(p.contains("BACKGROUND"), "no context ⇒ no background block (unchanged behaviour)")
        XCTAssertTrue(p.hasPrefix("The user asked:"))
    }

    // The grounding block is bounded so a huge project memory can't crowd out the answer being reviewed.
    func testGroundingBlockIsBounded() {
        let huge = String(repeating: "K", count: 20_000)
        let block = Copilot.groundingBlock(huge, maxChars: 6_000)
        XCTAssertTrue(block.contains("[context truncated]"))
        // clipped content (≤6000) + the fixed wrapper/label text — bounded well under the untruncated 20k.
        XCTAssertLessThan(block.count, 6_800)
    }

    // Wiring source pin: the review path must actually BUILD grounding and pass it into the prompt builders —
    // else the fix is dead code. Pins reviewerGrounding() (self-identity + project memory) and its use.
    func testReviewPassesGroundingToThePromptBuilders() {
        let repl = try! String(contentsOf: repoFile("Sources/Kist/KistREPL.swift"), encoding: .utf8)
        XCTAssertTrue(repl.contains("func reviewerGrounding()"),
                      "there must be a helper that assembles the reviewer's grounding")
        XCTAssertTrue(repl.contains("kistSelfContext()") && repl.contains("ProjectMemory(root: projectRoot).facts()"),
                      "grounding must reuse the primary turn's self-identity brief + durable project memory")
        XCTAssertTrue(repl.contains("projectContext: grounding"),
                      "the grounding must be threaded into BOTH review prompt builders")
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
