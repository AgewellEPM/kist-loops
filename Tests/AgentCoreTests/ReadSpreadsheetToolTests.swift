import XCTest
@testable import AgentCore

final class ReadSpreadsheetToolTests: XCTestCase {

    func testParseCSVHandlesQuotesEmbeddedDelimitersAndEscapes() {
        let csv = "a,b,c\n1,\"two, with comma\",3\n\"line\nbreak\",y,\"quote\"\"in\"\"field\""
        let rows = ReadSpreadsheetTool.parseCSV(csv, delimiter: ",")
        XCTAssertEqual(rows[0], ["a", "b", "c"])
        XCTAssertEqual(rows[1], ["1", "two, with comma", "3"])
        XCTAssertEqual(rows[2], ["line\nbreak", "y", "quote\"in\"field"])
    }

    func testParseCSVDropsBlankLines() {
        let rows = ReadSpreadsheetTool.parseCSV("a,b\n\n1,2\n", delimiter: ",")
        XCTAssertEqual(rows.count, 2)
    }

    func testRenderTableCapsRows() {
        let rows = (0..<100).map { ["\($0)", "x"] }
        let out = ReadSpreadsheetTool.renderTable(rows, maxRows: 10)
        XCTAssertTrue(out.contains("+90 more rows"))
    }

    func testExecuteReadsCSVConfinedToRoot() async throws {
        let dir = NSTemporaryDirectory() + "rs_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let csv = "name,score\nAlice,10\nBob,20\n"
        try csv.write(toFile: dir + "/data.csv", atomically: true, encoding: .utf8)

        let ctx = ToolContext(projectRoot: dir)
        let result = try await ReadSpreadsheetTool().execute(arguments: ["path": "data.csv"], context: ctx)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("3 rows × 2 cols"))
        XCTAssertTrue(result.output.contains("Alice | 10"))
        XCTAssertEqual(result.metadata["rows"], "3")
    }

    func testExecuteRefusesPathEscape() async {
        let dir = NSTemporaryDirectory() + "rs_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ctx = ToolContext(projectRoot: dir)
        do {
            _ = try await ReadSpreadsheetTool().execute(arguments: ["path": "../../etc/hosts"], context: ctx)
            XCTFail("expected a path-escape refusal")
        } catch {
            // ToolError.pathEscape or notFound — either way it must not read outside the root.
            XCTAssertTrue(true)
        }
    }
}
