import Foundation

/// A drafted disclosure — the program-facing writeup of a VERIFIED finding. It exists ONLY for a
/// report-ready finding (see `ReportDrafter`), so by construction there is no such thing as a draft for an
/// unproven/refuted bug. Every field is populated from grounded data (the finding, its reproduced PoC),
/// not invented — the same no-fabrication spine, carried to the last mile.
public struct DisclosureReport: Sendable, Codable, Equatable {
    public let findingId: String
    public let program: String
    public let title: String
    public let severity: SecurityFinding.Severity
    public let asset: String            // the attested target this binds to (repo or host)
    public let vulnClass: String
    public let owasp: String?
    public let summary: String
    public let stepsToReproduce: String
    public let impact: String
    public let remediation: String
    public let proofOfConcept: String   // repro recipe + the observed signal that confirmed it
    public let estimatedPayoutUSD: Int? // looked up from the program payout table by severity — informational

    public init(findingId: String, program: String, title: String, severity: SecurityFinding.Severity,
                asset: String, vulnClass: String, owasp: String?, summary: String, stepsToReproduce: String,
                impact: String, remediation: String, proofOfConcept: String, estimatedPayoutUSD: Int?) {
        self.findingId = findingId; self.program = program; self.title = title; self.severity = severity
        self.asset = asset; self.vulnClass = vulnClass; self.owasp = owasp; self.summary = summary
        self.stepsToReproduce = stepsToReproduce; self.impact = impact; self.remediation = remediation
        self.proofOfConcept = proofOfConcept; self.estimatedPayoutUSD = estimatedPayoutUSD
    }

    /// A clean Markdown disclosure in the shape triagers expect. Deterministic; secrets already redacted
    /// upstream in the finding evidence. This is what the human reviews before submitting.
    public func renderMarkdown() -> String {
        var s = "# \(title)\n\n"
        s += "- **Program:** \(program)\n"
        s += "- **Severity:** \(severity.rawValue.uppercased())\n"
        s += "- **Asset:** \(asset)\n"
        s += "- **Class:** \(vulnClass)\(owasp.map { " (\($0))" } ?? "")\n"
        if let p = estimatedPayoutUSD { s += "- **Est. payout (program table):** $\(p)\n" }
        s += "\n## Summary\n\(summary)\n"
        s += "\n## Steps to reproduce\n\(stepsToReproduce)\n"
        s += "\n## Proof of concept\n\(proofOfConcept)\n"
        s += "\n## Impact\n\(impact)\n"
        s += "\n## Remediation\n\(remediation)\n"
        s += "\n---\n_Verified by reproduction before disclosure. A human reviews and submits; nothing is auto-filed._\n"
        return s
    }
}
