import Foundation

/// The fleet HANDOFF token + its lifecycle (pure value types). A Baton is the unit the captain (foreman)
/// mints, hands to an agent, accepts on surrender, and advances ONLY after a forge-proof signoff. It
/// carries `accumulatedContext` — the running ledger of PROVEN work — so the proven slice of one agent's
/// output reaches the next agent's brief without re-prompting.
///
/// PURE value types: a baton DESCRIBES handoff state; it never executes work, touches git, or reads a
/// clock. Epochs are caller-supplied Doubles (deterministic). ADDITIVE-DECODE discipline: post-genesis
/// fields are `decodeIfPresent` so an older baton.json still decodes. The state-machine validator
/// (`BatonState.canTransition`) is the ONLY place legality lives — no second copy to drift.
///
/// Ported from TinkySDR's Captain (Stage 2). `currentSubtask` reuses Mythos's own `PlanStep` (the typed
/// plan-DAG step); `signoffSeq` links a contribution to a Stage-1.5 `FleetSignoffEntry.seq`.
/// LABEL: PROTOTYPE.

/// The forge-proof lifecycle of a baton. `String`-backed so a baton.json survives the enum gaining cases
/// — an unknown raw value is the one case decode rejects (a baton in a state this build can't reason
/// about must NOT be coerced into a wrong-but-known state).
public enum BatonState: String, Codable, Equatable, Sendable {
    case created      // captain minted it, not handed out
    case held         // an agent owns it and is working
    case submitted    // agent committed + dropped done-marker; awaiting foreman
    case verified     // foreman green AND signoff sealed+appended
    case passed       // handed on (sequential) / converged (parallel)
    case rejected     // foreman non-green → bounce for retry
    case timedOut     // deadline elapsed in .held with no surrender
    case failed       // retry budget exhausted / unrecoverable

    /// Terminal states: no legal transition leaves them.
    public var isTerminal: Bool { self == .passed || self == .failed }

    /// The single source of truth for which transitions the backbone permits. Deterministic, pure, total.
    ///   created → held · held → submitted|timedOut · submitted → verified|rejected · verified → passed
    ///   rejected → held|failed · timedOut → failed|held · passed/failed → ∅
    public func canTransition(to next: BatonState) -> Bool {
        switch self {
        case .created:   return next == .held
        case .held:      return next == .submitted || next == .timedOut
        case .submitted: return next == .verified || next == .rejected
        case .verified:  return next == .passed
        case .rejected:  return next == .held || next == .failed
        case .timedOut:  return next == .failed || next == .held
        case .passed:    return false
        case .failed:    return false
        }
    }
}

/// One predecessor's PROVEN work, accreted onto the baton as it passes. Only a signed-off contribution is
/// ever appended — `signoffSeq` is the forge-proof link back into FleetSignoffLedger, so a contribution
/// can't claim "done" without a sealed ledger row behind it.
public struct BatonContribution: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let subtaskTitle: String
    public let branch: String                       // the deliverable's branch
    public let commitSHA: String                    // surrendered commit (deliverable handle)
    public let summary: String                      // "what I did + what the next agent must know"
    public let scopeGlobs: [String]                 // becomes the next agent's no-touch set
    public let signoffSeq: Int                      // -> FleetSignoffEntry.seq (forge-proof link)
    public let evidence: String                     // the foreman's measured note
    public let signedAtEpoch: Double

    public init(id: UUID = UUID(), subtaskTitle: String, branch: String, commitSHA: String, summary: String,
                scopeGlobs: [String] = [], signoffSeq: Int, evidence: String, signedAtEpoch: Double) {
        self.id = id; self.subtaskTitle = subtaskTitle; self.branch = branch; self.commitSHA = commitSHA
        self.summary = summary; self.scopeGlobs = scopeGlobs; self.signoffSeq = signoffSeq
        self.evidence = evidence; self.signedAtEpoch = signedAtEpoch
    }
}

/// One audit row in the baton's from→to→when lineage. `state` is the state the baton is IN after this hop.
public struct BatonHop: Codable, Equatable, Sendable {
    public let from: String                         // predecessor sessionId, or "captain" at genesis
    public let to: String
    public let atEpoch: Double
    public let state: BatonState                     // state AFTER this hop
    public init(from: String, to: String, atEpoch: Double, state: BatonState) {
        self.from = from; self.to = to; self.atEpoch = atEpoch; self.state = state
    }
}

