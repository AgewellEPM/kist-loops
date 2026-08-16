import XCTest
@testable import AgentCore

final class SolReasoningRouterRegressionTests: XCTestCase {
    private let policy = SolReasoningRoutePolicy()

    func testStructuralInputsSelectDirectPlannedAndFleet() {
        XCTAssertEqual(policy.decide(.init(complexity: 10, risk: .low,
                                           expectedToolCalls: 1)).route, .direct)
        XCTAssertEqual(policy.decide(.init(complexity: 20, risk: .medium,
                                           requiresMutation: true)).route, .planned)
        XCTAssertEqual(policy.decide(.init(complexity: 60, independentWorkstreams: 2,
                                           expectedToolCalls: 8)).route, .fleet)
        XCTAssertEqual(policy.decide(.init(complexity: 80)).route, .fleet)
    }

    func testCriticalMutationCannotForceUnsafeDirectOverride() {
        let decision = policy.decide(.init(explicitRoute: .direct, complexity: 5,
                                           risk: .critical, requiresMutation: true))
        XCTAssertEqual(decision.route, .planned)
    }

    func testBuilderAssuranceRouterPromotesStructuralHighRiskSignals() {
        XCTAssertEqual(BuilderRouteHint(risk: .high).resolve(), .highAssurance)
        XCTAssertEqual(BuilderRouteHint(requiresResearch: true).resolve(), .highAssurance)
        XCTAssertEqual(BuilderRouteHint(requiresSimulation: true).resolve(), .highAssurance)
    }
}
