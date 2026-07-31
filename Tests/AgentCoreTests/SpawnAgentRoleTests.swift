import XCTest
@testable import AgentCore

final class SpawnAgentRoleTests: XCTestCase {
    func testAdvertisedCompositeRolesResolve() {
        XCTAssertEqual(SpawnAgentTool.parseRole("worker/researcher"), .worker)
        XCTAssertEqual(SpawnAgentTool.parseRole("coder/builder"), .coder)
        XCTAssertEqual(SpawnAgentTool.parseRole("critic/reviewer"), .critic)
        XCTAssertEqual(SpawnAgentTool.parseRole("planner"), .planner)
    }

    func testSingleAliasesAndCasingStillResolve() {
        XCTAssertEqual(SpawnAgentTool.parseRole("Critic"), .critic)
        XCTAssertEqual(SpawnAgentTool.parseRole("  REVIEWER "), .critic)
        XCTAssertEqual(SpawnAgentTool.parseRole("dev"), .coder)
        XCTAssertEqual(SpawnAgentTool.parseRole("researcher"), .worker)
    }

    func testUnknownAndMixedCompositeRolesAreRejected() {
        XCTAssertNil(SpawnAgentTool.parseRole("wizard"))
        XCTAssertNil(SpawnAgentTool.parseRole("wizard/critic"))
        XCTAssertNil(SpawnAgentTool.parseRole("critic/coder"))
        XCTAssertNil(SpawnAgentTool.parseRole("not critic"))
        XCTAssertNil(SpawnAgentTool.parseRole("critic,reviewer"))
        XCTAssertNil(SpawnAgentTool.parseRole(nil))
        XCTAssertNil(SpawnAgentTool.parseRole(""))
    }
}
