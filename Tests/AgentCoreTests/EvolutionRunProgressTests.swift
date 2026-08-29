import XCTest
@testable import AgentCore

/// Pins the multi-generation DGM progress arithmetic: only PASSED candidates count as fitness, strict
/// improvement resets stagnation, and early-stop fires exactly at the patience threshold.
final class EvolutionRunProgressTests: XCTestCase {
    private func rec(_ id: String, status: EvolutionCandidateStatus, score: Int) -> EvolutionCandidateRecord {
        EvolutionTestAuthority.seal(EvolutionCandidateRecord(runID: "r", candidateID: id, parentID: nil, objective: "o", branch: "b",
                                 worktreePath: "/w", baseSHA: "0", commitSHA: "1", status: status, score: score,
                                 changedFiles: ["a.swift"], protectedFiles: [], benchmarks: [], summary: "s", createdAtEpoch: 0))
    }

    func testBestPassingScoreIgnoresNonPassed() {
        let archive = [rec("a", status: .passed, score: 120), rec("b", status: .failed, score: 999),
                       rec("c", status: .blocked, score: 9999), rec("d", status: .passed, score: 150)]
        XCTAssertEqual(EvolutionRunProgress.bestPassingScoreForTesting(archive), 150)
        XCTAssertNil(EvolutionRunProgress.bestPassingScoreForTesting(
            [rec("x", status: .failed, score: 5)]))
        XCTAssertNil(EvolutionRunProgress.bestPassingScoreForTesting([]))
        XCTAssertNil(EvolutionRunProgress.bestPassingScore(archive),
                     "unwitnessed local benchmark scores are sterile")
    }

    func testImprovementSemantics() {
        XCTAssertTrue(EvolutionRunProgress.improved(from: nil, to: 100))     // first pass is improvement
        XCTAssertTrue(EvolutionRunProgress.improved(from: 100, to: 101))
        XCTAssertFalse(EvolutionRunProgress.improved(from: 100, to: 100))    // equal is NOT improvement
        XCTAssertFalse(EvolutionRunProgress.improved(from: 100, to: 90))
        XCTAssertFalse(EvolutionRunProgress.improved(from: 100, to: nil))    // losing all passers isn't improvement
    }

    func testStagnationCounterResetsOnImprovement() {
        var stagnant = 0
        stagnant = EvolutionRunProgress.updateStagnation(stagnant, improved: false)  // 1
        stagnant = EvolutionRunProgress.updateStagnation(stagnant, improved: false)  // 2
        XCTAssertEqual(stagnant, 2)
        stagnant = EvolutionRunProgress.updateStagnation(stagnant, improved: true)   // reset
        XCTAssertEqual(stagnant, 0)
    }

    func testEarlyStopFiresAtPatience() {
        XCTAssertFalse(EvolutionRunProgress.shouldStop(consecutiveStagnant: 1, patience: 2))
        XCTAssertTrue(EvolutionRunProgress.shouldStop(consecutiveStagnant: 2, patience: 2))
        XCTAssertTrue(EvolutionRunProgress.shouldStop(consecutiveStagnant: 5, patience: 2))
        // patience 0 (default) disables early stop entirely
        XCTAssertFalse(EvolutionRunProgress.shouldStop(consecutiveStagnant: 99, patience: 0))
    }

    // A generation index must vary the parent-selection seed (gen 2 explores differently than gen 1).
    func testSelectionSeedVariesByGeneration() {
        let g1 = EvolutionParentSelector.selectionSeed(baseSHA: "base", objective: "o", variantIndex: 1, variantCount: 3, generation: 1)
        let g2 = EvolutionParentSelector.selectionSeed(baseSHA: "base", objective: "o", variantIndex: 1, variantCount: 3, generation: 2)
        XCTAssertNotEqual(g1, g2)
        // and default generation (1) is stable/back-compatible with the original single-generation seed
        XCTAssertEqual(g1, EvolutionParentSelector.selectionSeed(baseSHA: "base", objective: "o", variantIndex: 1, variantCount: 3))
        XCTAssertEqual(g1, EvolutionParentSelector.seed("evolve-parent", "base", "o", "1", "3"))
    }
}
