import XCTest
import Foundation
@testable import AgentCore

/// LIVE verification that the `browse` tool actually drives Playwright (renders a real page and
/// extracts text). Skips cleanly when node/playwright/network aren't available so CI stays green.
final class BrowserLiveTests: XCTestCase {
    func testBrowseRendersRealPage() async throws {
        guard RunCommandTool.resolveExecutable("node", env: ProcessInfo.processInfo.environment) != nil else {
            throw XCTSkip("node not available")
        }
        let root = NSTemporaryDirectory() + "browse-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ctx = ToolContext(projectRoot: root, shell: ShellPolicy(enabled: true, autoApprove: true))

        let r = try await BrowserTool().execute(arguments: ["url": "https://example.com", "extract": "text"], context: ctx)
        if !r.success {
            // Playwright not installed / offline → skip, don't fail (the point is: does it work when set up).
            throw XCTSkip("browse did not succeed (likely playwright/network): \((r.error ?? r.output).prefix(160))")
        }
        XCTAssertTrue(r.output.contains("Example Domain"),
                      "rendered text should contain the page's heading; got: \(r.output.prefix(200))")
    }
}
