import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Builder fleet verification / receipts / stores / requests — value types extracted from BuilderRun.swift to keep the actor core under the size limit.

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
    /// Explicit review provenance. Older snapshots decode these as nil and remain independent-only.
    public let reviewGrade: EvolutionReviewGrade?
    public let independent: Bool?
    public let freshConversation: Bool?
    public let separateInvocation: Bool?
    public let producerInvocationIDs: [String]?
    public let reviewerInvocationIDs: [String]?
    public let reviewThreshold: Int?
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
        votes: [BuilderReviewVoteReceipt]? = nil,
        reviewGrade: EvolutionReviewGrade? = nil,
        independent: Bool? = nil,
        freshConversation: Bool? = nil,
        separateInvocation: Bool? = nil,
        producerInvocationIDs: [String]? = nil,
        reviewerInvocationIDs: [String]? = nil,
        reviewThreshold: Int? = nil
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
        self.reviewGrade = reviewGrade
        self.independent = independent
        self.freshConversation = freshConversation
        self.separateInvocation = separateInvocation
        self.producerInvocationIDs = producerInvocationIDs
        self.reviewerInvocationIDs = reviewerInvocationIDs
        self.reviewThreshold = reviewThreshold
    }
}
public struct BuilderReviewVoteReceipt: Codable, Sendable, Equatable {
    public let lens: String; public let accepted: Bool; public let reason: String; public let failed: Bool
    public let provider: String?
    public let model: String?
    public let invocationID: String?
    public let freshConversation: Bool?
    public init(lens: String, accepted: Bool, reason: String, failed: Bool,
                provider: String? = nil, model: String? = nil,
                invocationID: String? = nil, freshConversation: Bool? = nil) {
        self.lens = lens; self.accepted = accepted; self.reason = reason; self.failed = failed
        self.provider = provider; self.model = model
        self.invocationID = invocationID; self.freshConversation = freshConversation
    }
}
public struct BuilderReviewAttemptReceipt: Codable, Sendable, Equatable {
    public let reviewerIdentity: String; public let producerIdentities: [String]
    public let evidencePacketDigest: String; public let votes: [BuilderReviewVoteReceipt]
    public let accepted: Bool; public let attemptedAt: Date
    public let missionInstanceID: String?
    public let reviewGrade: EvolutionReviewGrade?
    public let independent: Bool?
    public let freshConversation: Bool?
    public let separateInvocation: Bool?
    public let producerInvocationIDs: [String]?
    public let reviewerInvocationIDs: [String]?
    public let reviewThreshold: Int?
    public init(reviewerIdentity: String, producerIdentities: [String],
                evidencePacketDigest: String, votes: [BuilderReviewVoteReceipt],
                accepted: Bool, attemptedAt: Date, missionInstanceID: String? = nil,
                reviewGrade: EvolutionReviewGrade? = nil, independent: Bool? = nil,
                freshConversation: Bool? = nil, separateInvocation: Bool? = nil,
                producerInvocationIDs: [String]? = nil,
                reviewerInvocationIDs: [String]? = nil,
                reviewThreshold: Int? = nil) {
        self.reviewerIdentity = reviewerIdentity; self.producerIdentities = producerIdentities
        self.evidencePacketDigest = evidencePacketDigest; self.votes = votes
        self.accepted = accepted; self.attemptedAt = attemptedAt
        self.missionInstanceID = missionInstanceID
        self.reviewGrade = reviewGrade; self.independent = independent
        self.freshConversation = freshConversation; self.separateInvocation = separateInvocation
        self.producerInvocationIDs = producerInvocationIDs
        self.reviewerInvocationIDs = reviewerInvocationIDs
        self.reviewThreshold = reviewThreshold
    }
}
public struct BuilderFinalAuthority: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let parentContractFingerprint: String
    public let graphFingerprint: String
    public let objectiveFingerprint: String
    public let commitEpoch: String
    public let trustedTelemetryDigest: String
    public let finalReceiptDigest: String
    public let seal: String

    init(parentContractFingerprint: String, graphFingerprint: String,
         objectiveFingerprint: String, commitEpoch: String,
         trustedTelemetryDigest: String,
         finalReceiptDigest: String) throws {
        self.schemaVersion = 1
        self.parentContractFingerprint = parentContractFingerprint
        self.graphFingerprint = graphFingerprint
        self.objectiveFingerprint = objectiveFingerprint
        self.commitEpoch = commitEpoch
        self.trustedTelemetryDigest = trustedTelemetryDigest
        self.finalReceiptDigest = finalReceiptDigest
        self.seal = ForgeSeal.sign(try Self.canonicalBinding(
            schemaVersion: 1,
            parentContractFingerprint: parentContractFingerprint,
            graphFingerprint: graphFingerprint,
            objectiveFingerprint: objectiveFingerprint,
            commitEpoch: commitEpoch,
            trustedTelemetryDigest: trustedTelemetryDigest,
            finalReceiptDigest: finalReceiptDigest))
        guard !seal.isEmpty else {
            throw BuilderRunError.persistedStateInvalid(
                "Builder final authority could not be sealed")
        }
    }

    func validates(finalReceiptDigest expectedFinalDigest: String) -> Bool {
        let digests = [parentContractFingerprint, graphFingerprint, objectiveFingerprint,
                       commitEpoch, trustedTelemetryDigest, finalReceiptDigest]
        guard schemaVersion == 1,
              finalReceiptDigest == expectedFinalDigest,
              digests.allSatisfy({ value in
                  value.utf8.count == 64 && value.utf8.allSatisfy {
                      (48...57).contains($0) || (97...102).contains($0)
                  }
              }),
              let canonical = try? Self.canonicalBinding(
                schemaVersion: schemaVersion,
                parentContractFingerprint: parentContractFingerprint,
                graphFingerprint: graphFingerprint,
                objectiveFingerprint: objectiveFingerprint,
                commitEpoch: commitEpoch,
                trustedTelemetryDigest: trustedTelemetryDigest,
                finalReceiptDigest: finalReceiptDigest) else { return false }
        return ForgeSeal.verify(canonical, seal: seal)
    }

    private static func canonicalBinding(
        schemaVersion: Int, parentContractFingerprint: String,
        graphFingerprint: String, objectiveFingerprint: String,
        commitEpoch: String,
        trustedTelemetryDigest: String, finalReceiptDigest: String
    ) throws -> String {
        struct Binding: Codable {
            let receiptType: String
            let schemaVersion: Int
            let parentContractFingerprint: String
            let graphFingerprint: String
            let objectiveFingerprint: String
            let commitEpoch: String
            let trustedTelemetryDigest: String
            let finalReceiptDigest: String
        }
        return String(decoding: try BuilderDurableIO.canonicalData(Binding(
            receiptType: "kist.builder-final-authority",
            schemaVersion: schemaVersion,
            parentContractFingerprint: parentContractFingerprint,
            graphFingerprint: graphFingerprint,
            objectiveFingerprint: objectiveFingerprint,
            commitEpoch: commitEpoch,
            trustedTelemetryDigest: trustedTelemetryDigest,
            finalReceiptDigest: finalReceiptDigest)), as: UTF8.self)
    }
}

