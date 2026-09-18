import Foundation

/// The self-upgrade checklist, made legible. `EvolutionAutonomyReadinessAssessment` already knows which
/// of the six live-authority gates are attested, but the only place a human saw it was a one-line refusal
/// when arming. This renders each gate with its state and honest reason, plus the held-out corpus probe —
/// so "what is blocking self-evolution, and what would unblock it" is answerable at a glance.
///
/// Pure render: it takes a readiness value and an optional corpus probe result. It cannot make status
/// optimistic (no gate is invented, no I/O decides readiness here) and never claims a tier it lacks.
public enum EvolutionReadinessReport {
    /// Gates a MANUAL `--evolve` requires. Mirrors `KistRunner.runEvolution`'s `requiredManualGates`;
    /// the enforcement lives there, this is the human-visible echo. Pinned equal by test.
    public static let manualEvolutionGates: [EvolutionAutonomyGate] = [
        .parentRelativeCapabilityFitness, .externalRollbackWitness, .hardProcessContainment,
    ]

    /// `corpus` is an optional (ready, detail) probe from `EvolutionHeldOutCorpus.availability`. It is
    /// shown nested under the fitness gate as INFORMATIONAL: a present corpus is necessary but not
    /// sufficient — the gate stays closed until hard containment and a host executor also exist.
    public static func render(readiness: EvolutionAutonomyReadiness,
                              corpus: (ready: Bool, detail: String)? = nil) -> String {
        let gates = readiness.gates
        let live = gates.filter(\.ready).count
        var out: [String] = []
        out.append("self-upgrade readiness · \(readiness.ready ? "READY" : "REFUSED") (\(live)/\(gates.count) gates live)")

        for state in gates {
            out.append("  \(state.ready ? "✓" : "✗") \(state.gate.rawValue) — \(state.reason)")
            if state.gate == .parentRelativeCapabilityFitness, let corpus {
                out.append("      held-out corpus · \(corpus.ready ? "present" : "absent") — \(corpus.detail)  (informational; gate also needs containment + host executor)")
            }
        }

        let manualMissing = manualEvolutionGates.filter { gate in
            !(gates.first { $0.gate == gate }?.ready ?? false)
        }
        out.append("")
        if manualMissing.isEmpty {
            out.append("manual --evolve · gates met (execution still refuses without a host benchmark backend)")
        } else {
            out.append("manual --evolve · needs: " + manualMissing.map(\.rawValue).joined(separator: ", "))
        }
        out.append("unattended --evolve-session · needs all \(gates.count) gates. Never auto-promotes; humans review kept branches.")
        return out.joined(separator: "\n")
    }
}
