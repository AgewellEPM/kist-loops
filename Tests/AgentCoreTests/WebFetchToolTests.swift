import XCTest
import Foundation
@testable import AgentCore

/// Deterministic (no real network): the SSRF classifier runs on numeric IPs (getaddrinfo
/// resolves them instantly) and literal localhost, and the scheme/HTML logic is pure.
final class WebFetchToolTests: XCTestCase {
    private actor FetchProbe {
        private var calls = 0

        func record() { calls += 1 }
        func count() -> Int { calls }
    }

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
        // Block every representative special-purpose class, not just RFC1918.
        for host in ["127.0.0.1", "10.0.0.1", "192.168.1.1", "172.16.0.1", "172.31.255.255",
                     "169.254.169.254", "0.0.0.0", "100.64.0.1", "198.18.0.1",
                     "192.0.2.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "240.0.0.1",
                     "192.31.196.1", "192.52.193.1", "192.88.99.1", "192.175.48.1",
                     "::", "::1", "fec0::1", "fe80::1", "fc00::1", "ff05::1",
                     "64:ff9b::1", "100::1", "2001:db8::1", "2001::1", "2002::1",
                     "2620:4f:8000::1", "3fff::1"] {
            XCTAssertNotNil(WebFetchTool.ssrfBlockReason(host: host), "\(host) must be blocked")
        }
        XCTAssertNotNil(WebFetchTool.ssrfBlockReason(host: "localhost"))
    }

    func testSSRFAllowsPublic() {
        for host in ["8.8.8.8", "1.1.1.1", "172.32.0.1", "2606:4700:4700::1111",
                     "2001:4860:4860::8888"] {
            XCTAssertNil(WebFetchTool.ssrfBlockReason(host: host), "\(host) is public, must be allowed")
        }
    }

    func testSSRFRejectsResolutionFailure() {
        XCTAssertNotNil(WebFetchTool.ssrfBlockReason(host: "cannot-resolve.invalid"))
    }

    func testEmptyConfiguredAllowlistPermitsPublicHosts() {
        XCTAssertNil(WebFetchTool.allowlistBlockReason(host: "8.8.8.8", configured: [], perCall: []))
    }

    func testPerCallAllowlistNarrowsUnrestrictedPublicPolicy() {
        XCTAssertNil(WebFetchTool.allowlistBlockReason(host: "8.8.8.8",
                                                       configured: [], perCall: ["8.8.8.8"]))
        XCTAssertNotNil(WebFetchTool.allowlistBlockReason(host: "1.1.1.1",
                                                          configured: [], perCall: ["8.8.8.8"]))
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

    func testConfiguredAndPerCallPoliciesBlockBeforeTransportOrDNS() async {
        let probe = FetchProbe()
        let tool = WebFetchTool(allowedHosts: ["*.example"]) { _, _ in
            await probe.record()
            return PublicWebHTTPResponse(statusCode: 200, body: "unexpected")
        }
        let registry = ToolRegistry([tool])

        let configured = await registry.execute(
            name: "fetch_url",
            arguments: ["url": "https://outside.test/page"],
            context: ToolContext(projectRoot: "/tmp")
        )
        let perCall = await registry.execute(
            name: "fetch_url",
            arguments: ["url": "https://allowed.example/page", "allowed_hosts": ["other.example"]],
            context: ToolContext(projectRoot: "/tmp")
        )
        let callCount = await probe.count()

        XCTAssertFalse(configured.success)
        XCTAssertFalse(perCall.success)
        XCTAssertEqual(callCount, 0)
    }

    func testEmptyConfiguredPolicyAllowsPublicHostThroughTransport() async {
        let probe = FetchProbe()
        let tool = WebFetchTool(allowedHosts: []) { _, _ in
            await probe.record()
            return PublicWebHTTPResponse(statusCode: 200, body: "public result")
        }
        let result = await ToolRegistry([tool]).execute(
            name: "fetch_url",
            arguments: ["url": "https://example.com/page"],
            context: ToolContext(projectRoot: "/tmp")
        )
        let callCount = await probe.count()

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "public result")
        XCTAssertEqual(callCount, 1)
    }

    func testBoundedPrimaryFetchForwardsFiniteByteLimitAndReportsPartialStatus() async {
        let limits = FetchLimitProbe()
        let tool = WebFetchTool(allowedHosts: []) { _, maxBytes in
            await limits.record(maxBytes)
            return PublicWebHTTPResponse(statusCode: 206, body: "bounded primary evidence")
        }
        let result = await ToolRegistry([tool]).execute(
            name: "fetch_url",
            arguments: [
                "url": "https://docs.example.com/manual",
                "allowed_hosts": ["docs.example.com"],
                "max_bytes": 64_000,
            ],
            context: ToolContext(projectRoot: "/tmp"))

        let capturedLimits = await limits.values()
        XCTAssertTrue(result.success, result.error ?? result.output)
        XCTAssertEqual(capturedLimits, [64_000])
        XCTAssertEqual(result.metadata["status"], "206")
        XCTAssertEqual(result.metadata["fetch_status"], "partial")
    }

    func testRangeIgnoringSuccessIsUTF8ByteBoundedAndMarkedPartial() async {
        let body = String(repeating: "é", count: 40_000)
        let tool = WebFetchTool(allowedHosts: []) { _, _ in
            PublicWebHTTPResponse(statusCode: 200, body: body)
        }
        let result = await ToolRegistry([tool]).execute(
            name: "fetch_url",
            arguments: [
                "url": "https://docs.example.com/manual",
                "allowed_hosts": ["docs.example.com"],
                "max_bytes": 64_001,
            ],
            context: ToolContext(projectRoot: "/tmp"))

        XCTAssertTrue(result.success, result.error ?? result.output)
        XCTAssertLessThanOrEqual(result.output.utf8.count, 64_001)
        XCTAssertTrue(result.output.hasSuffix("é"), "UTF-8 prefix must not end in a replacement scalar")
        XCTAssertEqual(result.metadata["status"], "200")
        XCTAssertEqual(result.metadata["fetch_status"], "partial")
        XCTAssertEqual(result.metadata["truncated"], "true")
    }

    func testInvalidBoundedPrimaryFetchLimitFailsBeforeTransport() async {
        let probe = FetchProbe()
        let tool = WebFetchTool(allowedHosts: []) { _, _ in
            await probe.record()
            return PublicWebHTTPResponse(statusCode: 200, body: "unexpected")
        }
        let result = await ToolRegistry([tool]).execute(
            name: "fetch_url",
            arguments: ["url": "https://example.com", "max_bytes": 10],
            context: ToolContext(projectRoot: "/tmp"))

        let callCount = await probe.count()
        XCTAssertFalse(result.success)
        XCTAssertEqual(callCount, 0)
    }

    func testMalformedPerCallAllowlistIsRejected() async {
        let r = await ToolRegistry([WebFetchTool(allowedHosts: ["8.8.8.8"])]).execute(
            name: "fetch_url", arguments: ["url": "https://8.8.8.8", "allowed_hosts": [String]()],
            context: ToolContext(projectRoot: "/tmp"))
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("non-empty string array"))

        for malformed: Any in ["8.8.8.8", [8, 8, 8, 8]] {
            let wrongType = await ToolRegistry([WebFetchTool()]).execute(
                name: "fetch_url",
                arguments: ["url": "https://8.8.8.8", "allowed_hosts": malformed],
                context: ToolContext(projectRoot: "/tmp"))
            XCTAssertFalse(wrongType.success)
            XCTAssertFalse((wrongType.error ?? "").isEmpty)
        }
    }

    func testMalformedConfiguredAllowlistFailsClosedBeforeTransport() async {
        let probe = FetchProbe()
        let tool = WebFetchTool(allowedHosts: ["example.com", "https://bad.example"]) { _, _ in
            await probe.record()
            return PublicWebHTTPResponse(statusCode: 200, body: "unexpected")
        }
        let result = await ToolRegistry([tool]).execute(
            name: "fetch_url", arguments: ["url": "https://example.com"],
            context: ToolContext(projectRoot: "/tmp"))
        let callCount = await probe.count()

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("configured fetch host allowlist"))
        XCTAssertEqual(callCount, 0)
    }

    func testOversizedURLFailsBeforeTransport() async {
        let probe = FetchProbe()
        let tool = WebFetchTool(allowedHosts: []) { _, _ in
            await probe.record()
            return PublicWebHTTPResponse(statusCode: 200, body: "unexpected")
        }
        let url = "https://example.com/" + String(
            repeating: "x", count: PublicWebTransport.maxURLBytes)
        let result = await ToolRegistry([tool]).execute(
            name: "fetch_url", arguments: ["url": url],
            context: ToolContext(projectRoot: "/tmp"))
        let callCount = await probe.count()

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("byte limit"))
        XCTAssertEqual(callCount, 0)
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

private actor FetchLimitProbe {
    private var captured: [Int] = []
    func record(_ value: Int) { captured.append(value) }
    func values() -> [Int] { captured }
}
