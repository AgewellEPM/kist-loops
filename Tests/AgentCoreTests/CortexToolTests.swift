import XCTest
@testable import AgentCore

/// The agent-writable Cortex tool: remember (preferences), project facts, journal, recall.
/// Writes go under XDG_DATA_HOME so the real ~/.kist/cortex is never touched.
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
    private func read(_ rel: String) -> String? {
        try? String(contentsOfFile: home + "/cortex/" + rel, encoding: .utf8)
    }

    func testRememberWritesPreference() async throws {
        let r = try await CortexTool().execute(
            arguments: ["action": "remember", "text": "Luke wants each increment on its own branch"],
            context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(read("preferences.md")?.contains("own branch"), true, "preference must persist")
    }

    func testProjectFactWritesUnderProjectName() async throws {
        let r = try await CortexTool().execute(
            arguments: ["action": "project", "text": "Swift/SPM; MCP auto-loads from ~/.mcp.json"],
            context: ctx("kist"))
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["project"], "kist")
        XCTAssertEqual(read("projects/kist.md")?.contains("MCP auto-loads"), true)
    }

    func testProjectOverrideName() async throws {
        _ = try await CortexTool().execute(
            arguments: ["action": "project", "text": "fact", "project": "OtherApp"],
            context: ctx("kist"))
        XCTAssertEqual(read("projects/OtherApp.md")?.contains("fact"), true)
    }

    func testJournalWritesDatedEntry() async throws {
        let r = try await CortexTool().execute(
            arguments: ["action": "journal", "text": "wired agent-lsp + symbols tool"], context: ctx())
        XCTAssertTrue(r.success)
        let dir = home + "/cortex/journal"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        XCTAssertEqual(files.count, 1, "one dated journal file")
        XCTAssertEqual(files.first?.hasSuffix(".md"), true)
        let body = read("journal/" + (files.first ?? ""))
        XCTAssertEqual(body?.contains("wired agent-lsp"), true)
    }

    func testRecallReturnsWhatWasLearned() async throws {
        _ = try await CortexTool().execute(arguments: ["action": "remember", "text": "prefers adversarial review gates"], context: ctx())
        let r = try await CortexTool().execute(arguments: ["action": "recall"], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.output.contains("adversarial review gates"), true, "recall surfaces learned preferences")
    }

    func testToolResponseRedactsSecrets() async throws {
        // DeepSeek HIGH: the tool RESULT (which enters the transcript) must not echo a secret,
        // even though it's already redacted on disk.
        let secret = "sk-ant-abcdefghijklmnopqrstuvwxyz0123456789"
        let r = try await CortexTool().execute(arguments: ["action": "remember", "text": "key \(secret)"], context: ctx())
        XCTAssertFalse(r.output.contains(secret), "remember response must not echo the secret")
        let p = try await CortexTool().execute(arguments: ["action": "project", "text": "aws \(secret)"], context: ctx())
        XCTAssertFalse(p.output.contains(secret), "project response must not echo the secret")
        let j = try await CortexTool().execute(arguments: ["action": "journal", "text": "used \(secret)"], context: ctx())
        XCTAssertFalse(j.output.contains(secret), "journal response must not echo the secret")
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
