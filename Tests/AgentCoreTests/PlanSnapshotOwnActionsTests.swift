import XCTest
@testable import AgentCore

/// A pending plan survives its OWN recorded workspace actions (0.17.63). Before this, the first
/// `write_file` of a plan advanced the lifecycle head and the plan's next step was refused as
/// "generated under an obsolete workspace manifest" — one replan per file, every multi-step
/// mutation plan (live 2026-09-27: hello.py, test_hello.py, then the test run took three plans).
final class PlanSnapshotOwnActionsTests: XCTestCase {
    private let policy = "manifest-policy-v1"

    // MARK: accepted

    func testIdenticalHeadStillMatches() throws {
        var state = makeState()
        try configureLifecycle(&state)
        XCTAssertTrue(PlanExecuteLoop.snapshotMatchesWorkspace(snapshot(planID: "plan-1"), control: state))
    }

    func testHeadReachedByThePlansOwnSingleWriteMatches() throws {
        var state = makeState()
        try configureLifecycle(&state)
        try record(&state, planID: "plan-1", ordinal: 1, post: 5)
        XCTAssertEqual(state.workspaceManifestDigest, "manifest-head-5")
        XCTAssertTrue(PlanExecuteLoop.snapshotMatchesWorkspace(snapshot(planID: "plan-1"), control: state))
    }

    func testHeadReachedByThePlansOwnChainOfWritesMatches() throws {
        var state = makeState()
        try configureLifecycle(&state)
        try record(&state, planID: "plan-1", ordinal: 1, post: 5)
        try record(&state, planID: "plan-1", ordinal: 2, post: 6, success: false)   // a failed own step still accounts for the head
        try record(&state, planID: "plan-1", ordinal: 3, post: 7)
        XCTAssertTrue(PlanExecuteLoop.snapshotMatchesWorkspace(snapshot(planID: "plan-1"), control: state))
    }

    func testEarlierForeignHistoryBeforeTheSnapshotHeadIsIgnored() throws {
        // plan-0 wrote at revision 4→5 BEFORE plan-1 was generated at head-5; plan-1 then wrote 5→6.
        var state = makeState()
        try configureLifecycle(&state)
        try record(&state, planID: "plan-0", ordinal: 1, post: 5)
        try record(&state, planID: "plan-1", ordinal: 2, post: 6)
        XCTAssertTrue(PlanExecuteLoop.snapshotMatchesWorkspace(
            snapshot(planID: "plan-1", revision: 5, head: "manifest-head-5"), control: state))
    }

    // MARK: still forces a replan

    func testForeignReceiptAfterTheSnapshotHeadDoesNotMatch() throws {
        var state = makeState()
        try configureLifecycle(&state)
        try record(&state, planID: "plan-1", ordinal: 1, post: 5)
        try record(&state, planID: "plan-2", ordinal: 2, post: 6)   // someone else moved the workspace
        XCTAssertFalse(PlanExecuteLoop.snapshotMatchesWorkspace(snapshot(planID: "plan-1"), control: state))
    }

    func testHeadWithNoReceiptDoesNotMatch() throws {
        // The state sits at head-4 with no receipts; a plan generated at head-3 (an earlier state
        // no receipt accounts for) cannot prove the workspace only moved through its own actions.
        var state = makeState()
        try configureLifecycle(&state)
        XCTAssertFalse(PlanExecuteLoop.snapshotMatchesWorkspace(
            snapshot(planID: "plan-1", revision: 3, head: "manifest-head-3"), control: state))
    }

    func testOwnChainEndingShortOfTheCurrentHeadDoesNotMatch() throws {
        var state = makeState()
        try configureLifecycle(&state)
        try record(&state, planID: "plan-1", ordinal: 1, post: 5)
        try record(&state, planID: "plan-3", ordinal: 2, post: 6)
        // plan-1's chain stops at head-5; the current head-6 belongs to plan-3.
        XCTAssertFalse(PlanExecuteLoop.snapshotMatchesWorkspace(snapshot(planID: "plan-1"), control: state))
    }

