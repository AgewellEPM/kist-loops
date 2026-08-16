import Foundation
import XCTest

final class KistInterruptWarningIntegrationTests: XCTestCase {
    func testREPLWiresVisibleRawWatchFailureWarning() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Kist/KistREPL.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("onInterruptUnavailable:"))
        XCTAssertTrue(source.contains("warning: keyboard interrupt unavailable for this turn"))
        XCTAssertTrue(source.contains("self.pinnedBar.suspend()"))
    }
}
