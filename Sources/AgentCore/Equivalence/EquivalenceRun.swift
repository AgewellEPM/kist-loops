import Foundation

/// The capture/orchestration layer that PRODUCES the evidence the verdict core judges. For each input it
/// runs the ORIGINAL oracle TWICE (that duplicate replay is Gate 0 — the determinism/capture-integrity
/// check, NOT a statistical noise floor) and the candidate port ONCE, assembling a `CaseEvidence` per case.
///
/// The oracle and candidate are injected as throwing closures so the whole layer is pure and unit-testable
/// (a real backend seals the clock/RNG/FS and executes the original; a test passes deterministic closures).
/// A closure that THROWS is captured as a fact, not a crash:
///   • oracle throws  → no reference captured for this input → `notCovered` (we cannot judge without a
///     reference; capturing an intentional error as behavior is a later refinement, tracked in the plan).
///   • candidate throws (oracle succeeded) → the port failed where the original produced output → the
///     `candidateThrew` flag (out-of-band, never an in-band sentinel) surfaces it as `notEquivalent`.
public enum EquivalenceRun {

    public struct Case: Sendable {
        public let id: String
        public let input: String
        /// The caller declares this input exercises a genuinely-unsealed field (separates `unprovable`
        /// from `captureFailed` when the two oracle replays disagree).
        public let mayBeNondeterministic: Bool
        /// Optional invariant/metamorphic check evaluated on (oracleOutput?, candidateOutput) — the oracle
        /// for cases exact-match can't judge. Returns whether the invariant holds.
        public let invariant: (@Sendable (_ oracle: String?, _ candidate: String) -> Bool)?

        public init(id: String, input: String, mayBeNondeterministic: Bool = false,
                    invariant: (@Sendable (_ oracle: String?, _ candidate: String) -> Bool)? = nil) {
            self.id = id; self.input = input
            self.mayBeNondeterministic = mayBeNondeterministic; self.invariant = invariant
        }
    }

    public static func capture(_ cases: [Case], volatiles: [VolatileField] = [],
                               oracle: (String) throws -> String,
                               candidate: (String) throws -> String) -> [CaseEvidence] {
        cases.map { c in
            // Gate 0's two sealed replays of the ORIGINAL. A throw ⇒ nil ⇒ no reference ⇒ notCovered.
            let a = try? oracle(c.input)
            let b = try? oracle(c.input)
            // A candidate throw is signalled OUT-OF-BAND (candidateThrew), never as an in-band sentinel
            // string that could collide with a real oracle output and mint a false equivalent (council).
            let candOut: String?
            let threw: Bool
            do { candOut = try candidate(c.input); threw = false } catch { candOut = nil; threw = true }
            // Evaluate the invariant (if any) against the first oracle run + the candidate output (only
            // when the candidate actually produced output).
            let inv: Bool? = candOut.flatMap { out in c.invariant.map { $0(a, out) } }
            return CaseEvidence(id: c.id, oracleRunA: a, oracleRunB: b, candidate: candOut,
                                candidateThrew: threw, volatiles: volatiles,
                                mayBeNondeterministic: c.mayBeNondeterministic, invariantHolds: inv)
        }
    }

    /// Capture + judge in one call — the full L0 loop for a corpus: returns the honest `EquivalenceReport`.
    public static func run(_ cases: [Case], volatiles: [VolatileField] = [],
                           oracle: (String) throws -> String,
                           candidate: (String) throws -> String) -> EquivalenceReport {
        EquivalenceReport.judging(capture(cases, volatiles: volatiles, oracle: oracle, candidate: candidate))
    }
}
