import Foundation

/// An LLM-backed skeptic for the adversarial panel. Its ONLY job is to try to REFUTE a finding — it can
/// down-rank one but can never mint one. Fail-closed toward refuted: an empty/ambiguous/errored model
/// response counts as "I couldn't confirm this," which drops the finding rather than promoting it.
public struct LLMFindingRefuter: FindingRefuter {
    public typealias Complete = @Sendable (_ system: String, _ user: String) async -> String?
    private let complete: Complete
    public init(complete: @escaping Complete) { self.complete = complete }

    static let system = """
    You are a skeptical security reviewer on a bug-bounty triage panel. Your ONLY job is to try to REFUTE \
    the finding below: is it a false positive, not reachable, not exploitable in real context, or already \
    obviously known/duplicate? Default to refuting when uncertain — a wrong report gets the hunter banned. \
    Answer on the FIRST line with exactly one word: CONFIRM (it is a real, in-context issue) or REFUTE \
    (it is not). Then one short sentence of reasoning.
    """

    public func refute(_ finding: SecurityFinding) async -> RefuteVote {
        let user = """
        Finding: \(finding.title)
        Severity: \(finding.severity.rawValue)  Rule: \(finding.rule)  Category: \(finding.category.rawValue)
        Location: \(finding.file):\(finding.line)
        Evidence: \(finding.evidence)
        OWASP: \(finding.owasp ?? "n/a")
        """
        guard let raw = await complete(Self.system, user)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return RefuteVote(refuted: true, reason: "no model response — fail-closed to refuted")
        }
        let lower = raw.lowercased()
        let firstLine = lower.split(whereSeparator: \.isNewline).first.map(String.init) ?? lower
        // Confirm ONLY when the FIRST WORD is exactly "confirm". A substring check fails OPEN — "cannot
        // confirm", "confirmed false positive", "unable to confirm" all contain "confirm" and would wrongly
        // promote a finding the model actually refused. The skeptic default is refuted, so anything but a
        // clean leading "confirm" (incl. a leading "refute") stays refuted. (Panel review found this.)
        let firstWord = firstLine.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        // Strictest: the first word must be exactly "confirm" AND the line must not also hedge with "refute".
        let confirmed = firstWord == "confirm" && !firstLine.contains("refute")
        return RefuteVote(refuted: !confirmed, reason: String(raw.prefix(200)))
    }
}

/// Deterministic fallback skeptic for when no model is available (offline / no key). It refutes anything
/// below a severity floor — a rubber-stamp-free stand-in so the panel still has teeth. The REAL reproduction
/// gate is what ultimately proves a source finding; this keeps low-signal noise from becoming report-ready.
public struct SeverityThresholdRefuter: FindingRefuter {
    public let floor: SecurityFinding.Severity
    public init(minConfirmable floor: SecurityFinding.Severity = .medium) { self.floor = floor }
    public func refute(_ finding: SecurityFinding) async -> RefuteVote {
        if finding.severity < floor {
            return RefuteVote(refuted: true, reason: "below the \(floor.rawValue) confirmable floor (deterministic panel)")
        }
        return RefuteVote(refuted: false, reason: "at/above the confirmable floor (deterministic panel)")
    }
}
