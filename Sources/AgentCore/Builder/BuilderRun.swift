import Foundation
import CryptoKit

private func builderIsHostDeterministicVerifier(provider: String, model: String) -> Bool {
    ["host", "process", "kist"].contains(provider.lowercased())
        && ["deterministic", "command"].contains(model.lowercased())
}

private func builderFinalVerifierIdentitiesMatch(
    _ lhs: BuilderModelIdentity, _ rhs: BuilderModelIdentity
) -> Bool {
    lhs == rhs || (
        builderIsHostDeterministicVerifier(
            provider: lhs.providerID, model: lhs.modelID)
            && builderIsHostDeterministicVerifier(
                provider: rhs.providerID, model: rhs.modelID)
    )
}
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
public enum BuilderRoute: String, Codable, Sendable, Hashable, CaseIterable {
    case direct
    case planned
    case fleet
    case highAssurance
}
public enum BuilderRisk: String, Codable, Sendable, Hashable {
    case low, medium, high, critical
}
public enum BuilderCompletionMode: String, Codable, Sendable, Hashable {
    case build
    case verificationOnly
}
public struct BuilderRouteHint: Codable, Sendable, Equatable {
    public var preferred: BuilderRoute?; public var estimatedFiles: Int; public var independentWorkstreams: Int; public var risk: BuilderRisk; public var requiresResearch: Bool; public var requiresSimulation: Bool
    public init(
        preferred: BuilderRoute? = nil,
        estimatedFiles: Int = 1,
        independentWorkstreams: Int = 1,
        risk: BuilderRisk = .low,
        requiresResearch: Bool = false,
        requiresSimulation: Bool = false
    ) {
        self.preferred = preferred
        self.estimatedFiles = max(0, estimatedFiles)
        self.independentWorkstreams = max(1, independentWorkstreams)
        self.risk = risk
        self.requiresResearch = requiresResearch
        self.requiresSimulation = requiresSimulation
    }
    public func resolve() -> BuilderRoute {
        if let preferred { return preferred }
        if requiresResearch || requiresSimulation || risk == .high || risk == .critical {
            return .highAssurance
        }
        if independentWorkstreams > 1 { return .fleet }
        if estimatedFiles > 1 || risk == .medium { return .planned }
        return .direct
    }
}
public struct BuilderContract: Codable, Sendable, Equatable {
    public let id: String; public var objective: String; public var constraints: [String]; public var allowedPaths: [String]; public var capabilities: [String]; public var doneWhen: [String]; public var routeHint: BuilderRouteHint; public var checkpointIdentity: String?; public var maxTokens: Int?; public var completionMode: BuilderCompletionMode?; public var producerIdentities: [String]?; public var executionContract: SealedBuilderExecutionContract?; public var governanceAdmission: BuilderGraphGovernanceAdmission?
    public init(
        id: String = UUID().uuidString,
        objective: String,
        constraints: [String] = [],
        allowedPaths: [String] = [],
        capabilities: [String] = [],
        doneWhen: [String],
        routeHint: BuilderRouteHint = .init(),
        checkpointIdentity: String? = nil,
        maxTokens: Int? = nil,
        completionMode: BuilderCompletionMode = .build,
        producerIdentities: [String]? = nil,
        executionContract: SealedBuilderExecutionContract? = nil,
        governanceAdmission: BuilderGraphGovernanceAdmission? = nil
    ) {
        self.id = id
        self.objective = objective
        self.constraints = constraints
        self.allowedPaths = allowedPaths
        self.capabilities = capabilities
        self.doneWhen = doneWhen
        self.routeHint = routeHint
        self.checkpointIdentity = checkpointIdentity
        self.maxTokens = maxTokens.map { max(0, $0) }
        self.completionMode = completionMode
        self.producerIdentities = producerIdentities
        self.executionContract = executionContract
        self.governanceAdmission = governanceAdmission
    }

    public var effectiveCompletionMode: BuilderCompletionMode { completionMode ?? .build }
}
public enum BuilderResourceAccess: String, Codable, Sendable, Hashable { case read, write }
public enum BuilderIsolation: String, Codable, Sendable, Hashable { case shared, sandbox, worktree }
public enum BuilderRole: String, Codable, Sendable, Hashable {
    case coordinator, planner, builder, verifier, reviewer
}
public struct BuilderResourceClaim: Codable, Sendable, Hashable {
    public let path: String; public let access: BuilderResourceAccess
    public init(path: String, access: BuilderResourceAccess) {
        self.path = path
        self.access = access
    }
}
public struct BuilderNode: Codable, Sendable, Identifiable, Equatable {
    public let id: String; public var objective: String; public var dependencies: [String]; public var resources: [BuilderResourceClaim]; public var isolation: BuilderIsolation; public var role: BuilderRole; public var retryLimit: Int
    public init(
        id: String,
        objective: String,
        dependencies: [String] = [],
        resources: [BuilderResourceClaim] = [],
        isolation: BuilderIsolation = .worktree,
        role: BuilderRole = .builder,
        retryLimit: Int = 2
    ) {
        self.id = id
        self.objective = objective
        self.dependencies = dependencies
        self.resources = resources
        self.isolation = isolation
        self.role = role
        self.retryLimit = max(0, retryLimit)
    }
}
public enum BuilderGraphError: Error, LocalizedError, Sendable, Equatable {
    case emptyNodeID
    case duplicateNode(String)
    case duplicateDependency(node: String, dependency: String)
    case unknownDependency(node: String, dependency: String)
    case cycle([String])
    public var errorDescription: String? {
        switch self {
        case .emptyNodeID: return "Builder node IDs must not be empty"
        case .duplicateNode(let id): return "Duplicate builder node: \(id)"
        case .duplicateDependency(let node, let dependency):
            return "Node \(node) repeats dependency \(dependency)"
        case .unknownDependency(let node, let dependency):
            return "Node \(node) has unknown dependency \(dependency)"
        case .cycle(let nodes): return "Builder graph contains a cycle: \(nodes.joined(separator: ", "))"
        }
    }
}
public struct BuilderGraph: Codable, Sendable, Equatable {
    public let nodes: [BuilderNode]
    public init(nodes: [BuilderNode]) throws {
        try Self.validate(nodes)
        self.nodes = nodes
    }
    public static func validate(_ nodes: [BuilderNode]) throws {
        var ids = Set<String>()
        for node in nodes {
            guard !node.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BuilderGraphError.emptyNodeID
            }
            guard ids.insert(node.id).inserted else { throw BuilderGraphError.duplicateNode(node.id) }
        }
        var indegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]
        for node in nodes {
            var seen = Set<String>()
            for dependency in node.dependencies {
                guard ids.contains(dependency) else {
                    throw BuilderGraphError.unknownDependency(node: node.id, dependency: dependency)
                }
                guard seen.insert(dependency).inserted else {
                    throw BuilderGraphError.duplicateDependency(node: node.id, dependency: dependency)
                }
                dependents[dependency, default: []].append(node.id)
            }
            indegree[node.id] = node.dependencies.count
        }
        var queue = indegree.filter { $0.value == 0 }.map(\.key).sorted()
        var visited = 0
        while !queue.isEmpty {
            let id = queue.removeFirst()
            visited += 1
            for dependent in dependents[id, default: []].sorted() {
                indegree[dependent, default: 0] -= 1
                if indegree[dependent] == 0 {
                    queue.append(dependent)
                    queue.sort()
                }
            }
        }
        if visited != nodes.count {
            let cycle = indegree.filter { $0.value > 0 }.map(\.key).sorted()
            throw BuilderGraphError.cycle(cycle)
        }
    }
    private enum CodingKeys: String, CodingKey { case nodes }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(nodes: values.decode([BuilderNode].self, forKey: .nodes))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(nodes, forKey: .nodes)
    }
}
public enum BuilderNodePhase: String, Codable, Sendable, Hashable {
    case pending, running, verifying, accepted, failed, blocked
}
public struct BuilderArtifact: Codable, Sendable, Equatable {
    public let path: String; public let kind: String; public let digest: String?
    public init(path: String, kind: String, digest: String? = nil) {
        self.path = path
        self.kind = kind
        self.digest = digest
    }
}
public struct BuilderCheckReceipt: Codable, Sendable, Equatable {
    public let name: String; public let passed: Bool; public let details: String
    public init(name: String, passed: Bool, details: String = "") {
        self.name = name
        self.passed = passed
        self.details = details
    }
}
public enum BuilderCommandVerifierStatus: String, Codable, Sendable, Equatable {
    case passed, executed, expectedDomainStatus
}
public enum BuilderEvidenceDigest {
    public static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
public enum BuilderContractFingerprint {
    public static func canonical(_ contract: BuilderContract) throws -> String {
        BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(contract), as: UTF8.self))
    }
}
public struct BuilderCommandEvidenceReceipt: Codable, Sendable, Equatable {
    public let tool: String; public let verifierStatus: BuilderCommandVerifierStatus
    public let exitCode: Int; public let allowedExitCodes: String; public let semanticStatus: String
    public let argsFingerprint: String; public let outputDigest: String; public let outputExcerpt: String
    public let subjectDigestAfter: String; public let executionPhase: Int?; public let completedAt: Date
    public let trustedCommandReference: BuilderTrustedCommandReference?
    public let evidenceDigest: String

    public static func bound(tool: String, verifierStatus: BuilderCommandVerifierStatus,
                             exitCode: Int, allowedExitCodes: String, semanticStatus: String,
                             argsFingerprint: String, output: String, subjectDigestAfter: String,
                             contractFingerprint: String, executionPhase: Int? = nil,
                             trustedCommandReference: BuilderTrustedCommandReference? = nil,
                             completedAt: Date = Date()) -> Self {
        let redacted = SecretMasker.mask(output)
        let excerpt = String(redacted.prefix(240))
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let outputDigest = BuilderEvidenceDigest.sha256(redacted)
        let canonical = [tool, verifierStatus.rawValue, String(exitCode), allowedExitCodes,
                         semanticStatus, argsFingerprint, outputDigest, subjectDigestAfter,
                         contractFingerprint, executionPhase.map(String.init) ?? "none",
                         trustedCommandReference?.bindingDigest ?? "unbound-launcher",
                         trustedCommandReference?.observationID ?? "unbound-observation",
                         String(completedAt.timeIntervalSince1970)].joined(separator: "\u{0}")
        return Self(tool: tool, verifierStatus: verifierStatus, exitCode: exitCode,
                    allowedExitCodes: allowedExitCodes, semanticStatus: semanticStatus,
                    argsFingerprint: argsFingerprint, outputDigest: outputDigest,
                    outputExcerpt: excerpt, subjectDigestAfter: subjectDigestAfter,
                    executionPhase: executionPhase, completedAt: completedAt,
                    trustedCommandReference: trustedCommandReference,
                    evidenceDigest: BuilderEvidenceDigest.sha256(canonical))
    }

    public static func boundPrehashed(
        tool: String,
        verifierStatus: BuilderCommandVerifierStatus,
        exitCode: Int,
        allowedExitCodes: String,
        semanticStatus: String,
        argsFingerprint: String,
        outputDigest: String,
        boundedRedactedOutputExcerpt: String,
        subjectDigestAfter: String,
        contractFingerprint: String,
        executionPhase: Int? = nil,
        trustedCommandReference: BuilderTrustedCommandReference? = nil,
        completedAt: Date = Date()
    ) -> Self {
        let excerpt = String(SecretMasker.mask(boundedRedactedOutputExcerpt).prefix(240))
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let canonical = [tool, verifierStatus.rawValue, String(exitCode), allowedExitCodes,
                         semanticStatus, argsFingerprint, outputDigest, subjectDigestAfter,
                         contractFingerprint, executionPhase.map(String.init) ?? "none",
                         trustedCommandReference?.bindingDigest ?? "unbound-launcher",
                         trustedCommandReference?.observationID ?? "unbound-observation",
                         String(completedAt.timeIntervalSince1970)].joined(separator: "\u{0}")
        return Self(tool: tool, verifierStatus: verifierStatus, exitCode: exitCode,
                    allowedExitCodes: allowedExitCodes, semanticStatus: semanticStatus,
                    argsFingerprint: argsFingerprint, outputDigest: outputDigest,
                    outputExcerpt: excerpt, subjectDigestAfter: subjectDigestAfter,
                    executionPhase: executionPhase, completedAt: completedAt,
                    trustedCommandReference: trustedCommandReference,
                    evidenceDigest: BuilderEvidenceDigest.sha256(canonical))
    }

    public func isBound(contractFingerprint: String, subjectDigest: String) -> Bool {
        guard !tool.isEmpty, !argsFingerprint.isEmpty, subjectDigestAfter == subjectDigest,
              !subjectDigest.hasPrefix("unavailable:") else { return false }
        let canonical = [tool, verifierStatus.rawValue, String(exitCode), allowedExitCodes,
                         semanticStatus, argsFingerprint, outputDigest, subjectDigestAfter,
                         contractFingerprint, executionPhase.map(String.init) ?? "none",
                         trustedCommandReference?.bindingDigest ?? "unbound-launcher",
                         trustedCommandReference?.observationID ?? "unbound-observation",
                         String(completedAt.timeIntervalSince1970)].joined(separator: "\u{0}")
        return evidenceDigest == BuilderEvidenceDigest.sha256(canonical)
            && (trustedCommandReference?.isValid ?? true)
    }
}
public struct BuilderUsageReceipt: Codable, Sendable, Equatable {
    public let inputTokens: Int; public let outputTokens: Int; public let wallTimeSeconds: Double; public let aggregateTokens: Int?; public let unmeteredStages: [String]?
    public init(inputTokens: Int = 0, outputTokens: Int = 0, wallTimeSeconds: Double = 0,
                aggregateTokens: Int? = nil, unmeteredStages: [String]? = nil) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.wallTimeSeconds = max(0, wallTimeSeconds)
        self.aggregateTokens = aggregateTokens.map { max(0, $0) }
        self.unmeteredStages = unmeteredStages?.filter { !$0.isEmpty }
    }
}
public struct BuilderWorkerReceipt: Codable, Sendable, Equatable {
    public let nodeID: String; public let provider: String; public let model: String; public let artifacts: [BuilderArtifact]; public let changedPaths: [String]; public let checks: [BuilderCheckReceipt]; public let unresolvedRisks: [String]; public let usage: BuilderUsageReceipt; public let commandEvidence: [BuilderCommandEvidenceReceipt]?
    public let requiredSupportingObligations: [PlanSupportingObligation]?
    public let supportingCommandReceipts: [PlanSupportingCommandReceipt]?
    public let planFinalVerificationReceipt: PlanFinalVerificationReceipt?
    public let missionInstanceID: String?
    public internal(set) var trustedCLIRouteReceipts: [BuilderTrustedCLIRouteReceipt]?
    public init(
        nodeID: String,
        provider: String,
        model: String,
        artifacts: [BuilderArtifact] = [],
        changedPaths: [String] = [],
        checks: [BuilderCheckReceipt] = [],
        unresolvedRisks: [String] = [],
        usage: BuilderUsageReceipt = .init(),
        commandEvidence: [BuilderCommandEvidenceReceipt]? = nil,
        requiredSupportingObligations: [PlanSupportingObligation]? = nil,
        supportingCommandReceipts: [PlanSupportingCommandReceipt]? = nil,
        planFinalVerificationReceipt: PlanFinalVerificationReceipt? = nil,
        missionInstanceID: String? = nil
    ) {
        self.nodeID = nodeID
        self.provider = provider
        self.model = model
        self.artifacts = artifacts
        self.changedPaths = changedPaths
        self.checks = checks
        self.unresolvedRisks = unresolvedRisks
        self.usage = usage
        self.commandEvidence = commandEvidence
        self.requiredSupportingObligations = requiredSupportingObligations
        self.supportingCommandReceipts = supportingCommandReceipts
        self.planFinalVerificationReceipt = planFinalVerificationReceipt
        self.missionInstanceID = missionInstanceID
        self.trustedCLIRouteReceipts = nil
    }


    var claimsSubscriptionCLI: Bool {
        ["claude-cli", "codex-cli"].contains(provider.lowercased())
    }

    func bindingObservedCLIInvocationsIfRequired() throws -> Self {
        guard claimsSubscriptionCLI else { return self }
        guard trustedCLIRouteReceipts == nil else {
            throw BuilderBudgetLedgerError.conflictingObservation(
                "worker CLI invocation evidence was already bound")
        }
        var copy = self
        copy.trustedCLIRouteReceipts = try BuilderTrustedTelemetry.consumeCLIInvocations(
            providerID: provider, modelID: model)
        return copy
    }

