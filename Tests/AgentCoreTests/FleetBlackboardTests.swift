import XCTest
@testable import AgentCore

/// The blackboard is pure value types: it must round-trip on disk (additive-decode tolerant of older
/// schemas), derive a correct Foreman subject from a cell, and keep Notes append-only.
final class FleetBlackboardTests: XCTestCase {

    private func enc() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private func dec() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    private func sampleCell(_ id: UUID = UUID()) -> AgentCell {
        AgentCell(id: id, title: "build the parser", branch: "mythos/a", worktreePath: "/wt/a",
                  baseSHA: "deadbeef", scopeGlobs: ["Core/*"], acceptanceCriterion: "parses a plan",
                  status: .working, filesTouched: ["Core/Parser.swift"],
                  keyDecisions: [Note(atEpoch: 1, text: "chose recursive descent over a table")],
                  lastHeartbeatEpoch: 5, liveStep: 3, lastAction: "writing Parser.swift")
    }

    func testBoardRoundTrips() throws {
        let board = FleetBlackboard(
            id: UUID(), goal: "ship the fleet", plan: [PlanStepRef(title: "parser", intent: "parse plans", scope: "Core")],
            integrationBranch: "mythos/integration", repo: "/repo",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), cells: [sampleCell()], revision: 4)
        let data = try enc().encode(board)
        let back = try dec().decode(FleetBlackboard.self, from: data)
        XCTAssertEqual(back.goal, board.goal)
        XCTAssertEqual(back.schemaVersion, FleetBlackboard.currentSchemaVersion)
        XCTAssertEqual(back.revision, 4)
        XCTAssertEqual(back.plan.first?.scope, "Core")
        XCTAssertEqual(back.cells.first?.scopeGlobs, ["Core/*"])
        XCTAssertEqual(back.cells.first?.liveStep, 3)
        XCTAssertEqual(back.cells.first?.keyDecisions.count, 1)
    }

    func testAdditiveDecodeToleratesOldSchema() throws {
        // A board written before cells/plan/revision/integrationBranch existed — only the v1-required
        // fields. Must decode with safe defaults, never throw.
        let oldJSON = #"""
        {"id":"\#(UUID().uuidString)","goal":"old","repo":"/r","startedAt":"2023-11-14T22:13:20Z"}
        """#
        let board = try dec().decode(FleetBlackboard.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(board.goal, "old")
        XCTAssertTrue(board.cells.isEmpty)
        XCTAssertTrue(board.plan.isEmpty)
        XCTAssertEqual(board.schemaVersion, 1)
        XCTAssertEqual(board.revision, 0)
        XCTAssertEqual(board.integrationBranch, "")
    }

    func testSupervisorDeliveryRecordsDecodeMissingDeliveredAsUndelivered() throws {
        let interventionJSON = #"""
        {"kind":"stale","atEpoch":1,"summary":"pending","evidence":["queued"]}
        """#
        let intervention = try dec().decode(SupervisorInterventionRecord.self,
                                            from: Data(interventionJSON.utf8))
        XCTAssertFalse(intervention.delivered)
        XCTAssertTrue(intervention.deliveryFailures.isEmpty)

        let escalationJSON = #"""
        {"kind":"blocked","atEpoch":2,"summary":"rescue","evidence":["blocked"],"assignment":"fix it"}
        """#
        let escalation = try dec().decode(SupervisorEscalationRecord.self,
                                          from: Data(escalationJSON.utf8))
        XCTAssertFalse(escalation.delivered)
        XCTAssertEqual(escalation.assignment, "fix it")
    }

    func testCellAdditiveDecodeDefaults() throws {
        // A cell with only the required v1 identity fields decodes with pending status + empty ledgers.
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","title":"t","branch":"b","worktreePath":"/w"}"#
        let cell = try dec().decode(AgentCell.self, from: Data(json.utf8))
        XCTAssertEqual(cell.status, .pending)
        XCTAssertEqual(cell.baseSHA, "")
        XCTAssertTrue(cell.scopeGlobs.isEmpty)
        XCTAssertNil(cell.signoff)
        XCTAssertNil(cell.liveStep)
    }

    func testCellDerivesForemanSubject() {
        let id = UUID()
        let s = sampleCell(id).foremanSubject
        XCTAssertEqual(s.agentID, id)
        XCTAssertEqual(s.branch, "mythos/a")
        XCTAssertEqual(s.worktreePath, "/wt/a")
        XCTAssertEqual(s.baseSHA, "deadbeef")
        XCTAssertEqual(s.scopeGlobs, ["Core/*"])
        XCTAssertEqual(s.acceptanceCriterion, "parses a plan")
        XCTAssertEqual(s.title, "build the parser")
    }

    func testNotesAreValueEqualAndCarryProvenance() {
        let n = Note(atEpoch: 7, text: "needs API from cell B")
        XCTAssertEqual(n, n)
        XCTAssertEqual(n.atEpoch, 7)
        XCTAssertNotEqual(Note(atEpoch: 7, text: "x"), Note(atEpoch: 7, text: "y"))
    }
}
