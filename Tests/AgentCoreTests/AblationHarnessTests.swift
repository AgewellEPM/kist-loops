import XCTest
@testable import AgentCore

/// The ablation ORACLE — the un-fakeable "is the flywheel real" measure. These pin the three properties that
/// keep the Captain from wishing the curve upward: contamination REFUSAL, negative-transfer honesty, and a
/// slope that reflects real compounding.
final class AblationHarnessTests: XCTestCase {

    // WARM helps on held-out → positive advantage.
    func testWarmAdvantageIsMeasured() {
        let r = AblationHarness.measure(
            coldGrounded: [false, false, true, false],   // 25%
            warmGrounded: [true, false, true, true],     // 75%
            heldOutIDs: ["h1", "h2", "h3", "h4"], accumulatedFrom: ["t1", "t2"],
            corpusHash: "c", epoch: 1)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.coldSuccess, 0.25, accuracy: 1e-9)
        XCTAssertEqual(r!.warmSuccess, 0.75, accuracy: 1e-9)
        XCTAssertEqual(r!.advantage, 0.5, accuracy: 1e-9)
        XCTAssertFalse(r!.negativeTransfer)
    }

    // The honesty signature: the number CAN go down. Warm worse than cold → negative-transfer alarm.
    func testNegativeTransferIsAFirstClassOutcome() {
        let r = AblationHarness.measure(
            coldGrounded: [true, true, true, false],     // 75%
            warmGrounded: [false, true, false, false],   // 25%
            heldOutIDs: ["h1", "h2", "h3", "h4"], accumulatedFrom: [],
            corpusHash: "c", epoch: 1)
        XCTAssertNotNil(r)
        XCTAssertLessThan(r!.advantage, 0)
        XCTAssertTrue(r!.negativeTransfer, "warm worse than cold must alarm — a curve that only rises is gamed")
    }

    // THE anti-self-cert guard: if the held-out corpus overlaps what fed the warm state, REFUSE to produce a
    // number. A contaminated measurement is not a rosy result — it's no result.
    func testContaminatedCorpusRefusesToMeasure() {
        let r = AblationHarness.measure(
            coldGrounded: [true, true], warmGrounded: [true, true],
            heldOutIDs: ["h1", "shared"], accumulatedFrom: ["shared", "t2"],   // "shared" is in both
            corpusHash: "c", epoch: 1)
        XCTAssertNil(r, "held-out overlapping the warm training must invalidate the measurement")
    }

    func testCleanCorpusPasses() {
        XCTAssertTrue(AblationHarness.heldOutIsClean(heldOut: ["a", "b"], accumulatedFrom: ["c", "d"]))
        XCTAssertFalse(AblationHarness.heldOutIsClean(heldOut: ["a", "b"], accumulatedFrom: ["b", "c"]))
    }

    func testRefusesMalformedArms() {
        XCTAssertNil(AblationHarness.measure(coldGrounded: [], warmGrounded: [], heldOutIDs: [],
                                             accumulatedFrom: [], corpusHash: "c", epoch: 1), "empty is not a comparison")
        XCTAssertNil(AblationHarness.measure(coldGrounded: [true], warmGrounded: [true, false],
                                             heldOutIDs: ["h1"], accumulatedFrom: [], corpusHash: "c", epoch: 1), "size mismatch")
        XCTAssertNil(AblationHarness.measure(coldGrounded: [true, false], warmGrounded: [true, true],
                                             heldOutIDs: ["h1"], accumulatedFrom: [], corpusHash: "c", epoch: 1), "id count mismatch")
    }

    // The flywheel-acceleration signal: advantage growing over epochs → positive slope.
    func testAdvantageSlopeReflectsCompounding() {
        func res(_ e: Double, cold: Double, warm: Double) -> AblationResult {
            AblationResult(epoch: e, corpusHash: "c", n: 10, coldSuccess: cold, warmSuccess: warm)
        }
        let rising = [res(1, cold: 0.5, warm: 0.5), res(2, cold: 0.5, warm: 0.6), res(3, cold: 0.5, warm: 0.8)]
        XCTAssertGreaterThan(AblationHarness.advantageSlope(rising), 0, "growing warm advantage = accelerating flywheel")
        let falling = [res(1, cold: 0.5, warm: 0.8), res(2, cold: 0.5, warm: 0.6), res(3, cold: 0.5, warm: 0.5)]
        XCTAssertLessThan(AblationHarness.advantageSlope(falling), 0, "decaying advantage = flywheel stalling")
        XCTAssertEqual(AblationHarness.advantageSlope([res(1, cold: 0.5, warm: 0.6)]), 0, "one point = no trend")
    }
}
