import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum BuilderWorkspaceTransactionError: Error, LocalizedError, Sendable, Equatable {
    case attestationInvalid
    case invalidConfiguration(String)
    case invalidPath(String)
    case controlPath(String)
    case traversalLimit
    case specialFile(String)
    case escapingSymlink(String)
    case preimageMismatch(String)
    case undeclaredMutation(String)
    case noMutation(String)
    case operationMismatch(String)
    case stateMismatch(String)
    case tampered
    case rollbackUnproven(String)

    public var errorDescription: String? {
        switch self {
        case .attestationInvalid: return "OS sandbox confinement attestation is missing or invalid"
        case .invalidConfiguration(let value): return "Invalid workspace transaction configuration: \(value)"
        case .invalidPath(let value): return "Invalid transaction path: \(value)"
        case .controlPath(let value): return "Mutation authority excludes control path: \(value)"
        case .traversalLimit: return "Workspace traversal exceeded its configured bound"
        case .specialFile(let value): return "Workspace contains unsupported special file: \(value)"
        case .escapingSymlink(let value): return "Workspace symlink escapes the staged tree: \(value)"
        case .preimageMismatch(let value): return "Workspace preimage compare-and-swap failed: \(value)"
        case .undeclaredMutation(let value): return "Workspace contains undeclared mutation: \(value)"
        case .noMutation(let value): return "Workspace produced no declared mutation: \(value)"
        case .operationMismatch(let value): return "Workspace mutation does not match its declared operation: \(value)"
        case .stateMismatch(let value): return "Workspace transaction state mismatch: \(value)"
        case .tampered: return "Workspace transaction state failed canonical seal validation"
        case .rollbackUnproven(let value): return "Workspace rollback could not be proven: \(value)"
        }
    }
}

public struct BuilderSandboxAttestationRequest: Sendable, Equatable {
    public let contractFingerprint: String
    public let builderContractID: String
    public let nodeID: String
    public let attempt: Int
    public let stagedRoot: String
    public let governedRootDigest: String
    public let challenge: String
    public let stage: BuilderExecutionStage
    /// Host-owned paths that verification code must not read. The OS-sandbox policy binds these
    /// paths into its signed evidence; callers use this for source repositories, archives, and
    /// other authority stores that sit outside the staged workspace.
    public let forbiddenReadPaths: [String]

    public init(contractFingerprint: String, builderContractID: String, nodeID: String,
                attempt: Int, stagedRoot: String, governedRootDigest: String,
                challenge: String, stage: BuilderExecutionStage = .build,
                forbiddenReadPaths: [String] = []) {
        self.contractFingerprint = contractFingerprint
        self.builderContractID = builderContractID
        self.nodeID = nodeID
        self.attempt = attempt
        self.stagedRoot = stagedRoot
        self.governedRootDigest = governedRootDigest
        self.challenge = challenge
        self.stage = stage
        self.forbiddenReadPaths = forbiddenReadPaths
    }
}

public struct BuilderSandboxAttestation: Codable, Sendable, Equatable {
    public let contractFingerprint: String
    public let nodeID: String
    public let attempt: Int
    public let stagedRoot: String
    public let governedRootDigest: String
    public let challenge: String
    public let mechanism: String
    public let enforced: Bool
    public let evidenceDigest: String
    public let stage: BuilderExecutionStage?

    public init(request: BuilderSandboxAttestationRequest, mechanism: String,
                enforced: Bool, evidenceDigest: String) throws {
        let trimmed = mechanism.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BuilderWorkspaceTransactionError.attestationInvalid }
        self.contractFingerprint = request.contractFingerprint
        self.nodeID = request.nodeID
        self.attempt = request.attempt
        self.stagedRoot = request.stagedRoot
        self.governedRootDigest = request.governedRootDigest
        self.challenge = request.challenge
        self.mechanism = trimmed
        self.enforced = enforced
        self.evidenceDigest = try BuilderExecutionValidation.digest(
            evidenceDigest, field: "sandbox attestation evidence")
        self.stage = request.stage
    }

    public func validate(_ request: BuilderSandboxAttestationRequest) throws {
        guard enforced,
              contractFingerprint == request.contractFingerprint,
              nodeID == request.nodeID,
              attempt == request.attempt,
              stagedRoot == request.stagedRoot,
              governedRootDigest == request.governedRootDigest,
              challenge == request.challenge,
              stage == request.stage,
              !mechanism.isEmpty else {
            throw BuilderWorkspaceTransactionError.attestationInvalid
        }
    }
}

public protocol BuilderSandboxAttestor: Sendable {
    func attest(_ request: BuilderSandboxAttestationRequest) async throws
        -> BuilderSandboxAttestation
}

public struct BuilderWorkspaceRootIdentity: Codable, Sendable, Equatable {
    public let canonicalPath: String
    public let deviceID: UInt64
    public let inode: UInt64

