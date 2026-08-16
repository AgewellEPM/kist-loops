import Foundation

public enum BuilderPipelineCheckpointPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case prepared, running, verifying, committed, reviewApproved, finalized
    case rollingBack, rolledBack, failed
}

public struct BuilderPipelineCheckpoint: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let contractFingerprint: String
    public let contractSealReference: String?
    public let builderContractID: String
    public let nodeID: String
    public let attempt: Int
    public let sequence: Int
    public let phase: BuilderPipelineCheckpointPhase
    public let baseline: BuilderStageBaseline
    public let currentWorkspaceDigest: String?
    public let failureReason: String?
}

private struct SealedBuilderPipelineCheckpoint: Codable, Equatable {
    let checkpoint: BuilderPipelineCheckpoint
    let seal: String
}

public enum BuilderPipelineCheckpointError: Error, LocalizedError, Sendable, Equatable {
    case contractMismatch
    case invalidAttempt
    case invalidTransition(from: BuilderPipelineCheckpointPhase, to: BuilderPipelineCheckpointPhase)
    case conflictingPrepare
    case tampered

    public var errorDescription: String? {
        switch self {
        case .contractMismatch: return "Pipeline checkpoint contract/node/digest binding mismatch"
        case .invalidAttempt: return "Pipeline checkpoint attempt is invalid or nonmonotonic"
        case .invalidTransition(let from, let to):
            return "Invalid pipeline checkpoint transition: \(from.rawValue) -> \(to.rawValue)"
        case .conflictingPrepare: return "Prepared pipeline checkpoint conflicts with durable state"
        case .tampered: return "Pipeline checkpoint failed canonical ForgeSeal validation"
        }
    }
}

