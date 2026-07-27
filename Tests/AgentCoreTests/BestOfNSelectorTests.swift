import XCTest
@testable import AgentCore

/// Phase 3.1 — execution-based best-of-N selection: keep the attempt that PASSED, never the model's pick.
final class BestOfNSelectorTests: XCTestCase {
    private func a(_ v: Bool, _ q: Int) -> BestOfNSelector.Attempt { .init(verified: v, quality: q) }

    func testPicksHighestQualityVerified() {
        XCTAssertEqual(BestOfNSelector.pick([a(false, 99), a(true, 40), a(true, 80)]), 2)
    }
    func testNilWhenNoneVerified() {
        XCTAssertNil(BestOfNSelector.pick([a(false, 90), a(false, 100)]), "unverified best-of-N is still not done")
    }
    func testTiesGoToEarliest() {
        XCTAssertEqual(BestOfNSelector.pick([a(true, 70), a(true, 70)]), 0)
    }
    func testVerifiedCount() {
        XCTAssertEqual(BestOfNSelector.verifiedCount([a(true, 1), a(false, 1), a(true, 1)]), 2)
    }
    func testEmptyIsNil() { XCTAssertNil(BestOfNSelector.pick([])) }
}
