import Foundation

// MARK: - The guided wizard (beginner mode) — the UX that sequences passes 1–5
//
// This is the headless ORCHESTRATOR a UI drives (a REPL command or a view). It teaches the game AS it
// runs, and the verify spine makes that SAFE for a beginner: it blocks the exact mistakes that get
// newcomers banned. It NEVER submits — it hands a drafted report back with a "you review and file this"
// step. Each stage carries plain-language coaching so the user learns by doing.

public struct WizardStep: Sendable, Equatable {
    public let stage: String
    public let title: String
    public let teaching: String    // plain-language "learn the game" coaching
    public let detail: String      // what actually happened / what to do now
    public let needsHuman: Bool
}

public struct WizardOutcome: Sendable {
    public let steps: [WizardStep]
    public let prioritized: [PrioritizedFinding]
    public let topDraft: DisclosureReport?   // the best report-ready finding, drafted for HUMAN review
    public let reportReadyCount: Int
    public let candidateCount: Int
    public let refusedReason: String?        // set if recon itself was refused (out of scope, automation banned)
}

public struct BountyWizard: Sendable {
    public let gate: BountyGate
    public init(gate: BountyGate = BountyGate()) { self.gate = gate }

    /// The just-in-time intro lesson (wizard step 1). Short and plain — not a textbook.
    public static func teach() -> String {
        """
        Bug bounty in one breath: it's AUTHORIZED testing. A program publishes a SCOPE (the exact assets you
        may test) and RULES (rate limits, whether tooling is allowed, which bug types count). You stay strictly
        in scope, follow the rules, and — this is the whole game — you only report what you can PROVE. The
        platforms are drowning in AI-guessed false positives and are banning people for it. Our edge is the
        opposite: we refuse to report anything that doesn't reproduce. A human always files the report.
        """
    }

    /// Run the source-recon flow end to end and return a narrated outcome. Never submits.
    public func run(target: ReconTarget,
                    engagement: SecurityEngagement,
                    rules: BountyProgramRules,
                    panel: [FindingRefuter],
                    priorSubmissions: [SubmissionRecord] = []) async -> WizardOutcome {
        var steps: [WizardStep] = []
        steps.append(WizardStep(stage: "welcome", title: "What you're about to do",
            teaching: Self.teach(), detail: "We'll recon an in-scope target, prove any real issues, and draft a report you file yourself.",
            needsHuman: false))
        steps.append(WizardStep(stage: "program", title: "Scope + rules loaded",
            teaching: "Scope = what you may touch; rules = how. Everything is fail-closed: not explicitly allowed ⇒ refused.",
            detail: "Program '\(engagement.program)' · targets: \(engagement.targets.count) · automation: \(rules.automation.rawValue) · accepted classes: \(rules.allowedVulnClasses.sorted().joined(separator: ", ").ifEmptyBounty("none"))",
            needsHuman: false))

        // Pass 3 — recon (gated)
        let recon = ReconPipeline(gate: gate).run(target: target, engagement: engagement, rules: rules)
        guard case .completed(let report) = recon else {
            let reason: String = { if case .refused(let r, _) = recon { return r }; return "recon refused" }()
            steps.append(WizardStep(stage: "recon", title: "Recon refused (this is the guardrail working)",
                teaching: "If the target isn't in your attested scope — or the program bans tooling — we don't scan. That refusal is what keeps you legal.",
                detail: reason, needsHuman: true))
            return WizardOutcome(steps: steps, prioritized: [], topDraft: nil,
                                 reportReadyCount: 0, candidateCount: 0, refusedReason: reason)
        }
        steps.append(WizardStep(stage: "recon", title: "Recon found candidates (UNPROVEN)",
            teaching: "A scanner flags patterns; do NOT trust them yet. These are leads, not bugs — most scanner hits are noise.",
            detail: report.note, needsHuman: false))

        // Pass 2 — verify each candidate (the moat), with the real source reproducer
        let reproducer = SourceRescanReproducer(root: target.root, findings: report.candidates.map(\.finding))
        let verifier = BountyFindingVerifier(gate: gate, reproducer: reproducer)
        var reportReady: [VerifiedBountyFinding] = []
        for c in report.candidates {
            let v = await verifier.verify(finding: c.finding, poc: c.pocDraft, engagement: engagement,
                                          rules: rules, auditRepo: target.repo, panel: panel)
            if v.isReportReady { reportReady.append(v) }
        }
        steps.append(WizardStep(stage: "verify", title: "Verified — the moat",
            teaching: "Each candidate must be authorized to reproduce, survive a skeptic panel, AND actually reproduce. Anything that can't is DROPPED as a false positive. This is what keeps you off the ban list.",
            detail: "\(report.candidates.count) candidate(s) → \(reportReady.count) reproduced & report-ready",
            needsHuman: false))

        // Pass 5 — prioritize
        let ranked = FindingPrioritizer(priorSubmissions: priorSubmissions).rank(reportReady.map(\.finding), program: rules)
        steps.append(WizardStep(stage: "prioritize", title: "Prioritized",
            teaching: "Work novel, severe, better-paying issues first; likely duplicates sink — a dup wastes time and doesn't pay.",
            detail: ranked.isEmpty ? "nothing report-ready to prioritize"
                                   : ranked.prefix(3).map { "• \($0.rationale)" }.joined(separator: "\n"),
            needsHuman: false))

        // Pass 4 — draft the top finding (refuses non-report-ready by construction)
        var topDraft: DisclosureReport? = nil
        if let top = ranked.first, let v = reportReady.first(where: { $0.finding.id == top.finding.id }) {
            topDraft = try? ReportDrafter().draft(v, program: rules, programName: engagement.program)
        }
        if let topDraft {
            steps.append(WizardStep(stage: "draft", title: "Report drafted for your review",
                teaching: "A good report: summary, exact repro steps, proof, impact, fix — all grounded in what actually reproduced. No speculation.",
                detail: topDraft.renderMarkdown(), needsHuman: true))
            steps.append(WizardStep(stage: "submit", title: "You submit — never the tool",
                teaching: "Review the draft and file it on the platform YOURSELF. One bad auto-filed report can torch your reputation, so a human always stays on the button.",
                detail: "When you've reviewed it, submit on the program platform, then record the outcome so your reputation tracks.",
                needsHuman: true))
        } else {
            steps.append(WizardStep(stage: "draft", title: "Nothing to report (and that's the point)",
                teaching: "No candidate reproduced, so there's nothing to file. Reporting an unproven bug is exactly what gets people banned — we didn't.",
                detail: "0 report-ready findings. Try another in-scope asset or a different vuln class the program accepts.",
                needsHuman: false))
        }

        steps.append(WizardStep(stage: "coach", title: "Track + learn",
            teaching: "Record every outcome. Accepted/paid build reputation (you get triaged faster over time); duplicates/rejections teach you what's already known. Reputation compounds.",
            detail: "Use the submission tracker to log what you file and its result.", needsHuman: false))

        return WizardOutcome(steps: steps, prioritized: ranked, topDraft: topDraft,
                             reportReadyCount: reportReady.count, candidateCount: report.candidates.count,
                             refusedReason: nil)
    }
}

private extension String {
    /// Small local helper so an empty class list renders as a word, not a blank.
    func ifEmptyBounty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
