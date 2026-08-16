import XCTest
import AgentCore
@testable import Kist

final class KistConfigPublicWebTests: XCTestCase {
    func testWrongFetchAllowlistJSONTypeRemainsInvalidAndFailsClosed() async throws {
        for raw: Any in ["example.com", ["example.com", 7], 7] {
            let config = KistConfig.parse(["fetchAllowedHosts": raw])
            XCTAssertFalse(config.fetchAllowedHosts.isEmpty,
                           "malformed policy must not become unrestricted")
            let result = try await WebFetchTool(allowedHosts: config.fetchAllowedHosts).execute(
                arguments: ["url": "https://example.com"],
                context: ToolContext(projectRoot: NSTemporaryDirectory()))
            XCTAssertFalse(result.success)
            XCTAssertTrue((result.error ?? "").contains("configured fetch host allowlist"))
        }
    }

    func testAbsentAndStringArrayFetchAllowlistShapesRemainValid() {
        XCTAssertEqual(KistConfig.parse([:]).fetchAllowedHosts, [])
        XCTAssertEqual(
            KistConfig.parse(["fetchAllowedHosts": ["docs.swift.org"]]).fetchAllowedHosts,
            ["docs.swift.org"])
    }


    func testMalformedJSONAndNonObjectRootFailClosed() async throws {
        for data in [Data(#"{"fetchAllowedHosts":["example.com"],}"#.utf8),
                     Data(#"["example.com"]"#.utf8)] {
            let config = KistConfig.parseData(data)
            XCTAssertFalse(config.fetchAllowedHosts.isEmpty)
            let result = try await WebFetchTool(allowedHosts: config.fetchAllowedHosts).execute(
                arguments: ["url": "https://example.com"],
                context: ToolContext(projectRoot: NSTemporaryDirectory()))
            XCTAssertFalse(result.success)
            XCTAssertTrue((result.error ?? "").contains("configured fetch host allowlist"))
        }
    }

    func testWriteSelectByValidationRejectsMalformedExistingConfig() {
        XCTAssertFalse(KistConfig.isValidConfigObjectData(
            Data(#"{"fetchAllowedHosts":["example.com"],}"#.utf8)))
        XCTAssertFalse(KistConfig.isValidConfigObjectData(Data(#"["example.com"]"#.utf8)))
        XCTAssertTrue(KistConfig.isValidConfigObjectData(
            Data(#"{"fetchAllowedHosts":["example.com"]}"#.utf8)))
    }
}
