import Foundation
import AgentCore

// Cobolo value types (stage, contract, baseline, receipts, plan/revision, model invocation, store)
// extracted from KistRunner+Cobolo.swift to keep the runner core under the size limit.

enum CoboloStage: String, Codable, Sendable, CaseIterable {
    case initialized
    case explored
    case planned
    case attempting
    case generating
    case candidateWritten
    case candidateVerified
    case criticApproved
    case promotionApproved
    case promoted
    case completed

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

struct CoboloContract: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let id: String
    let goal: String
    let projectRoot: String
    let target: String
    let expectedStdout: String
    let ollamaEndpoint: String
    let producerIdentities: [String]
    let criticIdentity: String
    let promotionReviewerIdentity: String
    let maxRevisions: Int
    /// Nil decodes schema-v1/v2 state for an explicit non-resumable migration refusal.
    let builderExecutionContract: SealedBuilderExecutionContract?

    init(schemaVersion: Int, id: String, goal: String, projectRoot: String,
         target: String, expectedStdout: String, ollamaEndpoint: String,
         producerIdentities: [String], criticIdentity: String,
         promotionReviewerIdentity: String, maxRevisions: Int,
         builderExecutionContract: SealedBuilderExecutionContract? = nil) {
        self.schemaVersion = schemaVersion; self.id = id; self.goal = goal
        self.projectRoot = projectRoot; self.target = target
        self.expectedStdout = expectedStdout; self.ollamaEndpoint = ollamaEndpoint
        self.producerIdentities = producerIdentities; self.criticIdentity = criticIdentity
        self.promotionReviewerIdentity = promotionReviewerIdentity
        self.maxRevisions = maxRevisions
        self.builderExecutionContract = builderExecutionContract
    }
}

struct CoboloBaseline: Codable, Sendable, Equatable {
    let missing: Bool
    let sha256: String?

    static let absent = Self(missing: true, sha256: nil)
    static func digest(_ value: String) -> Self { Self(missing: false, sha256: value) }
}

struct CoboloCommandInvocation: Codable, Sendable, Equatable {
    let executable: String
    let arguments: [String]
    let workingDirectory: String
    let timeoutSeconds: Int
    let allowedExitCodes: [Int]

    var toolArguments: [String: Any] {
        [
            "executable": executable,
            "args": arguments,
            "cwd": workingDirectory,
            "timeout": timeoutSeconds,
            "allowed_exit_codes": allowedExitCodes,
        ]
    }
}

struct CoboloCommandReceipt: Codable, Sendable, Equatable {
    let stage: String
    let executable: String
    let arguments: [String]
    let exitCode: Int32
    let sandboxed: Bool
    let timedOut: Bool
    let wasSignalled: Bool
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    let outputTruncated: Bool
    let stdout: String
    let stderr: String
    let capturedAt: Date
    let invocation: CoboloCommandInvocation?
    let trustedCommandReference: BuilderTrustedCommandReference?

    init(stage: String, executable: String, arguments: [String], exitCode: Int32,
         sandboxed: Bool, timedOut: Bool, wasSignalled: Bool,
         stdoutTruncated: Bool, stderrTruncated: Bool, outputTruncated: Bool,
         stdout: String, stderr: String, capturedAt: Date,
         invocation: CoboloCommandInvocation? = nil,
         trustedCommandReference: BuilderTrustedCommandReference? = nil) {
        self.stage = stage; self.executable = executable; self.arguments = arguments
        self.exitCode = exitCode; self.sandboxed = sandboxed; self.timedOut = timedOut
        self.wasSignalled = wasSignalled; self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated; self.outputTruncated = outputTruncated
        self.stdout = stdout; self.stderr = stderr; self.capturedAt = capturedAt
        self.invocation = invocation
        self.trustedCommandReference = trustedCommandReference
    }

    var evidenceDigest: String {
        var fields = [
            stage, executable, arguments.joined(separator: "\u{0}"), String(exitCode),
            String(sandboxed), String(timedOut), String(wasSignalled),
            String(stdoutTruncated), String(stderrTruncated), String(outputTruncated), stdout, stderr
        ]
        if let invocation {
            fields += [
                invocation.executable, invocation.arguments.joined(separator: "\u{0}"),
                invocation.workingDirectory, String(invocation.timeoutSeconds),
                invocation.allowedExitCodes.map(String.init).joined(separator: ","),
                trustedCommandReference?.bindingDigest ?? "unbound-launcher",
                trustedCommandReference?.observationID ?? "unbound-observation",
            ]
        }
        return BuilderEvidenceDigest.sha256(fields.joined(separator: "\u{1f}"))
    }
}

struct CoboloVerificationReceipt: Codable, Sendable, Equatable {
    let phase: String
    let sourcePath: String
    let sourceSHA256: String
    let binarySHA256: String
    let compile: CoboloCommandReceipt
    let run: CoboloCommandReceipt
    let expectedStdout: String
    let verifiedAt: Date
}

