import Foundation
import AgentCore

/// Why is confidence X — and what would raise it? The dashboard used to derive confidence as a bare
/// `Double` and throw the reasoning away, so the number was unexplainable ("why is it 62%?" had no
/// answer). This model keeps the *factors* that produced the score, each with the concrete action an
/// agent (or Luke) can take to raise it. It is the single source of truth for both the inline panel
/// gauge and the `/confidence` (`/why`) command. Pure → unit-tested.
public struct ConfidenceReport: Sendable, Equatable {
    /// One contributor to (or drag on) the score.
    public struct Factor: Sendable, Equatable {
        public let label: String     // "Reliability", "Health", "Grounding"
        public let penalty: Double   // amount subtracted from the ceiling (>= 0)
        public let detail: String    // the evidence — why this factor stands where it does
        public let raise: String     // the concrete move that recovers this penalty ("" when already clean)
        public init(label: String, penalty: Double, detail: String, raise: String) {
            self.label = label; self.penalty = max(0, penalty); self.detail = detail; self.raise = raise
        }
        /// Clean: contributes no drag. Float slop guarded so 0.0 reads as OK.
        public var ok: Bool { penalty <= 0.0001 }
    }

    public let score: Double      // 0.30…0.98, clamped identically to the legacy formula
    public let base: Double       // the ceiling the penalties are subtracted from (0.95)
    public let factors: [Factor]

    public init(score: Double, base: Double, factors: [Factor]) {
        self.score = min(0.98, max(0.30, score)); self.base = base; self.factors = factors
    }

    /// Factors currently dragging the score down — the "to raise it, do these" list.
    public var pending: [Factor] { factors.filter { !$0.ok } }
    public var percent: Int { Int((score * 100).rounded()) }
    /// Battery color by charge level: green healthy, amber caution, red low. Bright variants so it
    /// reads as a gauge, not body text.
    public var batteryCode: String { score >= 0.75 ? "92;1" : (score >= 0.5 ? "93;1" : "91;1") }

    /// Build from the same primitives `buildDashboard` already has, so the panel and `/confidence`
    /// agree to the decimal. Returns nil when there were no tool actions (a plain answer has nothing
    /// to score — matching the old `trajectory.isEmpty ⇒ nil confidence`).
    public static func compute(report: TrajectoryReport, grounded: Bool, base: Double = 0.95) -> ConfidenceReport? {
        guard report.toolCalls > 0 else { return nil }

        // 1) Reliability — failed tool calls. Same weight (0.4) as the legacy formula.
        let relPenalty = report.failureRate * 0.4
        let failPct = Int((report.failureRate * 100).rounded())
        let reliability = Factor(
            label: "Reliability",
            penalty: relPenalty,
            detail: report.failures == 0
                ? "all \(report.toolCalls) tool call(s) succeeded"
                : "\(report.failures)/\(report.toolCalls) tool call(s) failed (\(failPct)%)",
            raise: report.failures == 0
                ? ""
                : "re-run or drop the failing step(s) so the trajectory comes back clean")

        // 2) Health — deterministic reliability issues (runaway loops, no-progress, failure spikes).
        let healthPenalty = report.healthy ? 0 : 0.15
        let issueKinds = report.issues.map { $0.kind.rawValue }.joined(separator: ", ")
        let health = Factor(
            label: "Health",
            penalty: healthPenalty,
            detail: report.healthy ? "no reliability issues detected" : "issues: \(issueKinds)",
            raise: report.healthy ? "" : "resolve the trajectory issue(s) — \(healthRaiseHint(report.issues))")

        // 3) Grounding — did the answer touch real files/sources.
        let groundPenalty = grounded ? 0 : 0.15
        let grounding = Factor(
            label: "Grounding",
            penalty: groundPenalty,
            detail: grounded ? "answer grounded in real files/sources" : "answer was not grounded in files/sources",
            raise: grounded ? "" : "read the real files or cite sources before answering, then re-verify")

        let factors = [reliability, health, grounding]
        let score = base - factors.reduce(0) { $0 + $1.penalty }
        return ConfidenceReport(score: score, base: base, factors: factors)
    }

    /// Turn detected issue kinds into a plain-language next move.
    private static func healthRaiseHint(_ issues: [TrajectoryIssue]) -> String {
        var hints: [String] = []
        var seen = Set<TrajectoryIssue.Kind>()
        for issue in issues where seen.insert(issue.kind).inserted {
            switch issue.kind {
            case .runawayLoop: hints.append("break the repeated identical action")
            case .failureSpike: hints.append("fix the burst of failing calls")
            case .nearIterationBudget: hints.append("narrow the plan so it finishes within budget")
            case .noToolProgress: hints.append("make a real change instead of read-only spinning")
            }
        }
        return hints.isEmpty ? "let the plan verify its work" : hints.joined(separator: "; ")
    }

    // MARK: - Rendering

    private func c(_ code: String, _ s: String, _ on: Bool) -> String { on ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }

    /// The battery gauge: a colored charge bar + percentage. `width` is the number of cells.
    public func bar(width: Int = 10, color: Bool) -> String {
        let cells = max(4, width)
        let filled = max(0, min(cells, Int((score * Double(cells)).rounded())))
        let charge = c(batteryCode, String(repeating: "█", count: filled), color)
        let empty = c("2", String(repeating: "░", count: cells - filled), color)
        return charge + empty + " " + c(batteryCode, "\(percent)%", color)
    }

    /// The full "why / how to raise it" drawer for `/confidence`. Names each factor, its drag, and
    /// the concrete move to recover it — so an agent knows exactly what to do next.
    public func renderBreakdown(color: Bool, width: Int = 72) -> String {
        let rule = c("2", String(repeating: "━", count: max(16, width)), color)
        var out = "\n" + rule + "\n\n"
        out += c("96;1", "🔋 Confidence · why \(percent)%", color) + "\n\n"
        out += bar(width: 20, color: color) + "\n\n"
        out += c("2", "ceiling \(Int(base * 100))% · each factor below subtracts from it", color) + "\n\n"
        for f in factors {
            let mark = f.ok ? c("92;1", "✓", color) : c("91;1", "▾", color)
            let head = f.ok
                ? "\(mark) \(c("37;1", f.label, color)) \(c("2", "· no drag", color))"
                : "\(mark) \(c("37;1", f.label, color)) \(c("91", "· −\(Int((f.penalty * 100).rounded()))%", color))"
            out += head + "\n"
            out += c("2", "   " + f.detail, color) + "\n"
            if !f.ok, !f.raise.isEmpty {
                out += c("93", "   ↑ raise: ", color) + c("37", f.raise, color) + "\n"
            }
            out += "\n"
        }
        if pending.isEmpty {
            out += c("92", "Nothing dragging it down — this is the ceiling for a grounded, clean, healthy run.", color) + "\n"
        } else {
            let recoveredPercent = Int((base * 100).rounded()).clampedPercent
            out += c("2", "Clearing every factor above would raise confidence to ~\(recoveredPercent)%.", color) + "\n"
        }
        out += "\n" + rule + "\n"
        return out
    }
}

private extension Int {
    /// Confidence is capped at 98% even when fully clean — mirror that in the "would raise to" hint.
    var clampedPercent: Int { Swift.min(98, Swift.max(0, self)) }
}
