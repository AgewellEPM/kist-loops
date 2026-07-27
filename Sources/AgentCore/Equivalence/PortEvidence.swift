import Foundation

/// The audit-grade evidence artifact — the PRODUCT. It fuses the two honesty signals the council insisted
/// must travel together: WHAT the port did (the equivalence verdict over the corpus) and HOW STRONG the
/// corpus itself is (the mutation score). The load-bearing rule this encodes:
///
///   **A clean equivalence run on a WEAK corpus is NOT a pass.** "The port matched on every input I tried"
///   means nothing if the corpus couldn't catch a fault anyway. Only a clean run over a corpus PROVEN to
///   kill injected faults earns `evidenceBoundedEquivalent`. This is the difference between honest evidence
///   and the green-suite lie.
public struct PortEvidence: Sendable, Equatable {
    public let equivalence: EquivalenceReport.Overall
    public let equivalent: Int
    public let notEquivalent: Int
    public let notCovered: Int
    public let unprovable: Int
    public let captureFailed: Int
    public let corpusSize: Int
    public let mutationScore: Double?          // nil = corpus strength UNMEASURED
    public let survivedMutants: [String]
    public let inconclusiveMutants: [String]   // measurement compromised (oracle non-determinism / gaps)
    public let mutantsMeasured: Int            // killed + survived — the score's denominator
    public let minMutationScore: Double
    public let minMutants: Int                 // a score means nothing over too few mutants (council)

    /// The overall trust tier — the weakest link across BOTH the equivalence verdict and the corpus
    /// strength. Only `evidenceBoundedEquivalent` is cutover-eligible.
    public enum Trust: String, Sendable, Equatable {
        case captureBroken               // equivalence capture failed → evidence itself is invalid
        case regressed                   // a real divergence between candidate and oracle
        case incomplete                  // no regression, but coverage/provability gaps in the run
        case corpusTooWeak               // port matched, but the corpus can't be trusted to catch faults
        case evidenceBoundedEquivalent   // clean run over a corpus PROVEN to kill injected faults
    }

    public var trust: Trust {
        switch equivalence {
        case .captureFailed: return .captureBroken
        case .regressed:     return .regressed
        case .incomplete:    return .incomplete
        case .evidenceBoundedEquivalent:
            // The equivalence run is clean — now the corpus must have EARNED the right to say so: a strong
            // mutation score AND enough measured mutants that the score is meaningful (a 1-of-1 kill is
            // 100% but proves nothing — council). Too few, or unmeasured, ⇒ can't certify.
            guard let s = mutationScore, s >= minMutationScore, mutantsMeasured >= minMutants else { return .corpusTooWeak }
            return .evidenceBoundedEquivalent
        }
    }

    public var isCutoverEligible: Bool { trust == .evidenceBoundedEquivalent }

    public static func compile(equivalence: EquivalenceReport, mutation: MutationMeter.Score,
                               minMutationScore: Double = 0.9, minMutants: Int = 5) -> PortEvidence {
        PortEvidence(
            equivalence: equivalence.overall,
            equivalent: equivalence.count(.equivalent),
            notEquivalent: equivalence.count(.notEquivalent),
            notCovered: equivalence.count(.notCovered),
            unprovable: equivalence.count(.unprovable),
            captureFailed: equivalence.count(.captureFailed),
            corpusSize: equivalence.total,
            mutationScore: mutation.score,
            survivedMutants: mutation.survived,
            inconclusiveMutants: mutation.inconclusive,
            mutantsMeasured: mutation.measured,
            minMutationScore: minMutationScore,
            minMutants: minMutants)
    }

    /// The audit-readable report. Leads with the weakest-link trust tier; never a bare "passed". Surfaces
    /// both the four equivalence states AND the corpus-strength verdict (survived mutants named).
    public func render() -> String {
        var lines = ["Port evidence: \(trust.rawValue.uppercased()) · corpus \(corpusSize)"]
        lines.append("  equivalence: equivalent \(equivalent) · NOT-EQUIVALENT \(notEquivalent) · not-covered \(notCovered) · unprovable \(unprovable) · CAPTURE-FAILED \(captureFailed)")
        let scoreStr = mutationScore.map { String(format: "%.0f%%", $0 * 100) } ?? "UNMEASURED"
        lines.append("  corpus strength (mutation score): \(scoreStr) over \(mutantsMeasured) mutant\(mutantsMeasured == 1 ? "" : "s") (min to certify: \(String(format: "%.0f%%", minMutationScore * 100)) over ≥\(minMutants))")
        if !survivedMutants.isEmpty {
            lines.append("  ⚠ corpus BLIND to fault classes: \(survivedMutants.joined(separator: ", ")) — synthesize inputs that exercise these")
        }
        if !inconclusiveMutants.isEmpty {
            lines.append("  ⚠ INCONCLUSIVE mutants (oracle not deterministically sealed?): \(inconclusiveMutants.joined(separator: ", "))")
        }
        switch trust {
        case .captureBroken: lines.append("  ⨯ capture broken — evidence INVALID; seal the oracle before any verdict.")
        case .regressed:     lines.append("  ⨯ real regression — NOT safe to cut over.")
        case .incomplete:    lines.append("  ◐ coverage/provability gaps — human risk-acceptance required.")
        case .corpusTooWeak: lines.append("  ◐ port matched, but the corpus can't be trusted to catch faults — strengthen it before certifying.")
        case .evidenceBoundedEquivalent: lines.append("  ✓ evidence-bounded equivalent over a corpus proven to kill injected faults — cutover-eligible pending human sign-off.")
        }
        return lines.joined(separator: "\n")
    }
}
