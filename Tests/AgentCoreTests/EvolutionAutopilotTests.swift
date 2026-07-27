import XCTest
@testable import AgentCore

/// Pins the cross-session autopilot's SAFETY brain: it is FAIL-CLOSED. It must refuse to run unless
/// explicitly armed AND within every bound (time, sessions, cumulative budget, global stagnation). A bug
/// here could let an autonomous loop spend unbounded money over days — so every gate is tested.
final class EvolutionAutopilotTests: XCTestCase {

    private func arming(objective: String = "improve X", budget: Int = 100_000, sessions: Int = 10,
                        expires: Double = 1_000_000, gens: Int = 2, patience: Int = 0) -> EvolutionArming {
        EvolutionArming(objective: objective, cumulativeBudgetTokens: budget, maxSessions: sessions,
                        expiresAtEpoch: expires, armedAtEpoch: 0, generationsPerSession: gens, stagnationPatience: patience)
    }

    // THE default: no arming file ⇒ never runs.
    func testDisarmedNeverRuns() {
        let d = EvolutionRunController.decide(arming: nil, state: .init(), nowEpoch: 0, perSessionBudgetCap: 50_000)
        XCTAssertFalse(d.shouldRun)
        XCTAssertEqual(d.sessionBudgetTokens, 0)
        XCTAssertTrue(d.reason.contains("DISARMED"))
    }

    func testExpiredRefuses() {
        let d = EvolutionRunController.decide(arming: arming(expires: 500), state: .init(), nowEpoch: 600, perSessionBudgetCap: 10_000)
        XCTAssertFalse(d.shouldRun); XCTAssertTrue(d.reason.contains("EXPIRED"))
    }

    func testSessionCeilingRefuses() {
        let state = EvolutionRunState(sessionsRun: 10)
        let d = EvolutionRunController.decide(arming: arming(sessions: 10), state: state, nowEpoch: 0, perSessionBudgetCap: 10_000)
        XCTAssertFalse(d.shouldRun); XCTAssertTrue(d.reason.contains("session ceiling"))
    }

    func testCumulativeBudgetExhaustedRefuses() {
        let state = EvolutionRunState(sessionsRun: 5, tokensSpent: 100_000)
        let d = EvolutionRunController.decide(arming: arming(budget: 100_000), state: state, nowEpoch: 0, perSessionBudgetCap: 10_000)
        XCTAssertFalse(d.shouldRun); XCTAssertTrue(d.reason.contains("exhausted"))
    }

    func testGlobalStagnationRefuses() {
        let state = EvolutionRunState(sessionsRun: 3, consecutiveStagnantSessions: 3)
        let d = EvolutionRunController.decide(arming: arming(patience: 3), state: state, nowEpoch: 0, perSessionBudgetCap: 10_000)
        XCTAssertFalse(d.shouldRun); XCTAssertTrue(d.reason.contains("stagnation"))
    }

    func testPatienceZeroDisablesStagnationStop() {
        let state = EvolutionRunState(sessionsRun: 3, consecutiveStagnantSessions: 99)
        let d = EvolutionRunController.decide(arming: arming(patience: 0), state: state, nowEpoch: 0, perSessionBudgetCap: 10_000)
        XCTAssertTrue(d.shouldRun, "patience 0 ⇒ stagnation never stops")
    }

    // All gates green ⇒ runs, with sessionBudget = min(cap, remaining cumulative).
    func testRunsWithinBounds() {
        let state = EvolutionRunState(sessionsRun: 2, tokensSpent: 20_000)
        let d = EvolutionRunController.decide(arming: arming(budget: 100_000, sessions: 10), state: state,
                                              nowEpoch: 0, perSessionBudgetCap: 30_000)
        XCTAssertTrue(d.shouldRun)
        XCTAssertEqual(d.sessionBudgetTokens, 30_000, "cap is the binding limit here")
    }

    func testSessionBudgetClampedToRemaining() {
        let state = EvolutionRunState(sessionsRun: 9, tokensSpent: 95_000)  // only 5k left
        let d = EvolutionRunController.decide(arming: arming(budget: 100_000, sessions: 10), state: state,
                                              nowEpoch: 0, perSessionBudgetCap: 30_000)
        XCTAssertTrue(d.shouldRun)
        XCTAssertEqual(d.sessionBudgetTokens, 5_000, "the per-session budget can never exceed the remaining cumulative")
    }

