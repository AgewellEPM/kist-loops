import XCTest
import Foundation
@testable import AgentCore

/// Parity gaps vs Claude Code, closed: edit_file replace_all + run_command background jobs (poll/kill).
final class GapParityTests: XCTestCase {
    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "gap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }
    private func ctx() -> ToolContext { ToolContext(projectRoot: root, shell: ShellPolicy(enabled: true, autoApprove: true)) }
    private func msg(_ r: ToolResult) -> String { r.output + " " + (r.error ?? "") }

    // MARK: edit_file replace_all

    func testEditFileUniqueByDefaultRejectsMultiMatch() async throws {
        let path = root + "/a.txt"
        try "x foo x foo x".write(toFile: path, atomically: true, encoding: .utf8)
        let r = try await EditFileTool().execute(arguments: ["path": "a.txt", "old_text": "foo", "new_text": "bar"], context: ctx())
        XCTAssertFalse(r.success, "non-unique match must fail without replace_all")
        XCTAssertTrue(msg(r).contains("replace_all"), "error should point to replace_all")
    }

    func testEditFileReplaceAllReplacesEvery() async throws {
        let path = root + "/a.txt"
        try "foo foo foo".write(toFile: path, atomically: true, encoding: .utf8)
        let r = try await EditFileTool().execute(arguments: ["path": "a.txt", "old_text": "foo", "new_text": "bar", "replace_all": true], context: ctx())
        XCTAssertTrue(r.success, r.output)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "bar bar bar")
        XCTAssertEqual(r.metadata["occurrences"], "3")
    }

    // MARK: background jobs (run_command background:true + job tool)

    func testBackgroundJobStreamsPollsAndKills() async throws {
        // Core mechanism (store directly, no shell gating): a loop that prints incrementally.
        // owner MUST match the projectRoot the job tool will query with (production: RunCommandTool
        // and ManageJobsTool both use context.projectRoot) — jobs are owner-scoped.
        guard let id = BackgroundJobStore.shared.start(
            launchPath: "/bin/sh",
            args: ["-c", "for i in 1 2 3 4 5; do echo line$i; sleep 0.3; done"],
            cwd: root, env: ["PATH": "/usr/bin:/bin"], command: "loop", owner: root) else {
            return XCTFail("job did not start")
        }
        // Poll incremental output via the job tool until we see the first line (bounded).
        var seen = ""
        for _ in 0..<40 {
            let out = try await ManageJobsTool().execute(arguments: ["action": "output", "id": id], context: ctx())
            seen += out.output
            if seen.contains("line1") { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertTrue(seen.contains("line1"), "should stream incremental output; saw: \(seen.prefix(120))")
        // list shows it; kill stops it.
        let list = try await ManageJobsTool().execute(arguments: ["action": "list"], context: ctx())
        XCTAssertTrue(list.output.contains(id))
        let kill = try await ManageJobsTool().execute(arguments: ["action": "kill", "id": id], context: ctx())
        XCTAssertTrue(kill.success, kill.output)
    }

    func testRunCommandBackgroundReturnsJobId() async throws {
        // Wiring: run_command(background:true) in executable mode returns a job id immediately.
        let r = try await RunCommandTool().execute(arguments: [
            "executable": "/bin/sh", "args": ["-c", "sleep 1"], "background": true,
        ], context: ctx())
        XCTAssertTrue(r.success, msg(r))
        XCTAssertNotNil(r.metadata["job_id"], "background run must return a job id")
        if let id = r.metadata["job_id"] { _ = BackgroundJobStore.shared.kill(id) }
    }

    func testJobUnknownIdFailsGracefully() async throws {
        let r = try await ManageJobsTool().execute(arguments: ["action": "output", "id": "job_999"], context: ctx())
        XCTAssertFalse(r.success)
    }

    // MARK: notebook_edit (.ipynb)

    func testNotebookReplaceInsertDelete() async throws {
        let nbPath = root + "/nb.ipynb"
        let nb = #"{"cells":[{"cell_type":"code","source":["print(1)"],"metadata":{}}],"metadata":{},"nbformat":4,"nbformat_minor":5}"#
        try nb.write(toFile: nbPath, atomically: true, encoding: .utf8)
        let tool = NotebookEditTool()

        // replace cell 0
        var r = try await tool.execute(arguments: ["path": "nb.ipynb", "cell_number": 0, "new_source": "print(42)"], context: ctx())
        XCTAssertTrue(r.success, msg(r))
        XCTAssertTrue(try String(contentsOfFile: nbPath, encoding: .utf8).contains("print(42)"))

        // insert a markdown cell at top
        r = try await tool.execute(arguments: ["path": "nb.ipynb", "cell_number": 0, "new_source": "# Title", "cell_type": "markdown", "edit_mode": "insert"], context: ctx())
        XCTAssertTrue(r.success, msg(r))
        XCTAssertEqual(r.metadata["cells"], "2")

        // delete cell 0
        r = try await tool.execute(arguments: ["path": "nb.ipynb", "cell_number": 0, "edit_mode": "delete"], context: ctx())
        XCTAssertTrue(r.success, msg(r))
        XCTAssertEqual(r.metadata["cells"], "1")

        // non-notebook path rejected
        r = try await tool.execute(arguments: ["path": "nb.txt", "cell_number": 0, "new_source": "x"], context: ctx())
        XCTAssertFalse(r.success)
    }
}
