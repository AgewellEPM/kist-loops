import Foundation
import XCTest
@testable import AgentCore

/// Pins the open-ended DGM parent-selection contract: never breed from a cheat, keep the whole archive
/// as stepping-stones, favour the under-explored frontier, and stay deterministic (reproducible runs).
final class EvolutionParentSelectorTests: XCTestCase {

    private func rec(_ id: String, status: EvolutionCandidateStatus, score: Int,
                     parent: String? = nil, changed: [String] = ["a.swift"], at: Double = 0) -> EvolutionCandidateRecord {
        EvolutionTestAuthority.seal(EvolutionCandidateRecord(runID: "r", candidateID: id, parentID: parent, objective: "o", branch: "b",
                                 worktreePath: "/w", baseSHA: "0", commitSHA: "1", status: status, score: score,
                                 changedFiles: changed, protectedFiles: [], benchmarks: [], summary: "s", createdAtEpoch: at))
    }

    // A `blocked` candidate gamed the verifier / touched the trust spine — breeding from it would let the
    // reward-hack propagate. It must NEVER be eligible.
    func testBlockedIsNeverAParent() {
        let archive = [rec("cheat", status: .blocked, score: 999), rec("honest", status: .passed, score: 10)]
        let eligible = EvolutionParentSelector.eligibleParents(archive)
        XCTAssertEqual(eligible.map(\.candidateID), ["honest"])
        // even with a huge score, the cheat is never selected
        for seed in UInt64(0)..<50 {
            XCTAssertEqual(EvolutionParentSelector.selectParent(from: archive, seed: seed)?.candidateID, "honest")
        }
    }

    func testNoChangeIsNeverAParent() {
        let archive = [rec("empty", status: .noChange, score: 0, changed: []), rec("real", status: .passed, score: 5)]
        XCTAssertEqual(EvolutionParentSelector.eligibleParents(archive).map(\.candidateID), ["real"])
    }

    func testFailedWithDiffIsASteppingStoneWhenEnabled() {
        let archive = [rec("partial", status: .failed, score: 1, changed: ["x.swift"])]
        XCTAssertTrue(EvolutionParentSelector.eligibleParents(archive).isEmpty,
                      "default/autonomous parent selection must be passed-only")
        XCTAssertEqual(EvolutionParentSelector.eligibleParents(
            archive, config: .init(includeFailedSteppingStones: true)).count, 1,
            "failed stepping stones require an explicit experimental opt-in")
        // a failed candidate with NO diff is not a stepping-stone (nothing to build on)
        XCTAssertTrue(EvolutionParentSelector.eligibleParents(
            [rec("nodiff", status: .failed, score: 1, changed: [])],
            config: .init(includeFailedSteppingStones: true)).isEmpty)
    }

    func testArchiveContextShowsSelectedFailedSteppingStone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evolution-parent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EvolutionArchiveStore(root: root.path)
        _ = try store.append(EvolutionArchiveAuthorityCodec.withoutAuthority(
            rec("winner", status: .passed, score: 120, changed: ["winner.swift"])))
        let steppingStone = try store.append(EvolutionArchiveAuthorityCodec.withoutAuthority(
            rec("partial", status: .failed, score: 10, changed: ["partial.swift"])))
        _ = try store.append(EvolutionArchiveAuthorityCodec.withoutAuthority(
            rec("blocked", status: .blocked, score: 999, changed: ["trust.swift"])))

