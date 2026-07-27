import XCTest
@testable import AgentCore

final class DisplayGeometryTests: XCTestCase {

    // main: 1440x900 pt @2x at origin (0,0); secondary: 1920x1080 pt @1x to the right at x=1440.
    private let main = DisplayInfo(id: 1, originX: 0, originY: 0, widthPt: 1440, heightPt: 900, scale: 2, isMain: true)
    private let secondary = DisplayInfo(id: 2, originX: 1440, originY: 0, widthPt: 1920, heightPt: 1080, scale: 1, isMain: false)
    private var displays: [DisplayInfo] { [main, secondary] }

    func testPixelDimensions() {
        XCTAssertEqual(main.pixelWidth, 2880); XCTAssertEqual(main.pixelHeight, 1800)   // 2x
        XCTAssertEqual(secondary.pixelWidth, 1920)                                        // 1x
    }

    func testGlobalPointToLocalPixelMainRetina() {
        // center of main (720,450 pt) → pixels (1440,900) at 2x
        XCTAssertEqual(main.globalPointToLocalPixel(x: 720, y: 450).x, 1440)
        XCTAssertEqual(main.globalPointToLocalPixel(x: 720, y: 450).y, 900)
    }

    func testGlobalPointToLocalPixelSecondaryOffset() {
        // a point at global (1440,0) is the secondary's TOP-LEFT → local pixel (0,0)
        XCTAssertEqual(secondary.globalPointToLocalPixel(x: 1440, y: 0).x, 0)
        // global (2400, 540) → local point (960,540) @1x → pixel (960,540)
        XCTAssertEqual(secondary.globalPointToLocalPixel(x: 2400, y: 540).x, 960)
        XCTAssertEqual(secondary.globalPointToLocalPixel(x: 2400, y: 540).y, 540)
    }

    func testLocalPixelToGlobalPointRoundTrips() {
        for d in displays {
            let g = d.localPixelToGlobalPoint(x: 100, y: 60)
            let p = d.globalPointToLocalPixel(x: g.x, y: g.y)
            XCTAssertEqual(p.x, 100); XCTAssertEqual(p.y, 60)
        }
    }

    func testDisplayForGlobalPointPicksRightMonitor() {
        XCTAssertEqual(DisplayGeometry.display(forGlobalPoint: 100, y: 100, in: displays)?.id, 1)
        XCTAssertEqual(DisplayGeometry.display(forGlobalPoint: 2000, y: 500, in: displays)?.id, 2)
        // dead space below main (main is only 900pt tall) but within secondary's x-range/y: still secondary if inside it
        XCTAssertNil(DisplayGeometry.display(forGlobalPoint: 100, y: 2000, in: displays))   // off all displays
    }

    func testContainsLocalPixelBounds() {
        XCTAssertTrue(main.containsLocalPixel(x: 0, y: 0))
        XCTAssertTrue(main.containsLocalPixel(x: 2879, y: 1799))
        XCTAssertFalse(main.containsLocalPixel(x: 2880, y: 0))   // one past the edge
        XCTAssertFalse(main.containsLocalPixel(x: -1, y: 0))
    }

    func testResolveByIdAndMain() {
        XCTAssertEqual(DisplayGeometry.display(id: nil, in: displays)?.id, 1)   // nil ⇒ main
        XCTAssertEqual(DisplayGeometry.display(id: 2, in: displays)?.id, 2)
        XCTAssertNil(DisplayGeometry.display(id: 99, in: displays))             // unknown id
        XCTAssertEqual(DisplayGeometry.main(displays)?.id, 1)
    }

    func testDegenerateScaleGuarded() {
        let d = DisplayInfo(id: 3, originX: 0, originY: 0, widthPt: 100, heightPt: 100, scale: 0, isMain: false)
        // guarded to a tiny positive scale — no divide-by-zero / trap
        XCTAssertNoThrow(_ = d.localPixelToGlobalPoint(x: 10, y: 10))
        XCTAssertGreaterThan(d.scale, 0)
    }
}
