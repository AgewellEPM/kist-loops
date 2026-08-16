import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Builder core value types (route, contract, graph, nodes, artifacts, command/worker receipts) — value types extracted from BuilderRun.swift to keep the actor core under the size limit.

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

