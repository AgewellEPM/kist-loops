import Foundation

public enum BuilderNodeExecutionClass: String, Codable, Sendable, Equatable {
    case mutation
    case readOnly
}

public struct BuilderGraphExecutionPolicy: Codable, Sendable, Equatable {
    public let nodeClasses: [String: BuilderNodeExecutionClass]

    public init(nodeClasses: [String: BuilderNodeExecutionClass] = [:]) {
        self.nodeClasses = nodeClasses
    }

    public func executionClass(for nodeID: String) -> BuilderNodeExecutionClass {
        nodeClasses[nodeID] ?? .mutation
    }

    func validate(graph: BuilderGraph) throws {
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        for (nodeID, executionClass) in nodeClasses {
            guard let node = nodes[nodeID] else {
                throw BuilderDynamicContractError.policyReferencesUnknownNode(nodeID)
            }
            if executionClass == .readOnly,
               node.resources.contains(where: { $0.access == .write }) {
                throw BuilderDynamicContractError.readOnlyNodeClaimsWrite(nodeID)
            }
        }
    }
}

public struct BuilderCommittedDependencyResult: Sendable, Equatable {
    public let node: BuilderNode
    public let worker: BuilderWorkerReceipt
    public let verification: BuilderVerifierReceipt
    public let bindingDigest: String?
    public let bindingSeal: String?
    public let acceptedCheckpointSequence: Int?

    public init(node: BuilderNode, worker: BuilderWorkerReceipt,
                verification: BuilderVerifierReceipt) {
        self.node = node
        self.worker = worker
        self.verification = verification
        self.bindingDigest = nil
        self.bindingSeal = nil
        self.acceptedCheckpointSequence = nil
    }

    init(node: BuilderNode, worker: BuilderWorkerReceipt,
         verification: BuilderVerifierReceipt, parentContractFingerprint: String,
         graphFingerprint: String, consumerNodeID: String, consumerAttempt: Int,
         acceptedCheckpointSequence: Int) throws {
        guard worker.nodeID == node.id, verification.scope == .node(node.id),
              verification.deterministic, verification.passed,
              verification.checks.allSatisfy(\.passed), acceptedCheckpointSequence >= 0 else {
            throw BuilderDynamicContractError.invalidDependencyResults(consumerNodeID)
        }
        self.node = node; self.worker = worker; self.verification = verification
        self.acceptedCheckpointSequence = acceptedCheckpointSequence
        let canonical = try Self.bindingCanonical(
            node: node, worker: worker, verification: verification,
            parentContractFingerprint: parentContractFingerprint,
            graphFingerprint: graphFingerprint, consumerNodeID: consumerNodeID,
            consumerAttempt: consumerAttempt,
            acceptedCheckpointSequence: acceptedCheckpointSequence)
        self.bindingDigest = BuilderEvidenceDigest.sha256(canonical)
        self.bindingSeal = ForgeSeal.sign(canonical)
        guard bindingSeal?.isEmpty == false else {
            throw BuilderDynamicContractError.invalidDependencyResults(consumerNodeID)
        }
    }

    func validate(parentContractFingerprint: String, graphFingerprint: String,
                  consumerNodeID: String, consumerAttempt: Int,
                  currentCheckpointSequence: Int) throws {
        guard let bindingDigest, let bindingSeal, let acceptedCheckpointSequence,
              acceptedCheckpointSequence <= currentCheckpointSequence else {
            throw BuilderDynamicContractError.invalidDependencyResults(consumerNodeID)
        }
        let canonical = try Self.bindingCanonical(
            node: node, worker: worker, verification: verification,
            parentContractFingerprint: parentContractFingerprint,
            graphFingerprint: graphFingerprint, consumerNodeID: consumerNodeID,
            consumerAttempt: consumerAttempt,
            acceptedCheckpointSequence: acceptedCheckpointSequence)
        guard BuilderEvidenceDigest.sha256(canonical) == bindingDigest,
              ForgeSeal.verify(canonical, seal: bindingSeal) else {
            throw BuilderDynamicContractError.invalidDependencyResults(consumerNodeID)
        }
    }

    private struct Binding: Codable {
        let node: BuilderNode; let worker: BuilderWorkerReceipt
        let verification: BuilderVerifierReceipt
        let parentContractFingerprint: String; let graphFingerprint: String
        let consumerNodeID: String; let consumerAttempt: Int
        let acceptedCheckpointSequence: Int
    }

    private static func bindingCanonical(
        node: BuilderNode, worker: BuilderWorkerReceipt,
        verification: BuilderVerifierReceipt, parentContractFingerprint: String,
        graphFingerprint: String, consumerNodeID: String, consumerAttempt: Int,
        acceptedCheckpointSequence: Int
    ) throws -> String {
        String(decoding: try BuilderDurableIO.canonicalData(Binding(
            node: node, worker: worker, verification: verification,
            parentContractFingerprint: parentContractFingerprint,
            graphFingerprint: graphFingerprint, consumerNodeID: consumerNodeID,
            consumerAttempt: consumerAttempt,
            acceptedCheckpointSequence: acceptedCheckpointSequence)), as: UTF8.self)
    }
}

