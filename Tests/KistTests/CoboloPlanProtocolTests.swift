import XCTest
import AgentCore
@testable import Kist

final class CoboloPlanProtocolTests: XCTestCase {
    private let prefix = """
    {
      "contract_id": "contract",
      "exploration_digest": "exploration",
      "revision": 0,
      "planner_identity": "codex-cli:gpt-5.6-sol",
      "upstream_plan_digest": null,
      "feedback_digest": null,
    """

    func testDecodesExactLiveObjectShapedPlanIntoCanonicalStrings() throws {
        let response = prefix + """
          "steps": [{"id":"create-source","action":"Write payroll.cbl"}],
          "acceptance_checks": [{"id":"compile","check":"cobc exits zero"}]
        }
        """
        let plan = try KistRunner.coboloDecodePlanResponse(response)
        XCTAssertEqual(plan.contractID, "contract")
        XCTAssertEqual(plan.plannerIdentity, "codex-cli:gpt-5.6-sol")
        XCTAssertEqual(plan.steps, ["create-source: Write payroll.cbl"])
        XCTAssertEqual(plan.acceptanceChecks, ["compile: cobc exits zero"])
    }

    func testAcceptsSingleJSONFenceAndStringArrays() throws {
        let response = """
        ```json
        \(prefix)
          "steps": ["Write payroll.cbl"],
          "acceptance_checks": ["cobc exits zero"]
        }
        ```
        """
        let plan = try KistRunner.coboloDecodePlanResponse(response)
        XCTAssertEqual(plan.steps, ["Write payroll.cbl"])
        XCTAssertEqual(plan.acceptanceChecks, ["cobc exits zero"])
    }

    func testRejectsUnknownObjectShapeAndExtraTopLevelKeys() {
        let wrongItem = prefix + """
          "steps": [{"id":"create-source","description":"wrong key"}],
          "acceptance_checks": ["cobc exits zero"]
        }
        """
        XCTAssertThrowsError(try KistRunner.coboloDecodePlanResponse(wrongItem))

        let extraKey = prefix + """
          "steps": ["Write payroll.cbl"],
          "acceptance_checks": ["cobc exits zero"],
          "unbound": true
        }
        """
        XCTAssertThrowsError(try KistRunner.coboloDecodePlanResponse(extraKey))
    }

    func testRejectsEmptyOversizedAndExcessiveItems() {
        let empty = prefix + """
          "steps": [""],
          "acceptance_checks": ["cobc exits zero"]
        }
        """
        XCTAssertThrowsError(try KistRunner.coboloDecodePlanResponse(empty))

        let oversized = String(repeating: "X", count: 4_097)
        let oversizedResponse = prefix + """
          "steps": ["\(oversized)"],
          "acceptance_checks": ["cobc exits zero"]
        }
        """
        XCTAssertThrowsError(try KistRunner.coboloDecodePlanResponse(oversizedResponse))

        let items = Array(repeating: "\"step\"", count: 17).joined(separator: ",")
        let excessive = prefix + """
          "steps": [\(items)],
          "acceptance_checks": ["cobc exits zero"]
        }
        """
        XCTAssertThrowsError(try KistRunner.coboloDecodePlanResponse(excessive))
    }

    func testNestedTargetRequiresExistingRealParentBeforeWork() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cobolo-parent-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let confined = try ConfinedRoot(root: rootURL.path)

        XCTAssertNoThrow(try KistRunner.coboloRequireExistingTargetParent(
            root: confined, target: "payroll.cbl"))
        XCTAssertThrowsError(try KistRunner.coboloRequireExistingTargetParent(
            root: confined, target: "examples/payroll.cbl")) { error in
            XCTAssertTrue(error.localizedDescription.contains("parent directory does not exist"))
        }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("examples"), withIntermediateDirectories: false)
        XCTAssertNoThrow(try KistRunner.coboloRequireExistingTargetParent(
            root: confined, target: "examples/payroll.cbl"))
    }
}
