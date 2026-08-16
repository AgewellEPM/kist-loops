import Foundation

public enum BuilderBudgetObservationSource: Codable, Sendable, Equatable {
    case tool(String)
    case provider(BuilderModelIdentity)
    case clock
}

public struct BuilderTrustedBudgetObservation: Codable, Sendable, Equatable {
    public let id: String
    public let contractFingerprint: String
    public let nodeID: String
    public let attempt: Int
    public let stage: BuilderExecutionStage
    public let source: BuilderBudgetObservationSource
    public let toolCalls: Int
    public let tokens: Int
    public let wallTimeMilliseconds: Int
    public let telemetrySeal: String?

    public init(id: String, contractFingerprint: String, nodeID: String, attempt: Int,
                stage: BuilderExecutionStage, source: BuilderBudgetObservationSource,
                toolCalls: Int = 0, tokens: Int = 0, wallTimeMilliseconds: Int = 0,
                telemetrySeal: String? = nil) throws {
        self.id = try BuilderExecutionValidation.identifier(id, field: "budget observation")
        self.contractFingerprint = try BuilderExecutionValidation.digest(
            contractFingerprint, field: "contract fingerprint")
        self.nodeID = try BuilderExecutionValidation.identifier(nodeID, field: "budget node")
        guard attempt > 0, toolCalls >= 0, tokens >= 0, wallTimeMilliseconds >= 0,
              toolCalls > 0 || tokens > 0 || wallTimeMilliseconds > 0 else {
            throw BuilderBudgetLedgerError.invalidObservation("attempt and usage deltas must be positive")
        }
        switch source {
        case .tool(let name):
            _ = try BuilderExecutionValidation.identifier(name, field: "tool")
            guard toolCalls > 0, tokens == 0 else {
                throw BuilderBudgetLedgerError.invalidObservation("tool observations only meter tool calls and time")
            }
        case .provider:
            guard toolCalls == 0, tokens > 0 else {
                throw BuilderBudgetLedgerError.invalidObservation("provider observations require measured tokens")
            }
        case .clock:
            guard toolCalls == 0, tokens == 0, wallTimeMilliseconds > 0 else {
                throw BuilderBudgetLedgerError.invalidObservation("clock observations only meter elapsed time")
            }
        }
        self.attempt = attempt
        self.stage = stage
        self.source = source
        self.toolCalls = toolCalls
        self.tokens = tokens
        self.wallTimeMilliseconds = wallTimeMilliseconds
        self.telemetrySeal = telemetrySeal
    }

    func fingerprint() throws -> String {
        BuilderEvidenceDigest.sha256(String(decoding: try BuilderDurableIO.canonicalData(self), as: UTF8.self))
    }
}

public struct BuilderBudgetUsage: Codable, Sendable, Equatable {
    public let toolCalls: Int
    public let tokens: Int
    public let wallTimeMilliseconds: Int
    public static let zero = Self(toolCalls: 0, tokens: 0, wallTimeMilliseconds: 0)

    init(toolCalls: Int, tokens: Int, wallTimeMilliseconds: Int) {
        self.toolCalls = toolCalls
        self.tokens = tokens
        self.wallTimeMilliseconds = wallTimeMilliseconds
    }

    func adding(_ observation: BuilderTrustedBudgetObservation) throws -> Self {
        let (tools, toolOverflow) = toolCalls.addingReportingOverflow(observation.toolCalls)
        let (newTokens, tokenOverflow) = tokens.addingReportingOverflow(observation.tokens)
        let (time, timeOverflow) = wallTimeMilliseconds.addingReportingOverflow(observation.wallTimeMilliseconds)
        guard !toolOverflow, !tokenOverflow, !timeOverflow else {
            throw BuilderBudgetLedgerError.overflow
        }
        return Self(toolCalls: tools, tokens: newTokens, wallTimeMilliseconds: time)
    }
}

public struct BuilderStageBudgetUsage: Codable, Sendable, Equatable {
    public let stage: BuilderExecutionStage
    public let usage: BuilderBudgetUsage
}

public struct BuilderBudgetSnapshot: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let contractFingerprint: String
    public let sequence: Int
    public let total: BuilderBudgetUsage
    public let stages: [BuilderStageBudgetUsage]
    public let observations: [BuilderBudgetObservationRecord]
    public let breach: String?
}

