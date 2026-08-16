import Foundation

public enum BuilderMutationKind: String, Codable, Sendable, Hashable, CaseIterable {
    case create, modify, delete
}

public enum BuilderExecutionStage: String, Codable, Sendable, Hashable, CaseIterable {
    case captain, research, peel, council, planning, build, verification, review, promotion
}

public enum BuilderCriterionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case deterministicCommand, artifactDigest, lineageReceipt, modelJudgment, humanApproval, noNewWarnings
}

public enum BuilderExecutionContractError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedVersion(Int)
    case invalidIdentifier(field: String, value: String)
    case invalidPath(String)
    case invalidDigest(field: String)
    case unexpectedCreatePreimage(String)
    case duplicateMutation(String)
    case invalidCriterion(String)
    case duplicateCriterion(String)
    case noRequiredCriterion
    case invalidBudget(String)
    case duplicateStageBudget(BuilderExecutionStage)
    case stageBudgetExceedsTotal(BuilderExecutionStage)
    case missingStageBudget(BuilderExecutionStage)
    case invalidIdentity(String)
    case identityConflict(String)
    case invalidLineage(String)
    case sealUnavailable
    case fingerprintMismatch
    case invalidSeal
    case builderContractMismatch
    case builderNodeMissing(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported builder execution contract version: \(version)"
        case .invalidIdentifier(let field, let value):
            return "Invalid \(field) identifier: \(value)"
        case .invalidPath(let path):
            return "Mutation path must be a normalized project-relative path: \(path)"
        case .invalidDigest(let field):
            return "\(field) must be a canonical, nonzero SHA-256 digest"
        case .unexpectedCreatePreimage(let path):
            return "Create mutation cannot declare a preimage digest: \(path)"
        case .duplicateMutation(let path):
            return "Duplicate or conflicting mutation for path: \(path)"
        case .invalidCriterion(let reason):
            return "Invalid stage criterion: \(reason)"
        case .duplicateCriterion(let id):
            return "Duplicate stage criterion: \(id)"
        case .noRequiredCriterion:
            return "At least one stage criterion must be required"
        case .invalidBudget(let reason):
            return "Invalid builder budget: \(reason)"
        case .duplicateStageBudget(let stage):
            return "Duplicate budget for builder stage: \(stage.rawValue)"
        case .stageBudgetExceedsTotal(let stage):
            return "Budget for \(stage.rawValue) exceeds the total builder budget"
        case .missingStageBudget(let stage):
            return "No budget is declared for criterion stage: \(stage.rawValue)"
        case .invalidIdentity(let reason):
            return "Invalid concrete model identity: \(reason)"
        case .identityConflict(let identity):
            return "Producer/reviewer identity is duplicated or not independent: \(identity)"
        case .invalidLineage(let reason):
            return "Invalid builder lineage: \(reason)"
        case .sealUnavailable:
            return "ForgeSeal key is unavailable; refusing to issue an unsealed builder contract"
        case .fingerprintMismatch:
            return "Builder execution contract fingerprint does not match its canonical content"
        case .invalidSeal:
            return "Builder execution contract ForgeSeal is invalid"
        case .builderContractMismatch:
            return "Builder execution contract is bound to a different BuilderContract"
        case .builderNodeMissing(let nodeID):
            return "Builder execution contract names an unknown graph node: \(nodeID)"
        }
    }
}

enum BuilderExecutionValidation {
    static func identifier(_ raw: String, field: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 256,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                          options: .regularExpression) != nil,
              value != ".", value != ".." else {
            throw BuilderExecutionContractError.invalidIdentifier(field: field, value: raw)
        }
        return value
    }

    static func text(_ raw: String, field: String, limit: Int = 8_192) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= limit,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw BuilderExecutionContractError.invalidCriterion("\(field) is empty, oversized, or contains control characters")
        }
        return value
    }

    static func digest(_ value: String, field: String) throws -> String {
        let canonical = value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
        guard canonical, value.utf8.contains(where: { $0 != 48 }) else {
            throw BuilderExecutionContractError.invalidDigest(field: field)
        }
        return value
    }

    static func path(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.count <= 4_096,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw BuilderExecutionContractError.invalidPath(raw)
        }
        let slashed = raw.replacingOccurrences(of: "\\", with: "/")
        guard !slashed.hasPrefix("/"), !slashed.hasPrefix("~/"),
              !slashed.hasPrefix("//"),
              slashed.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) == nil,
              !slashed.contains("://") else {
            throw BuilderExecutionContractError.invalidPath(raw)
        }
        var components: [String] = []
        for component in slashed.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            guard component != ".." else {
                throw BuilderExecutionContractError.invalidPath(raw)
            }
            components.append(String(component))
        }
        guard !components.isEmpty, components.first != "~" else {
            throw BuilderExecutionContractError.invalidPath(raw)
        }
        return components.joined(separator: "/")
    }

    static func identityPart(_ raw: String, field: String, provider: Bool) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = value.lowercased()
        let placeholders = ["none", "unknown", "default", "current", "auto"]
        guard !value.isEmpty, value.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !placeholders.contains(lowered) else {
            throw BuilderExecutionContractError.invalidIdentity("\(field) must name a concrete value")
        }
        if provider {
            guard lowered.range(of: #"^[a-z0-9][a-z0-9._-]*$"#,
                                options: .regularExpression) != nil else {
                throw BuilderExecutionContractError.invalidIdentity("providerID contains unsupported characters")
            }
            return lowered
        }
        return value
    }
}