public actor BuilderPipelineCheckpointStore {
    private let directoryURL: URL
    private let contract: BuilderExecutionContract
    private let contractFingerprint: String
    private let contractSealReference: String?

    public init(directoryURL: URL, contract: BuilderExecutionContract,
                contractSealReference: String? = nil) throws {
        self.directoryURL = directoryURL
        self.contract = contract
        self.contractFingerprint = try contract.fingerprint()
        self.contractSealReference = try contractSealReference.map {
            try BuilderExecutionValidation.digest($0, field: "checkpoint contract seal reference")
        }
    }

    public func load(nodeID: String) throws -> BuilderPipelineCheckpoint? {
        guard nodeID == contract.builderNodeID else { throw BuilderPipelineCheckpointError.contractMismatch }
        let url = fileURL(nodeID: nodeID)
        guard let data = try BuilderDurableIO.readSecure(url) else { return nil }
        let envelope = try JSONDecoder().decode(SealedBuilderPipelineCheckpoint.self, from: data)
        guard try BuilderDurableIO.canonicalData(envelope) == data else {
            throw BuilderPipelineCheckpointError.tampered
        }
        let checkpoint = envelope.checkpoint
        let canonical = String(decoding: try BuilderDurableIO.canonicalData(checkpoint), as: UTF8.self)
        guard ForgeSeal.verify(canonical, seal: envelope.seal), checkpoint.schemaVersion == 1,
              checkpoint.contractFingerprint == contractFingerprint,
              checkpoint.contractSealReference == contractSealReference,
              checkpoint.builderContractID == contract.builderContractID,
              checkpoint.nodeID == nodeID,
              checkpoint.baseline.contractFingerprint == contractFingerprint,
              checkpoint.baseline.builderContractID == contract.builderContractID,
              checkpoint.baseline.nodeID == nodeID,
              checkpoint.baseline.attempt == checkpoint.attempt else {
            throw BuilderPipelineCheckpointError.tampered
        }
        return checkpoint
    }

    @discardableResult
    public func prepare(nodeID: String, attempt: Int,
                        baseline: BuilderStageBaseline) throws -> BuilderPipelineCheckpoint {
        guard nodeID == contract.builderNodeID,
              baseline.contractFingerprint == contractFingerprint,
              baseline.builderContractID == contract.builderContractID,
              baseline.nodeID == nodeID, baseline.attempt == attempt else {
            throw BuilderPipelineCheckpointError.contractMismatch
        }
        guard attempt > 0 else { throw BuilderPipelineCheckpointError.invalidAttempt }
        if let existing = try load(nodeID: nodeID) {
            if existing.attempt == attempt, existing.phase == .prepared,
               existing.baseline == baseline { return existing }
            guard existing.phase == .rolledBack, attempt == existing.attempt + 1 else {
                throw BuilderPipelineCheckpointError.conflictingPrepare
            }
            return try publish(.init(
                schemaVersion: 1, contractFingerprint: contractFingerprint,
                contractSealReference: contractSealReference,
                builderContractID: contract.builderContractID, nodeID: nodeID,
                attempt: attempt, sequence: existing.sequence + 1, phase: .prepared,
                baseline: baseline, currentWorkspaceDigest: baseline.workspaceDigest,
                failureReason: nil))
        }
        return try publish(.init(
            schemaVersion: 1, contractFingerprint: contractFingerprint,
            contractSealReference: contractSealReference,
            builderContractID: contract.builderContractID, nodeID: nodeID,
            attempt: attempt, sequence: 0, phase: .prepared, baseline: baseline,
            currentWorkspaceDigest: baseline.workspaceDigest, failureReason: nil))
    }

    @discardableResult
    public func transition(nodeID: String, attempt: Int, to phase: BuilderPipelineCheckpointPhase,
                           currentWorkspaceDigest: String?, failureReason: String? = nil) throws
        -> BuilderPipelineCheckpoint {
        guard let existing = try load(nodeID: nodeID), existing.attempt == attempt else {
            throw BuilderPipelineCheckpointError.invalidAttempt
        }
        guard Self.allowed(existing.phase, phase) else {
            throw BuilderPipelineCheckpointError.invalidTransition(from: existing.phase, to: phase)
        }
        let digest = try currentWorkspaceDigest.map {
            try BuilderExecutionValidation.digest($0, field: "checkpoint workspace digest")
        }
        return try publish(.init(
            schemaVersion: 1, contractFingerprint: contractFingerprint,
            contractSealReference: existing.contractSealReference,
            builderContractID: contract.builderContractID, nodeID: nodeID,
            attempt: attempt, sequence: existing.sequence + 1, phase: phase,
            baseline: existing.baseline,
            currentWorkspaceDigest: digest ?? existing.currentWorkspaceDigest,
            failureReason: failureReason))
    }

    private func publish(_ checkpoint: BuilderPipelineCheckpoint) throws -> BuilderPipelineCheckpoint {
        let canonical = String(decoding: try BuilderDurableIO.canonicalData(checkpoint), as: UTF8.self)
        let seal = ForgeSeal.sign(canonical)
        guard !seal.isEmpty else { throw BuilderPipelineCheckpointError.tampered }
        try BuilderDurableIO.writeAtomic(
            try BuilderDurableIO.canonicalData(
                SealedBuilderPipelineCheckpoint(checkpoint: checkpoint, seal: seal)),
            to: fileURL(nodeID: checkpoint.nodeID))
        return checkpoint
    }

    private func fileURL(nodeID: String) -> URL {
        directoryURL.appendingPathComponent("\(contractFingerprint.prefix(16))-\(nodeID).json")
    }

    private static func allowed(_ from: BuilderPipelineCheckpointPhase,
                                _ to: BuilderPipelineCheckpointPhase) -> Bool {
        switch (from, to) {
        case (.prepared, .running), (.running, .verifying), (.verifying, .committed),
             (.committed, .reviewApproved), (.reviewApproved, .finalized),
             (.prepared, .rollingBack), (.running, .rollingBack), (.verifying, .rollingBack),
             (.committed, .rollingBack), (.reviewApproved, .rollingBack),
             (.finalized, .rollingBack),
             (.rollingBack, .rolledBack),
             (.prepared, .failed), (.running, .failed), (.verifying, .failed),
             (.rollingBack, .failed): return true
        default: return false
        }
    }
}
