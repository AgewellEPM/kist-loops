import Foundation

public struct BuilderObservedPathState: Codable, Sendable, Equatable, Hashable {
    public let path: String
    public let digest: String?
    public init(path: String, digest: String?) throws {
        self.path = try BuilderExecutionValidation.path(path)
        self.digest = try digest.map { try BuilderExecutionValidation.digest($0, field: "path-state digest") }
    }
}

public struct BuilderObservedMutation: Codable, Sendable, Equatable, Hashable {
    public let kind: BuilderMutationKind
    public let path: String
    public let preimageSHA256: String?
    public let postimageSHA256: String?
    public init(kind: BuilderMutationKind, path: String, preimageSHA256: String?,
                postimageSHA256: String?) throws {
        let normalized = try BuilderExecutionValidation.path(path)
        let before = try preimageSHA256.map {
            try BuilderExecutionValidation.digest($0, field: "observed preimage")
        }
        let after = try postimageSHA256.map {
            try BuilderExecutionValidation.digest($0, field: "observed postimage")
        }
        switch kind {
        case .create:
            guard before == nil, after != nil else {
                throw BuilderContractVerifierError.operationMismatch(normalized)
            }
        case .modify:
            guard before != nil, after != nil else {
                throw BuilderContractVerifierError.operationMismatch(normalized)
            }
        case .delete:
            guard before != nil, after == nil else {
                throw BuilderContractVerifierError.operationMismatch(normalized)
            }
        }
        self.kind = kind; self.path = normalized
        self.preimageSHA256 = before; self.postimageSHA256 = after
    }
}

public struct BuilderCriterionObservation: Codable, Sendable, Equatable, Hashable {
    public let criterionID: String
    public let passed: Bool
    public let evidenceDigest: String
    public init(criterionID: String, passed: Bool, evidenceDigest: String) throws {
        self.criterionID = try BuilderExecutionValidation.identifier(criterionID, field: "criterion observation")
        self.passed = passed
        self.evidenceDigest = try BuilderExecutionValidation.digest(
            evidenceDigest, field: "criterion evidence digest")
    }
}

public enum BuilderObservedIdentityRole: String, Codable, Sendable, Equatable, Hashable {
    case producer, reviewer
}

public struct BuilderIdentityObservation: Codable, Sendable, Equatable, Hashable {
    public let role: BuilderObservedIdentityRole
    public let identity: BuilderModelIdentity
    public init(role: BuilderObservedIdentityRole, identity: BuilderModelIdentity) {
        self.role = role; self.identity = identity
    }
}

public struct BuilderStageBaseline: Codable, Sendable, Equatable {
    public let contractFingerprint: String
    public let builderContractID: String
    public let nodeID: String
    public let attempt: Int
    public let stage: BuilderExecutionStage
    public let workspaceDigest: String
    public let pathStates: [BuilderObservedPathState]
    public let warnings: [String]
    public let budgetObservations: [BuilderTrustedBudgetObservation]

    public init(contractFingerprint: String, builderContractID: String, nodeID: String,
                attempt: Int, stage: BuilderExecutionStage, workspaceDigest: String,
                pathStates: [BuilderObservedPathState] = [], warnings: [String] = [],
                budgetObservations: [BuilderTrustedBudgetObservation] = []) throws {
        self.contractFingerprint = try BuilderExecutionValidation.digest(
            contractFingerprint, field: "baseline contract fingerprint")
        self.builderContractID = try BuilderExecutionValidation.identifier(
            builderContractID, field: "baseline Builder contract")
        self.nodeID = try BuilderExecutionValidation.identifier(nodeID, field: "baseline node")
        guard attempt > 0 else { throw BuilderContractVerifierError.bindingMismatch("attempt") }
        let paths = pathStates.map(\.path)
        guard Set(paths).count == paths.count else {
            throw BuilderContractVerifierError.bindingMismatch("duplicate baseline path")
        }
        self.attempt = attempt; self.stage = stage
        self.workspaceDigest = try BuilderExecutionValidation.digest(
            workspaceDigest, field: "baseline workspace digest")
        self.pathStates = pathStates.sorted { $0.path < $1.path }
        self.warnings = Self.canonicalWarnings(warnings)
        self.budgetObservations = budgetObservations.sorted { $0.id < $1.id }
    }

