import Foundation
import XCTest
@testable import AgentCore

final class WorkspaceLifecycleRegressionTests: XCTestCase {
    func testConfigureWorkspaceLifecycleBindsObjectivePolicyAndInitialHeads() throws {
        var state = makeState(id: "binding")

        try configureLifecycle(&state)
        try configureLifecycle(&state)

        XCTAssertEqual(state.schemaVersion, ReasoningControlState.currentSchemaVersion)
        XCTAssertEqual(state.canonicalFunctionalObjectiveFingerprint, "objective-v1")
        XCTAssertEqual(state.workspaceManifestPolicyFingerprint, "manifest-policy-v1")
        XCTAssertEqual(state.workspaceManifestRevision, 4)
        XCTAssertEqual(state.workspaceManifestDigest, "manifest-head-4")
        XCTAssertNil(state.previousWorkspaceManifestDigest)
        XCTAssertEqual(state.lastAcknowledgedGovernedWorkspaceDigest, "governed-head-4")
        XCTAssertNil(state.activeWorkspaceAction)
        XCTAssertEqual(state.workspaceActionReceipts, [])

        XCTAssertThrowsError(try state.configureWorkspaceLifecycle(
            canonicalFunctionalObjectiveFingerprint: "different-objective",
            workspaceManifestPolicyFingerprint: "manifest-policy-v1",
            workspaceManifestRevision: 4,
            workspaceManifestDigest: "manifest-head-4",
            lastAcknowledgedGovernedWorkspaceDigest: "governed-head-4"
        )) { error in
            self.assertInvalidState(error)
        }
    }

    func testStartedWorkspaceActionPreventsBlindInterruptedNodeRecovery() throws {
        var state = makeState(id: "crash-gap")
        try configureLifecycle(&state)
        let node = ReasoningPlanNode(id: "node-1", title: "Mutate workspace")
        try state.installPlanNodes([node], acceptedIDs: [node.id])
        try state.activatePlanNode(node.id)
        let started = makeIntent(state: state, id: "action-1", ordinal: 1)
        try state.beginWorkspaceAction(started)

        XCTAssertThrowsError(try state.recoverInterruptedPlanNode()) { error in
            self.assertInvalidState(error)
        }

        XCTAssertEqual(state.activeWorkspaceAction, started)
        XCTAssertEqual(state.activePlanNodeID, node.id)
        XCTAssertEqual(state.planNodes[node.id]?.phase, .active)
        XCTAssertEqual(state.recoveryCount, 0)
        XCTAssertEqual(state.workspaceActionReceipts, [])
    }

    func testValidWorkspaceCompletionsAdvanceHeadsAndAppendReceiptChain() throws {
        var state = makeState(id: "receipt-chain")
        try configureLifecycle(&state)
        let firstIntent = makeIntent(state: state, id: "action-1", ordinal: 1)
        try state.beginWorkspaceAction(firstIntent)
        let firstReceipt = DurableWorkspaceActionCompletionReceipt(
            intent: firstIntent,
            postWorkspaceManifestRevision: 5,
            postWorkspaceManifestDigest: "manifest-head-5",
            postGovernedWorkspaceDigest: "governed-head-5",
            success: true,
            completedAt: 11
        )
        try state.completeWorkspaceAction(firstReceipt)

        XCTAssertNil(state.activeWorkspaceAction)
        XCTAssertEqual(state.previousWorkspaceManifestDigest, "manifest-head-4")
        XCTAssertEqual(state.workspaceManifestRevision, 5)
        XCTAssertEqual(state.workspaceManifestDigest, "manifest-head-5")
        XCTAssertEqual(state.lastAcknowledgedGovernedWorkspaceDigest, "governed-head-5")
        XCTAssertEqual(state.workspaceActionReceipts, [firstReceipt])
        XCTAssertTrue(firstReceipt.hasValidReceiptDigest)

        let secondIntent = makeIntent(state: state, id: "action-2", ordinal: 2)
        XCTAssertEqual(secondIntent.priorReceiptDigest, firstReceipt.receiptDigest)
        try state.beginWorkspaceAction(secondIntent)
        let secondReceipt = DurableWorkspaceActionCompletionReceipt(
            intent: secondIntent,
            postWorkspaceManifestRevision: 6,
            postWorkspaceManifestDigest: "manifest-head-6",
            postGovernedWorkspaceDigest: "governed-head-6",
            success: false,
            completedAt: 12
        )
        try state.completeWorkspaceAction(secondReceipt)

        XCTAssertEqual(state.previousWorkspaceManifestDigest, "manifest-head-5")
        XCTAssertEqual(state.workspaceManifestRevision, 6)
        XCTAssertEqual(state.workspaceManifestDigest, "manifest-head-6")
        XCTAssertEqual(state.lastAcknowledgedGovernedWorkspaceDigest, "governed-head-6")
        XCTAssertEqual(state.workspaceActionReceipts, [firstReceipt, secondReceipt])
        XCTAssertEqual(state.workspaceActionReceipts?.last?.intent.priorReceiptDigest,
                       firstReceipt.receiptDigest)
        XCTAssertNoThrow(try state.validateWorkspaceLifecycle())
    }

