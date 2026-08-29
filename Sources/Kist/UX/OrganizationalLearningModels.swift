import Foundation
import AgentCore

struct LearningCapsule: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable { case pass = "PASS", fail = "FAIL" }

    var id: String
    var taskTitle: String
    var status: Status
    var summary: String
    var learned: [String]
    var surprises: [String]
    var slowdowns: [String]
    var assumptionsToChallenge: [String]
    var futureEvolution: String
    var tokenCount: Int
    var at: Double
    /// Optional so historical JSONL remains readable. Legacy projection is computed in memory and
    /// is never written back merely because the capsule was read.
    var temporal: MemoryTemporalEnvelope? = nil

    var temporalProjection: MemoryTemporalEnvelope? {
        if let temporal {
            return OrganizationalMemoryTemporal.validatedStored(
                temporal, createdAt: at, updatedAt: at)
        }
        return OrganizationalMemoryTemporal.legacy(
            createdAt: at, updatedAt: at, decayRate: .medium)
    }
}

struct KnowledgeDebtRecord: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable { case open, done }
    enum Priority: String, Codable, Equatable, Sendable { case high, medium }

    var id: String
    var topic: String
    var reason: String
    var visit: String
    var impact: Int
    var priority: Priority
    var estimatedLearning: String
    var expectedBenefit: [String]
    var sourceCapsuleID: String?
    var status: Status
    var createdAt: Double
    var updatedAt: Double
    var temporal: MemoryTemporalEnvelope? = nil

    var temporalProjection: MemoryTemporalEnvelope? {
        if let temporal {
            return OrganizationalMemoryTemporal.validatedStored(
                temporal, createdAt: createdAt, updatedAt: updatedAt)
        }
        return OrganizationalMemoryTemporal.legacy(
            createdAt: createdAt, updatedAt: updatedAt, decayRate: .slow)
    }
}

struct OrganizationalRuleRecord: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable { case active, proposed, retired }

    var id: String
    var lesson: String
    var confidence: Int
    var reason: String
    var evidence: [String]
    var sourceCapsuleID: String?
    var status: Status
    var createdAt: Double
    var updatedAt: Double
    var temporal: MemoryTemporalEnvelope? = nil

    var temporalProjection: MemoryTemporalEnvelope? {
        if let temporal {
            return OrganizationalMemoryTemporal.validatedStored(
                temporal, createdAt: createdAt, updatedAt: updatedAt)
        }
        return OrganizationalMemoryTemporal.legacy(
            createdAt: createdAt, updatedAt: updatedAt, decayRate: .verySlow)
    }
}

/// Organizational records use AgentCore's single temporal kernel. These adapters only project legacy
/// scalar timestamps and preserve envelope fields during a transaction update; they contain no decay,
/// recurrence, lifecycle, or authority logic of their own.
enum OrganizationalMemoryTemporal {
    static let storedClockAgreementTolerance =
        MemoryTemporalEnvelope.storedClockAgreementTolerance

    /// Foundation's ISO-8601 encoder emits millisecond precision on the supported platforms. Store
    /// the legacy scalar and nested envelope at that same precision so cross-runtime projections do
    /// not disagree merely because the original Date carried sub-millisecond residue.
    static func canonicalInstant(_ instant: Date) -> Date {
        let epoch = instant.timeIntervalSince1970
        guard epoch.isFinite else { return instant }
        return Date(timeIntervalSince1970: (epoch * 1_000).rounded() / 1_000)
    }

    static func make(createdAt: Date, decayRate: MemoryDecayRate,
                     seasonalWindow: SeasonalMemoryWindow? = nil) -> MemoryTemporalEnvelope? {
        try? MemoryTemporalEnvelope(createdAt: canonicalInstant(createdAt),
                                    seasonalWindow: seasonalWindow,
                                    decayRate: decayRate)
    }

    /// A nested envelope is accepted only when it describes the same transaction clocks as the
    /// legacy scalar fields beside it. This keeps Swift retrieval aligned with the JSONL indexer and
    /// prevents a row from presenting one history to audit code and another to temporal ranking.
    static func validatedStored(_ envelope: MemoryTemporalEnvelope,
                                createdAt: Double,
                                updatedAt: Double) -> MemoryTemporalEnvelope? {
        guard clock(createdAt, agreesWith: envelope.createdAt),
              clock(updatedAt, agreesWith: envelope.updatedAt) else { return nil }
        return envelope
    }

    private static func clock(_ scalar: Double, agreesWith nested: Date) -> Bool {
        MemoryTemporalEnvelope.storedClockAgrees(scalar, with: nested)
    }

    static func legacy(createdAt: Double, updatedAt: Double,
                       decayRate: MemoryDecayRate) -> MemoryTemporalEnvelope? {
        guard createdAt.isFinite, updatedAt.isFinite else { return nil }
        return try? MemoryTemporalEnvelope(
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            accessedAt: Date(timeIntervalSince1970: createdAt),
            decayRate: decayRate)
    }

