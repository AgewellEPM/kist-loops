import XCTest
@testable import AgentCore

final class A2AAgentCardTests: XCTestCase {
    func testKistAgentCardAdvertisesCoreSkills() throws {
        let card = KistA2A.agentCard(version: "test")

        XCTAssertEqual(card.name, "Kist / Mythos")
        XCTAssertTrue(card.skills.contains { $0.id == "plan-execute" })
        XCTAssertTrue(card.skills.contains { $0.id == "fleet" })
        XCTAssertTrue(card.skills.contains { $0.id == "computer-verify" })
        XCTAssertTrue(card.jsonString().contains("\"skills\""))
    }

    func testTaskEnvelopeCarriesGoalAndRole() {
        let task = A2ATaskEnvelope(taskId: "t1", goal: "review this", role: "critic", createdAtEpoch: 1)

        XCTAssertEqual(task.taskId, "t1")
        XCTAssertEqual(task.goal, "review this")
        XCTAssertEqual(task.role, "critic")
    }
}