struct CoboloSemanticReviewReceipt: Codable, Sendable, Equatable {
    let contractID: String
    let reviewerIdentity: String
    let candidateSHA256: String
    let compileEvidenceDigest: String
    let runEvidenceDigest: String
    let approved: Bool
    let reason: String
    let reviewedAt: Date

    var evidenceDigest: String {
        BuilderEvidenceDigest.sha256([
            contractID, reviewerIdentity, candidateSHA256, compileEvidenceDigest,
            runEvidenceDigest, String(approved), reason
        ].joined(separator: "\u{1f}"))
    }
}

struct CoboloPromotionReviewReceipt: Codable, Sendable, Equatable {
    struct Vote: Codable, Sendable, Equatable {
        let name: String
        let approved: Bool
        let failed: Bool
        let reason: String
    }

    let reviewerIdentity: String
    let contractID: String
    let candidateSHA256: String
    let semanticReceiptDigest: String
    let verificationDigest: String
    let approved: Bool
    let reason: String
    let votes: [Vote]
    let reviewedAt: Date
}

struct CoboloAcceptanceReceipt: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let contractID: String
    let target: String
    let baseline: CoboloBaseline
    let candidateSHA256: String
    let promotedSHA256: String
    /// Governed workspace digest captured under the canonical lease immediately
    /// after the final post-review verification. Optional only so schema-v1
    /// durable receipts can be replayed and upgraded fail-closed.
    let observedWorkspaceDigest: String?
    let producerIdentities: [String]
    let compilerPreflight: CoboloCommandReceipt
    let critic: CoboloSemanticReviewReceipt
    let promotionReview: CoboloPromotionReviewReceipt
    let verifications: [CoboloVerificationReceipt]
    let acceptedAt: Date
    let builderExecutionContract: SealedBuilderExecutionContract?

    init(schemaVersion: Int, contractID: String, target: String, baseline: CoboloBaseline,
         candidateSHA256: String, promotedSHA256: String, observedWorkspaceDigest: String?,
         producerIdentities: [String], compilerPreflight: CoboloCommandReceipt,
         critic: CoboloSemanticReviewReceipt, promotionReview: CoboloPromotionReviewReceipt,
         verifications: [CoboloVerificationReceipt], acceptedAt: Date,
         builderExecutionContract: SealedBuilderExecutionContract? = nil) {
        self.schemaVersion = schemaVersion; self.contractID = contractID; self.target = target
        self.baseline = baseline; self.candidateSHA256 = candidateSHA256
        self.promotedSHA256 = promotedSHA256
        self.observedWorkspaceDigest = observedWorkspaceDigest
        self.producerIdentities = producerIdentities
        self.compilerPreflight = compilerPreflight; self.critic = critic
        self.promotionReview = promotionReview; self.verifications = verifications
        self.acceptedAt = acceptedAt
        self.builderExecutionContract = builderExecutionContract
    }
}

/// Typed boundary between the governed Cobolo loop and the outer BuilderRun.
/// The Builder must never infer acceptance from an exit status alone.
struct CoboloBuilderEvidence: Sendable {
    let producerIdentities: [String]
    let target: String
    let promotedSHA256: String
    let observedWorkspaceDigest: String
    let finalVerification: CoboloVerificationReceipt
    let reviewerIdentity: String
    let executionContract: SealedBuilderExecutionContract
}

/// Injectable Cobolo runtime seams. Production continues to use the canonical
/// registry and tool instances when this value is nil.
struct CoboloToolOutcome {
    let success: Bool
    let output: String
    let error: String?
    let metadata: [String: String]
    let trustedCommandReference: BuilderTrustedCommandReference?

    init(success: Bool, output: String = "", error: String? = nil,
         metadata: [String: String] = [:],
         trustedCommandReference: BuilderTrustedCommandReference? = nil) {
        self.success = success; self.output = output; self.error = error; self.metadata = metadata
        self.trustedCommandReference = trustedCommandReference
    }

    init(_ result: ToolResult) {
        self.init(success: result.success, output: result.output,
                  error: result.error, metadata: result.metadata,
                  trustedCommandReference: result.trustedCommandReference)
    }
}

enum CoboloModelStage: String, Sendable {
    case driverPlan
    case coderPlan
    case semanticCritic
    case promotion
}

struct CoboloModelInvocation {
    let stage: CoboloModelStage
    let binding: ProviderBinding
    let prompt: String
    let contractID: String
    let explorationDigest: String?
    let revision: Int?
    let upstreamPlanDigest: String?
    let feedbackDigest: String?
    let candidateSHA256: String?
    let compileEvidenceDigest: String?
    let runEvidenceDigest: String?
    let semanticReceiptDigest: String?
    let verificationDigest: String?
}

