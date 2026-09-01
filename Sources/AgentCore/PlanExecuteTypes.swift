import Foundation
// Cross-platform crypto: swift-crypto's `Crypto` (CryptoKit-compatible, Linux-safe).
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// PlanExecute VALUE TYPES (mission id, launch mode, outcomes, supporting obligations/receipts, final
// verification invocation/receipt, completion contract) extracted from PlanExecuteLoop.swift to keep the
// loop core under the size limit. Pure data types shared with the loop.

/// Opaque identity of one logical PlanExecute mission. It is an identifier, not a credential.
public struct PlanExecuteMissionID: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.count == 64,
              rawValue == rawValue.lowercased(),
              rawValue.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else { return nil }
        self.rawValue = rawValue
    }

    public static func fresh() -> PlanExecuteMissionID {
        let key = SymmetricKey(size: .bits256)
        let value = key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        return PlanExecuteMissionID(rawValue: value)!
    }
}

public enum PlanExecuteLaunchMode: Sendable, Equatable {
    case fresh
    case resume(PlanExecuteMissionID)
}

/// Outcome of a plan→execute run.
public struct PlanOutcome: Sendable {
    public let success: Bool
    public let plan: ExecutablePlan?      // the last plan that ran (nil if none could be produced)
    public let execution: PlanExecution?  // the last execution (nil if aborted before executing)
    public let message: String
    public let replansUsed: Int           // how many times the loop revised the plan
    /// R1: true when the run stopped because the USER interrupted (ESC), not because the goal
    /// failed. Callers must not record failure lessons/episodes for interrupted runs — a user
    /// cancel is zero evidence about the goal (structured flag, never sniff the message string).
    public var interrupted: Bool = false
    /// Stable durable reasoning checkpoint used by this run.
    public var checkpointId: String? = nil
    /// Stable across replans and explicit recovery, unique across fresh user invocations.
    public var missionInstanceID: String? = nil
    /// A host-consumable receipt minted only by a successful, non-mutating exact replay after the
    /// final observed mutation frontier. Ordinary plan attempts and exit-1 domain probes never
    /// populate this field.
    public var finalVerificationReceipt: PlanFinalVerificationReceipt? = nil
    /// Host-declared obligations are independent of the receipts that claim to satisfy them. This lets
    /// an outer gate detect omitted evidence rather than inferring the required set from what happened.
    public var requiredSupportingObligations: [PlanSupportingObligation] = []
    /// Every successful structured run_command attempt retained across replans and durable resume.
    public var supportingCommandReceipts: [PlanSupportingCommandReceipt] = []
}

public enum PlanSupportingObligationKind: String, Sendable, Equatable, Codable {
    case build
    case fixtureFileInput = "fixture-file-input"
    case expectedDomainFailure = "expected-domain-failure"
    case structuredStandardInput = "structured-standard-input"
    case custom
}

public struct PlanSupportingObligation: Sendable, Equatable, Codable {
    public let id: String
    public let kind: PlanSupportingObligationKind

    public init(id: String, kind: PlanSupportingObligationKind) {
        self.id = id
        self.kind = kind
    }
}

/// Contract-bound supporting evidence for one successful structured command. It deliberately stores
/// only a digest and byte count for stdin, and a redacted bounded output excerpt.
public struct PlanSupportingCommandReceipt: Sendable, Equatable, Codable {
    /// Optional only for decoding legacy receipts; current receipts always bind a mission ID.
    public let missionInstanceID: String?
    public let contractID: String
    public let captureOrdinal: Int
    public let mutationFrontierOrdinal: Int?
    public let stepID: String
    public let tool: String
    public let executable: String
    public let argv: [String]
    public let workingDirectory: String?
    public let hasStandardInput: Bool
    public let standardInputDigest: String?
    public let standardInputByteCount: Int
    public let standardInputSourceKind: PlanStandardInputSourceKind
    public let standardInputRelativePath: String?
    public let allowedExitCodes: [Int]
    public let actualExitCode: Int
    public let wasSignalled: Bool
    public let timedOut: Bool
    public let semanticStatus: String
    public let verificationEligible: Bool
    public let success: Bool
    public let argsFingerprint: String
    public let commandFingerprint: String
    public let outputDigest: String
    public var trustedCommandReference: BuilderTrustedCommandReference? = nil
    public let boundedRedactedOutputExcerpt: String
    public let effectObservation: ToolEffectObservation
    public let executionPhase: Int?
    public let completedAt: Date
    public let completionContractFingerprint: String
    public let obligationsFingerprint: String
    public let executionPolicyFingerprint: String
    public let workspaceManifestDigest: String
    public let governedWorkspaceDigest: String
    public let satisfiedObligationIDs: [String]
    public var canonicalFunctionalObjectiveFingerprint: String? = nil
    public var workspaceManifestPolicyFingerprint: String? = nil
    public var workspaceManifestRevision: Int? = nil
    public var planID: String? = nil
    public var planRevision: Int? = nil
    public var workspaceActionReceiptDigest: String? = nil
    public var evidenceDigest: String = ""

