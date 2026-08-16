import XCTest
@testable import AgentCore
@testable import Kist

final class KistCLIPublicBrowserPolicyTests: XCTestCase {
    private func fullRegistry(hosts: [String]) -> ToolRegistry {
        ToolRegistry([
            WebFetchTool(allowedHosts: hosts),
            WebSearchTool(),
            BrowserTool(allowedHosts: hosts),
            ComputerControlTool(),
            DesktopControlTool(),
        ])
    }

    func testExplicitFetchHostExposesBrowserWithoutHostControl() {
        let route = KistRunner.readOnlyOneShotTools(
            from: fullRegistry(hosts: ["example.com"]),
            fetchAllowedHosts: ["example.com"])
        let names = Set(route.names)

        XCTAssertTrue(names.contains("browse"))
        XCTAssertTrue(names.contains("fetch_url"))
        XCTAssertTrue(names.contains("web_search"))
        XCTAssertFalse(names.contains("computer_control"))
        XCTAssertFalse(names.contains("desktop_control"))
    }

    func testBrowserIsNotAdvertisedWithoutExplicitHostBoundary() {
        let route = KistRunner.readOnlyOneShotTools(
            from: fullRegistry(hosts: []), fetchAllowedHosts: [])

        XCTAssertFalse(route.names.contains("browse"))
        XCTAssertTrue(route.names.contains("fetch_url"))
        XCTAssertTrue(route.names.contains("web_search"))
    }

    func testCLIBrowserRejectsDisallowedHostAndWritesTypedRunReceipt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-cli-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runID = "cli-policy"
        let audit = AuditLog.forRun(root: root.path, runID: runID)
        let context = ToolContext(
            projectRoot: root.path,
            shell: ShellPolicy(enabled: true, autoApprove: true),
            auditLog: audit)
        let route = KistRunner.readOnlyOneShotTools(
            from: fullRegistry(hosts: ["example.com"]),
            fetchAllowedHosts: ["example.com"])

        let result = await route.execute(
            name: "browse", arguments: ["url": "https://openai.com"], context: context)

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("host allowlist"))
        let receipts = await audit.entries()
        let receipt = try XCTUnwrap(receipts.last)
        XCTAssertEqual(receipt.schemaVersion, 1)
        XCTAssertEqual(receipt.runID, runID)
        XCTAssertEqual(receipt.tool, "browse")
        XCTAssertEqual(receipt.outcome, "error")
        XCTAssertFalse(receipt.success)
        XCTAssertEqual(audit.path, root.path + "/" + AuditLog.runRelativePath(runID: runID))
        let persisted = try String(contentsOfFile: audit.path, encoding: .utf8)
        XCTAssertFalse(persisted.contains("https://openai.com"))
        XCTAssertFalse(persisted.contains("proxyUsername"))
        XCTAssertFalse(persisted.contains("proxyPassword"))
    }

    func testRunAuditPathReducesUnsafeIdentifiersToOpaqueFilename() {
        let relative = AuditLog.runRelativePath(runID: "../../secret/token")
        XCTAssertTrue(relative.hasPrefix(".kist/audit/tools-opaque-"))
        XCTAssertTrue(relative.hasSuffix(".jsonl"))
        XCTAssertFalse(relative.contains("secret"))
        XCTAssertFalse(relative.contains(".."))
    }
}