    func trustedCLIInvocationsMatch(
        _ observations: [BuilderTrustedTelemetryObservation], requireComplete: Bool
    ) -> Bool {
        guard claimsSubscriptionCLI else { return trustedCLIRouteReceipts == nil }
        guard let receipts = trustedCLIRouteReceipts, !receipts.isEmpty,
              Set(receipts.map(\.observationID)).count == receipts.count,
              receipts.allSatisfy({
                  $0.isValid && $0.nodeID == nodeID
                      && $0.providerID.lowercased() == provider.lowercased()
                      && $0.modelID == model
              }) else { return false }
        let matching = observations.filter {
            $0.kind == .cliProviderInvocation
                && $0.providerID?.lowercased() == provider.lowercased()
                && $0.modelID == model && $0.nodeID == nodeID
        }
        let byID = Dictionary(uniqueKeysWithValues: matching.map { ($0.id, $0) })
        guard receipts.allSatisfy({ receipt in
            guard let observation = byID[receipt.observationID] else { return false }
            return observation.cliRouteReceipt == receipt && observation.success
        }) else { return false }
        return !requireComplete
            || Set(receipts.map(\.observationID)) == Set(matching.map(\.id))
    }
}
public enum BuilderVerificationScope: Codable, Sendable, Equatable {
    case node(String)
    case final
}

public enum BuilderFleetVerificationError: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Invalid fleet verification bundle: \(reason)"
        }
    }
}

public struct BuilderFleetChildVerificationBundle: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let nodeID: String
    public let partitionID: String
    public let attempt: Int
    public let partitionPaths: [String]
    public let contractFingerprint: String
    public let verifierIdentity: BuilderModelIdentity
    public let verificationSubject: String
    public let baselineDigest: String
    public let subjectDigest: String
    public let commandEvidence: [BuilderCommandEvidenceReceipt]
    public let verifiedAt: Date
    public let bindingDigest: String

    private struct Binding: Codable {
        let schemaVersion: Int
        let nodeID: String
        let partitionID: String
        let attempt: Int
        let partitionPaths: [String]
        let contractFingerprint: String
        let verifierIdentity: BuilderModelIdentity
        let verificationSubject: String
        let baselineDigest: String
        let subjectDigest: String
        let commandEvidence: [BuilderCommandEvidenceReceipt]
        let verifiedAt: Date
    }

    public init(nodeID: String, attempt: Int, partitionPaths: [String],
                contractFingerprint: String, verifierIdentity: BuilderModelIdentity,
                verificationSubject: String, baselineDigest: String,
                subjectDigest: String, commandEvidence: [BuilderCommandEvidenceReceipt],
                verifiedAt: Date) throws {
        let canonicalNode = try BuilderExecutionValidation.identifier(
            nodeID, field: "fleet child node")
        guard canonicalNode.hasPrefix("fleet-") else {
            throw BuilderFleetVerificationError.invalid(
                "child node must use the fleet-<partition> convention")
        }
        let partition = String(canonicalNode.dropFirst("fleet-".count))
        _ = try BuilderExecutionValidation.identifier(partition, field: "fleet partition")
        guard attempt > 0 else {
            throw BuilderFleetVerificationError.invalid("child attempt must be positive")
        }
        let paths = try partitionPaths.map(BuilderExecutionValidation.path).sorted()
        guard !paths.isEmpty, Set(paths).count == paths.count else {
            throw BuilderFleetVerificationError.invalid(
                "child partition paths must be nonempty and unique")
        }
        let fingerprint = try BuilderExecutionValidation.digest(
            contractFingerprint, field: "fleet child contract fingerprint")
        let subject = try BuilderExecutionValidation.text(
            verificationSubject, field: "fleet verification subject")
        let baseline = try BuilderExecutionValidation.digest(
            baselineDigest, field: "fleet child baseline")
        let digest = try BuilderExecutionValidation.digest(
            subjectDigest, field: "fleet child subject")
        guard !commandEvidence.isEmpty, verifiedAt.timeIntervalSince1970.isFinite else {
            throw BuilderFleetVerificationError.invalid(
                "child command evidence and verification time are required")
        }
        var observationIDs = Set<String>()
        var invocationIDs = Set<String>()
        for receipt in commandEvidence {
            guard let reference = receipt.trustedCommandReference,
                  reference.isValid, reference.exitCode == 0,
                  !reference.timedOut, !reference.wasSignalled,
                  receipt.verifierStatus == .passed, receipt.exitCode == 0,
                  receipt.argsFingerprint == reference.gateArgumentsDigest,
                  receipt.outputDigest == reference.fullStreamDigest,
                  receipt.isBound(contractFingerprint: fingerprint, subjectDigest: digest),
                  observationIDs.insert(reference.observationID).inserted,
                  invocationIDs.insert(reference.invocationID).inserted else {
                throw BuilderFleetVerificationError.invalid(
                    "child command evidence is unbound, stale, reused, or incomplete")
            }
        }
        schemaVersion = 1
        self.nodeID = canonicalNode
        partitionID = partition
        self.attempt = attempt
        self.partitionPaths = paths
        self.contractFingerprint = fingerprint
        self.verifierIdentity = verifierIdentity
        self.verificationSubject = subject
        self.baselineDigest = baseline
        self.subjectDigest = digest
        self.commandEvidence = commandEvidence
        self.verifiedAt = verifiedAt
        let canonicalBinding = Binding(
            schemaVersion: 1,
            nodeID: canonicalNode,
            partitionID: partition,
            attempt: attempt,
            partitionPaths: paths,
            contractFingerprint: fingerprint,
            verifierIdentity: verifierIdentity,
            verificationSubject: subject,
            baselineDigest: baseline,
            subjectDigest: digest,
            commandEvidence: commandEvidence,
            verifiedAt: verifiedAt)
        bindingDigest = BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(canonicalBinding), as: UTF8.self))
    }

    private var binding: Binding {
        Binding(schemaVersion: schemaVersion, nodeID: nodeID, partitionID: partitionID,
                attempt: attempt, partitionPaths: partitionPaths,
                contractFingerprint: contractFingerprint,
                verifierIdentity: verifierIdentity,
                verificationSubject: verificationSubject,
                baselineDigest: baselineDigest, subjectDigest: subjectDigest,
                commandEvidence: commandEvidence, verifiedAt: verifiedAt)
    }

    public func validate() throws {
        let rebuilt = try Self(
            nodeID: nodeID, attempt: attempt, partitionPaths: partitionPaths,
            contractFingerprint: contractFingerprint, verifierIdentity: verifierIdentity,
            verificationSubject: verificationSubject, baselineDigest: baselineDigest,
            subjectDigest: subjectDigest, commandEvidence: commandEvidence,
            verifiedAt: verifiedAt)
        guard schemaVersion == 1, rebuilt == self else {
            throw BuilderFleetVerificationError.invalid(
                "child binding digest or canonical fields changed")
        }
    }
}

struct BuilderFleetChildVerificationExpectation: Sendable, Equatable {
    let nodeID: String
    let attempt: Int
    let partitionPaths: [String]
    let contractFingerprint: String

    init(nodeID: String, attempt: Int, partitionPaths: [String],
         contractFingerprint: String) throws {
        self.nodeID = try BuilderExecutionValidation.identifier(
            nodeID, field: "expected fleet node")
        guard attempt > 0 else {
            throw BuilderFleetVerificationError.invalid("expected child attempt is invalid")
        }
        let paths = try partitionPaths.map(BuilderExecutionValidation.path).sorted()
        guard !paths.isEmpty, Set(paths).count == paths.count else {
            throw BuilderFleetVerificationError.invalid("expected partition paths are invalid")
        }
        self.attempt = attempt
        self.partitionPaths = paths
        self.contractFingerprint = try BuilderExecutionValidation.digest(
            contractFingerprint, field: "expected child fingerprint")
    }
}

public struct BuilderFleetVerificationBundle: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let parentContractFingerprint: String
    public let graphFingerprint: String
    public let children: [BuilderFleetChildVerificationBundle]
    public let verificationSubject: String
    public let subjectDigest: String
    public let aggregateDigest: String

    private struct Binding: Codable {
        let schemaVersion: Int
        let parentContractFingerprint: String
        let graphFingerprint: String
        let children: [BuilderFleetChildVerificationBundle]
    }

    public init(parentContractFingerprint: String, graphFingerprint: String,
                children: [BuilderFleetChildVerificationBundle]) throws {
        let parent = try BuilderExecutionValidation.digest(
            parentContractFingerprint, field: "fleet parent contract fingerprint")
        let graph = try BuilderExecutionValidation.digest(
            graphFingerprint, field: "fleet graph fingerprint")
        guard !children.isEmpty else {
            throw BuilderFleetVerificationError.invalid("fleet has no child proofs")
        }
        let ordered = children.sorted { $0.nodeID < $1.nodeID }
        for child in ordered { try child.validate() }
        guard Set(ordered.map(\.nodeID)).count == ordered.count,
              Set(ordered.map(\.partitionID)).count == ordered.count,
              Set(ordered.map(\.contractFingerprint)).count == ordered.count else {
            throw BuilderFleetVerificationError.invalid(
                "fleet child IDs, partitions, and fingerprints must be unique")
        }
        let paths = ordered.flatMap(\.partitionPaths)
        let references = ordered.flatMap(\.commandEvidence)
            .compactMap(\.trustedCommandReference)
        guard Set(paths).count == paths.count,
              references.count == ordered.flatMap(\.commandEvidence).count,
              Set(references.map(\.observationID)).count == references.count,
              Set(references.map(\.invocationID)).count == references.count else {
            throw BuilderFleetVerificationError.invalid(
                "fleet partitions or trusted command references collide")
        }
        guard let aggregateSubject = ordered.first?.verificationSubject,
              let aggregateSubjectDigest = ordered.first?.subjectDigest,
              ordered.allSatisfy({
                  $0.verificationSubject == aggregateSubject
                      && $0.subjectDigest == aggregateSubjectDigest
              }) else {
            throw BuilderFleetVerificationError.invalid(
                "fleet children do not verify one exact aggregate workspace subject")
        }
        schemaVersion = 1
        self.parentContractFingerprint = parent
        self.graphFingerprint = graph
        self.children = ordered
        let binding = Binding(schemaVersion: 1, parentContractFingerprint: parent,
                              graphFingerprint: graph, children: ordered)
        let canonical = String(
            decoding: try BuilderDurableIO.canonicalData(binding), as: UTF8.self)
        aggregateDigest = BuilderEvidenceDigest.sha256(canonical)
        // These identify the exact aggregate staging bytes. They intentionally
        // remain stable when a fresh verification issues new one-use evidence.
        verificationSubject = aggregateSubject
        subjectDigest = aggregateSubjectDigest
    }

    public func validate() throws {
        let rebuilt = try Self(
            parentContractFingerprint: parentContractFingerprint,
            graphFingerprint: graphFingerprint, children: children)
        guard schemaVersion == 1, rebuilt == self else {
            throw BuilderFleetVerificationError.invalid(
                "aggregate binding digest or canonical child order changed")
        }
    }

    func validate(expectedChildren: [BuilderFleetChildVerificationExpectation],
                  verifierIdentity: BuilderModelIdentity,
                  observations: [BuilderTrustedTelemetryObservation]) throws {
        try validate()
        let expected = expectedChildren.sorted { $0.nodeID < $1.nodeID }
        guard expected.count == children.count,
              Set(expected.map(\.nodeID)).count == expected.count,
              expected.map(\.nodeID) == children.map(\.nodeID) else {
            throw BuilderFleetVerificationError.invalid(
                "fleet child set is missing, duplicated, or contains extras")
        }
        let commandObservations = observations.filter { $0.kind == .command }
        var consumedObservationIDs = Set<String>()
        for (child, requirement) in zip(children, expected) {
            guard child.nodeID == requirement.nodeID,
                  child.partitionID == String(requirement.nodeID.dropFirst("fleet-".count)),
                  child.attempt == requirement.attempt,
                  child.partitionPaths == requirement.partitionPaths,
                  child.contractFingerprint == requirement.contractFingerprint,
                  builderFinalVerifierIdentitiesMatch(
                    child.verifierIdentity, verifierIdentity) else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet child proof is stale or does not match its selected partition contract")
            }
            let referenceIDs = Set(child.commandEvidence.compactMap {
                $0.trustedCommandReference?.observationID
            })
            let childObservations = commandObservations.filter {
                referenceIDs.contains($0.id)
            }
            guard childObservations.count == referenceIDs.count,
                  BuilderTrustedTelemetry.commandEvidenceMatches(
                    child.commandEvidence, observations: childObservations,
                    contractFingerprint: child.contractFingerprint,
                    subjectDigest: child.subjectDigest,
                    requireBuilderOSSandbox: true) else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet child trusted command observations are missing or mismatched")
            }
            consumedObservationIDs.formUnion(referenceIDs)
        }
        guard consumedObservationIDs == Set(commandObservations.map(\.id)),
              consumedObservationIDs.count == commandObservations.count else {
            throw BuilderFleetVerificationError.invalid(
                "final command telemetry is unclaimed, duplicated, or incomplete")
        }
    }
}