    public init(
        missionInstanceID: String? = nil,
        contractID: String, captureOrdinal: Int, mutationFrontierOrdinal: Int? = nil,
        stepID: String, tool: String = "run_command", executable: String, argv: [String],
        workingDirectory: String? = nil, hasStandardInput: Bool,
        standardInputDigest: String? = nil, standardInputByteCount: Int,
        standardInputSourceKind: PlanStandardInputSourceKind = .none,
        standardInputRelativePath: String? = nil,
        allowedExitCodes: [Int], actualExitCode: Int, wasSignalled: Bool, timedOut: Bool,
        semanticStatus: String, verificationEligible: Bool, success: Bool,
        argsFingerprint: String, commandFingerprint: String, outputDigest: String,
        boundedRedactedOutputExcerpt: String, effectObservation: ToolEffectObservation,
        executionPhase: Int? = nil, completedAt: Date,
        completionContractFingerprint: String, obligationsFingerprint: String,
        executionPolicyFingerprint: String, workspaceManifestDigest: String,
        governedWorkspaceDigest: String, satisfiedObligationIDs: [String],
        canonicalFunctionalObjectiveFingerprint: String? = nil,
        workspaceManifestPolicyFingerprint: String? = nil,
        workspaceManifestRevision: Int? = nil,
        planID: String? = nil,
        planRevision: Int? = nil,
        workspaceActionReceiptDigest: String? = nil,
        trustedCommandReference: BuilderTrustedCommandReference? = nil
    ) {
        self.missionInstanceID = missionInstanceID
        self.contractID = contractID
        self.captureOrdinal = captureOrdinal
        self.mutationFrontierOrdinal = mutationFrontierOrdinal
        self.stepID = stepID
        self.tool = tool
        self.executable = executable
        self.argv = argv
        self.workingDirectory = workingDirectory
        self.hasStandardInput = hasStandardInput
        self.standardInputDigest = standardInputDigest
        self.standardInputByteCount = standardInputByteCount
        self.standardInputSourceKind = standardInputSourceKind
        self.standardInputRelativePath = standardInputRelativePath
        self.allowedExitCodes = allowedExitCodes
        self.actualExitCode = actualExitCode
        self.wasSignalled = wasSignalled
        self.timedOut = timedOut
        self.semanticStatus = semanticStatus
        self.verificationEligible = verificationEligible
        self.success = success
        self.argsFingerprint = argsFingerprint
        self.commandFingerprint = commandFingerprint
        self.outputDigest = outputDigest
        self.trustedCommandReference = trustedCommandReference
        self.boundedRedactedOutputExcerpt = boundedRedactedOutputExcerpt
        self.effectObservation = effectObservation
        self.executionPhase = executionPhase
        self.completedAt = completedAt
        self.completionContractFingerprint = completionContractFingerprint
        self.obligationsFingerprint = obligationsFingerprint
        self.executionPolicyFingerprint = executionPolicyFingerprint
        self.workspaceManifestDigest = workspaceManifestDigest
        self.governedWorkspaceDigest = governedWorkspaceDigest
        self.satisfiedObligationIDs = satisfiedObligationIDs
        self.canonicalFunctionalObjectiveFingerprint = canonicalFunctionalObjectiveFingerprint
        self.workspaceManifestPolicyFingerprint = workspaceManifestPolicyFingerprint
        self.workspaceManifestRevision = workspaceManifestRevision
        self.planID = planID
        self.planRevision = planRevision
        self.workspaceActionReceiptDigest = workspaceActionReceiptDigest
        self.evidenceDigest = ""
        self.evidenceDigest = computedEvidenceDigest
    }

