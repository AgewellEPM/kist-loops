import Foundation

/// PROOF-BY-CONSTRUCTION TRUST CURRENCY. A `GroundedVerdict` is the only thing the fleet's trust layer
/// will treat as an earned verdict, and by its TYPE a fake `.green` is impossible — not by discipline,
/// not by a test, but because there is NO public initializer that takes a verdict. You cannot
/// hand-construct a `.green`. The init is private.
///
/// The ways to MINT a GroundedVerdict are static factories that COMPUTE the verdict from a real
/// observation:
///   • fromCode(facts)              — INTERNAL to AgentCore. Runs the deterministic
///                                    SymbolicCaptain.judge over real artifact evidence.
///   • fromGame(expected:observed:) — a DETERMINISTIC win-check. .green ONLY when the observed state
///                                    clearly satisfies the expected marker.
///   • unconfirmed(fromText:)       — the conservative fail-safe for an ungrounded text/transport-ack.
///                                    NEVER .green (no facts were observed): .blocked on an error token,
///                                    else .driftFlagged.
///
/// WHY A TYPE AND NOT A FUNCTION: the signoff ledger's `record` takes a GroundedVerdict, not a bare
/// verdict, AND it admits only `.code` provenance. Public callers can still create public game/text
/// verdicts, but those cannot unlock code signoff. A code green can only be minted inside AgentCore,
/// where Stage 1.6's Foreman builds facts from GitIsolation + the real test runner.
///
/// Ported from TinkySDR's Captain (Stage 1.4). `fitnessWeight` routed through `CaptainMemory.fitness`
/// in TinkySDR; CaptainMemory isn't ported yet, so GroundedVerdict.fitness(for:) is the CANONICAL single
/// mapping for now — when CaptainMemory ports, it must reference THIS table (no second copy to drift).
public struct GroundedVerdict: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        /// Minted by AgentCore's code referee over CaptainFacts. The only source FleetSignoffLedger admits.
        case code
        /// Minted by a deterministic game-state check. May be green, but never signs off code.
        case game
        /// Minted from ungrounded text/transport state. Never green.
        case unconfirmed
    }

    /// The grounded verdict (reuses the SymbolicCaptain's vocabulary so the whole system speaks one
    /// verdict language).
    public let verdict: CaptainJudgment.Verdict
    /// Provenance of the mint. This is load-bearing: code signoff admits only `.code`.
    public let source: Source
    /// A short, human-readable note on WHY this verdict — for logs/diagnostics.
    public let evidence: String

    /// PRIVATE — the only initializer. Cannot be called from outside this type, so no caller can mint a
    /// chosen verdict (e.g. a fake .green). Every public mint routes through a factory that computes
    /// `verdict` from a real observation.
    private init(verdict: CaptainJudgment.Verdict, source: Source, evidence: String) {
        self.verdict = verdict
        self.source = source
        self.evidence = evidence
    }

    // MARK: - The ONLY mints (each computes the verdict from a real observation)

    /// GROUNDED-FROM-CODE. Run the deterministic SymbolicCaptain over real artifact evidence and wrap
    /// its ruling. A .green is possible here ONLY when the facts pass every structural blocker AND no
    /// drift is flagged — exactly the gate that also stops the autonomous loop. One judge, one currency.
    static func fromCode(_ facts: CaptainFacts,
                         captain: SymbolicCaptain = SymbolicCaptain()) -> GroundedVerdict {
        let judgment = captain.judge(facts)
        let note: String
        switch judgment.verdict {
        case .green:
            note = "code: all structural invariants hold, no drift (build \(facts.build.buildID))"
        case .blocked:
            note = "code: blocker(s) failed: " +
                   (judgment.failedBlockers.isEmpty ? "unknown" : judgment.failedBlockers.joined(separator: ", "))
        case .driftFlagged:
            note = "code: drift — " + (judgment.driftReason ?? "world unconfirmed")
        }
        return GroundedVerdict(verdict: judgment.verdict, source: .code, evidence: note)
    }

    /// GROUNDED-FROM-GAME. A DETERMINISTIC win-check over a real observation. Pure: same
    /// (expected, observed) always yields the same verdict.
    public static func fromGame(expected: String, observed: String) -> GroundedVerdict {
        let want = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let got  = observed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // A failure/error marker in the observation is a hard contradiction.
        if Self.failureTokens.contains(where: { got.contains($0) }) {
            return GroundedVerdict(verdict: .blocked, source: .game,
                                   evidence: "game: observed a failure marker in “\(Self.cap(observed))”")
        }
        // Nothing to compare against, or no observation yet → unconfirmed, never green.
        guard !want.isEmpty, !got.isEmpty else {
            return GroundedVerdict(verdict: .driftFlagged, source: .game,
                                   evidence: "game: ambiguous (expected or observed empty) — unconfirmed")
        }
        // The decisive, deterministic win-check: the observation must contain the expected marker.
        if got.contains(want) {
            return GroundedVerdict(verdict: .green, source: .game,
                                   evidence: "game: observed satisfies expected marker “\(Self.cap(expected))”")
        }
        return GroundedVerdict(verdict: .driftFlagged, source: .game,
                               evidence: "game: expected “\(Self.cap(expected))” not yet confirmed in observation")
    }

    /// CONSERVATIVE FAIL-SAFE from an UNGROUNDED text/transport-ack. No CaptainFacts were observed, so
    /// by construction this NEVER returns .green:
    ///   • any error/failure token in the text → .blocked
    ///   • otherwise (even if it brags "tests pass") → .driftFlagged
    /// To earn .green a caller must build real CaptainFacts and use `fromCode`.
    public static func unconfirmed(fromText text: String) -> GroundedVerdict {
        let lower = text.lowercased()
        if Self.failureTokens.contains(where: { lower.contains($0) }) {
            return GroundedVerdict(verdict: .blocked, source: .unconfirmed,
                                   evidence: "ungrounded text carried an error signal — denied reward")
        }
        return GroundedVerdict(verdict: .driftFlagged, source: .unconfirmed,
                               evidence: "ungrounded text (no observed facts) — claimed but unconfirmed")
    }

    /// Internal gate used by FleetSignoffLedger. Public game/text greens are useful verdicts, but they
    /// are not code-signoff receipts.
    var isAdmissibleCodeGreen: Bool { verdict == .green && source == .code }

    // MARK: - Fitness (the single verdict→fitness mapping in the codebase)

    /// The grounded fitness for THIS verdict. Pure, off the verdict only. NO keywords.
    public var fitnessWeight: Double { Self.fitness(for: verdict) }

    /// The ONE verdict→fitness table. .green 1.0 / .driftFlagged 0.35 / .blocked 0.0.
    public static func fitness(for verdict: CaptainJudgment.Verdict) -> Double {
        switch verdict {
        case .green: return 1.0
        case .driftFlagged: return 0.35
        case .blocked: return 0.0
        }
    }

    // MARK: - Shared, pure helpers

    /// Failure/error tokens that force a non-reward. Substring match, lowercased.
    public static let failureTokens = [
        "error", "failed", "failure", "cannot", "can't", "stuck", "blocked",
        "exception", "undefined", "no such", "not found", "traceback", "panic",
        "unresolved", "crash", "aborted", "game over",
    ]

    /// Bound an evidence fragment so a huge observation can't bloat the note.
    private static func cap(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 60 ? String(t.prefix(60)) + "…" : t
    }
}