public struct BuilderFinalReceipt: Codable, Sendable, Equatable {
    public let contractID: String; public let route: BuilderRoute; public let workers: [BuilderWorkerReceipt]; public let verification: BuilderVerifierReceipt; public let review: BuilderReviewReceipt; public let accepted: Bool; public let completedAt: Date
    public let authority: BuilderFinalAuthority?
    public init(
        contractID: String,
        route: BuilderRoute,
        workers: [BuilderWorkerReceipt],
        verification: BuilderVerifierReceipt,
        review: BuilderReviewReceipt,
        accepted: Bool,
        completedAt: Date,
        authority: BuilderFinalAuthority? = nil
    ) {
        self.contractID = contractID
        self.route = route
        self.workers = workers
        self.verification = verification
        self.review = review
        self.accepted = accepted
        self.completedAt = completedAt
        self.authority = authority
    }

    /// True only for a final published by BuilderRun under the current install's ForgeSeal key.
    /// Publicly constructed and legacy receipts intentionally return false.
    public var hasValidBuilderFinalAuthority: Bool {
        guard let authority,
              let digest = try? unsignedAuthorityPayloadDigest() else { return false }
        return authority.validates(finalReceiptDigest: digest)
    }

    func authorizing(
        parentContractFingerprint: String,
        graphFingerprint: String,
        objectiveFingerprint: String,
        commitEpoch: String,
        trustedTelemetry: [BuilderTrustedTelemetryObservation]
    ) throws -> Self {
        guard accepted, authority == nil else {
            throw BuilderRunError.persistedStateInvalid(
                "only an unsigned accepted Builder final can be authorized")
        }
        let telemetryDigest = BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(trustedTelemetry), as: UTF8.self))
        let finalDigest = try unsignedAuthorityPayloadDigest()
        let authority = try BuilderFinalAuthority(
            parentContractFingerprint: parentContractFingerprint,
            graphFingerprint: graphFingerprint,
            objectiveFingerprint: objectiveFingerprint,
            commitEpoch: commitEpoch,
            trustedTelemetryDigest: telemetryDigest,
            finalReceiptDigest: finalDigest)
        return Self(
            contractID: contractID, route: route, workers: workers,
            verification: verification, review: review, accepted: accepted,
            completedAt: completedAt, authority: authority)
    }

    private func unsignedAuthorityPayloadDigest() throws -> String {
        let unsigned = Self(
            contractID: contractID, route: route, workers: workers,
            verification: verification, review: review, accepted: accepted,
            completedAt: completedAt, authority: nil)
        return BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(unsigned), as: UTF8.self))
    }
}