    public var computedEvidenceDigest: String {
        planEvidenceDigest([
            "missionInstanceID": missionInstanceID as Any? ?? NSNull(),
            "contractID": contractID, "captureOrdinal": captureOrdinal,
            "mutationFrontierOrdinal": mutationFrontierOrdinal as Any? ?? NSNull(),
            "stepID": stepID, "tool": tool, "executable": executable, "argv": argv,
            "workingDirectory": workingDirectory as Any? ?? NSNull(),
            "hasStandardInput": hasStandardInput,
            "standardInputDigest": standardInputDigest as Any? ?? NSNull(),
            "standardInputByteCount": standardInputByteCount,
            "standardInputSourceKind": standardInputSourceKind.rawValue,
            "standardInputRelativePath": standardInputRelativePath as Any? ?? NSNull(),
            "allowedExitCodes": allowedExitCodes, "actualExitCode": actualExitCode,
            "wasSignalled": wasSignalled, "timedOut": timedOut,
            "semanticStatus": semanticStatus, "verificationEligible": verificationEligible,
            "success": success, "argsFingerprint": argsFingerprint,
            "commandFingerprint": commandFingerprint, "outputDigest": outputDigest,
            "boundedRedactedOutputExcerpt": boundedRedactedOutputExcerpt,
            "effectMutation": effectObservation.mutation.rawValue,
            "effectVerification": effectObservation.verification.rawValue,
            "effectProgress": effectObservation.progress.rawValue,
            "effectMutationEvidence": effectObservation.mutationEvidence.rawValue,
            "executionPhase": executionPhase as Any? ?? NSNull(),
            "completedAtBits": String(completedAt.timeIntervalSince1970.bitPattern),
            "completionContractFingerprint": completionContractFingerprint,
            "obligationsFingerprint": obligationsFingerprint,
            "executionPolicyFingerprint": executionPolicyFingerprint,
            "workspaceManifestDigest": workspaceManifestDigest,
            "governedWorkspaceDigest": governedWorkspaceDigest,
            "satisfiedObligationIDs": satisfiedObligationIDs.sorted(),
            "canonicalFunctionalObjectiveFingerprint":
                canonicalFunctionalObjectiveFingerprint as Any? ?? NSNull(),
            "workspaceManifestPolicyFingerprint":
                workspaceManifestPolicyFingerprint as Any? ?? NSNull(),
            "workspaceManifestRevision": workspaceManifestRevision as Any? ?? NSNull(),
            "planID": planID as Any? ?? NSNull(),
            "planRevision": planRevision as Any? ?? NSNull(),
            "workspaceActionReceiptDigest": workspaceActionReceiptDigest as Any? ?? NSNull(),
            "trustedCommandReference": trustedCommandReference.flatMap {
                try? BuilderDurableIO.canonicalData($0)
            }.map { String(decoding: $0, as: UTF8.self) } as Any? ?? NSNull(),
        ])
    }

    public var hasValidEvidenceDigest: Bool {
        !evidenceDigest.isEmpty && evidenceDigest == computedEvidenceDigest
    }

