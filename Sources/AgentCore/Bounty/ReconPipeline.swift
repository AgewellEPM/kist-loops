import Foundation

// MARK: - Pass 3: scope+rules-gated recon → candidate findings + drafted PoCs
//
// Recon is the intake that FEEDS the verify spine (Pass 2). It is deliberately narrow and safe: it runs
// the existing DETERMINISTIC source scanners (SecurityAuditor: secrets/SAST/dependency) over an ATTESTED
// repo, behind the Pass-1 gate, and turns each grounded finding into a candidate with a drafted PoC.
//
// Two hard properties:
//   • It never runs unless `BountyGate` authorizes recon on the repo (scope + automation policy). An
//     out-of-scope or automation-banned program yields a refusal, not a scan.
//   • It only surfaces findings whose vuln class the program ACCEPTS — source findings skip the gate's
//     (active-only) class check, so recon is where that program-interest filter is enforced.
//
// Live-host DAST is intentionally OUT of Pass 3 (bigger, riskier surface); source recon is the safe,
// high-signal starting point. The candidates it emits are unproven until the verify spine reproduces them.

public struct ReconTarget: Sendable, Equatable {
    public let repo: String   // "owner/name" — MUST be attested in the engagement
    public let root: String   // local checkout path to scan (a trusted, confined absolute path)
    public init(repo: String, root: String) { self.repo = repo; self.root = root }
}

/// A grounded finding paired with the PoC the verify spine will try to reproduce.
public struct ReconCandidate: Sendable, Equatable {
    public let finding: SecurityFinding
    public let pocDraft: ProofOfConcept
}

public struct ReconReport: Sendable, Equatable {
    public let repo: String
    public let filesScanned: Int
    public let candidates: [ReconCandidate]     // in-scope AND in an accepted vuln class
    public let droppedOutOfClass: Int           // grounded findings the program doesn't accept (not reported)
    public let note: String
}

public enum ReconOutcome: Sendable, Equatable {
    case refused(reason: String, rule: String?)
    case completed(ReconReport)
}

public struct ReconPipeline: Sendable {
    public let gate: BountyGate
    public init(gate: BountyGate = BountyGate()) { self.gate = gate }

    public func run(target: ReconTarget, engagement: SecurityEngagement, rules: BountyProgramRules) -> ReconOutcome {
        // 1) AUTHORIZE recon — passive source review of an attested repo. Fail-closed: no scan on refusal.
        let action = BountyAction(targetRepo: target.repo, vulnClass: "", method: .passiveRecon, isAutomated: true)
        let decision = gate.evaluate(action, engagement: engagement, rules: rules)
        guard decision.isAllowed else {
            return .refused(reason: decision.reason, rule: decision.ruleHit)
        }

        // 2) DETERMINISTIC scan (no LLM in the finding path → grounded by construction).
        let report = SecurityAuditor.audit(root: target.root)

        // 3) KEEP only findings whose class the program accepts; draft a PoC for each survivor.
        var candidates: [ReconCandidate] = []
        var dropped = 0
        for f in report.findings {
            let cls = Self.vulnClass(for: f.category)
            guard rules.isAllowed(vulnClass: cls) else { dropped += 1; continue }
            candidates.append(ReconCandidate(finding: f, pocDraft: Self.draftPoC(for: f, repo: target.repo, vulnClass: cls)))
        }
        let note = "recon of \(target.repo): \(report.filesScanned) files, \(candidates.count) in-class candidate(s)"
            + (dropped > 0 ? ", \(dropped) finding(s) dropped as out-of-program-class" : "")
            + " — all UNPROVEN until the verify spine reproduces them"
        return .completed(ReconReport(repo: target.repo, filesScanned: report.filesScanned,
                                      candidates: candidates, droppedOutOfClass: dropped, note: note))
    }

    /// A source-level PoC: reproduction is a deterministic RE-SCAN of the file (no target traffic), so its
    /// method is passive. `SourceRescanReproducer` executes it. The human/report drafter refines it later.
    static func draftPoC(for f: SecurityFinding, repo: String, vulnClass: String) -> ProofOfConcept {
        ProofOfConcept(
            findingId: f.id, summary: f.title, method: .passiveRecon,
            targetHost: nil, targetRepo: repo, vulnClass: vulnClass, requestsPerSecond: nil,
            reproSteps: "Re-scan \(f.file) with the deterministic analyzer; assert rule '\(f.rule)' fires at line \(f.line).",
            expectedSignal: f.evidence)
    }

    /// Map a finding category to a canonical program vuln-class tag. Programs list which they accept.
    static func vulnClass(for c: SecurityFinding.Category) -> String {
        switch c {
        case .secret:        return "secret"
        case .dependency:    return "dependency"
        case .codeInjection: return "injection"
        case .crypto:        return "crypto"
        case .config:        return "config"
        }
    }
}
