import XCTest
@testable import AgentCore

final class ContextWindowManagerTests: XCTestCase {
    func testTrimKeepsOpeningAndFreshTailWithNotice() {
        let messages = [
            ChatMessage(role: .user, content: "start " + String(repeating: "a", count: 100)),
            ChatMessage(role: .assistant, content: "middle-one " + String(repeating: "b", count: 600)),
            ChatMessage(role: .user, content: "middle-two " + String(repeating: "c", count: 600)),
            ChatMessage(role: .assistant, content: "recent " + String(repeating: "d", count: 100)),
            ChatMessage(role: .user, content: "latest " + String(repeating: "e", count: 100)),
        ]
        let manager = ContextWindowManager(maxCharacters: 1_200, keepFirst: 1, keepLast: 2)

        let trimmed = manager.trim(messages)

        XCTAssertLessThan(trimmed.count, messages.count)
        XCTAssertTrue(trimmed.first?.content.contains("start") ?? false)
        XCTAssertTrue(trimmed.contains { $0.content.contains("Context window notice") })
        XCTAssertTrue(trimmed.contains { $0.content.contains("recent") })
        XCTAssertTrue(trimmed.contains { $0.content.contains("latest") })
        XCTAssertFalse(trimmed.contains { $0.content.contains("middle-one") })
    }

    func testSmallTranscriptIsUnchanged() {
        let messages = [
            ChatMessage(role: .user, content: "hello"),
            ChatMessage(role: .assistant, content: "world"),
        ]
        XCTAssertEqual(ContextWindowManager(maxCharacters: 1_200).trim(messages), messages)
    }

    func testLargeContextModelGetsLargeWindow() {
        let manager = ContextWindowManager.forModel(
            capabilities: ModelCapabilities(nativeTools: false, contextWindowTokens: 1_000_000)
        )

        XCTAssertGreaterThanOrEqual(manager.maxCharacters, 3_000_000)
        XCTAssertEqual(manager.keepLast, 256)
    }

    // Auto-compaction: split an over-budget transcript into prefix/middle/suffix, then assemble the
    // compacted list = prefix + ONE summary message + suffix (vs trim() which just drops the middle).
    func testCompactionSplitAndAssemble() {
        let mgr = ContextWindowManager(maxCharacters: 2_000, keepFirst: 1, keepLast: 2)
        var msgs = [ChatMessage(role: .user, content: "GOAL: build a clock")]
        for i in 0..<20 { msgs.append(ChatMessage(role: .assistant, content: "step \(i) " + String(repeating: "x", count: 300))) }
        msgs.append(ChatMessage(role: .user, content: "RECENT-1"))
        msgs.append(ChatMessage(role: .assistant, content: "RECENT-2"))

        XCTAssertTrue(mgr.overBudget(msgs))
        guard let split = mgr.compactionSplit(msgs) else { return XCTFail("expected a compaction split") }
        XCTAssertEqual(split.prefix.first?.content, "GOAL: build a clock")
        XCTAssertEqual(split.suffix.last?.content, "RECENT-2")
        XCTAssertFalse(split.middle.isEmpty)

        let out = mgr.compacted(prefix: split.prefix, summary: "did steps 0-19", suffix: split.suffix)
        XCTAssertEqual(out.count, split.prefix.count + 1 + split.suffix.count)
        XCTAssertTrue(out.contains { $0.content.contains("did steps 0-19") })
        XCTAssertTrue(out.contains { $0.content == "RECENT-2" })
        XCTAssertFalse(out.contains { $0.content.contains("step 5 ") })   // middle replaced, not kept
    }

    func testNoCompactionWhenUnderBudget() {
        let mgr = ContextWindowManager(maxCharacters: 100_000, keepFirst: 1, keepLast: 2)
        let msgs = [ChatMessage(role: .user, content: "hi"), ChatMessage(role: .assistant, content: "hello")]
        XCTAssertFalse(mgr.overBudget(msgs))
        XCTAssertNil(mgr.compactionSplit(msgs))
    }
}
