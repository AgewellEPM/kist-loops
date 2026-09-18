import Foundation
import XCTest
@testable import AgentCore

/// Pins for the self-upgrade readiness checklist render. It must show every gate, never claim readiness
/// it lacks, echo the manual-evolution gate set that `runEvolution` actually enforces, and surface the
/// corpus probe as informational under the fitness gate.
final class EvolutionReadinessReportTests: XCTestCase {
    private func gate(_ gate: EvolutionAutonomyGate, ready: Bool) -> EvolutionAutonomyGateState {
        .init(gate: gate, ready: ready, reason: ready ? "attested by live authority" : "not yet attested")
    }

    private func allGates(ready: Bool) -> EvolutionAutonomyReadiness {
        EvolutionAutonomyReadiness(gates: EvolutionAutonomyGate.allCases.map { gate($0, ready: ready) })
    }

    func testProductionReadinessRendersEveryGateAsRefused() {
        let text = EvolutionReadinessReport.render(readiness: EvolutionAutonomyReadinessAssessment.current)
        XCTAssertTrue(text.contains("REFUSED"), "the checked-in runtime is not self-upgrade ready")
        for gate in EvolutionAutonomyGate.allCases {
            XCTAssertTrue(text.contains(gate.rawValue), "readiness view omitted gate \(gate.rawValue)")
        }
        XCTAssertFalse(text.contains("✓"), "no gate is live in the checked-in runtime")
    }

    func testManualGateEchoMatchesTheEnforcedSet() {
        // If runEvolution's requiredManualGates ever diverges from this echo, this is the canary. The
        // three gates below are exactly what KistRunner.runEvolution enforces for a manual --evolve.
        XCTAssertEqual(Set(EvolutionReadinessReport.manualEvolutionGates),
                       [.parentRelativeCapabilityFitness, .externalRollbackWitness, .hardProcessContainment])
    }

    func testAllGatesLiveRendersReadyAndMeetsManualEvolution() {
        let text = EvolutionReadinessReport.render(readiness: allGates(ready: true))
        XCTAssertTrue(text.contains("READY (6/6 gates live)"))
        XCTAssertTrue(text.contains("manual --evolve · gates met"))
    }

    func testMissingManualGateIsNamedInTheChecklist() {
        let gates = EvolutionAutonomyGate.allCases.map {
            gate($0, ready: $0 != .hardProcessContainment)
        }
        let text = EvolutionReadinessReport.render(readiness: EvolutionAutonomyReadiness(gates: gates))
        XCTAssertTrue(text.contains("needs: hardProcessContainment"),
                      "an unmet manual gate must be named: \(text)")
    }

    func testCorpusProbeShownAsInformationalUnderTheFitnessGate() {
        let present = EvolutionReadinessReport.render(
            readiness: EvolutionAutonomyReadinessAssessment.current,
            corpus: (ready: true, detail: "3 frozen held-out case(s)"))
        XCTAssertTrue(present.contains("held-out corpus · present"))
        XCTAssertTrue(present.contains("informational"))

        let absent = EvolutionReadinessReport.render(
            readiness: EvolutionAutonomyReadinessAssessment.current,
            corpus: (ready: false, detail: "manifest is missing"))
        XCTAssertTrue(absent.contains("held-out corpus · absent"))
        // A present corpus must NEVER flip the fitness gate on its own.
        XCTAssertTrue(present.contains("✗ parentRelativeCapabilityFitness"))
    }
}
