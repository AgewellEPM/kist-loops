import Foundation

/// The single "what needs a human" projection shared by every operator surface (HTTP
/// `GET /approvals`, the interactive REPL prompt, serve-mode logs). One source of truth so no
/// surface can disagree about what is pending: tasks parked at an approval gate (with the exact
/// revision an approve command must pin), tasks parked at a capability awaiting dispatch, and
/// stuck capability claims (a prior dispatch was claimed but never completed — crash-orphaned,
/// requiring human resolution; the pump never auto-retries them).
public struct SMLRuntimePendingView: Sendable, Codable, Equatable {
    public struct PendingApproval: Sendable, Codable, Equatable {
        public let taskID: String
        public let workflowID: String
        public let workflowVersion: String
        public let taskRevision: Int
        public let gateInstructionID: String
        public let gateOwner: String?
        public let gateReason: String?
        /// The instruction the gate guards — what approval will actually unleash.
        public let guardedInstructionID: String?
        public let waitingSinceEpoch: Double

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case workflowID = "workflow_id"
            case workflowVersion = "workflow_version"
            case taskRevision = "task_revision"
            case gateInstructionID = "gate_instruction_id"
            case gateOwner = "gate_owner"
            case gateReason = "gate_reason"
            case guardedInstructionID = "guarded_instruction_id"
            case waitingSinceEpoch = "waiting_since_epoch"
        }
    }

    public struct PendingCapability: Sendable, Codable, Equatable {
        public let taskID: String
        public let workflowID: String
        public let instructionID: String
        public let taskRevision: Int

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case workflowID = "workflow_id"
            case instructionID = "instruction_id"
            case taskRevision = "task_revision"
        }
    }

    public struct StuckClaim: Sendable, Codable, Equatable {
        public let taskID: String
        public let instructionID: String
        public let dispatchID: String
        public let driverID: String
        public let claimedAtEpoch: Double

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case instructionID = "instruction_id"
            case dispatchID = "dispatch_id"
            case driverID = "driver_id"
            case claimedAtEpoch = "claimed_at_epoch"
        }
    }

    public let approvals: [PendingApproval]
    public let capabilities: [PendingCapability]
    public let stuckClaims: [StuckClaim]

    enum CodingKeys: String, CodingKey {
        case approvals
        case capabilities
        case stuckClaims = "stuck_claims"
    }

    public var isEmpty: Bool {
        approvals.isEmpty && capabilities.isEmpty && stuckClaims.isEmpty
    }

    /// Builds the projection from one snapshot. Pure and deterministic — callers load the
    /// snapshot however they like (store.load() in hosts, a fixture in tests).
    public static func build(from snapshot: SMLRuntimeSnapshot) -> SMLRuntimePendingView {
        var approvals: [PendingApproval] = []
        var capabilities: [PendingCapability] = []
        var stuckClaims: [StuckClaim] = []

        for task in snapshot.tasks.values.sorted(by: { $0.taskID < $1.taskID }) {
            let workflowKey = SMLRuntimeSnapshot.workflowStorageKey(
                id: task.workflowID, version: task.workflowVersion
            )
            let workflow = snapshot.workflows[workflowKey]?.workflow
            switch task.status {
            case .waitingApproval:
                let gate = workflow?.instructions.first { $0.id == task.currentInstructionID }
                approvals.append(PendingApproval(
                    taskID: task.taskID,
                    workflowID: task.workflowID,
                    workflowVersion: task.workflowVersion,
                    taskRevision: task.revision,
                    gateInstructionID: task.currentInstructionID,
                    gateOwner: gate?.owner ?? task.waitingApprovalOwner,
                    gateReason: gate?.reason,
                    guardedInstructionID: gate?.next,
                    waitingSinceEpoch: task.updatedAtEpoch
                ))
            case .waitingCapability:
                if let claim = task.capabilityClaim {
                    stuckClaims.append(StuckClaim(
                        taskID: task.taskID,
                        instructionID: claim.instructionID,
                        dispatchID: claim.dispatchID,
                        driverID: claim.driverID,
                        claimedAtEpoch: claim.claimedAtEpoch
                    ))
                } else {
                    capabilities.append(PendingCapability(
                        taskID: task.taskID,
                        workflowID: task.workflowID,
                        instructionID: task.currentInstructionID,
                        taskRevision: task.revision
                    ))
                }
            case .ready, .completed, .escalated, .rolledBack, .refused:
                continue
            }
        }
        return SMLRuntimePendingView(
            approvals: approvals,
            capabilities: capabilities,
            stuckClaims: stuckClaims
        )
    }
}