    public func validatesBinding(
        missionInstanceID expectedMissionInstanceID: String,
        contractID expectedContractID: String,
        completionContractFingerprint expectedCompletion: String,
        obligationsFingerprint expectedObligations: String,
        executionPolicyFingerprint expectedPolicy: String,
        workspaceManifestDigest expectedManifest: String,
        governedWorkspaceDigest expectedWorkspace: String,
        requiredObligationIDs: Set<String>,
        beforeFinalCaptureOrdinal: Int? = nil,
        canonicalFunctionalObjectiveFingerprint expectedObjective: String? = nil,
        workspaceManifestPolicyFingerprint expectedManifestPolicy: String? = nil,
        maximumWorkspaceManifestRevision: Int? = nil
    ) -> Bool {
        !expectedMissionInstanceID.isEmpty && missionInstanceID == expectedMissionInstanceID
            && hasValidEvidenceDigest && success && tool == "run_command" && !executable.isEmpty
            && trustedCommandReference?.isValid == true
            && trustedCommandReference?.exitCode == actualExitCode
            && trustedCommandReference?.timedOut == timedOut
            && trustedCommandReference?.wasSignalled == wasSignalled
            && allowedExitCodes.contains(actualExitCode) && !wasSignalled && !timedOut
            && contractID == expectedContractID
            && completionContractFingerprint == expectedCompletion
            && obligationsFingerprint == expectedObligations
            && executionPolicyFingerprint == expectedPolicy
            && workspaceManifestDigest == expectedManifest
            && governedWorkspaceDigest == expectedWorkspace
            && (expectedObjective.map { canonicalFunctionalObjectiveFingerprint == $0 } ?? true)
            && (expectedManifestPolicy.map { workspaceManifestPolicyFingerprint == $0 } ?? true)
            && (maximumWorkspaceManifestRevision.map { maximum in
                workspaceManifestRevision.map { $0 <= maximum } ?? false
            } ?? true)
            && (expectedObjective == nil || planID?.isEmpty == false)
            && (expectedObjective == nil || planRevision != nil)
            && (expectedObjective == nil || workspaceActionReceiptDigest?.isEmpty == false)
            && Set(satisfiedObligationIDs).isSubset(of: requiredObligationIDs)
            && (beforeFinalCaptureOrdinal.map { captureOrdinal < $0 } ?? true)
            && (hasStandardInput
                ? standardInputDigest?.isEmpty == false && standardInputByteCount > 0
                    && standardInputSourceKind != .none
                    && (standardInputSourceKind == .governedPath
                        ? standardInputRelativePath?.isEmpty == false
                        : standardInputRelativePath == nil)
                : standardInputDigest == nil && standardInputByteCount == 0
                    && standardInputSourceKind == .none && standardInputRelativePath == nil)
            && (semanticStatus != "expected_domain_status" || !verificationEligible)
    }
}

public struct PlanFinalVerificationInvocation: Sendable, Equatable, Codable {
    // stdin_path evidence is stored below as kind/path/count/digest; raw bytes are never durable.
    public let executable: String
    public let argv: [String]
    public let workingDirectory: String?
    public let hasStandardInput: Bool
    public let standardInputDigest: String?
    public let standardInputSourceKind: PlanStandardInputSourceKind
    public let standardInputRelativePath: String?
    public let standardInputByteCount: Int

    public init(executable: String, argv: [String], workingDirectory: String? = nil,
                hasStandardInput: Bool, standardInputDigest: String? = nil,
                standardInputSourceKind: PlanStandardInputSourceKind = .none,
                standardInputRelativePath: String? = nil,
                standardInputByteCount: Int = 0) {
        self.executable = executable
        self.argv = argv
        self.workingDirectory = workingDirectory
        self.hasStandardInput = hasStandardInput
        self.standardInputDigest = standardInputDigest
        self.standardInputSourceKind = standardInputSourceKind
        self.standardInputRelativePath = standardInputRelativePath
        self.standardInputByteCount = standardInputByteCount
    }
}

public struct PlanFinalVerificationReceipt: Sendable, Equatable, Codable {
    /// Optional only for decoding legacy receipts; current receipts always bind a mission ID.
    public let missionInstanceID: String?
    public let contractID: String
    public let stepID: String
    public let tool: String
    public let invocation: PlanFinalVerificationInvocation
    public let commandFingerprint: String
    public let expectedExitCode: Int
    public let actualExitCode: Int
    public let outputDigest: String
    public var trustedCommandReference: BuilderTrustedCommandReference? = nil
    public let boundedRedactedOutputExcerpt: String
    public let governedWorkspaceDigest: String
    public let completionContractFingerprint: String
    public let executionPolicyFingerprint: String
    public let verifiedAt: Date
    public let freshAfterMutationFrontier: Bool
    public var captureOrdinal: Int = 0
    public var mutationFrontierOrdinal: Int? = nil
    public var obligationsFingerprint: String = ""
    public var workspaceManifestDigest: String = ""
    public var canonicalFunctionalObjectiveFingerprint: String? = nil
    public var workspaceManifestPolicyFingerprint: String? = nil
    public var workspaceManifestRevision: Int? = nil
    public var planID: String? = nil
    public var planRevision: Int? = nil
    public var workspaceActionReceiptDigest: String? = nil
    public var evidenceDigest: String = ""

