import XCTest
@testable import AgentCore

/// A clean non-zero exit that produced output carries that output IN its error string (0.17.63).
/// The plan executor's replan steering and the sealed verification failure relay only `error`, so
/// a planner that saw a bare "exit code 1" regenerated already-correct files instead of fixing its
/// test runner (live 2026-09-27: `python3 -m pytest` said "No module named pytest"; nobody saw it).
final class RunCommandOutputTailTests: XCTestCase {
    func testOutputTailFlattensNewlinesAndBoundsBytes() {
        XCTAssertEqual(RunCommandTool.outputTail("a\nb\nc"), "a ⏎ b ⏎ c")
        let long = String(repeating: "x", count: 2_000) + "END"
        let tail = RunCommandTool.outputTail(long, maxBytes: 50)
        XCTAssertTrue(tail.hasPrefix("…"))
        XCTAssertTrue(tail.hasSuffix("END"))
        XCTAssertLessThanOrEqual(tail.utf8.count, 50 + "…".utf8.count)
        XCTAssertEqual(RunCommandTool.outputTail(""), "")
    }

    func testCleanNonZeroExitWithOutputCarriesTheTailInItsError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-command-tail-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let registry = ToolRegistry([RunCommandTool()])
        let context = ToolContext(
            projectRoot: root,
            shell: ShellPolicy(enabled: true, autoApprove: true, allow: ["ls"]))
        let result = await registry.execute(
            name: "run_command",
            arguments: ["executable": "/bin/ls", "args": ["/definitely/not/a/real/path-\(UUID().uuidString)"]],
            context: context)
        XCTAssertFalse(result.success)
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.contains("allowed exit codes"), error)
        XCTAssertTrue(error.contains("output tail:"), error)
        XCTAssertTrue(error.lowercased().contains("no such file"), "the diagnosis travels with the error: \(error)")
    }
}
