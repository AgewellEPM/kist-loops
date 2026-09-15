import XCTest
import AgentCore
@testable import Kist

final class AgentMetadataRoutingTests: XCTestCase {
    func testRegistrationFeedbackDoesNotHideSourceOrUnknownMutations() {
        let registration = ActionRecord(tool: "create_agent", argsFingerprint: "", success: true,
                                        effectObservation: ToolEffectObservation(mutation: .nonSource))
        XCTAssertTrue(AgentMetadataRequest.isRegistrationOnly([registration]))
        XCTAssertFalse(AgentMetadataRequest.isRegistrationOnly([]))
        for mutation: ToolEffectObservation.Mutation in [.source, .unknownTarget, .nonSource] {
            let other = ActionRecord(tool: "edit_file", argsFingerprint: "", success: false,
                                     effectObservation: ToolEffectObservation(mutation: mutation))
            XCTAssertFalse(AgentMetadataRequest.isRegistrationOnly([registration, other]))
        }
    }

    func testPlainAgentRegistrationUsesBoundedToolsAndExplicitBuilderStillUsesBuilder() {
        for goal in [
            "Create a reusable agent named historian using create_agent",
            "Please make an agent named helper",
            "Register an agent definition for code review",
            "Use create_agent to register my specialist",
        ] {
            XCTAssertTrue(AgentMetadataRequest.matches(goal), goal)
            XCTAssertEqual(PromptCompiler.inferIntent(goal), .build, goal)
            XCTAssertFalse(KistRunner.builderRunRequired(for: KistOptions.parse([goal]), goal: goal), goal)
            XCTAssertTrue(KistRunner.builderRunRequired(for: KistOptions.parse(["--headless", goal]), goal: goal), goal)
        }
    }

    func testSourceBuildsAndReadOnlyQuestionsDoNotBecomeMetadataRegistration() {
        for goal in ["Create agent.swift", "Build an agent application in Swift", "Create a CLI tool", "Explain how to create a reusable agent", "Review create_agent"] {
            XCTAssertFalse(AgentMetadataRequest.matches(goal), goal)
        }
        let goal = "Create agent.swift"
        XCTAssertTrue(KistRunner.builderRunRequired(for: KistOptions.parse([goal]), goal: goal))
        let readOnly = HeadlessAgentLoop.conversationalToolset(
            ToolRegistry([CreateAgentTool(ceiling: []), ListAgentsTool(), SharedAgentMemoryTool()]), intent: .plan,
            request: "Create a reusable agent named helper")
        XCTAssertNil(readOnly.tool(named: "create_agent"))
        XCTAssertNotNil(readOnly.tool(named: "list_agents"))
        XCTAssertNotNil(readOnly.tool(named: "shared_memory"))
        XCTAssertFalse(PromptCompiler.inferIntent("Use create_agent, but only explain; do not change any files").expectsMutation)
    }
}