struct CoboloModelCompletion {
    let providerId: String
    let model: String
    let text: String
}

struct CoboloIdentityPlan {
    let driver: ProviderBinding
    let coder: ProviderBinding
    let cobol: ProviderBinding
    let critic: ProviderBinding
    let promotion: ProviderBinding

    var producerIdentities: [String] {
        Array(Set([driver, coder, cobol].map {
            "\($0.providerId.lowercased()):\(($0.model ?? "unknown").lowercased())"
        })).sorted()
    }
}

struct CoboloDependencies {
    let environment: [String: String]?
    let identityPlan: CoboloIdentityPlan?
    let executeTool: ((String, [String: Any], ToolContext, String) async -> CoboloToolOutcome)?
    let complete: ((CoboloModelInvocation) async throws -> CoboloModelCompletion)?
    let beforePromotion: (() throws -> Void)?
    /// Test seam for a conditional publication implementation that can publish
    /// and then report a durability error. Production always uses descriptor-
    /// confined conditionalReplace while the canonical lease is held.
    let conditionalPromotion: ((ConfinedRoot, String, Data,
                                ConfinedRoot.ConditionalBaseline) throws -> Data)?
    /// Test seam for the crash window after publication but before durable
    /// promoted-state persistence.
    let beforePromotedStateSave: (() throws -> Void)?
    let attemptJournal: (any CoboloAttemptJournal)?

    init(environment: [String: String]? = nil,
         identityPlan: CoboloIdentityPlan? = nil,
         executeTool: ((String, [String: Any], ToolContext, String) async -> CoboloToolOutcome)? = nil,
         complete: ((CoboloModelInvocation) async throws -> CoboloModelCompletion)? = nil,
         beforePromotion: (() throws -> Void)? = nil,
         conditionalPromotion: ((ConfinedRoot, String, Data,
                                 ConfinedRoot.ConditionalBaseline) throws -> Data)? = nil,
         beforePromotedStateSave: (() throws -> Void)? = nil,
         attemptJournal: (any CoboloAttemptJournal)? = nil) {
        self.environment = environment; self.identityPlan = identityPlan
        self.executeTool = executeTool; self.complete = complete
        self.beforePromotion = beforePromotion
        self.conditionalPromotion = conditionalPromotion
        self.beforePromotedStateSave = beforePromotedStateSave
        self.attemptJournal = attemptJournal
    }
}

struct CoboloExplorationEntry: Codable, Sendable, Equatable {
    let path: String
    let sha256: String
}

struct CoboloExplorationReceipt: Codable, Sendable, Equatable {
    let contractID: String
    let compilerIdentity: String
    let files: [CoboloExplorationEntry]
    let receiptDigest: String
    let exploredAt: Date

    var computedDigest: String {
        BuilderEvidenceDigest.sha256([
            contractID, compilerIdentity,
            files.map { "\($0.path)=\($0.sha256)" }.joined(separator: "\u{1e}")
        ].joined(separator: "\u{1f}"))
    }
}

struct CoboloPlanReceipt: Codable, Sendable, Equatable {
    let role: String
    let plannerIdentity: String
    let contractID: String
    let explorationDigest: String
    let revision: Int
    let upstreamPlanDigest: String?
    let feedbackDigest: String?
    let steps: [String]
    let acceptanceChecks: [String]
    let rawResponse: String
    let receiptDigest: String
    let plannedAt: Date

    var computedDigest: String {
        BuilderEvidenceDigest.sha256([
            role, plannerIdentity, contractID, explorationDigest, String(revision),
            upstreamPlanDigest ?? "", feedbackDigest ?? "", steps.joined(separator: "\u{1e}"),
            acceptanceChecks.joined(separator: "\u{1e}"), rawResponse
        ].joined(separator: "\u{1f}"))
    }
}

struct CoboloRevisionReceipt: Codable, Sendable, Equatable {
    let attempt: Int
    let revision: Int
    let candidatePath: String
    let candidateSHA256: String?
    let planDigest: String
    let outcome: String
    let feedback: String?
    let verification: CoboloVerificationReceipt?
    let critic: CoboloSemanticReviewReceipt?
    let finishedAt: Date
}

struct CoboloBaselineSnapshot: Codable, Sendable, Equatable {
    let missing: Bool
    let path: String?
    let sha256: String?
    let byteCount: Int
    let capturedAt: Date
}

struct CoboloRollbackReceipt: Codable, Sendable, Equatable {
    let action: String
    let candidateSHA256: String
    let baselineSHA256: String?
    let succeeded: Bool
    let error: String?
    let rolledBackAt: Date
}

