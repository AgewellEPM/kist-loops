import XCTest
import Foundation
@testable import AgentCore

final class WebSearchToolTests: XCTestCase {
    private let html = #"""
    <html><body>
      <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fone&amp;rut=x">Example &amp; One</a>
      <a class="result__snippet">First <b>snippet</b> &amp; details.</a>
      <a rel="nofollow" class="result__a" href="https://swift.org/blog/">Swift Blog</a>
      <div class="result__snippet">Second snippet.</div>
    </body></html>
    """#

    func testParsesDuckDuckGoResultsAndNormalizesRedirectURLs() {
        let results = WebSearchTool.parseDuckDuckGoHTML(html, limit: 10)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Example & One")
        XCTAssertEqual(results[0].url, "https://example.com/one")
        XCTAssertEqual(results[0].snippet, "First snippet & details.")
        XCTAssertEqual(results[1].url, "https://swift.org/blog/")
    }

    func testClampsLimit() {
        XCTAssertEqual(WebSearchTool.clampedLimit(nil), 5)
        XCTAssertEqual(WebSearchTool.clampedLimit(0), 1)
        XCTAssertEqual(WebSearchTool.clampedLimit(99), 10)
        XCTAssertEqual(WebSearchTool.clampedLimit("3"), 3)
        XCTAssertEqual(WebSearchTool.clampedLimit(Double.nan), 5)
        XCTAssertEqual(WebSearchTool.clampedLimit(Double.infinity), 5)
    }

    func testExecuteBuildsSiteConstrainedQueryAndReturnsResults() async throws {
        let capture = SearchURLCapture()
        let html = self.html
        let tool = WebSearchTool(fetcher: { url in
            await capture.record(url)
            return html
        }, backends: [.duckDuckGoHTML])

        let result = try await tool.execute(arguments: [
            "query": "concurrency actors",
            "site": "swift.org",
            "limit": 1,
        ], context: ToolContext(projectRoot: "/tmp"))

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(result.output.contains("Example & One"))
        XCTAssertFalse(result.output.contains("Swift Blog"), "limit=1 should return one result")
        XCTAssertEqual(result.metadata["count"], "1")

        let url = await capture.last()
        let query = URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        XCTAssertEqual(query, "site:swift.org concurrency actors")
    }

    func testExecuteRejectsEmptyQuery() async throws {
        let result = try await WebSearchTool(fetcher: { _ in "" }).execute(
            arguments: ["query": "   "],
            context: ToolContext(projectRoot: "/tmp")
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("query is required"))
    }

    func testExecuteRejectsOversizedQueryAndSiteBeforeFetch() async throws {
        let capture = SearchURLCapture()
        let tool = WebSearchTool(fetcher: { url in
            await capture.record(url)
            return ""
        })
        let queryResult = try await tool.execute(
            arguments: ["query": String(repeating: "q", count: WebSearchTool.maxQueryBytes + 1)],
            context: ToolContext(projectRoot: "/tmp"))
        let siteResult = try await tool.execute(
            arguments: ["query": "safe", "site": String(
                repeating: "s", count: WebSearchTool.maxSiteBytes + 1)],
            context: ToolContext(projectRoot: "/tmp"))
        let fetchedURLs = await capture.all()

        XCTAssertFalse(queryResult.success)
        XCTAssertFalse(siteResult.success)
        XCTAssertTrue((queryResult.error ?? "").contains("byte limit"))
        XCTAssertTrue((siteResult.error ?? "").contains("bounded exact hostname"))
        XCTAssertTrue(fetchedURLs.isEmpty)
    }

    func testExecuteRejectsWrongSiteTypeBeforeFetch() async throws {
        let capture = SearchURLCapture()
        let tool = WebSearchTool(fetcher: { url in await capture.record(url); return "" })
        let result = try await tool.execute(
            arguments: ["query": "safe", "site": ["example.com"]],
            context: ToolContext(projectRoot: "/tmp"))

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("bounded exact hostname"))
        let fetchedURLs = await capture.all()
        XCTAssertTrue(fetchedURLs.isEmpty)
    }

    func testExecuteFallsBackToDuckDuckGoLiteWhenHTMLParserFindsNothing() async throws {
        let capture = SearchURLCapture()
        let responses = SearchResponses([
            "<html><body>no standard results</body></html>",
            #"""
            <html><body>
              <a rel="nofollow" href="https://example.com/lite">Lite Result</a>
              <td class="result-snippet">Lite snippet.</td>
            </body></html>
            """#,
        ])
        let tool = WebSearchTool(fetcher: { url in
            await capture.record(url)
            return await responses.next()
        }, backends: [.duckDuckGoHTML, .duckDuckGoLite])

        let result = try await tool.execute(arguments: ["query": "fallback search"], context: ToolContext(projectRoot: "/tmp"))

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(result.output.contains("Lite Result"))
        XCTAssertEqual(result.metadata["engine"], "duckduckgo_lite")
        let urls = await capture.all()
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0].host, "duckduckgo.com")
        XCTAssertEqual(urls[1].host, "lite.duckduckgo.com")
    }

    func testExecuteUsesBraveJSONWhenConfigured() async throws {
        let json = #"""
        {"web":{"results":[
          {"title":"Brave &amp; Result","url":"https://example.com/brave","description":"Fresh source."}
        ]}}
        """#
        let tool = WebSearchTool(fetcher: { _ in json }, backends: [.brave])

        let result = try await tool.execute(arguments: ["query": "current source"], context: ToolContext(projectRoot: "/tmp"))

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(result.output.contains("Brave & Result"))
        XCTAssertEqual(result.metadata["engine"], "brave_search")
    }
}

private actor SearchURLCapture {
    private var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }

    func last() -> URL? {
        urls.last
    }

    func all() -> [URL] {
        urls
    }
}

private actor SearchResponses {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        values.isEmpty ? "" : values.removeFirst()
    }
}
