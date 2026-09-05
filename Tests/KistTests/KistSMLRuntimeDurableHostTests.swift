import XCTest
@testable import Kist
@testable import AgentCore

/// Pins the durable host contract end to end, in-process, against a fixture project root:
/// task state survives across separate host launches through `.kist/sml/runtime.json` (with the
/// snapshot's tasks adopted into the new session lease), the exclusive host lock refuses a second
/// concurrent mutating host and is released on failure paths, and the durable mode fails closed
/// without the human-owned authority/catalog files — while the ephemeral export mode keeps its
/// rubber-stamp behavior and never touches the project store. One assertion per contract site so
/// a regression names itself.
final class KistSMLRuntimeDurableHostTests: XCTestCase {
    private var projectRoot: URL!

    /// Runs the REAL internal REPL-transcript surface (script file and all) and returns its
    /// pretty JSON, so assertions cover exactly what the CLI would print.
    private func durableREPLTranscriptJSON(
        sourcePath: String,
        mode: SMLRuntimeHostMode,
        lines: [String]
    ) async throws -> String {
        let scriptURL = projectRoot.appendingPathComponent("script-\(UUID().uuidString).repl")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        let transcript = try await KistRunner.makeSMLRuntimeHostREPLTranscript(
            sourcePath: sourcePath,
            projectRoot: projectRoot.path,
            mode: mode,
            scriptPath: scriptURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(transcript), as: UTF8.self)
    }

    private func durableREPLCommandJSON(
        sourcePath: String,
        mode: SMLRuntimeHostMode,
        line: String
    ) async throws -> String {
        let command = try await KistRunner.makeSMLRuntimeHostREPLCommand(
            sourcePath: sourcePath,
            projectRoot: projectRoot.path,
            mode: mode,
            line: line
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(command), as: UTF8.self)
    }

    override func setUpWithError() throws {
        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-durable-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        // Canonicalize through symlinks (/var -> /private/var) so store paths compare cleanly.
        projectRoot = URL(
            fileURLWithPath: try XCTUnwrap(projectRoot.resolvingSymlinksInPath().path as String?),
            isDirectory: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectRoot)
    }

    private var workflowURL: URL { projectRoot.appendingPathComponent("wf.json") }

    private func writeFixtureWorkflow() throws {
        let workflow = """
        {
          "ir_version": 1,
          "id": "p0.durable",
          "version": "1.0.0",
          "name": "P0 durable fixture",
          "source": {"kind": "native", "reference": "tests://p0-durable"},
          "trigger": {"kind": "manual"},
          "state_schema": [],
          "entrypoint": "done",
          "instructions": [{"id": "done", "op": "COMPLETE"}]
        }
        """
        try workflow.write(to: workflowURL, atomically: true, encoding: .utf8)
    }

