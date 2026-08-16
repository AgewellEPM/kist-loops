import Foundation

/// Phase 3.5 — the DECISION→OUTCOME record for one finished run. This is the data spine the
/// self-improving Captain (Phase 4) reasons over: for each task, *what the organization DECIDED*
/// (which route, which effort tiers, which specialists) paired with *what outcome the referee
/// MEASURED*. It is deliberately distinct from the two records that already exist:
///   • `AgentSpan`/`TraceRecorder` — per-call token/vendor attribution (the OTel cost view).
///   • `EffortOutcome`/`EffortMemory` — was the complexity *prediction* calibrated (one scalar).
/// Neither ties a routing/organization decision to its result, so neither can answer the question that
/// drives organizational self-improvement: "does decision X systematically correlate with worse runs?"
///
/// CORE INVARIANT (inherited from `AgentTrace`, and load-bearing here): a RunRecord carries only
/// MEASURED facts — the decision that was made, and the outcome the referee/critic measured. It has NO
/// field for "the agent said it succeeded". `success` and `verified` are referee facts, never the
/// agent's self-report. Observability must not mint trust; the improvement loop must train on truth.
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    // Identity / provenance
    public let id: String                 // the run/trace id
    public let at: Double                  // unix seconds (caller-supplied → the struct stays pure/testable)
    public let goal: String
    public let signature: String           // EffortController.signature(for: goal) — groups "similar" tasks
    /// A stable fingerprint of the organization's config AT THE TIME OF THIS RUN (routing thresholds +
    /// effort knobs). Phase 4 compares runs across two orgVersions to PROVE a config change helped.
    public let orgVersion: String

    // The DECISION (what the organization chose, before the work ran)
    public let route: String               // TaskRouter.Route.rawValue: fast / standard / pipeline
    public let complexity: Int             // 0…100 the decision was based on
    public let thinking: String            // EffortController tiers, as chosen
    public let planning: String
    public let team: String
    public let modelTier: String
    public let decisionReason: String
    public let specialists: [String]       // specialist roles actually assembled/used ([] if solo)
    public let provider: String?
    public let model: String?

    // The OUTCOME (measured by the referee AFTER the work ran)
    public let success: Bool               // did the run complete its goal (referee verdict)
    public let verified: Bool              // did a critic independently verify (distinct from success)
    public let failureRate: Double         // 0…1 of tool calls that failed
    public let iterationsUsed: Int
    public let iterationBudget: Int
    public let replansUsed: Int
    public let wasStuck: Bool
    public let toolCalls: Int
    public let durationMs: Double
    public let totalTokens: Int
    /// Coarse "where it failed" bucket for pattern mining: e.g. "plan" / "act" / "verify" / nil on success.
    public let failureStage: String?

    public init(id: String, at: Double, goal: String, signature: String, orgVersion: String,
                route: String, complexity: Int, thinking: String, planning: String, team: String,
                modelTier: String, decisionReason: String, specialists: [String] = [],
                provider: String? = nil, model: String? = nil,
                success: Bool, verified: Bool, failureRate: Double, iterationsUsed: Int,
                iterationBudget: Int, replansUsed: Int, wasStuck: Bool, toolCalls: Int,
                durationMs: Double, totalTokens: Int, failureStage: String? = nil) {
        self.id = id; self.at = at; self.goal = goal; self.signature = signature; self.orgVersion = orgVersion
        self.route = route; self.complexity = complexity; self.thinking = thinking; self.planning = planning
        self.team = team; self.modelTier = modelTier; self.decisionReason = decisionReason
        self.specialists = specialists; self.provider = provider; self.model = model
        self.success = success; self.verified = verified; self.failureRate = failureRate
        self.iterationsUsed = iterationsUsed; self.iterationBudget = iterationBudget
        self.replansUsed = replansUsed; self.wasStuck = wasStuck; self.toolCalls = toolCalls
        self.durationMs = durationMs; self.totalTokens = totalTokens; self.failureStage = failureStage
    }

    /// Did this run's OUTCOME contradict its routing DECISION? This is the core self-improvement signal —
    /// not "the run failed" (that can be the task's fault), but "the router mis-sized the task":
    ///   • a fast/standard run that got STUCK, replanned repeatedly, or failed → route was too optimistic
    ///     (under-served; the asymmetric-risk lane the TaskRouter warns about).
    ///   • a pipeline run that finished trivially with no struggle → over-escalation (burned the heavy
    ///     machinery on an easy task; wasted latency/cost, the thing Phase 2 exists to avoid).
    /// A run whose decision matched its outcome returns nil (nothing to learn from the routing choice).
    public var routingMisfit: RoutingMisfit? {
        let struggled = wasStuck || replansUsed >= 2 || !success
        if route == "fast" || route == "standard" {
            return struggled ? .underEscalated : nil
        }
        if route == "pipeline" {
            // "trivial in hindsight": succeeded fast, no struggle, well under budget.
            let trivial = success && !wasStuck && replansUsed == 0 && failureRate == 0
                && (iterationBudget > 0 ? iterationsUsed <= iterationBudget / 3 : iterationsUsed <= 3)
            return trivial ? .overEscalated : nil
        }
        return nil
    }
}

public enum RoutingMisfit: String, Sendable, Codable, Equatable {
    case underEscalated   // went too light → struggled/failed
    case overEscalated    // went too heavy → trivial in hindsight
}

/// A stable, cross-process config fingerprint. Swift's built-in `Hasher` is per-process seeded, so it is
/// UNSAFE for `orgVersion` (two runs in different processes on the same config would hash differently and
/// break before/after comparison). This is a deterministic FNV-1a over the sorted key=value pairs.
public enum OrgFingerprint {
    public static func make(_ keyValues: [String: String]) -> String {
        let canonical = keyValues.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        return String(FNV1a.hash64(canonical), radix: 16)   // canonical FNV-1a (constants were inlined here)
    }
}