    static func canonicalWarnings(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
    }
}

public struct BuilderStageObservation: Codable, Sendable, Equatable {
    public let contractFingerprint: String
    public let builderContractID: String
    public let nodeID: String
    public let attempt: Int
    public let stage: BuilderExecutionStage
    public let workspaceDigestBefore: String
    public let workspaceDigestAfter: String
    public let operations: [BuilderObservedMutation]
    public let criteria: [BuilderCriterionObservation]
    public let identities: [BuilderIdentityObservation]
    public let lineage: BuilderLineageEnvelope
    public let baselineWarnings: [String]
    public let currentWarnings: [String]
    public let budgetObservations: [BuilderTrustedBudgetObservation]

    public init(contractFingerprint: String, builderContractID: String, nodeID: String,
                attempt: Int, stage: BuilderExecutionStage,
                workspaceDigestBefore: String, workspaceDigestAfter: String,
                operations: [BuilderObservedMutation] = [],
                criteria: [BuilderCriterionObservation] = [],
                identities: [BuilderIdentityObservation], lineage: BuilderLineageEnvelope,
                baselineWarnings: [String] = [], currentWarnings: [String] = [],
                budgetObservations: [BuilderTrustedBudgetObservation] = []) throws {
        self.contractFingerprint = try BuilderExecutionValidation.digest(
            contractFingerprint, field: "observation contract fingerprint")
        self.builderContractID = try BuilderExecutionValidation.identifier(
            builderContractID, field: "observation Builder contract")
        self.nodeID = try BuilderExecutionValidation.identifier(nodeID, field: "observation node")
        guard attempt > 0 else { throw BuilderContractVerifierError.bindingMismatch("attempt") }
        let operationPaths = operations.map(\.path)
        guard Set(operationPaths).count == operationPaths.count else {
            throw BuilderContractVerifierError.operationMismatch("duplicate observed path")
        }
        let criterionIDs = criteria.map(\.criterionID)
        guard Set(criterionIDs).count == criterionIDs.count else {
            throw BuilderContractVerifierError.criterionMismatch("duplicate criterion observation")
        }
        self.attempt = attempt; self.stage = stage
        self.workspaceDigestBefore = try BuilderExecutionValidation.digest(
            workspaceDigestBefore, field: "workspace-before digest")
        self.workspaceDigestAfter = try BuilderExecutionValidation.digest(
            workspaceDigestAfter, field: "workspace-after digest")
        self.operations = operations.sorted { $0.path < $1.path }
        self.criteria = criteria.sorted { $0.criterionID < $1.criterionID }
        self.identities = identities.sorted { $0.identity.canonicalID < $1.identity.canonicalID }
        self.lineage = lineage
        self.baselineWarnings = BuilderStageBaseline.canonicalWarnings(baselineWarnings)
        self.currentWarnings = BuilderStageBaseline.canonicalWarnings(currentWarnings)
        self.budgetObservations = budgetObservations.sorted { $0.id < $1.id }
    }
}

public struct BuilderRollbackObservation: Codable, Sendable, Equatable {
    public let contractFingerprint: String
    public let builderContractID: String
    public let nodeID: String
    public let attempt: Int
    public let workspaceDigestAfter: String
    public let restoredPathStates: [BuilderObservedPathState]
    public let warnings: [String]
    public let budgetObservations: [BuilderTrustedBudgetObservation]

