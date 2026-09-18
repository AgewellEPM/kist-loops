import Foundation
import XCTest
@testable import AgentCore
@testable import Kist

final class KistSMLRuntimeInteractiveREPLTests: XCTestCase {
    private struct CLIResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private var projectRoot: URL!

    private var kistExecutableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/kist")
    }

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: kistExecutableURL.path) else {
            throw XCTSkip("kist executable is not present in the SwiftPM products directory")
        }
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-interactive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        projectRoot = URL(fileURLWithPath: raw.resolvingSymlinksInPath().path, isDirectory: true)
        try writeWorkflow()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectRoot)
    }

    func testInteractiveREPLConsumesScriptedStdinAndExitsCleanlyOnEOF() throws {
        let result = try runInteractive(input: "help\n")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(result.stdout.contains("sml workflow repl · interactive.listing"))
        XCTAssertTrue(result.stdout.contains("ephemeral sandbox — no drivers"))
        XCTAssertTrue(result.stdout.contains("commands:"))
        XCTAssertTrue(result.stdout.hasSuffix("\n"), "EOF should leave the prompt on a clean line")
    }

    func testInteractiveREPLRejectsAnUnboundedInputLine() throws {
        let oversized = String(
            repeating: "x",
            count: SMLRuntimeBoundedLineReader.maximumLineBytes + 1
        ) + "\n"
        let result = try runInteractive(input: oversized)

        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("SML REPL input exceeds the 65536-byte line limit"))
    }

    func testDurableInteractiveREPLApprovesAndDispatchesThroughTheSharedStack() async throws {
        try writeDurableConfiguration()
        let result = try runInteractive(
            input: """
            start TASK-INTERACTIVE
            approve TASK-INTERACTIVE {"task_revision":1}
            watch
            receipts
            exit

            """,
            additionalArguments: ["--sml-runtime-durable"]
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertFalse(result.stderr.contains("error:"), result.stderr)
        XCTAssertTrue(result.stdout.contains("[1 pending]"), result.stdout)
        XCTAssertTrue(
            result.stdout.contains("· dispatched capability for TASK-INTERACTIVE"),
            result.stdout
        )
        XCTAssertTrue(result.stdout.contains("completed"), result.stdout)
        XCTAssertTrue(result.stdout.contains("Leaving interactive.listing."), result.stdout)

        let store = SMLRuntimeStore(
            fileURL: projectRoot.appendingPathComponent(".kist/sml/runtime.json")
        )
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.tasks["TASK-INTERACTIVE"]?.status, .completed)

        let auditURL = projectRoot.appendingPathComponent(".kist/audit/tools.jsonl")
        let auditLines = try String(contentsOf: auditURL, encoding: .utf8)
            .split(separator: "\n")
        let entries = try auditLines.map {
            try JSONDecoder().decode(AuditEntry.self, from: Data($0.utf8))
        }
        XCTAssertEqual(entries.map(\.tool), ["list_files"])
        XCTAssertEqual(entries.map(\.outcome), ["ok"])

        let environment = try await SMLRuntimeDurableHostEnvironment.acquire(
            projectRoot: projectRoot.path
        )
        environment.lock.release()
    }

    func testBoundedReaderRejectsInvalidUTF8() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data([0xFF, 0x0A]))
        try pipe.fileHandleForWriting.close()
        let reader = SMLRuntimeBoundedLineReader(input: pipe.fileHandleForReading)
        XCTAssertThrowsError(try reader.readLine()) { error in
            XCTAssertEqual(
                String(describing: error),
                "SML REPL input must be valid UTF-8"
            )
        }
    }

    private func runInteractive(
        input: String,
        additionalArguments: [String] = []
    ) throws -> CLIResult {
        let process = Process()
        process.executableURL = kistExecutableURL
        process.currentDirectoryURL = projectRoot
        process.arguments = [
            "--sml-runtime-repl", "workflow.json",
            "--project", projectRoot.path,
        ] + additionalArguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KIST_ACTIVE")
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        guard exited.wait(timeout: .now() + .seconds(10)) == .success else {
            throw InteractiveREPLTestError.processTimeout
        }
        return CLIResult(
            exitCode: process.terminationStatus,
            stdout: String(
                decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ),
            stderr: String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            )
        )
    }

    private func writeWorkflow() throws {
        try """
        {
          "ir_version": 1,
          "id": "interactive.listing",
          "version": "1.0.0",
          "name": "Interactive listing",
          "source": {"kind": "native", "reference": "tests://interactive"},
          "trigger": {"kind": "manual"},
          "state_schema": [
            {"name": "listing", "type": "string", "required": false}
          ],
          "interface": {"output_fields": ["listing"]},
          "entrypoint": "list",
          "instructions": [
            {
              "id": "list",
              "op": "CALL_TOOL",
              "capability": "list_files",
              "arguments": {"path": ".", "output_field": "listing"},
              "next": "emit"
            },
            {"id": "emit", "op": "EMIT_RECEIPT", "receipt_fields": ["listing"]}
          ]
        }
        """.write(
            to: projectRoot.appendingPathComponent("workflow.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeDurableConfiguration() throws {
        let directory = projectRoot.appendingPathComponent(".kist/sml", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let authorityURL = directory.appendingPathComponent("authority.json")
        try """
        {
          "schema_version": 1,
          "actors": [
            {
              "id": "sml-runtime-exporter",
              "roles": ["workflow-agent"],
              "operations": [
                "workflow.run", "workflow.inspect", "task.watch", "receipts.list",
                "task.approve_request", "task.refuse_request",
                "task.claim_capability", "task.record_step"
              ],
              "approval_authorities": ["host-operator"]
            }
          ]
        }
        """.write(to: authorityURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: authorityURL.path
        )
        let catalogURL = directory.appendingPathComponent("catalog.json")
        try """
        {
          "schema_version": 1,
          "tool_capabilities": ["list_files"],
          "approval_authorities": ["host-operator"]
        }
        """.write(
            to: catalogURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: catalogURL.path
        )
    }
}

private enum InteractiveREPLTestError: Error {
    case processTimeout
}