public struct BuilderVerifierReceipt: Codable, Sendable, Equatable {
    public let scope: BuilderVerificationScope; public let provider: String; public let model: String; public let deterministic: Bool; public let passed: Bool; public let checks: [BuilderCheckReceipt]; public let failureFingerprint: String?; public let verificationSubject: String?; public let baselineDigest: String?; public let subjectDigest: String?; public let contractFingerprint: String?; public let completionMode: BuilderCompletionMode?; public let commandEvidence: [BuilderCommandEvidenceReceipt]?; public let verifiedAt: Date?
    public let requiredSupportingObligations: [PlanSupportingObligation]?
    public let supportingCommandReceipts: [PlanSupportingCommandReceipt]?
    public let planFinalVerificationReceipt: PlanFinalVerificationReceipt?
    public let missionInstanceID: String?
    public let fleetVerification: BuilderFleetVerificationBundle?
    public init(
        scope: BuilderVerificationScope,
        provider: String,
        model: String,
        deterministic: Bool,
        passed: Bool,
        checks: [BuilderCheckReceipt] = [],
        failureFingerprint: String? = nil,
        verificationSubject: String? = nil,
        baselineDigest: String? = nil,
        subjectDigest: String? = nil,
        contractFingerprint: String? = nil,
        completionMode: BuilderCompletionMode? = nil,
        commandEvidence: [BuilderCommandEvidenceReceipt]? = nil,
        verifiedAt: Date? = nil,
        requiredSupportingObligations: [PlanSupportingObligation]? = nil,
        supportingCommandReceipts: [PlanSupportingCommandReceipt]? = nil,
        planFinalVerificationReceipt: PlanFinalVerificationReceipt? = nil,
        missionInstanceID: String? = nil,
        fleetVerification: BuilderFleetVerificationBundle? = nil
    ) {
        self.scope = scope
        self.provider = provider
        self.model = model
        self.deterministic = deterministic
        self.passed = passed
        self.checks = checks
        self.failureFingerprint = failureFingerprint
        self.verificationSubject = verificationSubject
        self.baselineDigest = baselineDigest
        self.subjectDigest = subjectDigest
        self.contractFingerprint = contractFingerprint
        self.completionMode = completionMode
        self.commandEvidence = commandEvidence
        self.verifiedAt = verifiedAt
        self.requiredSupportingObligations = requiredSupportingObligations
        self.supportingCommandReceipts = supportingCommandReceipts
        self.planFinalVerificationReceipt = planFinalVerificationReceipt
        self.missionInstanceID = missionInstanceID
        self.fleetVerification = fleetVerification
    }
}
public struct BuilderReviewReceipt: Codable, Sendable, Equatable {
    public let provider: String; public let model: String; public let accepted: Bool; public let checks: [BuilderCheckReceipt]; public let findings: [String]; public let usage: BuilderUsageReceipt
    /// Canonical lower-cased provider:model identities compared by the completion gate. Optional so
    /// snapshots written before independent-review identity auditing still decode.
    public let workerIdentities: [String]?
    public let reviewerIdentity: String?
    public let evidencePacketDigest: String?
    public let votes: [BuilderReviewVoteReceipt]?
    public init(
        provider: String,
        model: String,
        accepted: Bool,
        checks: [BuilderCheckReceipt] = [],
        findings: [String] = [],
        usage: BuilderUsageReceipt = .init(),
        workerIdentities: [String]? = nil,
        reviewerIdentity: String? = nil,
        evidencePacketDigest: String? = nil,
        votes: [BuilderReviewVoteReceipt]? = nil
    ) {
        self.provider = provider
        self.model = model
        self.accepted = accepted
        self.checks = checks
        self.findings = findings
        self.usage = usage
        self.workerIdentities = workerIdentities
        self.reviewerIdentity = reviewerIdentity
        self.evidencePacketDigest = evidencePacketDigest
        self.votes = votes
    }
}
public struct BuilderReviewVoteReceipt: Codable, Sendable, Equatable {
    public let lens: String; public let accepted: Bool; public let reason: String; public let failed: Bool
    public let provider: String?
    public let model: String?
    public init(lens: String, accepted: Bool, reason: String, failed: Bool,
                provider: String? = nil, model: String? = nil) {
        self.lens = lens; self.accepted = accepted; self.reason = reason; self.failed = failed
        self.provider = provider; self.model = model
    }
}
public struct BuilderReviewAttemptReceipt: Codable, Sendable, Equatable {
    public let reviewerIdentity: String; public let producerIdentities: [String]
    public let evidencePacketDigest: String; public let votes: [BuilderReviewVoteReceipt]
    public let accepted: Bool; public let attemptedAt: Date
    public let missionInstanceID: String?
    public init(reviewerIdentity: String, producerIdentities: [String],
                evidencePacketDigest: String, votes: [BuilderReviewVoteReceipt],
                accepted: Bool, attemptedAt: Date, missionInstanceID: String? = nil) {
        self.reviewerIdentity = reviewerIdentity; self.producerIdentities = producerIdentities
        self.evidencePacketDigest = evidencePacketDigest; self.votes = votes
        self.accepted = accepted; self.attemptedAt = attemptedAt
        self.missionInstanceID = missionInstanceID
    }
}
public struct BuilderFinalReceipt: Codable, Sendable, Equatable {
    public let contractID: String; public let route: BuilderRoute; public let workers: [BuilderWorkerReceipt]; public let verification: BuilderVerifierReceipt; public let review: BuilderReviewReceipt; public let accepted: Bool; public let completedAt: Date
    public init(
        contractID: String,
        route: BuilderRoute,
        workers: [BuilderWorkerReceipt],
        verification: BuilderVerifierReceipt,
        review: BuilderReviewReceipt,
        accepted: Bool,
        completedAt: Date
    ) {
        self.contractID = contractID
        self.route = route
        self.workers = workers
        self.verification = verification
        self.review = review
        self.accepted = accepted
        self.completedAt = completedAt
    }
}
public struct BuilderNodeState: Codable, Sendable, Equatable {
    public var phase: BuilderNodePhase; public var attempts: Int; public var lastFailureFingerprint: String?; public var identicalFailureCount: Int; public var failureReason: String?; public var worker: BuilderWorkerReceipt?; public var verification: BuilderVerifierReceipt?; public var promotion: BuilderTransactionPromotionReceipt?; public var trustedTelemetry: [BuilderTrustedTelemetryObservation]
    public init(phase: BuilderNodePhase = .pending) {
        self.phase = phase
        self.attempts = 0
        self.lastFailureFingerprint = nil
        self.identicalFailureCount = 0
        self.failureReason = nil
        self.worker = nil
        self.verification = nil
        self.promotion = nil
        self.trustedTelemetry = []
    }
}
public struct BuilderRunSnapshot: Codable, Sendable, Equatable {
    public let contractID: String; public var checkpointIdentity: String? = nil; public let route: BuilderRoute; public var nodeStates: [String: BuilderNodeState]; public var finalReceipt: BuilderFinalReceipt?; public var updatedAt: Date; public var usage: BuilderUsageReceipt? = nil; public var reviewAttempt: BuilderReviewAttemptReceipt? = nil

    public var selectedExecutionContracts: [String: BuilderSelectedNodeExecutionContract]? = nil
    public var governanceAdmission: BuilderGraphGovernanceAdmission? = nil
    public var schemaVersion: Int = 2
    public var parentContractFingerprint: String? = nil
    public var graphFingerprint: String? = nil
    public var sequence: Int = 0
    public var reviewAccepted: Bool = false
    public var commitEpoch: String? = nil
    public var finalizationPending: Bool = false
    public var pendingFinalReceipt: BuilderFinalReceipt? = nil
    public var trustedTelemetry: [BuilderTrustedTelemetryObservation] = []
    public var aggregateTransaction: BuilderAggregateTransactionDescriptor? = nil
}

private struct SealedBuilderRunSnapshot: Codable, Sendable, Equatable {
    let snapshot: BuilderRunSnapshot
    let seal: String
}

private struct BuilderRunHighWaterRecord: Codable, Sendable, Equatable {
    let sequence: Int
    let snapshotDigest: String
    let previousDigest: String?
}

private struct SealedBuilderRunHighWaterRecord: Codable, Sendable, Equatable {
    let record: BuilderRunHighWaterRecord
    let seal: String
}

public final class BuilderJSONStoreLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }
    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }
    deinit { release() }
}

public actor BuilderJSONStore {
    public nonisolated let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func acquireLease() throws -> BuilderJSONStoreLease {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(".\(fileURL.lastPathComponent).lease")
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw BuilderRunError.persistedStateMismatch }
        guard fchmod(fd, mode_t(0o600)) == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd)
            throw BuilderRunError.persistedStateMismatch
        }
        return BuilderJSONStoreLease(descriptor: fd)
    }
    public func load() throws -> BuilderRunSnapshot? {
        guard let data = try BuilderDurableIO.readSecure(fileURL) else { return nil }
        let envelope = try JSONDecoder().decode(SealedBuilderRunSnapshot.self, from: data)
        guard try BuilderDurableIO.canonicalData(envelope) == data else {
            throw BuilderRunError.persistedStateInvalid("run snapshot is not canonical")
        }
        let canonical = String(
            decoding: try BuilderDurableIO.canonicalData(envelope.snapshot), as: UTF8.self)
        guard ForgeSeal.verify(canonical, seal: envelope.seal) else {
            throw BuilderRunError.persistedStateInvalid("run snapshot seal is invalid")
        }
        let snapshotDigest = BuilderEvidenceDigest.sha256(canonical)
        let records = try highWaterRecords()
        guard let last = records.last else {
            throw BuilderRunError.persistedStateInvalid("run high-water journal is missing")
        }
        if envelope.snapshot.sequence == last.sequence + 1 {
            try appendHighWater(sequence: envelope.snapshot.sequence,
                                snapshotDigest: snapshotDigest, previous: last)
        } else {
            guard envelope.snapshot.sequence == last.sequence,
                  last.snapshotDigest == snapshotDigest else {
                throw BuilderRunError.persistedStateInvalid(
                    "sealed run snapshot was replayed or diverged from its monotonic journal")
            }
        }
        return envelope.snapshot
    }
    public func create(_ snapshot: BuilderRunSnapshot) throws {
        let data = try sealedData(snapshot)
        do {
            try BuilderDurableIO.writeExclusive(data, to: fileURL)
            try appendHighWater(
                sequence: snapshot.sequence,
                snapshotDigest: BuilderEvidenceDigest.sha256(String(
                    decoding: try BuilderDurableIO.canonicalData(snapshot), as: UTF8.self)),
                previous: nil)
        }
        catch { throw BuilderRunError.persistedStateMismatch }
    }
    public func save(_ snapshot: BuilderRunSnapshot) throws {
        guard let current = try load(), snapshot.sequence == current.sequence + 1 else {
            throw BuilderRunError.persistedStateInvalid(
                "run snapshot sequence is stale or nonmonotonic")
        }
        try BuilderDurableIO.writeAtomic(try sealedData(snapshot), to: fileURL)
        let previous = try highWaterRecords().last
        try appendHighWater(
            sequence: snapshot.sequence,
            snapshotDigest: BuilderEvidenceDigest.sha256(String(
                decoding: try BuilderDurableIO.canonicalData(snapshot), as: UTF8.self)),
            previous: previous)
    }
    private func sealedData(_ snapshot: BuilderRunSnapshot) throws -> Data {
        let canonical = String(
            decoding: try BuilderDurableIO.canonicalData(snapshot), as: UTF8.self)
        let seal = ForgeSeal.sign(canonical)
        guard !seal.isEmpty else {
            throw BuilderRunError.persistedStateInvalid("run snapshot seal unavailable")
        }
        return try BuilderDurableIO.canonicalData(
            SealedBuilderRunSnapshot(snapshot: snapshot, seal: seal))
    }

    private var highWaterURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).high-water")
    }

    private func highWaterRecords() throws -> [BuilderRunHighWaterRecord] {
        guard let data = try BuilderDurableIO.readSecure(highWaterURL) else { return [] }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BuilderRunError.persistedStateInvalid("run high-water journal is not UTF-8")
        }
        var records: [BuilderRunHighWaterRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let bytes = String(line).data(using: .utf8) else {
                throw BuilderRunError.persistedStateInvalid("invalid high-water record")
            }
            let envelope = try JSONDecoder().decode(
                SealedBuilderRunHighWaterRecord.self, from: bytes)
            guard try BuilderDurableIO.canonicalData(envelope) == bytes else {
                throw BuilderRunError.persistedStateInvalid("noncanonical high-water record")
            }
            let canonical = String(
                decoding: try BuilderDurableIO.canonicalData(envelope.record), as: UTF8.self)
            guard ForgeSeal.verify(canonical, seal: envelope.seal),
                  envelope.record.sequence == records.count,
                  envelope.record.previousDigest == records.last?.snapshotDigest else {
                throw BuilderRunError.persistedStateInvalid("invalid high-water chain")
            }
            records.append(envelope.record)
        }
        return records
    }

    private func appendHighWater(sequence: Int, snapshotDigest: String,
                                 previous: BuilderRunHighWaterRecord?) throws {
        guard sequence == (previous?.sequence ?? -1) + 1 else {
            throw BuilderRunError.persistedStateInvalid("nonmonotonic high-water append")
        }
        let record = BuilderRunHighWaterRecord(
            sequence: sequence, snapshotDigest: snapshotDigest,
            previousDigest: previous?.snapshotDigest)
        let canonical = String(
            decoding: try BuilderDurableIO.canonicalData(record), as: UTF8.self)
        let seal = ForgeSeal.sign(canonical)
        guard !seal.isEmpty else {
            throw BuilderRunError.persistedStateInvalid("high-water seal unavailable")
        }
        var data = try BuilderDurableIO.canonicalData(
            SealedBuilderRunHighWaterRecord(record: record, seal: seal))
        data.append(0x0a)
        try BuilderDurableIO.appendDurable(data, to: highWaterURL)
    }
}
public struct BuilderLease: Sendable, Hashable {
    fileprivate let id: UUID
    public let owner: String
}
public actor BuilderResourceLeaseTable {
    private struct Entry: Sendable {
        let lease: BuilderLease
        let claims: [BuilderResourceClaim]
    }
    private var entries: [UUID: Entry] = [:]
    public init() {}
    public func acquire(owner: String, claims: [BuilderResourceClaim]) async throws -> BuilderLease {
        let normalized = claims.map {
            BuilderResourceClaim(path: normalize($0.path), access: $0.access)
        }
        while hasConflict(claims: normalized) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let lease = BuilderLease(id: UUID(), owner: owner)
        entries[lease.id] = Entry(lease: lease, claims: normalized)
        return lease
    }
    public func release(_ lease: BuilderLease) { entries.removeValue(forKey: lease.id) }
    private func hasConflict(claims: [BuilderResourceClaim]) -> Bool {
        for entry in entries.values {
            for left in claims {
                for right in entry.claims where overlaps(left.path, right.path) {
                    if left.access == .write || right.access == .write { return true }
                }
            }
        }
        return false
    }
    private func normalize(_ path: String) -> String {
        let expanded = (path as NSString).standardizingPath
        return expanded.isEmpty ? "." : expanded
    }
    private func overlaps(_ left: String, _ right: String) -> Bool {
        if left == right || left == "." || right == "." || left == "/" || right == "/" { return true }
        return left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }
}
public struct BuilderAcceptedDependencyResult: Codable, Sendable, Equatable {
    public let nodeID: String
    public let worker: BuilderWorkerReceipt
    public let verification: BuilderVerifierReceipt
    public let parentContractFingerprint: String?
    public let graphFingerprint: String?
    public let consumerNodeID: String?
    public let consumerAttempt: Int?
    public let acceptedCheckpointSequence: Int?
    public let bindingDigest: String?
    public let bindingSeal: String?

    public init(nodeID: String, worker: BuilderWorkerReceipt,
                verification: BuilderVerifierReceipt) throws {
        guard worker.nodeID == nodeID,
              verification.scope == .node(nodeID),
              verification.deterministic, verification.passed,
              verification.checks.allSatisfy(\.passed) else {
            throw BuilderRunError.persistedStateInvalid(
                "dependency \(nodeID) lacks an accepted deterministic receipt")
        }
        self.nodeID = nodeID; self.worker = worker; self.verification = verification
        self.parentContractFingerprint = nil; self.graphFingerprint = nil
        self.consumerNodeID = nil; self.consumerAttempt = nil
        self.acceptedCheckpointSequence = nil
        self.bindingDigest = nil; self.bindingSeal = nil
    }

    init(nodeID: String, worker: BuilderWorkerReceipt,
         verification: BuilderVerifierReceipt, parentContractFingerprint: String,
         graphFingerprint: String, consumerNodeID: String, consumerAttempt: Int,
         acceptedCheckpointSequence: Int) throws {
        guard worker.nodeID == nodeID,
              verification.scope == .node(nodeID),
              verification.deterministic, verification.passed,
              verification.checks.allSatisfy(\.passed) else {
            throw BuilderRunError.persistedStateInvalid(
                "dependency \(nodeID) lacks an accepted deterministic receipt")
        }
        self.nodeID = nodeID
        self.worker = worker
        self.verification = verification
        self.parentContractFingerprint = parentContractFingerprint
        self.graphFingerprint = graphFingerprint
        self.consumerNodeID = consumerNodeID
        self.consumerAttempt = consumerAttempt
        self.acceptedCheckpointSequence = acceptedCheckpointSequence
        struct Binding: Codable {
            let nodeID: String; let worker: BuilderWorkerReceipt
            let verification: BuilderVerifierReceipt
            let parentContractFingerprint: String; let graphFingerprint: String
            let consumerNodeID: String; let consumerAttempt: Int
            let acceptedCheckpointSequence: Int
        }
        let canonical = String(decoding: try BuilderDurableIO.canonicalData(Binding(
            nodeID: nodeID, worker: worker, verification: verification,
            parentContractFingerprint: parentContractFingerprint,
            graphFingerprint: graphFingerprint, consumerNodeID: consumerNodeID,
            consumerAttempt: consumerAttempt,
            acceptedCheckpointSequence: acceptedCheckpointSequence)), as: UTF8.self)
        let digest = BuilderEvidenceDigest.sha256(canonical)
        let seal = ForgeSeal.sign(canonical)
        guard !seal.isEmpty else {
            throw BuilderRunError.persistedStateInvalid("dependency binding seal unavailable")
        }
        self.bindingDigest = digest
        self.bindingSeal = seal
    }

    func validateBinding(parentContractFingerprint: String, graphFingerprint: String,
                         consumerNodeID: String, consumerAttempt: Int,
                         currentCheckpointSequence: Int) throws {
        guard self.parentContractFingerprint == parentContractFingerprint,
              self.graphFingerprint == graphFingerprint,
              self.consumerNodeID == consumerNodeID,
              self.consumerAttempt == consumerAttempt,
              let acceptedCheckpointSequence,
              acceptedCheckpointSequence <= currentCheckpointSequence,
              let bindingDigest, let bindingSeal else {
            throw BuilderRunError.persistedStateInvalid("dependency result is unbound or stale")
        }
        let rebound = try BuilderAcceptedDependencyResult(
            nodeID: nodeID, worker: worker, verification: verification,
            parentContractFingerprint: parentContractFingerprint,
            graphFingerprint: graphFingerprint, consumerNodeID: consumerNodeID,
            consumerAttempt: consumerAttempt,
            acceptedCheckpointSequence: acceptedCheckpointSequence)
        guard rebound.bindingDigest == bindingDigest,
              ForgeSeal.verify(
                String(decoding: try BuilderDurableIO.canonicalData(
                    DependencyBindingProjection(rebound)), as: UTF8.self),
                seal: bindingSeal) else {
            throw BuilderRunError.persistedStateInvalid("dependency result seal is invalid")
        }
    }
}

