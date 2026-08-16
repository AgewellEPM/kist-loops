import Foundation
// Cross-platform crypto: swift-crypto's `Crypto` (CryptoKit-compatible, Linux-safe).
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum BuilderWorkspaceTransactionFaultPoint: String, Sendable, Equatable {
    case afterPrepared
    case beforePromotion
    case afterMutationIntent
    case afterMutationBeforeApplied
    case afterPromotedPath
    case afterCommitted
    case afterReviewApproved
    case afterFinalized
    case afterAggregatePrepared
    case afterAggregateMergeIntent
    case afterAggregateChildMerged
    case beforeAggregatePromotion
    case afterAggregatePromotedPath
}

public protocol BuilderWorkspaceTransactionFaultInjector: Sendable {
    func hit(_ point: BuilderWorkspaceTransactionFaultPoint) throws
}

enum BuilderWorkspaceTransactionPhase: String, Codable, Sendable, Equatable {
    case prepared, running, observed, verified, promoting, committed
    case reviewApproved, finalized, rollingBack, rolledBack, failed
}

enum BuilderWorkspaceMutationIntentPhase: String, Codable, Sendable, Equatable {
    case intent, applied
}

struct BuilderWorkspaceMutationIntent: Codable, Sendable, Equatable {
    let index: Int
    let operation: BuilderMutationOperation
    let temporaryLeaf: String
    let quarantineLeaf: String
    let preimage: BuilderWorkspaceManifestEntry?
    var phase: BuilderWorkspaceMutationIntentPhase
}

struct BuilderWorkspaceTransactionState: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let contractFingerprint: String
    let builderContractID: String
    let nodeID: String
    let attempt: Int
    var phase: BuilderWorkspaceTransactionPhase
    let baseline: BuilderWorkspaceManifest
    var subject: BuilderWorkspaceManifest?
    let challenge: String
    var attestation: BuilderSandboxAttestation?
    var promotionIndex: Int
    var createdDirectories: [String]
    var pendingIntent: BuilderWorkspaceMutationIntent?
    var failureReason: String?
    var promotionRecoveryPreimages: [BuilderWorkspaceManifestEntry]? = nil
    var aggregateID: String? = nil
    let workspaceRootIdentity: BuilderWorkspaceRootIdentity
    let baselineRootIdentity: BuilderWorkspaceRootIdentity
    var retainedDataReleaseStarted: Bool = false
    var workspaceReleased: Bool = false
    var baselineReleased: Bool = false
}

private struct SealedBuilderWorkspaceTransactionState: Codable, Sendable, Equatable {
    let state: BuilderWorkspaceTransactionState
    let seal: String
}

final class BuilderWorkspaceDirectoryLease: @unchecked Sendable {
    let identity: BuilderWorkspaceRootIdentity
    private let descriptor: Int32

    init(identity: BuilderWorkspaceRootIdentity) throws {
        let descriptor = open(
            identity.canonicalPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "concurrent governed-root drift: \(identity.canonicalPath)")
        }
        self.identity = identity
        self.descriptor = descriptor
        do {
            try validate()
        } catch {
            close(descriptor)
            throw error
        }
    }

    func validate() throws {
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              (descriptorStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              UInt64(descriptorStatus.st_dev) == identity.deviceID,
              UInt64(descriptorStatus.st_ino) == identity.inode,
              let current = try? BuilderWorkspaceRootIdentity.capture(
                rootPath: identity.canonicalPath),
              current == identity else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "concurrent governed-root drift: \(identity.canonicalPath)")
        }
    }

    deinit { close(descriptor) }
}

