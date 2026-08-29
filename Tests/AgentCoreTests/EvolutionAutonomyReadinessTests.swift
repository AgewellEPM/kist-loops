import XCTest
@testable import AgentCore

final class EvolutionAutonomyReadinessTests: XCTestCase {
    func testCurrentRuntimeNamesEveryGateAndRefusesUnattendedEvolution() {
        let status = EvolutionAutonomyReadinessAssessment.current
        XCTAssertFalse(status.ready)
        XCTAssertEqual(Set(status.gates.map(\.gate)), Set(EvolutionAutonomyGate.allCases))
        XCTAssertEqual(status.blockers.count, EvolutionAutonomyGate.allCases.count)
        XCTAssertTrue(status.blockerSummary.contains("parentRelativeCapabilityFitness"))
        XCTAssertTrue(status.blockerSummary.contains("externalRollbackWitness"))
        XCTAssertTrue(status.blockerSummary.contains("hardProcessContainment"))
        XCTAssertTrue(status.blockerSummary.contains("identityDistinctReview"))
    }

    func testMissingDuplicateAndEmptyEvidenceFailClosed() {
        let readyStates = EvolutionAutonomyGate.allCases.map {
            EvolutionAutonomyGateState(gate: $0, ready: true, reason: "attested")
        }
        XCTAssertTrue(EvolutionAutonomyReadiness(gates: readyStates).ready)

        XCTAssertFalse(EvolutionAutonomyReadiness(gates: Array(readyStates.dropLast())).ready)
        XCTAssertFalse(EvolutionAutonomyReadiness(gates: readyStates + [readyStates[0]]).ready)
        var emptyReason = readyStates
        emptyReason[0] = .init(gate: emptyReason[0].gate, ready: true, reason: "")
        XCTAssertFalse(EvolutionAutonomyReadiness(gates: emptyReason).ready)
    }
}
