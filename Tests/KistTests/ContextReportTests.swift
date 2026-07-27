import XCTest
import AgentCore
@testable import Kist

/// Pins the `/context` window breakdown: token estimation, per-role grouping, capacity math.
final class ContextReportTests: XCTestCase {

    private func msg(_ role: ChatMessage.Role, _ content: String) -> ChatMessage {
        ChatMessage(role: role, content: content)
    }

    func testEstimateTokensRoughlyFourCharsEach() {
        XCTAssertEqual(ContextReport.estimateTokens(""), 0)
        XCTAssertEqual(ContextReport.estimateTokens("abcd"), 1)
        XCTAssertEqual(ContextReport.estimateTokens(String(repeating: "x", count: 400)), 100)
    }

    func testBuildGroupsTranscriptByRole() {
        let transcript = [
            msg(.user, String(repeating: "u", count: 40)),        // 10 tok
            msg(.assistant, String(repeating: "a", count: 80)),   // 20 tok
            msg(.tool, String(repeating: "t", count: 400)),       // 100 tok
            msg(.assistant, String(repeating: "b", count: 40)),   // 10 tok
        ]
        let sources = ContextReport.build(transcript: transcript, memory: nil, systemPrompt: nil)
        let tool = sources.first { $0.label == "tool output" }
        let assistant = sources.first { $0.label.contains("assistant") }
        XCTAssertEqual(tool?.tokens, 100)
        XCTAssertEqual(tool?.items, 1)
        XCTAssertEqual(assistant?.tokens, 30, "both assistant msgs summed")
        XCTAssertEqual(assistant?.items, 2)
    }

    func testBuildIncludesSystemAndMemoryWhenPresent() {
        let sources = ContextReport.build(transcript: [],
                                          memory: String(repeating: "m", count: 40),
                                          systemPrompt: String(repeating: "s", count: 400))
        XCTAssertTrue(sources.contains { $0.label == "system prompt" && $0.tokens == 100 })
        XCTAssertTrue(sources.contains { $0.label == "project memory" && $0.tokens == 10 })
    }

    func testEmptyTranscriptOmitsRoleLines() {
        let sources = ContextReport.build(transcript: [], memory: nil, systemPrompt: nil)
        XCTAssertTrue(sources.isEmpty)
        XCTAssertTrue(ContextReport.render(sources: sources, windowTokens: nil).contains("empty"))
    }

    func testTotalAndRenderPercentAndWarning() {
        let sources = [ContextReport.Source(label: "tool output", tokens: 8_500, items: 3)]
        XCTAssertEqual(ContextReport.total(sources), 8_500)
        let out = ContextReport.render(sources: sources, windowTokens: 10_000)
        XCTAssertTrue(out.contains("85%"))
        XCTAssertTrue(out.contains("near capacity"), "≥80% warns")
    }

    func testRenderWithoutWindowOmitsPercent() {
        let sources = [ContextReport.Source(label: "conversation · you", tokens: 500, items: 2)]
        let out = ContextReport.render(sources: sources, windowTokens: nil)
        XCTAssertFalse(out.contains("%"))
        XCTAssertTrue(out.contains("500"))
    }

    func testThousandsFormatting() {
        XCTAssertEqual(ContextReport.fmt(999), "999")
        XCTAssertEqual(ContextReport.fmt(12_345), "12,345")
        XCTAssertEqual(ContextReport.fmt(1_000_000), "1,000,000")
    }
}
