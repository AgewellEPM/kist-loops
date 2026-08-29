import XCTest
@testable import AgentCore

/// The retired Cortex compatibility tool must fail closed around raw Markdown.
final class CortexToolTests: XCTestCase {

    private var home: String!
    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "cortex-tool-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        setenv("XDG_DATA_HOME", home, 1)
    }
    override func tearDownWithError() throws {
        unsetenv("XDG_DATA_HOME")
        if let home { try? FileManager.default.removeItem(atPath: home) }
    }

    private func ctx(_ project: String = "myproj") -> ToolContext {
        ToolContext(projectRoot: NSTemporaryDirectory() + project, shell: .denied)
    }
    func testEveryLegacyActionFailsClosedWithoutWritingOrEchoingInput() async throws {
        let secret = "sk-ant-abcdefghijklmnopqrstuvwxyz0123456789"
        for action in ["remember", "project", "journal", "recall"] {
            let result = try await CortexTool().execute(
                arguments: ["action": action, "text": "must not persist \(secret)"],
                context: ctx("kist"))
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.contains("raw audit-only") == true)
            XCTAssertFalse(result.error?.contains(secret) == true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/cortex"))
    }

    func testRecallCannotSurfacePreexistingRawMarkdown() async throws {
        let directory = home + "/cortex"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        try "RAW MARKER MUST NOT ENTER MODEL OUTPUT".write(
            toFile: directory + "/preferences.md", atomically: true, encoding: .utf8)

        let result = try await CortexTool().execute(
            arguments: ["action": "recall"], context: ctx())

        XCTAssertFalse(result.success)
        XCTAssertFalse(result.error?.contains("RAW MARKER") == true)
        XCTAssertEqual(try String(
            contentsOfFile: directory + "/preferences.md", encoding: .utf8),
                       "RAW MARKER MUST NOT ENTER MODEL OUTPUT")
    }

    func testUnknownActionFails() async throws {
        let r = try await CortexTool().execute(arguments: ["action": "forget"], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error?.contains("unknown action"), true)
    }

    func testTodayIsIsoDate() {
        let d = CortexTool.today()
        XCTAssertNotNil(try? NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$").firstMatch(
            in: d, range: NSRange(d.startIndex..., in: d)))
    }
}