    public init(contractFingerprint: String, builderContractID: String, nodeID: String,
                attempt: Int, workspaceDigestAfter: String,
                restoredPathStates: [BuilderObservedPathState], warnings: [String] = [],
                budgetObservations: [BuilderTrustedBudgetObservation] = []) throws {
        self.contractFingerprint = try BuilderExecutionValidation.digest(
            contractFingerprint, field: "rollback contract fingerprint")
        self.builderContractID = try BuilderExecutionValidation.identifier(
            builderContractID, field: "rollback Builder contract")
        self.nodeID = try BuilderExecutionValidation.identifier(nodeID, field: "rollback node")
        guard attempt > 0 else { throw BuilderContractVerifierError.bindingMismatch("rollback attempt") }
        let paths = restoredPathStates.map(\.path)
        guard Set(paths).count == paths.count else {
            throw BuilderContractVerifierError.rollbackMismatch("duplicate restored path")
        }
        self.attempt = attempt
        self.workspaceDigestAfter = try BuilderExecutionValidation.digest(
            workspaceDigestAfter, field: "rollback workspace digest")
        self.restoredPathStates = restoredPathStates.sorted { $0.path < $1.path }
        self.warnings = BuilderStageBaseline.canonicalWarnings(warnings)
        self.budgetObservations = budgetObservations.sorted { $0.id < $1.id }
    }
}

public struct BuilderContractVerificationReceipt: Codable, Sendable, Equatable {
    public let contractFingerprint: String
    public let nodeID: String
    public let attempt: Int
    public let stage: BuilderExecutionStage
    public let observationDigest: String
}

public enum BuilderContractVerifierError: Error, LocalizedError, Sendable, Equatable {
    case bindingMismatch(String)
    case operationMismatch(String)
    case criterionMismatch(String)
    case identityMismatch(String)
    case lineageMismatch
    case newWarnings([String])
    case rollbackMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .bindingMismatch(let field): return "Trusted stage observation binding mismatch: \(field)"
        case .operationMismatch(let path): return "Mutation operation/preimage mismatch: \(path)"
        case .criterionMismatch(let value): return "Stage criterion failed closed: \(value)"
        case .identityMismatch(let value): return "Observed provider/model identity is not contract-bound: \(value)"
        case .lineageMismatch: return "Observed lineage does not equal the sealed contract lineage"
        case .newWarnings(let warnings): return "New warnings introduced: \(warnings.joined(separator: "; "))"
        case .rollbackMismatch(let value): return "Rollback did not restore the trusted baseline: \(value)"
        }
    }
}

public struct BuilderContractVerifier: Sendable {
    public init() {}

    public func validateBaseline(contract: BuilderExecutionContract,
                                 baseline: BuilderStageBaseline) throws {
        let fingerprint = try contract.fingerprint()
        guard baseline.contractFingerprint == fingerprint,
              baseline.builderContractID == contract.builderContractID,
              baseline.nodeID == contract.builderNodeID else {
            throw BuilderContractVerifierError.bindingMismatch("contract/node")
        }
        if baseline.stage == .build {
            let expectedPaths = Set(contract.mutations.map(\.path))
            guard Set(baseline.pathStates.map(\.path)) == expectedPaths else {
                throw BuilderContractVerifierError.operationMismatch("baseline path set")
            }
            let states = Dictionary(uniqueKeysWithValues: baseline.pathStates.map { ($0.path, $0.digest) })
            for operation in contract.mutations {
                let observed = states[operation.path] ?? nil
                switch operation.kind {
                case .create:
                    guard observed == nil else {
                        throw BuilderContractVerifierError.operationMismatch(operation.path)
                    }
                case .modify, .delete:
                    guard let observed else {
                        throw BuilderContractVerifierError.operationMismatch(operation.path)
                    }
                    if let required = operation.preimageSHA256, observed != required {
                        throw BuilderContractVerifierError.operationMismatch(operation.path)
                    }
                }
            }
        }
    }