public struct BuilderMutationOperation: Codable, Sendable, Equatable, Hashable {
    public let kind: BuilderMutationKind
    public let path: String
    public let preimageSHA256: String?

    public init(kind: BuilderMutationKind, path: String, preimageSHA256: String? = nil) throws {
        let normalized = try BuilderExecutionValidation.path(path)
        if kind == .create, preimageSHA256 != nil {
            throw BuilderExecutionContractError.unexpectedCreatePreimage(normalized)
        }
        self.kind = kind
        self.path = normalized
        self.preimageSHA256 = try preimageSHA256.map {
            try BuilderExecutionValidation.digest($0, field: "preimageSHA256")
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, path, preimageSHA256 }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: values.decode(BuilderMutationKind.self, forKey: .kind),
            path: values.decode(String.self, forKey: .path),
            preimageSHA256: values.decodeIfPresent(String.self, forKey: .preimageSHA256))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(path, forKey: .path)
        if let preimageSHA256 {
            try values.encode(preimageSHA256, forKey: .preimageSHA256)
        } else {
            try values.encodeNil(forKey: .preimageSHA256)
        }
    }
}

public struct BuilderStageCriterion: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let stage: BuilderExecutionStage
    public let kind: BuilderCriterionKind
    public let statement: String
    public let required: Bool

    public init(id: String, stage: BuilderExecutionStage, kind: BuilderCriterionKind,
                statement: String, required: Bool = true) throws {
        self.id = try BuilderExecutionValidation.identifier(id, field: "criterion")
        self.stage = stage
        self.kind = kind
        self.statement = try BuilderExecutionValidation.text(statement, field: "statement")
        self.required = required
    }

    private enum CodingKeys: String, CodingKey { case id, stage, kind, statement, required }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id),
                      stage: values.decode(BuilderExecutionStage.self, forKey: .stage),
                      kind: values.decode(BuilderCriterionKind.self, forKey: .kind),
                      statement: values.decode(String.self, forKey: .statement),
                      required: values.decode(Bool.self, forKey: .required))
    }
}

public struct BuilderResourceBudget: Codable, Sendable, Equatable, Hashable {
    public let maxToolCalls: Int
    public let maxTokens: Int
    public let maxWallTimeSeconds: Int

    public init(maxToolCalls: Int, maxTokens: Int, maxWallTimeSeconds: Int) throws {
        guard maxToolCalls > 0, maxTokens > 0, maxWallTimeSeconds > 0 else {
            throw BuilderExecutionContractError.invalidBudget("tool, token, and wall-time limits must all be positive")
        }
        self.maxToolCalls = maxToolCalls
        self.maxTokens = maxTokens
        self.maxWallTimeSeconds = maxWallTimeSeconds
    }

    private enum CodingKeys: String, CodingKey { case maxToolCalls, maxTokens, maxWallTimeSeconds }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maxToolCalls: values.decode(Int.self, forKey: .maxToolCalls),
                      maxTokens: values.decode(Int.self, forKey: .maxTokens),
                      maxWallTimeSeconds: values.decode(Int.self, forKey: .maxWallTimeSeconds))
    }
}

public struct BuilderStageBudget: Codable, Sendable, Equatable, Hashable {
    public let stage: BuilderExecutionStage
    public let limit: BuilderResourceBudget
    public init(stage: BuilderExecutionStage, limit: BuilderResourceBudget) {
        self.stage = stage
        self.limit = limit
    }
}

