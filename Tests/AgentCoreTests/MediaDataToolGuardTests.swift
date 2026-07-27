import XCTest
@testable import AgentCore

final class MediaDataToolGuardTests: XCTestCase {

    // MARK: extract_clip timestamp validation

    func testTimestampValidation() {
        XCTAssertTrue(MediaClipTool.isValidTimestamp("04:12"))
        XCTAssertTrue(MediaClipTool.isValidTimestamp("01:04:12"))
        XCTAssertTrue(MediaClipTool.isValidTimestamp("90"))
        XCTAssertTrue(MediaClipTool.isValidTimestamp("12.5"))
        XCTAssertFalse(MediaClipTool.isValidTimestamp(""))
        XCTAssertFalse(MediaClipTool.isValidTimestamp("-1"))
        XCTAssertFalse(MediaClipTool.isValidTimestamp("4m12s"))
        XCTAssertFalse(MediaClipTool.isValidTimestamp("04:60"))
        XCTAssertFalse(MediaClipTool.isValidTimestamp("1.5:02"))
        XCTAssertFalse(MediaClipTool.isValidTimestamp("; rm -rf /"))
        XCTAssertFalse(MediaClipTool.isValidTimestamp("00:"))
    }

    func testExtractClipRejectsUnknownKindBeforeTouchingFilesystem() async throws {
        let tool = MediaClipTool()
        let result = try await tool.execute(
            arguments: ["path": "missing.mp4", "at": "00:01", "kind": "gif"],
            context: ToolContext(projectRoot: NSTemporaryDirectory())
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "kind must be 'frame' or 'clip'")
    }

    // MARK: query_data read-only enforcement

    func testReadOnlySqlAccepted() {
        XCTAssertTrue(QueryDataTool.isReadOnly("SELECT region, sum(sales) FROM data GROUP BY region"))
        XCTAssertTrue(QueryDataTool.isReadOnly("  with t as (select * from data) select count(*) from t  "))
        XCTAssertTrue(QueryDataTool.isReadOnly("DESCRIBE data"))
        XCTAssertTrue(QueryDataTool.isReadOnly("SUMMARIZE data"))
        XCTAssertTrue(QueryDataTool.isReadOnly("SELECT * FROM data;"))   // trailing ; trimmed
    }

    func testMutatingOrMultiStatementSqlRejected() {
        XCTAssertFalse(QueryDataTool.isReadOnly("DROP TABLE data"))
        XCTAssertFalse(QueryDataTool.isReadOnly("INSERT INTO data VALUES (1)"))
        XCTAssertFalse(QueryDataTool.isReadOnly("COPY data TO 'out.csv'"))
        XCTAssertFalse(QueryDataTool.isReadOnly("ATTACH 'evil.db'"))
        XCTAssertFalse(QueryDataTool.isReadOnly("SELECT 1; DROP TABLE data"))   // multi-statement
        XCTAssertFalse(QueryDataTool.isReadOnly("INSTALL httpfs"))
        XCTAssertFalse(QueryDataTool.isReadOnly("select * from data into outfile 'x'"))
    }

    func testReaderForFileType() {
        XCTAssertTrue(QueryDataTool.readerFor("/p/a.parquet").hasPrefix("read_parquet("))
        XCTAssertTrue(QueryDataTool.readerFor("/p/a.json").hasPrefix("read_json_auto("))
        XCTAssertTrue(QueryDataTool.readerFor("/p/a.csv").hasPrefix("read_csv_auto("))
        // single-quote in a path is escaped to keep it a literal
        XCTAssertTrue(QueryDataTool.readerFor("/p/o'brien.csv").contains("o''brien"))
    }
}
