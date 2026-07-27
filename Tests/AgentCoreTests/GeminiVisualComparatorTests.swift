import XCTest
@testable import AgentCore

/// The real visual-diff node's parsing + fail-closed behavior (stubbed vision response — no network).
final class GeminiVisualComparatorTests: XCTestCase {

    func comparator(_ reply: String?) -> GeminiVisualComparator {
        GeminiVisualComparator { _, _, _ in reply }
    }
    let ref = VisualReference(label: "real", source: "/tmp/real.png")
    func rendered(ok: Bool = true) -> RenderedView { RenderedView(imagePath: "/tmp/shot.png", ok: ok) }

    func testParsesScoreAndDiffs() async {
        let c = comparator("SIMILARITY: 87\nDIFF|major|header|logo missing\nDIFF|minor|button|slightly darker")
        let r = await c.compare(reference: ref, rendered: rendered())
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.similarity, 0.87, accuracy: 0.001)
        XCTAssertEqual(r.diffs.count, 2)
        XCTAssertEqual(r.diffs.first?.area, "header")
    }

    func testPerfectScoreClampsToOne() async {
        let r = await comparator("SIMILARITY: 100").compare(reference: ref, rendered: rendered())
        XCTAssertEqual(r.similarity, 1.0, accuracy: 0.001)
        XCTAssertTrue(r.diffs.isEmpty)
    }

    func testNoScoreFailsClosed() async {
        // model rambled but gave no SIMILARITY line ⇒ not ok, similarity 0 (never read as a match).
        let r = await comparator("it looks pretty close honestly").compare(reference: ref, rendered: rendered())
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.similarity, 0.0, accuracy: 0.001)
    }

    func testEmptyResponseFailsClosed() async {
        let r = await comparator(nil).compare(reference: ref, rendered: rendered())
        XCTAssertFalse(r.ok)
    }

    func testNoRenderFailsClosedBeforeCallingModel() async {
        // even if the model would say 100, a missing screenshot can't be compared.
        let r = await comparator("SIMILARITY: 100").compare(reference: ref, rendered: rendered(ok: false))
        XCTAssertFalse(r.ok)
    }

    func testAcceptsFractionalOneToZeroScale() async {
        let r = await comparator("similarity 0.92").compare(reference: ref, rendered: rendered())
        XCTAssertEqual(r.similarity, 0.92, accuracy: 0.001)
    }
}
