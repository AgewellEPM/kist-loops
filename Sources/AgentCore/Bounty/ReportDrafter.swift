import Foundation

/// Turns a REPORT-READY finding into a disclosure. The hard rule (plan + wizard step 4): a finding cannot
/// even be DRAFTED until it has a reproducible PoC that passed the adversarial re-check — so this refuses
/// (throws) for anything that isn't `.reportReady`. You literally cannot generate the AI-slop that gets a
/// hunter banned, because the draft path is closed to unproven findings.
public enum ReportDraftError: Error, Equatable {
    case notReportReady(reason: String)
    case missingProof   // report-ready but PoC/repro somehow absent (defensive; should not happen)
}

public struct ReportDrafter: Sendable {
    public init() {}

    public func draft(_ v: VerifiedBountyFinding,
                      program: BountyProgramRules,
                      programName: String) throws -> DisclosureReport {
        guard v.isReportReady else {
            throw ReportDraftError.notReportReady(reason: v.verdict.dropReason ?? "finding is not report-ready")
        }
        guard let poc = v.poc, let repro = v.repro, repro.reproduced else {
            throw ReportDraftError.missingProof
        }
        let f = v.finding
        let asset = v.panel?.matchedTarget ?? poc.targetHost ?? poc.targetRepo ?? "(attested target)"
        let payout = program.payoutTableUSD[f.severity.rawValue]

        let summary = "\(f.title) at `\(f.file):\(f.line)`. Detected by rule `\(f.rule)` and confirmed by an "
            + "adversarial refute panel plus a deterministic reproduction — this is not a speculative finding."
        let steps = poc.reproSteps + "\nExpected signal: \(poc.expectedSignal)"
        let proof = "Reproduced: \(repro.observed)\nEvidence: \(f.evidence)"
        let impact = Self.impact(for: f)
        let remediation = f.recommendation

        return DisclosureReport(
            findingId: f.id, program: programName, title: f.title, severity: f.severity,
            asset: asset, vulnClass: poc.vulnClass, owasp: f.owasp, summary: summary,
            stepsToReproduce: steps, impact: impact, remediation: remediation,
            proofOfConcept: proof, estimatedPayoutUSD: payout)
    }

    /// A grounded, category-based impact statement (no invented severity claims).
    static func impact(for f: SecurityFinding) -> String {
        let base: String
        switch f.category {
        case .secret:        base = "A committed credential can be used directly by anyone with repo access to impersonate the service or pivot to connected systems."
        case .dependency:    base = "A vulnerable/unpinned dependency exposes the app to known CVEs and supply-chain tampering."
        case .codeInjection: base = "Attacker-controlled input reaching this sink allows command/query injection — potential remote code execution or data access."
        case .crypto:        base = "Weak or misused cryptography undermines confidentiality/integrity of the protected data."
        case .config:        base = "This insecure configuration weakens the app's transport/security posture and broadens the attack surface."
        }
        return base + " Severity assessed as \(f.severity.rawValue) from the detector; the program triager sets the final rating."
    }
}