    func testPolicyOrRevisionMismatchNeverMatches() throws {
        var state = makeState()
        try configureLifecycle(&state)
        try record(&state, planID: "plan-1", ordinal: 1, post: 5)
        XCTAssertFalse(PlanExecuteLoop.snapshotMatchesWorkspace(
            snapshot(planID: "plan-1", policy: "other-policy"), control: state))
        XCTAssertFalse(PlanExecuteLoop.snapshotMatchesWorkspace(
            snapshot(planID: "plan-1", revision: 99), control: state))
    }

    func testMissingSnapshotBindingsNeverMatch() throws {
        var state = makeState()
        try configureLifecycle(&state)
        let unbound = DurableExecutablePlanSnapshot(
            id: "plan-1", generation: 1, plan: ExecutablePlan(goal: "g", steps: []))
        XCTAssertFalse(PlanExecuteLoop.snapshotMatchesWorkspace(unbound, control: state))
    }

    // MARK: fixtures (same shapes as WorkspaceLifecycleRegressionTests)

    private func makeState() -> ReasoningControlState {
        ReasoningControlState(id: "own-actions", route: .planned, goalFingerprint: "goal-v1",
                              missionInstanceID: "mission-own-actions", updatedAt: 0)
    }

    private func configureLifecycle(_ state: inout ReasoningControlState) throws {
        try state.configureWorkspaceLifecycle(
            canonicalFunctionalObjectiveFingerprint: "objective-v1",
            workspaceManifestPolicyFingerprint: policy,
            workspaceManifestRevision: 4,
            workspaceManifestDigest: "manifest-head-4",
            lastAcknowledgedGovernedWorkspaceDigest: "governed-head-4")
    }

    /// A snapshot generated at revision 4 / head-4 unless told otherwise.
    private func snapshot(planID: String, policy: String? = nil, revision: Int = 4,
                          head: String = "manifest-head-4") -> DurableExecutablePlanSnapshot {
        DurableExecutablePlanSnapshot(
            id: planID, generation: 1, plan: ExecutablePlan(goal: "g", steps: []),
            workspaceManifestPolicyFingerprint: policy ?? self.policy,
            workspaceManifestRevision: revision, workspaceManifestDigest: head)
    }

    /// Begin + complete one durable workspace action for `planID`, advancing the head to `post`.
    private func record(_ state: inout ReasoningControlState, planID: String, ordinal: Int,
                        post: Int, success: Bool = true) throws {
        let intent = DurableWorkspaceActionIntent(
            id: "action-\(ordinal)", ordinal: ordinal,
            missionInstanceID: state.missionInstanceID!,
            canonicalFunctionalObjectiveFingerprint: state.canonicalFunctionalObjectiveFingerprint!,
            planID: planID, planRevision: 1, nodeID: "node-\(ordinal)", stepID: "step-\(ordinal)",
            attempt: 1, tool: "write_file", argsFingerprint: "args-\(ordinal)",
            capabilityFingerprint: "capability-v1", completionContractFingerprint: "contract-v1",
            executionPolicyFingerprint: "execution-policy-v1",
            workspaceManifestPolicyFingerprint: state.workspaceManifestPolicyFingerprint!,
            preWorkspaceManifestRevision: state.workspaceManifestRevision!,
            preWorkspaceManifestDigest: state.workspaceManifestDigest!,
            preGovernedWorkspaceDigest: state.lastAcknowledgedGovernedWorkspaceDigest!,
            priorReceiptDigest: state.workspaceActionReceipts?.last?.receiptDigest,
            startedAt: Double(10 + ordinal))
        try state.beginWorkspaceAction(intent)
        let receipt = DurableWorkspaceActionCompletionReceipt(
            intent: intent,
            postWorkspaceManifestRevision: post,
            postWorkspaceManifestDigest: "manifest-head-\(post)",
            postGovernedWorkspaceDigest: "governed-head-\(post)",
            success: success,
            completedAt: Double(20 + ordinal))
        try state.completeWorkspaceAction(receipt)
    }
}
