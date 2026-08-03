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
