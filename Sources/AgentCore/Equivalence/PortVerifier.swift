import Foundation

/// The facade — the whole L0 Legacy Modernization loop behind one call. Given the shape of a legacy
/// transform's record, the ORIGINAL behavior, and a CANDIDATE port, it:
///   1. SYNTHESIZES a boundary-hunting corpus (InputSynthesizer) + any caller-supplied seed inputs,
///   2. CAPTURES + JUDGES the candidate against the twice-run oracle (EquivalenceRun, Gate 0),
///   3. MEASURES corpus strength by whether it kills injected faults (MutationMeter),
///   4. COMPILES the fused, honest audit artifact (PortEvidence).
/// Returns the evidence plus the raw sub-reports for drill-down. This is the cathedral assembled: point it
/// at an original and a port, get back one honest verdict about whether the port is safe to cut over.
public enum PortVerifier {

    public struct Result: Sendable {
        public let evidence: PortEvidence
        public let equivalence: EquivalenceReport
        public let mutation: MutationMeter.Score
        public let corpus: [EquivalenceRun.Case]
    }

    public static func verify(record: [InputSynthesizer.Field],
                              seedInputs: [EquivalenceRun.Case] = [],
                              volatiles: [VolatileField] = [],
                              mutants: [MutationMeter.Mutant] = [],
                              minMutationScore: Double = 0.9, minMutants: Int = 5,
                              delimiter: String = ",", rowSeparator: String = "\n",
                              oracle: (String) throws -> String,
                              candidate: (String) throws -> String) -> Result {
        // 1. The corpus = synthesized boundary cases + the caller's real seed inputs (captured traffic).
        let synthesized = InputSynthesizer.synthesize(record: record, delimiter: delimiter, rowSeparator: rowSeparator)
        let corpus = synthesized + seedInputs

        // 2. Capture + judge the candidate.
        let equivalence = EquivalenceRun.run(corpus, volatiles: volatiles, oracle: oracle, candidate: candidate)

        // 3. Measure how strong that corpus actually is (does it kill injected faults?).
        let mutation = MutationMeter.measure(corpus: corpus, volatiles: volatiles, oracle: oracle, mutants: mutants)

        // 4. Fuse into the honest audit artifact.
        let evidence = PortEvidence.compile(equivalence: equivalence, mutation: mutation,
                                            minMutationScore: minMutationScore, minMutants: minMutants)
        return Result(evidence: evidence, equivalence: equivalence, mutation: mutation, corpus: corpus)
    }
}