    public init(
        missionInstanceID: String? = nil,
        contractID: String, stepID: String, tool: String,
        invocation: PlanFinalVerificationInvocation, commandFingerprint: String,
        expectedExitCode: Int, actualExitCode: Int, outputDigest: String,
        boundedRedactedOutputExcerpt: String, governedWorkspaceDigest: String,
        completionContractFingerprint: String, executionPolicyFingerprint: String,
        verifiedAt: Date, freshAfterMutationFrontier: Bool,
        captureOrdinal: Int = 0, mutationFrontierOrdinal: Int? = nil,
        obligationsFingerprint: String = "", workspaceManifestDigest: String = "",
        canonicalFunctionalObjectiveFingerprint: String? = nil,
        workspaceManifestPolicyFingerprint: String? = nil,
        workspaceManifestRevision: Int? = nil,
        planID: String? = nil,
        planRevision: Int? = nil,
        workspaceActionReceiptDigest: String? = nil,
        trustedCommandReference: BuilderTrustedCommandReference? = nil
    ) {
        self.missionInstanceID = missionInstanceID
        self.contractID = contractID
        self.stepID = stepID
        self.tool = tool
        self.invocation = invocation
        self.commandFingerprint = commandFingerprint
        self.expectedExitCode = expectedExitCode
        self.actualExitCode = actualExitCode
        self.outputDigest = outputDigest
        self.trustedCommandReference = trustedCommandReference
        self.boundedRedactedOutputExcerpt = boundedRedactedOutputExcerpt
        self.governedWorkspaceDigest = governedWorkspaceDigest
        self.completionContractFingerprint = completionContractFingerprint
        self.executionPolicyFingerprint = executionPolicyFingerprint
        self.verifiedAt = verifiedAt
        self.freshAfterMutationFrontier = freshAfterMutationFrontier
        self.captureOrdinal = captureOrdinal
        self.mutationFrontierOrdinal = mutationFrontierOrdinal
        self.obligationsFingerprint = obligationsFingerprint
        self.workspaceManifestDigest = workspaceManifestDigest
        self.canonicalFunctionalObjectiveFingerprint = canonicalFunctionalObjectiveFingerprint
        self.workspaceManifestPolicyFingerprint = workspaceManifestPolicyFingerprint
        self.workspaceManifestRevision = workspaceManifestRevision
        self.planID = planID
        self.planRevision = planRevision
        self.workspaceActionReceiptDigest = workspaceActionReceiptDigest
        self.evidenceDigest = ""
        self.evidenceDigest = computedEvidenceDigest
    }