        let context = store.contextForTesting(selectedParent: steppingStone, limit: 3)
        XCTAssertTrue(context.contains("Selected parent to build from:"))
        XCTAssertTrue(context.contains("partial status=failed"))
        XCTAssertTrue(context.contains("partial.swift"))
        XCTAssertFalse(context.contains("blocked status=blocked"))
    }

    func testEmptyArchiveSelectsNil() {
        XCTAssertNil(EvolutionParentSelector.selectParent(from: [], seed: 1))
    }

    // Open-endedness: an under-explored candidate (fewer children) is weighted UP relative to an equally-fit
    // over-explored one — this is what escapes local optima.
    func testExplorationFavorsUnderExploredParents() {
        let explored = weightOf(score: 100, childCount: 8)
        let fresh = weightOf(score: 100, childCount: 0)
        XCTAssertGreaterThan(fresh, explored, "same fitness, fewer children ⇒ higher selection weight")
    }

    func testFitnessStillMattters() {
        XCTAssertGreaterThan(weightOf(score: 200, childCount: 0), weightOf(score: 10, childCount: 0))
        // a 0-score stepping-stone is still selectable (floored at 1), not weight 0
        XCTAssertGreaterThan(weightOf(score: 0, childCount: 0), 0)
    }

    func testGreedyConfigIgnoresExploration() {
        // explorationWeight 0 ⇒ weight is pure fitness (child count irrelevant)
        let cfg = EvolutionParentSelector.Config(explorationWeight: 0)
        XCTAssertEqual(EvolutionParentSelector.weight(score: 50, childCount: 0, config: cfg),
                       EvolutionParentSelector.weight(score: 50, childCount: 99, config: cfg))
    }

    // Deterministic: same archive + same seed ⇒ same parent (reproducible evolution runs).
    func testSelectionIsDeterministicPerSeed() {
        let archive = [rec("a", status: .passed, score: 30), rec("b", status: .passed, score: 30),
                       rec("c", status: .failed, score: 5, changed: ["z.swift"])]
        for seed in UInt64(0)..<20 {
            let first = EvolutionParentSelector.selectParent(from: archive, seed: seed)?.candidateID
            let again = EvolutionParentSelector.selectParent(from: archive, seed: seed)?.candidateID
            XCTAssertEqual(first, again)
        }
    }

    // Different seeds explore DIFFERENT parents across a balanced archive (not stuck on one).
    func testDifferentSeedsExploreDifferentParents() {
        let archive = [rec("a", status: .passed, score: 40), rec("b", status: .passed, score: 40),
                       rec("c", status: .passed, score: 40)]
        var picked = Set<String>()
        for seed in UInt64(0)..<200 { if let id = EvolutionParentSelector.selectParent(from: archive, seed: seed)?.candidateID { picked.insert(id) } }
        XCTAssertGreaterThanOrEqual(picked.count, 2, "balanced archive should explore more than one parent")
    }

    func testFrontierRanksUnderExploredFirst() {
        // two equal-fitness winners; 'b' already has a child ⇒ 'a' (unexplored) ranks first
        let archive = [rec("a", status: .passed, score: 50, at: 1),
                       rec("b", status: .passed, score: 50, at: 2),
                       rec("child", status: .failed, score: 1, parent: "b", changed: ["k.swift"], at: 3)]
        XCTAssertEqual(EvolutionParentSelector.frontier(archive).first?.candidateID, "a")
    }

    // The seed helper must be STABLE (reproducible across processes) and VARY per candidate.
    func testSeedIsStableAndVaries() {
        XCTAssertEqual(EvolutionParentSelector.seed("run1", "run1-v1"), EvolutionParentSelector.seed("run1", "run1-v1"))
        XCTAssertNotEqual(EvolutionParentSelector.seed("run1", "run1-v1"), EvolutionParentSelector.seed("run1", "run1-v2"))
        XCTAssertNotEqual(EvolutionParentSelector.seed("run1", "x"), EvolutionParentSelector.seed("run2", "x"))
        // token boundaries matter: ("ab","c") must not collide with ("a","bc")
        XCTAssertNotEqual(EvolutionParentSelector.seed("ab", "c"), EvolutionParentSelector.seed("a", "bc"))
        XCTAssertNotEqual(EvolutionParentSelector.seed("a/b", "c"), EvolutionParentSelector.seed("a", "b/c"))
    }

    func testSelectionSeedIsStableAndVariesByCandidateSlot() {
        XCTAssertEqual(
            EvolutionParentSelector.selectionSeed(baseSHA: "base", objective: "o", variantIndex: 1, variantCount: 3),
            EvolutionParentSelector.selectionSeed(baseSHA: "base", objective: "o", variantIndex: 1, variantCount: 3)
        )
        XCTAssertNotEqual(
            EvolutionParentSelector.selectionSeed(baseSHA: "base", objective: "o", variantIndex: 1, variantCount: 3),
            EvolutionParentSelector.selectionSeed(baseSHA: "base", objective: "o", variantIndex: 2, variantCount: 3)
        )
    }

    // Review hardening (GPT): a negative explorationWeight is clamped to 0 at the Config boundary, so
    // weights can never go negative / degenerate selection.
    func testNegativeExplorationWeightIsClamped() {
        let cfg = EvolutionParentSelector.Config(explorationWeight: -5)
        XCTAssertEqual(cfg.explorationWeight, 0)
        XCTAssertGreaterThan(EvolutionParentSelector.weight(score: 50, childCount: 0, config: cfg), 0)
    }

    // Review hardening (Gemini): an extreme score is capped so it can't blow the Double dynamic range and
    // starve low-weight stepping-stones. weight(Int.max) == weight(maxFitness).
    func testExtremeScoreIsCapped() {
        let capped = EvolutionParentSelector.weight(score: EvolutionParentSelector.maxFitness, childCount: 0, config: .default)
        let huge = EvolutionParentSelector.weight(score: Int.max, childCount: 0, config: .default)
        XCTAssertEqual(huge, capped, "an astronomically large score is capped to maxFitness")
        XCTAssertTrue(huge.isFinite && huge > 0)
    }

    private func weightOf(score: Int, childCount: Int) -> Double {
        EvolutionParentSelector.weight(score: score, childCount: childCount, config: .default)
    }
}
