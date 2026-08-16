import XCTest
@testable import AgentCore

final class BuilderRunRouteGraphTests: XCTestCase {
    func testLowRiskSingleScopeRoutesDirect() {
        XCTAssertEqual(BuilderRouteHint(estimatedFiles: 1, independentWorkstreams: 1,
                                        risk: .low).resolve(), .direct)
    }

    func testCoupledOrMediumRiskWorkRoutesPlanned() {
        XCTAssertEqual(BuilderRouteHint(estimatedFiles: 2).resolve(), .planned)
        XCTAssertEqual(BuilderRouteHint(risk: .medium).resolve(), .planned)
    }

    func testIndependentWorkstreamsRouteFleet() {
        XCTAssertEqual(BuilderRouteHint(estimatedFiles: 4,
                                        independentWorkstreams: 2).resolve(), .fleet)
    }

    func testAssuranceSignalsTakePriorityOverFleetShape() {
        let hints: [BuilderRouteHint] = [
            .init(independentWorkstreams: 3, risk: .high),
            .init(requiresResearch: true),
            .init(requiresSimulation: true),
            .init(risk: .critical),
        ]
        for hint in hints {
            XCTAssertEqual(hint.resolve(), .highAssurance)
        }
    }

    func testExplicitRouteOverrideWinsDeterministically() {
        let hint = BuilderRouteHint(preferred: .planned, independentWorkstreams: 5,
                                    risk: .critical, requiresResearch: true,
                                    requiresSimulation: true)
        XCTAssertEqual(hint.resolve(), .planned)
    }

    func testGraphAcceptsDependenciesRegardlessOfDeclarationOrder() throws {
        let graph = try BuilderGraph(nodes: [
            BuilderNode(id: "package", objective: "package", dependencies: ["compile", "docs"]),
            BuilderNode(id: "docs", objective: "document"),
            BuilderNode(id: "compile", objective: "compile", dependencies: ["generate"]),
            BuilderNode(id: "generate", objective: "generate"),
        ])
        XCTAssertEqual(Set(graph.nodes.map(\.id)), ["package", "docs", "compile", "generate"])
    }

    func testGraphRejectsMalformedIdentifiersAndDependencies() {
        assertGraphError([BuilderNode(id: " ", objective: "x")], equals: .emptyNodeID)
        assertGraphError([
            BuilderNode(id: "same", objective: "x"),
            BuilderNode(id: "same", objective: "y"),
        ], equals: .duplicateNode("same"))
        assertGraphError([
            BuilderNode(id: "child", objective: "x", dependencies: ["missing"]),
        ], equals: .unknownDependency(node: "child", dependency: "missing"))
        assertGraphError([
            BuilderNode(id: "root", objective: "x"),
            BuilderNode(id: "child", objective: "y", dependencies: ["root", "root"]),
        ], equals: .duplicateDependency(node: "child", dependency: "root"))
    }

    func testGraphRejectsCyclesWithStableNodeList() {
        assertGraphError([
            BuilderNode(id: "b", objective: "b", dependencies: ["a"]),
            BuilderNode(id: "a", objective: "a", dependencies: ["b"]),
        ], equals: .cycle(["a", "b"]))
    }

    private func assertGraphError(_ nodes: [BuilderNode], equals expected: BuilderGraphError,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try BuilderGraph(nodes: nodes), file: file, line: line) { error in
            XCTAssertEqual(error as? BuilderGraphError, expected, file: file, line: line)
        }
    }
}
