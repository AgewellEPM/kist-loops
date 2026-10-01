import XCTest
@testable import Kist

final class PlanSearchOptionsTests: XCTestCase {
    func testDefaultAndExplicitSearchWidth() {
        XCTAssertEqual(KistOptions.parse(["--plan-execute", "build it"]).planCandidates, 2)
        XCTAssertEqual(KistOptions.parse(["--plan-candidates", "1", "build it"]).planCandidates, 1)
        XCTAssertEqual(KistOptions.parse(["--plan-candidates", "4", "build it"]).planCandidates, 4)
        XCTAssertTrue(KistOptions.helpText.contains("--plan-candidates <1...4>"))
    }
    func testInvalidWidthFailsClosed() {
        for value in ["0", "5", "-1", "oops"] {
            XCTAssertFalse(KistOptions.parse(["--plan-candidates", value]).optionErrors.isEmpty)
        }
        XCTAssertFalse(KistOptions.parse(["--plan-candidates"]).optionErrors.isEmpty)
    }
}
