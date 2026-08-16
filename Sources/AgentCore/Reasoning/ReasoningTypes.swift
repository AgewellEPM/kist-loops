import CryptoKit
import Foundation

private func durableWorkspaceSHA256(_ components: [String]) -> String {
    let canonical = components.map { value in
        "\(value.utf8.count):\(value)"
    }.joined(separator: "|")
    return SHA256.hash(data: Data(canonical.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}
import CryptoKit

/// The runtime lane selected before work begins. This is intentionally independent of
/// prompt wording so routing is an executable decision rather than an inferred label.
public enum ReasoningRoute: String, Codable, Sendable, Equatable, CaseIterable {
    case direct
    case planned
    case fleet
}

public enum ReasoningEvidenceKind: String, Codable, Sendable, Equatable {
    case artifact
    case check
    case externalState
    case research
    case delegation
    case feedback
    case decision
}

/// A durable reference to evidence. The evidence remains in its source system; the control
/// checkpoint stores only a bounded description and stable locator/digest.
public struct ReasoningEvidenceReference: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: ReasoningEvidenceKind
    public let nodeID: String?
    public let locator: String?
    public let digest: String?
    public let summary: String
    public let at: Double

    public init(id: String = UUID().uuidString, kind: ReasoningEvidenceKind,
                nodeID: String? = nil, locator: String? = nil, digest: String? = nil,
                summary: String, at: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.kind = kind
        self.nodeID = nodeID
        self.locator = locator
        self.digest = digest
        self.summary = String(summary.prefix(2_000))
        self.at = at
    }
}

public struct ReasoningArtifactReference: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    /// A content digest, version, or other source-issued monotonic identity.
    public let revision: String
    public let nodeID: String?

    public init(id: String, path: String, revision: String, nodeID: String? = nil) {
        self.id = id
        self.path = path
        self.revision = revision
        self.nodeID = nodeID
    }
}

public enum ReasoningCheckState: String, Codable, Sendable, Equatable {
    case unknown
    case failed
    case passed
    case blocked
}

public struct ReasoningCheckReceipt: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let state: ReasoningCheckState
    public let evidenceID: String?
    public let nodeID: String?

    public init(id: String, name: String, state: ReasoningCheckState,
                evidenceID: String? = nil, nodeID: String? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.evidenceID = evidenceID
        self.nodeID = nodeID
    }
}

public enum ReasoningRiskLevel: String, Codable, Sendable, Equatable, Comparable {
    case low
    case medium
    case high
    case critical

    public static func < (lhs: ReasoningRiskLevel, rhs: ReasoningRiskLevel) -> Bool {
        let order: [ReasoningRiskLevel] = [.low, .medium, .high, .critical]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

public struct ReasoningRiskReceipt: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let level: ReasoningRiskLevel
    public let summary: String
    public let mitigation: String?
    public let nodeID: String?

    public init(id: String = UUID().uuidString, level: ReasoningRiskLevel,
                summary: String, mitigation: String? = nil, nodeID: String? = nil) {
        self.id = id
        self.level = level
        self.summary = String(summary.prefix(1_000))
        self.mitigation = mitigation.map { String($0.prefix(1_000)) }
        self.nodeID = nodeID
    }
}

/// Provider-issued continuation material only (for example an encrypted response handle).
/// Callers must never put raw chain-of-thought in `reference`; use `reasoningSummary` for a
/// bounded, model-safe summary instead.
public struct OpaqueProviderReasoningHandle: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let providerID: String
    public let modelID: String
    public let kind: String
    public let reference: String
    public let expiresAt: Double?
    /// Optional provider-part/tool-call identity the opaque state must be replayed alongside.
    public let associationID: String?

    public init(id: String = UUID().uuidString, providerID: String, modelID: String,
                kind: String, reference: String, expiresAt: Double? = nil,
                associationID: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.kind = String(kind.prefix(80))
        // Cryptographic provider state must round-trip byte-for-byte; truncating it makes it invalid.
        self.reference = reference
        self.expiresAt = expiresAt
        self.associationID = associationID
    }
}

/// There is deliberately no read/list/search case. A caller cannot convert a successful read
/// into progress without producing a material artifact, effect, evidence item, or check transition.
public enum ReasoningProgressEvidence: Codable, Sendable, Equatable {
    case artifact(ReasoningArtifactReference)
    case workspaceMutation(effectID: String, paths: [String])
    case externalStateChange(effectID: String, target: String)
    case evidence(ReasoningEvidenceReference)
    case checkTransition(ReasoningCheckReceipt)
    case delegationCompleted(effectID: String, childID: String, artifactIDs: [String])
}

public struct ReasoningProgressReceipt: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let nodeID: String?
    public let evidence: ReasoningProgressEvidence
    public let at: Double

    public init(id: String = UUID().uuidString, nodeID: String? = nil,
                evidence: ReasoningProgressEvidence,
                at: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.nodeID = nodeID
        self.evidence = evidence
        self.at = at
    }
}

public struct MonotonicProgressSnapshot: Codable, Sendable, Equatable {
    public var revision: Int
    public var artifactRevisions: [String: String]
    public var effectIDs: Set<String>
    public var evidenceIDs: Set<String>
    public var checkStates: [String: ReasoningCheckState]
    public var receipts: [ReasoningProgressReceipt]

    public init(revision: Int = 0, artifactRevisions: [String: String] = [:],
                effectIDs: Set<String> = [], evidenceIDs: Set<String> = [],
                checkStates: [String: ReasoningCheckState] = [:],
                receipts: [ReasoningProgressReceipt] = []) {
        self.revision = revision
        self.artifactRevisions = artifactRevisions
        self.effectIDs = effectIDs
        self.evidenceIDs = evidenceIDs
        self.checkStates = checkStates
        self.receipts = receipts
    }
}

public enum PlanNodeCompletionRequirement: String, Codable, Sendable, Equatable {
    case summary
    case artifact
    case passingCheck
    case evidence
    case delegation
}

public struct ReasoningPlanNode: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let dependencies: [String]
    public let completionRequirement: PlanNodeCompletionRequirement
    /// Optional live executable payload. Older/general reasoning nodes leave this nil; PlanExecute
    /// stores the frozen PlanStep here so a process restart never has to ask the model to recreate it.
    public let planID: String?
    public let executableStep: PlanStep?

    public init(id: String, title: String, dependencies: [String] = [],
                completionRequirement: PlanNodeCompletionRequirement = .summary,
                planID: String? = nil, executableStep: PlanStep? = nil) {
        self.id = id
        self.title = String(title.prefix(1_000))
        self.dependencies = dependencies
        self.completionRequirement = completionRequirement
        self.planID = planID
        self.executableStep = executableStep
    }
}

