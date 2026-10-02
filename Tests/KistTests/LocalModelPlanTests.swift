import XCTest
import AgentCore
@testable import Kist

final class LocalModelPlanTests: XCTestCase {
    func testDiagnosticFlagWorksWithWrapperFlagsAndMissingModelFails() {
        let opts = KistOptions.parse(["--roles", "truth-team", "--allow-read", "/Volumes",
                                     "--local-model-plan", "qwen2.5-coder:1.5b"])
        XCTAssertEqual(opts.localModelPlan, "qwen2.5-coder:1.5b")
        XCTAssertTrue(opts.optionErrors.isEmpty)
        XCTAssertFalse(KistOptions.parse(["--local-model-plan"]).optionErrors.isEmpty)
        XCTAssertFalse(KistOptions.parse(["--local-model-plan", "--auto"]).optionErrors.isEmpty)
        XCTAssertTrue(KistOptions.helpText.contains("--local-model-plan"))
    }

    func testMemoryFailureCanEscalateButAuthorityAndCancellationCannot() {
        let reason = "local model capacity unavailable: host memory pressure"
        XCTAssertTrue(KistRunner.localPlanningCanEscalate(AIProviderError.configuration(reason)))
        XCTAssertNotNil(KistRunner.buildLaneProviderFailure(AIProviderError.configuration(reason)))
        XCTAssertNotNil(KistREPL.modelSubstitutionReason(success: false, summary: reason))
        XCTAssertNil(KistREPL.modelSubstitutionReason(success: false, summary: "authorization denied; " + reason))
        XCTAssertNil(KistRunner.buildLaneProviderFailure(AIProviderError.configuration("permission denied")))
        XCTAssertNil(KistRunner.buildLaneProviderFailure(CancellationError()))
    }
}
