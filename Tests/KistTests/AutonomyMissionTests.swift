import Foundation
import XCTest
@testable import AgentCore
@testable import Kist

final class AutonomyMissionTests: XCTestCase {
    func testMissionIsAnAutopilotSandboxedMode() {
        unsetenv("KIST_ACTIVE")
        let options = KistOptions.parse(["--mission", "fix the captain loop"])

        XCTAssertTrue(options.mission)
        XCTAssertTrue(options.auto)
        XCTAssertTrue(options.yolo)
        XCTAssertTrue(options.allowShell)
        XCTAssertTrue(options.sandbox)
        XCTAssertEqual(options.goal, "fix the captain loop")
    }

    func testIndependentReviewRejectsSameProviderAndModel() {
        let deepseek = ProviderBinding(providerId: "deepseek", model: "reasoner")
        XCTAssertNil(KistRunner.independentReviewIdentities(builder: deepseek, reviewer: deepseek))

        let critic = ProviderBinding(providerId: "zhipu", model: "glm-5")
        let identities = KistRunner.independentReviewIdentities(builder: deepseek, reviewer: critic)
        XCTAssertEqual(identities?.builder, "deepseek:reasoner")
        XCTAssertEqual(identities?.reviewer, "zhipu:glm-5")
    }

    func testReceiptLineUsesTheRuntimeContract() throws {
        let line = try XCTUnwrap(KistRunner.autonomyReceiptLine(
            prefix: "KIST_OBJECTIVE_RECEIPT:",
            payload: [
                "receiptType": "kist.objective-stages",
                "schemaVersion": 1,
                "stages": [["name": "verify", "status": "passed"]],
            ]
        ))
        XCTAssertTrue(line.hasPrefix("KIST_OBJECTIVE_RECEIPT: "))
        let json = String(line.dropFirst("KIST_OBJECTIVE_RECEIPT: ".count))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["receiptType"] as? String, "kist.objective-stages")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }
}
