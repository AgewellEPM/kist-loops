import XCTest
@testable import AgentCore

final class AskUserToolTests: XCTestCase {
    private struct StubInteractor: RuntimeInteractor {
        let answer: String
        func requestApproval(planSummary: String) async -> Bool { true }
        func requestInput(question: String) async -> String { answer }
    }
    private let ctx = ToolContext(projectRoot: NSTemporaryDirectory())

    func testReturnsUserAnswer() async throws {
        let tool = AskUserTool(interactor: StubInteractor(answer: "use postgres"))
        let r = try await tool.execute(arguments: ["question": "which database?", "options": "postgres, sqlite"], context: ctx)
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("use postgres"))
    }

    func testNonInteractiveReturnsProceedNote() async throws {
        let tool = AskUserTool(interactor: AutoApproveInteractor())   // requestInput → ""
        let r = try await tool.execute(arguments: ["question": "which database?"], context: ctx)
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("best judgment"))            // doesn't block autopilot
    }

    func testEmptyQuestionFails() async throws {
        let r = try await AskUserTool(interactor: AutoApproveInteractor()).execute(arguments: [:], context: ctx)
        XCTAssertFalse(r.success)
    }

    func testAskUserIsClassifiedSafe() {
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "ask_user", args: ["question": "x"], projectRoot: "/tmp"), .safe)
    }

    // The loop injects ask_user, so it appears in both protocols' advertised tool surface.
    func testAskUserAppearsInRegistryAfterAdding() {
        let reg = ToolRegistry.headless().adding(AskUserTool(interactor: AutoApproveInteractor()))
        XCTAssertNotNil(reg.tool(named: "ask_user"))
    }
}
