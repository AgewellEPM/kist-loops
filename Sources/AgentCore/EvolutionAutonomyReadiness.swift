import Foundation

/// Independent gates that must all be backed by live host authority before unattended self-evolution.
public enum EvolutionAutonomyGate: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case parentRelativeCapabilityFitness
    case externalRollbackWitness
    case hardProcessContainment
    case identityDistinctReview
    case sealedActivationAuthority
    case witnessedBudgetReservation
}

public struct EvolutionAutonomyGateState: Codable, Sendable, Equatable {
    public let gate: EvolutionAutonomyGate
    public let ready: Bool
    public let reason: String

    public init(gate: EvolutionAutonomyGate, ready: Bool, reason: String) {
        self.gate = gate
        self.ready = ready
        self.reason = reason
    }
}

/// Machine-readable self-assessment. Missing, duplicated, or optimistic-without-evidence gates refuse.
public struct EvolutionAutonomyReadiness: Sendable, Equatable {
    public let gates: [EvolutionAutonomyGateState]

    public init(gates: [EvolutionAutonomyGateState]) {
        self.gates = gates.sorted { $0.gate.rawValue < $1.gate.rawValue }
    }

    public var ready: Bool {
        let expected = Set(EvolutionAutonomyGate.allCases)
        let actual = Set(gates.map(\.gate))
        return gates.count == expected.count
            && actual == expected
            && gates.allSatisfy { $0.ready && !$0.reason.isEmpty }
    }

    public var blockers: [EvolutionAutonomyGateState] {
        guard !ready else { return [] }
        let counts = Dictionary(grouping: gates, by: \.gate).mapValues(\.count)
        var result = gates.filter { !$0.ready || $0.reason.isEmpty }
        for gate in EvolutionAutonomyGate.allCases where counts[gate] == nil {
            result.append(.init(gate: gate, ready: false, reason: "gate state is missing"))
        }
        for gate in EvolutionAutonomyGate.allCases where (counts[gate] ?? 0) > 1 {
            result.append(.init(gate: gate, ready: false, reason: "gate state is duplicated"))
        }
        return result.sorted { $0.gate.rawValue < $1.gate.rawValue }
    }

    public var blockerSummary: String {
        let details = blockers.map { "\($0.gate.rawValue): \($0.reason)" }
        return details.isEmpty ? "all unattended-evolution gates are attested" : details.joined(separator: "; ")
    }
}

public enum EvolutionAutonomyReadinessAssessment {
    /// Honest status of the checked-in runtime. Pure contracts are not live authorities: the paired
    /// fitness referee is bound into benchmark authority, but lacks private-suite execution; no external CAS witness or witnessed
    /// budget ledger is configured; identity-distinct completion receipts are not yet canonicalized;
    /// and the current process runner is advisory rather than hard containment.
    public static var current: EvolutionAutonomyReadiness {
        let containment = HardProcessContainmentRuntime.currentAvailability
        return EvolutionAutonomyReadiness(gates: [
            .init(
                gate: .parentRelativeCapabilityFitness,
                ready: false,
                reason: EvolutionHeldOutOracle.unavailableReason),
            .init(
                gate: .externalRollbackWitness,
                ready: false,
                reason: "external compare-and-advance rollback anchor is not configured"),
            .init(
                gate: .hardProcessContainment,
                ready: containment.available,
                reason: containment.reason),
            .init(
                gate: .identityDistinctReview,
                ready: false,
                reason: "no sealed actual-route identity-distinct reviewer invocation authority"),
            .init(
                gate: .sealedActivationAuthority,
                ready: false,
                reason: "self-tool activation is unavailable until review and containment receipts compose"),
            .init(
                gate: .witnessedBudgetReservation,
                ready: false,
                reason: "session budget is local and is not reserved through an external witness before spawn"),
        ])
    }
}
