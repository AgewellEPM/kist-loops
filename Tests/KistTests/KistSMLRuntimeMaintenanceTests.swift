import XCTest
import AgentCore
@testable import Kist

final class KistSMLRuntimeMaintenanceTests: XCTestCase {
    func testMaintenanceOptionsRejectAmbiguousOrIncompleteOperations() {
        for args in [
            ["--sml-store", "backup"],
            ["--sml-store", "restore"],
            ["--sml-store", "archive"],
            ["--sml-store", "delete"],
            ["--sml-store", "verify", "--sml-backup", "backup.json"],
            ["--sml-store", "verify", "--sml-runtime-serve", "source.json"],
            ["--sml-backup", "backup.json"],
            ["--sml-store", "archive", "--sml-archive-before", "2026-01-01T00:00:00Z", "--sml-archive-max", "10001"],
            ["--sml-store", "restore", "--sml-backup", "backup.json", "--sml-replace-sha256", "bad"],
        ] {
            XCTAssertFalse(KistOptions.parse(args).optionErrors.isEmpty, args.joined(separator: " "))
        }
        for args in [
            ["--sml-store", "verify"],
            ["--sml-store", "backup", "--sml-backup", "backup.json"],
            ["--sml-store", "restore", "--sml-backup", "backup.json"],
            ["--sml-store", "archive", "--sml-archive-before", "2026-01-01T00:00:00Z", "--sml-archive-max", "2"],
        ] { XCTAssertTrue(KistOptions.parse(args).optionErrors.isEmpty, args.joined(separator: " ")) }
    }

    func testMaintenanceUsesExplicitProjectAndRejectsInvalidCutoffWithoutMutation() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("sml-maint-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let runtimeURL = SMLRuntimeStore.defaultURL(projectRoot: project.path)
        let store = SMLRuntimeStore(fileURL: runtimeURL)
        try await store.save(SMLRuntimeSnapshot())
        let original = try Data(contentsOf: runtimeURL)
        let verify = try await KistRunner.performSMLRuntimeMaintenance(KistOptions.parse([
            "--sml-store", "verify", "--project", project.path
        ]))
        XCTAssertEqual(verify.liveTaskCount, 0)
        let backup = try await KistRunner.performSMLRuntimeMaintenance(KistOptions.parse([
            "--sml-store", "backup", "--sml-backup", "saved.json", "--project", project.path
        ]))
        XCTAssertEqual(backup.destinationPath, project.appendingPathComponent("saved.json").path)
        do {
            _ = try await KistRunner.performSMLRuntimeMaintenance(KistOptions.parse([
                "--sml-store", "archive", "--sml-archive-before", "yesterday", "--project", project.path
            ]))
            XCTFail("an implicit or invalid timestamp must not archive history")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: runtimeURL), original)
    }

    func testRecoveryFilesRoundTripAndNeverReplaceNewerHostConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sml-recovery-files-\(UUID().uuidString)")
        let original = directory.appendingPathComponent("original")
        let recovered = directory.appendingPathComponent("recovered")
        for path in [original, recovered] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let policyPath = ".kist/sml/policy.json"
        let policy = Data(#"{"schema_version":1,"default":"approve_always"}"#.utf8)
        let originalRoot = try ConfinedRoot(root: original.path)
        try originalRoot.createDataIfMissing(policyPath, policy, createParents: true)
        let workflow = SMLWorkflow(id: "recovery.wf", version: "1.0.0", name: "Recovery",
            source: .init(kind: .native, reference: "tests://recovery"), trigger: .init(kind: .manual),
            stateSchema: [], interface: .init(), entrypoint: "done", instructions: [.init(id: "done", op: .complete)])
        let snapshot = SMLRuntimeSnapshot(workflows: [
            SMLRuntimeSnapshot.workflowStorageKey(id: workflow.id, version: workflow.version):
                SMLRuntimeWorkflowRecord(role: "recorded-role", workflow: workflow, installedAtEpoch: 1)
        ], activeWorkflowVersions: [workflow.id: workflow.version])
        let files = try KistRunner.captureSMLRecoveryFiles(project: original, snapshot: snapshot)
        XCTAssertEqual(files[policyPath], policy)
        let sourceSetPath = try XCTUnwrap(files.keys.first { $0.hasSuffix("/source-set.json") })
        let sourceSet = try JSONDecoder().decode(KistRunner.SMLRuntimeHostSourceSet.self, from: files[sourceSetPath]!)
        XCTAssertEqual(sourceSet.sources.first?.role, "recorded-role")
        try KistRunner.restoreSMLRecoveryFiles(files, project: recovered, replacingRuntime: false)
        try KistRunner.restoreSMLRecoveryFiles(files, project: recovered, replacingRuntime: true)
        let recoveredRoot = try ConfinedRoot(root: recovered.path)
        XCTAssertEqual(try recoveredRoot.readStableOwnerOnlyData(policyPath, maxBytes: 1024, permissions: 0o600), policy)
        var altered = files
        altered[policyPath] = Data(#"{"schema_version":1,"default":"free_run"}"#.utf8)
        XCTAssertThrowsError(try KistRunner.restoreSMLRecoveryFiles(altered, project: recovered, replacingRuntime: true))
        XCTAssertEqual(try recoveredRoot.readData(policyPath), policy)
        XCTAssertThrowsError(try KistRunner.restoreSMLRecoveryFiles(["../outside": policy], project: recovered, replacingRuntime: false))
        XCTAssertThrowsError(try KistRunner.restoreSMLRecoveryFiles([".kist/sml/runtime.json": policy], project: recovered, replacingRuntime: false))
    }
}
