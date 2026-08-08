import XCTest
@testable import AgentCore

/// P2 — the deterministic capability nominator: a RECURRING, unresolved failure signature gets queued for a
/// future curriculum; a resolved one never is; the queue is idempotent.
final class CapabilityNominatorTests: XCTestCase {

    private func att(_ sig: String, _ outcome: String, _ epoch: Double, tool: String = "self__x", cat: String = "toolLimit") -> SelfEvolutionAttempt {
        SelfEvolutionAttempt(tool: tool, category: cat, signature: sig, outcome: outcome, atEpoch: epoch)
    }

    func testRecurringUnresolvedSignatureIsNominated() {
        let now = 10_000.0
        let history = [att("self__zip|unknown", "attempted", 100), att("self__zip|unknown", "attempted", 200)]
        let noms = CapabilityNominator.nominate(history: history, now: now)
        XCTAssertEqual(noms.count, 1)
        XCTAssertEqual(noms.first?.signature, "self__zip|unknown")
        XCTAssertEqual(noms.first?.recurrence, 2)
        XCTAssertEqual(noms.first?.atEpoch, now, "nominated-at uses the injected now, not a smuggled clock")
    }

    func testBelowThresholdNotNominated() {
        let noms = CapabilityNominator.nominate(history: [att("s|a", "attempted", 100)], now: 10_000)
        XCTAssertTrue(noms.isEmpty, "a single occurrence is not a recurring wall")
    }

    func testResolvedSignatureNeverReNominated() {
        for terminal in ["promoted", "rejected", "spec-handed-off"] {
            let history = [att("s|a", "attempted", 100), att("s|a", "attempted", 150), att("s|a", terminal, 200)]
            XCTAssertTrue(CapabilityNominator.nominate(history: history, now: 10_000).isEmpty,
                          "a ‘\(terminal)’ signature is settled — never re-nominate it")
        }
    }

    func testBlockedCountsAsRecurrenceButAttemptedDrivesIt() {
        // attempted + blocked are both non-terminal recurrence signals.
        let history = [att("s|a", "attempted", 100), att("s|a", "blocked", 150)]
        let noms = CapabilityNominator.nominate(history: history, now: 10_000)
        XCTAssertEqual(noms.first?.recurrence, 2, "attempted and blocked both count toward recurrence")
    }

    func testGlobalRateCapDefersTheBatch() {
        // 3 recent attempts across signatures hit the global cap (default 3/hr) → decideShouldAttempt says no →
        // nomination DEFERS (queues for next pass), it does not drop the recurring signature.
        let now = 1000.0
        let history = [att("s|a", "attempted", 990), att("s|a", "attempted", 995),
                       att("other|b", "attempted", 998)]   // 3 within the window
        let noms = CapabilityNominator.nominate(history: history, now: now, windowSeconds: 3600)
        XCTAssertTrue(noms.isEmpty, "at the global rate cap the batch defers rather than churning")
    }

    func testQueueIsIdempotentBySignature() {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("kist-nom-\(UUID().uuidString)")
        let store = CapabilityNominationStore(projectRoot: root)
        let n = CapabilityNomination(signature: "s|a", tool: "self__x", category: "toolLimit", recurrence: 2, atEpoch: 1)
        XCTAssertEqual(store.enqueueNew([n]).count, 1, "first enqueue writes it")
        XCTAssertEqual(store.enqueueNew([n]).count, 0, "re-enqueuing the same signature is a no-op (idempotent)")
        XCTAssertEqual(store.load().count, 1, "no duplicate rows for one signature")
    }
}
