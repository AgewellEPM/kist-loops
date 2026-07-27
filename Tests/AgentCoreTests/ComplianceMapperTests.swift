import XCTest
@testable import AgentCore

final class ComplianceMapperTests: XCTestCase {

    func testCoversTheAgenticTop10() {
        // At least the 10 numbered OWASP agentic risks are present.
        let numbered = ComplianceMapper.controls.filter { $0.risk.hasPrefix("AAI0") || $0.risk.hasPrefix("AAI1") }
        XCTAssertGreaterThanOrEqual(numbered.count, 10)
    }

    func testEverySatisfiedControlHasEvidence() {
        // Honesty: a "satisfied" claim must point at a real mechanism. No evidence ⇒ can't be satisfied.
        for c in ComplianceMapper.controls where c.status == .satisfied {
            XCTAssertFalse(c.evidence.isEmpty, "\(c.risk) claims satisfied but has no evidence")
        }
    }

    func testEveryGapOrPartialNamesTheResidualRisk() {
        for c in ComplianceMapper.controls where c.status != .satisfied {
            XCTAssertNotNil(c.gap, "\(c.risk) is \(c.status.rawValue) but names no gap")
        }
    }

    func testReportRendersCountsAndKnownGap() {
        let r = ComplianceMapper.report()
        XCTAssertTrue(r.contains("OWASP Top-10 Agentic"))
        XCTAssertTrue(r.contains("AAI07 Unverified"))   // our moat control is present
        XCTAssertTrue(r.contains("Identity Abuse"))     // the honest gap is shown
    }
}
