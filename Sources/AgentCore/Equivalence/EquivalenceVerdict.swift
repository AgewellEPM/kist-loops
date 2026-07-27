import Foundation

/// The verdict for ONE case (one input run through the original oracle and the candidate port). These are
/// the four honest states from the build plan, plus `captureFailed` — the council-added Gate 0 outcome.
/// There is deliberately NO "passed": a case is EQUIVALENT (evidence-bounded), NOT-EQUIVALENT (a real
/// regression), NOT-COVERED (never exercised), UNPROVABLE (genuinely nondeterministic, no oracle), or
/// CAPTURE-FAILED (the oracle disagreed with itself → the capture/sealing is broken; no verdict is valid).
public enum CaseVerdict: String, Sendable, Equatable, Codable {
    case notCovered      // no captured oracle output and/or no candidate output for this case
    case captureFailed   // Gate 0: two sealed oracle replays disagreed on a field we EXPECTED to be sealed
    case unprovable      // oracle is nondeterministic here by known design, and no invariant can adjudicate
    case notEquivalent   // a real semantic divergence between candidate and (deterministic) oracle
    case equivalent      // candidate matches the oracle after canonicalization (or an invariant holds)
}

/// Everything needed to judge one case. `oracleRunA`/`oracleRunB` are TWO sealed replays of the ORIGINAL
/// system on the same input (that duplicate replay is the determinism check, NOT a statistical noise
/// floor — that misapplication was the council's dominant finding). `candidate` is the port's output.
public struct CaseEvidence: Sendable, Equatable {
    public let id: String
    public let oracleRunA: String?
    public let oracleRunB: String?
    public let candidate: String?
    /// OUT-OF-BAND signal that the candidate port THREW/crashed on this input (as opposed to simply not
    /// being attempted). This is a flag, never an in-band sentinel STRING — the council caught that a
    /// magic-string error marker could collide with a real oracle output and mint a false `.equivalent`
    /// (a crashing port read as correct). A thrown candidate on a successful oracle ⇒ `notEquivalent`.
    public let candidateThrew: Bool
    public let volatiles: [VolatileField]
    /// The caller DECLARES this case contains a field that is intentionally not sealed (genuinely
    /// nondeterministic). This is what separates an honest `unprovable` from a `captureFailed`: an
    /// undeclared oracle disagreement means the sealing is broken (fail-closed), not that the field is free.
    public let mayBeNondeterministic: Bool
    /// Optional invariant/metamorphic result on the candidate — the oracle for cases exact-match can't
    /// judge. `nil` = no invariant available; `true`/`false` = the invariant held / was violated.
    public let invariantHolds: Bool?

    public init(id: String, oracleRunA: String?, oracleRunB: String?, candidate: String?,
                candidateThrew: Bool = false, volatiles: [VolatileField] = [],
                mayBeNondeterministic: Bool = false, invariantHolds: Bool? = nil) {
        self.id = id; self.oracleRunA = oracleRunA; self.oracleRunB = oracleRunB; self.candidate = candidate
        self.candidateThrew = candidateThrew
        self.volatiles = volatiles; self.mayBeNondeterministic = mayBeNondeterministic; self.invariantHolds = invariantHolds
    }
}

/// The per-case judge — the council-corrected three-concern model made concrete. Ordering matters and is
/// the whole point: determinism (Gate 0) is checked and separated FROM equivalence, so "the oracle agreed
/// with itself" can never be mistaken for "the port is correct."
public enum EquivalenceHarness {
    public static func judge(_ e: CaseEvidence) -> CaseVerdict {
        // Concern 1 — coverage: no captured ORACLE reference ⇒ this case is simply unverified. (Coverage
        // depends on the reference existing, NOT on the candidate — a thrown candidate is handled below.)
        guard let a0 = e.oracleRunA, let b0 = e.oracleRunB else { return .notCovered }

        let a = CanonicalForm.canonicalize(a0, projecting: e.volatiles)
        let b = CanonicalForm.canonicalize(b0, projecting: e.volatiles)

        // GATE 0 — capture integrity: two sealed replays of the ORIGINAL must be identical after declared
        // projection. If they aren't, exact equivalence against this oracle is meaningless.
        if a != b {
            // FAIL-CLOSED FIRST (council-critical): an UNDECLARED oracle disagreement means the sealing is
            // broken, and NOTHING — not even an invariant — may override that into a verdict. Checking the
            // invariant before this let a trivial `invariantHolds: true` launder a broken capture into
            // `.equivalent`. The invariant can only ever rescue a field the caller DECLARED nondeterministic.
            guard e.mayBeNondeterministic else { return .captureFailed }
            // Declared nondeterministic: an invariant adjudicates if present; otherwise honestly unprovable.
            if let holds = e.invariantHolds { return holds ? .equivalent : .notEquivalent }
            return .unprovable
        }

        // The oracle is deterministic here. A candidate that THREW where the original produced output is a
        // real divergence — signalled out-of-band (never an in-band sentinel that could collide, council).
        if e.candidateThrew { return .notEquivalent }
        guard let c0 = e.candidate else { return .notCovered }   // candidate not attempted ⇒ unverified

        // Concern 3 — candidate equivalence: an exact (canonical) match is a real equivalence witness; any
        // difference is a real regression.
        let c = CanonicalForm.canonicalize(c0, projecting: e.volatiles)
        if c == a { return .equivalent }
        // Even on a deterministic oracle, an explicit invariant can rescue an intentionally-different-but-
        // correct output (e.g., a reformat that preserves meaning) — but only if the caller supplied one.
        if let holds = e.invariantHolds, holds { return .equivalent }
        return .notEquivalent
    }
}