    public init(canonicalPath: String, deviceID: UInt64, inode: UInt64) {
        self.canonicalPath = canonicalPath
        self.deviceID = deviceID
        self.inode = inode
    }

    public static func capture(rootPath: String) throws -> Self {
        let standardized = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL.path
        guard standardized.hasPrefix("/"),
              let resolvedPointer = realpath(standardized, nil) else {
            throw BuilderWorkspaceTransactionError.invalidConfiguration(
                "workspace root must be an existing canonical absolute directory")
        }
        defer { free(resolvedPointer) }
        let resolved = String(cString: resolvedPointer)
        var status = stat()
        guard lstat(resolved, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw BuilderWorkspaceTransactionError.invalidConfiguration(
                "workspace root must be an existing canonical absolute directory")
        }
        return .init(canonicalPath: resolved, deviceID: UInt64(status.st_dev),
                     inode: UInt64(status.st_ino))
    }
}

public struct BuilderExecutionWorkspace: Sendable, Equatable {
    public let rootPath: String
    public let rootIdentity: BuilderWorkspaceRootIdentity
    public let attestation: BuilderSandboxAttestation
    public let workspaceDigest: String?

    public init(rootPath: String, rootIdentity: BuilderWorkspaceRootIdentity,
                attestation: BuilderSandboxAttestation,
                workspaceDigest: String? = nil) {
        self.rootPath = rootPath
        self.rootIdentity = rootIdentity
        self.attestation = attestation
        self.workspaceDigest = workspaceDigest
    }
}

public struct BuilderAggregateTransactionDescriptor: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let aggregateID: String
    public let parentContractFingerprint: String
    public let graphFingerprint: String
    public let expectedNodeIDs: [String]
    public let bindingDigest: String

    private struct Binding: Codable {
        let schemaVersion: Int
        let aggregateID: String
        let parentContractFingerprint: String
        let graphFingerprint: String
        let expectedNodeIDs: [String]
    }

    public init(aggregateID: String, parentContractFingerprint: String,
                graphFingerprint: String, expectedNodeIDs: [String]) throws {
        let identifier = try BuilderExecutionValidation.digest(
            aggregateID, field: "aggregate transaction ID")
        let parent = try BuilderExecutionValidation.digest(
            parentContractFingerprint, field: "aggregate parent fingerprint")
        let graph = try BuilderExecutionValidation.digest(
            graphFingerprint, field: "aggregate graph fingerprint")
        let nodes = try expectedNodeIDs.map {
            try BuilderExecutionValidation.identifier($0, field: "aggregate child node")
        }.sorted()
        guard nodes.count > 1, Set(nodes).count == nodes.count else {
            throw BuilderWorkspaceTransactionError.invalidConfiguration(
                "aggregate transactions require at least two unique child nodes")
        }
        schemaVersion = 1
        self.aggregateID = identifier
        self.parentContractFingerprint = parent
        self.graphFingerprint = graph
        self.expectedNodeIDs = nodes
        let binding = Binding(
            schemaVersion: 1, aggregateID: identifier,
            parentContractFingerprint: parent, graphFingerprint: graph,
            expectedNodeIDs: nodes)
        bindingDigest = BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(binding), as: UTF8.self))
    }

    public func validate() throws {
        let rebuilt = try Self(
            aggregateID: aggregateID,
            parentContractFingerprint: parentContractFingerprint,
            graphFingerprint: graphFingerprint,
            expectedNodeIDs: expectedNodeIDs)
        guard schemaVersion == 1, rebuilt == self else {
            throw BuilderWorkspaceTransactionError.tampered
        }
    }
}

public enum BuilderAggregateTransactionStatus: String, Codable, Sendable, Equatable {
    case collecting, ready, reviewApproved, committed, finalized, rolledBack
}

public struct BuilderAggregateTransactionReceipt: Codable, Sendable, Equatable {
    public let aggregateID: String
    public let descriptorBindingDigest: String
    public let workspaceDigest: String
    public let verificationSubject: String
    public let childNodeIDs: [String]
    public let status: BuilderAggregateTransactionStatus
    public let receiptDigest: String

    public init(descriptor: BuilderAggregateTransactionDescriptor,
                workspaceDigest: String, childNodeIDs: [String],
                status: BuilderAggregateTransactionStatus) throws {
        try descriptor.validate()
        self.aggregateID = descriptor.aggregateID
        self.descriptorBindingDigest = descriptor.bindingDigest
        self.workspaceDigest = try BuilderExecutionValidation.digest(
            workspaceDigest, field: "aggregate workspace digest")
        self.verificationSubject = "builder-aggregate://\(descriptor.aggregateID)"
        self.childNodeIDs = childNodeIDs.sorted()
        self.status = status
        let canonical = [aggregateID, descriptorBindingDigest, self.workspaceDigest,
                         verificationSubject, self.childNodeIDs.joined(separator: ","),
                         status.rawValue].joined(separator: "\u{0}")
        self.receiptDigest = BuilderEvidenceDigest.sha256(canonical)
    }
}

