import XCTest
@testable import DesignFlowKit

final class SignalRankerTests: XCTestCase {
    func testAccessibilitySignalOutranksTrivialViralPost() {
        let ranker = SignalRanker()
        let accessible = Signal(source: "s", title: "Accessible AAC board editor for speech therapy",
                                body: "assistive tool for disability", url: "u", engagement: 50)
        let trivial = Signal(source: "s", title: "Yet another todo app",
                             body: "hello world todo app", url: "u", engagement: 5000)
        let ranked = ranker.rank([trivial, accessible])
        XCTAssertEqual(ranked.first?.signal.title, accessible.title,
                       "relevance must beat raw engagement")
    }

    func testNegativeKeywordsPushDown() {
        let ranker = SignalRanker()
        XCTAssertLessThan(
            ranker.score(Signal(source: "s", title: "Yet another todo app", body: "", url: "u", engagement: 10)),
            ranker.score(Signal(source: "s", title: "ADA accessibility tool", body: "", url: "u", engagement: 10)))
    }

    func testRankingIsDeterministic() {
        let ranker = SignalRanker()
        let signals = (0..<20).map { Signal(source: "s", title: "t\($0)", body: "b", url: "u", engagement: $0) }
        XCTAssertEqual(ranker.rank(signals), ranker.rank(signals))
    }

    func testTopIsNilForEmpty() {
        XCTAssertNil(SignalRanker().top([]))
    }
}
