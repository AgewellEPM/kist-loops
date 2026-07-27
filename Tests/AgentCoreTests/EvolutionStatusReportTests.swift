import XCTest
@testable import AgentCore

/// Pins the human-review archive view: honest counts, the safety-blocked signal is surfaced loudly, the
/// frontier shows who'd be bred next, and a cheat is never presented as the best.
final class EvolutionStatusReportTests: XCTestCase {

    private func rec(_ id: String, status: EvolutionCandidateStatus, score: Int,
                     parent: String? = nil, changed: [String] = ["a.swift"], at: Double = 0, summary: String = "s") -> EvolutionCandidateRecord {
        EvolutionCandidateRecord(runID: "r", candidateID: id, parentID: parent, objective: "o", branch: "evo/\(id)",
                                 worktreePath: "/w", baseSHA: "0", commitSHA: "1", status: status, score: score,
                                 changedFiles: changed, protectedFiles: [], benchmarks: [], summary: summary, createdAtEpoch: at)
    }

    func testEmptyArchiveGuidance() {
        let out = EvolutionStatusReport.render(records: [])
        XCTAssertTrue(out.contains("No evolution candidates yet"))
        XCTAssertTrue(out.contains("--evolve"))
    }

    func testCountsAndBest() {
        let out = EvolutionStatusReport.render(records: [
            rec("a", status: .passed, score: 120, summary: "made it faster"),
            rec("b", status: .passed, score: 150, summary: "the winner"),
            rec("c", status: .failed, score: 5),
            rec("d", status: .noChange, score: 0, changed: []),
        ])
        XCTAssertTrue(out.contains("4 candidate(s)"))
        XCTAssertTrue(out.contains("passed 2 · failed 1 · blocked 0 · no-change 1"))
        XCTAssertTrue(out.contains("best · b · score 150"))
        XCTAssertTrue(out.contains("the winner"))
    }

    func testBlockedIsSurfacedAndNeverBest() {
        let out = EvolutionStatusReport.render(records: [
            rec("cheat", status: .blocked, score: 9999, summary: "deleted a test"),
            rec("honest", status: .passed, score: 30, summary: "small real gain"),
        ])
        XCTAssertTrue(out.contains("1 candidate(s) BLOCKED"))
        XCTAssertTrue(out.contains("best · honest · score 30"), "a blocked cheat must never be shown as best")
        XCTAssertFalse(out.contains("best · cheat"))
    }

    func testNoPassingYet() {
        let out = EvolutionStatusReport.render(records: [rec("x", status: .failed, score: 3, changed: ["y.swift"])])
        XCTAssertTrue(out.contains("nothing has passed benchmarks yet"))
    }

    func testFrontierListsEligibleNotBlocked() {
        let out = EvolutionStatusReport.render(records: [
            rec("win", status: .passed, score: 100),
            rec("stone", status: .failed, score: 10, changed: ["z.swift"]),
            rec("cheat", status: .blocked, score: 9999, changed: ["trust.swift"]),
        ])
        XCTAssertTrue(out.contains("next to breed"))
        XCTAssertTrue(out.contains("win"))
        XCTAssertTrue(out.contains("stone"))
        XCTAssertFalse(out.contains("cheat  ["), "a blocked candidate must never appear on the breed frontier")
    }
}
