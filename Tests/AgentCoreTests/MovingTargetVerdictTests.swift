import XCTest
@testable import AgentCore

/// Pins `MovingTargetVerdict.judge` — the P1 wire that turns the co-evolving moving-target probe into the live
/// `/ablation` verdict (previously `runMovingTarget`/`advantageIsReal`/`.gamed()` had zero non-test consumers).
/// The helper is pure, so these run without live models. Each test maps to a branch a promote gate depends on.
final class MovingTargetVerdictTests: XCTestCase {

    // n=5 ⇒ gaming epsilon = max(0.05, 1/5) = 0.2. Δ 0 ⇒ not gamed; Δ 0.6 ⇒ gamed.
    private func result(cold: Double, warm: Double, n: Int = 5) -> AblationResult {
        AblationResult(epoch: 0, corpusHash: "cap-test", n: n, coldSuccess: cold, warmSuccess: warm)
    }
    private func gaming(orig: Double, mutated: Double, n: Int = 5) -> SpecGamingResult {
        SpecGamingResult(originalSuccess: orig, mutatedSuccess: mutated, n: n)
    }

    /// No round at all ⇒ inconclusive, never a real/false verdict.
    func testNilRoundIsInconclusive() {
        guard case .inconclusive = MovingTargetVerdict.judge(nil) else { return XCTFail("nil must be inconclusive") }
    }

    /// A contaminated/malformed mutated corpus (runner returns onMovingTarget=nil) ⇒ inconclusive, NOT real.
    func testContaminatedMovingCorpusIsInconclusive() {
        let mt = MovingTargetAblation(onMovingTarget: nil, warmGaming: nil, seed: 1)
        guard case .inconclusive = MovingTargetVerdict.judge(mt) else { return XCTFail("nil onMovingTarget must be inconclusive") }
        XCTAssertFalse(MovingTargetVerdict.judge(mt).isReal)
    }

    /// Advantage holds on the moved surface AND gaming Δ is within noise ⇒ REAL.
    func testAdvantageSurvivesIsReal() {
        let mt = MovingTargetAblation(onMovingTarget: result(cold: 0.4, warm: 0.8),   // +0.4 on the moved surface
                                      warmGaming: gaming(orig: 0.6, mutated: 0.6),    // Δ 0 ⇒ not gamed
                                      seed: 1)
        guard case .real(let adv, let d) = MovingTargetVerdict.judge(mt) else { return XCTFail("must be real") }
        XCTAssertEqual(adv, 0.4, accuracy: 1e-9)
        XCTAssertEqual(d, 0.0, accuracy: 1e-9)
        XCTAssertTrue(MovingTargetVerdict.judge(mt).isReal)
    }

    /// The advantage EVAPORATES when the surface moves (Δ past threshold) ⇒ GAMED, veto-worthy.
    func testAdvantageEvaporatesIsGamed() {
        let mt = MovingTargetAblation(onMovingTarget: result(cold: 0.3, warm: 0.9),   // looks great on fixed
                                      warmGaming: gaming(orig: 0.9, mutated: 0.3),    // Δ 0.6 > 0.2 ⇒ gamed
                                      seed: 1)
        guard case .gamed(let d) = MovingTargetVerdict.judge(mt) else { return XCTFail("must be gamed") }
        XCTAssertEqual(d, 0.6, accuracy: 1e-9)
        XCTAssertFalse(MovingTargetVerdict.judge(mt).isReal)
    }

    /// SAFETY ORDERING: a reading that has a positive moving-target advantage AND games must be reported GAMED,
    /// never `real` — gaming is checked first so a veto-worthy reading can never be laundered as competence.
    func testGamingTakesPrecedenceOverPositiveAdvantage() {
        let mt = MovingTargetAblation(onMovingTarget: result(cold: 0.2, warm: 0.7),   // advantage +0.5 (> 0)
                                      warmGaming: gaming(orig: 0.95, mutated: 0.4),   // Δ 0.55 > 0.2 ⇒ gamed
                                      seed: 1)
        guard case .gamed = MovingTargetVerdict.judge(mt) else { return XCTFail("gaming must win over positive advantage") }
    }

    /// Moving-target advantage collapses to ~0 without tripping the gaming Δ ⇒ EVAPORATED (not reproducible),
    /// distinct from GAMED and from REAL.
    func testAdvantageCollapsesIsEvaporated() {
        let mt = MovingTargetAblation(onMovingTarget: result(cold: 0.6, warm: 0.6),   // advantage 0 on moved surface
                                      warmGaming: gaming(orig: 0.6, mutated: 0.6),    // Δ 0 ⇒ not gamed
                                      seed: 1)
        guard case .evaporated = MovingTargetVerdict.judge(mt) else { return XCTFail("must be evaporated") }
        XCTAssertFalse(MovingTargetVerdict.judge(mt).isReal)
    }

    /// The load-bearing invariant a gate relies on: `judge(mt).isReal` MUST equal `mt.advantageIsReal` for every
    /// non-nil round. If a refactor ever lets the decomposed verdict disagree with the boolean the gate reads,
    /// this fails — the two must never diverge.
    func testIsRealMatchesAdvantageIsRealInvariant() {
        let rounds: [MovingTargetAblation] = [
            .init(onMovingTarget: result(cold: 0.4, warm: 0.8), warmGaming: gaming(orig: 0.6, mutated: 0.6), seed: 1), // real
            .init(onMovingTarget: result(cold: 0.3, warm: 0.9), warmGaming: gaming(orig: 0.9, mutated: 0.3), seed: 2), // gamed
            .init(onMovingTarget: result(cold: 0.6, warm: 0.6), warmGaming: gaming(orig: 0.6, mutated: 0.6), seed: 3), // evaporated
            .init(onMovingTarget: result(cold: 0.2, warm: 0.7), warmGaming: gaming(orig: 0.95, mutated: 0.4), seed: 4),// pos+gamed
            .init(onMovingTarget: nil, warmGaming: nil, seed: 5),                                                      // inconclusive
        ]
        for (i, mt) in rounds.enumerated() {
            XCTAssertEqual(MovingTargetVerdict.judge(mt).isReal, mt.advantageIsReal,
                           "verdict.isReal must equal advantageIsReal for round \(i)")
        }
    }
}
