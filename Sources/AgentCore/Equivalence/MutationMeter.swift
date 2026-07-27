import Foundation

/// The corpus-STRENGTH meter — the council's answer to "a green equivalence run only proves the port
/// matches on the inputs I happened to test; how do I know my corpus is actually strong?" Coverage says
/// which code ran; mutation score says whether the corpus would CATCH a fault if one were there.
///
/// The elegant framing that reuses the whole engine: a **mutant is a deliberately-faulty candidate** — the
/// reference behavior with one injected fault. A trustworthy corpus must make EVERY mutant regress (catch
/// the fault). A mutant the corpus reads as "equivalent" SURVIVED — a fault class the corpus is blind to,
/// i.e. a real gap that tells the InputSynthesizer where to hunt next.
public enum MutationMeter {

    /// One injected fault: a faulty variant of the ORIGINAL's behavior the corpus should detect.
    public struct Mutant: Sendable {
        public let name: String
        public let faulty: @Sendable (String) throws -> String
        /// Caller-declared EQUIVALENT mutant: an injected change that is semantically a no-op (cannot be
        /// killed by any corpus). Excluded from the denominator so it doesn't drag the score down (council:
        /// equivalent mutants create false gaps — require an explicit declaration, don't guess).
        public let isEquivalent: Bool
        public init(name: String, isEquivalent: Bool = false, faulty: @escaping @Sendable (String) throws -> String) {
            self.name = name; self.isEquivalent = isEquivalent; self.faulty = faulty
        }
    }

    public struct Score: Sendable, Equatable {
        public let killed: [String]         // corpus produced a real distinguishing divergence
        public let survived: [String]       // corpus was blind (clean equivalent) — a gap
        public let inconclusive: [String]   // measurement compromised (oracle non-deterministic / gaps), NOT a kill
        public let equivalentSkipped: [String]
        /// killed / (killed + survived) — equivalent AND inconclusive mutants excluded. 1.0 = the corpus
        /// caught every fault it could cleanly measure; nil when nothing was cleanly measurable (honest
        /// "unmeasured"). `measured` is the denominator — a certification gate must also require it be large
        /// enough to mean something (a 1-of-1 kill is 100% but proves almost nothing).
        public var measured: Int { killed.count + survived.count }
        public var score: Double? { measured == 0 ? nil : Double(killed.count) / Double(measured) }
    }

    /// Measure a corpus against a set of mutants. A mutant is KILLED only when the corpus produces a REAL
    /// distinguishing divergence (`.notEquivalent` on ≥1 case). A run that merely fails to come back clean
    /// for another reason — `captureFailed` (the ORACLE was non-deterministic) or `incomplete` (coverage
    /// gaps) with no divergence — is INCONCLUSIVE, never a kill: the corpus did not distinguish the mutant,
    /// the measurement setup did. Counting those as kills falsely inflated corpus strength and could
    /// false-certify a broken port off a flaky oracle (council-critical).
    public static func measure(corpus: [EquivalenceRun.Case], volatiles: [VolatileField] = [],
                               oracle: (String) throws -> String, mutants: [Mutant]) -> Score {
        var killed: [String] = [], survived: [String] = [], inconclusive: [String] = [], equiv: [String] = []
        for m in mutants {
            if m.isEquivalent { equiv.append(m.name); continue }
            let report = EquivalenceRun.run(corpus, volatiles: volatiles, oracle: oracle, candidate: { try m.faulty($0) })
            if report.count(.notEquivalent) > 0 { killed.append(m.name) }               // corpus caught the fault
            else if report.overall == .evidenceBoundedEquivalent { survived.append(m.name) }  // corpus blind
            else { inconclusive.append(m.name) }                                        // measurement compromised
        }
        return Score(killed: killed, survived: survived, inconclusive: inconclusive, equivalentSkipped: equiv)
    }
}