public struct BuilderBudgetObservationRecord: Codable, Sendable, Equatable {
    public let id: String
    public let fingerprint: String
}

private struct SealedBuilderBudgetSnapshot: Codable, Equatable {
    let snapshot: BuilderBudgetSnapshot
    let seal: String
}

public enum BuilderBudgetLedgerError: Error, LocalizedError, Sendable, Equatable {
    case invalidObservation(String)
    case contractMismatch
    case unknownStage(BuilderExecutionStage)
    case identityNotDeclared(String)
    case conflictingObservation(String)
    case exceeded(String)
    case overflow
    case tampered

    public var errorDescription: String? {
        switch self {
        case .invalidObservation(let reason): return "Invalid trusted budget observation: \(reason)"
        case .contractMismatch: return "Budget observation belongs to a different contract or node"
        case .unknownStage(let stage): return "No budget exists for stage \(stage.rawValue)"
        case .identityNotDeclared(let value): return "Provider observation identity is not contract-bound: \(value)"
        case .conflictingObservation(let id): return "Budget observation ID was replayed with different content: \(id)"
        case .exceeded(let reason): return reason
        case .overflow: return "Builder budget counter overflow"
        case .tampered: return "Durable builder budget ledger failed canonical seal validation"
        }
    }
}

public actor BuilderBudgetLedger {
    private let fileURL: URL
    private let contract: BuilderExecutionContract
    private let contractFingerprint: String
    private var cached: BuilderBudgetSnapshot?

    public init(fileURL: URL, contract: BuilderExecutionContract) throws {
        self.fileURL = fileURL
        self.contract = contract
        self.contractFingerprint = try contract.fingerprint()
    }

    @discardableResult
    public func record(_ observation: BuilderTrustedBudgetObservation) throws -> BuilderBudgetSnapshot {
        var state = try loadOrCreate()
        guard observation.contractFingerprint == contractFingerprint,
              observation.nodeID == contract.builderNodeID else {
            throw BuilderBudgetLedgerError.contractMismatch
        }
        guard contract.budgets.stages.contains(where: { $0.stage == observation.stage }) else {
            throw BuilderBudgetLedgerError.unknownStage(observation.stage)
        }
        if case .provider(let identity) = observation.source {
            let declared = contract.identities.producers + contract.identities.reviewers
            guard declared.contains(identity) else {
                throw BuilderBudgetLedgerError.identityNotDeclared(identity.canonicalID)
            }
        }
        let fingerprint = try observation.fingerprint()
        if let existing = state.observations.first(where: { $0.id == observation.id }) {
            guard existing.fingerprint == fingerprint else {
                throw BuilderBudgetLedgerError.conflictingObservation(observation.id)
            }
            if let breach = state.breach { throw BuilderBudgetLedgerError.exceeded(breach) }
            return state
        }
        try BuilderTrustedTelemetryAuthority.consume(
            id: observation.id, fingerprint: fingerprint,
            telemetrySeal: observation.telemetrySeal)
        if let breach = state.breach { throw BuilderBudgetLedgerError.exceeded(breach) }

        let projectedTotal = try state.total.adding(observation)
        var stageUsage = state.stages
        guard let index = stageUsage.firstIndex(where: { $0.stage == observation.stage }) else {
            throw BuilderBudgetLedgerError.unknownStage(observation.stage)
        }
        let projectedStage = try stageUsage[index].usage.adding(observation)
        stageUsage[index] = BuilderStageBudgetUsage(stage: observation.stage, usage: projectedStage)
        let totalLimit = contract.budgets.total
        let stageLimit = contract.budgets.stages.first { $0.stage == observation.stage }!.limit
        let breach = Self.breach(usage: projectedTotal, limit: totalLimit, label: "total")
            ?? Self.breach(usage: projectedStage, limit: stageLimit, label: observation.stage.rawValue)
        state = BuilderBudgetSnapshot(
            schemaVersion: 1, contractFingerprint: contractFingerprint,
            sequence: state.sequence + 1, total: projectedTotal,
            stages: stageUsage.sorted { $0.stage.rawValue < $1.stage.rawValue },
            observations: (state.observations + [.init(id: observation.id, fingerprint: fingerprint)])
                .sorted { $0.id < $1.id }, breach: breach)
        try persist(state)
        if let breach { throw BuilderBudgetLedgerError.exceeded(breach) }
        return state
    }

    public func snapshot() throws -> BuilderBudgetSnapshot { try loadOrCreate() }

    /// A no-op recovery must not launch another provider after its sealed budget is spent.
    /// Provider observations always consume measured tokens and elapsed time; tool capacity is
    /// intentionally not reserved because subscription CLIs may perform their mutation internally.
    public func admitsProviderRetry(stage: BuilderExecutionStage) throws -> Bool {
        let state = try loadOrCreate()
        guard state.breach == nil,
              let stageUsage = state.stages.first(where: { $0.stage == stage })?.usage,
              let stageLimit = contract.budgets.stages.first(where: { $0.stage == stage })?.limit else {
            return false
        }
        return Self.hasProviderCapacity(state.total, limit: contract.budgets.total)
            && Self.hasProviderCapacity(stageUsage, limit: stageLimit)
    }

    private func loadOrCreate() throws -> BuilderBudgetSnapshot {
        if let cached { return cached }
        if let data = try BuilderDurableIO.readSecure(fileURL) {
            let envelope = try JSONDecoder().decode(SealedBuilderBudgetSnapshot.self, from: data)
            guard try BuilderDurableIO.canonicalData(envelope) == data,
                  envelope.snapshot.schemaVersion == 1,
                  envelope.snapshot.contractFingerprint == contractFingerprint else {
                throw BuilderBudgetLedgerError.tampered
            }
            let canonical = String(decoding: try BuilderDurableIO.canonicalData(envelope.snapshot), as: UTF8.self)
            guard ForgeSeal.verify(canonical, seal: envelope.seal) else {
                throw BuilderBudgetLedgerError.tampered
            }
            cached = envelope.snapshot
            return envelope.snapshot
        }
        let initial = BuilderBudgetSnapshot(
            schemaVersion: 1, contractFingerprint: contractFingerprint, sequence: 0,
            total: .zero,
            stages: contract.budgets.stages.map { .init(stage: $0.stage, usage: .zero) },
            observations: [], breach: nil)
        try persist(initial)
        return initial
    }

    private func persist(_ snapshot: BuilderBudgetSnapshot) throws {
        let canonical = String(decoding: try BuilderDurableIO.canonicalData(snapshot), as: UTF8.self)
        let seal = ForgeSeal.sign(canonical)
        guard !seal.isEmpty else { throw BuilderBudgetLedgerError.tampered }
        try BuilderDurableIO.writeAtomic(
            try BuilderDurableIO.canonicalData(SealedBuilderBudgetSnapshot(snapshot: snapshot, seal: seal)),
            to: fileURL)
        cached = snapshot
    }

    private static func breach(usage: BuilderBudgetUsage, limit: BuilderResourceBudget,
                               label: String) -> String? {
        let (milliseconds, overflow) = limit.maxWallTimeSeconds.multipliedReportingOverflow(by: 1_000)
        if overflow { return "\(label) wall-time budget cannot be represented safely" }
        if usage.toolCalls > limit.maxToolCalls {
            return "\(label) tool-call budget exceeded (\(usage.toolCalls)/\(limit.maxToolCalls))"
        }
        if usage.tokens > limit.maxTokens {
            return "\(label) token budget exceeded (\(usage.tokens)/\(limit.maxTokens))"
        }
        if usage.wallTimeMilliseconds > milliseconds {
            return "\(label) wall-time budget exceeded (\(usage.wallTimeMilliseconds)/\(milliseconds)ms)"
        }
        return nil
    }

    private static func hasProviderCapacity(
        _ usage: BuilderBudgetUsage, limit: BuilderResourceBudget
    ) -> Bool {
        let (milliseconds, overflow) = limit.maxWallTimeSeconds.multipliedReportingOverflow(by: 1_000)
        guard !overflow else { return false }
        return usage.tokens < limit.maxTokens
            && usage.wallTimeMilliseconds < milliseconds
    }
}
