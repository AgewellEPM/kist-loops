import XCTest
@testable import AgentCore

final class ResearchGoalURLExtractorTests: XCTestCase {
    func testExtractsExactLiveResearchURLInsteadOfTreatingItAsSearchOnly() {
        let goal = "Use --research and fetch https://example.com/ before the council decides."
        XCTAssertEqual(ResearchRunTool.canonicalGoalURLs(in: goal), ["https://example.com/"])
    }

    func testCanonicalizesDeduplicatesAndCapsHTTPURLs() {
        let goal = """
        Compare HTTPS://EXAMPLE.com:443/docs#intro, https://example.com/docs#other,
        http://Example.com:80/a), and https://second.example/path.
        """
        XCTAssertEqual(ResearchRunTool.canonicalGoalURLs(in: goal, limit: 2), [
            "https://example.com/docs",
            "http://example.com/a",
        ])
    }

    func testIgnoresNonHTTPAndCredentialBearingURLs() {
        let goal = "ftp://example.com/a file:///tmp/a https://user:secret@example.com/private"
        XCTAssertTrue(ResearchRunTool.canonicalGoalURLs(in: goal).isEmpty)
    }
}
