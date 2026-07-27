import Foundation

/// The BLACKBOARD substrate — the fleet's shared read-only context. A fleet is a crew of agents working
/// one mission in parallel; the blackboard is the shared truth ("who owns what, and what each has proven
/// done") the whole crew can read. The CAPTAIN is the sole writer; agents are read-only and report
/// progress out-of-band (the `.fleet-progress.jsonl` advisory channel folded each sweep).
///
/// PURE value types: a blackboard DESCRIBES the fleet's state, it never executes anything. Epochs are
/// caller-supplied Doubles (deterministic; never Date() in pure code) — except `startedAt`, a Date for
/// the on-disk shape. ADDITIVE-DECODE DISCIPLINE: every growable type supplies explicit CodingKeys +
/// init(from:) using decodeIfPresent for post-v1 fields, so an older blackboard.json still decodes.
///
/// Ported from TinkySDR's Captain (Stage 2). All types public; `signoff` is the Stage-1.5 `Signoff`.
/// LABEL: PROTOTYPE.

/// The whole-fleet shared memory document. One per fleet. `cells` is one entry per spawned agent;
/// `revision` is a monotone stale-read guard bumped on every committed write.
public struct FleetBlackboard: Identifiable, Codable, Sendable {
    public static let currentSchemaVersion = 2

    public let id: UUID                       // fleetID
    public var schemaVersion: Int             // migration marker for durable board shape
    public let goal: String                   // verbatim launchFleet goal
    public let plan: [PlanStepRef]            // flattened planner decomposition (the manifest)
    public let integrationBranch: String      // where verified branches converge (the merge gate)
    public let repo: String
    public let startedAt: Date
    public var cells: [AgentCell]             // one per spawned agent
    public var revision: Int                  // monotone; bumped on every committed write

    public init(id: UUID, goal: String, plan: [PlanStepRef], integrationBranch: String, repo: String,
                startedAt: Date, cells: [AgentCell] = [], revision: Int = 0,
                schemaVersion: Int = FleetBlackboard.currentSchemaVersion) {
        self.id = id; self.schemaVersion = schemaVersion; self.goal = goal; self.plan = plan; self.integrationBranch = integrationBranch
        self.repo = repo; self.startedAt = startedAt; self.cells = cells; self.revision = revision
    }

    enum CodingKeys: String, CodingKey {
        case id, schemaVersion, goal, plan, integrationBranch, repo, startedAt, cells, revision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        goal = try c.decode(String.self, forKey: .goal)
        plan = try c.decodeIfPresent([PlanStepRef].self, forKey: .plan) ?? []
        integrationBranch = try c.decodeIfPresent(String.self, forKey: .integrationBranch) ?? ""
        repo = try c.decode(String.self, forKey: .repo)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        cells = try c.decodeIfPresent([AgentCell].self, forKey: .cells) ?? []
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }
}

/// A flattened plan step used as the fleet MANIFEST — the contract every agent reads to know who owns
/// what. `scope` is the owning file/module hint; `assignedAgentID` is the owning cell + dependency edge
/// (nil = unassigned).
public struct PlanStepRef: Codable, Equatable, Sendable {
    public let title: String
    public let intent: String
    public let scope: String?
    public let assignedAgentID: UUID?

    public init(title: String, intent: String, scope: String? = nil, assignedAgentID: UUID? = nil) {
        self.title = title; self.intent = intent; self.scope = scope; self.assignedAgentID = assignedAgentID
    }

    enum CodingKeys: String, CodingKey { case title, intent, scope, assignedAgentID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        intent = try c.decode(String.self, forKey: .intent)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        assignedAgentID = try c.decodeIfPresent(UUID.self, forKey: .assignedAgentID)
    }
}

