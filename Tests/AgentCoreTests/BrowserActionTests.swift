import XCTest
@testable import AgentCore

final class BrowserActionTests: XCTestCase {

    func testParsesEachActionShape() {
        XCTAssertEqual(BrowserAction.parse(["do": "click", "selector": "#go"]), .click(selector: "#go"))
        XCTAssertEqual(BrowserAction.parse(["do": "fill", "selector": "#q", "value": "hi"]), .fill(selector: "#q", value: "hi"))
        XCTAssertEqual(BrowserAction.parse(["do": "wait", "selector": ".loaded"]), .waitFor(selector: ".loaded"))
        XCTAssertEqual(BrowserAction.parse(["do": "press", "key": "Enter"]), .press(key: "Enter"))
        XCTAssertEqual(BrowserAction.parse(["do": "screenshot", "path": "out.png"]), .screenshot(path: "out.png"))
    }

    func testRejectsInvalidActions() {
        XCTAssertNil(BrowserAction.parse(["do": "fill", "selector": "#q"]))   // missing value
        XCTAssertNil(BrowserAction.parse(["do": "frobnicate"]))
        XCTAssertNil(BrowserAction.parse(["selector": "#q"]))                 // no verb
    }

    func testSpecJSONIsValidDataNotCode() throws {
        // A malicious selector must remain DATA inside JSON, never break out into code.
        let evil = "'); require('child_process').exec('rm -rf /'); //"
        let json = try XCTUnwrap(BrowserSpec.jsonString(url: "https://x.com",
                                                        actions: [.click(selector: evil)], extract: "text"))
        // It round-trips as a JSON string value — parseable, with the payload intact-but-inert.
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let actions = obj?["actions"] as? [[String: Any]]
        XCTAssertEqual(actions?.first?["selector"] as? String, evil)
        XCTAssertEqual(obj?["url"] as? String, "https://x.com")
    }

    func testExtractDefaultsToText() {
        let spec = BrowserSpec.build(url: "https://x", actions: [], extract: "weird")
        XCTAssertEqual(spec["extract"] as? String, "text")
        XCTAssertEqual(spec["allowLocalhost"] as? Bool, false)
        XCTAssertEqual(spec["localCaptureHost"] as? String, "")
        XCTAssertEqual(spec["localCapturePort"] as? String, "")
        XCTAssertEqual(BrowserSpec.build(url: "https://x", actions: [], extract: "html")["extract"] as? String, "html")
    }

    func testLocalhostCaptureSpecIsPinnedToOriginalOrigin() throws {
        let json = try XCTUnwrap(BrowserSpec.jsonString(url: "http://127.0.0.1:5173",
                                                        actions: [], extract: "text",
                                                        allowLocalhost: true,
                                                        localCaptureHost: "127.0.0.1",
                                                        localCapturePort: "5173"))
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["allowLocalhost"] as? Bool, true)
        XCTAssertEqual(obj?["localCaptureHost"] as? String, "127.0.0.1")
        XCTAssertEqual(obj?["localCapturePort"] as? String, "5173")
    }

    func testBrowserRefusesScreenshotPathEscapeBeforeLaunch() async throws {
        let root = NSTemporaryDirectory() + "browser-root-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ctx = ToolContext(projectRoot: root, shell: ShellPolicy(enabled: true, autoApprove: true))
        let r = try await BrowserTool().execute(arguments: [
            "url": "https://example.com",
            "actions": [["do": "screenshot", "path": "/tmp/outside.png"]]
        ], context: ctx)
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("screenshot path"), r.error ?? "")
    }

    func testBrowserHonorsConfiguredHostAllowlistBeforeLaunch() async throws {
        let ctx = ToolContext(projectRoot: NSTemporaryDirectory(), shell: ShellPolicy(enabled: true, autoApprove: true))
        let r = try await BrowserTool(allowedHosts: ["example.com"]).execute(arguments: [
            "url": "https://openai.com"
        ], context: ctx)
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("host allowlist"), r.error ?? "")
    }

    func testBrowserRefusesSSRFTargets() async throws {
        let ctx = ToolContext(projectRoot: NSTemporaryDirectory(), shell: ShellPolicy(enabled: true, autoApprove: true))
        for bad in ["http://localhost/", "http://127.0.0.1/", "http://169.254.169.254/latest/meta-data/", "http://10.0.0.5/"] {
            let r = try await BrowserTool().execute(arguments: ["url": bad], context: ctx)
            XCTAssertFalse(r.success, "should refuse \(bad)")
            XCTAssertTrue((r.error ?? "").contains("SSRF") || (r.error ?? "").contains("not allowed"), "for \(bad): \(r.error ?? "")")
        }
    }

    func testBrowserCanOptIntoLocalhostForVisualDevServerCapture() async throws {
        let root = NSTemporaryDirectory() + "browser-local-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ctx = ToolContext(projectRoot: root, shell: ShellPolicy(enabled: true, autoApprove: true))

        let allowed = try await BrowserTool(allowLocalhost: true).execute(arguments: [
            "url": "http://127.0.0.1:5173/",
            "actions": [["do": "screenshot", "path": "/tmp/outside.png"]]
        ], context: ctx)

        XCTAssertFalse(allowed.success)
        XCTAssertTrue((allowed.error ?? "").contains("screenshot path"), allowed.error ?? "")
        XCTAssertFalse((allowed.error ?? "").contains("SSRF"), allowed.error ?? "")
        XCTAssertTrue(BrowserTool.isAllowedLocalhostHost("localhost"))
        XCTAssertTrue(BrowserTool.isAllowedLocalhostHost("127.0.0.1"))
        XCTAssertFalse(BrowserTool.isAllowedLocalhostHost("0.0.0.0"))
        XCTAssertFalse(BrowserTool.isAllowedLocalhostHost("10.0.0.5"))
    }

    func testBrowserRejectsNonHTTP() async throws {
        let ctx = ToolContext(projectRoot: NSTemporaryDirectory())
        let r = try await BrowserTool().execute(arguments: ["url": "file:///etc/passwd"], context: ctx)
        XCTAssertFalse(r.success)
    }

    func testDriverIsConstantAndUsesArgvSpec() {
        // The driver must read the spec from argv (data), not interpolate — pin the contract.
        XCTAssertTrue(BrowserSpec.driverJS.contains("JSON.parse(process.argv[2])"))
        XCTAssertTrue(BrowserSpec.driverJS.contains("playwright"))
        XCTAssertTrue(BrowserSpec.driverJS.contains("headless: true"))
        XCTAssertTrue(BrowserSpec.driverJS.contains("page.route('**/*'"))
        XCTAssertTrue(BrowserSpec.driverJS.contains("configuredAllowedHosts"))
        XCTAssertTrue(BrowserSpec.driverJS.contains("allowLocalhost"))
        XCTAssertTrue(BrowserSpec.driverJS.contains("sameLocalCaptureOrigin"))
        XCTAssertTrue(BrowserSpec.driverJS.contains("localCapturePort"))
        XCTAssertFalse(BrowserSpec.driverJS.contains("h === '0.0.0.0'"))
    }

    func testDriverTempFileIsOwnerOnly() throws {
        let path = NSTemporaryDirectory() + "kist-browser-driver-test-\(UUID().uuidString).js"
        defer { try? FileManager.default.removeItem(atPath: path) }

        try BrowserTool.writeDriver(at: path)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perms.intValue & 0o777, 0o600)
    }
}