public actor BuilderIsolatedWorkspaceTransactionSource:
    BuilderAggregateTransactionalStageObservationSource {
    public nonisolated let projectRoot: URL
    public nonisolated let stagingBase: URL
    let attestor: (any BuilderSandboxAttestor)?
    let limits: BuilderWorkspaceTraversalLimits
    let faultInjector: (any BuilderWorkspaceTransactionFaultInjector)?
    public nonisolated let usesOSProcessSandbox: Bool
    private var rootLeases: [String: BuilderWorkspaceDirectoryLease] = [:]

    public init(projectRoot: URL, stagingBase: URL,
                attestor: (any BuilderSandboxAttestor)?,
                limits: BuilderWorkspaceTraversalLimits = try! .init(),
                faultInjector: (any BuilderWorkspaceTransactionFaultInjector)? = nil) throws {
        let projectCandidate = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        let projectIdentity = try BuilderWorkspaceRootIdentity.capture(
            rootPath: projectCandidate.path)
        let project = URL(
            fileURLWithPath: projectIdentity.canonicalPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BuilderWorkspaceTransactionError.invalidConfiguration(
                "governed project root does not exist")
        }
        try FileManager.default.createDirectory(
            at: stagingBase, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let stagingCandidate = stagingBase.resolvingSymlinksInPath().standardizedFileURL
        let stagingIdentity = try BuilderWorkspaceRootIdentity.capture(
            rootPath: stagingCandidate.path)
        let staging = URL(
            fileURLWithPath: stagingIdentity.canonicalPath, isDirectory: true)
        guard !Self.contains(staging.path, within: project.path) else {
            throw BuilderWorkspaceTransactionError.invalidConfiguration(
                "staging root must be outside the governed project")
        }
        guard chmod(staging.path, 0o700) == 0 else {
            throw BuilderWorkspaceTransactionError.invalidConfiguration(
                "cannot secure staging root")
        }
        self.projectRoot = project
        self.stagingBase = staging
        self.attestor = attestor
        self.usesOSProcessSandbox = attestor is BuilderOSProcessSandboxAttestor
        self.limits = limits
        self.faultInjector = faultInjector
    }

    public func prepare(_ context: BuilderStageContext) async throws -> BuilderStageBaseline {
        try validate(context)
        if var state = try load(context) {
            try validate(state, context: context)
            if let registration = try aggregateRegistration(for: context) {
                guard state.aggregateID == nil || state.aggregateID == registration.aggregateID else {
                    throw BuilderWorkspaceTransactionError.stateMismatch(
                        "child transaction changed aggregate binding")
                }
                if state.aggregateID == nil {
                    state.aggregateID = registration.aggregateID
                    try publish(state, context: context)
                }
            }
            if state.phase == .promoting {
                try restore(&state, context: context, reason: "resume interrupted promotion")
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "interrupted promotion was rolled back; a new attempt is required")
            }
            guard state.phase != .rolledBack, state.phase != .failed else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "transaction attempt is terminal")
            }
            if !state.workspaceReleased {
                _ = try executionTarget(context: context, state: state)
            }
            return try baseline(context: context, state: state)
        }
        guard context.stage == .build else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "verification/review cannot precede prepared build state")
        }
        let directory = transactionURL(context)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "stale transaction directory has no valid state")
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let workspace = workspaceURL(context)
        let manifest = try BuilderWorkspaceManifestScanner.scan(
            root: projectRoot, limits: limits, copyTo: workspace)
        let registration = try aggregateRegistration(for: context)
        if let registration {
            try validateRegisteredAggregateBaseline(
                registration: registration, manifest: manifest, context: context)
        }
        try FileManager.default.copyItem(at: workspace, to: baselineArchiveURL(context))
        let workspaceRootIdentity = try BuilderWorkspaceRootIdentity.capture(
            rootPath: workspace.path)
        let baselineRootIdentity = try BuilderWorkspaceRootIdentity.capture(
            rootPath: baselineArchiveURL(context).path)
        _ = try retainedRootLease(workspaceRootIdentity)
        _ = try retainedRootLease(baselineRootIdentity)
        try validateAuthorityAndPreimages(context.contract, baseline: manifest)
        let state = BuilderWorkspaceTransactionState(
            schemaVersion: 2,
            contractFingerprint: try context.contract.fingerprint(),
            builderContractID: context.contract.builderContractID,
            nodeID: context.node.id,
            attempt: context.attempt,
            phase: .prepared,
            baseline: manifest,
            subject: nil,
            challenge: UUID().uuidString,
            attestation: nil,
            promotionIndex: 0,
            createdDirectories: [],
            pendingIntent: nil,
            failureReason: nil,
            aggregateID: registration?.aggregateID,
            workspaceRootIdentity: workspaceRootIdentity,
            baselineRootIdentity: baselineRootIdentity)
        try publish(state, context: context)
        try faultInjector?.hit(.afterPrepared)
        return try baseline(context: context, state: state)
    }

    public func executionWorkspace(for context: BuilderStageContext) async throws
        -> BuilderExecutionWorkspace {
        guard [.build, .verification, .review].contains(context.stage) else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "execution workspace is unavailable for this stage")
        }
        guard var state = try load(context) else {
            throw BuilderWorkspaceTransactionError.stateMismatch("transaction is not prepared")
        }
        try validate(state, context: context)
        guard !state.workspaceReleased else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "finalized staged workspace has already been released")
        }
        let target = try executionTarget(context: context, state: state)
        let request = BuilderSandboxAttestationRequest(
            contractFingerprint: state.contractFingerprint,
            builderContractID: state.builderContractID,
            nodeID: state.nodeID,
            attempt: state.attempt,
            stagedRoot: target.identity.canonicalPath,
            governedRootDigest: BuilderEvidenceDigest.sha256(projectRoot.path),
            challenge: state.challenge,
            stage: context.stage)
        let receipt: BuilderSandboxAttestation
        if let existing = state.attestation,
           existing.stage == request.stage,
           existing.stagedRoot == request.stagedRoot {
            try existing.validate(request)
            if let osAttestor = attestor as? BuilderOSProcessSandboxAttestor {
                receipt = try await osAttestor.reattestIfNeeded(request, existing: existing)
                if receipt != existing {
                    state.attestation = receipt
                    try publish(state, context: context)
                }
            } else {
                receipt = existing
            }
        } else {
            guard let attestor else {
                throw BuilderWorkspaceTransactionError.attestationInvalid
            }
            receipt = try await attestor.attest(request)
            try receipt.validate(request)
            state.attestation = receipt
            if context.stage == .build, state.phase == .prepared {
                state.phase = .running
            }
            try publish(state, context: context)
        }
        return .init(rootPath: target.identity.canonicalPath,
                     rootIdentity: target.identity, attestation: receipt,
                     workspaceDigest: target.digest)
    }

    public func observe(_ request: BuilderStageObservationRequest) async throws
        -> BuilderStageObservation {
        let context = request.context
        try validate(context)
        let telemetryBinding = try BuilderTrustedTelemetryBinding(
            contractFingerprint: context.contract.fingerprint(), nodeID: context.node.id,
            attempt: context.attempt, stage: context.stage)
        for observation in request.trustedTelemetry {
            try observation.validate(binding: telemetryBinding)
        }
        guard var state = try load(context) else {
            throw BuilderWorkspaceTransactionError.stateMismatch("transaction is missing")
        }
        try validate(state, context: context)
        let observationTarget = try executionTarget(context: context, state: state)
        let current = try BuilderWorkspaceManifestScanner.scan(
            root: observationTarget.root, limits: limits)
        let operations: [BuilderObservedMutation]
        switch context.stage {
        case .build:
            guard state.phase == .running, state.attestation != nil else {
                throw BuilderWorkspaceTransactionError.attestationInvalid
            }
            let governedCurrent: BuilderWorkspaceManifest
            do {
                governedCurrent = try BuilderWorkspaceManifestScanner.scan(
                    root: projectRoot, limits: limits)
            } catch {
                throw BuilderWorkspaceTransactionError.undeclaredMutation(
                    "worker introduced a hard link or unsupported filesystem object")
            }
            guard governedCurrent == state.baseline else {
                throw BuilderWorkspaceTransactionError.undeclaredMutation(
                    "worker bypassed the staged transactional root")
            }
            operations = try validateSubject(
                contract: context.contract, baseline: state.baseline, subject: current)
            state.subject = current
            state.phase = .observed
            try publish(state, context: context)
        case .verification:
            if state.aggregateID != nil, state.phase == .committed {
                let aggregate = try aggregateStateReady(for: state.aggregateID!)
                guard aggregate.subject == current else {
                    throw BuilderWorkspaceTransactionError.undeclaredMutation(
                        "aggregate staged workspace changed during final verification")
                }
                operations = []
                break
            }
            guard let subject = state.subject,
                  state.phase == .observed || state.phase == .verified,
                  subject == current else {
                throw BuilderWorkspaceTransactionError.undeclaredMutation(
                    "staged workspace changed during verification")
            }
            operations = []
            state.phase = .verified
            try publish(state, context: context)
        case .review:
            if state.aggregateID != nil {
                let aggregate = try aggregateStateReady(for: state.aggregateID!)
                guard aggregate.subject == current else {
                    throw BuilderWorkspaceTransactionError.stateMismatch(
                        "review did not consume the accepted aggregate staged workspace")
                }
                operations = []
                break
            }
            guard let subject = state.subject,
                  [.committed, .reviewApproved, .finalized].contains(state.phase),
                  subject == current || state.phase == .finalized else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "review subject is not the verified staged manifest")
            }
            operations = []
        default:
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "transaction source does not implement \(context.stage.rawValue)")
        }
        return try BuilderStageObservation(
            contractFingerprint: state.contractFingerprint,
            builderContractID: state.builderContractID,
            nodeID: state.nodeID,
            attempt: state.attempt,
            stage: context.stage,
            workspaceDigestBefore: request.baseline.workspaceDigest,
            workspaceDigestAfter: try current.digest(),
            operations: operations,
            criteria: try criterionObservations(
                context: context, subject: request.subject,
                telemetry: request.trustedTelemetry, operations: operations),
            identities: try identityObservations(
                context: context, telemetry: request.trustedTelemetry),
            lineage: context.contract.lineage,
            baselineWarnings: request.baseline.warnings,
            currentWarnings: [],
            budgetObservations: try request.trustedTelemetry.compactMap {
                try $0.accountableBudgetObservation()
            })
    }

    public func commit(context: BuilderStageContext,
                       verifiedWorkspaceDigest: String) async throws {
        guard var state = try load(context), let subject = state.subject else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "verified transaction state is missing")
        }
        try validate(state, context: context)
        if state.aggregateID != nil {
            try mergeChildIntoAggregate(
                state: &state, context: context,
                verifiedWorkspaceDigest: verifiedWorkspaceDigest)
            return
        }
        if state.phase == .finalized {
            try verifyPromoted(state, context: context)
            return
        }
        if state.phase == .committed {
            try verifySealedPrepublication(state, context: context)
            return
        }
        if state.phase == .reviewApproved {
            if try promotionCompleted(state, context: context) { return }
            try verifySealedPrepublication(state, context: context)
            return
        }
        guard state.phase == .verified,
              try subject.digest() == verifiedWorkspaceDigest else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "commit digest is not the verified staged subject")
        }
        try verifySealedPrepublication(state, context: context)
        state.phase = .committed
        state.promotionIndex = 0
        state.createdDirectories = []
        state.pendingIntent = nil
        state.failureReason = nil
        state.promotionRecoveryPreimages = nil
        try publish(state, context: context)
    }

    public func promotionReceipt(context: BuilderStageContext) async throws
        -> BuilderTransactionPromotionReceipt {
        let state = try requireState(context)
        guard [.committed, .reviewApproved, .finalized].contains(state.phase),
              let subject = state.subject else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "promotion receipt requested before verified staging was committed")
        }
        if state.aggregateID == nil {
            if state.phase == .finalized {
                try verifyPromoted(state, context: context)
            } else if try promotionCompleted(state, context: context) {
                try verifyPromoted(state, context: context)
            } else {
                try verifySealedPrepublication(state, context: context)
            }
        }
        let operations = try validateSubject(
            contract: context.contract, baseline: state.baseline, subject: subject)
        return try .init(
            contractFingerprint: state.contractFingerprint,
            builderContractID: state.builderContractID,
            nodeID: state.nodeID, attempt: state.attempt,
            workspaceDigest: subject.digest(), operations: operations)
    }

    public func markReviewApproved(context: BuilderStageContext) async throws {
        guard var state = try load(context) else {
            throw BuilderWorkspaceTransactionError.stateMismatch("transaction is missing")
        }
        if let aggregateID = state.aggregateID {
            if state.phase == .reviewApproved || state.phase == .finalized { return }
            let aggregate = try aggregateState(for: aggregateID)
            try validateAggregateRetainedRoots(aggregate)
            guard [.reviewApproved, .committed, .finalized].contains(aggregate.phase),
                  state.phase == .committed else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "aggregate review approval requires the durable parent decision")
            }
            state.phase = .reviewApproved
            try publish(state, context: context)
            return
        }
        if state.phase == .finalized {
            try verifyPromoted(state, context: context)
            if !state.workspaceReleased { try validateRetainedRoots(state) }
            return
        }
        if state.phase == .reviewApproved {
            if try promotionCompleted(state, context: context) {
                try verifyPromoted(state, context: context)
            } else {
                try verifySealedPrepublication(state, context: context)
            }
            return
        }
        guard state.phase == .committed else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "review approval requires committed state")
        }
        try verifySealedPrepublication(state, context: context)
        state.phase = .reviewApproved
        try publish(state, context: context)
        try faultInjector?.hit(.afterReviewApproved)
    }

    public func finalize(context: BuilderStageContext) async throws {
        guard var state = try load(context) else {
            throw BuilderWorkspaceTransactionError.stateMismatch("transaction is missing")
        }
        if state.phase == .finalized {
            try verifyPromoted(state, context: context)
            if !state.workspaceReleased { try validateRetainedRoots(state) }
            return
        }
        if let aggregateID = state.aggregateID {
            let aggregate = try aggregateState(for: aggregateID)
            guard aggregate.phase == .finalized, state.phase == .reviewApproved else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "per-node finalize cannot publish an aggregate transaction")
            }
            try verifyAggregatePromoted(aggregate)
            state.phase = .finalized
            try publish(state, context: context)
            return
        }
        if state.phase == .promoting {
            try recoverInterruptedFinalizationPromotion(&state, context: context)
        }
        guard state.phase == .reviewApproved else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "finalize requires durable review approval")
        }
        if !(try promotionCompleted(state, context: context)) {
            try verifySealedPrepublication(state, context: context)
            try promote(&state, context: context)
        }
        try verifyPromoted(state, context: context)
        state.phase = .finalized
        try publish(state, context: context)
        try faultInjector?.hit(.afterFinalized)
    }

    public func releaseRetainedData(context: BuilderStageContext) async throws {
        guard var state = try load(context) else {
            throw BuilderWorkspaceTransactionError.stateMismatch("transaction is missing")
        }
        try validate(state, context: context)
        guard state.phase == .finalized else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "retained transaction data cannot be released before finalization")
        }
        if let aggregateID = state.aggregateID {
            let aggregate = try aggregateState(for: aggregateID)
            guard aggregate.phase == .finalized else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "aggregate retained data cannot be released before finalization")
            }
            try verifyAggregatePromoted(aggregate)
        } else {
            try verifyPromoted(state, context: context)
        }
        if state.workspaceReleased && state.baselineReleased { return }
        if !state.retainedDataReleaseStarted {
            state.retainedDataReleaseStarted = true
            try publish(state, context: context)
        }
        if !state.workspaceReleased {
            try releaseRetainedRoot(state.workspaceRootIdentity)
            state.workspaceReleased = true
            try publish(state, context: context)
        }
        if !state.baselineReleased {
            try releaseRetainedRoot(state.baselineRootIdentity)
            state.baselineReleased = true
            try publish(state, context: context)
        }
    }

    public func verifyFinalized(context: BuilderStageContext) async throws {
        guard let state = try load(context), state.phase == .finalized else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "transaction is not finalized")
        }
        if let aggregateID = state.aggregateID {
            let aggregate = try aggregateState(for: aggregateID)
            guard aggregate.phase == .finalized else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "aggregate transaction is not finalized")
            }
            try verifyAggregatePromoted(aggregate)
        } else {
            try verifyPromoted(state, context: context)
        }
    }

    public func rollback(_ request: BuilderRollbackRequest) async throws
        -> BuilderRollbackObservation {
        var state = try requireState(request.context)
        if let aggregateID = state.aggregateID {
            try rollbackAggregateID(aggregateID, reason: request.reason)
            state.phase = .rolledBack
            state.failureReason = request.reason
            try publish(state, context: request.context)
            return try rollbackObservation(state, context: request.context)
        }
        try restore(&state, context: request.context, reason: request.reason)
        return try rollbackObservation(state, context: request.context)
    }

    public func rollbackCommitted(context: BuilderStageContext, reason: String) async throws
        -> BuilderRollbackObservation {
        var state = try requireState(context)
        if let aggregateID = state.aggregateID {
            try rollbackAggregateID(aggregateID, reason: reason)
            state.phase = .rolledBack
            state.failureReason = reason
            try publish(state, context: context)
            return try rollbackObservation(state, context: context)
        }
        guard !state.retainedDataReleaseStarted else {
            throw BuilderWorkspaceTransactionError.rollbackUnproven(
                "retained rollback evidence was already released")
        }
        if [.committed, .reviewApproved].contains(state.phase),
           state.promotionIndex == 0, state.pendingIntent == nil {
            return try rollbackUnpublished(
                &state, context: context, reason: reason)
        }
        try restore(&state, context: context, reason: reason)
        return try rollbackObservation(state, context: context)
    }

    private func rollbackUnpublished(
        _ state: inout BuilderWorkspaceTransactionState,
        context: BuilderStageContext,
        reason: String
    ) throws -> BuilderRollbackObservation {
        state.phase = .rollingBack
        state.failureReason = reason
        try publish(state, context: context)
        let current = try BuilderWorkspaceManifestScanner.scan(
            root: projectRoot, limits: limits, mode: .restoration)
        state.phase = .rolledBack
        try publish(state, context: context)
        return try BuilderRollbackObservation(
            contractFingerprint: state.contractFingerprint,
            builderContractID: state.builderContractID,
            nodeID: state.nodeID,
            attempt: state.attempt,
            workspaceDigestAfter: current.digest(),
            restoredPathStates: try context.contract.mutations.map {
                try BuilderObservedPathState(
                    path: $0.path,
                    digest: current.entry($0.path)?.contentDigest)
            })
    }

    private func baseline(context: BuilderStageContext,
                          state: BuilderWorkspaceTransactionState) throws
        -> BuilderStageBaseline {
        let manifest: BuilderWorkspaceManifest
        let pathStates: [BuilderObservedPathState]
        if context.stage == .build {
            manifest = state.baseline
            pathStates = try context.contract.mutations.map {
                try BuilderObservedPathState(
                    path: $0.path,
                    digest: state.baseline.entry($0.path)?.contentDigest)
            }
        } else if state.aggregateID != nil, state.phase == .committed,
                  context.stage == .review {
            let aggregate = try aggregateStateReady(for: state.aggregateID!)
            guard let aggregateSubject = aggregate.subject else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "aggregate review subject is missing")
            }
            manifest = aggregateSubject
            pathStates = []
        } else {
            guard let subject = state.subject else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "verified subject manifest is missing")
            }
            manifest = subject
            pathStates = []
        }
        return try BuilderStageBaseline(
            contractFingerprint: state.contractFingerprint,
            builderContractID: state.builderContractID,
            nodeID: state.nodeID,
            attempt: state.attempt,
            stage: context.stage,
            workspaceDigest: manifest.digest(),
            pathStates: pathStates)
    }

    func validateAuthorityAndPreimages(
        _ contract: BuilderExecutionContract,
        baseline: BuilderWorkspaceManifest
    ) throws {
        for operation in contract.mutations {
            let path = try safeMutationPath(operation.path)
            let entry = baseline.entry(path)
            switch operation.kind {
            case .create:
                guard entry == nil else {
                    throw BuilderWorkspaceTransactionError.preimageMismatch(path)
                }
            case .modify, .delete:
                guard let entry, entry.type == .regular,
                      let required = operation.preimageSHA256,
                      entry.contentDigest == required else {
                    throw BuilderWorkspaceTransactionError.preimageMismatch(path)
                }
            }
        }
    }

    func validateSubject(
        contract: BuilderExecutionContract,
        baseline: BuilderWorkspaceManifest,
        subject: BuilderWorkspaceManifest
    ) throws -> [BuilderObservedMutation] {
        let operations = Dictionary(uniqueKeysWithValues: contract.mutations.map { ($0.path, $0) })
        let before = Dictionary(uniqueKeysWithValues: baseline.entries.map { ($0.path, $0) })
        let after = Dictionary(uniqueKeysWithValues: subject.entries.map { ($0.path, $0) })
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        if changed.isEmpty, !contract.mutations.isEmpty {
            throw BuilderWorkspaceTransactionError.noMutation(
                contract.mutations.map(\.path).sorted().joined(separator: ", "))
        }
        for path in changed {
            if operations[path] != nil { continue }
            if before[path] == nil, after[path]?.type == .directory,
               operations.keys.contains(where: { $0.hasPrefix(path + "/") }) { continue }
            throw BuilderWorkspaceTransactionError.undeclaredMutation(path)
        }
        return try contract.mutations.map { operation in
            let prior = before[operation.path]
            let next = after[operation.path]
            switch operation.kind {
            case .create:
                guard prior == nil, next?.type == .regular else {
                    throw BuilderWorkspaceTransactionError.operationMismatch(operation.path)
                }
            case .modify:
                guard prior?.type == .regular, next?.type == .regular, prior != next else {
                    throw BuilderWorkspaceTransactionError.operationMismatch(operation.path)
                }
            case .delete:
                guard prior?.type == .regular, next == nil else {
                    throw BuilderWorkspaceTransactionError.operationMismatch(operation.path)
                }
            }
            return try BuilderObservedMutation(
                kind: operation.kind,
                path: operation.path,
                preimageSHA256: prior?.contentDigest,
                postimageSHA256: next?.contentDigest)
        }
    }

    private func promote(_ state: inout BuilderWorkspaceTransactionState,
                         context: BuilderStageContext) throws {
        guard let subject = state.subject else {
            throw BuilderWorkspaceTransactionError.stateMismatch("subject is missing")
        }
        try validateRetainedRoots(state)
        let current = try BuilderWorkspaceManifestScanner.scan(root: projectRoot, limits: limits)
        for operation in context.contract.mutations {
            guard current.entry(operation.path) == state.baseline.entry(operation.path) else {
                throw BuilderWorkspaceTransactionError.preimageMismatch(operation.path)
            }
        }
        let real = try ConfinedRoot(root: projectRoot.path)
        state.phase = .promoting
        state.promotionIndex = 0
        try publish(state, context: context)
        try faultInjector?.hit(.beforePromotion)
        let staged = try ConfinedRoot(root: workspaceURL(context).path, readOnly: true)
        for (index, operation) in context.contract.mutations.enumerated() {
            let expectedEntry: BuilderWorkspaceManifestEntry?
            if let recovered = state.promotionRecoveryPreimages {
                expectedEntry = recovered.first(where: { $0.path == operation.path })
            } else {
                expectedEntry = state.baseline.entry(operation.path)
            }
            try recheckCurrent(operation, expected: expectedEntry, root: real)
            let token = UUID().uuidString.lowercased()
            let temporary = ".kist-builder-tmp-\(token)"
            let quarantine = ".kist-builder-quarantine-\(token)"
            state.pendingIntent = .init(
                index: index, operation: operation, temporaryLeaf: temporary,
                quarantineLeaf: quarantine,
                preimage: state.baseline.entry(operation.path), phase: .intent)
            try publish(state, context: context)
            try faultInjector?.hit(.afterMutationIntent)
            switch operation.kind {
            case .create, .modify:
                guard let next = subject.entry(operation.path), next.type == .regular else {
                    throw BuilderWorkspaceTransactionError.operationMismatch(operation.path)
                }
                state.createdDirectories.append(contentsOf: try ensureParents(
                    operation.path, root: real))
                let data = try staged.readStableData(
                    operation.path, maxBytes: limits.maxFileBytes)
                try real.transactionPublish(
                    operation.path, data: data, mode: next.mode,
                    expected: try transactionPreimage(expectedEntry),
                    kind: operation.kind, tempLeaf: temporary,
                    quarantineLeaf: quarantine)
            case .delete:
                let prior = try transactionPreimage(expectedEntry)
                try real.transactionPublish(
                    operation.path, data: nil, mode: prior?.mode ?? 0,
                    expected: prior, kind: .delete, tempLeaf: temporary,
                    quarantineLeaf: quarantine)
            }
            try faultInjector?.hit(.afterMutationBeforeApplied)
            state.promotionIndex = index + 1
            state.createdDirectories = Array(Set(state.createdDirectories)).sorted()
            state.pendingIntent?.phase = .applied
            try publish(state, context: context)
            try faultInjector?.hit(.afterPromotedPath)
            state.pendingIntent = nil
            try publish(state, context: context)
        }
        state.phase = .reviewApproved
        try publish(state, context: context)
        try faultInjector?.hit(.afterCommitted)
    }

    private func verifySealedPrepublication(
        _ state: BuilderWorkspaceTransactionState,
        context: BuilderStageContext
    ) throws {
        try validateRetainedRoots(state)
        guard let subject = state.subject else {
            throw BuilderWorkspaceTransactionError.stateMismatch("subject is missing")
        }
        let staged = try BuilderWorkspaceManifestScanner.scan(
            root: workspaceURL(context), limits: limits)
        guard staged == subject else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "verified staged subject drifted before publication")
        }
        let current = try BuilderWorkspaceManifestScanner.scan(root: projectRoot, limits: limits)
        for operation in context.contract.mutations {
            guard current.entry(operation.path) == state.baseline.entry(operation.path) else {
                throw BuilderWorkspaceTransactionError.preimageMismatch(operation.path)
            }
        }
    }

    private func promotionCompleted(
        _ state: BuilderWorkspaceTransactionState,
        context: BuilderStageContext
    ) throws -> Bool {
        guard state.promotionIndex == context.contract.mutations.count,
              state.pendingIntent == nil else { return false }
        do {
            try verifyPromoted(state, context: context)
            return true
        } catch {
            return false
        }
    }

    private func recoverInterruptedFinalizationPromotion(
        _ state: inout BuilderWorkspaceTransactionState,
        context: BuilderStageContext
    ) throws {
        if try promotionCompleted(state, context: context) {
            state.phase = .reviewApproved
            try publish(state, context: context)
            return
        }
        try restore(&state, context: context, reason: "resume interrupted finalization promotion")
        let restored = try BuilderWorkspaceManifestScanner.scan(
            root: projectRoot, limits: limits, mode: .restoration)
        state.phase = .reviewApproved
        state.failureReason = nil
        state.promotionIndex = 0
        state.createdDirectories = []
        state.pendingIntent = nil
        state.promotionRecoveryPreimages = context.contract.mutations.compactMap {
            restored.entry($0.path)
        }.sorted { $0.path < $1.path }
        try publish(state, context: context)
    }

    private func restore(_ state: inout BuilderWorkspaceTransactionState,
                         context: BuilderStageContext, reason: String) throws {
        guard !state.retainedDataReleaseStarted else {
            throw BuilderWorkspaceTransactionError.rollbackUnproven(
                "retained rollback evidence was already released")
        }
        try validateRetainedRoots(state)
        state.phase = .rollingBack
        state.failureReason = reason
        try publish(state, context: context)
        let restored = try restoreGovernedPaths(
            to: state.baseline,
            createdDirectories: state.createdDirectories,
            context: context)
        for operation in context.contract.mutations {
            guard restored.entry(operation.path) == state.baseline.entry(operation.path) else {
                throw BuilderWorkspaceTransactionError.rollbackUnproven(operation.path)
            }
        }
        state.phase = .rolledBack
        state.pendingIntent = nil
        try publish(state, context: context)
    }

    private func verifyPromoted(_ state: BuilderWorkspaceTransactionState,
                                context: BuilderStageContext) throws {
        guard let subject = state.subject else {
            throw BuilderWorkspaceTransactionError.stateMismatch("subject is missing")
        }
        for operation in context.contract.mutations {
            guard try currentRegularEntry(operation.path) == subject.entry(operation.path) else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "promoted path drifted: \(operation.path)")
            }
        }
    }

    private func recheckCurrent(_ operation: BuilderMutationOperation,
                                expected: BuilderWorkspaceManifestEntry?,
                                root: ConfinedRoot) throws {
        let current = try currentRegularEntry(operation.path)
        guard current == expected else {
            throw BuilderWorkspaceTransactionError.preimageMismatch(operation.path)
        }
        _ = root
    }

    func currentRegularEntry(_ path: String) throws -> BuilderWorkspaceManifestEntry? {
        let absolute = projectRoot.appendingPathComponent(path).path
        var info = stat()
        if lstat(absolute, &info) != 0 {
            if errno == ENOENT { return nil }
            throw BuilderWorkspaceTransactionError.stateMismatch("cannot lstat \(path)")
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw BuilderWorkspaceTransactionError.specialFile(path)
        }
        let data = try ConfinedRoot(root: projectRoot.path)
            .readStableData(path, maxBytes: limits.maxFileBytes)
        return .init(
            path: path,
            type: .regular,
            mode: UInt16(info.st_mode & 0o7777),
            byteCount: Int64(data.count),
            contentDigest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            linkTarget: nil, deviceID: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            linkCount: UInt64(info.st_nlink))
    }

    func ensureParents(_ path: String, root: ConfinedRoot) throws -> [String] {
        let components = path.split(separator: "/").dropLast().map(String.init)
        var current = ""
        var created: [String] = []
        for component in components {
            current = current.isEmpty ? component : "\(current)/\(component)"
            let type = try root.fileType(current)
            if type.exists {
                guard type.isDir else {
                    throw BuilderWorkspaceTransactionError.operationMismatch(current)
                }
            } else {
                try root.makeDirectory(current)
                created.append(current)
            }
        }
        return created
    }

    private func criterionObservations(context: BuilderStageContext,
                                       subject: BuilderStageObservationSubject,
                                       telemetry: [BuilderTrustedTelemetryObservation],
                                       operations: [BuilderObservedMutation]) throws
        -> [BuilderCriterionObservation] {
        try context.contract.criteria.filter { $0.stage == context.stage }.map { criterion in
            let passed: Bool
            switch (context.stage, criterion.kind, subject) {
            case (.build, .artifactDigest, _):
                passed = !operations.isEmpty
                    && operations.allSatisfy { $0.kind == .delete || $0.postimageSHA256 != nil }
            case (_, .lineageReceipt, _):
                let lineage = context.contract.lineage
                passed = lineage.captainDecisionDigest != nil || lineage.research != nil
                    || lineage.peelReceiptDigest != nil || lineage.councilArtifactDigest != nil
                    || lineage.taskBoard != nil
            case (_, .noNewWarnings, _):
                passed = !telemetry.isEmpty && telemetry.allSatisfy { $0.warningCount == 0 }
            case (.verification, .deterministicCommand, .verification(_, let proof)):
                let command = telemetry.filter { $0.kind == .command }
                let evidence = proof.commandEvidence ?? []
                passed = proof.deterministic && proof.passed && proof.checks.allSatisfy(\.passed)
                    && !command.isEmpty && command.allSatisfy { $0.success && $0.exitCode == 0 }
                    && BuilderTrustedTelemetry.commandEvidenceMatches(
                        evidence, observations: telemetry,
                        contractFingerprint: (try? context.contract.fingerprint()) ?? "",
                        subjectDigest: proof.subjectDigest ?? "")
            case (.review, .modelJudgment, .review(_, _, let review)):
                let routes = telemetry.filter { $0.kind == .provider && $0.success }
                passed = review.accepted && !routes.isEmpty
                    && routes.contains {
                        $0.providerID?.lowercased() == review.provider.lowercased()
                            && $0.modelID == review.model
                    }
                    && review.evidencePacketDigest?.count == 64
            default: passed = false
            }
            return try BuilderCriterionObservation(
                criterionID: criterion.id,
                passed: passed,
                evidenceDigest: BuilderEvidenceDigest.sha256(
                    "\(context.stage.rawValue):\(criterion.id):\(passed)"))
        }
    }

    private func identityObservations(context: BuilderStageContext,
                                      telemetry: [BuilderTrustedTelemetryObservation]) throws
        -> [BuilderIdentityObservation] {
        let role: BuilderObservedIdentityRole = context.stage == .build ? .producer : .reviewer
        return try telemetry.filter { $0.kind == .provider && $0.success }.map {
            .init(role: role, identity: try .init(
                providerID: $0.providerID ?? "", modelID: $0.modelID ?? ""))
        }
    }

    func rollbackObservation(_ state: BuilderWorkspaceTransactionState,
                                     context: BuilderStageContext) throws
        -> BuilderRollbackObservation {
        try BuilderRollbackObservation(
            contractFingerprint: state.contractFingerprint,
            builderContractID: state.builderContractID,
            nodeID: state.nodeID,
            attempt: state.attempt,
            workspaceDigestAfter: try BuilderWorkspaceManifestScanner.scan(
                root: projectRoot, limits: limits, mode: .restoration).digest(),
            restoredPathStates: try context.contract.mutations.map {
                try BuilderObservedPathState(
                    path: $0.path,
                    digest: state.baseline.entry($0.path)?.contentDigest)
            })
    }

    private func validate(_ context: BuilderStageContext) throws {
        guard context.contract.builderNodeID == context.node.id else {
            throw BuilderWorkspaceTransactionError.stateMismatch("node binding")
        }
        _ = try context.contract.fingerprint()
        for operation in context.contract.mutations { _ = try safeMutationPath(operation.path) }
    }

    private func validate(_ state: BuilderWorkspaceTransactionState,
                          context: BuilderStageContext) throws {
        guard state.schemaVersion == 2,
              state.contractFingerprint == (try context.contract.fingerprint()),
              state.builderContractID == context.contract.builderContractID,
              state.nodeID == context.node.id,
              state.attempt == context.attempt,
              state.workspaceRootIdentity.canonicalPath == workspaceURL(context).path,
              state.baselineRootIdentity.canonicalPath == baselineArchiveURL(context).path,
              (!state.workspaceReleased || state.retainedDataReleaseStarted),
              (!state.baselineReleased || state.retainedDataReleaseStarted) else {
            throw BuilderWorkspaceTransactionError.stateMismatch("contract/node/attempt binding")
        }
    }

    func safeMutationPath(_ value: String) throws -> String {
        let path = try BuilderExecutionValidation.path(value)
        guard !BuilderPathSecurity.containsControlComponent(path) else {
            throw BuilderWorkspaceTransactionError.controlPath(path)
        }
        return path
    }

    private func requireState(_ context: BuilderStageContext) throws
        -> BuilderWorkspaceTransactionState {
        guard let state = try load(context) else {
            throw BuilderWorkspaceTransactionError.stateMismatch("transaction is missing")
        }
        try validate(state, context: context)
        return state
    }

    func load(_ context: BuilderStageContext) throws
        -> BuilderWorkspaceTransactionState? {
        guard let data = try BuilderDurableIO.readSecure(stateURL(context)) else { return nil }
        let envelope = try JSONDecoder().decode(
            SealedBuilderWorkspaceTransactionState.self, from: data)
        guard try BuilderDurableIO.canonicalData(envelope) == data else {
            throw BuilderWorkspaceTransactionError.tampered
        }
        let canonical = String(decoding: try BuilderDurableIO.canonicalData(envelope.state),
                               as: UTF8.self)
        guard ForgeSeal.verify(canonical, seal: envelope.seal) else {
            throw BuilderWorkspaceTransactionError.tampered
        }
        return envelope.state
    }

    func publish(_ state: BuilderWorkspaceTransactionState,
                         context: BuilderStageContext) throws {
        let canonical = String(decoding: try BuilderDurableIO.canonicalData(state), as: UTF8.self)
        let seal = ForgeSeal.sign(canonical)
        guard !seal.isEmpty else { throw BuilderWorkspaceTransactionError.tampered }
        try BuilderDurableIO.writeAtomic(
            try BuilderDurableIO.canonicalData(
                SealedBuilderWorkspaceTransactionState(state: state, seal: seal)),
            to: stateURL(context))
    }

    func transactionURL(_ context: BuilderStageContext) -> URL {
        let key = BuilderEvidenceDigest.sha256(
            "\((try? context.contract.fingerprint()) ?? "invalid"):\(context.node.id):\(context.attempt)")
        return stagingBase.appendingPathComponent(key, isDirectory: true)
    }

    func workspaceURL(_ context: BuilderStageContext) -> URL {
        transactionURL(context).appendingPathComponent("workspace", isDirectory: true)
    }

    private func backupURL(_ context: BuilderStageContext) -> URL {
        baselineArchiveURL(context)
    }

    func baselineArchiveURL(_ context: BuilderStageContext) -> URL {
        transactionURL(context).appendingPathComponent("baseline", isDirectory: true)
    }

    private func stateURL(_ context: BuilderStageContext) -> URL {
        transactionURL(context).appendingPathComponent("transaction.json")
    }

    func retainedRootLease(
        _ identity: BuilderWorkspaceRootIdentity
    ) throws -> BuilderWorkspaceDirectoryLease {
        if let existing = rootLeases[identity.canonicalPath] {
            guard existing.identity == identity else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "concurrent governed-root drift: \(identity.canonicalPath)")
            }
            try existing.validate()
            return existing
        }
        let lease = try BuilderWorkspaceDirectoryLease(identity: identity)
        rootLeases[identity.canonicalPath] = lease
        return lease
    }

    func validateRetainedRoots(_ state: BuilderWorkspaceTransactionState) throws {
        guard !state.workspaceReleased, !state.baselineReleased else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "retained transaction data is incomplete")
        }
        _ = try retainedRootLease(state.workspaceRootIdentity)
        _ = try retainedRootLease(state.baselineRootIdentity)
    }

    func releaseRetainedRoot(_ identity: BuilderWorkspaceRootIdentity) throws {
        if !FileManager.default.fileExists(atPath: identity.canonicalPath) {
            rootLeases.removeValue(forKey: identity.canonicalPath)
            return
        }
        _ = try retainedRootLease(identity)
        try FileManager.default.removeItem(atPath: identity.canonicalPath)
        rootLeases.removeValue(forKey: identity.canonicalPath)
    }

    func transactionPreimage(_ entry: BuilderWorkspaceManifestEntry?) throws
        -> ConfinedRoot.TransactionPreimage? {
        guard let entry else { return nil }
        guard entry.type == .regular, let digest = entry.contentDigest,
              let data = Data(hexBuilderDigest: digest),
              let deviceID = entry.deviceID, let inode = entry.inode,
              let linkCount = entry.linkCount, linkCount == 1 else {
            throw BuilderWorkspaceTransactionError.preimageMismatch(entry.path)
        }
        return .init(deviceID: deviceID, inode: inode, linkCount: linkCount,
                     mode: entry.mode, sha256: data)
    }

    private func restoreGovernedPaths(
        to baseline: BuilderWorkspaceManifest,
        createdDirectories: [String],
        context: BuilderStageContext
    ) throws -> BuilderWorkspaceManifest {
        let current = try BuilderWorkspaceManifestScanner.scan(
            root: projectRoot, limits: limits, mode: .restoration)
        let real = try ConfinedRoot(root: projectRoot.path)
        let archive = try ConfinedRoot(root: baselineArchiveURL(context).path, readOnly: true)
        let actual = Dictionary(uniqueKeysWithValues: current.entries.map { ($0.path, $0) })

        for operation in context.contract.mutations {
            let expected = baseline.entry(operation.path)
            let found = actual[operation.path]
            let unsafeLink = found.map {
                ($0.type == .regular || $0.type == .symlink) && $0.linkCount != 1
            } ?? false
            if let found, expected == nil || found.type != expected?.type || unsafeLink {
                switch found.type {
                case .regular, .symlink, .special:
                    try real.removeFile(operation.path)
                case .directory:
                    try real.removeDirectory(operation.path)
                }
            }
            guard let expected else { continue }
            switch expected.type {
            case .regular:
                if found != expected || unsafeLink {
                    try real.writeData(
                        operation.path,
                        archive.readStableData(operation.path, maxBytes: limits.maxFileBytes),
                        createParents: true)
                }
                try real.setModeAndSync(operation.path, mode: expected.mode)
            case .symlink:
                guard let target = expected.linkTarget else {
                    throw BuilderWorkspaceTransactionError.rollbackUnproven(
                        "baseline symbolic link has no target at \(operation.path)")
                }
                if found != expected || unsafeLink {
                    try real.replaceSymlink(
                        operation.path, target: target, createParents: true)
                }
            case .directory:
                if found?.type != .directory { try real.makeDirectory(operation.path) }
                try real.setModeAndSync(operation.path, mode: expected.mode)
            case .special:
                throw BuilderWorkspaceTransactionError.rollbackUnproven(
                    "baseline unexpectedly contains a special file at \(operation.path)")
            }
        }

        for path in Set(createdDirectories).sorted(by: {
            $0.split(separator: "/").count > $1.split(separator: "/").count
        }) where baseline.entry(path) == nil {
            let afterMutationRestore = try BuilderWorkspaceManifestScanner.scan(
                root: projectRoot, limits: limits, mode: .restoration)
            guard afterMutationRestore.entry(path)?.type == .directory,
                  !afterMutationRestore.entries.contains(where: {
                      $0.path.hasPrefix(path + "/")
                  }) else { continue }
            try real.removeDirectory(path)
        }

        let restored = try BuilderWorkspaceManifestScanner.scan(
            root: projectRoot, limits: limits, mode: .restoration)
        for operation in context.contract.mutations where
            restored.entry(operation.path) != baseline.entry(operation.path) {
            throw BuilderWorkspaceTransactionError.rollbackUnproven(operation.path)
        }
        return restored
    }


    private static func contains(_ candidate: String, within root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

private extension Data {
    init?(hexBuilderDigest value: String) {
        guard value.count == 64 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        self.init(bytes)
    }
}