    public var computedEvidenceDigest: String {
        planEvidenceDigest([
            "missionInstanceID": missionInstanceID as Any? ?? NSNull(),
            "contractID": contractID, "stepID": stepID, "tool": tool,
            "executable": invocation.executable, "argv": invocation.argv,
            "workingDirectory": invocation.workingDirectory as Any? ?? NSNull(),
            "hasStandardInput": invocation.hasStandardInput,
            "standardInputDigest": invocation.standardInputDigest as Any? ?? NSNull(),
            "standardInputSourceKind": invocation.standardInputSourceKind.rawValue,
            "standardInputRelativePath": invocation.standardInputRelativePath as Any? ?? NSNull(),
            "standardInputByteCount": invocation.standardInputByteCount,
            "commandFingerprint": commandFingerprint,
            "expectedExitCode": expectedExitCode, "actualExitCode": actualExitCode,
            "outputDigest": outputDigest,
            "boundedRedactedOutputExcerpt": boundedRedactedOutputExcerpt,
            "governedWorkspaceDigest": governedWorkspaceDigest,
            "completionContractFingerprint": completionContractFingerprint,
            "executionPolicyFingerprint": executionPolicyFingerprint,
            "verifiedAtBits": String(verifiedAt.timeIntervalSince1970.bitPattern),
            "freshAfterMutationFrontier": freshAfterMutationFrontier,
            "captureOrdinal": captureOrdinal,
            "mutationFrontierOrdinal": mutationFrontierOrdinal as Any? ?? NSNull(),
            "obligationsFingerprint": obligationsFingerprint,
            "workspaceManifestDigest": workspaceManifestDigest,
            "canonicalFunctionalObjectiveFingerprint":
                canonicalFunctionalObjectiveFingerprint as Any? ?? NSNull(),
            "workspaceManifestPolicyFingerprint":
                workspaceManifestPolicyFingerprint as Any? ?? NSNull(),
            "workspaceManifestRevision": workspaceManifestRevision as Any? ?? NSNull(),
            "planID": planID as Any? ?? NSNull(),
            "planRevision": planRevision as Any? ?? NSNull(),
            "workspaceActionReceiptDigest": workspaceActionReceiptDigest as Any? ?? NSNull(),
            "trustedCommandReference": trustedCommandReference.flatMap {
                try? BuilderDurableIO.canonicalData($0)
            }.map { String(decoding: $0, as: UTF8.self) } as Any? ?? NSNull(),
        ])
    }

    public var hasValidEvidenceDigest: Bool {
        !evidenceDigest.isEmpty && evidenceDigest == computedEvidenceDigest
    }

    public func validatesBinding(
        missionInstanceID expectedMissionInstanceID: String,
        contractID expectedContractID: String,
        completionContractFingerprint expectedCompletion: String,
        obligationsFingerprint expectedObligations: String,
        executionPolicyFingerprint expectedPolicy: String,
        workspaceManifestDigest expectedManifest: String,
        governedWorkspaceDigest expectedWorkspace: String,
        canonicalFunctionalObjectiveFingerprint expectedObjective: String? = nil,
        workspaceManifestPolicyFingerprint expectedManifestPolicy: String? = nil,
        workspaceManifestRevision expectedManifestRevision: Int? = nil
    ) -> Bool {
        !expectedMissionInstanceID.isEmpty && missionInstanceID == expectedMissionInstanceID
            && hasValidEvidenceDigest && tool == "run_command" && freshAfterMutationFrontier
            && trustedCommandReference?.isValid == true
            && trustedCommandReference?.exitCode == actualExitCode
            && expectedExitCode == 0 && actualExitCode == 0 && captureOrdinal > 0
            && mutationFrontierOrdinal.map { captureOrdinal > $0 } ?? true
            && contractID == expectedContractID
            && completionContractFingerprint == expectedCompletion
            && obligationsFingerprint == expectedObligations
            && executionPolicyFingerprint == expectedPolicy
            && workspaceManifestDigest == expectedManifest
            && governedWorkspaceDigest == expectedWorkspace
            && (expectedObjective.map { canonicalFunctionalObjectiveFingerprint == $0 } ?? true)
            && (expectedManifestPolicy.map { workspaceManifestPolicyFingerprint == $0 } ?? true)
            && (expectedManifestRevision.map { workspaceManifestRevision == $0 } ?? true)
            && (expectedObjective == nil || planID?.isEmpty == false)
            && (expectedObjective == nil || planRevision != nil)
            && (expectedObjective == nil || workspaceActionReceiptDigest?.isEmpty == false)
            && (invocation.hasStandardInput
                ? invocation.standardInputSourceKind != .none
                    && invocation.standardInputDigest?.isEmpty == false
                    && invocation.standardInputByteCount > 0
                    && (invocation.standardInputSourceKind == .governedPath
                        ? invocation.standardInputRelativePath?.isEmpty == false
                        : invocation.standardInputRelativePath == nil)
                : invocation.standardInputSourceKind == .none
                    && invocation.standardInputDigest == nil
                    && invocation.standardInputRelativePath == nil
                    && invocation.standardInputByteCount == 0)
    }
}

