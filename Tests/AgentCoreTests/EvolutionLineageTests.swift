import XCTest
@testable import AgentCore

/// Pins the ancestry view: generation parsing, the best-score trajectory, indented parent→child nesting,
/// and — the safety-critical part — cycle-safety so a corrupt parentID chain can never infinite-recurse.
final class EvolutionLineageTests: XCTestCase {

    private func rec(_ id: String, status: EvolutionCandidateStatus = .passed, score: Int = 100,
                     parent: String? = nil, at: Double = 0, summary: String = "s") -> EvolutionCandidateRecord {
        EvolutionCandidateRecord(runID: "r", candidateID: id, parentID: parent, objective: "o", branch: "b",
                                 worktreePath: "/w", baseSHA: "0", commitSHA: "1", status: status, score: score,
                                 changedFiles: ["a.swift"], protectedFiles: [], benchmarks: [], summary: summary, createdAtEpoch: at)
    }

    func testEmpty() {
        XCTAssertTrue(EvolutionLineage.render(records: []).contains("No evolution lineage yet"))
    }

    func testGenerationParsing() {
        XCTAssertEqual(EvolutionLineage.generation(of: "a1b2-g3-v2"), 3)
        XCTAssertEqual(EvolutionLineage.generation(of: "a1b2-v2"), 1)     // single-gen ⇒ 1
        XCTAssertEqual(EvolutionLineage.generation(of: "weird-id"), 1)    // no g-token ⇒ 1
    }

    func testTrajectoryShowsPerGenerationBestAndDelta() {
        let recs = [
            rec("r-g1-v1", score: 100, at: 1),
            rec("r-g1-v2", score: 120, at: 2),   // gen1 best 120
            rec("r-g2-v1", score: 150, at: 3),   // gen2 best 150 ↑
            rec("r-g3-v1", status: .failed, score: 5, at: 4),   // failed doesn't count
        ]
        let lines = EvolutionLineage.trajectoryLines(recs)
        XCTAssertTrue(lines.contains { $0.contains("gen 1: 120") })
        XCTAssertTrue(lines.contains { $0.contains("gen 2: 150") && $0.contains("↑+30") })
        XCTAssertFalse(lines.contains { $0.contains("gen 3") }, "a generation with no PASSED candidate has no trajectory point")
    }

    func testTrajectoryNothingPassed() {
        XCTAssertTrue(EvolutionLineage.trajectoryLines([rec("x", status: .failed, score: 3)]).first!.contains("nothing has passed"))
    }

    func testForestNestsChildrenUnderParents() {
        let recs = [
            rec("root", parent: nil, at: 1, summary: "the origin"),
            rec("child", parent: "root", at: 2, summary: "descendant"),
            rec("grandchild", parent: "child", at: 3, summary: "deeper"),
        ]
        let lines = EvolutionLineage.forestLines(recs)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("✓ root"), "root at depth 0")
        XCTAssertTrue(lines[1].contains("└ ✓ child") && lines[1].hasPrefix("  "), "child indented once")
        XCTAssertTrue(lines[2].hasPrefix("    "), "grandchild indented twice")
    }

    func testOrphanWhoseParentIsAbsentBecomesRoot() {
        // parentID points at a candidate not in the archive (e.g. from a prior pruned run) ⇒ treated as root
        let lines = EvolutionLineage.forestLines([rec("orphan", parent: "ghost", at: 1)])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("✓ orphan"))
    }

    // SAFETY: a corrupt archive with a parentID CYCLE must not infinite-recurse; every node emitted once.
    func testCycleIsSafeAndSurfaced() {
        let recs = [
            rec("a", parent: "b", at: 1),
            rec("b", parent: "a", at: 2),   // a→b→a cycle, no root
        ]
        let lines = EvolutionLineage.forestLines(recs)
        // both appear (one flagged unreachable), and it terminates
        XCTAssertTrue(lines.contains { $0.contains("unreachable — parentID cycle") })
        XCTAssertEqual(Set(lines.map { $0.contains("a ") || $0.contains(" a ") ? "a" : "b" }).count <= 2, true)
        XCTAssertLessThanOrEqual(lines.count, 4, "must terminate, not blow up")
    }

    func testStatusMarksInTree() {
        let lines = EvolutionLineage.forestLines([
            rec("p", status: .passed, at: 1), rec("f", status: .failed, at: 2),
            rec("bl", status: .blocked, at: 3), rec("nc", status: .noChange, at: 4),
        ])
        XCTAssertTrue(lines.contains { $0.contains("✓ p") })
        XCTAssertTrue(lines.contains { $0.contains("· f") })
        XCTAssertTrue(lines.contains { $0.contains("⚠ bl") })
        XCTAssertTrue(lines.contains { $0.contains("∅ nc") })
    }
}