private struct DependencyBindingProjection: Codable {
    let nodeID: String; let worker: BuilderWorkerReceipt
    let verification: BuilderVerifierReceipt
    let parentContractFingerprint: String; let graphFingerprint: String
    let consumerNodeID: String; let consumerAttempt: Int
    let acceptedCheckpointSequence: Int
    init(_ value: BuilderAcceptedDependencyResult) {
        nodeID = value.nodeID; worker = value.worker; verification = value.verification
        parentContractFingerprint = value.parentContractFingerprint ?? ""
        graphFingerprint = value.graphFingerprint ?? ""
        consumerNodeID = value.consumerNodeID ?? ""
        consumerAttempt = value.consumerAttempt ?? 0
        acceptedCheckpointSequence = value.acceptedCheckpointSequence ?? -1
    }
}

public struct BuilderExecutionRequest: Sendable {
    public let contract: BuilderContract; public let route: BuilderRoute; public let node: BuilderNode; public let attempt: Int; public let executionWorkspace: BuilderExecutionWorkspace?; public let acceptedDependencies: [BuilderAcceptedDependencyResult]
    public init(contract: BuilderContract, route: BuilderRoute, node: BuilderNode,
                attempt: Int, executionWorkspace: BuilderExecutionWorkspace? = nil,
                acceptedDependencies: [BuilderAcceptedDependencyResult] = []) {
        self.contract = contract; self.route = route; self.node = node
        self.attempt = attempt; self.executionWorkspace = executionWorkspace
        self.acceptedDependencies = acceptedDependencies.sorted { $0.nodeID < $1.nodeID }
    }
}
public enum BuilderVerificationRequest: Sendable {
    case node(
        contract: BuilderContract,
        node: BuilderNode,
        worker: BuilderWorkerReceipt,
        executionWorkspace: BuilderExecutionWorkspace?
    )
    case final(contract: BuilderContract, route: BuilderRoute, workers: [BuilderWorkerReceipt])
}
public struct BuilderReviewRequest: Sendable {
    public let contract: BuilderContract
    public let route: BuilderRoute
    public let workers: [BuilderWorkerReceipt]
    public let verification: BuilderVerifierReceipt
    public let promotionReceipts: [BuilderTransactionPromotionReceipt]
    public let acceptedAttempts: [String: Int]
    public let selectedContractFingerprints: [String: String]
    public let acceptedVerificationSubjectDigests: [String: String]