public struct BuilderNodeContractProviderIdentity: Codable, Sendable, Equatable {
    public let providerID: String
    public let implementationFingerprint: String

    public init(providerID: String, implementationFingerprint: String) throws {
        self.providerID = try BuilderExecutionValidation.identifier(
            providerID, field: "contract provider ID")
        self.implementationFingerprint = try BuilderExecutionValidation.digest(
            implementationFingerprint, field: "contract provider implementation fingerprint")
    }
}

public struct BuilderNodeContractRequest: Sendable, Equatable {
    public let builderContract: BuilderContract
    public let graph: BuilderGraph
    public let node: BuilderNode
    public let attempt: Int
    public let dependencies: [BuilderCommittedDependencyResult]

    public init(builderContract: BuilderContract, graph: BuilderGraph, node: BuilderNode,
                attempt: Int, dependencies: [BuilderCommittedDependencyResult]) throws {
        guard graph.nodes.contains(where: { $0.id == node.id }) else {
            throw BuilderDynamicContractError.nodeNotInGraph(node.id)
        }
        guard attempt > 0 else { throw BuilderDynamicContractError.invalidAttempt }
        let expected = Set(node.dependencies)
        let actual = Set(dependencies.map(\.node.id))
        guard expected == actual, dependencies.count == expected.count,
              dependencies.allSatisfy({ $0.worker.nodeID == $0.node.id }) else {
            throw BuilderDynamicContractError.invalidDependencyResults(node.id)
        }
        let parentFingerprint = try BuilderEvidenceDigest.sha256(String(
            decoding: BuilderDurableIO.canonicalData(builderContract), as: UTF8.self))
        let graphFingerprint = BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(graph), as: UTF8.self))
        for dependency in dependencies {
            try dependency.validate(
                parentContractFingerprint: parentFingerprint,
                graphFingerprint: graphFingerprint, consumerNodeID: node.id,
                consumerAttempt: attempt,
                currentCheckpointSequence: dependency.acceptedCheckpointSequence ?? -1)
        }
        self.builderContract = builderContract
        self.graph = graph
        self.node = node
        self.attempt = attempt
        self.dependencies = dependencies.sorted { $0.node.id < $1.node.id }
    }
}

public protocol BuilderNodeExecutionContractProvider: Sendable {
    var identity: BuilderNodeContractProviderIdentity { get }
    func sealedContract(for request: BuilderNodeContractRequest) async throws
        -> SealedBuilderExecutionContract
}

public struct BuilderNodeObservationSourceRequest: Sendable, Equatable {
    public let builderContractID: String
    public let graphNodeIDs: [String]
    public let node: BuilderNode
    public let attempt: Int
    public let contractFingerprint: String
    public let contractSealReference: String

    public init(builderContractID: String, graphNodeIDs: [String], node: BuilderNode,
                attempt: Int, contractFingerprint: String,
                contractSealReference: String) {
        self.builderContractID = builderContractID
        self.graphNodeIDs = graphNodeIDs.sorted()
        self.node = node
        self.attempt = attempt
        self.contractFingerprint = contractFingerprint
        self.contractSealReference = contractSealReference
    }
}

public protocol BuilderNodeObservationSourceProvider: Sendable {
    func source(for request: BuilderNodeObservationSourceRequest) async throws
        -> any BuilderStageObservationSource
}

