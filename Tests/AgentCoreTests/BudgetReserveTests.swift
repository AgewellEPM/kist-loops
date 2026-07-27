import XCTest
import Foundation
@testable import AgentCore

/// Sprint 3 / C2 — atomic reserve-before-spend. Closes the TOCTOU the council/Codex flagged: under a
/// shared fleet ledger two parallel workers can't both pass a check and both overspend, because the
/// first worker's RESERVATION is already counted against the second's reserve().
///
/// `reserve` now returns a RESERVATION ID (nil = denied) and `commit(reservation:)` consumes that
/// specific id — so a double-commit can't corrupt the ledger even with multiple live reservations.
final class BudgetReserveTests: XCTestCase {

    // The core guarantee: a second reservation that would breach the cap is DENIED even though
    // nothing has been spent/committed yet (the parallel-overspend window is closed).
    func testParallelReservationsCannotBothPassTheCap() async {
        let b = BudgetLedger(maxTokens: 100)
        let first = await b.reserve(tokens: 60, usd: 0)
        XCTAssertNotNil(first, "first worker reserves 60/100")
        let second = await b.reserve(tokens: 60, usd: 0)
        XCTAssertNil(second, "second worker's 60 would make 120 > 100 — DENIED before spending")
        // Spent is still 0 (reservations aren't spend) but the cap is protected.
        let spent = await b.spentTokens(); XCTAssertEqual(spent, 0)
    }

    func testCommitReleasesReservationAndBooksActual() async {
        let b = BudgetLedger(maxTokens: 100)
        let id = await b.reserve(tokens: 60, usd: 0.30)
        XCTAssertNotNil(id)
        await b.commit(reservation: id!, actualTokens: 40, actualUSD: 0.20)
        let spent = await b.spentTokens(); XCTAssertEqual(spent, 40, "actual booked")
        let usd = await b.spentUSD(); XCTAssertEqual(usd, 0.20, accuracy: 1e-9)
        // Reservation released → a fresh 60 now fits (40 spent + 60 = 100, not over).
        let again = await b.reserve(tokens: 60, usd: 0); XCTAssertNotNil(again, "released hold frees headroom")
    }

    func testReserveHonorsDollarCap() async {
        let b = BudgetLedger(maxUSD: 0.50)
        let a = await b.reserve(tokens: 0, usd: 0.40); XCTAssertNotNil(a)
        let c = await b.reserve(tokens: 0, usd: 0.20); XCTAssertNil(c, "0.40 + 0.20 > 0.50 — denied")
    }

    func testUncappedAlwaysReserves() async {
        let b = BudgetLedger()
        let a = await b.reserve(tokens: 9_999_999, usd: 9999); XCTAssertNotNil(a)
        let c = await b.reserve(tokens: 9_999_999, usd: 9999); XCTAssertNotNil(c)
    }

    // Error-path: a failed call commits with actual 0 → the hold is released, headroom restored.
    func testFailedCallReleasesHold() async {
        let b = BudgetLedger(maxTokens: 100)
        let held = await b.reserve(tokens: 90, usd: 0)
        XCTAssertNotNil(held)
        let blocked = await b.reserve(tokens: 90, usd: 0); XCTAssertNil(blocked, "held 90 blocks a second 90")
        await b.commit(reservation: held!, actualTokens: 0, actualUSD: 0)   // call failed
        let freed = await b.reserve(tokens: 90, usd: 0); XCTAssertNotNil(freed, "after release, 90 fits again")
    }

    // A reservation that exactly fills the cap is allowed (> breach, not >=); the NEXT one is denied.
    func testReserveBoundary() async {
        let b = BudgetLedger(maxTokens: 100)
        let atCap = await b.reserve(tokens: 100, usd: 0); XCTAssertNotNil(atCap, "exactly at cap is allowed")
        let over = await b.reserve(tokens: 1, usd: 0); XCTAssertNil(over, "one more is denied")
    }

    // Codex: the double-commit guard must be per-reservation, not a global counter — with TWO live
    // reservations, double-committing ONE must not double-book spend or over-release the other's hold.
    func testDoubleCommitOfOneReservationWithAnotherLiveDoesNotDoubleBook() async {
        let b = BudgetLedger(maxTokens: 1000, maxUSD: 10)
        let a = await b.reserve(tokens: 100, usd: 1); XCTAssertNotNil(a)
        let c = await b.reserve(tokens: 200, usd: 2); XCTAssertNotNil(c)   // B stays live
        await b.commit(reservation: a!, actualTokens: 80, actualUSD: 0.8)
        let spent1 = await b.spentTokens(); let usd1 = await b.spentUSD()
        // Double-commit A while B is still outstanding — must be a no-op (the counter bug Codex caught).
        await b.commit(reservation: a!, actualTokens: 80, actualUSD: 0.8)
        let spent2 = await b.spentTokens(); let usd2 = await b.spentUSD()
        XCTAssertEqual(spent1, 80)
        XCTAssertEqual(spent2, 80, "double-commit of A must NOT double-book, even with B live")
        XCTAssertEqual(usd1, 0.8, accuracy: 1e-9)
        XCTAssertEqual(usd2, 0.8, accuracy: 1e-9, "double-commit of A must NOT double-book dollars")
        // B's hold must STILL reduce capacity after A's double-commit — prove it wasn't over-released
        // (Codex: 1000 cap − 80 spent − 200 held by B = 720 headroom, so 721 must be DENIED).
        let probe = await b.reserve(tokens: 721, usd: 0)
        XCTAssertNil(probe, "B's 200-token hold must still reduce capacity after A's double-commit")
        // B's hold is intact: committing B books exactly its actual, not A's re-released amount.
        await b.commit(reservation: c!, actualTokens: 150, actualUSD: 1.5)
        let spentFinal = await b.spentTokens(); XCTAssertEqual(spentFinal, 230, "80 (A) + 150 (B), no corruption")
    }
}
