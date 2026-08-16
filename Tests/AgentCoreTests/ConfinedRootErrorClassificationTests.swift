import XCTest
@testable import AgentCore

final class ConfinedRootErrorClassificationTests: XCTestCase {
    func testMissingIntermediateIsNotMisreportedAsEscapeAndLocalizedErrorIsUseful() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("confined-errors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let confined = try ConfinedRoot(root: root.path)

        XCTAssertThrowsError(try confined.fileType("missing/child.cbl")) { error in
            guard case ToolError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.hasPrefix("not found:"))
            XCTAssertFalse(error.localizedDescription.contains("escapes the project root"))
        }
        let denied = ToolError.pathEscape(path: "../outside", root: confined.rootPath)
        XCTAssertEqual(denied.localizedDescription, denied.description)
    }
}