/// The immutable effect contract for one plan-execute mission. Execution mode answers HOW work runs;
/// it must not silently rewrite WHAT the user requested into a mutation. In particular, an explicit
/// verification-only audit promises fresh build/test evidence while promising no governed workspace edit.
public struct PlanExecuteCompletionContract: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case mutationBuild = "mutation-build"
        case verificationOnly = "verification-only"
        case evidence
        case externalAction = "external-action"
        case delegation
        case answer
    }

    public let kind: Kind
    public let requestedIntent: TaskBrief.Intent
    public let expectedOutcome: TaskBrief.ExpectedOutcome
    public let canonicalRequestFingerprint: String
    public let fingerprint: String

    public var requiresMutation: Bool { kind == .mutationBuild }
    public var requiresFreshVerification: Bool { kind == .verificationOnly }

    /// Derive from the canonical USER request, never from a memory/council/stage-wrapped planner goal.
    public static func derive(canonicalRequest raw: String) -> Self {
        let request = PromptCompiler.originalRequest(fromCompiledPrompt: raw) ?? raw
        let normalized = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        let intent = PromptCompiler.inferIntent(normalized, mode: .inline)
        let ordinaryOutcome = PromptCompiler.expectedOutcome(intent: intent, mode: .inline)
        let asksForVerification = [
            "verify", "verification", "run the build", "run build", "run the tests", "run tests",
            "build/test", "build and test", "test the existing",
        ].contains { lower.contains($0) }
        let forbidsUnneededEdits = [
            "verification-only", "read-only", "without edit", "without chang", "do not edit",
            "don't edit", "do not change", "don't change", "no edits", "no changes", "no writes",
        ].contains { lower.contains($0) }

        let kind: Kind
        let outcome: TaskBrief.ExpectedOutcome
        // The parent contract remains delegation even when the delegated child task contains
        // verification/read-only wording. Child execution language must never authorize the parent
        // PlanExecutor to perform that work locally.
        if ordinaryOutcome == .delegation {
            kind = .delegation
            outcome = .delegation
        } else if asksForVerification && forbidsUnneededEdits {
            kind = .verificationOnly
            outcome = .answer
        } else {
            outcome = ordinaryOutcome
            switch ordinaryOutcome {
            case .mutation: kind = .mutationBuild
            case .evidence: kind = .evidence
            case .externalAction: kind = .externalAction
            case .delegation: kind = .delegation
            case .answer, .plan: kind = .answer
            }
        }
        let requestFingerprint = digest(normalized)
        let contractFingerprint = digest([
            kind.rawValue, intent.rawValue, outcome.rawValue, requestFingerprint,
        ].joined(separator: "\u{0}"))
        return Self(kind: kind, requestedIntent: intent, expectedOutcome: outcome,
                    canonicalRequestFingerprint: requestFingerprint, fingerprint: contractFingerprint)
    }

    /// Remove only clauses owned by the outer BuilderRun final-review stage. Functional clauses are
    /// retained even when joined by "and" (the live goal's valid/invalid fixtures and stdin checks).
    public static func functionalObjective(from raw: String) -> String {
        let request = PromptCompiler.originalRequest(fromCompiledPrompt: raw) ?? raw
        let separated = request
            .replacingOccurrences(of: " and then ", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: ". ", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
        let hostReviewMarkers = [
            "independent final review", "independent review", "final independent review",
            "final review", "distinct review", "distinct reviewer", "authoritative review",
            "promotion review", "reviewer identity", "reviewer identities", "self-review", "self review",
            "builderrun verification",
        ]
        let functional = separated.split(separator: "\n").flatMap { rawClause -> [String] in
            let clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = clause.lowercased()
            guard hostReviewMarkers.contains(where: lower.contains) else {
                return clause.isEmpty ? [] : [clause]
            }
            // Split conjunctions only inside a clause that actually contains host-review language.
            // This preserves functional phrases such as "valid and invalid fixture inputs".
            return clause.replacingOccurrences(of: " and ", with: "\n", options: .caseInsensitive)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { part in
                    let partLower = part.lowercased()
                    return !part.isEmpty && !hostReviewMarkers.contains(where: partLower.contains)
                }
        }
            .joined(separator: ". ")
        return functional.isEmpty
            ? "Execute and verify the objective's functional requirements only."
            : functional
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