    /// Advances transaction time without touching access/reinforcement counters or evidence time.
    /// An explicit season may replace the prior season; nil preserves the prior configuration.
    static func transactionUpdated(_ envelope: MemoryTemporalEnvelope,
                                   at instant: Date,
                                   seasonalWindow: SeasonalMemoryWindow? = nil) -> MemoryTemporalEnvelope? {
        let canonical = canonicalInstant(instant)
        guard canonical >= envelope.updatedAt else { return envelope }
        return try? MemoryTemporalEnvelope(
            createdAt: envelope.createdAt,
            updatedAt: canonical,
            accessedAt: envelope.accessedAt,
            validFrom: envelope.validFrom,
            validUntil: envelope.validUntil,
            lastConfirmedAt: envelope.lastConfirmedAt,
            seasonalWindow: seasonalWindow ?? envelope.seasonalWindow,
            accessCount: envelope.accessCount,
            reinforcementCount: envelope.reinforcementCount,
            decayRate: envelope.decayRate,
            baseSalience: envelope.baseSalience,
            pinned: envelope.pinned,
            status: envelope.status,
            retiredAt: envelope.retiredAt,
            retiredReason: envelope.retiredReason,
            supersededBy: envelope.supersededBy,
            supersedes: envelope.supersedes)
    }
}

struct OrganizationalRulePromotionDecision: Equatable, Sendable {
    var accepted: Bool
    var blockers: [String]
    var verifiedEvidenceCount: Int
}

struct DiskMemoryRecord: Codable, Equatable, Sendable {
    var id: String?
    var title: String?
    var summary: String?
    var body: String?
    var source: String?
    var confidence: Int?
    var impact: Int?
    var tags: [String]?
    /// Optional for backward compatibility. Rows without an explicit event/transaction clock remain
    /// available to raw audit readers but cannot enter operational retrieval: inventing a timestamp
    /// from file mtime would silently rejuvenate copied or rewritten conclusions.
    var createdAt: Double? = nil
    var updatedAt: Double? = nil
    var temporal: MemoryTemporalEnvelope? = nil

    var temporalProjection: MemoryTemporalEnvelope? {
        guard let createdAt, let updatedAt else { return nil }
        if let temporal {
            guard let validated = OrganizationalMemoryTemporal.validatedStored(
                    temporal, createdAt: createdAt, updatedAt: updatedAt),
                  !validated.pinned,
                  validated.decayRate != .none,
                  validated.lastConfirmedAt == nil,
                  validated.accessCount == 0,
                  validated.reinforcementCount == 0,
                  abs(validated.accessedAt.timeIntervalSince(validated.createdAt))
                    <= OrganizationalMemoryTemporal.storedClockAgreementTolerance,
                  validated.baseSalience <= 0.8 + 0.000_000_1 else { return nil }
            return validated
        }
        return OrganizationalMemoryTemporal.legacy(
            createdAt: createdAt, updatedAt: updatedAt, decayRate: .medium)
    }
}

struct LearningEvidenceRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case selfHealSpecialist = "self-heal-specialist"
        case domainLearningSpecialist = "domain-learning-specialist"
    }

    var id: String
    var kind: Kind
    var objective: String
    var specialistName: String
    var role: String
    var preferredModel: String
    var artifactPath: String
    var memoryRecorded: Bool
    var taskIDs: [Int]
    var taskEvidenceUpdated: Int
    var createdAt: Double
}

struct EvolutionBoardReport: Equatable, Sendable {
    var path: String
    var text: String
    var seededResearchTasks: Int
    var createdSpecialists: Int
    var promotedRules: Int
}

struct SelfHealAgentAssignment: Equatable, Sendable, Codable {
    var specialistName: String
    var role: String
    var preferredModel: String
    var task: String
}

struct SelfHealMissionReport: Equatable, Sendable {
    var path: String
    var text: String
    var boardMeetingPath: String
    var seededTasks: Int
    var createdSpecialists: Int
    var promotedRules: Int
    var agentAssignments: [SelfHealAgentAssignment]
    var dispatchCommand: String
    var writeSucceeded: Bool
    var writeError: String?
}

struct SelfHealSpecialistArtifact: Equatable, Sendable {
    var path: String
    var memoryRecorded: Bool
    var taskEvidenceUpdated: Int
    var updatedTaskIDs: [Int]
    var evidenceLedgerRecorded: Bool
}

struct DomainLearningAssignment: Equatable, Sendable, Codable {
    var specialistName: String
    var role: String
    var preferredModel: String
    var task: String
}

struct DomainLearningReport: Equatable, Sendable {
    var path: String
    var text: String
    var objective: String
    var understandingConfidence: Int
    var confidenceThreshold: Int
    var canExecute: Bool
    var seededTasks: Int
    var knowledgeDebtCreated: Int
    var createdSpecialists: Int
    var memoryRecords: Int
    var agentAssignments: [DomainLearningAssignment]
    var dispatchCommand: String
    var writeSucceeded: Bool
    var writeError: String?
}

struct DomainLearningSpecialistArtifact: Equatable, Sendable {
    var path: String
    var memoryRecorded: Bool
    var taskEvidenceUpdated: Int
    var updatedTaskIDs: [Int]
    var evidenceLedgerRecorded: Bool
}