    public func verify(contract: BuilderExecutionContract, baseline: BuilderStageBaseline,
                       observation: BuilderStageObservation) throws -> BuilderContractVerificationReceipt {
        try validateBaseline(contract: contract, baseline: baseline)
        guard observation.contractFingerprint == baseline.contractFingerprint,
              observation.builderContractID == baseline.builderContractID,
              observation.nodeID == baseline.nodeID,
              observation.attempt == baseline.attempt,
              observation.stage == baseline.stage,
              observation.workspaceDigestBefore == baseline.workspaceDigest else {
            throw BuilderContractVerifierError.bindingMismatch("stage/attempt/workspace")
        }
        guard observation.lineage == contract.lineage else {
            throw BuilderContractVerifierError.lineageMismatch
        }
        guard observation.baselineWarnings == baseline.warnings else {
            throw BuilderContractVerifierError.bindingMismatch("warning baseline")
        }
        let newWarnings = Array(Set(observation.currentWarnings).subtracting(baseline.warnings)).sorted()
        guard newWarnings.isEmpty else { throw BuilderContractVerifierError.newWarnings(newWarnings) }
        try verifyCriteria(contract: contract, observation: observation)
        try verifyIdentities(contract: contract, observation: observation)
        if observation.stage == .build {
            try verifyOperations(contract: contract, baseline: baseline, observation: observation)
        } else if !observation.operations.isEmpty {
            throw BuilderContractVerifierError.operationMismatch("mutations outside build stage")
        }
        let digest = BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(observation), as: UTF8.self))
        return .init(contractFingerprint: observation.contractFingerprint,
                     nodeID: observation.nodeID, attempt: observation.attempt,
                     stage: observation.stage, observationDigest: digest)
    }

    public func verifyRollback(contract: BuilderExecutionContract, baseline: BuilderStageBaseline,
                               observation: BuilderRollbackObservation) throws {
        try validateBaseline(contract: contract, baseline: baseline)
        guard observation.contractFingerprint == baseline.contractFingerprint,
              observation.builderContractID == baseline.builderContractID,
              observation.nodeID == baseline.nodeID,
              observation.attempt == baseline.attempt,
              observation.restoredPathStates == baseline.pathStates else {
            throw BuilderContractVerifierError.rollbackMismatch("digest/path state")
        }
        let newWarnings = Array(Set(observation.warnings).subtracting(baseline.warnings)).sorted()
        guard newWarnings.isEmpty else { throw BuilderContractVerifierError.newWarnings(newWarnings) }
    }

    private func verifyOperations(contract: BuilderExecutionContract, baseline: BuilderStageBaseline,
                                  observation: BuilderStageObservation) throws {
        guard observation.operations.count == contract.mutations.count else {
            throw BuilderContractVerifierError.operationMismatch("operation count")
        }
        let observed = Dictionary(uniqueKeysWithValues: observation.operations.map { ($0.path, $0) })
        let baselineStates = Dictionary(uniqueKeysWithValues: baseline.pathStates.map { ($0.path, $0.digest) })
        for expected in contract.mutations {
            guard let actual = observed[expected.path], actual.kind == expected.kind,
                  actual.preimageSHA256 == (baselineStates[expected.path] ?? nil) else {
                throw BuilderContractVerifierError.operationMismatch(expected.path)
            }
        }
    }

    private func verifyCriteria(contract: BuilderExecutionContract,
                                observation: BuilderStageObservation) throws {
        let expected = contract.criteria.filter { $0.stage == observation.stage }
        let actual = Dictionary(uniqueKeysWithValues: observation.criteria.map { ($0.criterionID, $0) })
        guard Set(actual.keys).isSubset(of: Set(expected.map(\.id))) else {
            throw BuilderContractVerifierError.criterionMismatch("unknown criterion")
        }
        for criterion in expected where criterion.required {
            guard let result = actual[criterion.id], result.passed else {
                throw BuilderContractVerifierError.criterionMismatch(criterion.id)
            }
        }
    }

    private func verifyIdentities(contract: BuilderExecutionContract,
                                  observation: BuilderStageObservation) throws {
        switch observation.stage {
        case .build:
            let observed = observation.identities
                .filter { $0.role == .producer }.map(\.identity)
            guard !observed.isEmpty,
                  observed.allSatisfy(contract.identities.producers.contains) else {
                throw BuilderContractVerifierError.identityMismatch(
                    BuilderObservedIdentityRole.producer.rawValue)
            }
        case .verification:
            // Deterministic host commands are not model identities. Verification therefore
            // permits an empty identity set, while any model telemetry remains contract-bound
            // to an explicitly allowed reviewer and cannot masquerade as a producer.
            guard observation.identities.allSatisfy({
                $0.role == .reviewer && contract.identities.reviewers.contains($0.identity)
            }) else {
                throw BuilderContractVerifierError.identityMismatch(
                    BuilderObservedIdentityRole.reviewer.rawValue)
            }
        case .review:
            let observed = observation.identities
                .filter { $0.role == .reviewer }.map(\.identity)
            guard !observed.isEmpty,
                  observed.allSatisfy(contract.identities.reviewers.contains) else {
                throw BuilderContractVerifierError.identityMismatch(
                    BuilderObservedIdentityRole.reviewer.rawValue)
            }
        default:
            let observed = observation.identities
                .filter { $0.role == .reviewer }.map(\.identity)
            guard !observed.isEmpty,
                  observed.allSatisfy(contract.identities.reviewers.contains) else {
                throw BuilderContractVerifierError.identityMismatch(
                    BuilderObservedIdentityRole.reviewer.rawValue)
            }
        }
    }
}