public struct BuilderBudgetPolicy: Codable, Sendable, Equatable {
    public let total: BuilderResourceBudget
    public let stages: [BuilderStageBudget]

    public init(total: BuilderResourceBudget, stages: [BuilderStageBudget]) throws {
        guard !stages.isEmpty else {
            throw BuilderExecutionContractError.invalidBudget("at least one per-stage budget is required")
        }
        var seen: Set<BuilderExecutionStage> = []
        for item in stages {
            guard seen.insert(item.stage).inserted else {
                throw BuilderExecutionContractError.duplicateStageBudget(item.stage)
            }
            guard item.limit.maxToolCalls <= total.maxToolCalls,
                  item.limit.maxTokens <= total.maxTokens,
                  item.limit.maxWallTimeSeconds <= total.maxWallTimeSeconds else {
                throw BuilderExecutionContractError.stageBudgetExceedsTotal(item.stage)
            }
        }
        self.total = total
        self.stages = stages.sorted { $0.stage.rawValue < $1.stage.rawValue }
    }

    private enum CodingKeys: String, CodingKey { case total, stages }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(total: values.decode(BuilderResourceBudget.self, forKey: .total),
                      stages: values.decode([BuilderStageBudget].self, forKey: .stages))
    }
}

public struct BuilderModelIdentity: Codable, Sendable, Equatable, Hashable {
    public let providerID: String
    public let modelID: String

    public init(providerID: String, modelID: String) throws {
        self.providerID = try BuilderExecutionValidation.identityPart(
            providerID, field: "providerID", provider: true)
        self.modelID = try BuilderExecutionValidation.identityPart(
            modelID, field: "modelID", provider: false)
    }

    public var canonicalID: String { "\(providerID):\(modelID)" }
    fileprivate var independenceKey: String { modelID.lowercased() }

    private enum CodingKeys: String, CodingKey { case providerID, modelID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(providerID: values.decode(String.self, forKey: .providerID),
                      modelID: values.decode(String.self, forKey: .modelID))
    }
}

public struct BuilderIdentityPlan: Codable, Sendable, Equatable {
    public let producers: [BuilderModelIdentity]
    public let reviewers: [BuilderModelIdentity]

    public init(producers: [BuilderModelIdentity], reviewers: [BuilderModelIdentity]) throws {
        guard !producers.isEmpty, !reviewers.isEmpty else {
            throw BuilderExecutionContractError.invalidIdentity("producer and reviewer lists must both be nonempty")
        }
        var producerModels: Set<String> = []
        for identity in producers {
            guard producerModels.insert(identity.independenceKey).inserted else {
                throw BuilderExecutionContractError.identityConflict(identity.canonicalID)
            }
        }
        var reviewerModels: Set<String> = []
        for identity in reviewers {
            guard !producerModels.contains(identity.independenceKey),
                  reviewerModels.insert(identity.independenceKey).inserted else {
                throw BuilderExecutionContractError.identityConflict(identity.canonicalID)
            }
        }
        self.producers = producers.sorted { $0.canonicalID < $1.canonicalID }
        self.reviewers = reviewers.sorted { $0.canonicalID < $1.canonicalID }
    }

    private enum CodingKeys: String, CodingKey { case producers, reviewers }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(producers: values.decode([BuilderModelIdentity].self, forKey: .producers),
                      reviewers: values.decode([BuilderModelIdentity].self, forKey: .reviewers))
    }
}

public struct BuilderResearchLineage: Codable, Sendable, Equatable, Hashable {
    public let runID: String
    public let dossierDigest: String

    public init(runID: String, dossierDigest: String) throws {
        self.runID = try BuilderExecutionValidation.identifier(runID, field: "research run")
        self.dossierDigest = try BuilderExecutionValidation.digest(
            dossierDigest, field: "research dossier digest")
    }

    private enum CodingKeys: String, CodingKey { case runID, dossierDigest }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(runID: values.decode(String.self, forKey: .runID),
                      dossierDigest: values.decode(String.self, forKey: .dossierDigest))
    }
}

public struct BuilderTaskBoardLineage: Codable, Sendable, Equatable, Hashable {
    public let version: Int
    public let taskIDs: [String]
    public let handoffDigest: String