public struct BuilderSelectedNodeExecutionContract: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let nodeID: String
    public let attempt: Int
    public let providerIdentity: BuilderNodeContractProviderIdentity
    public let sealedContract: SealedBuilderExecutionContract

    public init(nodeID: String, attempt: Int,
                providerIdentity: BuilderNodeContractProviderIdentity,
                sealedContract: SealedBuilderExecutionContract) throws {
        guard attempt > 0 else { throw BuilderDynamicContractError.invalidAttempt }
        guard sealedContract.contract.builderNodeID == nodeID else {
            throw BuilderDynamicContractError.contractNodeMismatch(
                expected: nodeID, actual: sealedContract.contract.builderNodeID)
        }
        self.schemaVersion = 1
        self.nodeID = nodeID
        self.attempt = attempt
        self.providerIdentity = providerIdentity
        self.sealedContract = sealedContract
    }

    public var contractFingerprint: String { sealedContract.fingerprint }
    public var contractSealReference: String {
        BuilderEvidenceDigest.sha256(sealedContract.seal)
    }

    public func validate(builderContractID: String, graphNodeIDs: [String],
                         expectedNodeID: String, expectedAttempt: Int,
                         providerIdentity: BuilderNodeContractProviderIdentity,
                         parentAllowedPaths: [String]? = nil,
                         nodeWriteClaims: [String]? = nil) throws {
        guard schemaVersion == 1 else { throw BuilderDynamicContractError.unsupportedVersion }
        guard nodeID == expectedNodeID,
              sealedContract.contract.builderNodeID == expectedNodeID else {
            throw BuilderDynamicContractError.contractNodeMismatch(
                expected: expectedNodeID, actual: sealedContract.contract.builderNodeID)
        }
        guard attempt == expectedAttempt else { throw BuilderDynamicContractError.invalidAttempt }
        guard self.providerIdentity == providerIdentity else {
            throw BuilderDynamicContractError.providerDrift
        }
        do {
            try sealedContract.validate(
                builderContractID: builderContractID,
                graphNodeIDs: graphNodeIDs)
        } catch {
            throw BuilderDynamicContractError.invalidSealedContract(error.localizedDescription)
        }
        guard try sealedContract.contract.fingerprint() == sealedContract.fingerprint else {
            throw BuilderDynamicContractError.contractFingerprintDrift
        }
        if let parentAllowedPaths, let nodeWriteClaims {
            try Self.validateMutationAuthority(
                sealedContract.contract.mutations.map(\.path),
                parentAllowedPaths: parentAllowedPaths,
                nodeWriteClaims: nodeWriteClaims)
        }
    }

    static func validateMutationAuthority(
        _ mutationPaths: [String],
        parentAllowedPaths: [String],
        nodeWriteClaims: [String]
    ) throws {
        let parent = try parentAllowedPaths.map(normalizeAuthorityPath)
        let node = try nodeWriteClaims.map(normalizeAuthorityPath)
        for mutationPath in mutationPaths {
            let mutation = try normalizeAuthorityPath(mutationPath)
            guard parent.contains(where: { contains(mutation, authority: $0) }) else {
                throw BuilderDynamicContractError.mutationOutsideParentAuthority(mutation)
            }
            guard node.contains(where: { contains(mutation, authority: $0) }) else {
                throw BuilderDynamicContractError.mutationOutsideNodeAuthority(mutation)
            }
        }
    }

    private static func normalizeAuthorityPath(_ value: String) throws -> String {
        do {
            return try BuilderPathSecurity.authorityKey(value)
        } catch {
            throw BuilderDynamicContractError.invalidAuthorityPath(value)
        }
    }

    private static func contains(_ mutation: String, authority: String) -> Bool {
        mutation == authority || mutation.hasPrefix(authority + "/")
    }
}

public enum BuilderDynamicContractError: Error, LocalizedError, Sendable, Equatable {
    case policyReferencesUnknownNode(String)
    case readOnlyNodeClaimsWrite(String)
    case nodeNotInGraph(String)
    case invalidAttempt
    case invalidDependencyResults(String)
    case missingContractProvider(String)
    case missingObservationSource(String)
    case contractNodeMismatch(expected: String, actual: String)
    case invalidSealedContract(String)
    case contractFingerprintDrift
    case retryContractDrift
    case providerDrift
    case unsupportedVersion
    case invalidAuthorityPath(String)
    case mutationOutsideParentAuthority(String)
    case mutationOutsideNodeAuthority(String)

    public var errorDescription: String? {
        switch self {
        case .policyReferencesUnknownNode(let node):
            return "Builder execution policy references unknown node \(node)"
        case .readOnlyNodeClaimsWrite(let node):
            return "Explicit read-only node \(node) claims a write resource"
        case .nodeNotInGraph(let node):
            return "Dynamic contract target \(node) is not in the builder graph"
        case .invalidAttempt: return "Dynamic contract attempt must be positive and exact"
        case .invalidDependencyResults(let node):
            return "Dynamic contract dependencies are incomplete or invalid for \(node)"
        case .missingContractProvider(let node):
            return "Mutation-bearing node \(node) has no startup or dynamic contract provider"
        case .missingObservationSource(let node):
            return "Governed node \(node) has no scoped stage observation source"
        case .contractNodeMismatch(let expected, let actual):
            return "Dynamic contract node mismatch: expected \(expected), received \(actual)"
        case .invalidSealedContract(let reason):
            return "Dynamic sealed execution contract is invalid: \(reason)"
        case .contractFingerprintDrift:
            return "Dynamic contract fingerprint drifted from its sealed payload"
        case .retryContractDrift:
            return "Dynamic contract changed across a bounded retry"
        case .providerDrift:
            return "Dynamic contract provider identity or implementation drifted on resume"
        case .unsupportedVersion:
            return "Dynamic selected-contract record has an unsupported schema version"
        case .invalidAuthorityPath(let path):
            return "Dynamic contract authority path is invalid: \(path)"
        case .mutationOutsideParentAuthority(let path):
            return "Dynamic mutation \(path) is outside the parent BuilderContract allowed paths"
        case .mutationOutsideNodeAuthority(let path):
            return "Dynamic mutation \(path) is outside the node write-resource claims"
        }
    }
}