    public init(contract: BuilderContract, route: BuilderRoute,
                workers: [BuilderWorkerReceipt], verification: BuilderVerifierReceipt,
                promotionReceipts: [BuilderTransactionPromotionReceipt] = [],
                acceptedAttempts: [String: Int] = [:],
                selectedContractFingerprints: [String: String] = [:],
                acceptedVerificationSubjectDigests: [String: String] = [:]) {
        self.contract = contract
        self.route = route
        self.workers = workers
        self.verification = verification
        self.promotionReceipts = promotionReceipts
        self.acceptedAttempts = acceptedAttempts
        self.selectedContractFingerprints = selectedContractFingerprints
        self.acceptedVerificationSubjectDigests = acceptedVerificationSubjectDigests
    }
}
public typealias BuilderExecute = @Sendable (BuilderExecutionRequest) async throws -> BuilderWorkerReceipt
public typealias BuilderVerify = @Sendable (BuilderVerificationRequest) async throws -> BuilderVerifierReceipt
public typealias BuilderReview = @Sendable (BuilderReviewRequest) async throws -> BuilderReviewReceipt
public enum BuilderRunError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case persistedStateMismatch
    case persistedStateInvalid(String)
    case executionFailed([String: String])
    case stalled([String])
    case finalVerificationFailed(String)
    case reviewRejected([String])
    case reviewerNotIndependent(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let value): return value
        case .persistedStateMismatch: return "Persisted builder state belongs to another contract or graph"
        case .persistedStateInvalid(let value): return "Persisted builder state is invalid: \(value)"
        case .executionFailed(let failures):
            return failures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
        case .stalled(let nodes): return "Builder graph stalled at: \(nodes.joined(separator: ", "))"
        case .finalVerificationFailed(let value): return "Final verification failed: \(value)"
        case .reviewRejected(let findings): return "Independent review rejected: \(findings.joined(separator: "; "))"
        case .reviewerNotIndependent(let identity):
            return "Independent completion review unavailable: \(identity). Configure an available reviewer with a provider:model identity distinct from every producing worker."
        }
    }
}
private enum BuilderAttemptOutcome: Sendable {
    case accepted(String, BuilderWorkerReceipt, BuilderVerifierReceipt,
                  BuilderTransactionPromotionReceipt?,
                  [BuilderTrustedTelemetryObservation])
    case rejected(String, String, String)
    case terminal(String, String, String)
}
public actor BuilderRun {
    public let contract: BuilderContract; public let graph: BuilderGraph; public let route: BuilderRoute; public let maxParallelism: Int; public let identicalFailureLimit: Int
    private let store: BuilderJSONStore
    private let leases: BuilderResourceLeaseTable
    private let execute: BuilderExecute
    private let verify: BuilderVerify
    private let review: BuilderReview
    private let resumeExisting: Bool
    private let executionGovernance: BuilderExecutionGovernanceRuntime?
    private let graphExecutionPolicy: BuilderGraphExecutionPolicy?
    private let nodeExecutionContractProvider: (any BuilderNodeExecutionContractProvider)?
    private let nodeObservationSourceProvider: (any BuilderNodeObservationSourceProvider)?
    private let readOnlyObservationSourceProvider: (any BuilderReadOnlyObservationSourceProvider)?
    private let configuredAggregateTransaction: BuilderAggregateTransactionDescriptor?
    public init(
        contract: BuilderContract,
        graph: BuilderGraph,
        store: BuilderJSONStore,
        leases: BuilderResourceLeaseTable = .init(),
        maxParallelism: Int = 4,
        identicalFailureLimit: Int = 2,
        resumeExisting: Bool = false,
        graphExecutionPolicy: BuilderGraphExecutionPolicy? = nil,
        nodeExecutionContractProvider: (any BuilderNodeExecutionContractProvider)? = nil,
        nodeObservationSourceProvider: (any BuilderNodeObservationSourceProvider)? = nil,
        readOnlyObservationSourceProvider: (any BuilderReadOnlyObservationSourceProvider)? = nil,
        aggregateTransaction: BuilderAggregateTransactionDescriptor? = nil,
        stageObservationSource: (any BuilderStageObservationSource)? = nil,
        execute: @escaping BuilderExecute,
        verify: @escaping BuilderVerify,
        review: @escaping BuilderReview
    ) throws {
        guard maxParallelism > 0 else {
            throw BuilderRunError.invalidConfiguration("maxParallelism must be positive")
        }
        guard identicalFailureLimit > 0 else {
            throw BuilderRunError.invalidConfiguration("identicalFailureLimit must be positive")
        }
        if contract.effectiveCompletionMode == .build, graphExecutionPolicy == nil {
            throw BuilderRunError.invalidConfiguration(
                "build/mutation runs require an explicit graph execution policy; legacy execution is read-only only")
        }
        if let startup = contract.executionContract {
            guard let startupNode = graph.nodes.first(where: {
                $0.id == startup.contract.builderNodeID
            }) else {
                throw BuilderRunError.invalidConfiguration(
                    "startup execution contract references an unknown node")
            }
            do {
                try BuilderSelectedNodeExecutionContract.validateMutationAuthority(
                    startup.contract.mutations.map(\.path),
                    parentAllowedPaths: contract.allowedPaths,
                    nodeWriteClaims: startupNode.resources
                        .filter { $0.access == .write }.map(\.path))
            } catch {
                throw BuilderRunError.invalidConfiguration(error.localizedDescription)
            }
        }
        if let graphExecutionPolicy {
            do {
                try graphExecutionPolicy.validate(graph: graph)
                if let startup = contract.executionContract,
                   let startupNode = graph.nodes.first(where: {
                       $0.id == startup.contract.builderNodeID
                   }) {
                    if graphExecutionPolicy.executionClass(for: startupNode.id) == .readOnly,
                       !startup.contract.mutations.isEmpty {
                        throw BuilderRunError.invalidConfiguration(
                            "read-only startup node has mutation operations")
                    }
                }
            } catch {
                throw BuilderRunError.invalidConfiguration(error.localizedDescription)
            }
            let startupNodeID = contract.executionContract?.contract.builderNodeID
            let requiresDynamic = graph.nodes.contains {
                graphExecutionPolicy.executionClass(for: $0.id) == .mutation
                    && $0.id != startupNodeID
            }
            if requiresDynamic, nodeExecutionContractProvider == nil {
                throw BuilderRunError.invalidConfiguration(
                    "strict graph governance requires a dynamic contract provider")
            }
            if requiresDynamic, nodeObservationSourceProvider == nil {
                throw BuilderRunError.invalidConfiguration(
                    "dynamic governed nodes require a scoped observation-source provider")
            }
            let hasReadOnly = graph.nodes.contains {
                graphExecutionPolicy.executionClass(for: $0.id) == .readOnly
                    && $0.id != startupNodeID
            }
            if hasReadOnly, readOnlyObservationSourceProvider == nil {
                throw BuilderRunError.invalidConfiguration(
                    "explicit read-only nodes require a trusted workspace observation source")
            }
        } else if nodeExecutionContractProvider != nil || nodeObservationSourceProvider != nil
                    || readOnlyObservationSourceProvider != nil {
            throw BuilderRunError.invalidConfiguration(
                "dynamic contract providers require an explicit graph execution policy")
        }
        if let executionContract = contract.executionContract {
            do {
                try executionContract.validate(
                    builderContractID: contract.id,
                    graphNodeIDs: graph.nodes.map(\.id))
            } catch {
                throw BuilderRunError.invalidConfiguration(
                    "invalid sealed execution contract: \(error.localizedDescription)")
            }
        }
        self.contract = contract
        self.graph = graph
        self.route = contract.routeHint.resolve()
        self.store = store
        self.leases = leases
        self.maxParallelism = maxParallelism
        self.identicalFailureLimit = identicalFailureLimit
        self.resumeExisting = resumeExisting
        self.graphExecutionPolicy = graphExecutionPolicy
        self.nodeExecutionContractProvider = nodeExecutionContractProvider
        self.nodeObservationSourceProvider = nodeObservationSourceProvider
        self.readOnlyObservationSourceProvider = readOnlyObservationSourceProvider
        self.configuredAggregateTransaction = aggregateTransaction
        if let sealed = contract.executionContract {
            self.executionGovernance = try BuilderExecutionGovernanceRuntime(
                sealed: sealed, source: stageObservationSource, beside: store.fileURL)
        } else {
            self.executionGovernance = nil
        }
        self.execute = execute
        self.verify = verify
        self.review = review
    }

    private func dynamicGovernance(
        for node: BuilderNode,
        attempt: Int,
        snapshot: inout BuilderRunSnapshot
    ) async throws -> BuilderExecutionGovernanceRuntime? {
        if let executionGovernance,
           executionGovernance.contract.builderNodeID == node.id {
            return executionGovernance
        }
        guard let graphExecutionPolicy else { return nil }
        guard graphExecutionPolicy.executionClass(for: node.id) == .mutation else { return nil }
        guard let provider = nodeExecutionContractProvider else {
            throw BuilderDynamicContractError.missingContractProvider(node.id)
        }
        guard let sourceProvider = nodeObservationSourceProvider else {
            throw BuilderDynamicContractError.missingObservationSource(node.id)
        }

        let graphNodeIDs = graph.nodes.map(\.id)
        let writeClaims = node.resources.filter { $0.access == .write }.map(\.path)
        let selection: BuilderSelectedNodeExecutionContract
        if let persisted = snapshot.selectedExecutionContracts?[node.id],
           persisted.attempt == attempt {
            try persisted.validate(
                builderContractID: contract.id,
                graphNodeIDs: graphNodeIDs,
                expectedNodeID: node.id,
                expectedAttempt: attempt,
                providerIdentity: provider.identity,
                parentAllowedPaths: contract.allowedPaths,
                nodeWriteClaims: writeClaims)
            selection = persisted
        } else {
            if let persisted = snapshot.selectedExecutionContracts?[node.id],
               persisted.attempt >= attempt {
                throw BuilderDynamicContractError.invalidAttempt
            }
            let dependencies = try node.dependencies.map { dependencyID in
                guard let dependencyNode = graph.nodes.first(where: { $0.id == dependencyID }),
                      let state = snapshot.nodeStates[dependencyID],
                      state.phase == .accepted,
                      let worker = state.worker,
                      let verification = state.verification else {
                    throw BuilderDynamicContractError.invalidDependencyResults(node.id)
                }
                return try BuilderCommittedDependencyResult(
                    node: dependencyNode, worker: worker, verification: verification,
                    parentContractFingerprint: parentContractFingerprint(contract),
                    graphFingerprint: builderGraphFingerprint(graph),
                    consumerNodeID: node.id, consumerAttempt: attempt,
                    acceptedCheckpointSequence: snapshot.sequence)
            }
            let request = try BuilderNodeContractRequest(
                builderContract: contract, graph: graph, node: node,
                attempt: attempt, dependencies: dependencies)
            let sealed = try await provider.sealedContract(for: request)
            let derived = try BuilderSelectedNodeExecutionContract(
                nodeID: node.id, attempt: attempt,
                providerIdentity: provider.identity, sealedContract: sealed)
            try derived.validate(
                builderContractID: contract.id,
                graphNodeIDs: graphNodeIDs,
                expectedNodeID: node.id,
                expectedAttempt: attempt,
                providerIdentity: provider.identity,
                parentAllowedPaths: contract.allowedPaths,
                nodeWriteClaims: writeClaims)
            if let persisted = snapshot.selectedExecutionContracts?[node.id] {
                try persisted.validate(
                    builderContractID: contract.id,
                    graphNodeIDs: graphNodeIDs,
                    expectedNodeID: node.id,
                    expectedAttempt: persisted.attempt,
                    providerIdentity: provider.identity,
                    parentAllowedPaths: contract.allowedPaths,
                    nodeWriteClaims: writeClaims)
                guard persisted.attempt + 1 == attempt,
                      persisted.contractFingerprint == derived.contractFingerprint,
                      persisted.contractSealReference == derived.contractSealReference else {
                    throw BuilderDynamicContractError.retryContractDrift
                }
            }
            var selected = snapshot.selectedExecutionContracts ?? [:]
            selected[node.id] = derived
            snapshot.selectedExecutionContracts = selected
            selection = derived
        }

        let source = try await sourceProvider.source(for: .init(
            builderContractID: contract.id,
            graphNodeIDs: graphNodeIDs,
            node: node,
            attempt: attempt,
            contractFingerprint: selection.contractFingerprint,
            contractSealReference: selection.contractSealReference))
        let runtime = try BuilderExecutionGovernanceRuntime(
            sealed: selection.sealedContract,
            source: source,
            beside: store.fileURL,
            contractSealReference: selection.contractSealReference)
        try runtime.ensureReady()
        return runtime
    }

    private func reconcileDynamicGovernance(
        snapshot: inout BuilderRunSnapshot,
        runtimes: inout [String: BuilderExecutionGovernanceRuntime],
        aggregate: BuilderAggregateTransactionDescriptor?,
        aggregateSource: inout BuilderIsolatedWorkspaceTransactionSource?
    ) async throws {
        guard let selections = snapshot.selectedExecutionContracts, !selections.isEmpty else { return }
        guard graphExecutionPolicy != nil,
              let provider = nodeExecutionContractProvider,
              let sourceProvider = nodeObservationSourceProvider else {
            throw BuilderRunError.persistedStateInvalid(
                "persisted dynamic contracts require their trusted provider and observation source")
        }
        let graphNodeIDs = graph.nodes.map(\.id)
        for nodeID in selections.keys.sorted() {
            guard let selection = selections[nodeID],
                  let node = graph.nodes.first(where: { $0.id == nodeID }),
                  let state = snapshot.nodeStates[nodeID] else {
                throw BuilderRunError.persistedStateInvalid(
                    "persisted dynamic contract references an unknown node")
            }
            try selection.validate(
                builderContractID: contract.id,
                graphNodeIDs: graphNodeIDs,
                expectedNodeID: nodeID,
                expectedAttempt: state.attempts,
                providerIdentity: provider.identity,
                parentAllowedPaths: contract.allowedPaths,
                nodeWriteClaims: node.resources.filter { $0.access == .write }.map(\.path))
            let source = try await sourceProvider.source(for: .init(
                builderContractID: contract.id,
                graphNodeIDs: graphNodeIDs,
                node: node,
                attempt: selection.attempt,
                contractFingerprint: selection.contractFingerprint,
                contractSealReference: selection.contractSealReference))
            let runtime = try BuilderExecutionGovernanceRuntime(
                sealed: selection.sealedContract,
                source: source,
                beside: store.fileURL,
                contractSealReference: selection.contractSealReference)
        try runtime.ensureReady()
        if let aggregate {
            aggregateSource = try await registerAggregateRuntime(
                runtime, node: node, attempt: selection.attempt,
                descriptor: aggregate, current: aggregateSource)
        }
        try await runtime.reconcile(
            snapshotAccepted: state.phase == .accepted,
            runAccepted: snapshot.reviewAccepted
                && (snapshot.pendingFinalReceipt?.accepted == true
                    || snapshot.finalReceipt?.accepted == true)
                && snapshot.commitEpoch?.count == 64)
        runtimes[nodeID] = runtime
    }
}

    private func ensureAggregateDescriptor(
        snapshot: inout BuilderRunSnapshot
    ) throws -> BuilderAggregateTransactionDescriptor? {
        guard let policy = graphExecutionPolicy else { return nil }
        let nodes = graph.nodes.filter {
            policy.executionClass(for: $0.id) == .mutation
        }.map(\.id).sorted()
        guard nodes.count > 1 else {
            guard configuredAggregateTransaction == nil else {
                throw BuilderRunError.invalidConfiguration(
                    "aggregate transaction supplied for fewer than two mutation nodes")
            }
            return nil
        }
        let expectedParent = try parentContractFingerprint(contract)
        let expectedGraph = try builderGraphFingerprint(graph)
        let descriptor: BuilderAggregateTransactionDescriptor
        if let configuredAggregateTransaction {
            descriptor = configuredAggregateTransaction
        } else if let persisted = snapshot.aggregateTransaction {
            descriptor = persisted
        } else {
            descriptor = try .init(
                aggregateID: BuilderEvidenceDigest.sha256(
                    "\(expectedParent):\(expectedGraph):\(UUID().uuidString)"),
                parentContractFingerprint: expectedParent,
                graphFingerprint: expectedGraph,
                expectedNodeIDs: nodes)
        }
        try descriptor.validate()
        guard descriptor.parentContractFingerprint == expectedParent,
              descriptor.graphFingerprint == expectedGraph,
              descriptor.expectedNodeIDs == nodes,
              snapshot.aggregateTransaction == nil || snapshot.aggregateTransaction == descriptor else {
            throw BuilderRunError.persistedStateInvalid(
                "aggregate transaction does not match the parent graph")
        }
        snapshot.aggregateTransaction = descriptor
        return descriptor
    }

    private func registerAggregateRuntime(
        _ runtime: BuilderExecutionGovernanceRuntime,
        node: BuilderNode,
        attempt: Int,
        descriptor: BuilderAggregateTransactionDescriptor,
        current: BuilderIsolatedWorkspaceTransactionSource?
    ) async throws -> BuilderIsolatedWorkspaceTransactionSource {
        guard let source = runtime.source as? BuilderIsolatedWorkspaceTransactionSource else {
            throw BuilderRunError.invalidConfiguration(
                "fleet mutation nodes require one aggregate-capable transaction source")
        }
        if let current, current !== source {
            throw BuilderRunError.invalidConfiguration(
                "fleet mutation nodes must share one aggregate transaction source instance")
        }
        try await source.beginAggregate(descriptor)
        let context = try BuilderStageContext(
            contract: runtime.contract, node: node, attempt: attempt, stage: .build)
        try await source.registerAggregateChild(descriptor, context: context)
        return source
    }

    private func readOnlyGuard(for node: BuilderNode, attempt: Int) async throws
        -> BuilderReadOnlyExecutionGuard? {
        guard let graphExecutionPolicy,
              graphExecutionPolicy.executionClass(for: node.id) == .readOnly else { return nil }
        guard let provider = readOnlyObservationSourceProvider else {
            throw BuilderReadOnlyObservationError.missingTrustedSource(node.id)
        }
        let context = try BuilderReadOnlyObservationContext(
            builderContractID: contract.id,
            graphNodeIDs: graph.nodes.map(\.id),
            node: node,
            attempt: attempt)
        let source = try await provider.source(for: context)
        return .init(context: context, source: source)
    }

    private func admitGraphGovernance(snapshot: inout BuilderRunSnapshot) throws {
        let policy = graphExecutionPolicy ?? BuilderGraphExecutionPolicy(nodeClasses:
            Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, .readOnly) }))
        let expected = try BuilderGraphGovernanceAdmission.make(
            graph: graph, policy: policy,
            providerIdentity: nodeExecutionContractProvider?.identity)
        let hasDurableProgress = snapshot.finalReceipt != nil
            || snapshot.reviewAttempt != nil
            || snapshot.selectedExecutionContracts != nil
            || snapshot.nodeStates.values.contains {
                $0.attempts > 0 || $0.phase != .pending
            }
        if expected.governanceRequired {
            if let declared = contract.governanceAdmission {
                try declared.validate(matches: expected)
            } else if hasDurableProgress && snapshot.governanceAdmission == nil {
                throw BuilderGraphGovernanceAdmissionError.missingMutationGovernance
            }
        } else if let declared = contract.governanceAdmission {
            try declared.validate(matches: expected)
        }
        if let persisted = snapshot.governanceAdmission {
            try persisted.validate(matches: expected)
        } else {
            if expected.governanceRequired && hasDurableProgress {
                throw BuilderRunError.persistedStateInvalid(
                    "mutation run snapshot predates sealed graph-governance admission")
            }
            snapshot.governanceAdmission = expected
        }

        guard expected.governanceRequired else { return }
        let startupNodeID = contract.executionContract?.contract.builderNodeID
        let selected = Set(snapshot.selectedExecutionContracts?.keys.map { $0 } ?? [])
        for nodeID in expected.governedNodeIDs where nodeID != startupNodeID {
            guard let state = snapshot.nodeStates[nodeID] else {
                throw BuilderRunError.persistedStateInvalid(
                    "governed graph admission references missing node \(nodeID)")
            }
            if state.phase == .accepted || state.attempts > 0 {
                guard selected.contains(nodeID) else {
                    throw BuilderRunError.persistedStateInvalid(
                        "progressed mutation node \(nodeID) has no sealed selected execution contract")
                }
            }
        }
        if snapshot.finalReceipt?.accepted == true {
            let requiredDynamic = Set(expected.governedNodeIDs.filter { $0 != startupNodeID })
            guard selected == requiredDynamic else {
                throw BuilderRunError.persistedStateInvalid(
                    "accepted mutation run has an incomplete governed contract set")
            }
        }
    }

    public func run() async throws -> BuilderFinalReceipt {
        let runLease = try await store.acquireLease()
        defer { runLease.release() }
        var snapshot = try await restoredSnapshot()
        try admitGraphGovernance(snapshot: &snapshot)
        let aggregate = try ensureAggregateDescriptor(snapshot: &snapshot)
        try await persist(&snapshot)
        var governedRuntimes: [String: BuilderExecutionGovernanceRuntime] = [:]
        var aggregateSource: BuilderIsolatedWorkspaceTransactionSource?
        if let executionGovernance {
            try executionGovernance.ensureReady()
            let nodeID = executionGovernance.contract.builderNodeID
            if let aggregate,
               let node = graph.nodes.first(where: { $0.id == nodeID }),
               let attempt = snapshot.nodeStates[nodeID]?.attempts,
               attempt > 0 {
                aggregateSource = try await registerAggregateRuntime(
                    executionGovernance, node: node, attempt: attempt,
                    descriptor: aggregate, current: aggregateSource)
            }
            try await executionGovernance.reconcile(
                snapshotAccepted: snapshot.nodeStates[nodeID]?.phase == .accepted,
            runAccepted: snapshot.reviewAccepted
                && (snapshot.pendingFinalReceipt?.accepted == true
                    || snapshot.finalReceipt?.accepted == true)
                && snapshot.commitEpoch?.count == 64)
            governedRuntimes[nodeID] = executionGovernance
        }
        try await reconcileDynamicGovernance(
            snapshot: &snapshot, runtimes: &governedRuntimes,
            aggregate: aggregate, aggregateSource: &aggregateSource)
        if let pending = snapshot.pendingFinalReceipt, pending.accepted {
            guard snapshot.reviewAccepted, snapshot.commitEpoch?.count == 64 else {
                throw BuilderRunError.persistedStateInvalid(
                    "pending final receipt lacks a durable global acceptance decision")
            }
            do {
                let refreshed: BuilderVerifierReceipt
                if let aggregate {
                    guard let aggregateSource, let commitEpoch = snapshot.commitEpoch else {
                        throw BuilderRunError.persistedStateInvalid(
                            "pending aggregate acceptance has no transaction source or epoch")
                    }
                    refreshed = try await finalizeAcceptedAggregate(
                        aggregate, source: aggregateSource, commitEpoch: commitEpoch,
                        workers: pending.workers, expected: pending.verification,
                        runtimes: governedRuntimes, snapshot: &snapshot)
                } else {
                    refreshed = try await trustedFinalVerification(
                        workers: pending.workers, snapshot: &snapshot)
                }
                try validateTrustedTelemetry(snapshot)
                guard refreshed.scope == .final, refreshed.deterministic, refreshed.passed,
                      refreshed.checks.allSatisfy(\.passed),
                      refreshed.verificationSubject == pending.verification.verificationSubject,
                      refreshed.subjectDigest == pending.verification.subjectDigest else {
                    throw BuilderRunError.finalVerificationFailed(
                        "finalized workspace does not match the pending acceptance digest")
                }
                let receipt = BuilderFinalReceipt(
                    contractID: pending.contractID, route: pending.route,
                    workers: pending.workers, verification: refreshed,
                    review: pending.review, accepted: true, completedAt: pending.completedAt)
                snapshot.finalReceipt = receipt
                snapshot.pendingFinalReceipt = nil
                snapshot.finalizationPending = false
                try await persistAcceptedFinalReceipt(
                    receipt, aggregate: aggregate, aggregateSource: aggregateSource,
                    runtimes: governedRuntimes, snapshot: &snapshot)
            } catch {
                let original = error
                if snapshot.finalReceipt?.accepted != true {
                    let failures = await rollbackPendingGlobalAcceptance(
                        aggregate: aggregate, aggregateSource: aggregateSource,
                        runtimes: governedRuntimes, snapshot: &snapshot,
                        reason: "pending finalization failed: \(original.localizedDescription)")
                    if !failures.isEmpty {
                        throw BuilderRunError.finalVerificationFailed(
                            "pending finalization failed and rollback was not proven: \(failures.joined(separator: "; "))")
                    }
                    try await persist(&snapshot)
                }
                throw original
            }
        }
        if let completed = snapshot.finalReceipt, completed.accepted {
            let producers = try canonicalProducerIdentities(contract: contract, workers: completed.workers)
            guard let storedReviewer = canonicalIdentity(completed.review.reviewerIdentity ?? ""),
                  let storedProducers = canonicalIdentitySet(completed.review.workerIdentities ?? []),
                  storedProducers == producers, !producers.contains(storedReviewer) else {
                throw BuilderRunError.reviewerNotIndependent(
                    "persisted completion receipt has missing, unknown, self-reviewing, or mismatched provenance")
            }
            if let aggregate {
                guard let aggregateSource else {
                    throw BuilderRunError.persistedStateInvalid(
                        "completed aggregate run has no transaction source")
                }
                _ = try await aggregateSource.verifyAggregateFinalized(aggregate)
            } else if governedRuntimes.isEmpty && (contract.effectiveCompletionMode == .verificationOnly
                || completed.verification.subjectDigest != nil) {
                let refreshed = try await trustedFinalVerification(
                    workers: completed.workers, snapshot: &snapshot)
                guard refreshed.scope == .final, refreshed.deterministic, refreshed.passed,
                      refreshed.checks.allSatisfy(\.passed),
                      refreshed.verificationSubject == completed.verification.verificationSubject,
                      refreshed.subjectDigest == completed.verification.subjectDigest else {
                    throw BuilderRunError.finalVerificationFailed(
                        "persisted verification is stale for the current governed workspace digest")
                }
            }
            await releaseAcceptedRetainedData(
                aggregate: aggregate, aggregateSource: aggregateSource,
                runtimes: governedRuntimes, snapshot: snapshot)
            return completed
        }
        while !graph.nodes.allSatisfy({ snapshot.nodeStates[$0.id]?.phase == .accepted }) {
            blockDescendants(in: &snapshot)
            let ready = graph.nodes.filter { node in
                guard snapshot.nodeStates[node.id]?.phase == .pending else { return false }
                return node.dependencies.allSatisfy { snapshot.nodeStates[$0]?.phase == .accepted }
            }
            if ready.isEmpty {
                let failures = snapshot.nodeStates.compactMapValues { state -> String? in
                    state.phase == .failed ? (state.failureReason ?? "failed") : nil
                }
                if !failures.isEmpty {
                    try await persist(&snapshot)
                    throw BuilderRunError.executionFailed(failures)
                }
                let unfinished = snapshot.nodeStates.filter { $0.value.phase != .accepted }.map(\.key).sorted()
                try await persist(&snapshot)
                throw BuilderRunError.stalled(unfinished)
            }
            let batch = selectBatch(from: ready)
        for node in batch {
                snapshot.nodeStates[node.id]!.attempts += 1
            }
var executionGovernanceByNode: [String: BuilderExecutionGovernanceRuntime] = [:]
var readOnlyGuardsByNode: [String: BuilderReadOnlyExecutionGuard] = [:]
var acceptedDependenciesByNode: [String: [BuilderAcceptedDependencyResult]] = [:]
var governancePreparationFailures: [String: String] = [:]
for node in batch {
    let attempt = snapshot.nodeStates[node.id]!.attempts
    do {
        acceptedDependenciesByNode[node.id] = try node.dependencies.sorted().map { dependencyID in
            guard let dependency = snapshot.nodeStates[dependencyID],
                  dependency.phase == .accepted,
                  let worker = dependency.worker,
                  let verification = dependency.verification else {
                throw BuilderRunError.persistedStateInvalid(
                    "dependency \(dependencyID) is not durably accepted")
            }
            return try BuilderAcceptedDependencyResult(
                nodeID: dependencyID, worker: worker, verification: verification,
                parentContractFingerprint: parentContractFingerprint(contract),
                graphFingerprint: builderGraphFingerprint(graph),
                consumerNodeID: node.id, consumerAttempt: attempt,
                acceptedCheckpointSequence: snapshot.sequence)
        }
        if let runtime = try await dynamicGovernance(
                for: node, attempt: attempt, snapshot: &snapshot) {
                if let aggregate {
                    aggregateSource = try await registerAggregateRuntime(
                        runtime, node: node, attempt: attempt,
                        descriptor: aggregate, current: aggregateSource)
                }
                executionGovernanceByNode[node.id] = runtime
                governedRuntimes[node.id] = runtime
            }
                    if let guardValue = try await readOnlyGuard(for: node, attempt: attempt) {
                        readOnlyGuardsByNode[node.id] = guardValue
                    }
                    snapshot.nodeStates[node.id]!.phase = .running
                } catch {
                    governancePreparationFailures[node.id] = String(reflecting: error)
                    snapshot.nodeStates[node.id]!.phase = .failed
                    snapshot.nodeStates[node.id]!.failureReason = error.localizedDescription
                }
            }
            try await persist(&snapshot)
            let outcomes = await withTaskGroup(of: BuilderAttemptOutcome.self) { group in
                for node in batch {
                    let attempt = snapshot.nodeStates[node.id]!.attempts
                    group.addTask { [contract, route, leases, execute, verify, graphExecutionPolicy,
                                     executionGovernanceByNode, readOnlyGuardsByNode,
                                     governancePreparationFailures] in
                        if let reason = governancePreparationFailures[node.id] {
                            return .terminal(node.id, stableFingerprint(reason), reason)
                        }
                        do {
                            let lease = try await leases.acquire(owner: "\(contract.id):\(node.id)", claims: node.resources)
                            do {
if let nodeGovernance = executionGovernanceByNode[node.id] {
    let acceptedDependencies = acceptedDependenciesByNode[node.id] ?? []
    let result = await nodeGovernance.execute(
        builderContract: contract, route: route,
        node: node, attempt: attempt,
        acceptedDependencies: acceptedDependencies,
        execute: execute, verify: verify)
                                    await leases.release(lease)
                                    switch result {
                                    case .accepted(let worker, let proof, let promotion, let telemetry):
                                        return .accepted(node.id, worker, proof, promotion, telemetry)
                                    case .retryable(let fingerprint, let reason):
                                        return .rejected(node.id, fingerprint, reason)
                                    case .terminal(let fingerprint, let reason):
                                        return .terminal(node.id, fingerprint, reason)
                                    }
                                }
let executionRequest = BuilderExecutionRequest(
    contract: contract, route: route, node: node, attempt: attempt,
    acceptedDependencies: acceptedDependenciesByNode[node.id] ?? [])
                                let worker: BuilderWorkerReceipt
                                if let readOnlyGuard = readOnlyGuardsByNode[node.id] {
                                    worker = try await readOnlyGuard.execute {
                                        try await execute(executionRequest)
                                    }
                                } else {
                                    worker = try await execute(executionRequest)
                                }
                                guard worker.nodeID == node.id else {
                                    throw BuilderRunError.persistedStateInvalid("worker receipt has wrong node ID")
                                }
                                if graphExecutionPolicy?.executionClass(for: node.id) == .readOnly,
                                   !worker.changedPaths.isEmpty {
                                    throw BuilderRunError.persistedStateInvalid(
                                        "explicit read-only node reported changed paths")
                                }
                                let proof = try await verify(.node(
                                    contract: contract, node: node, worker: worker,
                                    executionWorkspace: nil))
                                await leases.release(lease)
                                guard proof.scope == .node(node.id) else {
                                    return .rejected(node.id, stableFingerprint("wrong verification scope"), "wrong verification scope")
                                }
                                guard proof.deterministic, proof.passed, proof.checks.allSatisfy(\.passed) else {
                                    let reason = proof.checks.filter { !$0.passed }.map(\.details).joined(separator: "; ")
                                    let basis = proof.failureFingerprint ?? reason.nonEmpty ?? "node verification rejected"
                                    return .rejected(node.id, stableFingerprint(basis), basis)
                                }
                                return .accepted(node.id, worker, proof, nil, [])
                            } catch {
                                await leases.release(lease)
                                throw error
                            }
                        } catch {
                            let reason = String(reflecting: error)
                            return .rejected(node.id, stableFingerprint(reason), reason)
                        }
                    }
                }
                var values: [BuilderAttemptOutcome] = []
                for await value in group { values.append(value) }
                return values
            }
            for outcome in outcomes {
                switch outcome {
                case .accepted(let id, let worker, let proof, let promotion, let telemetry):
                    snapshot.nodeStates[id]!.phase = .accepted
                    snapshot.nodeStates[id]!.worker = worker
                    snapshot.nodeStates[id]!.verification = proof
                    snapshot.nodeStates[id]!.promotion = promotion
                    snapshot.nodeStates[id]!.trustedTelemetry = telemetry
                    snapshot.trustedTelemetry.append(contentsOf: telemetry)
                    snapshot.nodeStates[id]!.failureReason = nil
                case .rejected(let id, let fingerprint, let reason):
                    var state = snapshot.nodeStates[id]!
                    state.identicalFailureCount = state.lastFailureFingerprint == fingerprint
                        ? state.identicalFailureCount + 1 : 1
                    state.lastFailureFingerprint = fingerprint
                    state.failureReason = reason
                    let node = graph.nodes.first { $0.id == id }!
                    let exhausted = state.attempts >= node.retryLimit + 1
                    state.phase = exhausted || state.identicalFailureCount >= identicalFailureLimit ? .failed : .pending
                    snapshot.nodeStates[id] = state
                case .terminal(let id, let fingerprint, let reason):
                    snapshot.nodeStates[id]!.phase = .failed
                    snapshot.nodeStates[id]!.lastFailureFingerprint = fingerprint
                    snapshot.nodeStates[id]!.failureReason = reason
                }
            }
            let usage = snapshot.nodeStates.values.compactMap(\.worker?.usage)
            let unmeteredStages = usage.flatMap { $0.unmeteredStages ?? [] }
            let hasCompleteAggregate = usage.allSatisfy { $0.aggregateTokens != nil }
            snapshot.usage = BuilderUsageReceipt(
                inputTokens: usage.reduce(0) { $0 + $1.inputTokens },
                outputTokens: usage.reduce(0) { $0 + $1.outputTokens },
                wallTimeSeconds: usage.reduce(0) { $0 + $1.wallTimeSeconds },
                aggregateTokens: hasCompleteAggregate
                    ? usage.reduce(0) { $0 + ($1.aggregateTokens ?? 0) }
                    : nil,
                unmeteredStages: unmeteredStages.isEmpty ? nil : unmeteredStages.sorted()
            )
            try await persist(&snapshot)
        }
        let workers = try graph.nodes.map { node -> BuilderWorkerReceipt in
            guard let worker = snapshot.nodeStates[node.id]?.worker else {
                throw BuilderRunError.persistedStateInvalid("accepted node \(node.id) has no worker receipt")
            }
            return worker
        }
        let acceptedAttempts = Dictionary(uniqueKeysWithValues:
            snapshot.nodeStates.compactMap { nodeID, state in
                state.phase == .accepted ? (nodeID, state.attempts) : nil
            })
        let selectedContracts = snapshot.selectedExecutionContracts ?? [:]
        let selectedContractFingerprints = selectedContracts.mapValues(\.contractFingerprint)
        let acceptedVerificationSubjectDigests: [String: String] = Dictionary(
            uniqueKeysWithValues: snapshot.nodeStates.compactMap {
                nodeID, state -> (String, String)? in
                guard state.phase == .accepted,
                      let subjectDigest = state.verification?.subjectDigest else { return nil }
                return (nodeID, subjectDigest)
            })
        let trustedPromotions = try snapshot.nodeStates.compactMap {
            nodeID, state -> BuilderTransactionPromotionReceipt? in
            guard let promotion = state.promotion else { return nil }
            guard state.phase == .accepted,
                  state.attempts == promotion.attempt,
                  promotion.nodeID == nodeID,
                  promotion.hasValidReceiptDigest else {
                throw BuilderRunError.persistedStateInvalid(
                    "promotion receipt is stale, forged, or not bound to its accepted attempt")
            }
            if let selected = selectedContracts[nodeID] {
                guard selected.attempt == state.attempts,
                      selected.contractFingerprint == promotion.contractFingerprint else {
                    throw BuilderRunError.persistedStateInvalid(
                        "promotion receipt is not bound to the current selected execution contract")
                }
            }
            return promotion
        }
        let mutationObserved = trustedPromotions.contains { !$0.operations.isEmpty }
        switch contract.effectiveCompletionMode {
        case .build:
            guard mutationObserved else {
                throw BuilderRunError.finalVerificationFailed(
                    "build/change contract produced no governed workspace mutation")
            }
        case .verificationOnly:
            guard !mutationObserved else {
                throw BuilderRunError.finalVerificationFailed(
                    "verification-only contract forbids governed workspace mutations")
            }
        }
        try admitGraphGovernance(snapshot: &snapshot)
        try await persist(&snapshot)
        let finalProof: BuilderVerifierReceipt
        do {
            if let aggregate {
                guard let aggregateSource else {
                    throw BuilderRunError.invalidConfiguration(
                        "aggregate transaction source was not registered")
                }
                _ = try await aggregateSource.assertAggregateReady(aggregate)
            }
            finalProof = try await trustedFinalVerification(
                workers: workers, snapshot: &snapshot)
            guard finalProof.scope == .final, finalProof.deterministic,
                  finalProof.passed, finalProof.checks.allSatisfy(\.passed) else {
                let reason = finalProof.checks.filter { !$0.passed }
                    .map(\.details).joined(separator: "; ")
                throw BuilderRunError.finalVerificationFailed(
                    reason.nonEmpty ?? "deterministic verifier rejected")
            }
        } catch {
            if let aggregate, let aggregateSource {
                try? await aggregateSource.rollbackAggregate(
                    aggregate, reason: "final verification failed: \(error.localizedDescription)")
                for nodeID in governedRuntimes.keys.sorted() {
                    guard let runtime = governedRuntimes[nodeID],
                          let node = graph.nodes.first(where: { $0.id == nodeID }),
                          let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
                    try? await runtime.rollbackCommitted(
                        node: node, attempt: attempt,
                        reason: "final verification failed: \(error.localizedDescription)")
                }
            }
            throw error
        }
        if contract.effectiveCompletionMode == .verificationOnly {
            guard let subject = finalProof.verificationSubject?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !subject.isEmpty,
                  let digest = finalProof.subjectDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !digest.isEmpty, !digest.hasPrefix("unavailable:") else {
                throw BuilderRunError.finalVerificationFailed(
                    "verification-only completion requires a concrete governed subject and digest")
            }
        }
        do {
            for nodeID in governedRuntimes.keys.sorted() {
                guard let runtime = governedRuntimes[nodeID] else { continue }
                try await runtime.ensureReviewProviderCapacity()
            }
        } catch {
            let reason = "review budget admission failed before invocation: \(error.localizedDescription)"
            let rollbackFailures = await rollbackGovernedReviewAttempt(
                runtimes: governedRuntimes, snapshot: &snapshot, reason: reason)
            try await persist(&snapshot)
            if !rollbackFailures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "\(reason); rollback was not proven: \(rollbackFailures.joined(separator: "; "))")
            }
            throw BuilderRunError.reviewRejected([reason])
        }
        let reviewTelemetryBinding = try BuilderTrustedTelemetryBinding(
            contractFingerprint: parentContractFingerprint(contract),
            nodeID: graph.nodes.first?.id ?? "final-review",
            attempt: max(1, snapshot.nodeStates.values.map(\.attempts).max() ?? 1),
            stage: .review)
        let capturedReview = await BuilderTrustedTelemetry.captureScope(
            binding: reviewTelemetryBinding, registerBudgetAuthority: false) {
            try await self.review(.init(
                contract: self.contract, route: self.route, workers: workers,
                verification: finalProof,
                promotionReceipts: trustedPromotions,
                acceptedAttempts: acceptedAttempts,
                selectedContractFingerprints: selectedContractFingerprints,
                acceptedVerificationSubjectDigests:
                    acceptedVerificationSubjectDigests))
        }
        let rawReviewTelemetry = capturedReview.1
        snapshot.trustedTelemetry.append(contentsOf: rawReviewTelemetry)
        try await persist(&snapshot)
        var governedReviewTelemetry: [String: [BuilderTrustedTelemetryObservation]] = [:]
        do {
            for nodeID in governedRuntimes.keys.sorted() {
                guard let runtime = governedRuntimes[nodeID],
                      let governedNode = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else {
                    throw BuilderRunError.persistedStateInvalid(
                        "governed review runtime is not bound to a graph node")
                }
                let telemetry = try BuilderTrustedTelemetry.rebound(
                    rawReviewTelemetry,
                    to: BuilderTrustedTelemetryBinding(
                        contractFingerprint: runtime.contract.fingerprint(),
                        nodeID: governedNode.id, attempt: attempt, stage: .review))
                try await runtime.recordReviewTelemetry(telemetry)
                governedReviewTelemetry[nodeID] = telemetry
            }
        } catch {
            let reason = "review budget accounting failed: \(error.localizedDescription)"
            let rollbackFailures = await rollbackGovernedReviewAttempt(
                runtimes: governedRuntimes, snapshot: &snapshot, reason: reason)
            try await persist(&snapshot)
            if !rollbackFailures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "\(reason); rollback was not proven: \(rollbackFailures.joined(separator: "; "))")
            }
            throw BuilderRunError.reviewRejected([reason])
        }
        let submittedReview: BuilderReviewReceipt
        do {
            submittedReview = try capturedReview.0.get()
        } catch {
            let reason = "independent review failed: \(error.localizedDescription)"
            let rollbackFailures = await rollbackGovernedReviewAttempt(
                runtimes: governedRuntimes, snapshot: &snapshot, reason: reason)
            try await persist(&snapshot)
            if !rollbackFailures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "\(reason); rollback was not proven: \(rollbackFailures.joined(separator: "; "))")
            }
            throw error
        }
        let reviewerIdentity = identity(submittedReview.provider, submittedReview.model)
        let rejectedDiagnostics = submittedReview.findings
            + (submittedReview.votes ?? []).filter(\.failed).map {
                "\($0.lens): \($0.reason)"
            }
        guard !reviewerIdentity.isEmpty else {
            if !submittedReview.accepted, !rejectedDiagnostics.isEmpty {
                throw BuilderRunError.reviewRejected(Array(Set(rejectedDiagnostics)).sorted())
            }
            throw BuilderRunError.reviewerNotIndependent("no distinct configured reviewer was available")
        }
        guard rawReviewTelemetry.hasAuthenticatedReviewerRoute(
            providerID: submittedReview.provider, modelID: submittedReview.model) else {
            if !submittedReview.accepted, !rejectedDiagnostics.isEmpty {
                // A host-side evidence gate can reject before any reviewer invocation. Preserve
                // that concrete fail-closed diagnosis instead of masking it with a secondary
                // missing-route error for a provider that was intentionally never called.
                throw BuilderRunError.reviewRejected(
                    Array(Set(rejectedDiagnostics)).sorted())
            }
            throw BuilderRunError.reviewRejected(
                ["reviewer identity has no trusted provider-route observation"])
        }
        if let votes = submittedReview.votes {
            let completed = votes.filter { !$0.failed }
            let routes = completed.compactMap { vote -> String? in
                guard let provider = vote.provider?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let model = vote.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !provider.isEmpty, !model.isEmpty else { return nil }
                return identity(provider, model)
            }
            if !routes.isEmpty {
                guard routes.count == completed.count,
                      Set(routes).count == 1,
                      routes[0] == reviewerIdentity,
                      completed.allSatisfy({ vote in
                          rawReviewTelemetry.hasAuthenticatedReviewerRoute(
                              providerID: vote.provider ?? "", modelID: vote.model ?? "")
                      }) else {
                    throw BuilderRunError.reviewRejected(
                        ["review votes do not share the authenticated reviewer route"])
                }
            }
        }
        let builderIdentities = try canonicalProducerIdentities(contract: contract, workers: workers)
        guard !builderIdentities.contains(reviewerIdentity) else {
            throw BuilderRunError.reviewerNotIndependent(reviewerIdentity)
        }
        let reviewReceipt = BuilderReviewReceipt(
            provider: submittedReview.provider,
            model: submittedReview.model,
            accepted: submittedReview.accepted,
            checks: submittedReview.checks,
            findings: submittedReview.findings,
            usage: submittedReview.usage,
            workerIdentities: builderIdentities.sorted(),
            reviewerIdentity: reviewerIdentity,
            evidencePacketDigest: submittedReview.evidencePacketDigest,
            votes: submittedReview.votes
        )
        if contract.producerIdentities != nil,
           reviewReceipt.evidencePacketDigest?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw BuilderRunError.reviewRejected(["outer review supplied no evidence-packet digest"])
        }
        snapshot.reviewAttempt = BuilderReviewAttemptReceipt(
            reviewerIdentity: reviewerIdentity, producerIdentities: builderIdentities.sorted(),
            evidencePacketDigest: reviewReceipt.evidencePacketDigest ?? "legacy-unbound",
            votes: reviewReceipt.votes ?? [],
            accepted: reviewReceipt.accepted && reviewReceipt.checks.allSatisfy(\.passed),
            attemptedAt: Date(),
            missionInstanceID: contract.checkpointIdentity.flatMap { value in
                value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
                    ? value : nil
            })
        try await persist(&snapshot)
        guard reviewReceipt.accepted, reviewReceipt.checks.allSatisfy(\.passed) else {
            var rollbackFailures: [String] = []
            for nodeID in governedRuntimes.keys.sorted() {
                guard let runtime = governedRuntimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
                do {
                    try await runtime.rollbackCommitted(
                        node: node, attempt: attempt, reason: "independent review rejected")
                    snapshot.nodeStates[nodeID]?.phase = .failed
                    snapshot.nodeStates[nodeID]?.failureReason = "independent review rejected"
                } catch {
                    rollbackFailures.append("\(nodeID): \(error.localizedDescription)")
                }
            }
            try await persist(&snapshot)
            if !rollbackFailures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "review rejected and rollback was not proven: \(rollbackFailures.joined(separator: "; "))")
            }
            throw BuilderRunError.reviewRejected(reviewReceipt.findings)
        }
        var acceptedProof = finalProof
        do {
            if finalProof.subjectDigest != nil || contract.effectiveCompletionMode == .verificationOnly {
                let refreshed = try await trustedFinalVerification(
                    workers: workers, snapshot: &snapshot)
                guard refreshed.scope == .final, refreshed.deterministic, refreshed.passed,
                      refreshed.checks.allSatisfy(\.passed) else {
                    let reason = refreshed.checks.filter { !$0.passed }.map(\.details).joined(separator: "; ")
                    throw BuilderRunError.finalVerificationFailed(
                        reason.nonEmpty ?? "post-review deterministic verifier rejected")
                }
                guard refreshed.verificationSubject == finalProof.verificationSubject,
                      refreshed.subjectDigest == finalProof.subjectDigest else {
                    throw BuilderRunError.finalVerificationFailed(
                        "governed workspace digest changed during independent review")
                }
                acceptedProof = refreshed
            }
        } catch {
            let verificationError = error
            var rollbackFailures: [String] = []
            for nodeID in governedRuntimes.keys.sorted() {
                guard let runtime = governedRuntimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
                do {
                    try await runtime.rollbackCommitted(
                        node: node, attempt: attempt,
                        reason: "post-review verification failed: \(verificationError.localizedDescription)")
                    snapshot.nodeStates[nodeID]?.phase = .failed
                    snapshot.nodeStates[nodeID]?.failureReason = verificationError.localizedDescription
                } catch {
                    rollbackFailures.append("\(nodeID): \(error.localizedDescription)")
                }
            }
            try await persist(&snapshot)
            if !rollbackFailures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "post-review verification failed and rollback was not proven: \(rollbackFailures.joined(separator: "; "))")
            }
            throw verificationError
        }
        if !governedRuntimes.isEmpty {
            do {
                for nodeID in governedRuntimes.keys.sorted() {
                    guard let runtime = governedRuntimes[nodeID],
                          let governedNode = graph.nodes.first(where: { $0.id == nodeID }),
                          let attempt = snapshot.nodeStates[nodeID]?.attempts else {
                        throw BuilderRunError.persistedStateInvalid(
                            "governed review runtime is not bound to a graph node")
                    }
                    try await runtime.verifyReview(
                        node: governedNode, attempt: attempt, workers: workers,
                        proof: acceptedProof, review: reviewReceipt,
                        trustedTelemetry: governedReviewTelemetry[nodeID] ?? [])
                }
            } catch {
                let reviewError = error
                var rollbackFailures: [String] = []
                for nodeID in governedRuntimes.keys.sorted() {
                    guard let runtime = governedRuntimes[nodeID],
                          let governedNode = graph.nodes.first(where: { $0.id == nodeID }),
                          let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
                    do {
                        try await runtime.rollbackCommitted(
                            node: governedNode, attempt: attempt,
                            reason: "contract review verification failed: \(reviewError.localizedDescription)")
                        snapshot.nodeStates[nodeID]?.phase = .failed
                        snapshot.nodeStates[nodeID]?.failureReason = reviewError.localizedDescription
                    } catch {
                        rollbackFailures.append("\(nodeID): \(error.localizedDescription)")
                    }
                }
                try await persist(&snapshot)
                if !rollbackFailures.isEmpty {
                    throw BuilderRunError.finalVerificationFailed(
                        "contract review failed and rollback was not proven: \(rollbackFailures.joined(separator: "; "))")
                }
                throw BuilderRunError.reviewRejected([reviewError.localizedDescription])
            }
        }
        try validateTrustedTelemetry(snapshot)
        let commitEpoch = BuilderEvidenceDigest.sha256(
            "\(contract.id):\(try parentContractFingerprint(contract)):\(Date().timeIntervalSince1970):\(UUID().uuidString)")
        let pendingFinal = BuilderFinalReceipt(
            contractID: contract.id, route: route, workers: workers,
            verification: acceptedProof, review: reviewReceipt, accepted: true,
            completedAt: Date())
        snapshot.reviewAccepted = true
        snapshot.commitEpoch = commitEpoch
        snapshot.finalizationPending = !governedRuntimes.isEmpty
        snapshot.pendingFinalReceipt = pendingFinal
        // This is the single durable run-level commit decision. No transaction may discard
        // rollback material until the accepted pending receipt and epoch are persisted.
        try await persist(&snapshot)
        if let aggregate {
            guard let aggregateSource else {
                throw BuilderRunError.invalidConfiguration(
                    "accepted aggregate run has no transaction source")
            }
            do {
                let finalizedProof = try await finalizeAcceptedAggregate(
                    aggregate, source: aggregateSource, commitEpoch: commitEpoch,
                    workers: workers, expected: acceptedProof,
                    runtimes: governedRuntimes, snapshot: &snapshot)
                let publishedFinal = BuilderFinalReceipt(
                    contractID: pendingFinal.contractID, route: pendingFinal.route,
                    workers: pendingFinal.workers, verification: finalizedProof,
                    review: pendingFinal.review, accepted: true,
                    completedAt: pendingFinal.completedAt)
                snapshot.finalizationPending = false
                snapshot.pendingFinalReceipt = nil
                snapshot.finalReceipt = publishedFinal
                try await persistAcceptedFinalReceipt(
                    publishedFinal, aggregate: aggregate, aggregateSource: aggregateSource,
                    runtimes: governedRuntimes, snapshot: &snapshot)
                return publishedFinal
            } catch {
                let original = error
                if snapshot.finalReceipt?.accepted != true {
                    let failures = await rollbackPendingGlobalAcceptance(
                        aggregate: aggregate, aggregateSource: aggregateSource,
                        runtimes: governedRuntimes, snapshot: &snapshot,
                        reason: "aggregate finalization failed: \(original.localizedDescription)")
                    if !failures.isEmpty {
                        throw BuilderRunError.finalVerificationFailed(
                            "aggregate finalization failed and rollback was not proven: \(failures.joined(separator: "; "))")
                    }
                    try await persist(&snapshot)
                }
                throw original
            }
        }
        do {
            for nodeID in governedRuntimes.keys.sorted() {
                guard let runtime = governedRuntimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else {
                    throw BuilderRunError.persistedStateInvalid(
                        "governed finalization runtime is not bound to a graph node")
                }
                try await runtime.markReviewApproved(node: node, attempt: attempt)
            }
            for nodeID in governedRuntimes.keys.sorted() {
                guard let runtime = governedRuntimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else {
                    throw BuilderRunError.persistedStateInvalid(
                        "governed finalization runtime is not bound to a graph node")
                }
                try await runtime.finalize(node: node, attempt: attempt)
            }
            let finalizedProof = try await trustedFinalVerification(
                workers: workers, snapshot: &snapshot)
            try validateTrustedTelemetry(snapshot)
            guard finalizedProof.scope == .final, finalizedProof.deterministic,
                  finalizedProof.passed, finalizedProof.checks.allSatisfy(\.passed),
                  finalizedProof.verificationSubject == acceptedProof.verificationSubject,
                  finalizedProof.subjectDigest == acceptedProof.subjectDigest else {
                throw BuilderRunError.finalVerificationFailed(
                    "finalized workspace changed after the pending acceptance decision")
            }
            let publishedFinal = BuilderFinalReceipt(
                contractID: pendingFinal.contractID, route: pendingFinal.route,
                workers: pendingFinal.workers, verification: finalizedProof,
                review: pendingFinal.review, accepted: true,
                completedAt: pendingFinal.completedAt)
            snapshot.finalizationPending = false
            snapshot.pendingFinalReceipt = nil
            snapshot.finalReceipt = publishedFinal
            try await persistAcceptedFinalReceipt(
                publishedFinal, aggregate: nil, aggregateSource: nil,
                runtimes: governedRuntimes, snapshot: &snapshot)
            return publishedFinal
        } catch {
            let original = error
            if snapshot.finalReceipt?.accepted != true {
                let failures = await rollbackPendingGlobalAcceptance(
                    aggregate: nil, aggregateSource: nil,
                    runtimes: governedRuntimes, snapshot: &snapshot,
                    reason: "post-promotion final verification failed: \(original.localizedDescription)")
                if !failures.isEmpty {
                    throw BuilderRunError.finalVerificationFailed(
                        "post-promotion final verification failed and rollback was not proven: \(failures.joined(separator: "; "))")
                }
                try await persist(&snapshot)
            }
            throw original
        }
    }

    private func finalizeAcceptedAggregate(
        _ descriptor: BuilderAggregateTransactionDescriptor,
        source: BuilderIsolatedWorkspaceTransactionSource,
        commitEpoch: String,
        workers: [BuilderWorkerReceipt],
        expected: BuilderVerifierReceipt,
        runtimes: [String: BuilderExecutionGovernanceRuntime],
        snapshot: inout BuilderRunSnapshot
    ) async throws -> BuilderVerifierReceipt {
        do {
            try await source.markAggregateReviewApproved(
                descriptor, commitEpoch: commitEpoch)
            for nodeID in runtimes.keys.sorted() {
                guard let runtime = runtimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else {
                    throw BuilderRunError.persistedStateInvalid(
                        "aggregate review runtime is not bound to a graph node")
                }
                try await runtime.markReviewApproved(node: node, attempt: attempt)
            }
            _ = try await source.finalizeAggregate(descriptor)
            let proof = try await trustedFinalVerification(
                workers: workers, snapshot: &snapshot)
            try validateTrustedTelemetry(snapshot)
            guard proof.scope == .final, proof.deterministic, proof.passed,
                  proof.checks.allSatisfy(\.passed),
                  proof.verificationSubject == expected.verificationSubject,
                  proof.subjectDigest == expected.subjectDigest else {
                throw BuilderRunError.finalVerificationFailed(
                    "globally promoted aggregate differs from the reviewed staged subject")
            }
            try await source.completeAggregate(descriptor)
            for nodeID in runtimes.keys.sorted() {
                guard let runtime = runtimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
                try await runtime.finalize(node: node, attempt: attempt)
            }
            return proof
        } catch {
            let original = error
            var failures: [String] = []
            do {
                try await source.rollbackAggregate(
                    descriptor, reason: original.localizedDescription)
            } catch {
                failures.append(error.localizedDescription)
            }
            for nodeID in runtimes.keys.sorted() {
                guard let runtime = runtimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
                do {
                    try await runtime.rollbackCommitted(
                        node: node, attempt: attempt,
                        reason: original.localizedDescription)
                } catch {
                    failures.append("\(nodeID): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "aggregate failure could not prove rollback: \(failures.joined(separator: "; "))")
            }
            throw original
        }
    }
    private func trustedFinalVerification(
        workers: [BuilderWorkerReceipt], snapshot: inout BuilderRunSnapshot
    ) async throws -> BuilderVerifierReceipt {
        let binding = try BuilderTrustedTelemetryBinding(
            contractFingerprint: parentContractFingerprint(contract),
            nodeID: "final-verification", attempt: 1, stage: .verification)
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: binding, registerBudgetAuthority: false) {
            try await self.verify(.final(
                contract: self.contract, route: self.route, workers: workers))
        }
        let telemetry = captured.1
        snapshot.trustedTelemetry.append(contentsOf: telemetry)
        try await persist(&snapshot)
        let proof = try captured.0.get()
        guard proof.scope == .final, proof.deterministic else {
            throw BuilderRunError.finalVerificationFailed(
                "final verifier did not return a deterministic final-scope proof")
        }
        // A negative deterministic proof is already safe to consume: the caller will
        // reject it and surface the failed check. Success evidence is required only
        // before a proof can authorize review or acceptance.
        if !proof.passed || !proof.checks.allSatisfy(\.passed) {
            return proof
        }
        if let fleet = proof.fleetVerification {
            try validateFleetFinalVerification(
                fleet, proof: proof, telemetry: telemetry, snapshot: snapshot)
            let obligations = proof.requiredSupportingObligations ?? []
            if !obligations.isEmpty {
                guard let receipts = proof.supportingCommandReceipts,
                      receipts.count >= obligations.count,
                      proof.planFinalVerificationReceipt != nil else {
                    throw BuilderRunError.finalVerificationFailed(
                        "supporting/final command receipts are incomplete")
                }
            }
            return proof
        }
        let hostDeterministic = builderIsHostDeterministicVerifier(
            provider: proof.provider, model: proof.model)
        let routeObserved = hostDeterministic
            ? telemetry.contains { $0.kind == .command && $0.success }
            : telemetry.hasSuccessfulProviderRoute(
                providerID: proof.provider, modelID: proof.model)
        guard routeObserved else {
            throw BuilderRunError.finalVerificationFailed(
                "final verifier identity has no trusted route observation")
        }
        guard let subject = proof.subjectDigest,
              subject.count == 64, !subject.hasPrefix("unavailable:"),
              let fingerprint = proof.contractFingerprint,
              fingerprint.count == 64 else {
            throw BuilderRunError.finalVerificationFailed(
                "final verifier supplied no canonical bound subject/contract digest")
        }
        let commands = telemetry.filter { $0.kind == .command }
        let evidence = proof.commandEvidence ?? []
        guard !commands.isEmpty,
              BuilderTrustedTelemetry.commandEvidenceMatches(
                evidence, observations: telemetry,
                contractFingerprint: fingerprint, subjectDigest: subject,
                requireBuilderOSSandbox: hostDeterministic) else {
            throw BuilderRunError.finalVerificationFailed(
                "final command evidence is missing, unbound, or not observed by the trusted launcher")
        }
        let obligations = proof.requiredSupportingObligations ?? []
        if !obligations.isEmpty {
            guard let receipts = proof.supportingCommandReceipts,
                  receipts.count >= obligations.count,
                  proof.planFinalVerificationReceipt != nil else {
                throw BuilderRunError.finalVerificationFailed(
                    "supporting/final command receipts are incomplete")
            }
        }
        return proof
    }

    private func validateFleetFinalVerification(
        _ fleet: BuilderFleetVerificationBundle,
        proof: BuilderVerifierReceipt,
        telemetry: [BuilderTrustedTelemetryObservation],
        snapshot: BuilderRunSnapshot
    ) throws {
        guard let policy = graphExecutionPolicy,
              let selections = snapshot.selectedExecutionContracts else {
            throw BuilderRunError.finalVerificationFailed(
                "fleet final proof has no selected partition contracts")
        }
        let mutationNodes = graph.nodes.filter {
            policy.executionClass(for: $0.id) == .mutation
        }.sorted { $0.id < $1.id }
        guard !mutationNodes.isEmpty,
              mutationNodes.allSatisfy({ $0.id.hasPrefix("fleet-") }),
              Set(selections.keys) == Set(mutationNodes.map(\.id)) else {
            throw BuilderRunError.finalVerificationFailed(
                "fleet selected contract set is incomplete or not partition-bound")
        }
        let parent = try parentContractFingerprint(contract)
        let graphDigest = BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(graph), as: UTF8.self))
        guard snapshot.parentContractFingerprint == parent,
              snapshot.graphFingerprint == graphDigest,
              fleet.parentContractFingerprint == parent,
              fleet.graphFingerprint == graphDigest,
              proof.contractFingerprint == parent,
              proof.verificationSubject == fleet.verificationSubject,
              proof.subjectDigest == fleet.subjectDigest,
              proof.commandEvidence?.isEmpty == false,
              let verifiedAt = proof.verifiedAt,
              verifiedAt >= (fleet.children.map(\.verifiedAt).max() ?? verifiedAt) else {
            throw BuilderRunError.finalVerificationFailed(
                "fleet aggregate proof is not bound to the parent contract and graph")
        }
        let verifierIdentity: BuilderModelIdentity
        do {
            verifierIdentity = try BuilderModelIdentity(
                providerID: proof.provider, modelID: proof.model)
        } catch {
            throw BuilderRunError.finalVerificationFailed(
                "fleet aggregate verifier identity is invalid")
        }
        let expected = try mutationNodes.map { node -> BuilderFleetChildVerificationExpectation in
            guard let selection = selections[node.id] else {
                throw BuilderFleetVerificationError.invalid(
                    "selected contract is missing for \(node.id)")
            }
            let graphPaths = node.resources.filter { $0.access == .write }.map(\.path).sorted()
            let mutationPaths = selection.sealedContract.contract.mutations.map(\.path).sorted()
            guard graphPaths == mutationPaths else {
                throw BuilderFleetVerificationError.invalid(
                    "graph claims and selected mutations differ for \(node.id)")
            }
            return try BuilderFleetChildVerificationExpectation(
                nodeID: node.id, attempt: selection.attempt,
                partitionPaths: graphPaths,
                contractFingerprint: selection.contractFingerprint)
        }
        do {
            guard let subject = proof.subjectDigest,
                  let verificationSubject = proof.verificationSubject,
                  let aggregateEvidence = proof.commandEvidence,
                  !aggregateEvidence.isEmpty else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet aggregate command evidence is missing")
            }
            let aggregateReferences = aggregateEvidence.compactMap(\.trustedCommandReference)
            let childEvidence = fleet.children.flatMap(\.commandEvidence)
            let childReferences = childEvidence.compactMap(\.trustedCommandReference)
            guard aggregateReferences.count == aggregateEvidence.count,
                  childReferences.count == childEvidence.count,
                  Set(aggregateReferences.map(\.observationID)).count
                    == aggregateReferences.count,
                  Set(aggregateReferences.map(\.invocationID)).count
                    == aggregateReferences.count,
                  Set(childReferences.map(\.observationID)).count
                    == childReferences.count,
                  Set(childReferences.map(\.invocationID)).count
                    == childReferences.count else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet aggregate or child command evidence is duplicated")
            }
            let aggregateObservationIDs = Set(aggregateReferences.map(\.observationID))
            let childObservationIDs = Set(childReferences.map(\.observationID))
            let aggregateInvocationIDs = Set(aggregateReferences.map(\.invocationID))
            let childInvocationIDs = Set(childReferences.map(\.invocationID))
            guard aggregateObservationIDs.isDisjoint(with: childObservationIDs),
                  aggregateInvocationIDs.isDisjoint(with: childInvocationIDs) else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet aggregate command evidence reuses child telemetry")
            }
            let commandTelemetry = telemetry.filter { $0.kind == .command }
            guard Set(commandTelemetry.map(\.id))
                    == aggregateObservationIDs.union(childObservationIDs) else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet final command telemetry is missing or unclaimed")
            }
            let aggregateTelemetry = commandTelemetry.filter {
                aggregateObservationIDs.contains($0.id)
            }
            guard aggregateTelemetry.allSatisfy({
                      $0.contractFingerprint == parent
                          && $0.nodeID == "final-verification"
                          && $0.attempt == 1
                          && $0.stage == .verification
                  }),
                  BuilderTrustedTelemetry.commandEvidenceMatches(
                      aggregateEvidence, observations: aggregateTelemetry,
                      contractFingerprint: parent, subjectDigest: subject,
                      requireBuilderOSSandbox: true) else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet aggregate command evidence is not parent-bound trusted telemetry")
            }
            let rootIdentity = try BuilderWorkspaceRootIdentity.capture(
                rootPath: verificationSubject)
            let allEvidence = aggregateEvidence + childEvidence
            let commandTools = telemetry.filter {
                $0.kind == .tool && $0.name == "run_command"
            }
            let expectedArgumentCounts = Dictionary(
                grouping: allEvidence, by: \.argsFingerprint).mapValues(\.count)
            let observedArgumentCounts = Dictionary(
                grouping: commandTools, by: \.subjectDigest).mapValues(\.count)
            guard commandTools.count == allEvidence.count,
                  expectedArgumentCounts == observedArgumentCounts,
                  commandTools.allSatisfy({
                      $0.success && $0.workspaceRootIdentity == rootIdentity
                  }) else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet command tools are not completely bound to the aggregate workspace identity")
            }
            let childTelemetry = commandTelemetry.filter {
                !aggregateObservationIDs.contains($0.id)
            }
            try fleet.validate(
                expectedChildren: expected, verifierIdentity: verifierIdentity,
                observations: childTelemetry)
        } catch {
            throw BuilderRunError.finalVerificationFailed(error.localizedDescription)
        }
    }

    private func validateTrustedTelemetry(_ snapshot: BuilderRunSnapshot) throws {
        let ids = snapshot.trustedTelemetry.map(\.id)
        guard Set(ids).count == ids.count else {
            throw BuilderRunError.persistedStateInvalid(
                "trusted telemetry observation ID was omitted or reused")
        }
        for observation in snapshot.trustedTelemetry {
            try observation.validate(binding: .init(
                contractFingerprint: observation.contractFingerprint,
                nodeID: observation.nodeID, attempt: observation.attempt,
                stage: observation.stage))
        }
        for state in snapshot.nodeStates.values {
            guard let worker = state.worker else { continue }
            guard worker.trustedCLIInvocationsMatch(
                snapshot.trustedTelemetry, requireComplete: false) else {
                throw BuilderRunError.persistedStateInvalid(
                    "worker CLI route receipt is missing, forged, reused, or unmatched")
            }
        }
        if let maxTokens = contract.maxTokens {
            let total = snapshot.trustedTelemetry
                .filter { $0.kind == .provider }
                .reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
            guard total > 0, total <= maxTokens else {
                throw BuilderRunError.finalVerificationFailed(
                    "trusted token usage is omitted or exceeds BuilderContract.maxTokens (\(total)/\(maxTokens))")
            }
        }
    }

    private func validateGlobalDecisionState(_ snapshot: BuilderRunSnapshot) throws {
        let pending = snapshot.pendingFinalReceipt
        let final = snapshot.finalReceipt
        guard pending == nil || final == nil else {
            throw BuilderRunError.persistedStateInvalid(
                "pending and public final receipts cannot coexist")
        }
        if snapshot.reviewAccepted {
            guard let epoch = snapshot.commitEpoch,
                  epoch.count == 64,
                  epoch.allSatisfy({ "0123456789abcdef".contains($0) }),
                  pending?.accepted == true || final?.accepted == true else {
                throw BuilderRunError.persistedStateInvalid(
                    "accepted review lacks a sealed run-level decision")
            }
        } else {
            guard snapshot.commitEpoch == nil, pending == nil, final == nil,
                  !snapshot.finalizationPending else {
                throw BuilderRunError.persistedStateInvalid(
                    "receipt or commit epoch exists before global review acceptance")
            }
        }
        guard !snapshot.finalizationPending || pending?.accepted == true else {
            throw BuilderRunError.persistedStateInvalid(
                "finalization is pending without an accepted pending receipt")
        }
    }

    private func restoredSnapshot() async throws -> BuilderRunSnapshot {
        if resumeExisting {
            guard var loaded = try await store.load() else {
                throw BuilderRunError.persistedStateMismatch
            }
            let graphIDs = Set(graph.nodes.map(\.id))
            guard loaded.schemaVersion == 2,
                  loaded.contractID == contract.id, loaded.route == route,
                  loaded.checkpointIdentity == contract.checkpointIdentity,
                  loaded.parentContractFingerprint == (try parentContractFingerprint(contract)),
                  loaded.graphFingerprint == (try builderGraphFingerprint(graph)),
                  Set(loaded.nodeStates.keys) == graphIDs else {
                throw BuilderRunError.persistedStateMismatch
            }
            try validateGlobalDecisionState(loaded)
            for id in graphIDs {
                if loaded.nodeStates[id]?.phase == .accepted && loaded.nodeStates[id]?.worker == nil {
                    throw BuilderRunError.persistedStateInvalid("accepted node \(id) has no receipt")
                }
                if loaded.nodeStates[id]?.phase == .running || loaded.nodeStates[id]?.phase == .verifying {
                    loaded.nodeStates[id]?.phase = .pending
                }
            }
            loaded.checkpointIdentity = contract.checkpointIdentity ?? loaded.checkpointIdentity
            if loaded.finalReceipt?.accepted == true {
                guard loaded.reviewAccepted, loaded.commitEpoch?.count == 64,
                      loaded.pendingFinalReceipt == nil, !loaded.finalizationPending else {
                    throw BuilderRunError.persistedStateInvalid(
                        "accepted snapshot lacks a complete global commit decision")
                }
            }
            try await persist(&loaded)
            return loaded
        }
        var snapshot = BuilderRunSnapshot(
            contractID: contract.id,
            checkpointIdentity: contract.checkpointIdentity,
            route: route,
            nodeStates: Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, BuilderNodeState()) }),
            finalReceipt: nil,
            updatedAt: Date()
        )
        snapshot.parentContractFingerprint = try parentContractFingerprint(contract)
        snapshot.graphFingerprint = try builderGraphFingerprint(graph)
        try await store.create(snapshot)
        return snapshot
    }
    private func blockDescendants(in snapshot: inout BuilderRunSnapshot) {
        var changed = true
        while changed {
            changed = false
            for node in graph.nodes where snapshot.nodeStates[node.id]?.phase == .pending {
                let blocker = node.dependencies.first {
                    let phase = snapshot.nodeStates[$0]?.phase
                    return phase == .failed || phase == .blocked
                }
                if let blocker {
                    snapshot.nodeStates[node.id]?.phase = .blocked
                    snapshot.nodeStates[node.id]?.failureReason = "blocked by \(blocker)"
                    changed = true
                }
            }
        }
    }
    private func rollbackGovernedReviewAttempt(
        runtimes: [String: BuilderExecutionGovernanceRuntime],
        snapshot: inout BuilderRunSnapshot,
        reason: String
    ) async -> [String] {
        var failures: [String] = []
        for nodeID in runtimes.keys.sorted() {
            guard let runtime = runtimes[nodeID],
                  let node = graph.nodes.first(where: { $0.id == nodeID }),
                  let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
            do {
                try await runtime.rollbackCommitted(
                    node: node, attempt: attempt, reason: reason)
                snapshot.nodeStates[nodeID]?.phase = .failed
                snapshot.nodeStates[nodeID]?.failureReason = reason
            } catch {
                failures.append("\(nodeID): \(error.localizedDescription)")
            }
        }
        return failures
    }

    private func rollbackPendingGlobalAcceptance(
        aggregate: BuilderAggregateTransactionDescriptor?,
        aggregateSource: BuilderIsolatedWorkspaceTransactionSource?,
        runtimes: [String: BuilderExecutionGovernanceRuntime],
        snapshot: inout BuilderRunSnapshot,
        reason: String
    ) async -> [String] {
        var failures: [String] = []
        if let aggregate {
            guard let aggregateSource else {
                failures.append("aggregate transaction source is unavailable")
                return failures
            }
            do {
                try await aggregateSource.rollbackAggregate(aggregate, reason: reason)
            } catch {
                failures.append("aggregate: \(error.localizedDescription)")
            }
        }
        failures.append(contentsOf: await rollbackGovernedReviewAttempt(
            runtimes: runtimes, snapshot: &snapshot, reason: reason))
        if failures.isEmpty {
            snapshot.reviewAccepted = false
            snapshot.commitEpoch = nil
            snapshot.finalizationPending = false
            snapshot.pendingFinalReceipt = nil
            snapshot.finalReceipt = nil
        }
        return failures
    }

    private func persistAcceptedFinalReceipt(
        _ receipt: BuilderFinalReceipt,
        aggregate: BuilderAggregateTransactionDescriptor?,
        aggregateSource: BuilderIsolatedWorkspaceTransactionSource?,
        runtimes: [String: BuilderExecutionGovernanceRuntime],
        snapshot: inout BuilderRunSnapshot
    ) async throws {
        do {
            try await persist(&snapshot)
        } catch {
            let persistenceError = error
            if let durable = try? await store.load(),
               durable.finalReceipt == receipt,
               durable.pendingFinalReceipt == nil,
               durable.finalizationPending == false,
               durable.reviewAccepted == true {
                snapshot = durable
                await releaseAcceptedRetainedData(
                    aggregate: aggregate, aggregateSource: aggregateSource,
                    runtimes: runtimes, snapshot: snapshot)
                return
            }
            snapshot.finalReceipt = nil
            let reason = "accepted final receipt persistence was not proven: \(persistenceError.localizedDescription)"
            let failures = await rollbackPendingGlobalAcceptance(
                aggregate: aggregate, aggregateSource: aggregateSource,
                runtimes: runtimes, snapshot: &snapshot, reason: reason)
            if !failures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "\(reason); rollback was not proven: \(failures.joined(separator: "; "))")
            }
            do {
                try await persist(&snapshot)
            } catch {
                throw BuilderRunError.persistedStateInvalid(
                    "\(reason); rollback succeeded but its cleared acceptance state could not be persisted: \(error.localizedDescription)")
            }
            throw persistenceError
        }
        await releaseAcceptedRetainedData(
            aggregate: aggregate, aggregateSource: aggregateSource,
            runtimes: runtimes, snapshot: snapshot)
    }

    private func releaseAcceptedRetainedData(
        aggregate: BuilderAggregateTransactionDescriptor?,
        aggregateSource: BuilderIsolatedWorkspaceTransactionSource?,
        runtimes: [String: BuilderExecutionGovernanceRuntime],
        snapshot: BuilderRunSnapshot
    ) async {
        guard snapshot.finalReceipt?.accepted == true,
              snapshot.pendingFinalReceipt == nil,
              !snapshot.finalizationPending else { return }
        if let aggregate, let aggregateSource {
            try? await aggregateSource.releaseAggregate(aggregate)
        }
        for nodeID in runtimes.keys.sorted() {
            guard let runtime = runtimes[nodeID],
                  let node = graph.nodes.first(where: { $0.id == nodeID }),
                  let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
            try? await runtime.releaseRetainedData(node: node, attempt: attempt)
        }
    }
    private func selectBatch(from ready: [BuilderNode]) -> [BuilderNode] {
        var selected: [BuilderNode] = []
        for node in ready.sorted(by: { $0.id < $1.id }) {
            guard selected.count < maxParallelism else { break }
            let conflicts = selected.contains { other in
                node.resources.contains { left in
                    other.resources.contains { right in
                        pathsOverlap(left.path, right.path) && (left.access == .write || right.access == .write)
                    }
                }
            }
            if !conflicts { selected.append(node) }
        }
        return selected.isEmpty ? Array(ready.prefix(1)) : selected
    }
    private func persist(_ snapshot: inout BuilderRunSnapshot) async throws {
        snapshot.updatedAt = Date()
        snapshot.sequence += 1
        try await store.save(snapshot)
    }
}
private func identity(_ provider: String, _ model: String) -> String {
    let provider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return provider.isEmpty || model.isEmpty ? "" : "\(provider):\(model)"
}
private func canonicalIdentity(_ value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let separator = value.firstIndex(of: ":"), separator != value.startIndex else { return nil }
    let modelStart = value.index(after: separator)
    guard modelStart != value.endIndex else { return nil }
    let canonical = identity(String(value[..<separator]), String(value[modelStart...]))
    return canonical.isEmpty ? nil : canonical
}
private func canonicalIdentitySet(_ values: [String]) -> Set<String>? {
    let canonical = values.compactMap(canonicalIdentity)
    return canonical.count == values.count ? Set(canonical) : nil
}
private func canonicalProducerIdentities(
    contract: BuilderContract,
    workers: [BuilderWorkerReceipt]
) throws -> Set<String> {
    let workerIdentities = workers.map { identity($0.provider, $0.model) }
    guard !workerIdentities.contains("") else {
        throw BuilderRunError.persistedStateInvalid("builder provider:model identity is empty")
    }
    guard let declared = canonicalIdentitySet(contract.producerIdentities ?? []) else {
        throw BuilderRunError.persistedStateInvalid("declared producer provider:model identity is malformed")
    }
    return Set(workerIdentities).union(declared)
}
private func governedMutationObserved(_ worker: BuilderWorkerReceipt) -> Bool {
    if !worker.changedPaths.isEmpty { return true }
    let before = worker.artifacts.first { $0.kind == "governed-workspace-baseline" }?.digest
    let after = worker.artifacts.last { $0.kind == "governed-workspace-subject" }?.digest
    return before != nil && after != nil && before != after
}
private func pathsOverlap(_ left: String, _ right: String) -> Bool {
    let left = (left as NSString).standardizingPath
    let right = (right as NSString).standardizingPath
    if left == right || left == "." || right == "." || left == "/" || right == "/" { return true }
    return left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
}
private func stableFingerprint(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}
private func parentContractFingerprint(_ contract: BuilderContract) throws -> String {
    try BuilderContractFingerprint.canonical(contract)
}
private func builderGraphFingerprint(_ graph: BuilderGraph) throws -> String {
    BuilderEvidenceDigest.sha256(String(
        decoding: try BuilderDurableIO.canonicalData(graph), as: UTF8.self))
}
private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