struct CoboloRunState: Codable, Sendable, Equatable {
    let contract: CoboloContract
    let baseline: CoboloBaseline
    var stage: CoboloStage
    var candidatePath: String
    var candidateSHA256: String?
    var promotedSHA256: String?
    var compilerPreflight: CoboloCommandReceipt?
    var verifications: [CoboloVerificationReceipt]
    var critic: CoboloSemanticReviewReceipt?
    var promotionReview: CoboloPromotionReviewReceipt?
    var acceptance: CoboloAcceptanceReceipt?
    var exploration: CoboloExplorationReceipt?
    var explorationHistory: [CoboloExplorationReceipt]?
    var planReceipts: [CoboloPlanReceipt]
    var activePlanDigest: String?
    var attemptsStarted: Int
    var revisionReceipts: [CoboloRevisionReceipt]
    var feedback: String?
    var baselineSnapshot: CoboloBaselineSnapshot?
    var rollback: CoboloRollbackReceipt?
    var lastError: String?
    var updatedAt: Date
}

enum CoboloLoopError: LocalizedError, Equatable {
    case configuration(String)
    case rejected(String)
    case retryableCandidate(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .rejected(let message), .retryableCandidate(let message): return message
        }
    }
}

struct CoboloRunStore {
    let root: ConfinedRoot
    let durableRoot: ConfinedRoot?
    let directory: String
    let durableDirectory: String

    init(root: ConfinedRoot, durableRoot: ConfinedRoot? = nil, runID: String) {
        self.root = root
        self.durableRoot = durableRoot
        self.directory = ".kist/cobolo-runs/\(runID)"
        self.durableDirectory = ".kist/cobolo-runs/\(runID)"
    }

    func prepare() throws {
        try root.makeDirectory(directory)
        try durableRoot?.makeDirectory(durableDirectory)
    }

    func load() throws -> CoboloRunState? {
        let path = "\(directory)/state.json"
        let data: Data
        if let durableRoot,
           (try? durableRoot.fileType("\(durableDirectory)/state.json").exists) == true {
            data = try durableRoot.readStableData(
                "\(durableDirectory)/state.json", maxBytes: 4_194_304)
            try root.writeData(path, data, createParents: true)
        } else {
            guard try root.fileType(path).exists else { return nil }
            data = try root.readStableData(path, maxBytes: 4_194_304)
        }
        let state = try Self.decoder.decode(CoboloRunState.self, from: data)
        try hydrate(state.candidatePath)
        if let baselinePath = state.baselineSnapshot?.path { try hydrate(baselinePath) }
        return state
    }

    func save(_ state: CoboloRunState) throws {
        let data = try Self.encoder.encode(state)
        try root.writeData("\(directory)/state.json", data, createParents: true)
        try durableRoot?.writeData(
            "\(durableDirectory)/state.json", data, createParents: true)
        try mirror(state.candidatePath)
        if let baselinePath = state.baselineSnapshot?.path { try mirror(baselinePath) }
    }

    func save(_ receipt: CoboloAcceptanceReceipt) throws {
        let data = try Self.encoder.encode(receipt)
        try root.writeData("\(directory)/receipt.json", data, createParents: true)
        try durableRoot?.writeData(
            "\(durableDirectory)/receipt.json", data, createParents: true)
    }

    func invalidateAcceptance(lease: WorkspaceExecutionLease) throws {
        let path = "\(directory)/receipt.json"
        do {
            if try root.fileType(path).exists {
                let digest = try root.fileSHA256(path)
                _ = try root.conditionalRemove(path, expectedSHA256: digest, lease: lease)
            }
        } catch ToolError.notFound {
            // Continue so an external durable receipt cannot survive rollback.
        }
        if let durableRoot {
            let durablePath = "\(durableDirectory)/receipt.json"
            if (try? durableRoot.fileType(durablePath).exists) == true {
                try durableRoot.removeFile(durablePath)
            }
        }
    }

    private func durablePath(for workspacePath: String) throws -> String {
        let prefix = directory + "/"
        guard workspacePath.hasPrefix(prefix) else {
            throw CoboloLoopError.rejected("Cobolo durable mirror path escaped its run directory")
        }
        return durableDirectory + "/" + workspacePath.dropFirst(prefix.count)
    }

    private func mirror(_ workspacePath: String) throws {
        guard let durableRoot,
              (try? root.fileType(workspacePath).exists) == true else { return }
        let data = try root.readStableData(workspacePath, maxBytes: 4_194_304)
        try durableRoot.writeData(
            durablePath(for: workspacePath), data, createParents: true)
    }

    private func hydrate(_ workspacePath: String) throws {
        guard let durableRoot else { return }
        let source = try durablePath(for: workspacePath)
        guard (try? durableRoot.fileType(source).exists) == true else { return }
        try root.writeData(
            workspacePath,
            try durableRoot.readStableData(source, maxBytes: 4_194_304),
            createParents: true)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
