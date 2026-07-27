import XCTest
@testable import AgentCore

/// The great-loop: the safety-rail decision brain, the learning (score → calibrate), and the runner that
/// ties them together. Pure/injected, so the 20-hour behavior is pinned deterministically without a run.
final class GreatLoopTests: XCTestCase {

    private func state(cycle: Int = 0, tokens: Int = 0, now: Double = 0,
                       done: Bool = false, noProgress: Int = 0) -> GreatLoopState {
        GreatLoopState(cycle: cycle, tokensSpent: tokens, nowEpoch: now,
                       lastCycleDoneAndVerified: done, consecutiveNoProgress: noProgress)
    }

    // MARK: decision brain + safety rails

    func testVerifiedDoneStopsAndWins() {
        // A verified finish beats every cap — even if the budget is also blown.
        let caps = GreatLoopCaps(maxCycles: 1, maxTokens: 10)
        let d = GreatLoopController.decide(state: state(cycle: 99, tokens: 9_999, done: true), caps: caps)
        XCTAssertEqual(d, .stopDone(reason: "goal completed and verified in cycle 99"))
        XCTAssertTrue(d.succeeded)
    }

    func testTokenCeilingStops() {
        let d = GreatLoopController.decide(state: state(tokens: 5000), caps: GreatLoopCaps(maxTokens: 5000))
        if case .stopBudget = d {} else { XCTFail("must stop on the token ceiling: \(d)") }
    }

    func testDeadlineStops() {
        let d = GreatLoopController.decide(state: state(now: 100), caps: GreatLoopCaps(deadlineEpoch: 100))
        if case .stopDeadline = d {} else { XCTFail("must stop at the wall-clock deadline: \(d)") }
    }

    func testCyclesCapStops() {
        let d = GreatLoopController.decide(state: state(cycle: 30), caps: GreatLoopCaps(maxCycles: 30))
        if case .stopCycles = d {} else { XCTFail("must stop at the cycle cap: \(d)") }
    }

    func testNoProgressStopsSpinning() {
        let d = GreatLoopController.decide(state: state(noProgress: 3), caps: GreatLoopCaps(noProgressLimit: 3))
        if case .stopNoProgress = d {} else { XCTFail("must stop rather than spin: \(d)") }
    }

    func testOtherwiseKeepsGoing() {
        let d = GreatLoopController.decide(state: state(cycle: 2, tokens: 100), caps: GreatLoopCaps(maxCycles: 30, maxTokens: 100000))
        XCTAssertFalse(d.isTerminal)
    }

    // MARK: scoring

    func testActualDifficultyReflectsStruggle() {
        let easy = EffortScorer.actualDifficulty(failureRate: 0, iterationsUsed: 3, replansUsed: 0, wasStuck: false)
        let hard = EffortScorer.actualDifficulty(failureRate: 0.7, iterationsUsed: 40, replansUsed: 3, wasStuck: true)
        XCTAssertLessThan(easy, hard)
        XCTAssertLessThanOrEqual(hard, 100)
    }

    func testQualityRewardsVerifiedEfficientRuns() {
        let good = EffortScorer.quality(success: true, verified: true, failureRate: 0.0, iterationsUsed: 10, iterationBudget: 100)
        let bad = EffortScorer.quality(success: false, verified: false, failureRate: 0.5, iterationsUsed: 100, iterationBudget: 50)
        XCTAssertGreaterThan(good, bad)
        XCTAssertGreaterThanOrEqual(good, 90)   // finished + verified + efficient
    }

    // MARK: learning — calibration from history

    func testCalibrationBiasesTowardActualDifficulty() {
        // History says tasks like this were HARDER than predicted → positive bias, gently for one sample.
        let hist = [EffortOutcome(signature: "sig", predicted: 20, actual: 60, quality: 40, success: true, at: 1)]
        let c = EffortMemory.calibration(from: hist, signature: "sig")
        XCTAssertEqual(c.samples, 1)
        XCTAssertEqual(c.bias, 8, "meanDelta 40 × confidence 0.2 (1 sample) = 8")
    }