public struct BuilderStageContext: Sendable {
    public let contract: BuilderExecutionContract
    public let node: BuilderNode
    public let attempt: Int
    public let stage: BuilderExecutionStage

    public init(contract: BuilderExecutionContract, node: BuilderNode,
                attempt: Int, stage: BuilderExecutionStage) throws {
        guard contract.builderNodeID == node.id else {
            throw BuilderContractVerifierError.bindingMismatch("contract/node")
        }
        guard attempt > 0 else {
            throw BuilderContractVerifierError.bindingMismatch("attempt")
        }
        _ = try contract.fingerprint()
        self.contract = contract
        self.node = node
        self.attempt = attempt
        self.stage = stage
    }
}

public enum BuilderStageObservationSubject: Sendable {
    case execution(BuilderWorkerReceipt)
    case verification(BuilderWorkerReceipt, BuilderVerifierReceipt)
    case review([BuilderWorkerReceipt], BuilderVerifierReceipt, BuilderReviewReceipt)
}

public struct BuilderStageObservationRequest: Sendable {
    public let context: BuilderStageContext
    public let baseline: BuilderStageBaseline
    public let subject: BuilderStageObservationSubject
    public let trustedTelemetry: [BuilderTrustedTelemetryObservation]

    public init(context: BuilderStageContext, baseline: BuilderStageBaseline,
                subject: BuilderStageObservationSubject,
                trustedTelemetry: [BuilderTrustedTelemetryObservation] = []) {
        self.context = context
        self.baseline = baseline
        self.subject = subject
        self.trustedTelemetry = trustedTelemetry
    }
}

public struct BuilderRollbackRequest: Sendable {
    public let context: BuilderStageContext
    public let baseline: BuilderStageBaseline
    public let currentWorkspaceDigest: String?
    public let reason: String
}

public protocol BuilderStageObservationSource: Sendable {
    func prepare(_ context: BuilderStageContext) async throws -> BuilderStageBaseline
    func observe(_ request: BuilderStageObservationRequest) async throws -> BuilderStageObservation
    func rollback(_ request: BuilderRollbackRequest) async throws -> BuilderRollbackObservation
}
