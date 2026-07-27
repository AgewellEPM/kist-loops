import XCTest
@testable import AgentCore

final class FleetCockpitTests: XCTestCase {

    private func cell(_ id: UUID, _ title: String, _ status: AgentCell.CellStatus, scope: [String] = ["Core/*"]) -> AgentCell {
        AgentCell(id: id, title: title, branch: "fleet/\(title)", worktreePath: "/wt/\(title)",
                  scopeGlobs: scope, status: status)
    }
    private func entry(_ seq: Int, _ agent: UUID, outOfScope: Int) -> FleetSignoffEntry {
        FleetSignoffEntry(seq: seq, prevHash: "", goalID: "G", agentID: agent, branch: "b", buildID: "x",
                          verdict: .green, testExitCode: 0, changedLines: 5, maxFileLines: 50,
                          outOfScopeCount: outOfScope, summary: "ok", recordedAt: Date(), entryHash: "h\(seq)", seal: "s")
    }

    // A HELD-OUT ADVISORY recorded on a cell's keyDecisions surfaces as a cockpit row flag + render note,
    // so the operator sees it in the whole-picture view (not just buried in the board). It NEVER blocks —
    // the agent still signs; the flag just says "review before promoting".
    func testHeldOutAdvisorySurfacesInCockpitRow() {
        let a = UUID()
        let advisoryCell = AgentCell(id: a, title: "alpha", branch: "fleet/alpha", worktreePath: "/wt/alpha",
                                     scopeGlobs: ["Core/*"], status: .signedOff,
                                     keyDecisions: [Note(atEpoch: 1, text: "HELD-OUT ADVISORY: base tests failed — review")])
        let pic = FleetCockpitModel.picture(goal: "g", cells: [advisoryCell],
                                            trustworthyEntries: [entry(1, a, outOfScope: 0)], chainIntact: true)
        XCTAssertTrue(pic.rows.first!.heldOutAdvisory, "the advisory keyDecision surfaces as a row flag")
        XCTAssertTrue(pic.render().contains("held-out advisory"), "and renders in the cockpit")
        // A cell without the advisory keyDecision does NOT flag.
        let plain = FleetCockpitModel.picture(goal: "g", cells: [cell(UUID(), "beta", .signedOff)],
                                              trustworthyEntries: [], chainIntact: true)
        XCTAssertFalse(plain.rows.first!.heldOutAdvisory)
    }

    func testInLeaseSignoffMergesOffLeaseHeld() {
        let a = UUID(), b = UUID(), c = UUID()
        let pic = FleetCockpitModel.picture(
            goal: "build it",
            cells: [cell(a, "alpha", .signedOff), cell(b, "bravo", .signedOff), cell(c, "charlie", .working)],
            trustworthyEntries: [entry(1, a, outOfScope: 0), entry(2, b, outOfScope: 3)],
            chainIntact: true)
        XCTAssertEqual(pic.total, 3)
        XCTAssertEqual(pic.signed, 2)
        XCTAssertEqual(pic.mergeable, 1)            // alpha (in-lease)
        XCTAssertEqual(pic.refusedForLease, 1)      // bravo (off-lease, held)
        XCTAssertTrue(pic.rows.first { $0.title == "alpha" }!.willMerge)
        XCTAssertTrue(pic.rows.first { $0.title == "bravo" }!.refusedForLease)
        XCTAssertFalse(pic.rows.first { $0.title == "charlie" }!.willMerge)   // unsigned
    }

    func testBrokenChainShowsZeroTrust() {
        let a = UUID()
        // chainIntact=false ⇒ render warns + nothing merges (trustworthyEntries would be EMPTY in reality).
        let pic = FleetCockpitModel.picture(goal: "g", cells: [cell(a, "x", .signedOff)],
                                            trustworthyEntries: [], chainIntact: false)
        XCTAssertEqual(pic.mergeable, 0)
        XCTAssertTrue(pic.render().contains("CHAIN BROKEN"))
    }

    func testRenderShowsMergeFate() {
        let a = UUID()
        let pic = FleetCockpitModel.picture(goal: "g", cells: [cell(a, "alpha", .signedOff)],
                                            trustworthyEntries: [entry(1, a, outOfScope: 0)], chainIntact: true)
        let r = pic.render()
        XCTAssertTrue(r.contains("alpha"))
        XCTAssertTrue(r.contains("→ merges"))
        XCTAssertTrue(r.contains("1 mergeable"))
    }

    func testLatestSignoffWinsPerAgent() {
        let a = UUID()
        // two entries for the same agent — the later seq (off-lease) wins → held, not merged.
        let pic = FleetCockpitModel.picture(goal: "g", cells: [cell(a, "x", .signedOff)],
                                            trustworthyEntries: [entry(1, a, outOfScope: 0), entry(2, a, outOfScope: 1)],
                                            chainIntact: true)
        XCTAssertEqual(pic.mergeable, 0)
        XCTAssertEqual(pic.refusedForLease, 1)
    }

    func testStaleness() {
        XCTAssertFalse(FleetCockpitModel.isStale(lastHeartbeatEpoch: 0, now: 1000))      // never heard = just started
        XCTAssertFalse(FleetCockpitModel.isStale(lastHeartbeatEpoch: 900, now: 1000))    // 100s < 300
        XCTAssertTrue(FleetCockpitModel.isStale(lastHeartbeatEpoch: 500, now: 1000))     // 500s > 300
    }
}