    func testCalibrationConfidenceRampsAndClamps() {
        let hist = (0..<6).map { EffortOutcome(signature: "s", predicted: 0, actual: 100, quality: 50, success: true, at: Double($0)) }
        let c = EffortMemory.calibration(from: hist, signature: "s")
        XCTAssertEqual(c.bias, 30, "full confidence × delta 100 clamps to +30")
    }

    func testNoHistoryIsNeutral() {
        XCTAssertEqual(EffortMemory.calibration(from: [], signature: "x"), .neutral)
    }

    // MARK: the runner ties it together

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    private func tempRoot() -> String { NSTemporaryDirectory() + "gl-\(UUID().uuidString)" }

    func testRunnerStopsWhenACycleFinishesVerified() async {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let counter = Counter()
        let runner = GreatLoopRunner(
            goal: "build a parser end-to-end", caps: GreatLoopCaps(maxCycles: 10),
            memory: EffortMemory(projectRoot: root), clock: { 1000 },
            runCycle: { _, _, _, _ in
                let n = counter.next()
                return CycleResult(doneAndVerified: n >= 3, tokensSpent: 500, madeProgress: true,
                                   signals: .init(failureRate: 0.1, iterationsUsed: 8), summary: "c\(n)")
            })
        let d = await runner.run()
        XCTAssertTrue(d.succeeded)
        XCTAssertEqual(counter.value, 3, "ran until the verified finish, no further")
        XCTAssertGreaterThanOrEqual(EffortMemory(projectRoot: root).load().count, 3, "each cycle was recorded (learning)")
    }

    func testRunnerRespectsCycleCap() async {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let counter = Counter()
        let runner = GreatLoopRunner(
            goal: "impossible task", caps: GreatLoopCaps(maxCycles: 4, noProgressLimit: 99),
            memory: EffortMemory(projectRoot: root), clock: { 0 },
            runCycle: { _, _, _, _ in
                _ = counter.next()
                return CycleResult(doneAndVerified: false, tokensSpent: 100, madeProgress: true,
                                   signals: .cold, summary: "x")
            })
        let d = await runner.run()
        if case .stopCycles = d {} else { XCTFail("must stop at the cycle cap: \(d)") }
        XCTAssertEqual(counter.value, 4)
    }

    func testRunnerPassesRemainingBudgetToCycle() async {
        // The cycle must receive REMAINING budget (total − spent) so it can size a per-cycle slice.
        let root = tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let seen = Counter()
        let box = RemainingBox()
        let runner = GreatLoopRunner(
            goal: "job", caps: GreatLoopCaps(maxCycles: 3, maxTokens: 10_000, noProgressLimit: 99),
            memory: EffortMemory(projectRoot: root), clock: { 0 },
            runCycle: { _, _, _, remaining in
                let n = seen.next()
                if n == 2 { box.set(remaining) }   // after cycle 1 spent 1000
                return CycleResult(doneAndVerified: false, tokensSpent: 1000, madeProgress: true, signals: .cold, summary: "x")
            })
        _ = await runner.run()
        XCTAssertEqual(box.value, 9_000, "cycle 2 sees 10000 − 1000 spent = 9000 remaining")
    }
    private final class RemainingBox: @unchecked Sendable {
        private let lock = NSLock(); private var v: Int? = nil
        var value: Int? { lock.lock(); defer { lock.unlock() }; return v }
        func set(_ x: Int?) { lock.lock(); v = x; lock.unlock() }
    }

    func testRunnerRespectsTokenCeiling() async {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let runner = GreatLoopRunner(
            goal: "big job", caps: GreatLoopCaps(maxCycles: 100, maxTokens: 2500, noProgressLimit: 99),
            memory: EffortMemory(projectRoot: root), clock: { 0 },
            runCycle: { _, _, _, _ in
                CycleResult(doneAndVerified: false, tokensSpent: 1000, madeProgress: true, signals: .cold, summary: "x")
            })
        let d = await runner.run()
        if case .stopBudget = d {} else { XCTFail("must stop on the token ceiling: \(d)") }
    }
}
