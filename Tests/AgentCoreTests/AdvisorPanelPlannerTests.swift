import XCTest
@testable import AgentCore

final class AdvisorPanelPlannerTests: XCTestCase {
    private let catalog = BuiltinSpecialists.all

    func testPicksCatalogNamesFromModelOutput() async {
        let names = await AdvisorPanelPlanner.classify(task: "help me toast the bride at a wedding",
                                                       catalog: catalog, limit: 2) { _, _ in "comedian, copywriter" }
        XCTAssertEqual(names, ["comedian", "copywriter"])
    }

    func testNoneReplyYieldsEmpty() async {
        let names = await AdvisorPanelPlanner.classify(task: "prove the Riemann hypothesis",
                                                       catalog: catalog) { _, _ in "NONE" }
        XCTAssertTrue(names.isEmpty)
    }

    /// A hallucinated (non-catalog) name is DROPPED — the classifier can never convene a persona that isn't real.
    func testHallucinatedNamesAreDropped() async {
        let names = await AdvisorPanelPlanner.classify(task: "x", catalog: catalog, limit: 3) { _, _ in
            "beekeeping-expert, comedian, totally-made-up"
        }
        XCTAssertEqual(names, ["comedian"])
    }

    func testStripsListFormattingPunctuation() async {
        let names = await AdvisorPanelPlanner.classify(task: "x", catalog: catalog, limit: 2) { _, _ in "- comedian.\n- copywriter" }
        XCTAssertEqual(names, ["comedian", "copywriter"])
    }

    func testRespectsLimit() async {
        let names = await AdvisorPanelPlanner.classify(task: "x", catalog: catalog, limit: 1) { _, _ in
            "comedian, copywriter, prose-editor"
        }
        XCTAssertEqual(names, ["comedian"])
    }

    func testProviderFailureFailsOpenToEmpty() async {
        let names = await AdvisorPanelPlanner.classify(task: "x", catalog: catalog) { _, _ in nil }
        XCTAssertTrue(names.isEmpty)
    }

    func testEmptyTaskOrEmptyCatalogYieldsEmpty() async {
        let a = await AdvisorPanelPlanner.classify(task: "   ", catalog: catalog) { _, _ in "comedian" }
        XCTAssertTrue(a.isEmpty)
        let b = await AdvisorPanelPlanner.classify(task: "joke", catalog: []) { _, _ in "comedian" }
        XCTAssertTrue(b.isEmpty)
    }
}