    // State folding: improvement resets stagnation; no improvement increments; tokens + sessions accrue.
    func testStateRecordingImprovement() {
        let s0 = EvolutionRunState(sessionsRun: 1, tokensSpent: 10_000, bestEverScore: 100, consecutiveStagnantSessions: 2)
        let s1 = s0.recording(tokensSpentThisSession: 5_000, newBestScore: 130, nowEpoch: 42)
        XCTAssertEqual(s1.sessionsRun, 2)
        XCTAssertEqual(s1.tokensSpent, 15_000)
        XCTAssertEqual(s1.bestEverScore, 130)
        XCTAssertEqual(s1.consecutiveStagnantSessions, 0, "improvement resets stagnation")
        XCTAssertEqual(s1.lastSessionAtEpoch, 42)
    }

    func testStateRecordingStagnation() {
        let s0 = EvolutionRunState(sessionsRun: 1, tokensSpent: 10_000, bestEverScore: 130, consecutiveStagnantSessions: 1)
        let s1 = s0.recording(tokensSpentThisSession: 5_000, newBestScore: 120, nowEpoch: 42)   // no improvement
        XCTAssertEqual(s1.bestEverScore, 130, "best-ever never regresses")
        XCTAssertEqual(s1.consecutiveStagnantSessions, 2, "no improvement increments stagnation")
    }

    // Panel hardening: negative/tampered counters must REFUSE (not bypass the ceiling via huge remaining).
    func testInvalidNegativeStateRefuses() {
        let bad = EvolutionRunState(sessionsRun: -1, tokensSpent: -999)
        let d = EvolutionRunController.decide(arming: arming(), state: bad, nowEpoch: 0, perSessionBudgetCap: 10_000)
        XCTAssertFalse(d.shouldRun); XCTAssertTrue(d.reason.contains("INVALID"))
    }

    // Panel BLOCKER: a PRESENT-but-corrupt run-state must fail CLOSED (nil), not reset to a fresh state.
    func testCorruptStateFailsClosed() throws {
        let dir = NSTemporaryDirectory() + "corrupt-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/.mythos/evolution", withIntermediateDirectories: true)
        let store = EvolutionAutopilotStore(root: dir)
        XCTAssertEqual(store.stateOrNil(), EvolutionRunState(), "MISSING state ⇒ fresh (first run is fine)")

        try Data("{ this is not valid json ".utf8).write(to: URL(fileURLWithPath: store.statePath))
        XCTAssertNil(store.stateOrNil(), "PRESENT-but-corrupt state ⇒ nil (caller must refuse, never reset budget)")
    }

    // Panel BLOCKER: the interprocess session lock is exclusive — a second acquire fails while held.
    func testSessionLockIsExclusive() {
        let dir = NSTemporaryDirectory() + "lock-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = EvolutionAutopilotStore(root: dir)
        guard let fd = store.acquireSessionLock() else { return XCTFail("first lock should succeed") }
        XCTAssertNil(store.acquireSessionLock(), "a second concurrent lock must fail while the first is held")
        store.releaseSessionLock(fd)
        // after release it can be acquired again
        guard let fd2 = store.acquireSessionLock() else { return XCTFail("lock should re-acquire after release") }
        store.releaseSessionLock(fd2)
    }

    // Persistence round-trip + fail-closed default.
    func testStoreRoundTrip() {
        let dir = NSTemporaryDirectory() + "auto-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = EvolutionAutopilotStore(root: dir)
        XCTAssertNil(store.arming(), "no file ⇒ disarmed")
        XCTAssertEqual(store.state(), EvolutionRunState(), "no state file ⇒ fresh state")

        XCTAssertTrue(store.arm(arming(objective: "speed up routing")))
        XCTAssertEqual(store.arming()?.objective, "speed up routing")
        XCTAssertTrue(store.save(state: EvolutionRunState(sessionsRun: 3, tokensSpent: 9)))
        XCTAssertEqual(store.state().sessionsRun, 3)

        XCTAssertTrue(store.disarm())
        XCTAssertNil(store.arming(), "disarm removes the arming ⇒ back to fail-closed")
        XCTAssertEqual(store.state().sessionsRun, 3, "disarm preserves run-state")
        XCTAssertTrue(store.disarm(), "disarming when already disarmed is a no-op success")
    }
}
