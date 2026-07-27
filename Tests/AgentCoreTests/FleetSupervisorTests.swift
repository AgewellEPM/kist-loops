import XCTest
@testable import AgentCore

/// The supervision loop, driven end-to-end with injected seams (no real git/sleep). The Foreman is real
/// (with fake measurement seams) so a GREEN actually SEALS into the ledger — the supervisor then folds
/// signed-off, advances the baton to passed, and the merge gate joins only signed + in-lease branches.
final class FleetSupervisorTests: XCTestCase {

    private var dir: URL!
    private let fleetID = UUID()
    private let goalID = "G"

    override func setUpWithError() throws {
        ForgeSeal.forceEphemeralKeyForTesting()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("super-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: substrate builders

    private func stores() -> (FleetBlackboardStore, FleetUpdateInbox, FleetSignoffLedger, FleetBatonStore) {
        (FleetBlackboardStore(fleetID: fleetID, baseDir: dir),
         FleetUpdateInbox(fleetID: fleetID, baseDir: dir),
         FleetSignoffLedger(baseDir: dir.appendingPathComponent("signoff")),
         FleetBatonStore(baseDir: dir.appendingPathComponent("batons")))
    }

    private func cell(_ id: UUID, _ branch: String, scope: [String] = ["Core/*"]) -> AgentCell {
        AgentCell(id: id, title: "task-\(branch)", branch: branch, worktreePath: "/wt/\(branch)",
                  scopeGlobs: scope, status: .working)
    }

    private func heldBaton(_ id: UUID, _ branch: String) -> Baton {
        Baton(fleetID: fleetID, missionGoal: "ship", repo: dir.path,
              holder: id.uuidString, currentBranch: branch, state: .held)
    }

    /// A real Foreman whose measurement seams are faked. `pass` drives the test exit; `changed` lets a
    /// branch escape its lease (to exercise the merge-gate refusal).
    private func foreman(_ ledger: FleetSignoffLedger, pass: Bool = true,
                         changed: @escaping (GitWorktree) -> [String] = { _ in ["Core/x.swift"] }) -> Foreman {
        Foreman(ledger: ledger,
                commitCount: { _ in 1 }, diff: { _ in "+ a change" }, changedPaths: changed,
                maxFileLines: { _, _ in 100 }, runTests: { _ in pass ? 0 : 1 }, trackedDirty: { _ in [] },
                codexReviewed: { _ in false }, readClaims: { _ in nil }, claimEvidence: { _ in ([], "") })
    }

    private func makeSupervisor(_ board: FleetBlackboardStore, _ inbox: FleetUpdateInbox,
                                _ ledger: FleetSignoffLedger, _ batons: FleetBatonStore, _ foreman: Foreman,
                                sentinel: @escaping (String) -> Bool = { _ in true }, maxRejects: Int = 2,
                                headSHA: @escaping (String) -> String = { _ in "test-head-sha" },
                                maxSweeps: Int = 10,
                                policy: FleetSupervisorPolicy = FleetSupervisorPolicy(staleAfterSeconds: 10_000),
                                readProgress: @escaping (String) -> FleetProgress? = { _ in nil },
                                nowEpoch: @escaping () -> Double = { 1000 },
                                writeSlice: @escaping (String, String) -> Bool = { _, _ in true },
                                writeIntervention: @escaping (String, FleetSupervisorIntervention) -> Bool = { _, _ in true },
                                writeEscalation: @escaping (String, FleetSupervisorEscalation) -> Bool = { _, _ in true },
                                archiveRejectedDone: @escaping (String, Double) -> Bool = { _, _ in true },
                                mergeRecorder: ((_ branches: [String]) -> Void)? = nil) -> FleetSupervisor {
        FleetSupervisor(
            board: board, inbox: inbox, ledger: ledger, batons: batons, foreman: foreman,
            maxSweeps: maxSweeps, maxRejects: maxRejects,
            doneSentinelPresent: sentinel, nowEpoch: nowEpoch, writeSlice: writeSlice,
            waitBetweenSweeps: {}, readProgress: readProgress, headSHA: headSHA,
            policy: policy, writeIntervention: writeIntervention, writeEscalation: writeEscalation,
            archiveRejectedDone: archiveRejectedDone,
            merge: { _, _, branches, intBranch, _ in
                mergeRecorder?(branches)
                return .merged(integrationBranch: intBranch, worktreePath: "/int", branches: branches)
            })
    }

    private func seed(_ board: FleetBlackboardStore, cells: [AgentCell]) {
        board.seed(FleetBlackboard(id: fleetID, goal: "ship", plan: [], integrationBranch: "mythos/integration",
                                   repo: dir.path, startedAt: Date(timeIntervalSince1970: 1), cells: cells))
    }

    private func blockBoardPersistence() throws {
        let boardDir = dir.appendingPathComponent(fleetID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: boardDir)
        try "file, not directory".write(to: boardDir, atomically: true, encoding: .utf8)
    }

    // MARK: all green → all signed

    func testAllGreenAgentsAreSignedAndBatonsPassed() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID(), b = UUID()
        seed(board, cells: [cell(a, "mythos/a"), cell(b, "mythos/b")])
        batons.save(heldBaton(a, "mythos/a")); batons.save(heldBaton(b, "mythos/b"))
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true))

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.signed, 2)
        XCTAssertTrue(result.allSigned)
        XCTAssertTrue(ledger.signedOff(goalID: goalID, agentID: a))
        XCTAssertTrue(ledger.signedOff(goalID: goalID, agentID: b))
        let cells = board.currentBoard()!.cells
        XCTAssertTrue(cells.allSatisfy { $0.status == .signedOff })
        XCTAssertTrue(cells.allSatisfy { $0.signoff != nil }, "each cell carries its sealed proof")
        XCTAssertTrue(batons.all().allSatisfy { $0.state == .passed }, "verified→passed")
        XCTAssertTrue(batons.all().allSatisfy { $0.accumulatedContext.count == 1 },
                      "each passed baton carries exactly one proven contribution")
        XCTAssertTrue(batons.all().allSatisfy { $0.accumulatedContext.allSatisfy { $0.commitSHA == "test-head-sha" } },
                      "baton contributions carry the surrendered commit SHA")
    }

    func testBlackboardPersistenceFailurePreventsAllSignedClaim() async throws {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(heldBaton(a, "mythos/a"))
        try blockBoardPersistence()
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true))

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.signed, 1, "the foreman proof can exist independently")
        XCTAssertEqual(result.persistenceFailures, 1)
        XCTAssertFalse(result.allSigned, "a fleet with blackboard persistence failure must not auto-merge")
        XCTAssertTrue(result.summary.contains("board persistence failure"))
        XCTAssertTrue(result.summary.contains("blackboard persistence failed") || result.summary.contains("PARTIAL"))
        XCTAssertEqual(board.currentBoard()!.cells[0].status, .working,
                       "the in-memory board stays at the last durable snapshot")
        XCTAssertEqual(batons.all().first?.state, .submitted,
                       "baton must not advance to passed until the signed-off board state persists")
        XCTAssertTrue(batons.all().first?.accumulatedContext.isEmpty ?? false)
        guard case .failed(let reason) = sup.joinSignedBranches(goalID: goalID, base: "deadbeef") else {
            return XCTFail("merge gate must fail closed after blackboard persistence failure")
        }
        XCTAssertTrue(reason.contains("persistence failure") || reason.contains("blackboard"),
                      "merge refusal should name the durability failure, got \(reason)")
    }

    // MARK: non-green → rejected, never signed

    func testFailingAgentIsRejectedNotSigned() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(heldBaton(a, "mythos/a"))
        // maxRejects 0 → the first rejection is terminal (.failed).
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: false), maxRejects: 0)

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.signed, 0)
        XCTAssertEqual(result.rejected, 1)
        XCTAssertFalse(ledger.signedOff(goalID: goalID, agentID: a), "a failing run never seals")
        let c = board.currentBoard()!.cells[0]
        XCTAssertEqual(c.status, .failed)
        XCTAssertFalse(c.blockers.isEmpty, "the failed blockers are surfaced as corrective context")
        XCTAssertTrue(c.keyDecisions.contains { $0.text.contains("RECOVERY") }, "a terminal failure records a recovery recommendation")
    }

    func testRejectionPersistenceFailureDoesNotArchiveDoneOrAdvanceBaton() async throws {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(heldBaton(a, "mythos/a"))
        try blockBoardPersistence()
        var archiveCalled = false
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: false),
                                 maxRejects: 0,
                                 archiveRejectedDone: { _, _ in
                                     archiveCalled = true
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.persistenceFailures, 1)
        XCTAssertFalse(archiveCalled, "a rejected done marker is not consumed until rejection is durable")
        XCTAssertEqual(board.currentBoard()!.cells[0].status, .working,
                       "the in-memory board stays at the last durable snapshot")
        XCTAssertEqual(batons.all().first?.state, .submitted,
                       "baton must not advance to rejected/failed until rejection persists")
    }

    func testRejectedDoneMarkerIsConsumedAndNotReprocessedWithoutNewCommit() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(heldBaton(a, "mythos/a"))
        var inspectCount = 0
        var sentinelPresent = true
        let fm = Foreman(ledger: ledger,
                         commitCount: { _ in 1 },
                         diff: { _ in "+ broken" },
                         changedPaths: { _ in ["Core/x.swift"] },
                         maxFileLines: { _, _ in 100 },
                         runTests: { _ in
                             inspectCount += 1
                             return 1
                         },
                         trackedDirty: { _ in [] },
                         codexReviewed: { _ in false },
                         readClaims: { _ in nil },
                         claimEvidence: { _ in ([], "") })
        let sup = makeSupervisor(board, inbox, ledger, batons, fm,
                                 sentinel: { _ in sentinelPresent },
                                 maxRejects: 2,
                                 maxSweeps: 3,
                                 archiveRejectedDone: { _, _ in
                                     sentinelPresent = false
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(inspectCount, 1, "the same rejected .fleet-done must not burn the retry budget repeatedly")
        XCTAssertEqual(result.rejected, 0, "within retry budget, the worker remains blocked rather than terminal failed")
        XCTAssertEqual(result.stillRunning, 1)
        XCTAssertEqual(board.currentBoard()!.cells[0].status, .blocked)
        XCTAssertEqual(batons.all().first?.rejectCount, 1)
    }

    func testRejectedDoneHeadPersistsSoRestartDoesNotReinspectSameCommit() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(heldBaton(a, "mythos/a"))
        var firstInspectCount = 0
        let failingForeman = Foreman(ledger: ledger,
                                     commitCount: { _ in 1 },
                                     diff: { _ in "+ broken" },
                                     changedPaths: { _ in ["Core/x.swift"] },
                                     maxFileLines: { _, _ in 100 },
                                     runTests: { _ in
                                         firstInspectCount += 1
                                         return 1
                                     },
                                     trackedDirty: { _ in [] },
                                     codexReviewed: { _ in false },
                                     readClaims: { _ in nil },
                                     claimEvidence: { _ in ([], "") })
        let first = makeSupervisor(board, inbox, ledger, batons, failingForeman,
                                   sentinel: { _ in true },
                                   maxRejects: 2,
                                   headSHA: { _ in "bad-head" },
                                   maxSweeps: 1,
                                   archiveRejectedDone: { _, _ in false })

        _ = await first.supervise(goalID: goalID)

        XCTAssertEqual(firstInspectCount, 1)
        XCTAssertEqual(board.currentBoard()!.cells[0].rejectedDoneHeadSHAs, ["bad-head"])
        var restartInspectCount = 0
        let restartedForeman = Foreman(ledger: ledger,
                                       commitCount: { _ in 1 },
                                       diff: { _ in "+ still broken" },
                                       changedPaths: { _ in ["Core/x.swift"] },
                                       maxFileLines: { _, _ in 100 },
                                       runTests: { _ in
                                           restartInspectCount += 1
                                           return 1
                                       },
                                       trackedDirty: { _ in [] },
                                       codexReviewed: { _ in false },
                                       readClaims: { _ in nil },
                                       claimEvidence: { _ in ([], "") })
        let restarted = makeSupervisor(board, inbox, ledger, batons, restartedForeman,
                                       sentinel: { _ in true },
                                       maxRejects: 2,
                                       headSHA: { _ in "bad-head" },
                                       maxSweeps: 1,
                                       archiveRejectedDone: { _, _ in false })

        _ = await restarted.supervise(goalID: goalID)

        XCTAssertEqual(restartInspectCount, 0,
                       "a restart must not re-inspect the same rejected done marker at the same commit")
        XCTAssertEqual(batons.all().first?.rejectCount, 1,
                       "the same rejected surrender must not burn another retry after restart")
    }

    func testEmptyHeadDoesNotPoisonRejectedSurrenderTracking() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(heldBaton(a, "mythos/a"))
        var inspectCount = 0
        let failingForeman = Foreman(ledger: ledger,
                                     commitCount: { _ in 1 },
                                     diff: { _ in "+ broken" },
                                     changedPaths: { _ in ["Core/x.swift"] },
                                     maxFileLines: { _, _ in 100 },
                                     runTests: { _ in
                                         inspectCount += 1
                                         return 1
                                     },
                                     trackedDirty: { _ in [] },
                                     codexReviewed: { _ in false },
                                     readClaims: { _ in nil },
                                     claimEvidence: { _ in ([], "") })
        let supervisor = makeSupervisor(board, inbox, ledger, batons, failingForeman,
                                        sentinel: { _ in true },
                                        maxRejects: 2,
                                        headSHA: { _ in "" },
                                        maxSweeps: 1,
                                        policy: FleetSupervisorPolicy(staleAfterSeconds: 10_000),
                                        archiveRejectedDone: { _, _ in false })

        _ = await supervisor.supervise(goalID: goalID)
        _ = await supervisor.supervise(goalID: goalID)

        XCTAssertEqual(inspectCount, 2,
                       "an unknown HEAD cannot safely dedupe a rejected done marker")
        XCTAssertEqual(board.currentBoard()!.cells[0].rejectedDoneHeadSHAs, [])
        XCTAssertEqual(batons.all().first?.rejectCount, 2)
    }

    // MARK: timeout → failed, partial, never merged

    func testTimedOutAgentIsFailedAndCapturedNotMerged() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        // A baton with a deadline already in the past (now is 1000).
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 1))
        // No sentinel ever appears.
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true), sentinel: { _ in false })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.timedOut, 1)
        XCTAssertEqual(result.signed, 0)
        let c = board.currentBoard()!.cells[0]
        XCTAssertEqual(c.status, .failed)
        XCTAssertTrue(c.blockers.contains { $0.text.hasPrefix("TIMED OUT") })
        XCTAssertTrue(result.summary.contains("PARTIAL"))
        XCTAssertTrue(result.summary.contains("nothing touched main"))
    }

    func testTimeoutPersistenceFailureDoesNotAdvanceBaton() async throws {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 1))
        try blockBoardPersistence()
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true), sentinel: { _ in false })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.persistenceFailures, 1)
        XCTAssertEqual(board.currentBoard()!.cells[0].status, .working,
                       "timeout is not published in memory if the board write fails")
        XCTAssertEqual(batons.all().first?.state, .held,
                       "baton must not advance to timedOut/failed until timeout persists")
    }

    // MARK: continuous supervisor — live intervention before terminal failure

    func testStaleAgentGetsSupervisorRepairDirectiveBeforeTimeout() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        var directives: [FleetSupervisorIntervention] = []
        var slices: [String] = []
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 1,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 60, maxInterventionsPerAgent: 1),
                                 writeSlice: { _, text in
                                     slices.append(text)
                                     return true
                                 },
                                 writeIntervention: { _, intervention in
                                     directives.append(intervention)
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.interventions, 1)
        XCTAssertEqual(result.stillRunning, 1)
        XCTAssertEqual(directives.first?.kind, .stale)
        XCTAssertTrue(directives.first?.directive.contains("Captain Continuous Supervisor") ?? false)
        XCTAssertTrue(slices.first?.contains("Repair Directive") ?? false)
        let c = board.currentBoard()!.cells[0]
        XCTAssertEqual(c.status, .blocked)
        XCTAssertTrue(c.blockers.contains { $0.text.contains("SUPERVISOR STALE") })
        XCTAssertTrue(c.keyDecisions.contains { $0.text.contains("SUPERVISOR INTERVENTION") })
        XCTAssertEqual(c.supervisorInterventions.count, 1)
        XCTAssertEqual(c.supervisorInterventions.first?.kind, "stale")
    }

    func testFailedSupervisorDirectiveDeliveryIsRecordedButNotCountedAsDelivered() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 1,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 60, maxInterventionsPerAgent: 1),
                                 writeSlice: { _, _ in true },
                                 writeIntervention: { _, _ in false })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.interventions, 0, "failed delivery is not reported as a delivered intervention")
        let c = board.currentBoard()!.cells[0]
        XCTAssertEqual(c.supervisorInterventions.count, 1, "the failed attempt remains auditable")
        XCTAssertEqual(c.supervisorInterventions.first?.delivered, false)
        XCTAssertTrue(c.supervisorInterventions.first?.deliveryFailures.contains(".mythos-fleet-supervisor.md write failed") ?? false)
        XCTAssertTrue(c.keyDecisions.contains { $0.text.contains("delivery FAILED") })
    }

    func testPendingSupervisorDirectiveDeliveryIsRecoveredOnNextSweep() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        var stuck = cell(a, "mythos/a")
        stuck.status = .blocked
        stuck.supervisorInterventions = [
            SupervisorInterventionRecord(kind: "stale",
                                         atEpoch: 900,
                                         summary: "no heartbeat",
                                         evidence: ["last heartbeat: 1"],
                                         delivered: false,
                                         deliveryFailures: ["delivery pending until board persistence succeeds"])
        ]
        seed(board, cells: [stuck])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        var directives: [FleetSupervisorIntervention] = []
        var slices: [String] = []
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 1,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 10_000,
                                                               maxInterventionsPerAgent: 0),
                                 writeSlice: { _, text in
                                     slices.append(text)
                                     return true
                                 },
                                 writeIntervention: { _, intervention in
                                     directives.append(intervention)
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.interventions, 1)
        XCTAssertEqual(directives.first?.kind, .stale)
        XCTAssertTrue(slices.first?.contains("Repair Directive") ?? false)
        let c = board.currentBoard()!.cells[0]
        XCTAssertEqual(c.supervisorInterventions.first?.delivered, true)
        XCTAssertEqual(c.supervisorInterventions.first?.deliveryFailures, [])
        XCTAssertTrue(c.keyDecisions.contains { $0.text.contains("INTERVENTION RECOVERY") })
    }

    func testFutureProgressTimestampDoesNotBecomeFutureHeartbeat() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 1,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 60, maxInterventionsPerAgent: 1),
                                 readProgress: { _ in FleetProgress(latestStep: 9,
                                                                     lastAction: "future heartbeat",
                                                                     lastActionEpoch: 99_999,
                                                                     lastFile: nil) })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.interventions, 1, "future-dated progress must not suppress stale supervision")
        let c = board.currentBoard()!.cells[0]
        XCTAssertEqual(c.liveStep, 9)
        XCTAssertEqual(c.lastAction, "future heartbeat")
        XCTAssertLessThan(c.lastHeartbeatEpoch, 99_999, "worker-controlled future time cannot poison the freshness clock")
    }

    func testFreshRepeatedProgressTimestampPreventsFalseStaleIntervention() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        var active = cell(a, "mythos/a")
        active.liveStep = 2
        active.lastAction = "running tests"
        active.lastHeartbeatEpoch = 900
        seed(board, cells: [active])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        var interventions = 0
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 1,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 60, maxInterventionsPerAgent: 1),
                                 readProgress: { _ in FleetProgress(latestStep: 2,
                                                                     lastAction: "running tests",
                                                                     lastActionEpoch: 990,
                                                                     lastFile: nil) },
                                 nowEpoch: { 1000 },
                                 writeIntervention: { _, _ in
                                     interventions += 1
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(interventions, 0)
        XCTAssertEqual(result.interventions, 0)
        XCTAssertEqual(board.currentBoard()!.cells[0].lastHeartbeatEpoch, 990)
    }

    func testOutOfLeaseProgressIsBlockedAsDriftAndInjectedIntoWorkerContext() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a", scope: ["Core/*"])])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        var directive: FleetSupervisorIntervention?
        var directivePath: String?
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 1,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 10_000, maxInterventionsPerAgent: 1),
                                 readProgress: { _ in FleetProgress(latestStep: 2,
                                                                     lastAction: "edit",
                                                                     lastActionEpoch: 999,
                                                                     lastFile: "Other/B.swift") },
                                 writeIntervention: { path, intervention in
                                     directivePath = path
                                     directive = intervention
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.interventions, 1)
        XCTAssertEqual(directive?.kind, .drift)
        XCTAssertTrue(directive?.summary.contains("Other/B.swift") ?? false)
        XCTAssertEqual(directive?.evidence.first, "reported progress file: Other/B.swift")
        XCTAssertEqual(directivePath, "/wt/mythos/a")
        let c = board.currentBoard()!.cells[0]
        XCTAssertEqual(c.liveStep, 2)
        XCTAssertEqual(c.lastAction, "edit")
        XCTAssertEqual(c.status, .blocked)
        XCTAssertTrue(c.blockers.contains { $0.text.contains("SUPERVISOR DRIFT") })
        XCTAssertEqual(c.supervisorInterventions.first?.kind, "drift")
    }

    func testWorkerReportedBlockedGetsSupervisorIntervention() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        var blocked = cell(a, "mythos/a")
        blocked.status = .blocked
        blocked.blockers = [Note(atEpoch: 900, text: "needs API contract")]
        seed(board, cells: [blocked])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        var directive: FleetSupervisorIntervention?
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 1,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 10_000, maxInterventionsPerAgent: 1),
                                 writeIntervention: { _, intervention in
                                     directive = intervention
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.interventions, 1)
        XCTAssertEqual(directive?.kind, .blocked)
        XCTAssertTrue(directive?.summary.contains("needs API contract") ?? false)
        XCTAssertEqual(board.currentBoard()!.cells[0].supervisorInterventions.first?.kind, "blocked")
    }

    func testSupervisorCreatedBlockedStateDoesNotTriggerSecondInterventionByDefault() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        var interventions = 0
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 3,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 60, maxInterventionsPerAgent: 2),
                                 writeIntervention: { _, _ in
                                     interventions += 1
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(interventions, 1)
        XCTAssertEqual(result.interventions, 1)
        XCTAssertEqual(board.currentBoard()!.cells[0].supervisorInterventions.count, 1)
    }

    func testUnresolvedSupervisorBlockEscalatesToRescueAssignment() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        var nowValues = [1000.0, 1000.0, 1121.0, 1121.0, 1121.0, 1121.0, 1121.0]
        var rescues: [FleetSupervisorEscalation] = []
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 2,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 60,
                                                               maxInterventionsPerAgent: 1,
                                                               escalateAfterSeconds: 120,
                                                               maxEscalationsPerAgent: 1),
                                 nowEpoch: { nowValues.isEmpty ? 1121 : nowValues.removeFirst() },
                                 writeEscalation: { _, escalation in
                                     rescues.append(escalation)
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.interventions, 1)
        XCTAssertEqual(result.escalations, 1)
        XCTAssertTrue(result.summary.contains("1 rescue escalation"))
        XCTAssertEqual(rescues.first?.kind, .blocked)
        XCTAssertTrue(rescues.first?.assignment.contains("Captain Rescue Assignment") ?? false)
        XCTAssertTrue(rescues.first?.assignment.contains("mythos/a") ?? false)
        let c = board.currentBoard()!.cells[0]
        XCTAssertEqual(c.status, .blocked)
        XCTAssertEqual(c.supervisorInterventions.count, 1)
        XCTAssertEqual(c.supervisorEscalations.count, 1)
        XCTAssertEqual(c.supervisorEscalations.first?.delivered, true)
        XCTAssertTrue(c.blockers.contains { $0.text.contains("SUPERVISOR ESCALATION BLOCKED") })
        XCTAssertTrue(c.keyDecisions.contains { $0.text.contains("rescue assignment delivered") })
    }

    func testFailedRescueEscalationDeliveryIsAuditedButNotCounted() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        var nowValues = [1000.0, 1000.0, 1121.0, 1121.0, 1121.0, 1121.0, 1121.0]
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 2,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 60,
                                                               maxInterventionsPerAgent: 1,
                                                               escalateAfterSeconds: 120,
                                                               maxEscalationsPerAgent: 1),
                                 nowEpoch: { nowValues.isEmpty ? 1121 : nowValues.removeFirst() },
                                 writeEscalation: { _, _ in false })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.interventions, 1)
        XCTAssertEqual(result.escalations, 0, "failed rescue delivery is not reported as delivered")
        let c = board.currentBoard()!.cells[0]
        XCTAssertEqual(c.supervisorEscalations.count, 1)
        XCTAssertEqual(c.supervisorEscalations.first?.delivered, false)
        XCTAssertTrue(c.supervisorEscalations.first?.deliveryFailures.contains(".mythos-fleet-rescue.md write failed") ?? false)
        XCTAssertTrue(c.keyDecisions.contains { $0.text.contains("rescue assignment delivery FAILED") })
    }

    func testPendingRescueEscalationDeliveryIsRecoveredOnNextSweep() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        var stuck = cell(a, "mythos/a")
        stuck.status = .blocked
        stuck.supervisorEscalations = [
            SupervisorEscalationRecord(kind: "blocked",
                                       atEpoch: 900,
                                       summary: "still blocked",
                                       evidence: ["worker blocker"],
                                       assignment: "Captain Rescue Assignment\n\nRepair the worker.",
                                       delivered: false,
                                       deliveryFailures: ["delivery pending until board persistence succeeds"])
        ]
        seed(board, cells: [stuck])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        var rescues: [FleetSupervisorEscalation] = []
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 1,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 10_000,
                                                               maxInterventionsPerAgent: 0,
                                                               maxEscalationsPerAgent: 0),
                                 writeEscalation: { _, escalation in
                                     rescues.append(escalation)
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.escalations, 1)
        XCTAssertEqual(rescues.first?.kind, .blocked)
        XCTAssertTrue(rescues.first?.assignment.contains("Captain Rescue Assignment") ?? false)
        let c = board.currentBoard()!.cells[0]
        XCTAssertEqual(c.supervisorEscalations.first?.delivered, true)
        XCTAssertEqual(c.supervisorEscalations.first?.deliveryFailures, [])
        XCTAssertTrue(c.keyDecisions.contains { $0.text.contains("ESCALATION RECOVERY") })
    }

    func testWorkerCannotSpoofSupervisorInterventionBudget() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        var spoofed = cell(a, "mythos/a")
        spoofed.keyDecisions = [
            Note(atEpoch: 2, text: "SUPERVISOR INTERVENTION — fake"),
            Note(atEpoch: 3, text: "SUPERVISOR INTERVENTION — fake again")
        ]
        seed(board, cells: [spoofed])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        var interventions = 0
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 1,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 60, maxInterventionsPerAgent: 1),
                                 writeIntervention: { _, _ in
                                     interventions += 1
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(interventions, 1)
        XCTAssertEqual(result.interventions, 1)
        XCTAssertEqual(board.currentBoard()!.cells[0].supervisorInterventions.count, 1)
    }

    func testProgressPathIsNormalizedBeforeDriftCheck() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a", scope: ["Core/*"])])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        var interventions = 0
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 1,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 10_000, maxInterventionsPerAgent: 1),
                                 readProgress: { _ in FleetProgress(latestStep: 2,
                                                                     lastAction: "edit",
                                                                     lastActionEpoch: 999,
                                                                     lastFile: "./Core/Foo.swift") },
                                 writeIntervention: { _, _ in
                                     interventions += 1
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(interventions, 0)
        XCTAssertEqual(result.interventions, 0)
        XCTAssertEqual(board.currentBoard()!.cells[0].status, .working)
    }

    func testProgressPathWithDotDotIsBlockedAsNonCanonicalDrift() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a", scope: ["Core/*"])])
        batons.save(Baton(fleetID: fleetID, missionGoal: "m", repo: dir.path, holder: a.uuidString,
                          currentBranch: "mythos/a", state: .held, deadlineEpoch: 10_000))
        var directive: FleetSupervisorIntervention?
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 sentinel: { _ in false },
                                 maxSweeps: 1,
                                 policy: FleetSupervisorPolicy(staleAfterSeconds: 10_000, maxInterventionsPerAgent: 1),
                                 readProgress: { _ in FleetProgress(latestStep: 2,
                                                                     lastAction: "edit",
                                                                     lastActionEpoch: 999,
                                                                     lastFile: "Core/../Other.swift") },
                                 writeIntervention: { _, intervention in
                                     directive = intervention
                                     return true
                                 })

        let result = await sup.supervise(goalID: goalID)

        XCTAssertEqual(result.interventions, 1)
        XCTAssertEqual(directive?.kind, .drift)
        XCTAssertTrue(directive?.summary.contains("non-canonical") ?? false)
        XCTAssertEqual(directive?.evidence.first, "reported progress file: Core/../Other.swift")
        XCTAssertEqual(board.currentBoard()!.cells[0].status, .blocked)
    }

    // MARK: merge gate — join signed + in-lease only

    func testMergeGateJoinsSignedInLeaseBranches() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID(), b = UUID()
        seed(board, cells: [cell(a, "mythos/a"), cell(b, "mythos/b")])
        batons.save(heldBaton(a, "mythos/a")); batons.save(heldBaton(b, "mythos/b"))
        var merged: [String] = []
        // both in-lease (changed path under Core/*)
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true),
                                 mergeRecorder: { merged = $0 })
        _ = await sup.supervise(goalID: goalID)

        let result = sup.joinSignedBranches(goalID: goalID, base: "deadbeef")
        guard case .merged(_, _, let branches) = result else { return XCTFail("expected merged, got \(result)") }
        XCTAssertEqual(Set(branches), ["mythos/a", "mythos/b"], "both signed in-lease branches join")
        XCTAssertEqual(Set(merged), ["mythos/a", "mythos/b"])
    }

    func testOutOfLeaseBranchRefusedAtSignoffNeverMerges() async {
        // C10: an out-of-lease branch is now refused AT SIGNOFF (Foreman GATE 3), not merely recorded
        // and held back at the merge gate. It never seals a green, so it never reaches the merge as a
        // signed branch — a strictly stronger guarantee than the old record-only-then-refuse-at-merge.
        let (board, inbox, ledger, batons) = stores()
        let a = UUID(), b = UUID()
        seed(board, cells: [cell(a, "mythos/a"), cell(b, "mythos/b")])
        batons.save(heldBaton(a, "mythos/a")); batons.save(heldBaton(b, "mythos/b"))
        // Branch b ESCAPES its Core/* lease (commits Other/B.swift) → blocked at signoff, never sealed.
        let fm = foreman(ledger, pass: true, changed: { wt in
            wt.branch.hasSuffix("/b") ? ["Other/B.swift"] : ["Core/A.swift"]
        })
        var merged: [String] = []
        let sup = makeSupervisor(board, inbox, ledger, batons, fm,
                                 mergeRecorder: { merged = $0 })
        _ = await sup.supervise(goalID: goalID)

        // Only the IN-LEASE branch is signed; the escapee is refused before sealing.
        XCTAssertTrue(ledger.signedOff(goalID: goalID, agentID: a))
        XCTAssertFalse(ledger.signedOff(goalID: goalID, agentID: b),
                       "off-lease work is refused at signoff — never sealed a green")
        // …so only a joins; b was never a signed candidate for the merge gate to consider.
        let result = sup.joinSignedBranches(goalID: goalID, base: "deadbeef")
        guard case .merged(_, _, let branches) = result else { return XCTFail("expected merged, got \(result)") }
        XCTAssertEqual(branches, ["mythos/a"], "the out-of-lease branch b never merges")
    }

    func testMergeGateStillRefusesInjectedOffLeaseEntry() {
        // Defense in depth: C10a stops Foreman from sealing off-lease work, so the normal flow no longer
        // produces a signed off-lease branch. But the merge gate's refusal must still hold for ANY sealed
        // entry with outOfScopeCount>0 (a pre-C10a entry, or a future non-Foreman signer). We seed a cell
        // that ALREADY carries a durable board signoff (the merged main gate requires it — cross-check at
        // FleetSupervisor.joinSignedBranches:965 — an even stronger backstop than c7 had) and inject a
        // matching ledger entry with oos>0, proving joinSignedBranches still refuses via the LEASE path.
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        // A pre-C10a / non-Foreman board signoff: status .signedOff + a non-nil proof so the board
        // cross-check passes and the entry reaches the lease (oos) refusal.
        let priorProof = Signoff(ledgerSeq: 1, ledgerEntryHash: "prior-hash",
                                 verdict: .green, testExitCode: 0, signedAtEpoch: 1)
        let signedCell = AgentCell(id: a, title: "task-a", branch: "mythos/a", worktreePath: "/wt/a",
                                   scopeGlobs: ["Core/*"], status: .signedOff, signoff: priorProof)
        seed(board, cells: [signedCell])
        let buildID = "bid-oos"
        let world = WorldFacts(confirmedHelpForBuild: 1, signalBroken: false, hasSignal: true)
        let build = BuildFacts(buildID: buildID, claimedDone: true, tests: TestRunEvidence(exitCode: 0),
                               diff: DiffEvidence(changedLines: 5, maxFileLines: 100),
                               codex: CodexEvidence(reviewed: true), stepCapHit: false, runIncomplete: false)
        let green = GroundedVerdict.fromCode(CaptainFacts(build: build, world: world))
        let ev = FleetSignoffEvidence(buildID: buildID, testExitCode: 0, changedLines: 5,
                                      maxFileLines: 100, outOfScopeCount: 1, summary: "off-lease")
        XCTAssertNotNil(ledger.record(goalID: goalID, agentID: a, branch: "mythos/a",
                                      grounded: green, evidence: ev, atEpoch: 1),
                        "the injected green entry (with oos>0) is sealed")

        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: true, changed: { _ in [] }))
        let result = sup.joinSignedBranches(goalID: goalID, base: "deadbeef")
        // oos>0 ⇒ refused at the merge gate's LEASE check (main's stronger contract: .failed, not a silent
        // nothingToMerge), and the off-lease branch is never joined.
        guard case .failed(let reason) = result else { return XCTFail("expected failed (lease-refused), got \(result)") }
        XCTAssertTrue(reason.contains("lease-refused"), "the refusal names the lease violation: \(reason)")
        let aCell = board.currentBoard()!.cells.first { $0.branch == "mythos/a" }!
        XCTAssertTrue(aCell.keyDecisions.contains { $0.text.contains("LEASE REFUSED at merge") },
                      "the merge-gate refusal is surfaced on the board")
    }

    // MARK: mandatory lease — a cleared/empty lease in a multi-agent fleet can't sign or merge (Codex HIGH)

    func testMandatoryLeaseRefusesClearedLeaseAgentNeverSignsOrMerges() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        // An EMPTY lease — the validator cleared a collision/hallucination. Everything else is green.
        seed(board, cells: [cell(a, "mythos/a", scope: [])])
        batons.save(heldBaton(a, "mythos/a"))
        let fm = Foreman(ledger: ledger, leaseRequired: true,
                         commitCount: { _ in 1 }, diff: { _ in "+ x" }, changedPaths: { _ in ["X.swift"] },
                         maxFileLines: { _, _ in 100 }, runTests: { _ in 0 }, trackedDirty: { _ in [] },
                         codexReviewed: { _ in false }, readClaims: { _ in nil }, claimEvidence: { _ in ([], "") })
        let sup = makeSupervisor(board, inbox, ledger, batons, fm)
        let result = await sup.supervise(goalID: goalID)
        XCTAssertEqual(result.signed, 0, "a mandatory-lease fleet refuses to sign an unscoped (cleared) agent")
        XCTAssertFalse(ledger.signedOff(goalID: goalID, agentID: a), "no seal ⇒ can't be laundered as in-lease")
        XCTAssertEqual(sup.joinSignedBranches(goalID: goalID, base: "x"), .nothingToMerge, "nothing to auto-join")
    }

    func testNothingSignedMergesNothing() async {
        let (board, inbox, ledger, batons) = stores()
        let a = UUID()
        seed(board, cells: [cell(a, "mythos/a")])
        batons.save(heldBaton(a, "mythos/a"))
        let sup = makeSupervisor(board, inbox, ledger, batons, foreman(ledger, pass: false), maxRejects: 0)
        _ = await sup.supervise(goalID: goalID)
        XCTAssertEqual(sup.joinSignedBranches(goalID: goalID, base: "x"), .nothingToMerge,
                       "no sealed in-lease branch ⇒ nothing to merge (no integration worktree spun up)")
    }
}
