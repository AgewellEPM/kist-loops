import Foundation

/// The top-level self-evolution decision: classify → route → resolve the concrete recovery, applying the
/// loop-guard for the risky (extendTool) path. A wiring layer calls `decide(...)` at a failed run and ACTS
/// on the result — inject a discovery-retry, open a capability-extension mission, surface a block, or hand
/// to the existing repair. Pure and fully testable; the actual tool calls / model calls live at the edge.
public struct SelfEvolutionDecision: Sendable, Equatable {
    public let category: FailureCategory
    public let kind: RecoveryKind
    /// The actionable instruction for this recovery (drives the self-heal brief / retry).
    public let brief: String
    public let culpritTool: String?
    /// Set for `.discoverAndRetry` — how to discover the tool's real capabilities and retry.
    public let discovery: DiscoveryStep?
    /// Set for `.extendTool` — may kist auto-evolve it (kist) or only spec it (foreign)?
    public let ownership: ToolOwnership?
    public let foreignServer: String?
    /// Set for `.extendTool` — ledger key so the same wall never triggers a second unattended evolution.
    public let signature: String?
    /// Non-nil when the ledger guard BLOCKED a repeat/rate-capped evolution (self-deployer safety).
    public let skipped: String?

    public init(category: FailureCategory, kind: RecoveryKind, brief: String, culpritTool: String?,
                discovery: DiscoveryStep?, ownership: ToolOwnership?, foreignServer: String?,
                signature: String?, skipped: String?) {
        self.category = category; self.kind = kind; self.brief = brief; self.culpritTool = culpritTool
        self.discovery = discovery; self.ownership = ownership; self.foreignServer = foreignServer
        self.signature = signature; self.skipped = skipped
    }
}

public enum SelfEvolutionEngine {

    public static func decide(signals: FailureSignals,
                              availableTools: [String],
                              ledgerHistory: [SelfEvolutionAttempt] = [],
                              now: Double,
                              maxAttemptsPerWindow: Int = 3,
                              windowSeconds: Double = 3600) -> SelfEvolutionDecision {
        let verdict = FailureClassifier.classify(signals)
        let plan = FailureRouter.plan(for: verdict)

        switch plan.kind {
        case .discoverAndRetry:
            let step = CapabilityDiscovery.step(tool: verdict.culpritTool ?? "",
                                                hint: verdict.discoveryHint,
                                                availableTools: availableTools)
            return SelfEvolutionDecision(
                category: verdict.category, kind: plan.kind, brief: step.brief,
                culpritTool: verdict.culpritTool, discovery: step,
                ownership: nil, foreignServer: nil, signature: nil, skipped: nil)

        case .extendTool:
            let tool = verdict.culpritTool ?? ""
            let owner = ToolOwnershipResolver.owner(of: tool)
            let server = ToolOwnershipResolver.foreignServer(of: tool)
            let sig = SelfEvolutionLedger.signature(tool: tool, evidence: verdict.evidence)
            // LOOP-GUARD (applies to the ONLY self-modifying path): never repeat a resolved evolution, and
            // never exceed the per-window cap.
            let guardDecision = SelfEvolutionLedger.decideShouldAttempt(
                signature: sig, now: now, history: ledgerHistory,
                maxAttemptsPerWindow: maxAttemptsPerWindow, windowSeconds: windowSeconds)
            guard guardDecision.ok else {
                return SelfEvolutionDecision(
                    category: verdict.category, kind: plan.kind,
                    brief: "SKIPPED self-evolution — \(guardDecision.reason). \(plan.brief)",
                    culpritTool: tool, discovery: nil, ownership: owner, foreignServer: server,
                    signature: sig, skipped: guardDecision.reason)
            }
            // Foreign tool: spec-only (never blend repos) — say so in the brief.
            let brief = owner == .foreign
                ? "\(plan.brief)\n\n`\(tool)` belongs to the ‘\(server ?? "external")’ system — write a "
                    + "capability SPEC for its owner; do NOT edit that repo from here."
                : "\(plan.brief)\n\n`\(tool)` is a native kist tool — auto-evolve it: implement the smallest "
                    + "safe extension WITH tests; it ships only after the regression gate AND an independent "
                    + "adversarial review pass (never self-certify)."
            return SelfEvolutionDecision(
                category: verdict.category, kind: plan.kind, brief: brief,
                culpritTool: tool, discovery: nil, ownership: owner, foreignServer: server,
                signature: sig, skipped: nil)

        case .surfaceBlocked, .repairCode, .repairSchema, .repairEnvironment, .reverify:
            return SelfEvolutionDecision(
                category: verdict.category, kind: plan.kind, brief: plan.brief,
                culpritTool: verdict.culpritTool, discovery: nil, ownership: nil,
                foreignServer: nil, signature: nil, skipped: nil)
        }
    }
}
