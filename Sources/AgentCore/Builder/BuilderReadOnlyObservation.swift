import Foundation

public struct BuilderReadOnlyObservationContext: Sendable, Equatable {
    public let builderContractID: String
    public let graphNodeIDs: [String]
    public let node: BuilderNode
    public let attempt: Int

    public init(builderContractID: String, graphNodeIDs: [String],
                node: BuilderNode, attempt: Int) throws {
        guard graphNodeIDs.contains(node.id) else {
            throw BuilderReadOnlyObservationError.nodeNotInGraph(node.id)
        }
        guard attempt > 0 else { throw BuilderReadOnlyObservationError.invalidAttempt }
        self.builderContractID = builderContractID
        self.graphNodeIDs = graphNodeIDs.sorted()
        self.node = node
        self.attempt = attempt
    }
}

public struct BuilderReadOnlyBaseline: Sendable, Equatable {
    public let builderContractID: String
    public let nodeID: String
    public let attempt: Int
    public let workspaceDigest: String
    public let pathStates: [BuilderObservedPathState]

    public init(builderContractID: String, nodeID: String, attempt: Int,
                workspaceDigest: String,
                pathStates: [BuilderObservedPathState] = []) throws {
        guard attempt > 0 else { throw BuilderReadOnlyObservationError.invalidAttempt }
        self.builderContractID = builderContractID
        self.nodeID = nodeID
        self.attempt = attempt
        self.workspaceDigest = try BuilderExecutionValidation.digest(
            workspaceDigest, field: "read-only baseline workspace digest")
        self.pathStates = pathStates.sorted { $0.path < $1.path }
    }
}

public struct BuilderReadOnlyObservation: Sendable, Equatable {
    public let builderContractID: String
    public let nodeID: String
    public let attempt: Int
    public let workspaceDigestBefore: String
    public let workspaceDigestAfter: String
    public let observedChangedPaths: [String]

    public init(builderContractID: String, nodeID: String, attempt: Int,
                workspaceDigestBefore: String, workspaceDigestAfter: String,
                observedChangedPaths: [String] = []) throws {
        guard attempt > 0 else { throw BuilderReadOnlyObservationError.invalidAttempt }
        self.builderContractID = builderContractID
        self.nodeID = nodeID
        self.attempt = attempt
        self.workspaceDigestBefore = try BuilderExecutionValidation.digest(
            workspaceDigestBefore, field: "read-only workspace digest before")
        self.workspaceDigestAfter = try BuilderExecutionValidation.digest(
            workspaceDigestAfter, field: "read-only workspace digest after")
        self.observedChangedPaths = try observedChangedPaths
            .map { try BuilderExecutionValidation.path($0) }.sorted()
    }
}

public struct BuilderReadOnlyRollbackRequest: Sendable {
    public let context: BuilderReadOnlyObservationContext
    public let baseline: BuilderReadOnlyBaseline
    public let observation: BuilderReadOnlyObservation?
    public let reason: String

    public init(context: BuilderReadOnlyObservationContext,
                baseline: BuilderReadOnlyBaseline,
                observation: BuilderReadOnlyObservation?, reason: String) {
        self.context = context
        self.baseline = baseline
        self.observation = observation
        self.reason = reason
    }
}

public struct BuilderReadOnlyRollbackObservation: Sendable, Equatable {
    public let builderContractID: String
    public let nodeID: String
    public let attempt: Int
    public let workspaceDigestAfter: String
    public let restoredPathStates: [BuilderObservedPathState]

    public init(builderContractID: String, nodeID: String, attempt: Int,
                workspaceDigestAfter: String,
                restoredPathStates: [BuilderObservedPathState] = []) throws {
        guard attempt > 0 else { throw BuilderReadOnlyObservationError.invalidAttempt }
        self.builderContractID = builderContractID
        self.nodeID = nodeID
        self.attempt = attempt
        self.workspaceDigestAfter = try BuilderExecutionValidation.digest(
            workspaceDigestAfter, field: "read-only rollback workspace digest")
        self.restoredPathStates = restoredPathStates.sorted { $0.path < $1.path }
    }
}