/// Codable projection of one actual tool invocation. It is deliberately richer than a summary:
/// verification after resume sees the exact observed effect and the failed attempt preceding a repair.
public struct DurablePlanInvocationReceipt: Codable, Sendable, Equatable {
    public let stepID: String
    public let tool: String
    public let success: Bool
    public let output: String
    public let error: String?
    public let metadata: [String: String]
    public let effectObservation: ToolEffectObservation
    public let executionPhase: Int?
    public let argsFingerprint: String?
    public var supportingCommandReceipt: PlanSupportingCommandReceipt? = nil
    public var workspaceActionReceipt: DurableWorkspaceActionCompletionReceipt? = nil

    public init(stepID: String, tool: String, success: Bool, output: String,
                error: String? = nil, metadata: [String: String] = [:],
                effectObservation: ToolEffectObservation = .none,
                executionPhase: Int? = nil, argsFingerprint: String? = nil,
                workspaceActionReceipt: DurableWorkspaceActionCompletionReceipt? = nil) {
        self.stepID = stepID
        self.tool = tool
        self.success = success
        self.output = String(output.prefix(8_000))
        self.error = error.map { String($0.prefix(2_000)) }
        self.metadata = metadata
        self.effectObservation = effectObservation
        self.executionPhase = executionPhase
        self.argsFingerprint = argsFingerprint
        self.workspaceActionReceipt = workspaceActionReceipt
    }
}

public enum PlanStandardInputSourceKind: String, Codable, Sendable, Equatable {
    case none
    case inline
    case governedPath = "governed_path"
}

/// Nonsecret durable stdin provenance. Inline bytes are never encoded: only their digest/count are
/// retained and that source is intentionally unreplayable after resume. A governed path is project-
/// relative and must be securely reread and matched inside RunCommandTool before process spawn.
public struct DurablePlanStandardInputSource: Codable, Sendable, Equatable {
    public static let currentRootPolicyVersion = "project-confined-openat-v1"

    public let kind: PlanStandardInputSourceKind
    public let relativePath: String?
    public let sha256: String?
    public let byteCount: Int
    public let rootPolicyVersion: String?

    public init(kind: PlanStandardInputSourceKind, relativePath: String? = nil,
                sha256: String? = nil, byteCount: Int = 0,
                rootPolicyVersion: String? = nil) {
        self.kind = kind
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.rootPolicyVersion = rootPolicyVersion
    }

    public static let none = DurablePlanStandardInputSource(kind: .none)
}

/// An exact, replayable verifier invocation plus the bindings that make it authoritative for one
/// immutable PlanExecute contract. No raw stdin bytes are retained in durable state.
public struct DurablePlanVerificationRecipe: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sourcePlanID: String
    public let stepID: String
    public let tool: String
    public let resolvedExecutable: String
    public let argv: [String]
    public let workingDirectory: String?
    /// Optional for backwards decoding: legacy checkpoints have only `standardInput`; synthesized
    /// decoding ignores that unknown raw field and leaves this nil, making resume fail closed. Any
    /// subsequent checkpoint rewrite therefore scrubs the legacy bytes.
    public let standardInputSource: DurablePlanStandardInputSource?
    public let allowedExitCodes: [Int]
    public let canonicalArgumentsJSON: String
    public let argsFingerprint: String
    public let commandFingerprint: String
    public let completionContractFingerprint: String
    public let obligationsFingerprint: String
    public let executionPolicyFingerprint: String
    public let workspaceManifestDigest: String
    public let proofWorkspaceDigest: String
    public let proofOutputDigest: String
    public let proofAt: Date
    public let capabilityFingerprint: String
    public let authorizationFingerprint: String
    public let toolSchemaFingerprint: String
    public let executableIdentity: String

    public init(id: String, sourcePlanID: String, stepID: String, tool: String,
                resolvedExecutable: String, argv: [String], workingDirectory: String? = nil,
                standardInputSource: DurablePlanStandardInputSource? = DurablePlanStandardInputSource.none,
                standardInput: String? = nil,
                allowedExitCodes: [Int],
                canonicalArgumentsJSON: String, argsFingerprint: String,
                commandFingerprint: String, completionContractFingerprint: String,
                obligationsFingerprint: String, executionPolicyFingerprint: String,
                workspaceManifestDigest: String, proofWorkspaceDigest: String,
                proofOutputDigest: String, proofAt: Date,
                capabilityFingerprint: String, authorizationFingerprint: String,
                toolSchemaFingerprint: String, executableIdentity: String) {
        self.id = id
        self.sourcePlanID = sourcePlanID
        self.stepID = stepID
        self.tool = tool
        self.resolvedExecutable = resolvedExecutable
        self.argv = argv
        self.workingDirectory = workingDirectory
        if let standardInput, standardInputSource?.kind == PlanStandardInputSourceKind.none {
            let data = Data(standardInput.utf8)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            self.standardInputSource = DurablePlanStandardInputSource(
                kind: .inline, sha256: digest, byteCount: data.count)
        } else {
            self.standardInputSource = standardInputSource
        }
        self.allowedExitCodes = allowedExitCodes
        self.canonicalArgumentsJSON = canonicalArgumentsJSON
        self.argsFingerprint = argsFingerprint
        self.commandFingerprint = commandFingerprint
        self.completionContractFingerprint = completionContractFingerprint
        self.obligationsFingerprint = obligationsFingerprint
        self.executionPolicyFingerprint = executionPolicyFingerprint
        self.workspaceManifestDigest = workspaceManifestDigest
        self.proofWorkspaceDigest = proofWorkspaceDigest
        self.proofOutputDigest = proofOutputDigest
        self.proofAt = proofAt
        self.capabilityFingerprint = capabilityFingerprint
        self.authorizationFingerprint = authorizationFingerprint
        self.toolSchemaFingerprint = toolSchemaFingerprint
        self.executableIdentity = executableIdentity
    }
}

/// Mission-scoped replay authority. Bindings and the attempt cap are immutable after configuration;
/// recipes and replay-start keys are append-only so a restart cannot erase prior authority or spend.
public struct DurablePlanVerificationControl: Codable, Sendable, Equatable {
    public let missionInstanceID: String?
    public let completionContractFingerprint: String
    public let obligationsFingerprint: String
    public let executionPolicyFingerprint: String
    public let workspaceManifestDigest: String
    public let attemptLimit: Int
    public var recipes: [DurablePlanVerificationRecipe]
    public var seenReplayStateKeys: [String]
    public var attemptsStarted: Int

