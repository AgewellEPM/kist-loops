import XCTest
@testable import AgentCore

/// Live-run regression: injected memory/repo-map must NOT poison the scope classifier. A create-task
/// fenced in the scope markers classifies as NORMAL even when the surrounding context says "Production".
final class ScopeSourceFenceTests: XCTestCase {
    func testFencedTaskIgnoresInjectedProductionMemory() {
        let fenced = PromptCompiler.scopeSourceStart + "\nCreate a Swift package named StringKit with tests.\n"
                   + PromptCompiler.scopeSourceEnd
                   + "\n\nMEMORY: Luke ships Production apps; TinkySpeak server; DNS; nginx."
        let src = HeadlessAgentLoop.scopeRequestSource(for: fenced)
        let decision = AuthorizationScopeEngine.evaluate(src)
        XCTAssertEqual(decision.kind, .normal, "fenced create-task must not misfire as serverDiagnostics — got \(decision.kind)")
        XCTAssertEqual(decision.gate, .allow)
    }
    func testUnfencedProductionStillClassifiesServer() {
        // sanity: without the fence, a genuine 'diagnose the production server' still triggers scope.
        let d = AuthorizationScopeEngine.evaluate("the production server has high latency, investigate")
        XCTAssertEqual(d.kind, .serverDiagnostics)
    }
}
