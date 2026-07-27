import Foundation

/// Maps the runtime's actual safety mechanisms to the OWASP Top-10 for Agentic Applications (2026) —
/// an honest governance posture buyers can attest against. Each control states whether we mitigate the
/// risk, with EVIDENCE pointing at the real mechanism (file/type), and names residual GAPS. Honesty is
/// the whole point: an aspirational compliance report is worse than none.
public struct ComplianceControl: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable { case satisfied, partial, gap }
    public let risk: String           // OWASP agentic risk id + name
    public let status: Status
    public let mechanism: String       // how we address it
    public let evidence: [String]      // concrete file/type references (grounding)
    public let gap: String?            // residual risk, if any
    public init(risk: String, status: Status, mechanism: String, evidence: [String], gap: String? = nil) {
        self.risk = risk; self.status = status; self.mechanism = mechanism; self.evidence = evidence; self.gap = gap
    }
}

public enum ComplianceMapper {
    /// The curated, code-grounded mapping. Each entry reflects what's ACTUALLY in the runtime today.
    public static let controls: [ComplianceControl] = [
        .init(risk: "AAI01 Goal/Prompt Hijacking", status: .partial,
              mechanism: "Plan mode (read-only proposal), approval gates on sensitive tools, brief compilation",
              evidence: ["HeadlessAgentLoop (planMode)", "TerminalInteractor", "PromptCompiler"],
              gap: "No dedicated prompt-injection classifier on tool outputs/web content."),
        .init(risk: "AAI02 Tool Misuse / Injection", status: .partial,
              mechanism: "Deny/allow/approve shell policy, structured argv spawn (no shell), confined FS, SSRF-guarded fetch/browser requests, browser screenshot path confinement",
              evidence: ["ShellPolicy", "ConfinedRoot", "ProcessGroupRunner", "WebFetchTool", "BrowserTool"],
              gap: "Browser tool is still PROTOTYPE/live-unverified and depends on Playwright request interception; no dedicated network proxy policy yet."),
        .init(risk: "AAI03 Identity Abuse", status: .gap,
              mechanism: "—",
              evidence: [],
              gap: "No agent identity (DID) or behavioral trust scoring — Tier-3 roadmap item."),
        .init(risk: "AAI04 Memory Poisoning", status: .satisfied,
              mechanism: "Memory is retrieval-only + advisory; 'proven' requires a real source; never a verdict authority",
              evidence: ["LessonStore (proven⇒source invariant)", "ProjectMemory (planningContext is CONTEXT not policy)"]),
        .init(risk: "AAI05 Cascading Failures (multi-agent)", status: .satisfied,
              mechanism: "Disjoint validated leases, bounded sweeps, delegation-depth cap, per-agent signoff gate",
              evidence: ["FleetScopeValidator", "FleetSupervisor", "SpawnAgentTool (depth budget)"]),
        .init(risk: "AAI06 Rogue Agent / Unbounded Autonomy", status: .satisfied,
              mechanism: "maxIterations + replan budget, git-isolated worktrees (never main), merge gate refuses off-lease/unsigned",
              evidence: ["HeadlessAgentLoop (maxIterations)", "GitIsolation", "FleetSupervisor.joinSignedBranches"]),
        .init(risk: "AAI07 Unverified / Hallucinated Output", status: .satisfied,
              mechanism: "Claim reconciliation vs committed diff + tests; grounded verdict; Foreman six-gate; deterministic audit findings",
              evidence: ["ClaimReconciler", "GroundedVerdict", "Foreman", "SecurityAuditor (no LLM in finding path)"]),
        .init(risk: "AAI08 Excessive Agency / Over-Privilege", status: .satisfied,
              mechanism: "Least-privilege tools, shell OFF by default, plan mode, opt-in OS sandbox",
              evidence: ["ShellPolicy.denied (default)", "SeatbeltSandbox", "ToolContext"]),
        .init(risk: "AAI09 Sensitive Information Disclosure", status: .satisfied,
              mechanism: "Secret masking in output, secret scanner with redaction (raw secret never leaves the tool)",
              evidence: ["SecretMasker", "SecretScanner.redact"]),
        .init(risk: "AAI10 Insecure Supply Chain", status: .partial,
              mechanism: "Dependency-hygiene scan (unpinned versions), pinned lockfile",
              evidence: ["DependencyAuditor", "Package.resolved"],
              gap: "No live CVE database lookup yet — flags hygiene, not known-vulnerable versions."),
        .init(risk: "AAIx Observability", status: .partial,
              mechanism: "Per-call trace spans, deterministic trajectory incident detectors wired into live runs, eval harness",
              evidence: ["AgentTrace", "TrajectoryAnalyzer", "EvalRunner", "KistRunner", "KistREPL", "TUIConversation"],
              gap: "No OpenTelemetry export / live dashboard yet; terminal self-checks are local-only."),
    ]

    public static func report() -> String {
        let satisfied = controls.filter { $0.status == .satisfied }.count
        let partial = controls.filter { $0.status == .partial }.count
        let gaps = controls.filter { $0.status == .gap }.count
        var s = "Governance posture · OWASP Top-10 Agentic (2026)\n"
        s += "\(satisfied) satisfied · \(partial) partial · \(gaps) gap\n"
        for c in controls {
            let mark = c.status == .satisfied ? "✓" : (c.status == .partial ? "◐" : "✗")
            s += "\n\(mark) [\(c.status.rawValue)] \(c.risk)\n"
            s += "    how: \(c.mechanism)\n"
            if !c.evidence.isEmpty { s += "    evidence: \(c.evidence.joined(separator: ", "))\n" }
            if let gap = c.gap { s += "    gap: \(gap)\n" }
        }
        return s
    }
}