    func testWrongOrStaleWorkspaceCompletionIsRejectedWithoutAdvancingHeads() throws {
        var state = makeState(id: "stale-completion")
        try configureLifecycle(&state)
        let started = makeIntent(state: state, id: "action-1", ordinal: 1)
        try state.beginWorkspaceAction(started)

        let wrongIntent = makeIntent(state: state, id: "different-action", ordinal: 1)
        let wrongReceipt = DurableWorkspaceActionCompletionReceipt(
            intent: wrongIntent,
            postWorkspaceManifestRevision: 5,
            postWorkspaceManifestDigest: "manifest-head-5",
            postGovernedWorkspaceDigest: "governed-head-5",
            success: true,
            completedAt: 11
        )
        XCTAssertThrowsError(try state.completeWorkspaceAction(wrongReceipt)) { error in
            self.assertInvalidState(error)
        }

        let staleReceipt = DurableWorkspaceActionCompletionReceipt(
            intent: started,
            postWorkspaceManifestRevision: 4,
            postWorkspaceManifestDigest: "manifest-head-4",
            postGovernedWorkspaceDigest: "governed-head-4",
            success: true,
            completedAt: 11
        )
        XCTAssertThrowsError(try state.completeWorkspaceAction(staleReceipt)) { error in
            self.assertInvalidState(error)
        }

        XCTAssertEqual(state.activeWorkspaceAction, started)
        XCTAssertEqual(state.workspaceManifestRevision, 4)
        XCTAssertEqual(state.workspaceManifestDigest, "manifest-head-4")
        XCTAssertEqual(state.lastAcknowledgedGovernedWorkspaceDigest, "governed-head-4")
        XCTAssertEqual(state.workspaceActionReceipts, [])
    }

    func testCanonicalWorkspaceAliasesContendAndSerializeAcrossMissionIDs() throws {
        let estate = temporaryDirectory("workspace-lock-estate")
        let workspace = temporaryDirectory("workspace-lock-root")
        let alias = workspace.deletingLastPathComponent()
            .appendingPathComponent("workspace-lock-alias-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: estate)
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: alias.path,
                                                   withDestinationPath: workspace.path)
        let coordinator = WorkspaceExecutionCoordinator(
            lockDirectory: estate.appendingPathComponent("workspace-locks", isDirectory: true))
        let first = try coordinator.acquire(
            projectRoot: workspace.path, missionInstanceID: "mission-a", blocking: false)

        XCTAssertThrowsError(try coordinator.acquire(
            projectRoot: alias.path, missionInstanceID: "mission-b", blocking: false
        )) { error in
            guard case WorkspaceExecutionCoordinatorError.lockUnavailable(let root) = error else {
                return XCTFail("expected lockUnavailable, got \(error)")
            }
            XCTAssertEqual(root, first.canonicalProjectRoot)
        }

        first.release()
        let second = try coordinator.acquire(
            projectRoot: alias.path, missionInstanceID: "mission-b", blocking: false)
        defer { second.release() }
        XCTAssertEqual(second.canonicalProjectRoot, first.canonicalProjectRoot)
        XCTAssertEqual(second.lockFileURL, first.lockFileURL)
        XCTAssertEqual(second.missionInstanceID, "mission-b")
    }

    private func makeState(id: String) -> ReasoningControlState {
        ReasoningControlState(
            id: id,
            route: .planned,
            goalFingerprint: "goal-v1",
            missionInstanceID: "mission-\(id)",
            updatedAt: 0
        )
    }

    private func configureLifecycle(_ state: inout ReasoningControlState) throws {
        try state.configureWorkspaceLifecycle(
            canonicalFunctionalObjectiveFingerprint: "objective-v1",
            workspaceManifestPolicyFingerprint: "manifest-policy-v1",
            workspaceManifestRevision: 4,
            workspaceManifestDigest: "manifest-head-4",
            lastAcknowledgedGovernedWorkspaceDigest: "governed-head-4"
        )
    }

    private func makeIntent(state: ReasoningControlState, id: String,
                            ordinal: Int) -> DurableWorkspaceActionIntent {
        DurableWorkspaceActionIntent(
            id: id,
            ordinal: ordinal,
            missionInstanceID: state.missionInstanceID!,
            canonicalFunctionalObjectiveFingerprint:
                state.canonicalFunctionalObjectiveFingerprint!,
            planID: "plan-1",
            planRevision: 1,
            nodeID: "node-1",
            stepID: "step-\(ordinal)",
            attempt: 1,
            tool: "run_command",
            argsFingerprint: "args-\(ordinal)",
            capabilityFingerprint: "capability-v1",
            completionContractFingerprint: "contract-v1",
            executionPolicyFingerprint: "execution-policy-v1",
            workspaceManifestPolicyFingerprint: state.workspaceManifestPolicyFingerprint!,
            preWorkspaceManifestRevision: state.workspaceManifestRevision!,
            preWorkspaceManifestDigest: state.workspaceManifestDigest!,
            preGovernedWorkspaceDigest: state.lastAcknowledgedGovernedWorkspaceDigest!,
            priorReceiptDigest: state.workspaceActionReceipts?.last?.receiptDigest,
            startedAt: 10
        )
    }

    private func assertInvalidState(_ error: Error, file: StaticString = #filePath,
                                    line: UInt = #line) {
        guard case ReasoningControlError.invalidState = error else {
            return XCTFail("expected invalidState, got \(error)", file: file, line: line)
        }
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}
