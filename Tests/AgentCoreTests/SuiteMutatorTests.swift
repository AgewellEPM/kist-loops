import XCTest
@testable import AgentCore

/// Co-evolving evaluator: the mutator must (1) preserve MEANING while moving the SURFACE, and (2) let
/// the SpecBench probe separate real competence (advantage transfers) from gaming (advantage
/// evaporates when the surface moves). Each behavior is pinned individually.
final class SuiteMutatorTests: XCTestCase {

    private let base = [
        EvalCase(name: "a", prompt: "task a", assertions: [.outputContains("AA")]),
        EvalCase(name: "b", prompt: "task b", assertions: [.outputContains("BB")]),
    ]

    // A seed whose perturbation changes BOTH prompts — chosen deterministically (splitmix64 is stable
    // across runs), so the gaming tests below are reproducible, never flaky.
    private func seedThatMovesAllPrompts() -> UInt64 {
        for s in UInt64(1)...500 {
            let m = SuiteMutator.mutate(base, seed: s)
            if zip(m, base).allSatisfy({ $0.prompt != $1.prompt }) { return s }
        }
        XCTFail("no seed moved all prompts"); return 0
    }

    func testMutationIsDeterministicForSameSeed() {
        XCTAssertEqual(SuiteMutator.mutate(base, seed: 42), SuiteMutator.mutate(base, seed: 42))
    }

    func testDifferentSeedsMoveTheSurface() {
        let m1 = SuiteMutator.mutate(base, seed: 1)
        let m2 = SuiteMutator.mutate(base, seed: 2)
        XCTAssertNotEqual(m1.map(\.name), m2.map(\.name))
    }

    func testMutatedNamesAreDisjointFromTheOriginals() {
        // The moving-target identity must not collide with the accumulated (original-named) corpus,
        // or the ablation disjointness guard would (correctly) refuse to measure.
        let mutated = Set(SuiteMutator.mutate(base, seed: 9).map(\.name))
        let originals = Set(base.map(\.name))
        XCTAssertTrue(mutated.isDisjoint(with: originals))
    }

    func testMeaningIsPreserved_genuineOutputPassesBothSurfaces() async {
        // An agent that actually produces the required content passes the fixed suite AND every
        // perturbation of it — Δ ≈ 0.
        let genuine: EvalRunner.Agent = { _ in .init(output: "here: AA and BB", trajectory: []) }
        let probe = await SpecGamingProbe.probe(base: base, agent: genuine, seed: seedThatMovesAllPrompts())
        XCTAssertNotNil(probe)
        XCTAssertEqual(probe!.originalSuccess, 1.0, accuracy: 1e-9)
        XCTAssertEqual(probe!.mutatedSuccess, 1.0, accuracy: 1e-9)
        XCTAssertFalse(probe!.gamed())
    }

    func testGamingIsDetected_memorizedSurfaceCollapsesWhenItMoves() async {
        // An agent that only emits the right answer for the EXACT memorized prompts scores on the
        // fixed suite but fails the moving target → Δ>0 → gamed.
        let memorized = Set(base.map(\.prompt))
        let gaming: EvalRunner.Agent = { p in
            memorized.contains(p) ? .init(output: "AA BB", trajectory: []) : .init(output: "xx", trajectory: [])
        }
        let probe = await SpecGamingProbe.probe(base: base, agent: gaming, seed: seedThatMovesAllPrompts())
        XCTAssertNotNil(probe)
        XCTAssertEqual(probe!.originalSuccess, 1.0, accuracy: 1e-9)
        XCTAssertEqual(probe!.mutatedSuccess, 0.0, accuracy: 1e-9)
        XCTAssertTrue(probe!.gamed())
        XCTAssertEqual(probe!.delta, 1.0, accuracy: 1e-9)
    }

    func testContainsAssertionSurvivesTheContainsToMatchesSwap() {
        // Whichever way a round perturbs an outputContains assertion, a correct output still passes.
        for seed in UInt64(1)...50 {
            let m = SuiteMutator.mutateOne(base[0], seed: seed)
            for a in m.assertions {
                XCTAssertTrue(a.check(output: "value AA present", trajectory: [], maxIterations: 12).0,
                              "seed \(seed): correct output must still pass the perturbed assertion")
            }
        }
    }

    // MARK: - Moving-target ablation (the wired gate signal)

    func testRealAdvantageTransfersToTheMovingTarget() async {
        let cold: EvalRunner.Agent = { _ in .init(output: "xx", trajectory: []) }          // fails always
        let warm: EvalRunner.Agent = { _ in .init(output: "AA and BB", trajectory: []) }   // genuinely capable
        let result = await AblationRunner.runMovingTarget(
            base: base, accumulatedFrom: Set(base.map(\.name)), epoch: 1,
            cold: cold, warm: warm, seed: seedThatMovesAllPrompts())
        XCTAssertNotNil(result)
        XCTAssertNotNil(result!.onMovingTarget)
        XCTAssertGreaterThan(result!.onMovingTarget!.advantage, 0)
        XCTAssertFalse(result!.warmGaming?.gamed() ?? true)
        XCTAssertTrue(result!.advantageIsReal)
    }

    func testStoredSeedReplaysTheExactMeasuredCorpus() async {
        // The `seed` MovingTargetAblation records must reproduce the SAME moving-target corpus whose
        // advantage was measured — otherwise "replays exactly" is an unverified promise.
        let cold: EvalRunner.Agent = { _ in .init(output: "xx", trajectory: []) }
        let warm: EvalRunner.Agent = { _ in .init(output: "AA BB", trajectory: []) }
        let seed = seedThatMovesAllPrompts()
        guard let result = await AblationRunner.runMovingTarget(
            base: base, accumulatedFrom: Set(base.map(\.name)), epoch: 1,
            cold: cold, warm: warm, seed: seed) else { XCTFail("nil result"); return }
        XCTAssertEqual(result.seed, seed)
        // Re-mutating the base with the recorded seed yields the corpus whose hash was measured.
        let replayHash = SuiteMutator.corpusHash(SuiteMutator.mutate(base, seed: result.seed))
        XCTAssertEqual(result.onMovingTarget?.corpusHash, replayHash)
    }

    func testGamedAdvantageIsRejectedOnTheMovingTarget() async {
        let memorized = Set(base.map(\.prompt))
        let cold: EvalRunner.Agent = { _ in .init(output: "xx", trajectory: []) }
        let warm: EvalRunner.Agent = { p in    // looks great on the fixed suite, collapses when surface moves
            memorized.contains(p) ? .init(output: "AA BB", trajectory: []) : .init(output: "xx", trajectory: [])
        }
        let result = await AblationRunner.runMovingTarget(
            base: base, accumulatedFrom: Set(base.map(\.name)), epoch: 1,
            cold: cold, warm: warm, seed: seedThatMovesAllPrompts())
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.warmGaming?.gamed() ?? false)
        XCTAssertFalse(result!.advantageIsReal)   // no free pass for a memorized surface
    }
}
