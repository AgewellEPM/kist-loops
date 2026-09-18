import XCTest
@testable import AgentCore

/// Fix (Luke 2026-08-06): a trivial "review this as deepseek" turn (intent .review, on weak MiMo) spawned a
/// research SUB-agent that ran 3 web searches + a fetch_url for ~200k tokens — "too much research, not
/// listening to me". `conversationalToolset` now enforces the typed effect contract at the registry boundary:
/// answer/evidence/plan turns get inspection tools only, while explicitly effectful intents retain mutators.
final class ConversationalToolsetTests: XCTestCase {

    private func registry() -> ToolRegistry {
        ToolRegistry([ReadFileTool(), WebSearchTool(), ManageTasksTool(),
                      StubTool(name: "spawn_agent"), StubTool(name: "spawn_specialist"),
                      EditFileTool()])
    }
    private func names(_ r: ToolRegistry) -> Set<String> { Set(r.all().map { $0.name }) }

    private func trustedDelegationRegistry() -> ToolRegistry {
        let base = ToolRegistry([ReadFileTool(), EditFileTool()])
        let spawn = SpawnAgentTool(providers: ProviderRegistry(providers: []),
                                   providerId: "missing", model: nil,
                                   baseTools: base, maxIterations: 2)
        return ToolRegistry(base.all() + [spawn])
    }

    func testChatDropsSpawnVectorAndMutatorsButKeepsReadTools() {
        let out = names(HeadlessAgentLoop.conversationalToolset(registry(), intent: .chat))
        XCTAssertFalse(out.contains("spawn_agent"), "chat must not delegate to a sub-agent")
        XCTAssertFalse(out.contains("spawn_specialist"))
        XCTAssertTrue(out.contains("web_search"), "a single bounded web_search stays — only recursion is cut")
        XCTAssertTrue(out.contains("read_file"))
        XCTAssertTrue(out.contains("tasks"), "safe task-board reads stay reachable; writes are call-gated")
        XCTAssertFalse(out.contains("edit_file"), "read-only authority must be enforced at execution")
    }

    func testReviewAlsoDropsSpawnVector() {
        let out = names(HeadlessAgentLoop.conversationalToolset(registry(), intent: .review))
        XCTAssertFalse(out.contains("spawn_agent"), "Luke's exact case: 'review this' must not spawn research")
        XCTAssertFalse(out.contains("spawn_specialist"))
    }

    func testReadOnlyIntentsDropSpawnAndMutators() {
        for intent in [TaskBrief.Intent.chat, .review, .research, .plan] {
            let out = names(HeadlessAgentLoop.conversationalToolset(registry(), intent: intent))
            XCTAssertFalse(out.contains("spawn_agent"), "\(intent) cannot delegate around read-only authority")
            XCTAssertFalse(out.contains("edit_file"), "\(intent) cannot mutate")
            XCTAssertTrue(out.contains("read_file"))
        }
    }

    func testEffectfulIntentsKeepSpawnAndMutators() {
        for intent in [TaskBrief.Intent.build, .fleet, .desktop] {
            let out = names(HeadlessAgentLoop.conversationalToolset(registry(), intent: intent))
            XCTAssertTrue(out.contains("spawn_agent"), "\(intent) retains effectful tools")
            XCTAssertTrue(out.contains("edit_file"), "\(intent) retains mutation tools")
        }
    }

    func testDelegateKeepsOnlyTrustedReadsAndOrchestrationImplementations() {
        let out = HeadlessAgentLoop.conversationalToolset(
            trustedDelegationRegistry(), intent: .delegate)
        let kept = names(out)

        XCTAssertTrue(kept.contains("read_file"))
        XCTAssertTrue(kept.contains("spawn_agent"))
        XCTAssertTrue(kept.contains("join_agent"))
        XCTAssertTrue(kept.contains("steer_agent"))
        XCTAssertTrue(kept.contains("cancel_agent"))
        XCTAssertFalse(kept.contains("edit_file"), "the parent cannot perform delegated work itself")
    }

    func testNilIntentIsUnchanged() {
        // Fail-open: an unclassified turn behaves exactly as before (no surprise tool removal).
        let out = names(HeadlessAgentLoop.conversationalToolset(registry(), intent: nil))
        XCTAssertTrue(out.contains("spawn_agent"))
    }

    func testExactNameShadowDoesNotForgeReadOnlyProvenance() {
        let out = HeadlessAgentLoop.conversationalToolset(
            ToolRegistry([StubTool(name: "read_file")]), intent: .chat)
        XCTAssertNil(out.tool(named: "read_file"),
                     "a tool name alone must not mint a read-only capability")
    }