    public init(version: Int, taskIDs: [String], handoffDigest: String) throws {
        guard version > 0 else {
            throw BuilderExecutionContractError.invalidLineage("task-board version must be positive")
        }
        guard !taskIDs.isEmpty else {
            throw BuilderExecutionContractError.invalidLineage("task-board handoff must name at least one task")
        }
        let normalized = try taskIDs.map {
            try BuilderExecutionValidation.identifier($0, field: "task")
        }
        guard Set(normalized).count == normalized.count else {
            throw BuilderExecutionContractError.invalidLineage("task-board handoff repeats a task ID")
        }
        self.version = version
        self.taskIDs = normalized.sorted()
        self.handoffDigest = try BuilderExecutionValidation.digest(
            handoffDigest, field: "task-board handoff digest")
    }

    private enum CodingKeys: String, CodingKey { case version, taskIDs, handoffDigest }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: values.decode(Int.self, forKey: .version),
                      taskIDs: values.decode([String].self, forKey: .taskIDs),
                      handoffDigest: values.decode(String.self, forKey: .handoffDigest))
    }
}

public struct BuilderLineageEnvelope: Codable, Sendable, Equatable {
    public let captainDecisionDigest: String?
    public let research: BuilderResearchLineage?
    public let peelReceiptDigest: String?
    public let councilArtifactDigest: String?
    public let taskBoard: BuilderTaskBoardLineage?

    public init(captainDecisionDigest: String? = nil,
                research: BuilderResearchLineage? = nil,
                peelReceiptDigest: String? = nil,
                councilArtifactDigest: String? = nil,
                taskBoard: BuilderTaskBoardLineage? = nil) throws {
        if peelReceiptDigest != nil, research == nil {
            throw BuilderExecutionContractError.invalidLineage("PEEL receipt requires research lineage")
        }
        if councilArtifactDigest != nil, peelReceiptDigest == nil {
            throw BuilderExecutionContractError.invalidLineage("council artifact requires a PEEL receipt")
        }
        if taskBoard != nil, councilArtifactDigest == nil {
            throw BuilderExecutionContractError.invalidLineage("task-board handoff requires a council artifact")
        }
        self.captainDecisionDigest = try captainDecisionDigest.map {
            try BuilderExecutionValidation.digest($0, field: "Captain decision digest")
        }
        self.research = research
        self.peelReceiptDigest = try peelReceiptDigest.map {
            try BuilderExecutionValidation.digest($0, field: "PEEL receipt digest")
        }
        self.councilArtifactDigest = try councilArtifactDigest.map {
            try BuilderExecutionValidation.digest($0, field: "council artifact digest")
        }
        self.taskBoard = taskBoard
    }

    private enum CodingKeys: String, CodingKey {
        case captainDecisionDigest, research, peelReceiptDigest, councilArtifactDigest, taskBoard
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            captainDecisionDigest: values.decodeIfPresent(String.self, forKey: .captainDecisionDigest),
            research: values.decodeIfPresent(BuilderResearchLineage.self, forKey: .research),
            peelReceiptDigest: values.decodeIfPresent(String.self, forKey: .peelReceiptDigest),
            councilArtifactDigest: values.decodeIfPresent(String.self, forKey: .councilArtifactDigest),
            taskBoard: values.decodeIfPresent(BuilderTaskBoardLineage.self, forKey: .taskBoard))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let captainDecisionDigest { try values.encode(captainDecisionDigest, forKey: .captainDecisionDigest) }
        else { try values.encodeNil(forKey: .captainDecisionDigest) }
        if let research { try values.encode(research, forKey: .research) }
        else { try values.encodeNil(forKey: .research) }
        if let peelReceiptDigest { try values.encode(peelReceiptDigest, forKey: .peelReceiptDigest) }
        else { try values.encodeNil(forKey: .peelReceiptDigest) }
        if let councilArtifactDigest { try values.encode(councilArtifactDigest, forKey: .councilArtifactDigest) }
        else { try values.encodeNil(forKey: .councilArtifactDigest) }
        if let taskBoard { try values.encode(taskBoard, forKey: .taskBoard) }
        else { try values.encodeNil(forKey: .taskBoard) }
    }
}

