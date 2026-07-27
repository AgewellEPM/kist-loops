import Foundation

/// One agent's self-reported update to its blackboard cell — the message an agent drops for the captain
/// to FOLD (it never writes the board directly). Everything here is ADVISORY: status is clamped (an agent
/// may not report itself `.signedOff` — only the foreman can), `filesTouched` is what the agent CLAIMS
/// (the captain harvests the authoritative set from git), and decisions/questions/blockers are append-only.
/// `baseRevision` is the board revision the agent composed this against — the stale-read guard keys on it.
///
/// Ported from TinkySDR's Captain (Stage 2). The `FleetUpdateInbox` (later increment) persists/reads these
/// as files; `FleetBlackboardStore.foldUpdate` consumes them. Additive-decode: a partial drop still loads.
public struct CellUpdate: Codable, Equatable, Sendable {
    public let agentID: UUID
    public let atEpoch: Double
    public var status: AgentCell.CellStatus?
    public var keyDecisions: [String]
    public var openQuestions: [String]
    public var blockers: [String]
    public var filesTouched: [String]
    public var baseRevision: Int

    public init(agentID: UUID, atEpoch: Double, status: AgentCell.CellStatus? = nil,
                keyDecisions: [String] = [], openQuestions: [String] = [], blockers: [String] = [],
                filesTouched: [String] = [], baseRevision: Int = 0) {
        self.agentID = agentID; self.atEpoch = atEpoch; self.status = status
        self.keyDecisions = keyDecisions; self.openQuestions = openQuestions; self.blockers = blockers
        self.filesTouched = filesTouched; self.baseRevision = baseRevision
    }

    enum CodingKeys: String, CodingKey {
        case agentID, atEpoch, status, keyDecisions, openQuestions, blockers, filesTouched, baseRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try c.decode(UUID.self, forKey: .agentID)
        atEpoch = try c.decode(Double.self, forKey: .atEpoch)
        status = try c.decodeIfPresent(AgentCell.CellStatus.self, forKey: .status)
        keyDecisions = try c.decodeIfPresent([String].self, forKey: .keyDecisions) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        blockers = try c.decodeIfPresent([String].self, forKey: .blockers) ?? []
        filesTouched = try c.decodeIfPresent([String].self, forKey: .filesTouched) ?? []
        baseRevision = try c.decodeIfPresent(Int.self, forKey: .baseRevision) ?? 0
    }
}