    public init(missionInstanceID: String? = nil,
                completionContractFingerprint: String, obligationsFingerprint: String,
                executionPolicyFingerprint: String, workspaceManifestDigest: String,
                attemptLimit: Int, recipes: [DurablePlanVerificationRecipe] = [],
                seenReplayStateKeys: [String] = [], attemptsStarted: Int = 0) throws {
        guard attemptLimit > 0 else {
            throw ReasoningControlError.invalidState("verification replay attempt limit must be positive")
        }
        guard attemptsStarted >= 0, attemptsStarted <= attemptLimit,
              attemptsStarted == seenReplayStateKeys.count,
              Set(seenReplayStateKeys).count == seenReplayStateKeys.count else {
            throw ReasoningControlError.invalidState("verification replay attempt ledger is inconsistent")
        }
        self.missionInstanceID = missionInstanceID
        self.completionContractFingerprint = completionContractFingerprint
        self.obligationsFingerprint = obligationsFingerprint
        self.executionPolicyFingerprint = executionPolicyFingerprint
        self.workspaceManifestDigest = workspaceManifestDigest
        self.attemptLimit = attemptLimit
        self.recipes = recipes
        self.seenReplayStateKeys = seenReplayStateKeys
        self.attemptsStarted = attemptsStarted
    }
}

/// Write-ahead intent for one workspace-affecting tool invocation. The intent is persisted before
/// execution and remains active until an explicit, digest-bound completion receipt is committed.
public struct DurableWorkspaceActionIntent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let ordinal: Int
    public let missionInstanceID: String
    public let canonicalFunctionalObjectiveFingerprint: String
    public let planID: String
    public let planRevision: Int
    public let nodeID: String
    public let stepID: String
    public let attempt: Int
    public let tool: String
    public let argsFingerprint: String
    public let capabilityFingerprint: String
    public let completionContractFingerprint: String
    public let executionPolicyFingerprint: String
    public let workspaceManifestPolicyFingerprint: String
    public let preWorkspaceManifestRevision: Int
    public let preWorkspaceManifestDigest: String
    public let preGovernedWorkspaceDigest: String
    public let priorReceiptDigest: String?
    public let startedAt: Double

    public init(id: String, ordinal: Int, missionInstanceID: String,
                canonicalFunctionalObjectiveFingerprint: String,
                planID: String, planRevision: Int, nodeID: String, stepID: String,
                attempt: Int, tool: String, argsFingerprint: String,
                capabilityFingerprint: String, completionContractFingerprint: String,
                executionPolicyFingerprint: String, workspaceManifestPolicyFingerprint: String,
                preWorkspaceManifestRevision: Int, preWorkspaceManifestDigest: String,
                preGovernedWorkspaceDigest: String, priorReceiptDigest: String? = nil,
                startedAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.ordinal = ordinal
        self.missionInstanceID = missionInstanceID
        self.canonicalFunctionalObjectiveFingerprint = canonicalFunctionalObjectiveFingerprint
        self.planID = planID
        self.planRevision = planRevision
        self.nodeID = nodeID
        self.stepID = stepID
        self.attempt = attempt
        self.tool = tool
        self.argsFingerprint = argsFingerprint
        self.capabilityFingerprint = capabilityFingerprint
        self.completionContractFingerprint = completionContractFingerprint
        self.executionPolicyFingerprint = executionPolicyFingerprint
        self.workspaceManifestPolicyFingerprint = workspaceManifestPolicyFingerprint
        self.preWorkspaceManifestRevision = preWorkspaceManifestRevision
        self.preWorkspaceManifestDigest = preWorkspaceManifestDigest
        self.preGovernedWorkspaceDigest = preGovernedWorkspaceDigest
        self.priorReceiptDigest = priorReceiptDigest
        self.startedAt = startedAt
    }

    public var computedIntentDigest: String {
        durableWorkspaceSHA256([
            "workspace-action-intent-v1", id, String(ordinal), missionInstanceID,
            canonicalFunctionalObjectiveFingerprint, planID, String(planRevision), nodeID,
            stepID, String(attempt), tool, argsFingerprint, capabilityFingerprint,
            completionContractFingerprint, executionPolicyFingerprint,
            workspaceManifestPolicyFingerprint, String(preWorkspaceManifestRevision),
            preWorkspaceManifestDigest, preGovernedWorkspaceDigest,
            priorReceiptDigest ?? "", String(startedAt.bitPattern),
        ])
    }
}

/// Completion of exactly one persisted action intent. Embedding the immutable intent binds the
/// post-state to the exact invocation and to the preceding append-only receipt chain.
public struct DurableWorkspaceActionCompletionReceipt: Codable, Sendable, Equatable, Identifiable {
    public var id: String { intent.id }
    public let intent: DurableWorkspaceActionIntent
    public let postWorkspaceManifestRevision: Int
    public let postWorkspaceManifestDigest: String
    public let postGovernedWorkspaceDigest: String
    public let success: Bool
    public let completedAt: Double
    public let receiptDigest: String

    public init(intent: DurableWorkspaceActionIntent,
                postWorkspaceManifestRevision: Int,
                postWorkspaceManifestDigest: String,
                postGovernedWorkspaceDigest: String,
                success: Bool,
                completedAt: Double = Date().timeIntervalSince1970) {
        self.intent = intent
        self.postWorkspaceManifestRevision = postWorkspaceManifestRevision
        self.postWorkspaceManifestDigest = postWorkspaceManifestDigest
        self.postGovernedWorkspaceDigest = postGovernedWorkspaceDigest
        self.success = success
        self.completedAt = completedAt
        self.receiptDigest = Self.digest(
            intent: intent,
            postWorkspaceManifestRevision: postWorkspaceManifestRevision,
            postWorkspaceManifestDigest: postWorkspaceManifestDigest,
            postGovernedWorkspaceDigest: postGovernedWorkspaceDigest,
            success: success,
            completedAt: completedAt)
    }

    public var computedReceiptDigest: String {
        Self.digest(intent: intent,
                    postWorkspaceManifestRevision: postWorkspaceManifestRevision,
                    postWorkspaceManifestDigest: postWorkspaceManifestDigest,
                    postGovernedWorkspaceDigest: postGovernedWorkspaceDigest,
                    success: success, completedAt: completedAt)
    }

    public var hasValidReceiptDigest: Bool {
        !receiptDigest.isEmpty && receiptDigest == computedReceiptDigest
    }

    private static func digest(intent: DurableWorkspaceActionIntent,
                               postWorkspaceManifestRevision: Int,
                               postWorkspaceManifestDigest: String,
                               postGovernedWorkspaceDigest: String,
                               success: Bool, completedAt: Double) -> String {
        durableWorkspaceSHA256([
            "workspace-action-completion-v1", intent.computedIntentDigest,
            String(postWorkspaceManifestRevision), postWorkspaceManifestDigest,
            postGovernedWorkspaceDigest, success ? "success" : "failure",
            String(completedAt.bitPattern),
        ])
    }
}

/// Redacted argument-shape evidence for a plan step rejected before becoming executable.
/// Values are never retained. String stdin is represented only by UTF-8 size and SHA-256.
public struct RejectedPlanStepSummary: Codable, Sendable, Equatable {
    public let stepID: String
    public let tool: String
    public let argumentTypes: [String: String]
    public let stdinPresent: Bool
    public let stdinByteCount: Int?
    public let stdinSHA256: String?

