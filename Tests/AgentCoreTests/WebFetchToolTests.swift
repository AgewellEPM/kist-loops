import XCTest
import Foundation
@testable import AgentCore

/// Deterministic (no real network): the SSRF classifier runs on numeric IPs (getaddrinfo
/// resolves them instantly) and literal localhost, and the scheme/HTML logic is pure.
final class WebFetchToolTests: XCTestCase {

    private func run(_ url: String) async -> ToolResult {
        await ToolRegistry([WebFetchTool()]).execute(name: "fetch_url", arguments: ["url": url],
                                                     context: ToolContext(projectRoot: "/tmp"))
    }

    func testRejectsNonHttpScheme() async {
        let r = await run("file:///etc/passwd")
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("http(s)"))
    }

    func testSSRFBlocksLoopbackAndPrivateAndMetadata() {
        // Block: loopback, RFC1918, link-local/metadata, ULA/link-local v6.
        for host in ["127.0.0.1", "10.0.0.1", "192.168.1.1", "172.16.0.1", "172.31.255.255",
                     "169.254.169.254", "0.0.0.0", "::1"] {
            XCTAssertNotNil(WebFetchTool.ssrfBlockReason(host: host), "\(host) must be blocked")
        }
        XCTAssertNotNil(WebFetchTool.ssrfBlockReason(host: "localhost"))
    }

    func testSSRFAllowsPublic() {
        for host in ["8.8.8.8", "1.1.1.1", "172.32.0.1"] {   // 172.32 is OUTSIDE the 172.16-31 private range
            XCTAssertNil(WebFetchTool.ssrfBlockReason(host: host), "\(host) is public, must be allowed")
        }
    }

    func testBlockedHostFetchFailsBeforeNetwork() async {
        let r = await run("http://169.254.169.254/latest/meta-data/")
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("SSRF"))
    }

    func testConfiguredAllowlistBlocksBeforeNetwork() async {
        let r = await ToolRegistry([WebFetchTool(allowedHosts: ["docs.swift.org"])]).execute(
            name: "fetch_url",
            arguments: ["url": "https://example.com/page"],
            context: ToolContext(projectRoot: "/tmp")
        )

        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("host allowlist"))
    }

    func testAllowlistSupportsExactAndWildcardHosts() {
        XCTAssertNil(WebFetchTool.allowlistBlockReason(host: "docs.swift.org",
                                                       configured: ["docs.swift.org"], perCall: []))
        XCTAssertNil(WebFetchTool.allowlistBlockReason(host: "api.swift.org",
                                                       configured: ["*.swift.org"], perCall: []))
        XCTAssertNotNil(WebFetchTool.allowlistBlockReason(host: "swift.org",
                                                          configured: ["*.swift.org"], perCall: []))
        XCTAssertNotNil(WebFetchTool.allowlistBlockReason(host: "evilswift.org",
                                                          configured: ["*.swift.org"], perCall: []))
    }

    func testPerCallAllowlistCanOnlyNarrowConfiguredAllowlist() {
        XCTAssertNil(WebFetchTool.allowlistBlockReason(host: "docs.swift.org",
                                                       configured: ["*.swift.org"], perCall: ["docs.swift.org"]))
        XCTAssertNotNil(WebFetchTool.allowlistBlockReason(host: "api.swift.org",
                                                          configured: ["*.swift.org"], perCall: ["docs.swift.org"]))
        XCTAssertNotNil(WebFetchTool.allowlistBlockReason(host: "example.com",
                                                          configured: ["docs.swift.org"], perCall: ["example.com"]))
    }

    func testHtmlToTextStripsScriptAndTagsAndEntities() {
        let html = "<html><head><style>.a{}</style></head><body><script>steal()</script><h1>Title</h1><p>x &amp; y &lt;ok&gt;</p></body></html>"
        let t = WebFetchTool.htmlToText(html)
        XCTAssertFalse(t.contains("steal()"))
        XCTAssertFalse(t.contains(".a{}"))
        XCTAssertFalse(t.contains("<h1>"))
        XCTAssertTrue(t.contains("Title"))
        XCTAssertTrue(t.contains("x & y <ok>"))
    }
}