public struct BuilderExecutionContract: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let builderContractID: String
    public let builderNodeID: String
    public let mutations: [BuilderMutationOperation]
    public let criteria: [BuilderStageCriterion]
    public let budgets: BuilderBudgetPolicy
    public let identities: BuilderIdentityPlan
    public let lineage: BuilderLineageEnvelope

    public init(builderContractID: String, builderNodeID: String,
                mutations: [BuilderMutationOperation], criteria: [BuilderStageCriterion],
                budgets: BuilderBudgetPolicy, identities: BuilderIdentityPlan,
                lineage: BuilderLineageEnvelope) throws {
        try self.init(schemaVersion: Self.currentSchemaVersion,
                      builderContractID: builderContractID, builderNodeID: builderNodeID,
                      mutations: mutations, criteria: criteria, budgets: budgets,
                      identities: identities, lineage: lineage)
    }

    private init(schemaVersion: Int, builderContractID: String, builderNodeID: String,
                 mutations: [BuilderMutationOperation], criteria: [BuilderStageCriterion],
                 budgets: BuilderBudgetPolicy, identities: BuilderIdentityPlan,
                 lineage: BuilderLineageEnvelope) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw BuilderExecutionContractError.unsupportedVersion(schemaVersion)
        }
        let contractID = try BuilderExecutionValidation.identifier(
            builderContractID, field: "Builder contract")
        let nodeID = try BuilderExecutionValidation.identifier(builderNodeID, field: "Builder node")
        var mutationPaths: Set<String> = []
        for mutation in mutations {
            guard mutationPaths.insert(mutation.path).inserted else {
                throw BuilderExecutionContractError.duplicateMutation(mutation.path)
            }
        }
        guard !criteria.isEmpty else {
            throw BuilderExecutionContractError.invalidCriterion("at least one criterion is required")
        }
        var criterionIDs: Set<String> = []
        for criterion in criteria {
            guard criterionIDs.insert(criterion.id).inserted else {
                throw BuilderExecutionContractError.duplicateCriterion(criterion.id)
            }
        }
        guard criteria.contains(where: \.required) else {
            throw BuilderExecutionContractError.noRequiredCriterion
        }
        let budgetedStages = Set(budgets.stages.map(\.stage))
        for stage in Set(criteria.map(\.stage)) where !budgetedStages.contains(stage) {
            throw BuilderExecutionContractError.missingStageBudget(stage)
        }
        self.schemaVersion = schemaVersion
        self.builderContractID = contractID
        self.builderNodeID = nodeID
        self.mutations = mutations.sorted {
            $0.path == $1.path ? $0.kind.rawValue < $1.kind.rawValue : $0.path < $1.path
        }
        self.criteria = criteria.sorted {
            $0.stage.rawValue == $1.stage.rawValue ? $0.id < $1.id : $0.stage.rawValue < $1.stage.rawValue
        }
        self.budgets = budgets
        self.identities = identities
        self.lineage = lineage
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, builderContractID, builderNodeID, mutations, criteria, budgets, identities, lineage
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
            builderContractID: values.decode(String.self, forKey: .builderContractID),
            builderNodeID: values.decode(String.self, forKey: .builderNodeID),
            mutations: values.decode([BuilderMutationOperation].self, forKey: .mutations),
            criteria: values.decode([BuilderStageCriterion].self, forKey: .criteria),
            budgets: values.decode(BuilderBudgetPolicy.self, forKey: .budgets),
            identities: values.decode(BuilderIdentityPlan.self, forKey: .identities),
            lineage: values.decode(BuilderLineageEnvelope.self, forKey: .lineage))
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func fingerprint() throws -> String {
        BuilderEvidenceDigest.sha256(String(decoding: try canonicalData(), as: UTF8.self))
    }
}

public struct SealedBuilderExecutionContract: Codable, Sendable, Equatable {
    public let contract: BuilderExecutionContract
    public let fingerprint: String
    public let seal: String

    public static func issue(_ contract: BuilderExecutionContract) throws -> Self {
        let canonical = String(decoding: try contract.canonicalData(), as: UTF8.self)
        let fingerprint = BuilderEvidenceDigest.sha256(canonical)
        let seal = ForgeSeal.sign(canonical)
        guard !seal.isEmpty else { throw BuilderExecutionContractError.sealUnavailable }
        return Self(contract: contract, fingerprint: fingerprint, seal: seal)
    }

    public func validate(builderContractID: String, graphNodeIDs: [String]) throws {
        let canonical = String(decoding: try contract.canonicalData(), as: UTF8.self)
        guard BuilderEvidenceDigest.sha256(canonical) == fingerprint else {
            throw BuilderExecutionContractError.fingerprintMismatch
        }
        guard ForgeSeal.verify(canonical, seal: seal) else {
            throw BuilderExecutionContractError.invalidSeal
        }
        guard contract.builderContractID == builderContractID else {
            throw BuilderExecutionContractError.builderContractMismatch
        }
        guard graphNodeIDs.contains(contract.builderNodeID) else {
            throw BuilderExecutionContractError.builderNodeMissing(contract.builderNodeID)
        }
    }
}