    private func writeAuthorityFile() throws {
        let smlDir = projectRoot.appendingPathComponent(".kist/sml", isDirectory: true)
        try FileManager.default.createDirectory(at: smlDir, withIntermediateDirectories: true)
        let authority = """
        {
          "schema_version": 1,
          "actors": [
            {
              "id": "sml-runtime-exporter",
              "roles": ["workflow-agent"],
              "operations": ["workflow.run", "task.watch", "receipts.list", "workflow.inspect"]
            }
          ]
        }
        """
        let url = smlDir.appendingPathComponent("authority.json")
        try authority.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private func writeCatalogFile() throws {
        let smlDir = projectRoot.appendingPathComponent(".kist/sml", isDirectory: true)
        try FileManager.default.createDirectory(at: smlDir, withIntermediateDirectories: true)
        let catalogURL = smlDir.appendingPathComponent("catalog.json")
        try """
        {"schema_version": 1}
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

    private func writeAllFixtures() throws {
        try writeFixtureWorkflow()
        try writeAuthorityFile()
        try writeCatalogFile()
    }

    // MARK: - Cross-launch persistence

    func testTaskStateSurvivesAcrossSeparateDurableHostLaunches() async throws {
        try writeAllFixtures()

        // Launch 1: start a task; the trivial workflow completes internally.
        let transcript = try await durableREPLTranscriptJSON(
            sourcePath: workflowURL.path,
            mode: .durable,
            lines: ["start TASK-P0-DURABLE {}"]
        )
        XCTAssertTrue(
            transcript.contains("TASK-P0-DURABLE"),
            "launch 1 must create the task: \(transcript)"
        )

        let storeURL = projectRoot.appendingPathComponent(".kist/sml/runtime.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storeURL.path),
            "durable mode must persist the store at <root>/.kist/sml/runtime.json"
        )

        // Launch 2: a brand-new host (new lease) must see the SAME task via snapshot adoption.
        let watch = try await durableREPLCommandJSON(
            sourcePath: workflowURL.path,
            mode: .durable,
            line: "watch TASK-P0-DURABLE"
        )
        XCTAssertTrue(
            watch.contains("TASK-P0-DURABLE") && watch.contains("completed"),
            "launch 2 must observe launch 1's completed task from the persistent store: \(watch)"
        )
    }

    // MARK: - Ephemeral mode stays rubber-stamp and store-free

    func testEphemeralExportModeNeverTouchesTheProjectStore() async throws {
        try writeFixtureWorkflow()
        // No authority.json, no catalog.json: the ephemeral path must still work (its catalog is
        // derived from the workflow and its authority is the rubber stamp) and must not create
        // the durable store.
        let transcript = try await durableREPLTranscriptJSON(
            sourcePath: workflowURL.path,
            mode: .ephemeralExport,
            lines: ["start TASK-EPHEMERAL {}"]
        )
        XCTAssertTrue(transcript.contains("TASK-EPHEMERAL"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: projectRoot.appendingPathComponent(".kist/sml/runtime.json").path
            ),
            "ephemeral export must never write the project store"
        )
    }

    // MARK: - Fail-closed configuration gates

    func testDurableModeFailsClosedWithoutAuthorityFile() async throws {
        try writeFixtureWorkflow()
        try writeCatalogFile()
        do {
            _ = try await durableREPLCommandJSON(
                sourcePath: workflowURL.path,
                mode: .durable,
                line: "describe"
        )
            XCTFail("durable mode must refuse to launch without authority.json")
        } catch let error as SMLRuntimeAuthorityConfig.LoadError {
            guard case .missing = error else {
                return XCTFail("expected .missing, got \(error)")
            }
        }
    }

    func testDurableModeFailsClosedWithoutCatalogFile() async throws {
        try writeFixtureWorkflow()
        try writeAuthorityFile()
        do {
            _ = try await durableREPLCommandJSON(
                sourcePath: workflowURL.path,
                mode: .durable,
                line: "describe"
        )
            XCTFail("durable mode must refuse to launch without catalog.json")
        } catch let error as SMLRuntimeHostCatalogFile.LoadError {
            guard case .missing = error else {
                return XCTFail("expected .missing, got \(error)")
            }
        }
    }

    func testHostLockIsReleasedAfterAFailedLaunchSoTheNextOneSucceeds() async throws {
        try writeFixtureWorkflow()
        try writeCatalogFile()
        // First attempt fails on missing authority; the lock taken before config load must be
        // released, or every subsequent durable launch would report a phantom concurrent host.
        _ = try? await durableREPLCommandJSON(
            sourcePath: workflowURL.path,
            mode: .durable,
            line: "describe"
        )
        try writeAuthorityFile()
        let described = try await durableREPLCommandJSON(
            sourcePath: workflowURL.path,
            mode: .durable,
            line: "describe"
        )
        XCTAssertTrue(described.contains("p0.durable"),
                      "lock must not leak from the failed launch: \(described)")
    }

    // MARK: - Exclusive host lock

    func testSecondConcurrentMutatingHostIsRefused() async throws {
        try writeAllFixtures()
        let environment = try await SMLRuntimeDurableHostEnvironment.acquire(
            projectRoot: projectRoot.path
        )
        defer { environment.lock.release() }
        do {
            let second = try await SMLRuntimeDurableHostEnvironment.acquire(
                projectRoot: projectRoot.path
            )
            second.lock.release()
            XCTFail("a second mutating host must be refused while the lock is held")
        } catch let error as SMLRuntimeDurableHostError {
            guard case .lockUnavailable = error else {
                return XCTFail("expected .lockUnavailable, got \(error)")
            }
        }
    }

    func testReleasedLockAdmitsTheNextHost() async throws {
        try writeAllFixtures()
        let first = try await SMLRuntimeDurableHostEnvironment.acquire(projectRoot: projectRoot.path)
        first.lock.release()
        let second = try await SMLRuntimeDurableHostEnvironment.acquire(projectRoot: projectRoot.path)
        second.lock.release()
    }
}