/// Non-forgeable cross-module handoff for an accepted Builder final. Only BuilderRun can construct
/// this value; consumers can inspect and revalidate the exact sealed final plus its authenticated
/// telemetry binding, but cannot turn a public BuilderFinalReceipt initializer into authority.
public struct BuilderFinalAcceptanceAuthority: Sendable, Equatable {
    public let finalReceipt: BuilderFinalReceipt
    public let trustedTelemetry: [BuilderTrustedTelemetryObservation]
    public let parentContractFingerprint: String
    public let graphFingerprint: String
    public let objectiveFingerprint: String
    public let commitEpoch: String

    init(finalReceipt: BuilderFinalReceipt,
         trustedTelemetry: [BuilderTrustedTelemetryObservation],
         parentContractFingerprint: String,
         graphFingerprint: String,
         objectiveFingerprint: String,
         commitEpoch: String) throws {
        self.finalReceipt = finalReceipt
        self.trustedTelemetry = trustedTelemetry
        self.parentContractFingerprint = parentContractFingerprint
        self.graphFingerprint = graphFingerprint
        self.objectiveFingerprint = objectiveFingerprint
        self.commitEpoch = commitEpoch
        guard isValid else {
            throw BuilderRunError.persistedStateInvalid(
                "Builder final acceptance authority is invalid")
        }
    }

    public var isValid: Bool {
        guard finalReceipt.hasValidBuilderFinalAuthority,
              let authority = finalReceipt.authority,
              authority.parentContractFingerprint == parentContractFingerprint,
              authority.graphFingerprint == graphFingerprint,
              authority.objectiveFingerprint == objectiveFingerprint,
              authority.commitEpoch == commitEpoch,
              let data = try? BuilderDurableIO.canonicalData(trustedTelemetry) else { return false }
        let telemetryDigest = BuilderEvidenceDigest.sha256(String(decoding: data, as: UTF8.self))
        return authority.trustedTelemetryDigest == telemetryDigest
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

struct SealedBuilderRunSnapshot: Codable, Sendable, Equatable {
    let snapshot: BuilderRunSnapshot
    let seal: String
}

struct BuilderRunHighWaterRecord: Codable, Sendable, Equatable {
    let sequence: Int
    let snapshotDigest: String
    let previousDigest: String?
}

struct SealedBuilderRunHighWaterRecord: Codable, Sendable, Equatable {
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

struct DependencyBindingProjection: Codable {
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
/// Optional idempotent commit which publishes an already-durable accepted Builder receipt to an
/// external authority store. Builder invokes it before releasing retained rollback material.
public typealias BuilderFinalAcceptanceCommit = @Sendable (BuilderFinalAcceptanceAuthority) async throws -> Void
public enum BuilderRunError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case persistedStateMismatch
    case persistedStateInvalid(String)
    case executionFailed([String: String])
    case stalled([String])
    case finalVerificationFailed(String)
    case reviewRejected([String])
    case reviewerNotIndependent(String)
    case acceptancePersistencePending(String)
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
        case .acceptancePersistencePending(let value):
            return "Builder acceptance is durable but external persistence is pending: \(value)"
        }
    }
}
enum BuilderAttemptOutcome: Sendable {
    case accepted(String, BuilderWorkerReceipt, BuilderVerifierReceipt,
                  BuilderTransactionPromotionReceipt?,
                  [BuilderTrustedTelemetryObservation])
    case rejected(String, String, String)
    case terminal(String, String, String)
}
