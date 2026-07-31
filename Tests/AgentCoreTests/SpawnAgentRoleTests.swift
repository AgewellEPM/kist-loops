import XCTest
@testable import AgentCore

/// Regression: the spawn_agent tool ADVERTISES composite role names ("worker/researcher",
/// "coder/builder", "critic/reviewer") in its description AND its error message — but parseRole only
/// accepted the single synonyms, so the model passing the advertised form got "unknown sub-agent role
/// 'critic/reviewer'. Use … critic/reviewer" (rejecting the exact name it lists). This pins that every
/// advertised form now resolves.
final class SpawnAgentRoleTests: XCTestCase {

    func testAdvertisedCompositeRolesResolve() {
        XCTAssertEqual(SpawnAgentTool.parseRole("worker/researcher"), .worker)
        XCTAssertEqual(SpawnAgentTool.parseRole("coder/builder"), .coder)
        XCTAssertEqual(SpawnAgentTool.parseRole("critic/reviewer"), .critic)
        XCTAssertEqual(SpawnAgentTool.parseRole("planner"), .planner)
    }

    func testSingleSynonymsAndCasingStillResolve() {
        XCTAssertEqual(SpawnAgentTool.parseRole("Critic"), .critic)
        XCTAssertEqual(SpawnAgentTool.parseRole("  REVIEWER "), .critic)
        XCTAssertEqual(SpawnAgentTool.parseRole("dev"), .coder)
        XCTAssertEqual(SpawnAgentTool.parseRole("researcher"), .worker)
    }

    func testUnknownStillRejectedAndNilPassthrough() {
        XCTAssertNil(SpawnAgentTool.parseRole("wizard"))
        XCTAssertNil(SpawnAgentTool.parseRole(nil))
        XCTAssertNil(SpawnAgentTool.parseRole(""))
    }
}
