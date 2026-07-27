import XCTest
@testable import AgentCore

final class MediaIndexTests: XCTestCase {

    func testParsesStructuredJSON() throws {
        let raw = """
        Here you go:
        ```json
        {"summary":"A product demo.","durationHint":"4:35",
         "timeline":[{"at":"00:10","label":"Intro","detail":"host greets"}],
         "transcript":[{"at":"00:12","speaker":"Host","label":"Welcome everyone"}],
         "keyMoments":[{"at":"02:40","label":"the pricing reveal"}]}
        ```
        """
        let idx = try XCTUnwrap(MediaIndex.parse(raw))
        XCTAssertEqual(idx.summary, "A product demo.")
        XCTAssertEqual(idx.durationHint, "4:35")
        XCTAssertEqual(idx.timeline.first?.at, "00:10")
        XCTAssertEqual(idx.transcript.first?.speaker, "Host")
        XCTAssertEqual(idx.keyMoments.first?.label, "the pricing reveal")
    }

    func testFirstJSONObjectIgnoresBracesInStrings() {
        let raw = #"prose {"summary":"he said {hi} to her","timeline":[]} trailing"#
        let idx = MediaIndex.parse(raw)
        XCTAssertEqual(idx?.summary, "he said {hi} to her")
    }

    func testParseRejectsMissingSummary() {
        XCTAssertNil(MediaIndex.parse(#"{"timeline":[]}"#))
        XCTAssertNil(MediaIndex.parse("no json here"))
    }

    func testSearchRanksMatchingMoments() {
        let idx = MediaIndex(summary: "x",
                             timeline: [.init(at: "01:00", label: "pricing discussion", detail: "they cover tiers")],
                             keyMoments: [.init(at: "02:00", label: "intro")])
        let hits = idx.search("pricing tiers")
        XCTAssertEqual(hits.first?.at, "01:00")
        XCTAssertTrue(idx.search("dinosaurs").isEmpty)
    }

    func testCacheKeyIsDeterministicPerBytes() {
        let a = MediaAnalyzer.cacheKey(forData: Data([1, 2, 3]))
        let b = MediaAnalyzer.cacheKey(forData: Data([1, 2, 3]))
        let c = MediaAnalyzer.cacheKey(forData: Data([1, 2, 4]))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 64)   // sha-256 hex
    }

    func testPromptCarriesSchemaAndFocus() {
        XCTAssertTrue(MediaAnalyzer.prompt(want: .transcript).contains("transcript"))
        XCTAssertTrue(MediaAnalyzer.prompt(want: .all).contains("\"timeline\""))
    }
}
