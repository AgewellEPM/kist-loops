import XCTest
@testable import AgentCore

final class MoveFileToolTests: XCTestCase {
    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "move-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }

    private var ctx: ToolContext { ToolContext(projectRoot: root) }   // shell DENIED by default

    func testMoveCreatesParentsAndMovesWithoutShell() async throws {
        try "img".write(toFile: root + "/photo.png", atomically: true, encoding: .utf8)
        let r = try await MoveFileTool().execute(arguments: ["from": "photo.png", "to": "Images/photo.png"], context: ctx)
        XCTAssertTrue(r.success, r.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/photo.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/Images/photo.png"))   // parent created
    }

    func testNormalizedSamePathIsANoOpWithChangedFalse() async throws {
        try "same".write(toFile: root + "/same.txt", atomically: true, encoding: .utf8)
        let r = try await MoveFileTool().execute(
            arguments: ["from": root + "/same.txt", "to": "./same.txt"], context: ctx)
        XCTAssertTrue(r.success, r.output)
        XCTAssertEqual(r.metadata["changed"], "false")
        XCTAssertEqual(try String(contentsOfFile: root + "/same.txt", encoding: .utf8), "same")
    }

    func testNormalizedSameMissingPathDoesNotClaimSuccess() async {
        do {
            _ = try await MoveFileTool().execute(
                arguments: ["from": root + "/missing.txt", "to": "./missing.txt"], context: ctx)
            XCTFail("a same-path spelling must not make a missing source successful")
        } catch {
            XCTAssertEqual(error as? ToolError, .notFound("\(root!)/missing.txt"))
        }
    }

    func testMakeDir() async throws {
        let r = try await MakeDirTool().execute(arguments: ["path": "a/b/c"], context: ctx)
        XCTAssertTrue(r.success)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/a/b/c", isDirectory: &isDir) && isDir.boolValue)
    }

    func testMoveRefusesEscapingDestination() async throws {
        try "x".write(toFile: root + "/f.txt", atomically: true, encoding: .utf8)
        do {
            _ = try await MoveFileTool().execute(arguments: ["from": "f.txt", "to": "../escape.txt"], context: ctx)
            XCTFail("escaping move should throw")
        } catch { /* expected: pathEscape */ }
        XCTAssertFalse(FileManager.default.fileExists(atPath: NSString(string: root + "/../escape.txt").standardizingPath))
    }

    func testClassifiedMutatingInProjectDangerousEscaping() {
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "move_file", args: ["from": "a.png", "to": "Images/a.png"], projectRoot: root), .mutating)
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "move_file", args: ["from": "a.png", "to": "/etc/evil"], projectRoot: root), .dangerous)
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "make_dir", args: ["path": "x"], projectRoot: root), .mutating)
    }

    // The capability-denial steer fires on shell-off / unsupported / unknown, and points at move_file.
    func testCapabilityDenialSteer() {
        let s = HeadlessAgentLoop.capabilityDenialSteer(error: "shell command denied: shell is disabled in this context",
                                                        tools: .headless(), shellEnabled: false)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("move_file"))
        XCTAssertFalse(s!.contains("run_command"))   // dead end not offered when shell is off
        XCTAssertNil(HeadlessAgentLoop.capabilityDenialSteer(error: "tests failed: 3 assertions",
                                                             tools: .headless(), shellEnabled: false))  // ordinary failure → no steer
        XCTAssertNotNil(HeadlessAgentLoop.capabilityDenialSteer(error: "unsupported computer_control action: move_file",
                                                                tools: .headless(), shellEnabled: true))
    }
}
