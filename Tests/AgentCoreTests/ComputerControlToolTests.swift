import XCTest
@testable import AgentCore

final class ComputerControlToolTests: XCTestCase {

    func testYouTubeSearchURLIsEncoded() {
        let url = ComputerControlTool.youtubeSearchURL(query: "latest hiphop 2026")
        XCTAssertEqual(url, "https://www.youtube.com/results?search_query=latest%20hiphop%202026")
    }

    func testRejectsUnsupportedActionAndBadURL() async throws {
        let tool = ComputerControlTool()
        let context = ToolContext(projectRoot: NSTemporaryDirectory())

        let badAction = try await tool.execute(arguments: ["action": "format_drive"], context: context)
        XCTAssertFalse(badAction.success)
        XCTAssertTrue((badAction.error ?? "").contains("unsupported"))

        let badURL = try await tool.execute(arguments: ["action": "open_url", "target": "file:///etc/passwd"], context: context)
        XCTAssertFalse(badURL.success)
        XCTAssertTrue((badURL.error ?? "").contains("http(s)"))
    }

    func testOpenURLUsesPlatformRunner() async throws {
        let recorder = RunnerRecorder()
        let runner: ComputerControlTool.ProcessRunner = { path, args, cwd, timeout in
            await recorder.run(path: path, args: args, cwd: cwd, timeout: timeout)
        }
        let tool = ComputerControlTool(runner: runner)
        let context = ToolContext(projectRoot: NSTemporaryDirectory())

        let result = try await tool.execute(
            arguments: ["action": "open_url", "target": "https://example.com/path?q=1"],
            context: context
        )

        XCTAssertTrue(result.success)
        let call = await recorder.snapshot().first
        #if os(macOS)
        XCTAssertEqual(call?.path, "/usr/bin/open")
        XCTAssertEqual(call?.args, ["https://example.com/path?q=1"])
        #elseif os(Linux)
        XCTAssertEqual(call?.args, ["https://example.com/path?q=1"])
        XCTAssertEqual((call?.path as NSString?)?.lastPathComponent, "xdg-open")
        #endif
    }

    #if os(macOS)
    func testOpenSafariCreatesAVisibleBrowserWindow() async throws {
        let recorder = RunnerRecorder()
        let runner: ComputerControlTool.ProcessRunner = { path, args, cwd, timeout in
            await recorder.run(path: path, args: args, cwd: cwd, timeout: timeout)
        }
        let tool = ComputerControlTool(runner: runner)
        let context = ToolContext(projectRoot: NSTemporaryDirectory())

        let result = try await tool.execute(arguments: ["action": "open_app", "target": "Safari"], context: context)

        XCTAssertTrue(result.success)
        let call = await recorder.snapshot().first
        XCTAssertEqual(call?.path, "/usr/bin/open")
        XCTAssertEqual(call?.args, ["-a", "Safari", "about:blank"])
    }

    func testOpenNonBrowserAppUsesAppNameOnly() async throws {
        let recorder = RunnerRecorder()
        let runner: ComputerControlTool.ProcessRunner = { path, args, cwd, timeout in
            await recorder.run(path: path, args: args, cwd: cwd, timeout: timeout)
        }
        let tool = ComputerControlTool(runner: runner)
        let context = ToolContext(projectRoot: NSTemporaryDirectory())

        let result = try await tool.execute(arguments: ["action": "open_app", "target": "Notes"], context: context)

        XCTAssertTrue(result.success)
        let call = await recorder.snapshot().first
        XCTAssertEqual(call?.args, ["-a", "Notes"])
    }
    #endif

    func testCleanDesktopDryRunDoesNotMoveFiles() async throws {
        let desktop = try makeTempDesktop()
        try "a".write(toFile: desktop.appendingPathComponent("a.txt").path, atomically: true, encoding: .utf8)
        try "hidden".write(toFile: desktop.appendingPathComponent(".hidden").path, atomically: true, encoding: .utf8)

        let tool = ComputerControlTool(desktopPath: desktop.path)
        let result = try await tool.execute(arguments: ["action": "clean_desktop", "dry_run": true], context: ToolContext(projectRoot: desktop.path))

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Would move 1 Desktop item"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktop.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktop.appendingPathComponent(".hidden").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: desktop.path).filter { $0.hasPrefix("Mythos Desktop Cleanup") }.count, 0)
    }

    func testCleanDesktopSanitizesDestinationLabel() async throws {
        let desktop = try makeTempDesktop()
        try "a".write(toFile: desktop.appendingPathComponent("a.txt").path, atomically: true, encoding: .utf8)

        let tool = ComputerControlTool(desktopPath: desktop.path)
        let result = try await tool.execute(
            arguments: ["action": "clean_desktop", "target": "../bad:name\nlabel", "dry_run": true],
            context: ToolContext(projectRoot: desktop.path)
        )

        XCTAssertTrue(result.success)
        let destinationName = (result.metadata["destination"]! as NSString).lastPathComponent
        XCTAssertTrue(destinationName.hasPrefix("Mythos Desktop Cleanup bad-name-label"))
        XCTAssertFalse(destinationName.contains("/"))
        XCTAssertFalse(destinationName.contains(":"))
        XCTAssertFalse(destinationName.contains("\n"))
    }

    func testCleanDesktopMovesVisibleItemsIntoCleanupFolder() async throws {
        let desktop = try makeTempDesktop()
        let file = desktop.appendingPathComponent("note.txt")
        let folder = desktop.appendingPathComponent("Work")
        try "note".write(toFile: file.path, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try "hidden".write(toFile: desktop.appendingPathComponent(".hidden").path, atomically: true, encoding: .utf8)

        let tool = ComputerControlTool(desktopPath: desktop.path)
        let result = try await tool.execute(arguments: ["action": "clean_desktop"], context: ToolContext(projectRoot: desktop.path))

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.metadata["count"], "2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktop.appendingPathComponent(".hidden").path))

        let cleanupDirs = try FileManager.default.contentsOfDirectory(atPath: desktop.path)
            .filter { $0.hasPrefix("Mythos Desktop Cleanup") }
        XCTAssertEqual(cleanupDirs.count, 1)
        let cleanup = desktop.appendingPathComponent(cleanupDirs[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanup.appendingPathComponent("note.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanup.appendingPathComponent("Work").path))
    }

    private func makeTempDesktop() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("computer-control-\(UUID().uuidString)", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        return desktop
    }
}

private actor RunnerRecorder {
    struct Call: Equatable {
        let path: String
        let args: [String]
        let cwd: String
        let timeout: Int
    }

    private var calls: [Call] = []

    func run(path: String, args: [String], cwd: String, timeout: Int) async -> ToolResult {
        calls.append(Call(path: path, args: args, cwd: cwd, timeout: timeout))
        return ToolResult(success: true, output: "opened")
    }

    func snapshot() -> [Call] { calls }
}