/// The handoff token. Pure value type; the captain mints it, routes it, and converges it.
public struct Baton: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let fleetID: UUID
    public let missionGoal: String                  // umbrella goal
    public let repo: String

    // WHO HOLDS IT NOW
    public var holder: String?                      // current agent sessionId; nil when at captain
    public var currentSubtask: PlanStep?            // next task for holder (Mythos plan-DAG step)
    public var currentWorktree: String?
    public var currentBranch: String?
    public var scopeGlobs: [String]                 // holder's lease

    // SHARED MEMORY (grows as it passes)
    public var accumulatedContext: [BatonContribution]

    // LIFECYCLE / PROVENANCE
    public var state: BatonState
    public var lineage: [BatonHop]                  // from→to→when audit chain
    public var leaseToken: String?                  // ties to claim/lock ownership
    public var deadlineEpoch: Double?               // wall-clock TTL backstop
    public var rejectCount: Int                     // retry budget

    public init(id: UUID = UUID(), fleetID: UUID, missionGoal: String, repo: String,
                holder: String? = nil, currentSubtask: PlanStep? = nil, currentWorktree: String? = nil,
                currentBranch: String? = nil, scopeGlobs: [String] = [],
                accumulatedContext: [BatonContribution] = [], state: BatonState = .created,
                lineage: [BatonHop] = [], leaseToken: String? = nil, deadlineEpoch: Double? = nil,
                rejectCount: Int = 0) {
        self.id = id; self.fleetID = fleetID; self.missionGoal = missionGoal; self.repo = repo
        self.holder = holder; self.currentSubtask = currentSubtask; self.currentWorktree = currentWorktree
        self.currentBranch = currentBranch; self.scopeGlobs = scopeGlobs
        self.accumulatedContext = accumulatedContext; self.state = state; self.lineage = lineage
        self.leaseToken = leaseToken; self.deadlineEpoch = deadlineEpoch; self.rejectCount = rejectCount
    }

    enum CodingKeys: String, CodingKey {
        case id, fleetID, missionGoal, repo
        case holder, currentSubtask, currentWorktree, currentBranch, scopeGlobs
        case accumulatedContext, state, lineage, leaseToken, deadlineEpoch, rejectCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fleetID = try c.decode(UUID.self, forKey: .fleetID)
        missionGoal = try c.decode(String.self, forKey: .missionGoal)
        repo = try c.decode(String.self, forKey: .repo)
        state = try c.decode(BatonState.self, forKey: .state)
        holder = try c.decodeIfPresent(String.self, forKey: .holder)
        currentSubtask = try c.decodeIfPresent(PlanStep.self, forKey: .currentSubtask)
        currentWorktree = try c.decodeIfPresent(String.self, forKey: .currentWorktree)
        currentBranch = try c.decodeIfPresent(String.self, forKey: .currentBranch)
        scopeGlobs = try c.decodeIfPresent([String].self, forKey: .scopeGlobs) ?? []
        accumulatedContext = try c.decodeIfPresent([BatonContribution].self, forKey: .accumulatedContext) ?? []
        lineage = try c.decodeIfPresent([BatonHop].self, forKey: .lineage) ?? []
        leaseToken = try c.decodeIfPresent(String.self, forKey: .leaseToken)
        deadlineEpoch = try c.decodeIfPresent(Double.self, forKey: .deadlineEpoch)
        rejectCount = try c.decodeIfPresent(Int.self, forKey: .rejectCount) ?? 0
    }
}

// MARK: - Pure helpers (deterministic; epochs as params, no Date())

extension Baton {
    /// Whether the current `state` may legally move to `next` (delegates to the single source of truth).
    public func canTransition(to next: BatonState) -> Bool { state.canTransition(to: next) }

    /// A copy advanced to `next`, recording a lineage hop, IFF the transition is legal — else `nil` (the
    /// supervisor treats nil as "illegal transition, do not write"). The ONLY mutator of `state`, so the
    /// legality check can never be bypassed.
    public func advanced(to next: BatonState, from: String, to: String, atEpoch: Double) -> Baton? {
        guard state.canTransition(to: next) else { return nil }
        var copy = self
        copy.state = next
        copy.lineage.append(BatonHop(from: from, to: to, atEpoch: atEpoch, state: next))
        return copy
    }

    /// A copy with a PROVEN contribution accreted onto `accumulatedContext`. Append-only.
    public func appendingContribution(_ c: BatonContribution) -> Baton {
        var copy = self
        copy.accumulatedContext.append(c)
        return copy
    }

    /// True when a wall-clock deadline exists and `nowEpoch` is past it. Pure predicate (does not mutate).
    public func isPastDeadline(nowEpoch: Double) -> Bool {
        guard let deadline = deadlineEpoch else { return false }
        return nowEpoch > deadline
    }
}