/// One agent's cell on the board: its lease, status, and append-only ledgers of decisions/questions/
/// blockers. `filesTouched` is HARVESTED from git by the captain (never self-reported) — the collision
/// unit. `signoff` is the baton proof; nil until the foreman has verified the cell done. A `ForemanSubject`
/// is derived from a cell for the verify-and-sign pass.
public struct AgentCell: Identifiable, Codable, Sendable {
    public let id: UUID                       // == FleetAgent.id
    public let title: String
    public let branch: String                 // GitWorktree.branch
    public let worktreePath: String
    public let baseSHA: String                // GitWorktree.base — for committed-diff lease measurement
    public var scopeGlobs: [String]           // LEASE CONTRACT
    public var acceptanceCriterion: String    // G2 (TDD) — the testable done-condition
    public var status: CellStatus
    public var filesTouched: [String]         // harvested from git — collision unit
    public var keyDecisions: [Note]           // append-only: "chose X over Y because Z"
    public var openQuestions: [Note]          // routed to fleet/captain
    public var blockers: [Note]               // hard stops ("needs API from cell B")
    public var lastHeartbeatEpoch: Double     // freshness clock — folded from progress + updates
    public var signoff: Signoff?              // the BATON proof; nil until verified done
    // LIVE in-flight signal (ADVISORY, not proof): folded from `.fleet-progress.jsonl` each sweep.
    public var liveStep: Int?                 // current step number (nil = no signal yet)
    public var lastAction: String?            // one-line "what it's doing right now"
    public var supervisorInterventions: [SupervisorInterventionRecord]
    public var supervisorEscalations: [SupervisorEscalationRecord]
    public var rejectedDoneHeadSHAs: [String] // done markers rejected at this commit; prevents re-burning retries after restart

    public enum CellStatus: String, Codable, Sendable {
        case pending, working, blocked, readyForSignoff, signedOff, failed
    }

    public init(id: UUID, title: String, branch: String, worktreePath: String, baseSHA: String = "",
                scopeGlobs: [String] = [], acceptanceCriterion: String = "", status: CellStatus = .pending,
                filesTouched: [String] = [], keyDecisions: [Note] = [], openQuestions: [Note] = [],
                blockers: [Note] = [], lastHeartbeatEpoch: Double = 0, signoff: Signoff? = nil,
                liveStep: Int? = nil, lastAction: String? = nil,
                supervisorInterventions: [SupervisorInterventionRecord] = [],
                supervisorEscalations: [SupervisorEscalationRecord] = [],
                rejectedDoneHeadSHAs: [String] = []) {
        self.id = id; self.title = title; self.branch = branch; self.worktreePath = worktreePath
        self.baseSHA = baseSHA; self.scopeGlobs = scopeGlobs; self.acceptanceCriterion = acceptanceCriterion
        self.status = status; self.filesTouched = filesTouched; self.keyDecisions = keyDecisions
        self.openQuestions = openQuestions; self.blockers = blockers
        self.lastHeartbeatEpoch = lastHeartbeatEpoch; self.signoff = signoff
        self.liveStep = liveStep; self.lastAction = lastAction
        self.supervisorInterventions = supervisorInterventions
        self.supervisorEscalations = supervisorEscalations
        self.rejectedDoneHeadSHAs = rejectedDoneHeadSHAs
    }

    enum CodingKeys: String, CodingKey {
        case id, title, branch, worktreePath, baseSHA, scopeGlobs, acceptanceCriterion, status, filesTouched
        case keyDecisions, openQuestions, blockers, lastHeartbeatEpoch, signoff, liveStep, lastAction
        case supervisorInterventions, supervisorEscalations, rejectedDoneHeadSHAs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        branch = try c.decode(String.self, forKey: .branch)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        baseSHA = try c.decodeIfPresent(String.self, forKey: .baseSHA) ?? ""
        scopeGlobs = try c.decodeIfPresent([String].self, forKey: .scopeGlobs) ?? []
        acceptanceCriterion = try c.decodeIfPresent(String.self, forKey: .acceptanceCriterion) ?? ""
        status = try c.decodeIfPresent(CellStatus.self, forKey: .status) ?? .pending
        filesTouched = try c.decodeIfPresent([String].self, forKey: .filesTouched) ?? []
        keyDecisions = try c.decodeIfPresent([Note].self, forKey: .keyDecisions) ?? []
        openQuestions = try c.decodeIfPresent([Note].self, forKey: .openQuestions) ?? []
        blockers = try c.decodeIfPresent([Note].self, forKey: .blockers) ?? []
        lastHeartbeatEpoch = try c.decodeIfPresent(Double.self, forKey: .lastHeartbeatEpoch) ?? 0
        signoff = try c.decodeIfPresent(Signoff.self, forKey: .signoff)
        liveStep = try c.decodeIfPresent(Int.self, forKey: .liveStep)
        lastAction = try c.decodeIfPresent(String.self, forKey: .lastAction)
        supervisorInterventions = try c.decodeIfPresent([SupervisorInterventionRecord].self,
                                                         forKey: .supervisorInterventions) ?? []
        supervisorEscalations = try c.decodeIfPresent([SupervisorEscalationRecord].self,
                                                       forKey: .supervisorEscalations) ?? []
        rejectedDoneHeadSHAs = try c.decodeIfPresent([String].self, forKey: .rejectedDoneHeadSHAs) ?? []
    }

