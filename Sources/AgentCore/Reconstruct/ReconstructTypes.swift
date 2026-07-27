import Foundation

// MARK: - Reconstruct + visual-diff: rebuild a target, screenshot it, compare it to the real thing, and
//         iterate on the DIFFERENCES until it matches (or the budget runs out).
//
// This is the honest, bounded version of "rebuild any system and compare it visually" — NOT a 100% clone
// machine. It is fail-closed on FIDELITY: it only reports a match when the measured visual similarity is at
// or above the threshold; anything less is `.unmatched` with the best score it actually reached. The visual
// comparison is done by a vision model (Gemini via VisualVerifyTool / tinky-verify / tinky-vision), which
// grounds the verdict in a real screenshot vs the real reference — no "looks done" hand-waving.

/// The real thing we're reconstructing toward — a screenshot path or a URL/app to capture.
public struct VisualReference: Sendable, Equatable {
    public let label: String
    public let source: String   // a local image path, or a URL/app identifier to capture
    public init(label: String, source: String) { self.label = label; self.source = source }
}

/// The output of a reconstruction attempt (an isolated build of the candidate implementation).
public struct ReconstructBuild: Sendable, Equatable {
    public let branch: String
    public let ok: Bool
    public let note: String
    public init(branch: String, ok: Bool, note: String = "") { self.branch = branch; self.ok = ok; self.note = note }
}

/// A rendered screenshot of the reconstruction (what our built version actually looks like).
public struct RenderedView: Sendable, Equatable {
    public let imagePath: String
    public let ok: Bool
    public let note: String
    public init(imagePath: String, ok: Bool, note: String = "") { self.imagePath = imagePath; self.ok = ok; self.note = note }
}

/// One concrete visual difference the comparator found — fed back so the next reconstruction can fix it.
public struct VisualDiff: Sendable, Equatable {
    public let area: String          // "header", "button", "layout/spacing", …
    public let description: String
    public let severity: String      // "major" | "minor"
    public init(area: String, description: String, severity: String) {
        self.area = area; self.description = description; self.severity = severity
    }
}

/// The comparator's verdict: a measured similarity in [0,1] + the concrete diffs. `ok == false` means the
/// comparison ITSELF failed (no screenshot, vision model errored) — which must never be read as a match.
public struct VisualComparison: Sendable, Equatable {
    public let similarity: Double
    public let diffs: [VisualDiff]
    public let ok: Bool
    public let note: String
    public init(similarity: Double, diffs: [VisualDiff], ok: Bool, note: String = "") {
        self.similarity = min(1, max(0, similarity)); self.diffs = diffs; self.ok = ok; self.note = note
    }
}

/// One reconstruct→render→compare cycle, kept for the audit trail.
public struct ReconstructRound: Sendable, Equatable {
    public let round: Int
    public let build: ReconstructBuild
    public let rendered: RenderedView?
    public let comparison: VisualComparison?
}

public enum ReconstructResult: Sendable, Equatable {
    /// Reached the fidelity threshold. Carries the branch + the measured similarity (>= threshold).
    case matched(branch: String, similarity: Double, rounds: [ReconstructRound])
    /// Never reached it — the honest outcome, with the BEST similarity actually measured.
    case unmatched(bestSimilarity: Double, rounds: [ReconstructRound], reason: String)

    public var didMatch: Bool { if case .matched = self { return true }; return false }
    public var bestSimilarity: Double {
        switch self {
        case .matched(_, let s, _): return s
        case .unmatched(let s, _, _): return s
        }
    }
    public var rounds: [ReconstructRound] {
        switch self { case .matched(_, _, let r): return r; case .unmatched(_, let r, _): return r }
    }
}

/// The stage seam. Real implementations wire: reconstruct → an agent build in an isolated worktree (from the
/// reference + accumulated diffs), render → tinky-vision `os_screenshot` / run-the-app capture, compare →
/// a vision model (Gemini / VisualVerifyTool) that scores similarity + lists concrete diffs. `reconstruct`
/// receives the accumulated open diffs so it FIXES them, not rebuilds blind.
public protocol ReconstructStages: Sendable {
    func reconstruct(goal: String, reference: VisualReference, feedback: [VisualDiff]) async -> ReconstructBuild
    func render(_ build: ReconstructBuild) async -> RenderedView
    func compare(reference: VisualReference, rendered: RenderedView) async -> VisualComparison
}
