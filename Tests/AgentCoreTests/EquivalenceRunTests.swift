import XCTest
@testable import AgentCore

final class EquivalenceRunTests: XCTestCase {

    private func cases(_ inputs: [String]) -> [EquivalenceRun.Case] {
        inputs.enumerated().map { EquivalenceRun.Case(id: "c\($0.offset)", input: $0.element) }
    }

    // A correct port matching a deterministic oracle → evidence-bounded equivalent over the corpus.
    func testCorrectPortIsEvidenceBoundedEquivalent() {
        let report = EquivalenceRun.run(cases(["a", "b", "c"]),
                                        oracle: { $0.uppercased() },
                                        candidate: { $0.uppercased() })
        XCTAssertEqual(report.overall, .evidenceBoundedEquivalent)
        XCTAssertEqual(report.count(.equivalent), 3)
    }

    // A port that differs on one input → the run REGRESSES (weakest link), not "2/3 passed".
    func testDivergentPortRegresses() {
        let report = EquivalenceRun.run(cases(["a", "b", "c"]),
                                        oracle: { $0.uppercased() },
                                        candidate: { $0 == "b" ? "WRONG" : $0.uppercased() })
        XCTAssertEqual(report.overall, .regressed)
        XCTAssertEqual(report.count(.notEquivalent), 1)
        XCTAssertEqual(report.count(.equivalent), 2)
    }

    // Gate 0: a NONDETERMINISTIC oracle (disagrees with itself) on an UNDECLARED field → captureFailed,
    // and the whole run is captureFailed (invalid evidence), never a pass. This is the capture-integrity
    // early-warning for the #1 real-world failure.
    func testNondeterministicOracleTripsGate0() {
        var tick = 0
        let report = EquivalenceRun.run(cases(["x"]),
                                        oracle: { _ in tick += 1; return "value-\(tick)" },  // differs each call
                                        candidate: { _ in "value-1" })
        XCTAssertEqual(report.overall, .captureFailed)
        XCTAssertFalse(report.isCutoverEligible)
    }

    // Declared-nondeterministic oracle + an invariant that holds → equivalent-by-invariant (metamorphic).
    func testDeclaredNondeterminismWithInvariantHolds() {
        var tick = 0
        let cs = [EquivalenceRun.Case(id: "nd", input: "x", mayBeNondeterministic: true,
                                      invariant: { _, cand in cand.hasPrefix("value-") })]
        let report = EquivalenceRun.run(cs,
                                        oracle: { _ in tick += 1; return "value-\(tick)" },
                                        candidate: { _ in "value-99" })
        XCTAssertEqual(report.overall, .evidenceBoundedEquivalent)
    }

    // A candidate that THROWS where the oracle succeeded → notEquivalent (a crashing port is not equivalent).
    func testCandidateThrowIsNotEquivalent() {
        struct Boom: Error {}
        let report = EquivalenceRun.run(cases(["a"]),
                                        oracle: { $0.uppercased() },
                                        candidate: { _ in throw Boom() })
        XCTAssertEqual(report.overall, .regressed)
        XCTAssertEqual(report.count(.notEquivalent), 1)
    }

    // Council fix: a candidate throw is out-of-band, so it can NEVER be laundered into equivalent by an
    // oracle that happens to emit the (former) sentinel string. Oracle emits that exact string; candidate
    // throws → still notEquivalent (no collision possible).
    func testCandidateThrowCannotCollideWithAnyOracleOutput() {
        struct Boom: Error {}
        let sentinelish = "\u{0} kist.candidate.threw \u{0}"   // the string the old marker used
        let report = EquivalenceRun.run(cases([sentinelish]),
                                        oracle: { _ in sentinelish },   // oracle legitimately emits it
                                        candidate: { _ in throw Boom() })
        XCTAssertEqual(report.overall, .regressed)              // a crashing port is NOT equivalent
        XCTAssertEqual(report.count(.notEquivalent), 1)
    }

    // An oracle that THROWS → no reference captured → notCovered (honest gap), not a pass.
    func testOracleThrowIsNotCovered() {
        struct Boom: Error {}
        let report = EquivalenceRun.run(cases(["a"]),
                                        oracle: { _ in throw Boom() },
                                        candidate: { $0.uppercased() })
        XCTAssertEqual(report.overall, .incomplete)
        XCTAssertEqual(report.count(.notCovered), 1)
    }

    // Volatile projection flows through: an oracle whose output carries a timestamp the candidate also
    // carries (different value) is equivalent once the timestamp is declared volatile.
    func testVolatileProjectionFlowsThrough() {
        let report = EquivalenceRun.run(cases(["a"]), volatiles: [.isoTimestamp],
                                        oracle: { _ in "ok at 2026-07-03T12:00:00Z" },
                                        candidate: { _ in "ok at 2026-01-01T00:00:00Z" })
        XCTAssertEqual(report.overall, .evidenceBoundedEquivalent)
    }

    func testCaptureProducesOneEvidencePerCase() {
        let ev = EquivalenceRun.capture(cases(["a", "b"]), oracle: { $0 }, candidate: { $0 })
        XCTAssertEqual(ev.count, 2)
        XCTAssertEqual(ev.map { $0.id }, ["c0", "c1"])
    }
}