    func testExactNameShadowDoesNotForgeDelegationProvenance() {
        let out = HeadlessAgentLoop.conversationalToolset(
            ToolRegistry([StubTool(name: "spawn_agent")]), intent: .delegate)
        XCTAssertNil(out.tool(named: "spawn_agent"))
    }

    // MARK: host-declared read-only MCP tools (bio-scientist audit fix, 2026-09-18)
    // Remote MCP tools can't be ReadOnlyAgentTool (untrusted external implementation); the owner's
    // per-server `toolEffects` declaration admits them instead. Per the multi-site rule, BOTH filter
    // sites are pinned: the chat/review/research/plan branch AND the .delegate branch.

    func testHostDeclaredReadOnlyMCPToolSurvivesEveryInspectOnlyIntent() {
        let reg = ToolRegistry([StubHostDeclaredTool(name: "bio-research__pubmed_search", hostDeclaredReadOnly: true),
                                StubHostDeclaredTool(name: "bio-research__run_python", hostDeclaredReadOnly: false),
                                StubTool(name: "bio-research__wetware_remove")])
        for intent in [TaskBrief.Intent.chat, .review, .research, .plan] {
            let out = names(HeadlessAgentLoop.conversationalToolset(reg, intent: intent))
            XCTAssertTrue(out.contains("bio-research__pubmed_search"),
                          "\(intent): owner-declared readOnly MCP tool must stay reachable")
            XCTAssertFalse(out.contains("bio-research__run_python"),
                           "\(intent): declared-effectful MCP tool must be excluded")
            XCTAssertFalse(out.contains("bio-research__wetware_remove"),
                           "\(intent): UNdeclared MCP tool defaults to effectful (fail-closed)")
        }
    }

    func testHostDeclaredReadOnlyMCPToolSurvivesDelegateBranch() {
        let reg = ToolRegistry([StubHostDeclaredTool(name: "jeeves-floor__symbolic_query", hostDeclaredReadOnly: true),
                                StubHostDeclaredTool(name: "jeeves-floor__teach_relation", hostDeclaredReadOnly: false)])
        let out = names(HeadlessAgentLoop.conversationalToolset(reg, intent: .delegate))
        XCTAssertTrue(out.contains("jeeves-floor__symbolic_query"),
                      "delegate branch (site 2 of 2) must also honor the owner's readOnly declaration")
        XCTAssertFalse(out.contains("jeeves-floor__teach_relation"))
    }

    func testEffectfulIntentsKeepAllMCPToolsRegardlessOfDeclaration() {
        let reg = ToolRegistry([StubHostDeclaredTool(name: "bio-research__run_python", hostDeclaredReadOnly: false)])
        for intent in [TaskBrief.Intent.build, .fleet, .desktop] {
            let out = names(HeadlessAgentLoop.conversationalToolset(reg, intent: intent))
            XCTAssertTrue(out.contains("bio-research__run_python"), "\(intent) retains effectful MCP tools")
        }
    }

    func testCallTimeEffectContractHonorsHostDeclaration() {
        // Site 3 of 3: the call-time effect contract (isTrustedReadOnlyCall) must agree with the
        // registry filter, or the tool is visible but every call is "Policy denied" (the exact
        // live failure this fix closes).
        let reg = ToolRegistry([StubHostDeclaredTool(name: "bio-research__uniprot_entry", hostDeclaredReadOnly: true),
                                StubHostDeclaredTool(name: "bio-research__run_python", hostDeclaredReadOnly: false)])
        XCTAssertTrue(HeadlessAgentLoop.isTrustedReadOnlyCall(
            registry: reg, tool: "bio-research__uniprot_entry", args: [:]),
            "declared-readOnly MCP tool must pass the call-time read-only contract")
        XCTAssertFalse(HeadlessAgentLoop.isTrustedReadOnlyCall(
            registry: reg, tool: "bio-research__run_python", args: [:]),
            "declared-effectful MCP tool must still be denied at call time")
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

/// Mirrors RemoteMCPTool's shape: a plain AgentTool carrying the owner's config declaration.
private struct StubHostDeclaredTool: AgentTool, HostDeclaredEffectTool {
    let name: String
    let hostDeclaredReadOnly: Bool
    var description: String { "test MCP tool" }
    var parameters: [ToolParameter] { [] }
    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        ToolResult(success: true, output: "ok")
    }
}