    /// The verify-and-sign subject derived from this cell (the lease + identity the Foreman judges).
    public var foremanSubject: ForemanSubject {
        ForemanSubject(agentID: id, branch: branch, worktreePath: worktreePath, baseSHA: baseSHA,
                       scopeGlobs: scopeGlobs, title: title, acceptanceCriterion: acceptanceCriterion)
    }
}

/// Captain-authored intervention proof. Unlike `keyDecisions`/`blockers`, workers cannot create these via
/// `CellUpdate`, so they are safe for supervisor budgets and post-run accountability.
public struct SupervisorInterventionRecord: Codable, Equatable, Sendable {
    public let kind: String
    public let atEpoch: Double
    public let summary: String
    public let evidence: [String]
    public let delivered: Bool
    public let deliveryFailures: [String]

    public init(kind: String, atEpoch: Double, summary: String, evidence: [String],
                delivered: Bool = false, deliveryFailures: [String] = []) {
        self.kind = kind
        self.atEpoch = atEpoch
        self.summary = summary
        self.evidence = evidence
        self.delivered = delivered
        self.deliveryFailures = deliveryFailures
    }

    enum CodingKeys: String, CodingKey {
        case kind, atEpoch, summary, evidence, delivered, deliveryFailures
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        atEpoch = try c.decode(Double.self, forKey: .atEpoch)
        summary = try c.decode(String.self, forKey: .summary)
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        delivered = try c.decodeIfPresent(Bool.self, forKey: .delivered) ?? false
        deliveryFailures = try c.decodeIfPresent([String].self, forKey: .deliveryFailures) ?? []
    }
}

/// Captain-authored rescue escalation proof. An intervention is a directive to the stuck worker; an
/// escalation is Captain admitting that the directive did not clear the risk and that a repair/rescue
/// assignment must be created before the fleet can be trusted.
public struct SupervisorEscalationRecord: Codable, Equatable, Sendable {
    public let kind: String
    public let atEpoch: Double
    public let summary: String
    public let evidence: [String]
    public let assignment: String
    public let delivered: Bool
    public let deliveryFailures: [String]

    public init(kind: String, atEpoch: Double, summary: String, evidence: [String], assignment: String,
                delivered: Bool = false, deliveryFailures: [String] = []) {
        self.kind = kind
        self.atEpoch = atEpoch
        self.summary = summary
        self.evidence = evidence
        self.assignment = assignment
        self.delivered = delivered
        self.deliveryFailures = deliveryFailures
    }

    enum CodingKeys: String, CodingKey {
        case kind, atEpoch, summary, evidence, assignment, delivered, deliveryFailures
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        atEpoch = try c.decode(Double.self, forKey: .atEpoch)
        summary = try c.decode(String.self, forKey: .summary)
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        assignment = try c.decodeIfPresent(String.self, forKey: .assignment) ?? summary
        delivered = try c.decodeIfPresent(Bool.self, forKey: .delivered) ?? false
        deliveryFailures = try c.decodeIfPresent([String].self, forKey: .deliveryFailures) ?? []
    }
}

/// An immutable, append-only fact with provenance. We never edit a Note in place; conflicting facts are
/// BOTH kept (no last-writer-wins merge). `atEpoch` is caller-supplied (deterministic).
public struct Note: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let atEpoch: Double
    public let text: String
    public init(id: UUID = UUID(), atEpoch: Double, text: String) {
        self.id = id; self.atEpoch = atEpoch; self.text = text
    }
}
