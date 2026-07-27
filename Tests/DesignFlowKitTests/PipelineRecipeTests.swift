import XCTest
@testable import DesignFlowKit

final class PipelineRecipeTests: XCTestCase {
    func testRecipeAgentOrder() {
        XCTAssertEqual(Pipeline.designOnly.agents, [.uiDesigner])
        XCTAssertEqual(Pipeline.designAndAnalysis.agents, [.uiDesigner, .designAnalyst])
        XCTAssertEqual(Pipeline.analysisAndCode.agents, [.designAnalyst, .developer])
        XCTAssertEqual(Pipeline.full.agents, [.uiDesigner, .designAnalyst, .developer, .buildArchitect])
    }

    func testNamedResolutionDefaultsToFull() {
        XCTAssertEqual(Pipeline.named(nil), .full)
        XCTAssertEqual(Pipeline.named(""), .full)
        XCTAssertEqual(Pipeline.named("garbage"), .full)
        XCTAssertEqual(Pipeline.named("design"), .designOnly)
        XCTAssertEqual(Pipeline.named("analysis-code"), .analysisAndCode)
    }

    func testEveryAgentKindHasDistinctArtifactPath() {
        let paths = AgentKind.allCases.map(\.artifactPath)
        XCTAssertEqual(Set(paths).count, paths.count, "artifact paths must be unique per stage")
    }

    func testSlugIsDeterministicAndSafe() {
        let a = OuterLoop.slug("Accessible AAC board editor!", cycle: 3)
        let b = OuterLoop.slug("Accessible AAC board editor!", cycle: 3)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("c003-"))
        XCTAssertFalse(a.contains("!"))
        XCTAssertFalse(a.contains(" "))
    }
}
