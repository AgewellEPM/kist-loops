import XCTest
@testable import AgentCore

/// History-repair for native tool-calling: orphan/out-of-order tool results would 400 strict
/// providers (Gemini/Anthropic). Repair keeps the content but makes the transcript valid.
final class TranscriptRepairTests: XCTestCase {

    func testValidTranscriptPassesThroughUnchanged() {
        let msgs = [
            ChatMessage(role: .user, content: "go"),
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRef(id: "c1", name: "read_file", argumentsJSON: "{}")]),
            ChatMessage.toolResult(callId: "c1", content: "ok"),
        ]
        XCTAssertFalse(TranscriptRepair.hasOrphanToolResults(msgs))
        let repaired = TranscriptRepair.repairForNativeTools(msgs)
        XCTAssertEqual(repaired, msgs)   // idempotent / unchanged
    }

    func testOrphanToolResultBecomesUserMessage() {
        // A tool result with no preceding matching assistant call.
        let msgs = [
            ChatMessage(role: .user, content: "go"),
            ChatMessage.toolResult(callId: "ghost", content: "leftover output"),
        ]
        XCTAssertTrue(TranscriptRepair.hasOrphanToolResults(msgs))
        let repaired = TranscriptRepair.repairForNativeTools(msgs)
        XCTAssertEqual(repaired.count, 2)
        XCTAssertEqual(repaired[1].role, .user)                       // tool → user
        XCTAssertTrue(repaired[1].content.contains("leftover output")) // content preserved (lossless)
        XCTAssertFalse(TranscriptRepair.hasOrphanToolResults(repaired)) // now valid
    }

    func testOutOfOrderResultBeforeItsCallIsRepaired() {
        // Result appears BEFORE the assistant call that would justify it → invalid ordering.
        let msgs = [
            ChatMessage.toolResult(callId: "c1", content: "early"),
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRef(id: "c1", name: "x", argumentsJSON: "{}")]),
        ]
        let repaired = TranscriptRepair.repairForNativeTools(msgs)
        XCTAssertEqual(repaired[0].role, .user)        // the early result was rewritten
        XCTAssertEqual(repaired[1].role, .user)        // the now-unanswered assistant call is rewritten too
        XCTAssertTrue(repaired[1].content.contains("incomplete"))
    }

    func testValidResultsAfterMultipleCallsAllKept() {
        let msgs = [
            ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCallRef(id: "c1", name: "read_file", argumentsJSON: "{}"),
                ToolCallRef(id: "c2", name: "read_file", argumentsJSON: "{}")]),
            ChatMessage.toolResult(callId: "c1", content: "A"),
            ChatMessage.toolResult(callId: "c2", content: "B"),
        ]
        XCTAssertFalse(TranscriptRepair.hasOrphanToolResults(msgs))
        let repaired = TranscriptRepair.repairForNativeTools(msgs)
        XCTAssertEqual(repaired.filter { $0.role == .tool }.count, 2)   // both results kept as tool
    }

    func testAssistantWithMissingToolResultIsRepaired() {
        // OpenAI-compatible providers reject this exact shape: assistant asked for c1+c2 but only
        // c1 is answered before the next user message.
        let msgs = [
            ChatMessage(role: .user, content: "go"),
            ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCallRef(id: "c1", name: "read_file", argumentsJSON: "{}"),
                ToolCallRef(id: "c2", name: "list_files", argumentsJSON: "{}")]),
            ChatMessage.toolResult(callId: "c1", content: "A"),
            ChatMessage(role: .user, content: "next"),
        ]
        XCTAssertTrue(TranscriptRepair.hasOrphanToolResults(msgs))
        let repaired = TranscriptRepair.repairForNativeTools(msgs)
        XCTAssertFalse(TranscriptRepair.hasOrphanToolResults(repaired))
        XCTAssertEqual(repaired[1].role, .user)
        XCTAssertTrue(repaired[1].content.contains("incomplete"))
        XCTAssertEqual(repaired[2].role, .user) // c1 is no longer treated as a native tool result
        XCTAssertTrue(repaired[2].content.contains("A"))
    }

    func testRepairIsIdempotent() {
        let msgs = [ChatMessage.toolResult(callId: "ghost", content: "x")]
        let once = TranscriptRepair.repairForNativeTools(msgs)
        let twice = TranscriptRepair.repairForNativeTools(once)
        XCTAssertEqual(once, twice)
    }
}
