import XCTest
import Foundation
@testable import AgentCore

/// LIVE verification that the `browse` tool actually drives Playwright (renders a real page and
/// extracts text). Skips cleanly when node/playwright/network aren't available so CI stays green.
final class BrowserLiveTests: XCTestCase {
    func testBrowseRendersRealPage() async throws {
        guard RunCommandTool.resolveExecutable("node", env: ProcessInfo.processInfo.environment) != nil else {
            if ProcessInfo.processInfo.environment["KIST_REQUIRE_LIVE_BROWSER"] == "1" {
                XCTFail("required live browser dogfood needs Node.js")
                return
            }
            throw XCTSkip("node not available")
        }
        let root = NSTemporaryDirectory() + "browse-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runID = "strict-live-browser"
        let audit = AuditLog.forRun(root: root, runID: runID)
        let ctx = ToolContext(projectRoot: root,
                              shell: ShellPolicy(enabled: true, autoApprove: true),
                              auditLog: audit)

        let tools = ToolRegistry([BrowserTool(allowedHosts: ["example.com"])])
        let r = await tools.execute(name: "browse", arguments: [
            "url": "https://example.com", "extract": "text",
        ], context: ctx)
        if !r.success {
            let diagnostic = [r.error, r.output].compactMap { $0 }.joined(separator: " | ")
            if ProcessInfo.processInfo.environment["KIST_REQUIRE_LIVE_BROWSER"] == "1" {
                XCTFail("required live browser dogfood failed: \(diagnostic.prefix(500))")
                return
            }
            // Default CI may omit Playwright or network. Release/dogfood sets KIST_REQUIRE_LIVE_BROWSER=1.
            throw XCTSkip("browse did not succeed (likely playwright/network): \(diagnostic.prefix(500))")
        }
        XCTAssertTrue(r.output.contains("Example Domain"),
                      "rendered text should contain the page's heading; got: \(r.output.prefix(200))")
        let receipts = await audit.entries()
        let receipt = try XCTUnwrap(receipts.last)
        XCTAssertEqual(receipt.schemaVersion, 1)
        XCTAssertEqual(receipt.runID, runID)
        XCTAssertEqual(receipt.tool, "browse")
        XCTAssertEqual(receipt.outcome, "ok")
        XCTAssertTrue(receipt.success)
        XCTAssertEqual(audit.path, root + "/.kist/audit/tools-\(runID).jsonl")
        let persisted = try String(contentsOfFile: audit.path, encoding: .utf8)
        XCTAssertFalse(persisted.contains("https://example.com"), "raw URL must not enter the receipt")
        XCTAssertFalse(persisted.contains("proxyUsername"))
        XCTAssertFalse(persisted.contains("proxyPassword"))
    }
}
