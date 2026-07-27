import XCTest
@testable import AgentCore

/// Summarizing compaction — the split, the trigger, the summary injection, and the safe fallback. Pure
/// over an injected summarize closure, so no model is needed. (The trigger clamps to a 2 000-char floor,
/// so histories here use ~500-char messages to cross it realistically.)
final class ConversationCompactorTests: XCTestCase {

    private func history(_ n: Int) -> [ChatMessage] {
        let filler = String(repeating: "x", count: 500)
        return (0..<n).map { ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, content: "step \($0) \(filler)") }
    }

    func testNoCompactionBelowTrigger() async {
        let c = ConversationCompactor(triggerCharacters: 1_000_000)
        let m = history(20)                    // ~10 k chars, well under a 1 M trigger
        XCTAssertFalse(c.needsCompaction(m))
        let (out, omitted) = await c.compact(m) { _ in "SUM" }
        XCTAssertEqual(omitted, 0)
        XCTAssertEqual(out.count, m.count, "unchanged when under the trigger")
    }

    func testNoCompactionWhenMiddleTooSmall() {
        // Over the size trigger (6×~532 ≈ 3.2 k > 2 k floor), but not enough middle to be worth an LLM call.
        let c = ConversationCompactor(triggerCharacters: 100, keepFirst: 1, keepRecent: 2, minMiddle: 5)
        let m = history(6)                     // middle = 6 - 1 - 2 = 3 < 5
        XCTAssertGreaterThan(c.totalCost(m), 2_000)
        XCTAssertFalse(c.needsCompaction(m))
    }

    func testCompactFoldsMiddleKeepingHeadAndTail() async {
        let c = ConversationCompactor(triggerCharacters: 100, keepFirst: 2, keepRecent: 3, minMiddle: 2)
        let m = history(20)
        XCTAssertTrue(c.needsCompaction(m))
        let (out, omitted) = await c.compact(m) { middle in "SUMMARY of \(middle.count) steps" }
        XCTAssertEqual(omitted, 15, "20 - keepFirst(2) - keepRecent(3) = 15 folded")
        XCTAssertEqual(out.count, 6, "prefix(2) + summary(1) + recent(3)")
        XCTAssertEqual(out.first?.content, m.first?.content, "head preserved verbatim")
        XCTAssertEqual(out.last?.content, m.last?.content, "most recent preserved verbatim")
        XCTAssertTrue(out[2].content.contains("SUMMARY of 15 steps"))
        XCTAssertTrue(out[2].content.contains("COMPACTED CONTEXT"))
        XCTAssertTrue(out[2].content.contains("source of truth"), "tells the model live files win on conflict")
    }

    func testFallbackNoticeWhenSummarizeFails() async {
        // Model error/cancel ⇒ summarize returns nil ⇒ still shrinks with a factual notice.
        let c = ConversationCompactor(triggerCharacters: 100, keepFirst: 2, keepRecent: 3, minMiddle: 2)
        let (out, omitted) = await c.compact(history(20)) { _ in nil }
        XCTAssertEqual(omitted, 15)
        XCTAssertEqual(out.count, 6)
        XCTAssertTrue(out[2].content.contains("compacted out of context"))
    }

    func testEmptySummaryTreatedAsFailure() async {
        let c = ConversationCompactor(triggerCharacters: 100, keepFirst: 2, keepRecent: 3, minMiddle: 2)
        let (out, _) = await c.compact(history(20)) { _ in "   \n  " }
        XCTAssertTrue(out[2].content.contains("compacted out of context"), "whitespace-only summary → fallback")
    }
}

/// Panel-finding regression: EffortMemory.record must be atomic (no partial-line corruption) and bounded.
final class EffortMemoryRecordTests: XCTestCase {
    func testRecordIsAtomicBoundedAndReadable() {
        let root = NSTemporaryDirectory() + "em-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mem = EffortMemory(projectRoot: root, maxRecords: 5)
        for i in 0..<12 {
            mem.record(EffortOutcome(signature: "s", predicted: i, actual: i, quality: i, success: true, at: Double(i)))
        }
        let loaded = mem.load()
        XCTAssertEqual(loaded.count, 5, "bounded to maxRecords")
        XCTAssertEqual(loaded.last?.predicted, 11, "keeps the most recent")
        XCTAssertTrue(loaded.allSatisfy { $0.signature == "s" }, "every line decodes — no corruption")
    }
}
