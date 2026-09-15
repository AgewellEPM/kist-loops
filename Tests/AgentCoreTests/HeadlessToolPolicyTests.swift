import XCTest
@testable import AgentCore

/// Static plan-mode and tool-boundary contracts, split from the loop behavior suite.
final class HeadlessToolPolicyTests: XCTestCase {
    func testPlanModeSystemPromptCarriesBanner() {
        let on = HeadlessAgentLoop.systemPrompt(tools: .headless(), projectRoot: "/tmp", planMode: true)
        XCTAssertTrue(on.contains("PLAN MODE IS ON"))
        let off = HeadlessAgentLoop.systemPrompt(tools: .headless(), projectRoot: "/tmp", planMode: false)
        XCTAssertFalse(off.contains("PLAN MODE IS ON"))
        // Native prompt too.
        XCTAssertTrue(HeadlessAgentLoop.nativeSystemPrompt(tools: .headless(), projectRoot: "/tmp", planMode: true).contains("PLAN MODE IS ON"))
        XCTAssertFalse(HeadlessAgentLoop.nativeSystemPrompt(tools: .headless(), projectRoot: "/tmp", planMode: false).contains("PLAN MODE IS ON"))
    }

    func testReadOnlyAllowlistIsExactlyTheSafeTools() {
        // Pin the allowlist so a new mutating tool isn't accidentally treated as read-only.
        // ast_grep is read-only (search + preview); ast_grep_apply (mutating) is intentionally absent.
        XCTAssertEqual(HeadlessAgentLoop.readOnlyTools, ["read_file", "read_files", "list_files", "glob_files", "search_code", "ast_grep", "git", "symbols", "context_brain", "fetch_url", "web_search", "list_agents", "shared_memory"])
        XCTAssertFalse(HeadlessAgentLoop.readOnlyTools.contains("ast_grep_apply"), "the mutating rewrite must never be read-only")
        XCTAssertFalse(HeadlessAgentLoop.readOnlyTools.contains("create_agent"), "persistent creation requires mutation authority")
    }

}
