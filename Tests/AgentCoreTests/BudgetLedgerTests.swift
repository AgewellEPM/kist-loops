import XCTest
@testable import AgentCore

/// The token cost ceiling — measured tokens, hard cap, thread-safe.
final class BudgetLedgerTests: XCTestCase {

    // DeepSeek LOW: a double-commit (caller breaks the "commit once" contract) must NOT corrupt the
    // ledger — committing the same reservation id twice is ignored, so spend isn't double-booked and the
    // hold isn't over-released.
    func testDoubleCommitIsIgnored() async {
        let b = BudgetLedger(maxTokens: 1000, maxUSD: 10)
        let id = await b.reserve(tokens: 200, usd: 2)
        XCTAssertNotNil(id)
        await b.commit(reservation: id!, actualTokens: 150, actualUSD: 1.5)
        let spentAfterOne = await b.spentTokens()
        let usdAfterOne = await b.spentUSD()
        // A SECOND commit for the same (already-released) reservation id is a no-op.
        await b.commit(reservation: id!, actualTokens: 150, actualUSD: 1.5)
        let spentAfterTwo = await b.spentTokens()
        let usdAfterTwo = await b.spentUSD()
        XCTAssertEqual(spentAfterOne, 150)
        XCTAssertEqual(spentAfterTwo, 150, "double-commit must not double-book spend")
        XCTAssertEqual(usdAfterOne, 1.5, accuracy: 1e-9)
        XCTAssertEqual(usdAfterTwo, 1.5, accuracy: 1e-9, "double-commit must not double-book dollar spend")
        // Reserve room is correctly freed (one reservation, fully released), not over-released.
        let canReserveFull = await b.reserve(tokens: 850, usd: 8.5)
        XCTAssertNotNil(canReserveFull, "after one balanced reserve/commit the remaining room is correct")
    }

    func testUncappedNeverExceeds() async {
        let b = BudgetLedger(maxTokens: nil)
        await b.add(1_000_000)
        let exceeded = await b.isExceeded()
        let remaining = await b.remaining()
        XCTAssertFalse(exceeded)
        XCTAssertNil(remaining)
    }

    func testAccumulatesAndReportsRemaining() async {
        let b = BudgetLedger(maxTokens: 100)
        await b.add(30)
        await b.add(20)
        let spent = await b.spentTokens()
        let remaining = await b.remaining()
        XCTAssertEqual(spent, 50)
        XCTAssertEqual(remaining, 50)
        let exceeded = await b.isExceeded()
        XCTAssertFalse(exceeded)
    }

    func testExceededAtCap() async {
        let b = BudgetLedger(maxTokens: 100)
        await b.add(100)
        let exceeded = await b.isExceeded()
        let remaining = await b.remaining()
        XCTAssertTrue(exceeded)            // >= cap
        XCTAssertEqual(remaining, 0)       // never negative
    }

    func testZeroBudgetExceededImmediately() async {
        let b = BudgetLedger(maxTokens: 0)
        let exceeded = await b.isExceeded()
        XCTAssertTrue(exceeded)
    }

    func testNegativeAddsIgnored() async {
        let b = BudgetLedger(maxTokens: 100)
        await b.add(-50)
        let spent = await b.spentTokens()
        XCTAssertEqual(spent, 0)
    }

    func testEstimateFallback() {
        let e = TokenUsage.estimate(promptChars: 400, completionChars: 80)
        XCTAssertEqual(e.promptTokens, 100)     // ~4 chars/token
        XCTAssertEqual(e.completionTokens, 20)
        XCTAssertEqual(e.total, 120)
    }
}