    public init(stepID: String, tool: String, argumentTypes: [String: String],
                stdinPresent: Bool, stdinByteCount: Int? = nil, stdinSHA256: String? = nil) {
        self.stepID = String(stepID.prefix(200))
        self.tool = String(tool.prefix(120))
        var bounded: [String: String] = [:]
        for (key, value) in argumentTypes.sorted(by: { $0.key < $1.key }).prefix(64) {
            let safeKey = String(key.prefix(120))
            if bounded[safeKey] == nil { bounded[safeKey] = String(value.prefix(40)) }
        }
        self.argumentTypes = bounded
        self.stdinPresent = stdinPresent
        self.stdinByteCount = stdinByteCount
        self.stdinSHA256 = stdinSHA256
    }
}

/// Durable forensic receipt for a parsed plan discarded by deterministic preflight. It cannot
/// reconstruct or execute the plan: only a fingerprint, argument shapes, redacted stdin metadata,
/// and bounded validation errors survive.
public struct RejectedPlanAttemptReceipt: Codable, Sendable, Equatable {
    public let planFingerprint: String
    public let providerID: String?
    public let modelID: String?
    public let stepSummaries: [RejectedPlanStepSummary]
    public let validationErrors: [String]
    public let at: Double
    public let ordinal: Int

    public init(planFingerprint: String, providerID: String? = nil, modelID: String? = nil,
                stepSummaries: [RejectedPlanStepSummary], validationErrors: [String],
                at: Double = Date().timeIntervalSince1970, ordinal: Int) {
        self.planFingerprint = planFingerprint
        self.providerID = providerID.map { String($0.prefix(200)) }
        self.modelID = modelID.map { String($0.prefix(200)) }
        self.stepSummaries = Array(stepSummaries.prefix(64))
        self.validationErrors = Array(validationErrors.prefix(32)).map { String($0.prefix(2_000)) }
        self.at = at
        self.ordinal = ordinal
    }
}

public struct DurableExecutablePlanSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let generation: Int
    public let plan: ExecutablePlan
    public let lintWarnings: [String]
    public let replacesPlanID: String?
    public let repairNodeID: String?
    public let workspaceManifestPolicyFingerprint: String?
    public let workspaceManifestRevision: Int?
    public let workspaceManifestDigest: String?
    public let createdAt: Double

    public init(id: String, generation: Int, plan: ExecutablePlan,
                lintWarnings: [String] = [], replacesPlanID: String? = nil,
                repairNodeID: String? = nil,
                workspaceManifestPolicyFingerprint: String? = nil,
                workspaceManifestRevision: Int? = nil,
                workspaceManifestDigest: String? = nil,
                createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.generation = max(0, generation)
        self.plan = plan
        self.lintWarnings = lintWarnings.map { String($0.prefix(1_000)) }
        self.replacesPlanID = replacesPlanID
        self.repairNodeID = repairNodeID
        self.workspaceManifestPolicyFingerprint = workspaceManifestPolicyFingerprint
        self.workspaceManifestRevision = workspaceManifestRevision
        self.workspaceManifestDigest = workspaceManifestDigest
        self.createdAt = createdAt
    }
}

public enum ReasoningPlanNodePhase: String, Codable, Sendable, Equatable {
    case pending
    case accepted
    case active
    case succeeded
    case failed
    case blocked
    case superseded
    case cancelled
}

public struct ReasoningPlanNodeRecord: Codable, Sendable, Equatable {
    public let node: ReasoningPlanNode
    public var phase: ReasoningPlanNodePhase
    public var attempts: Int
    public var lastSummary: String?
    public var evidenceIDs: [String]
    public var lastOutput: String?
    public var invocationReceipts: [DurablePlanInvocationReceipt]?

    public init(node: ReasoningPlanNode, phase: ReasoningPlanNodePhase = .pending,
                attempts: Int = 0, lastSummary: String? = nil, evidenceIDs: [String] = [],
                lastOutput: String? = nil,
                invocationReceipts: [DurablePlanInvocationReceipt]? = nil) {
        self.node = node
        self.phase = phase
        self.attempts = attempts
        self.lastSummary = lastSummary
        self.evidenceIDs = evidenceIDs
        self.lastOutput = lastOutput
        self.invocationReceipts = invocationReceipts
    }
}

public enum RepairTriggerKind: String, Codable, Sendable, Equatable {
    case failedAction
    case failedCheck
    case noProgress
    case reviewerRejection
    case capabilityDenied
    case contextLoss
}

public struct RepairTrigger: Codable, Sendable, Equatable {
    public let kind: RepairTriggerKind
    public let summary: String
    public let evidenceIDs: [String]

    public init(kind: RepairTriggerKind, summary: String, evidenceIDs: [String] = []) {
        self.kind = kind
        self.summary = String(summary.prefix(2_000))
        self.evidenceIDs = evidenceIDs
    }
}

public struct RepairAlternative: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let summary: String
    public let tradeoffs: [String]
    public let replacementNodes: [ReasoningPlanNode]
    public let retryOriginalNode: Bool

    public init(id: String, summary: String, tradeoffs: [String] = [],
                replacementNodes: [ReasoningPlanNode] = [], retryOriginalNode: Bool = false) {
        self.id = id
        self.summary = String(summary.prefix(2_000))
        self.tradeoffs = tradeoffs.map { String($0.prefix(500)) }
        self.replacementNodes = replacementNodes
        self.retryOriginalNode = retryOriginalNode
    }
}

/// A replan is scoped to one failed node and records the alternatives considered, the selected
/// branch, and the already-accepted nodes that were retained.
public struct NodeScopedRepairReceipt: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let nodeID: String
    public let trigger: RepairTrigger
    public let alternatives: [RepairAlternative]
    public let selectedAlternativeID: String?
    public var retainedAcceptedNodeIDs: [String]
    public let at: Double

    public init(id: String = UUID().uuidString, nodeID: String, trigger: RepairTrigger,
                alternatives: [RepairAlternative], selectedAlternativeID: String?,
                retainedAcceptedNodeIDs: [String] = [],
                at: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.nodeID = nodeID
        self.trigger = trigger
        self.alternatives = alternatives
        self.selectedAlternativeID = selectedAlternativeID
        self.retainedAcceptedNodeIDs = retainedAcceptedNodeIDs
        self.at = at
    }

    public var selectedAlternative: RepairAlternative? {
        guard let selectedAlternativeID else { return nil }
        return alternatives.first { $0.id == selectedAlternativeID }
    }
}

public enum PlanNodeExecutionOutcome: String, Codable, Sendable, Equatable {
    case succeeded
    case failed
    case blocked
    case cancelled
}

public struct PlanNodeExecutionReceipt: Codable, Sendable, Equatable {
    public let nodeID: String
    public let outcome: PlanNodeExecutionOutcome
    public let summary: String
    public let tokensSpent: Int
    public let progress: [ReasoningProgressReceipt]
    public let evidence: [ReasoningEvidenceReference]
    public let childCheckpointID: String?
    public let output: String?
    public let invocations: [DurablePlanInvocationReceipt]?

