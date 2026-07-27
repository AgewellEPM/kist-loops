import XCTest
import AgentCore
@testable import Kist

/// Pins `/compact` fold logic: split (summarize older / keep recent), prompt build, fold, tokens-freed.
final class TranscriptCompactorTests: XCTestCase {

    private func m(_ role: ChatMessage.Role, _ c: String) -> ChatMessage { ChatMessage(role: role, content: c) }
    private func convo(_ n: Int) -> [ChatMessage] {
        (0..<n).map { m($0 % 2 == 0 ? .user : .assistant, "message \($0)") }
    }

    func testPlanKeepsRecentAndSummarizesOlder() {
        let t = convo(10)
        let (summarize, keep) = TranscriptCompactor.plan(t, keepRecent: 4)
        XCTAssertEqual(summarize.count, 6)
        XCTAssertEqual(keep.count, 4)
        XCTAssertEqual(keep.first?.content, "message 6", "kept slice is the LAST 4")
        XCTAssertEqual(keep.last?.content, "message 9")
    }

    func testPlanShortConvoKeepsEverything() {
        let t = convo(3)
        let (summarize, keep) = TranscriptCompactor.plan(t, keepRecent: 6)
        XCTAssertTrue(summarize.isEmpty)
        XCTAssertEqual(keep.count, 3)
    }

    func testWorthCompactingThreshold() {
        XCTAssertFalse(TranscriptCompactor.worthCompacting(convo(8), keepRecent: 6, minToSummarize: 4),
                       "only 2 older messages ⇒ not worth it")
        XCTAssertTrue(TranscriptCompactor.worthCompacting(convo(12), keepRecent: 6, minToSummarize: 4),
                      "6 older messages ⇒ worth compacting")
    }

    func testSummarizationPromptLabelsRolesAndCarriesFocus() {
        let msgs = [m(.user, "build the parser"), m(.assistant, "done"), m(.tool, "ok")]
        let p = TranscriptCompactor.summarizationPrompt(msgs, focus: "keep API names")
        XCTAssertTrue(p.contains("USER: build the parser"))
        XCTAssertTrue(p.contains("ASSISTANT: done"))
        XCTAssertTrue(p.contains("TOOL: ok"))
        XCTAssertTrue(p.contains("Focus the summary on: keep API names"))
    }

    func testSummarizationPromptClipsHugeHistory() {
        let big = [m(.user, String(repeating: "x", count: 100_000))]
        let p = TranscriptCompactor.summarizationPrompt(big, focus: nil, maxChars: 1_000)
        XCTAssertTrue(p.contains("history truncated"))
        XCTAssertLessThan(p.count, 2_000)
    }

    func testFoldPrependsSummaryAsUserMessageThenKeeps() {
        let keep = [m(.user, "recent"), m(.assistant, "reply")]
        let folded = TranscriptCompactor.fold(summary: "the story so far", keep: keep)
        XCTAssertEqual(folded.count, 3)
        // MUST be .user, not .system — non-Gemini encoders strip mid-transcript .system (summary would vanish).
        XCTAssertEqual(folded.first?.role, .user)
        XCTAssertTrue(folded.first!.content.contains("Summary of the earlier conversation"))
        XCTAssertTrue(folded.first!.content.contains("the story so far"))
        XCTAssertEqual(Array(folded.dropFirst()), keep, "recent messages preserved verbatim after the summary")
    }

    func testTokensFreedIsPositiveWhenSummaryIsSmaller() {
        let summarize = [m(.user, String(repeating: "a", count: 4_000))]   // ~1000 tok
        let freed = TranscriptCompactor.tokensFreed(summarize: summarize, summary: "short")  // ~1 tok
        XCTAssertGreaterThan(freed, 900)
    }

    func testTokensFreedNeverNegative() {
        let summarize = [m(.user, "tiny")]
        let freed = TranscriptCompactor.tokensFreed(summarize: summarize,
                                                    summary: String(repeating: "z", count: 400))
        XCTAssertEqual(freed, 0, "a summary bigger than the source frees nothing, not negative")
    }
}
