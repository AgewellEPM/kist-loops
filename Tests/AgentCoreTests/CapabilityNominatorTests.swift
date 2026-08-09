import XCTest
@testable import AgentCore

/// P2 — the deterministic capability nominator: a RECURRING, unresolved failure signature gets queued for a
/// future curriculum; a resolved one never is; nomination is PASSIVE (not rate-capped); the queue upserts.
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

    func testResolvedByLatestRowNeverReNominated() {
        for terminal in ["promoted", "rejected", "spec-handed-off"] {
            let history = [att("s|a", "attempted", 100), att("s|a", "attempted", 150), att("s|a", terminal, 200)]
            XCTAssertTrue(CapabilityNominator.nominate(history: history, now: 10_000).isEmpty,
                          "a signature whose LATEST row is ‘\(terminal)’ is settled — never re-nominate it")
        }
    }

    func testRecurAfterTerminalReNominates() {
        // review #15 semantics: resolved is decided by the LATEST row. A wall that recurs AFTER a terminal
        // outcome (latest row non-terminal) is NOT settled and may re-nominate.
        let history = [att("s|a", "rejected", 100), att("s|a", "attempted", 200), att("s|a", "attempted", 300)]
        let noms = CapabilityNominator.nominate(history: history, now: 10_000)
        XCTAssertEqual(noms.first?.signature, "s|a", "recurred after the terminal row → eligible again")
        XCTAssertEqual(noms.first?.recurrence, 2, "recurrence counts the two non-terminal rows")
    }

    func testBlockedCountsAsRecurrence() {
        let history = [att("s|a", "attempted", 100), att("s|a", "blocked", 150)]
        XCTAssertEqual(CapabilityNominator.nominate(history: history, now: 10_000).first?.recurrence, 2,
                       "attempted and blocked are both non-terminal recurrence signals")
    }

    func testNominationIsNotRateCapped() {
        // review #8: nomination is a PASSIVE observation; a saturated window (many recent attempts) must NOT
        // suppress recording a genuinely recurring wall. The anti-churn cap lives at ACTUATION, not here.
        let now = 1000.0
        let history = [att("other|b", "attempted", 990), att("other|c", "attempted", 995),
                       att("other|d", "attempted", 998),
                       att("self__zip|x", "attempted", 700), att("self__zip|x", "attempted", 800)]
        let noms = CapabilityNominator.nominate(history: history, now: now)
        XCTAssertTrue(noms.contains { $0.signature == "self__zip|x" && $0.recurrence == 2 },
                      "the recurring wall is still nominated despite a saturated window")
    }

    func testQueueUpsertsRecurrenceBySignature() {
        // review #11: a signature that recurs FURTHER updates its stored recurrence instead of being frozen.
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("kist-nom-\(UUID().uuidString)")
        let store = CapabilityNominationStore(projectRoot: root)
        func nom(_ r: Int) -> CapabilityNomination {
            CapabilityNomination(signature: "s|a", tool: "self__x", category: "toolLimit", recurrence: r, atEpoch: 1)
        }
        XCTAssertEqual(store.enqueue([nom(2)]).count, 1, "first enqueue writes it")
        XCTAssertEqual(store.enqueue([nom(2)]).count, 0, "equal recurrence is a no-op (no new info)")
        XCTAssertEqual(store.enqueue([nom(9)]).count, 1, "higher recurrence UPDATES the record")
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1, "still one row per signature (no duplicates)")
        XCTAssertEqual(loaded.first?.recurrence, 9, "the stored recurrence reflects the worst the wall got, not the first")
    }
}
