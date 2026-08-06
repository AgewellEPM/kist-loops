import XCTest
@testable import AgentCore

/// Fix (Luke 2026-08-06): a trivial "review this as deepseek" turn (intent .review, on weak MiMo) spawned a
/// research SUB-agent that ran 3 web searches + a fetch_url for ~200k tokens — "too much research, not
/// listening to me". `conversationalToolset` withholds the RECURSIVE spawn vector from chat/review turns so
/// a plain reply can't balloon into a research expedition, while heavy/build intents keep it.
final class ConversationalToolsetTests: XCTestCase {

    private func registry() -> ToolRegistry {
        ToolRegistry([StubTool(name: "read_file"), StubTool(name: "web_search"),
                      StubTool(name: "spawn_agent"), StubTool(name: "spawn_specialist"),
                      StubTool(name: "edit_file")])
    }
    private func names(_ r: ToolRegistry) -> Set<String> { Set(r.all().map { $0.name }) }

    func testChatDropsSpawnVectorButKeepsDirectTools() {
        let out = names(HeadlessAgentLoop.conversationalToolset(registry(), intent: .chat))
        XCTAssertFalse(out.contains("spawn_agent"), "chat must not delegate to a sub-agent")
        XCTAssertFalse(out.contains("spawn_specialist"))
        XCTAssertTrue(out.contains("web_search"), "a single bounded web_search stays — only recursion is cut")
        XCTAssertTrue(out.contains("read_file"))
        XCTAssertTrue(out.contains("edit_file"))
    }

    func testReviewAlsoDropsSpawnVector() {
        let out = names(HeadlessAgentLoop.conversationalToolset(registry(), intent: .review))
        XCTAssertFalse(out.contains("spawn_agent"), "Luke's exact case: 'review this' must not spawn research")
        XCTAssertFalse(out.contains("spawn_specialist"))
    }

    func testBuildAndResearchKeepSpawn() {
        for intent in [TaskBrief.Intent.build, .plan, .fleet, .research, .desktop] {
            let out = names(HeadlessAgentLoop.conversationalToolset(registry(), intent: intent))
            XCTAssertTrue(out.contains("spawn_agent"), "\(intent) legitimately delegates — spawn stays")
        }
    }

    func testNilIntentIsUnchanged() {
        // Fail-open: an unclassified turn behaves exactly as before (no surprise tool removal).
        let out = names(HeadlessAgentLoop.conversationalToolset(registry(), intent: nil))
        XCTAssertTrue(out.contains("spawn_agent"))
    }
}

private struct StubTool: AgentTool {
    let name: String
    var description: String { "test tool" }
    var parameters: [ToolParameter] { [] }
    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        ToolResult(success: true, output: "ok")
    }
}
