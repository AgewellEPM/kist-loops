import XCTest
@testable import AgentCore

final class SelfHealHandoffTests: XCTestCase {
    func testParsesFencedHandoffBlock() throws {
        let summary = """
        Here is my analysis. Root cause found.

        ```handoff
        {
          "from": "self-heal-researcher",
          "to": "self-heal-builder",
          "task_id": 3,
          "root_cause": "Generic exception handler hides the failure type.",
          "confidence": 0.92,
          "target_files": ["Sources/Foo/teach_relation.swift"],
          "repair_spec": "Replace broad catch with typed handlers.",
          "reproduction_command": "swift test --filter AuthzTests",
          "verification_commands": ["swift test --filter AuthzTests", "git diff --check"],
          "blocked": false
        }
        ```
        """
        let h = try XCTUnwrap(SelfHealHandoff.parse(from: summary))
        XCTAssertEqual(h.rootCause, "Generic exception handler hides the failure type.")
        XCTAssertEqual(h.confidence, 0.92, accuracy: 0.001)
        XCTAssertEqual(h.targetFiles, ["Sources/Foo/teach_relation.swift"])
        XCTAssertEqual(h.taskId, 3)
        XCTAssertTrue(h.isActionable)
        XCTAssertTrue(h.builderBrief().contains("Do NOT research"))
        XCTAssertTrue(h.builderBrief().contains("Replace broad catch"))
    }

    func testNormalizesPercentConfidence() throws {
        let s = "```json\n{\"root_cause\":\"x\",\"repair_spec\":\"y\",\"confidence\":\"92%\",\"target_files\":[]}\n```"
        let h1 = try XCTUnwrap(SelfHealHandoff.parse(from: s))
        XCTAssertEqual(h1.confidence, 0.92, accuracy: 0.001)
        let s2 = "```json\n{\"root_cause\":\"x\",\"repair_spec\":\"y\",\"confidence\":92,\"target_files\":[]}\n```"
        let h2 = try XCTUnwrap(SelfHealHandoff.parse(from: s2))
        XCTAssertEqual(h2.confidence, 0.92, accuracy: 0.001)
    }

    func testBlockedHandoffIsNotActionable() {
        let s = "```handoff\n{\"root_cause\":\"unknown\",\"repair_spec\":\"\",\"confidence\":0.1,\"target_files\":[],\"blocked\":true,\"blocked_reason\":\"cannot reproduce\"}\n```"
        let h = SelfHealHandoff.parse(from: s)
        XCTAssertEqual(h?.blocked, true)
        XCTAssertFalse(h?.isActionable ?? true)
    }

    func testNoHandoffReturnsNil() {
        XCTAssertNil(SelfHealHandoff.parse(from: "I did a lot of research but produced no handoff block."))
    }

    func testFallbackParsesBareJSONObject() {
        let s = "Result: {\"root_cause\":\"race\",\"repair_spec\":\"add lock\",\"confidence\":0.8,\"target_files\":[\"a.swift\"]}"
        let h = SelfHealHandoff.parse(from: s)
        XCTAssertEqual(h?.repairSpec, "add lock")
        XCTAssertTrue(h?.isActionable ?? false)
    }
}
