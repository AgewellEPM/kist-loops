import Foundation
import XCTest
@testable import AgentCore

final class SandboxDefaultReliabilityTests: XCTestCase {
    func testToolContextDefaultsToKernelConfinement() {
        let context = ToolContext(projectRoot: NSTemporaryDirectory())
        XCTAssertTrue(context.sandbox.enabled)
        XCTAssertTrue(context.sandbox.denyNetwork)
        XCTAssertTrue(context.sandbox.confineWrites)
    }
    func testExplicitDisabledSandboxRemainsAvailable() {
        let context = ToolContext(projectRoot: NSTemporaryDirectory(), sandbox: .disabled)
        XCTAssertFalse(context.sandbox.enabled)
        XCTAssertFalse(context.sandbox.denyNetwork)
        XCTAssertFalse(context.sandbox.confineWrites)
    }
}
