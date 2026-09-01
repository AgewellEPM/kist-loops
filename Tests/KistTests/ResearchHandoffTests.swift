import XCTest
@testable import Kist

final class ResearchHandoffTests: XCTestCase {
    func testCouncilDecisionPrecedesAndOutweighsBoundedResearchDossier() throws {
        let finalPlan = String(repeating: "p", count: 4_000) + "plan-tail"
        let dossier = String(repeating: "d", count: 2_000) + "dossier-tail"

        let summary = try XCTUnwrap(KistRunner.researchHandoffSummary(
            councilFinalPlan: finalPlan, dossier: dossier))
        let councilRange = try XCTUnwrap(summary.range(of: "Council decision (advisory result):"))
        let dossierRange = try XCTUnwrap(summary.range(of: "Research dossier (advisory evidence):"))

        XCTAssertLessThan(councilRange.lowerBound, dossierRange.lowerBound)
        XCTAssertLessThan(summary.count, 4_000)
        XCTAssertTrue(summary.contains(String(repeating: "p", count: 2_800)))
        XCTAssertFalse(summary.contains(String(repeating: "p", count: 2_801)))
        XCTAssertTrue(summary.hasSuffix(String(repeating: "d", count: 1_000)))
        XCTAssertFalse(summary.hasSuffix(String(repeating: "d", count: 1_001)))
        XCTAssertFalse(summary.contains("plan-tail"))
        XCTAssertFalse(summary.contains("dossier-tail"))
    }

    func testResearchHandoffSummaryRejectsEmptyResultContext() {
        XCTAssertNil(KistRunner.researchHandoffSummary(
            councilFinalPlan: " \n", dossier: "\t"))
    }
}
