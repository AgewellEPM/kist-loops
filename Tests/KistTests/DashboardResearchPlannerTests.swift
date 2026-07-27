import XCTest
import AgentCore
@testable import Kist

final class DashboardResearchPlannerTests: XCTestCase {
    func testKistOrchestrationContextProducesResearchDebtAndQuestions() {
        let plan = Plan(
            title: "Kist Captain",
            tasks: [
                PlanTask(id: 1, title: "ACTION: wire Captain orchestration",
                         detail: "assign best models to workers and gate the swarm",
                         kind: .action),
                PlanTask(id: 2, title: "TEST: add benchmark learning loop",
                         detail: "promote models from eval evidence",
                         kind: .test)
            ]
        )

        let bundle = DashboardResearchPlanner.build(for: plan,
                                                    projectRoot: "/tmp/kist-loops",
                                                    trajectory: [ActionRecord(tool: "read_file",
                                                                              argsFingerprint: "a",
                                                                              success: true)])

        XCTAssertTrue(bundle.research.contains { $0.title == "Study Claude Code's fleet scheduling" })
        XCTAssertTrue(bundle.research.contains { $0.title == "Analyze Cursor background agents" })
        XCTAssertTrue(bundle.research.contains { $0.title == "Read Apple Foundation Models docs" })
        XCTAssertTrue(bundle.research.contains { $0.title == "Study DGM self-improvement architecture" })
        XCTAssertTrue(bundle.knowledgeDebt.contains { $0.topic == "Apple Foundation Models" })
        XCTAssertTrue(bundle.knowledgeDebt.contains { $0.topic == "DGM evolution architecture" })
        XCTAssertTrue(bundle.questions.contains { $0.contains("benchmark and live-eval signals") })
        XCTAssertEqual(bundle.observation?.expectedROI, "High")
    }

    func testExplicitResearchTasksArePromotedIntoQueue() {
        let plan = Plan(
            tasks: [
                PlanTask(id: 1,
                         title: "RESEARCH: compare MCP permission models",
                         detail: "Need to understand lifecycle and background workers",
                         status: .inProgress,
                         kind: .research,
                         link: "Anthropic MCP docs"),
                PlanTask(id: 2, title: "ACTION: implement permission gate", kind: .action)
            ]
        )

        let bundle = DashboardResearchPlanner.build(for: plan,
                                                    projectRoot: "/tmp/tooling",
                                                    trajectory: [])

        XCTAssertEqual(bundle.research.first?.title, "compare MCP permission models")
        XCTAssertEqual(bundle.research.first?.priority, .high)
        XCTAssertEqual(bundle.research.first?.visit, "Anthropic MCP docs")
        XCTAssertTrue(bundle.summaryLine?.contains("compare MCP permission models") == true)
    }

    func testPendingResearchDoesNotDisplaceContextSpecificResearch() {
        let plan = Plan(
            title: "Kist Captain",
            tasks: [
                PlanTask(id: 1,
                         title: "RESEARCH: Research React clock app examples",
                         detail: "Stale project research from an older board item",
                         kind: .research),
                PlanTask(id: 2,
                         title: "ACTION: wire Captain orchestration",
                         detail: "fleet worker model routing and background agents",
                         kind: .action)
            ]
        )

        let bundle = DashboardResearchPlanner.build(for: plan,
                                                    projectRoot: "/tmp/kist-loops",
                                                    trajectory: [])

        XCTAssertEqual(bundle.research.first?.title, "Study Claude Code's fleet scheduling")
        XCTAssertFalse(bundle.research.prefix(3).contains { $0.title == "Research React clock app examples" })
    }
}