public protocol BuilderReadOnlyObservationSource: Sendable {
    func prepare(_ context: BuilderReadOnlyObservationContext) async throws
        -> BuilderReadOnlyBaseline
    func observe(context: BuilderReadOnlyObservationContext,
                 baseline: BuilderReadOnlyBaseline,
                 worker: BuilderWorkerReceipt) async throws -> BuilderReadOnlyObservation
    func rollback(_ request: BuilderReadOnlyRollbackRequest) async throws
        -> BuilderReadOnlyRollbackObservation
}

public protocol BuilderReadOnlyObservationSourceProvider: Sendable {
    func source(for context: BuilderReadOnlyObservationContext) async throws
        -> any BuilderReadOnlyObservationSource
}

struct BuilderReadOnlyExecutionGuard: Sendable {
    let context: BuilderReadOnlyObservationContext
    let source: any BuilderReadOnlyObservationSource

    func execute(_ operation: @Sendable () async throws -> BuilderWorkerReceipt) async throws
        -> BuilderWorkerReceipt {
        let baseline = try await source.prepare(context)
        guard baseline.builderContractID == context.builderContractID,
              baseline.nodeID == context.node.id,
              baseline.attempt == context.attempt else {
            throw BuilderReadOnlyObservationError.bindingMismatch
        }
        let worker: BuilderWorkerReceipt
        do {
            worker = try await operation()
        } catch {
            try await rollback(baseline: baseline, observation: nil, error: error)
            throw error
        }
        let observation: BuilderReadOnlyObservation
        do {
            observation = try await source.observe(
                context: context, baseline: baseline, worker: worker)
            try Self.validate(context: context, baseline: baseline, observation: observation)
        } catch {
            try await rollback(baseline: baseline, observation: nil, error: error)
            throw error
        }
        return worker
    }

    private func rollback(baseline: BuilderReadOnlyBaseline,
                          observation: BuilderReadOnlyObservation?,
                          error: Error) async throws {
        let rollback = try await source.rollback(.init(
            context: context, baseline: baseline,
            observation: observation, reason: String(reflecting: error)))
        try Self.validateRollback(
            context: context, baseline: baseline, rollback: rollback)
    }

    private static func validate(
        context: BuilderReadOnlyObservationContext,
        baseline: BuilderReadOnlyBaseline,
        observation: BuilderReadOnlyObservation
    ) throws {
        guard baseline.builderContractID == context.builderContractID,
              baseline.nodeID == context.node.id,
              baseline.attempt == context.attempt,
              observation.builderContractID == context.builderContractID,
              observation.nodeID == context.node.id,
              observation.attempt == context.attempt,
              observation.workspaceDigestBefore == baseline.workspaceDigest else {
            throw BuilderReadOnlyObservationError.bindingMismatch
        }
        guard observation.observedChangedPaths.isEmpty,
              observation.workspaceDigestAfter == baseline.workspaceDigest else {
            throw BuilderReadOnlyObservationError.workspaceMutated(
                observation.observedChangedPaths)
        }
    }

    private static func validateRollback(
        context: BuilderReadOnlyObservationContext,
        baseline: BuilderReadOnlyBaseline,
        rollback: BuilderReadOnlyRollbackObservation
    ) throws {
        guard rollback.builderContractID == context.builderContractID,
              rollback.nodeID == context.node.id,
              rollback.attempt == context.attempt,
              rollback.workspaceDigestAfter == baseline.workspaceDigest,
              rollback.restoredPathStates == baseline.pathStates else {
            throw BuilderReadOnlyObservationError.rollbackUnproven
        }
    }
}

public enum BuilderReadOnlyObservationError: Error, LocalizedError, Sendable, Equatable {
    case nodeNotInGraph(String)
    case invalidAttempt
    case bindingMismatch
    case workspaceMutated([String])
    case rollbackUnproven
    case missingTrustedSource(String)

    public var errorDescription: String? {
        switch self {
        case .nodeNotInGraph(let node): return "Read-only node \(node) is not in the graph"
        case .invalidAttempt: return "Read-only observation attempt must be positive"
        case .bindingMismatch: return "Read-only observation binding mismatch"
        case .workspaceMutated(let paths):
            return "Read-only worker mutated the workspace: \(paths.joined(separator: ", "))"
        case .rollbackUnproven: return "Read-only rollback did not restore the trusted baseline"
        case .missingTrustedSource(let node):
            return "Explicit read-only node \(node) requires a trusted workspace observation source"
        }
    }
}