    public init(nodeID: String, outcome: PlanNodeExecutionOutcome, summary: String,
                tokensSpent: Int = 0, progress: [ReasoningProgressReceipt] = [],
                evidence: [ReasoningEvidenceReference] = [], childCheckpointID: String? = nil,
                output: String? = nil, invocations: [DurablePlanInvocationReceipt]? = nil) {
        self.nodeID = nodeID
        self.outcome = outcome
        self.summary = String(summary.prefix(4_000))
        self.tokensSpent = max(0, tokensSpent)
        self.progress = progress
        self.evidence = evidence
        self.childCheckpointID = childCheckpointID
        self.output = output.map { String($0.prefix(8_000)) }
        self.invocations = invocations
    }
}

public enum ReasoningControlError: Error, Sendable, Equatable {
    case missingState(String)
    case stateAlreadyExists(String)
    case invalidState(String)
    case nonMonotonicUpdate(String)
    case unknownPlanNode(String)
    case unacceptedPlanNode(String)
    case invalidPlanTransition(String)
    case invalidRepair(String)
}

/// Durable host-side reasoning state. It contains decisions, summaries, receipts, and opaque
/// provider continuation handles; it has no field capable of representing raw private reasoning.
public struct ReasoningControlState: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 5

    public let id: String
    public var schemaVersion: Int
    /// Random identity of one logical PlanExecute mission. Missing only on legacy checkpoints, which
    /// are intentionally ineligible for implicit or token-based resume.
    public var missionInstanceID: String?
    public var goalFingerprint: String?
    /// Optional for schema-v4 and older decoding. A legacy checkpoint cannot execute workspace
    /// actions until the host explicitly installs the complete lifecycle binding.
    public var canonicalFunctionalObjectiveFingerprint: String?
    public var workspaceManifestPolicyFingerprint: String?
    public var workspaceManifestRevision: Int?
    public var workspaceManifestDigest: String?
    public var previousWorkspaceManifestDigest: String?
    public var lastAcknowledgedGovernedWorkspaceDigest: String?
    public var activeWorkspaceAction: DurableWorkspaceActionIntent?
    public var workspaceActionReceipts: [DurableWorkspaceActionCompletionReceipt]?
    public var route: ReasoningRoute
    public var cycle: Int
    public var tokensSpent: Int
    public var lastCycleDoneAndVerified: Bool
    public var consecutiveNoProgress: Int
    public var activePlanNodeID: String?
    public var acceptedPlanNodeIDs: Set<String>
    public var planNodes: [String: ReasoningPlanNodeRecord]
    public var replanCount: Int
    public var nudgeCount: Int
    public var recoveryCount: Int
    public var repairReceipts: [NodeScopedRepairReceipt]
    public var feedbackReferences: [ReasoningEvidenceReference]
    public var evidenceReferences: [ReasoningEvidenceReference]
    public var childCheckpointIDs: [String: String]
    public var reasoningSummary: String?
    public var providerReasoningHandles: [OpaqueProviderReasoningHandle]
    /// Optional so checkpoints written before provider-neutral effort shipped still decode.
    public var providerEffortRecords: [ProviderEffortRecord]?
    public var progress: MonotonicProgressSnapshot
    /// Optional for backward decoding of checkpoints written before durable PlanExecute shipped.
    public var executablePlanSnapshots: [DurableExecutablePlanSnapshot]?
    public var approvedExecutablePlanIDs: Set<String>?
    /// Optional so schema-v1 checkpoints decode without manufacturing replay authority.
    public var verificationControl: DurablePlanVerificationControl?
    /// Optional so schema-v1/v2 checkpoints decode without inventing rejected planner attempts.
    public var rejectedPlanAttemptReceipts: [RejectedPlanAttemptReceipt]?
    public var revision: Int
    public var updatedAt: Double

    public init(id: String, route: ReasoningRoute, goalFingerprint: String? = nil,
                missionInstanceID: String? = nil,
                updatedAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.schemaVersion = Self.currentSchemaVersion
        self.missionInstanceID = missionInstanceID
        self.goalFingerprint = goalFingerprint
        self.canonicalFunctionalObjectiveFingerprint = nil
        self.workspaceManifestPolicyFingerprint = nil
        self.workspaceManifestRevision = nil
        self.workspaceManifestDigest = nil
        self.previousWorkspaceManifestDigest = nil
        self.lastAcknowledgedGovernedWorkspaceDigest = nil
        self.activeWorkspaceAction = nil
        self.workspaceActionReceipts = []
        self.route = route
        self.cycle = 0
        self.tokensSpent = 0
        self.lastCycleDoneAndVerified = false
        self.consecutiveNoProgress = 0
        self.activePlanNodeID = nil
        self.acceptedPlanNodeIDs = []
        self.planNodes = [:]
        self.replanCount = 0
        self.nudgeCount = 0
        self.recoveryCount = 0
        self.repairReceipts = []
        self.feedbackReferences = []
        self.evidenceReferences = []
        self.childCheckpointIDs = [:]
        self.reasoningSummary = nil
        self.providerReasoningHandles = []
        self.providerEffortRecords = []
        self.progress = MonotonicProgressSnapshot()
        self.executablePlanSnapshots = []
        self.approvedExecutablePlanIDs = []
        self.verificationControl = nil
        self.rejectedPlanAttemptReceipts = []
        self.revision = 0
        self.updatedAt = updatedAt
    }

    public mutating func recordTokenSpend(_ amount: Int) throws {
        guard amount >= 0 else { throw ReasoningControlError.invalidState("negative token spend") }
        let (next, overflow) = tokensSpent.addingReportingOverflow(amount)
        guard !overflow else { throw ReasoningControlError.invalidState("token counter overflow") }
        tokensSpent = next
    }

    public mutating func recordNudge() { nudgeCount += 1 }
    public mutating func recordRecovery() { recoveryCount += 1 }

    public mutating func addEvidence(_ references: [ReasoningEvidenceReference]) {
        var known = Set(evidenceReferences.map(\.id))
        for reference in references where known.insert(reference.id).inserted {
            evidenceReferences.append(reference)
        }
    }

    public mutating func addFeedback(_ references: [ReasoningEvidenceReference]) {
        var known = Set(feedbackReferences.map(\.id))
        for reference in references where known.insert(reference.id).inserted {
            feedbackReferences.append(reference)
        }
    }

    public mutating func setReasoningSummary(_ summary: String?) {
        let clean = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        reasoningSummary = clean.flatMap { $0.isEmpty ? nil : String($0.prefix(12_000)) }
    }

    public mutating func upsertProviderHandle(_ handle: OpaqueProviderReasoningHandle) {
        providerReasoningHandles.removeAll {
            $0.providerID == handle.providerID && $0.modelID == handle.modelID && $0.kind == handle.kind
        }
        providerReasoningHandles.append(handle)
        providerReasoningHandles = Array(providerReasoningHandles.suffix(128))
    }

    public mutating func recordProviderEffort(_ record: ProviderEffortRecord) {
        var records = providerEffortRecords ?? []
        if records.last != record { records.append(record) }
        providerEffortRecords = Array(records.suffix(128))
    }

    public mutating func installPlanNodes(_ nodes: [ReasoningPlanNode], acceptedIDs: Set<String>) throws {
        guard Set(nodes.map(\.id)).count == nodes.count else {
            throw ReasoningControlError.invalidState("plan contains duplicate node ids")
        }
        let known = Set(nodes.map(\.id))
        guard acceptedIDs.isSubset(of: known) else {
            throw ReasoningControlError.invalidState("accepted plan node is missing from the plan")
        }
        for node in nodes where planNodes[node.id] == nil {
            planNodes[node.id] = ReasoningPlanNodeRecord(node: node)
        }
        for id in acceptedIDs {
            acceptedPlanNodeIDs.insert(id)
            if planNodes[id]?.phase == .pending { planNodes[id]?.phase = .accepted }
        }
    }

    public mutating func activatePlanNode(_ nodeID: String) throws {
        guard acceptedPlanNodeIDs.contains(nodeID) else {
            throw ReasoningControlError.unacceptedPlanNode(nodeID)
        }
        guard var record = planNodes[nodeID] else { throw ReasoningControlError.unknownPlanNode(nodeID) }
        guard record.phase == .accepted || record.phase == .failed else {
            throw ReasoningControlError.invalidPlanTransition("cannot activate \(nodeID) from \(record.phase.rawValue)")
        }
        activePlanNodeID = nodeID
        record.phase = .active
        record.attempts += 1
        planNodes[nodeID] = record
    }

    public mutating func recordPlanNodeExecution(_ receipt: PlanNodeExecutionReceipt) throws {
        guard activePlanNodeID == receipt.nodeID, var record = planNodes[receipt.nodeID] else {
            throw ReasoningControlError.invalidPlanTransition("execution receipt does not match the active node")
        }
        record.phase = {
            switch receipt.outcome {
            case .succeeded: return .succeeded
            case .failed: return .failed
            case .blocked: return .blocked
            case .cancelled: return .cancelled
            }
        }()
        record.lastSummary = receipt.summary
        record.evidenceIDs = Array(Set(record.evidenceIDs + receipt.evidence.map(\.id))).sorted()
        record.lastOutput = receipt.output
        record.invocationReceipts = receipt.invocations
        planNodes[receipt.nodeID] = record
        activePlanNodeID = nil
        addEvidence(receipt.evidence)
        if let childCheckpointID = receipt.childCheckpointID {
            childCheckpointIDs[receipt.nodeID] = childCheckpointID
        }
        try recordTokenSpend(receipt.tokensSpent)
        for progressReceipt in receipt.progress { _ = MonotonicProgressReducer.apply(progressReceipt, to: &progress) }
    }

    public mutating func recoverInterruptedPlanNode() throws {
        guard activeWorkspaceAction == nil else {
            throw ReasoningControlError.invalidState(
                "interrupted workspace action requires explicit reconciliation before node recovery")
        }
        guard let nodeID = activePlanNodeID, var record = planNodes[nodeID] else {
            activePlanNodeID = nil
            return
        }
        guard record.phase == .active else {
            throw ReasoningControlError.invalidPlanTransition("active node pointer does not reference an active node")
        }
        record.phase = .accepted
        planNodes[nodeID] = record
        activePlanNodeID = nil
        recoveryCount += 1
    }

    public mutating func appendExecutablePlan(_ snapshot: DurableExecutablePlanSnapshot,
                                              nodes: [ReasoningPlanNode]) throws {
        var snapshots = executablePlanSnapshots ?? []
        if let existing = snapshots.first(where: { $0.id == snapshot.id }) {
            guard existing == snapshot else {
                throw ReasoningControlError.invalidState("plan snapshot identity was reused with different content")
            }
        } else {
            snapshots.append(snapshot)
            executablePlanSnapshots = snapshots
        }
        try installPlanNodes(nodes, acceptedIDs: Set(nodes.map(\.id)))
    }

    /// Append-only and capped by the caller's immutable plan-attempt budget. Rejected plans never
    /// install nodes, become approved, or enter executable snapshot history.
    public mutating func appendRejectedPlanAttempt(
        _ receipt: RejectedPlanAttemptReceipt,
        attemptLimit: Int
    ) throws {
        guard attemptLimit > 0 else {
            throw ReasoningControlError.invalidState("rejected plan attempt limit must be positive")
        }
        var receipts = rejectedPlanAttemptReceipts ?? []
        guard receipts.count < attemptLimit else {
            throw ReasoningControlError.invalidState("rejected plan attempt limit exhausted")
        }
        guard !receipt.planFingerprint.isEmpty,
              receipt.ordinal == receipts.count + 1 else {
            throw ReasoningControlError.invalidState(
                "rejected plan attempt ordinal or fingerprint is invalid")
        }
        receipts.append(receipt)
        rejectedPlanAttemptReceipts = receipts
    }

    public mutating func approveExecutablePlan(_ planID: String) throws {
        guard (executablePlanSnapshots ?? []).contains(where: { $0.id == planID }) else {
            throw ReasoningControlError.invalidState("cannot approve an unknown executable plan")
        }
        var approved = approvedExecutablePlanIDs ?? []
        approved.insert(planID)
        approvedExecutablePlanIDs = approved
    }

    /// Configure replay authority once. Repeating the exact binding is idempotent; changing any
    /// binding or the cap requires a new run/checkpoint identity.
    public mutating func configureVerificationControl(
        missionInstanceID: String? = nil,
        completionContractFingerprint: String,
        obligationsFingerprint: String,
        executionPolicyFingerprint: String,
        workspaceManifestDigest: String,
        attemptLimit: Int
    ) throws {
        if let existing = verificationControl {
            guard existing.missionInstanceID == missionInstanceID,
                  existing.completionContractFingerprint == completionContractFingerprint,
                  existing.obligationsFingerprint == obligationsFingerprint,
                  existing.executionPolicyFingerprint == executionPolicyFingerprint,
                  existing.workspaceManifestDigest == workspaceManifestDigest,
                  existing.attemptLimit == attemptLimit else {
                throw ReasoningControlError.invalidState(
                    "verification control is already configured with different immutable bindings")
            }
            return
        }
        verificationControl = try DurablePlanVerificationControl(
            missionInstanceID: missionInstanceID,
            completionContractFingerprint: completionContractFingerprint,
            obligationsFingerprint: obligationsFingerprint,
            executionPolicyFingerprint: executionPolicyFingerprint,
            workspaceManifestDigest: workspaceManifestDigest,
            attemptLimit: attemptLimit)
    }

    /// Append one exact verifier recipe. Reusing an id with identical content is idempotent; an id
    /// collision with different content fails closed.
    public mutating func appendVerificationRecipe(_ recipe: DurablePlanVerificationRecipe) throws {
        guard var control = verificationControl else {
            throw ReasoningControlError.invalidState("verification control is not configured")
        }
        guard recipe.completionContractFingerprint == control.completionContractFingerprint,
              recipe.obligationsFingerprint == control.obligationsFingerprint,
              recipe.executionPolicyFingerprint == control.executionPolicyFingerprint,
              recipe.workspaceManifestDigest == control.workspaceManifestDigest else {
            throw ReasoningControlError.invalidState(
                "verification recipe does not match the configured immutable bindings")
        }
        if let existing = control.recipes.first(where: { $0.id == recipe.id }) {
            guard existing == recipe else {
                throw ReasoningControlError.invalidState(
                    "verification recipe identity was reused with different content")
            }
            return
        }
        control.recipes.append(recipe)
        verificationControl = control
    }

    /// Reserve a replay attempt durably before its process is launched. A state key is single-use,
    /// and the counter/key append happen in the same store mutation.
    public mutating func beginVerificationReplay(stateKey: String) throws {
        let key = stateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ReasoningControlError.invalidState("verification replay state key is empty")
        }
        guard var control = verificationControl else {
            throw ReasoningControlError.invalidState("verification control is not configured")
        }
        guard !control.seenReplayStateKeys.contains(key) else {
            throw ReasoningControlError.invalidState(
                "verification replay state was already attempted")
        }
        guard control.attemptsStarted < control.attemptLimit else {
            throw ReasoningControlError.invalidState("verification replay attempt limit reached")
        }
        control.seenReplayStateKeys.append(key)
        control.attemptsStarted += 1
        verificationControl = control
    }

    /// Install the immutable objective/manifest policy and the initial acknowledged workspace head.
    /// Repeating the exact binding is idempotent. Partial legacy state and binding changes fail closed.
    public mutating func configureWorkspaceLifecycle(
        canonicalFunctionalObjectiveFingerprint: String,
        workspaceManifestPolicyFingerprint: String,
        workspaceManifestRevision: Int,
        workspaceManifestDigest: String,
        previousWorkspaceManifestDigest: String? = nil,
        lastAcknowledgedGovernedWorkspaceDigest: String
    ) throws {
        let objective = canonicalFunctionalObjectiveFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        let policy = workspaceManifestPolicyFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = workspaceManifestDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        let acknowledged = lastAcknowledgedGovernedWorkspaceDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard missionInstanceID?.isEmpty == false, !objective.isEmpty, !policy.isEmpty,
              workspaceManifestRevision >= 0, !head.isEmpty, !acknowledged.isEmpty else {
            throw ReasoningControlError.invalidState("workspace lifecycle binding is incomplete")
        }
        let configured = self.canonicalFunctionalObjectiveFingerprint != nil
            || self.workspaceManifestPolicyFingerprint != nil
            || self.workspaceManifestRevision != nil
            || self.workspaceManifestDigest != nil
            || self.lastAcknowledgedGovernedWorkspaceDigest != nil
        if configured {
            guard self.canonicalFunctionalObjectiveFingerprint == objective,
                  self.workspaceManifestPolicyFingerprint == policy,
                  self.workspaceManifestRevision == workspaceManifestRevision,
                  self.workspaceManifestDigest == head,
                  self.previousWorkspaceManifestDigest == previousWorkspaceManifestDigest,
                  self.lastAcknowledgedGovernedWorkspaceDigest == acknowledged else {
                throw ReasoningControlError.invalidState(
                    "workspace lifecycle is already configured with a different binding")
            }
            return
        }
        guard activeWorkspaceAction == nil, (workspaceActionReceipts ?? []).isEmpty else {
            throw ReasoningControlError.invalidState(
                "legacy workspace lifecycle cannot be configured after action history exists")
        }
        self.canonicalFunctionalObjectiveFingerprint = objective
        self.workspaceManifestPolicyFingerprint = policy
        self.workspaceManifestRevision = workspaceManifestRevision
        self.workspaceManifestDigest = head
        self.previousWorkspaceManifestDigest = previousWorkspaceManifestDigest
        self.lastAcknowledgedGovernedWorkspaceDigest = acknowledged
        self.workspaceActionReceipts = []
    }

    /// Persist STARTED authority before a tool may execute. There is deliberately no recovery path
    /// that clears this field; only a matching completion receipt may advance it.
    public mutating func beginWorkspaceAction(_ intent: DurableWorkspaceActionIntent) throws {
        try validateWorkspaceLifecycle()
        guard activeWorkspaceAction == nil else {
            throw ReasoningControlError.invalidState(
                "an active workspace action requires reconciliation")
        }
        let receipts = workspaceActionReceipts ?? []
        guard intent.ordinal == receipts.count + 1,
              !intent.id.isEmpty,
              !receipts.contains(where: { $0.id == intent.id }),
              intent.missionInstanceID == missionInstanceID,
              intent.canonicalFunctionalObjectiveFingerprint == canonicalFunctionalObjectiveFingerprint,
              intent.workspaceManifestPolicyFingerprint == workspaceManifestPolicyFingerprint,
              intent.preWorkspaceManifestRevision == workspaceManifestRevision,
              intent.preWorkspaceManifestDigest == workspaceManifestDigest,
              intent.preGovernedWorkspaceDigest == lastAcknowledgedGovernedWorkspaceDigest,
              intent.priorReceiptDigest == receipts.last?.receiptDigest,
              intent.planRevision >= 0, intent.attempt > 0,
              !intent.planID.isEmpty, !intent.nodeID.isEmpty, !intent.stepID.isEmpty,
              !intent.tool.isEmpty, !intent.argsFingerprint.isEmpty,
              !intent.capabilityFingerprint.isEmpty,
              !intent.completionContractFingerprint.isEmpty,
              !intent.executionPolicyFingerprint.isEmpty else {
            throw ReasoningControlError.invalidState(
                "workspace action intent does not match the durable lifecycle head")
        }
        activeWorkspaceAction = intent
    }

    /// Commit the action receipt and advance all manifest/acknowledgement heads together. Hosts
    /// should call this from DurablePlanExecuteLoop's state finalizer so the node receipt and these
    /// fields share one atomic checkpoint envelope.
    public mutating func completeWorkspaceAction(
        _ receipt: DurableWorkspaceActionCompletionReceipt
    ) throws {
        guard let activeWorkspaceAction else {
            throw ReasoningControlError.invalidState("no active workspace action to complete")
        }
        guard receipt.intent == activeWorkspaceAction,
              receipt.hasValidReceiptDigest,
              receipt.completedAt >= activeWorkspaceAction.startedAt,
              receipt.postWorkspaceManifestRevision == activeWorkspaceAction.preWorkspaceManifestRevision + 1,
              !receipt.postWorkspaceManifestDigest.isEmpty,
              !receipt.postGovernedWorkspaceDigest.isEmpty else {
            throw ReasoningControlError.invalidState(
                "workspace action completion does not match its STARTED intent")
        }
        var receipts = workspaceActionReceipts ?? []
        guard activeWorkspaceAction.priorReceiptDigest == receipts.last?.receiptDigest else {
            throw ReasoningControlError.invalidState("workspace action receipt chain diverged")
        }
        receipts.append(receipt)
        workspaceActionReceipts = receipts
        previousWorkspaceManifestDigest = workspaceManifestDigest
        workspaceManifestRevision = receipt.postWorkspaceManifestRevision
        workspaceManifestDigest = receipt.postWorkspaceManifestDigest
        lastAcknowledgedGovernedWorkspaceDigest = receipt.postGovernedWorkspaceDigest
        self.activeWorkspaceAction = nil
        try validateWorkspaceLifecycle()
    }

    /// Validate current lifecycle integrity without creating missing authority for legacy state.
    public func validateWorkspaceLifecycle() throws {
        let configuredValues: [Bool] = [
            canonicalFunctionalObjectiveFingerprint?.isEmpty == false,
            workspaceManifestPolicyFingerprint?.isEmpty == false,
            workspaceManifestRevision != nil,
            workspaceManifestDigest?.isEmpty == false,
            lastAcknowledgedGovernedWorkspaceDigest?.isEmpty == false,
        ]
        let configuredCount = configuredValues.filter { $0 }.count
        let receipts = workspaceActionReceipts ?? []
        if configuredCount == 0 {
            guard activeWorkspaceAction == nil, receipts.isEmpty else {
                throw ReasoningControlError.invalidState(
                    "legacy state contains workspace actions without lifecycle authority")
            }
            return
        }
        guard configuredCount == configuredValues.count,
              let missionInstanceID, !missionInstanceID.isEmpty,
              let objective = canonicalFunctionalObjectiveFingerprint,
              let policy = workspaceManifestPolicyFingerprint,
              let revision = workspaceManifestRevision, revision >= 0,
              let head = workspaceManifestDigest, !head.isEmpty,
              let acknowledged = lastAcknowledgedGovernedWorkspaceDigest,
              !acknowledged.isEmpty else {
            throw ReasoningControlError.invalidState("workspace lifecycle state is partial")
        }
        var priorReceiptDigest: String?
        var priorPostRevision: Int?
        var priorPostHead: String?
        var priorPostWorkspaceDigest: String?
        for (index, receipt) in receipts.enumerated() {
            let intent = receipt.intent
            guard receipt.hasValidReceiptDigest,
                  intent.ordinal == index + 1,
                  intent.missionInstanceID == missionInstanceID,
                  intent.canonicalFunctionalObjectiveFingerprint == objective,
                  intent.workspaceManifestPolicyFingerprint == policy,
                  intent.priorReceiptDigest == priorReceiptDigest,
                  receipt.postWorkspaceManifestRevision == intent.preWorkspaceManifestRevision + 1,
                  receipt.completedAt >= intent.startedAt else {
                throw ReasoningControlError.invalidState("workspace action receipt chain is invalid")
            }
            if let priorPostRevision {
                guard intent.preWorkspaceManifestRevision == priorPostRevision,
                      intent.preWorkspaceManifestDigest == priorPostHead,
                      intent.preGovernedWorkspaceDigest == priorPostWorkspaceDigest else {
                    throw ReasoningControlError.invalidState(
                        "workspace action receipt heads are discontinuous")
                }
            }
            priorReceiptDigest = receipt.receiptDigest
            priorPostRevision = receipt.postWorkspaceManifestRevision
            priorPostHead = receipt.postWorkspaceManifestDigest
            priorPostWorkspaceDigest = receipt.postGovernedWorkspaceDigest
        }
        if let last = receipts.last {
            guard revision == last.postWorkspaceManifestRevision,
                  head == last.postWorkspaceManifestDigest,
                  acknowledged == last.postGovernedWorkspaceDigest else {
                throw ReasoningControlError.invalidState(
                    "workspace lifecycle head does not match its final receipt")
            }
        }
        if let activeWorkspaceAction {
            guard activeWorkspaceAction.ordinal == receipts.count + 1,
                  activeWorkspaceAction.missionInstanceID == missionInstanceID,
                  activeWorkspaceAction.canonicalFunctionalObjectiveFingerprint == objective,
                  activeWorkspaceAction.workspaceManifestPolicyFingerprint == policy,
                  activeWorkspaceAction.preWorkspaceManifestRevision == revision,
                  activeWorkspaceAction.preWorkspaceManifestDigest == head,
                  activeWorkspaceAction.preGovernedWorkspaceDigest == acknowledged,
                  activeWorkspaceAction.priorReceiptDigest == receipts.last?.receiptDigest else {
                throw ReasoningControlError.invalidState(
                    "active workspace action does not match the lifecycle head")
            }
        }
    }

    /// Replanning never deletes accepted work. Only unfinished nodes belonging to the replaced plan
    /// become superseded; succeeded receipts and their evidence remain immutable and reusable.
    public mutating func supersedeUnfinishedNodes(planID: String) throws {
        for id in acceptedPlanNodeIDs {
            guard var record = planNodes[id], record.node.planID == planID else { continue }
            switch record.phase {
            case .succeeded, .superseded:
                continue
            case .active where activePlanNodeID == id:
                activePlanNodeID = nil
                record.phase = .superseded
            case .accepted, .failed, .blocked, .cancelled, .pending:
                record.phase = .superseded
            case .active:
                throw ReasoningControlError.invalidPlanTransition("unowned active plan node cannot be superseded")
            }
            planNodes[id] = record
        }
    }

    public mutating func applyRepair(_ original: NodeScopedRepairReceipt) throws {
        guard var failed = planNodes[original.nodeID] else {
            throw ReasoningControlError.unknownPlanNode(original.nodeID)
        }
        guard original.selectedAlternativeID == nil || original.selectedAlternative != nil else {
            throw ReasoningControlError.invalidRepair("selected alternative is not present")
        }
        var receipt = original
        receipt.retainedAcceptedNodeIDs = acceptedPlanNodeIDs.sorted()
        repairReceipts.append(receipt)
        replanCount += 1

        guard let selected = receipt.selectedAlternative else {
            failed.phase = .blocked
            planNodes[receipt.nodeID] = failed
            return
        }
        if selected.retryOriginalNode {
            failed.phase = .accepted
        } else {
            failed.phase = .superseded
        }
        planNodes[receipt.nodeID] = failed
        try installPlanNodes(selected.replacementNodes,
                             acceptedIDs: Set(selected.replacementNodes.map(\.id)))
    }

    public mutating func recordRepair(_ original: NodeScopedRepairReceipt) {
        var receipt = original
        receipt.retainedAcceptedNodeIDs = acceptedPlanNodeIDs.sorted()
        repairReceipts.append(receipt)
        replanCount += 1
    }
}
