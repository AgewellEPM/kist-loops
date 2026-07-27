import XCTest
import AgentCore
@testable import Kist

final class FloodPathTests: XCTestCase {
    let p = "/var/folders/d_/abc/T/TemporaryItems/NSIRD_x/Screenshot.png"

    func testFloodedPathCollapsesToOnePlusMessage() {
        let flooded = Array(repeating: p, count: 40).joined(separator: " ") + " what is this image of"
        let out = KistREPL.collapseFloodedPaths(flooded)
        XCTAssertEqual(out, "\(p) what is this image of")
    }

    func testNormalInputUntouched() {
        XCTAssertEqual(KistREPL.collapseFloodedPaths("build me a javascript clock"),
                       "build me a javascript clock")
    }

    func testASinglePathIsKept() {
        XCTAssertEqual(KistREPL.collapseFloodedPaths("\(p) describe this"), "\(p) describe this")
    }

    func testRepeatedShortWordsAreNotTouched() {
        // only path-like (has "/", long) tokens collapse — plain repeated words are left alone
        XCTAssertEqual(KistREPL.collapseFloodedPaths("very very very good"), "very very very good")
    }
}
