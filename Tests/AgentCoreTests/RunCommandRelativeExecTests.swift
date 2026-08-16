import XCTest
@testable import AgentCore

/// Regression pins for the 2026-08-06 dogfood find: the agent compiled a COBOL binary in the
/// project root, then run_command rejected `./payroll_report` as "not found or not executable"
/// — a false message that sent the model into a dyld goose chase and burned the whole
/// iteration budget. Relative-with-slash executables must resolve against the CONFINED cwd
/// (this adds no capability: the same binary was always reachable by absolute path, and the
/// deny gate fires on the resolved path).
///
/// Structured execution resolves relative paths against cwd. Raw command strings are not silently
/// tokenized into argv; callers must use the structured form or explicitly request shell mode.
final class RunCommandRelativeExecTests: XCTestCase {
    private var root: String = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "run-cmd-rel-exec-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // A tiny executable "built artifact" in the project root, like the compiled COBOL app.
        let script = "#!/bin/sh\necho built-artifact-ran\n"
        try script.write(toFile: root + "/artifact", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/artifact")
        // And one in a subdirectory, for the `build/tool` shape.
        try FileManager.default.createDirectory(atPath: root + "/build", withIntermediateDirectories: true)
        try script.write(toFile: root + "/build/tool", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/build/tool")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func ctx() -> ToolContext { ToolContext(projectRoot: root, shell: ShellPolicy(enabled: true, autoApprove: true)) }
    private func msg(_ r: ToolResult) -> String { r.output + " " + (r.error ?? "") }

    // MARK: resolver unit pins

    func testResolverAcceptsDotSlashAgainstCwd() {
        let resolved = RunCommandTool.resolveExecutable("./artifact", env: [:], cwd: root)
        XCTAssertNotNil(resolved, "./name must resolve against the provided cwd")
    }

    func testResolverAcceptsSubdirRelativeAgainstCwd() {
        let resolved = RunCommandTool.resolveExecutable("build/tool", env: [:], cwd: root)
        XCTAssertNotNil(resolved, "subdir/name must resolve against the provided cwd")
    }

    func testResolverStillRejectsRelativeWithoutCwd() {
        XCTAssertNil(RunCommandTool.resolveExecutable("./artifact", env: [:]),
                     "no cwd → relative-with-slash stays rejected (bare/PATH behavior unchanged)")
    }

    func testResolverRejectsMissingRelative() {
        XCTAssertNil(RunCommandTool.resolveExecutable("./does-not-exist", env: [:], cwd: root))
    }

    // MARK: end-to-end site 1 — structured `executable` mode

    func testStructuredModeRunsDotSlashExecutable() async throws {
        let r = try await RunCommandTool().execute(
            arguments: ["executable": "./artifact"], context: ctx())
        XCTAssertTrue(r.success, msg(r))
        XCTAssertTrue(r.output.contains("built-artifact-ran"), msg(r))
    }

    // MARK: raw command is not silently promoted

    func testRawCommandWithoutExplicitShellIsRejected() async throws {
        let r = try await RunCommandTool().execute(
            arguments: ["command": "./artifact"], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue(msg(r).contains("shell:true"), msg(r))
    }

    // MARK: the relative path honors the tool call's `cwd` argument, not just the root

    func testRelativeResolvesAgainstToolCallCwd() async throws {
        let r = try await RunCommandTool().execute(
            arguments: ["executable": "./tool", "cwd": "build"], context: ctx())
        XCTAssertTrue(r.success, msg(r))
        XCTAssertTrue(r.output.contains("built-artifact-ran"), msg(r))
    }
}
