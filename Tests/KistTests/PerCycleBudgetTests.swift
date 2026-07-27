import XCTest
@testable import Kist

/// The great-loop's per-cycle token budget. The captain over-spend fix once used a rigid total/maxCycles
/// fair share — which STARVED cycles: a cycle died mid-work (created files, no budget left to build/test)
/// and the next cycle restarted from scratch, so a task never converged even with budget to spare. The
/// budget is now an even share of what REMAINS across the cycles LEFT: cycle 0 still can't eat everything
/// (captain guard), but unspent budget flows forward and the LAST cycle can finish with all that's left.
final class PerCycleBudgetTests: XCTestCase {

    func testFirstCycleGetsEvenShareNotEverything() {
        // Cycle 0 of 4 with 400k left → 100k (not the whole 400k) — the captain over-spend guard holds.
        XCTAssertEqual(KistRunner.perCycleBudget(remaining: 400_000, cycleIndex: 0, maxCycles: 4), 100_000)
    }

    func testLastCycleCanSpendAllRemaining() {
        // Cycle 3 of 4 (one cycle left) with 300k unspent → gets all 300k, NOT capped to 100k fair-share.
        // This is the anti-starvation win: a nearly-done task can finish in the final cycle.
        XCTAssertEqual(KistRunner.perCycleBudget(remaining: 300_000, cycleIndex: 3, maxCycles: 4), 300_000)
    }

    func testUnspentBudgetFlowsForward() {
        // If early cycles were cheap, the mid cycle's even share grows (500k over the 2 remaining cycles).
        XCTAssertEqual(KistRunner.perCycleBudget(remaining: 500_000, cycleIndex: 2, maxCycles: 4), 250_000)
    }

    func testFlooredButNeverAboveRemaining() {
        // The floor guarantees a workable budget…
        XCTAssertEqual(KistRunner.perCycleBudget(remaining: 500_000, cycleIndex: 0, maxCycles: 20, floor: 60_000), 60_000)
        // …but never exceeds what's actually left (a nearly-drained budget isn't inflated to the floor).
        XCTAssertEqual(KistRunner.perCycleBudget(remaining: 30_000, cycleIndex: 0, maxCycles: 4, floor: 60_000), 30_000)
    }

    func testZeroRemainingIsZero() {
        XCTAssertEqual(KistRunner.perCycleBudget(remaining: 0, cycleIndex: 1, maxCycles: 4), 0)
    }

    func testCycleIndexBeyondMaxDoesNotDivideByZero() {
        // Defensive: an index at/over maxCycles still yields the full remaining (cyclesLeft floored at 1).
        XCTAssertEqual(KistRunner.perCycleBudget(remaining: 120_000, cycleIndex: 9, maxCycles: 4), 120_000)
    }
}
