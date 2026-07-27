import Foundation

/// The bug-bounty TRUST EDGE: a deterministic scanner produces grounded findings (SecurityFinding —
/// file+line+evidence, no LLM invented it), then this layer does two things before anything is
/// report-worthy:
///
///   1. SCOPE-BIND (fail-closed): a finding on a repo/host that is NOT in the attested engagement scope
///      is dropped as `.outOfScope`. You never report a vuln on a target you weren't authorized to test.
///   2. ADVERSARIALLY VERIFY: each in-scope finding faces a panel of skeptics whose ONLY job is to
///      REFUTE it (false positive? not reachable? not exploitable in context?). A finding is `.confirmed`
///      only if it survives — a strict minority of the panel refute it. Majority-refute ⇒ `.refuted`.
///      No panel ⇒ `.unverified` (held, never auto-promoted). LLMs enter here ONLY as refuters; they can
///      down-rank a finding but can NEVER mint one — the antidote to the frontier's fake-exploit problem.
public enum FindingVerdict: String, Sendable, Codable, Equatable {
    case confirmed    // in scope AND survived the refute panel → report-ready
    case refuted      // panel majority refuted it → dropped
    case unverified   // in scope but no panel ran → held, NOT report-ready
    case outOfScope   // not bound to any attested target → dropped, fail-closed
}

/// One skeptic's attempt to refute a finding. `refuted == true` means "I do not believe this is a real,
/// in-context, exploitable issue." Default toward refuted when uncertain (a skeptic, not a cheerleader).
public struct RefuteVote: Sendable, Codable, Equatable {
    public let refuted: Bool
    public let reason: String
    public init(refuted: Bool, reason: String) { self.refuted = refuted; self.reason = reason }
}

/// A skeptic. Real implementations call an LLM with a refute-this prompt; tests inject deterministic stubs.
/// It is handed an immutable finding and returns a vote — it CANNOT create or mutate findings.
public protocol FindingRefuter: Sendable {
    func refute(_ finding: SecurityFinding) async -> RefuteVote
}

public struct VerifiedFinding: Sendable, Codable, Equatable {
    public let finding: SecurityFinding
    public let verdict: FindingVerdict
    public let matchedTarget: String?   // the attested target this binds to (nil when out of scope)
    public let refuteCount: Int
    public let panelSize: Int
    public let rationale: String

    public init(finding: SecurityFinding, verdict: FindingVerdict, matchedTarget: String?,
                refuteCount: Int, panelSize: Int, rationale: String) {
        self.finding = finding; self.verdict = verdict; self.matchedTarget = matchedTarget
        self.refuteCount = refuteCount; self.panelSize = panelSize; self.rationale = rationale
    }

    /// The only findings that may appear in a submission/report. Everything else is held or dropped.
    public var isReportReady: Bool { verdict == .confirmed }
}

public enum FindingVerifier {

    /// Scope-bind then adversarially verify a deterministic audit. `auditRepo` is the "owner/name" the
    /// audit ran against — every file finding binds to it, so an audit of an UNAUTHORIZED repo yields ALL
    /// `.outOfScope` (you can't report what you weren't allowed to look at). Confirmation rule: strict
    /// minority refute (refuteCount * 2 < panelSize). Tie or majority ⇒ refuted. Empty panel ⇒ unverified.
    public static func verify(findings: [SecurityFinding],
                              engagement: SecurityEngagement,
                              auditRepo: String,
                              panel: [FindingRefuter]) async -> [VerifiedFinding] {
        let scope = engagement.inScope(repo: auditRepo)
        guard case let .inScope(target) = scope else {
            // Fail-closed: the whole audit is out of scope. Every finding is dropped with a clear reason.
            let reason = { if case let .outOfScope(r) = scope { return r }; return "out of scope" }()
            return findings.map {
                VerifiedFinding(finding: $0, verdict: .outOfScope, matchedTarget: nil,
                                refuteCount: 0, panelSize: 0, rationale: reason)
            }
        }
        var out: [VerifiedFinding] = []
        for f in findings {
            if panel.isEmpty {
                out.append(VerifiedFinding(finding: f, verdict: .unverified, matchedTarget: target.value,
                                           refuteCount: 0, panelSize: 0,
                                           rationale: "in scope (\(target.value)) but no refute panel ran — held, not report-ready"))
                continue
            }
            var refutes = 0
            var reasons: [String] = []
            for skeptic in panel {
                let v = await skeptic.refute(f)
                if v.refuted { refutes += 1; reasons.append(v.reason) }
            }
            let confirmed = refutes * 2 < panel.count   // strict minority refuted → survives
            let verdict: FindingVerdict = confirmed ? .confirmed : .refuted
            let tally = "refuted \(refutes)/\(panel.count)"
            let why = confirmed
                ? "in scope (\(target.value)); survived refute panel (\(tally))"
                : "in scope (\(target.value)) but refuted by the panel (\(tally))" + (reasons.isEmpty ? "" : ": \(reasons.prefix(2).joined(separator: "; "))")
            out.append(VerifiedFinding(finding: f, verdict: verdict, matchedTarget: target.value,
                                       refuteCount: refutes, panelSize: panel.count, rationale: why))
        }
        return out
    }
}