public struct BuilderTransactionPromotionReceipt: Codable, Sendable, Equatable {
    public let contractFingerprint: String
    public let builderContractID: String
    public let nodeID: String
    public let attempt: Int
    public let workspaceDigest: String
    public let verifierSubjectDigest: String?
    public let operations: [BuilderObservedMutation]
    public let receiptDigest: String

    public init(contractFingerprint: String, builderContractID: String, nodeID: String,
                attempt: Int, workspaceDigest: String,
                verifierSubjectDigest: String? = nil,
                operations: [BuilderObservedMutation]) throws {
        guard attempt > 0 else {
            throw BuilderWorkspaceTransactionError.stateMismatch("invalid promotion attempt")
        }
        self.contractFingerprint = try BuilderExecutionValidation.digest(
            contractFingerprint, field: "promotion contract fingerprint")
        self.builderContractID = try BuilderExecutionValidation.identifier(
            builderContractID, field: "promotion Builder contract")
        self.nodeID = try BuilderExecutionValidation.identifier(nodeID, field: "promotion node")
        self.attempt = attempt
        self.workspaceDigest = try BuilderExecutionValidation.digest(
            workspaceDigest, field: "promotion workspace digest")
        self.verifierSubjectDigest = try verifierSubjectDigest.map {
            try BuilderExecutionValidation.digest(
                $0, field: "promotion verifier subject digest")
        }
        self.operations = operations.sorted { $0.path < $1.path }
        struct Binding: Codable {
            let contractFingerprint: String; let builderContractID: String
            let nodeID: String; let attempt: Int; let workspaceDigest: String
            let verifierSubjectDigest: String?
            let operations: [BuilderObservedMutation]
        }
        let binding = Binding(contractFingerprint: self.contractFingerprint,
                              builderContractID: self.builderContractID,
                              nodeID: self.nodeID, attempt: attempt,
                              workspaceDigest: self.workspaceDigest,
                              verifierSubjectDigest: self.verifierSubjectDigest,
                              operations: self.operations)
        self.receiptDigest = BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(binding), as: UTF8.self))
    }

    public var hasValidReceiptDigest: Bool {
        guard let rebuilt = try? Self(
            contractFingerprint: contractFingerprint,
            builderContractID: builderContractID,
            nodeID: nodeID,
            attempt: attempt,
            workspaceDigest: workspaceDigest,
            verifierSubjectDigest: verifierSubjectDigest,
            operations: operations) else { return false }
        return rebuilt == self
    }
}

public protocol BuilderTransactionalStageObservationSource: BuilderStageObservationSource {
    var usesOSProcessSandbox: Bool { get }
    func executionWorkspace(for context: BuilderStageContext) async throws
        -> BuilderExecutionWorkspace
    func commit(context: BuilderStageContext, verifiedWorkspaceDigest: String) async throws
    func promotionReceipt(context: BuilderStageContext) async throws
        -> BuilderTransactionPromotionReceipt
    func markReviewApproved(context: BuilderStageContext) async throws
    func finalize(context: BuilderStageContext) async throws
    func releaseRetainedData(context: BuilderStageContext) async throws
    func rollbackCommitted(context: BuilderStageContext, reason: String) async throws
        -> BuilderRollbackObservation
    func verifyFinalized(context: BuilderStageContext) async throws
}

public protocol BuilderAggregateTransactionalStageObservationSource:
    BuilderTransactionalStageObservationSource {
    func beginAggregate(_ descriptor: BuilderAggregateTransactionDescriptor) async throws
    func registerAggregateChild(_ descriptor: BuilderAggregateTransactionDescriptor,
                                context: BuilderStageContext) async throws
    func aggregateDescriptor(for context: BuilderStageContext) async throws
        -> BuilderAggregateTransactionDescriptor?
    func assertAggregateReady(_ descriptor: BuilderAggregateTransactionDescriptor) async throws
        -> BuilderAggregateTransactionReceipt
    func markAggregateReviewApproved(_ descriptor: BuilderAggregateTransactionDescriptor,
                                     commitEpoch: String) async throws
    func finalizeAggregate(_ descriptor: BuilderAggregateTransactionDescriptor) async throws
        -> BuilderAggregateTransactionReceipt
    func completeAggregate(_ descriptor: BuilderAggregateTransactionDescriptor) async throws
    func releaseAggregate(_ descriptor: BuilderAggregateTransactionDescriptor) async throws
    func rollbackAggregate(_ descriptor: BuilderAggregateTransactionDescriptor,
                           reason: String) async throws
    func verifyAggregateFinalized(_ descriptor: BuilderAggregateTransactionDescriptor) async throws
        -> BuilderAggregateTransactionReceipt
}
