import XCTest
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class SMLRuntimeMaintenanceTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let store: SMLRuntimeStore
        let runtime: SMLRuntime
        let workflow: SMLWorkflow
        let gateway: SMLCommandGateway
    }

    private func fixture(pending: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sml-maintenance-" + UUID().uuidString)
        let store = SMLRuntimeStore(fileURL: directory.appendingPathComponent("runtime.json"), clock: { 1_000 })
        let runtime = SMLRuntime(store: store, clock: { 1_000 })
        let workflow = SMLWorkflow(id: "maintenance.workflow", version: "1.0.0", name: "Maintenance",
            source: .init(kind: .native, reference: "tests://maintenance"), trigger: .init(kind: .manual),
            stateSchema: [], entrypoint: pending ? "work" : "done",
            instructions: pending ? [.init(id: "work", op: .callTool, capability: "fake.step", next: "done"),
                .init(id: "done", op: .emitReceipt, receiptFields: ["task", "status"])] : [.init(id: "done", op: .emitReceipt, receiptFields: ["task", "status"])])
        let admitted = try SMLWorkflowAdmission.admitForExecution(SMLWorkflowValidator.requireValidForImport(workflow),
            catalog: SMLExecutionAdmissionCatalog(toolCapabilities: ["fake.step"]))
        _ = try await runtime.installWorkflow(admitted, role: "operator-role")
        return Fixture(directory: directory, store: store, runtime: runtime, workflow: workflow,
            gateway: SMLCommandGateway(runtime: runtime, replayGuard: store))
    }

    private func submit(_ f: Fixture, id: String = "TASK-ONE", op: String = SMLRuntimeCommandOperation.workflowRun,
        arguments: SMLObject? = nil) async throws -> SMLCommandResult {
        let command = SMLCommandEnvelope(actor: "operator.luke", role: "operator-role", task: id,
            op: op, arguments: arguments ?? ["workflow_id": .string(f.workflow.id)], issuedAtEpoch: 1_000)
        return try await f.gateway.submit(command, authority: SMLCommandAuthority(authenticatedActor: command.actor,
            leaseID: "maintenance-test", roles: [command.role], tasks: [id], operations: [op], scope: [:]), nowEpoch: 1_000)
    }

    func testArchivePreservesNormalWatchReceiptsAndRejectsTaskIDReuse() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        let before = try await f.store.load()
        let report = try await f.store.archiveTerminalTasks(updatedBeforeEpoch: 1_001)
        XCTAssertEqual(report.liveTaskCount, 0)
        XCTAssertEqual(report.archivedTaskCount, 1)
        let compacted = try await f.store.load()
        XCTAssertTrue(compacted.tasks.isEmpty)
        XCTAssertTrue(compacted.receipts.isEmpty)
        let archive = try await f.store.archivedTask(id: "TASK-ONE")
        XCTAssertEqual(archive?.task, before.tasks["TASK-ONE"])
        XCTAssertEqual(Set(archive?.receipts.map(\.id) ?? []), Set(before.receipts.keys))
        let watched = try await submit(f, op: SMLRuntimeCommandOperation.taskWatch, arguments: [:])
        XCTAssertEqual(watched.task?.status, .completed)
        let receipts = try await submit(f, op: SMLRuntimeCommandOperation.receiptsList, arguments: [:])
        XCTAssertEqual(receipts.receipts.count, before.receipts.count)
        do { _ = try await submit(f); XCTFail("archived identity must never become a new task") }
        catch let error as SMLRuntimeError { XCTAssertEqual(error, .taskAlreadyExists("TASK-ONE")) }
    }

    func testArchiveNeverSelectsUnfinishedTasksAndHonorsCutoffAndBatchLimit() async throws {
        let f = try await fixture(pending: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        let before = try await f.store.load()
        let report = try await f.store.archiveTerminalTasks(updatedBeforeEpoch: 2_000)
        XCTAssertEqual(report.liveTaskCount, 1)
        XCTAssertEqual(report.archivedTaskCount, 0)
        let unchanged = try await f.store.load()
        XCTAssertEqual(unchanged, before)
        let completed = try await fixture()
        defer { try? FileManager.default.removeItem(at: completed.directory) }
        for i in 0..<5 { _ = try await submit(completed, id: "TASK-\(i)") }
        let noSelection = try await completed.store.archiveTerminalTasks(updatedBeforeEpoch: 1_000)
        XCTAssertEqual(noSelection.archivedTaskCount, 0)
        let bounded = try await completed.store.archiveTerminalTasks(updatedBeforeEpoch: 1_001, maximumTasks: 2)
        XCTAssertEqual(bounded.archivedTaskCount, 2)
        XCTAssertEqual(bounded.liveTaskCount, 3)
    }

    func testBackupRestoreRoundTripPreservesArchiveAndReceipts() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        for i in 0..<9 { _ = try await submit(f, id: "TASK-\(i)") }
        _ = try await f.store.archiveTerminalTasks(updatedBeforeEpoch: 1_001, maximumTasks: 7)
        let backup = f.directory.appendingPathComponent("backup.json")
        let originalReport = try await f.store.backup(to: backup)
        let restored = SMLRuntimeStore(fileURL: f.directory.appendingPathComponent("restored/runtime.json"), clock: { 2_000 })
        let restoreReport = try await restored.restore(from: backup)
        XCTAssertEqual(restoreReport.receiptCount, originalReport.receiptCount)
        XCTAssertEqual(restoreReport.archivedTaskCount, 7)
        let original = try await f.store.load()
        let roundTrip = try await restored.load()
        XCTAssertEqual(roundTrip, original)
        let verified = try await restored.verify()
        XCTAssertEqual(verified.receiptCount, originalReport.receiptCount)
        let restoredArchive = try await restored.archivedTask(id: "TASK-3")
        let originalArchive = try await f.store.archivedTask(id: "TASK-3")
        XCTAssertEqual(restoredArchive, originalArchive)
    }

    func testRestoreQuarantinesUnfinishedUnclaimedTasksAndDoesNotReplay() async throws {
        let f = try await fixture(pending: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        let backup = f.directory.appendingPathComponent("backup.json")
        _ = try await f.store.backup(to: backup)
        let store = SMLRuntimeStore(fileURL: f.directory.appendingPathComponent("restored/runtime.json"), clock: { 2_000 })
        let result = try await store.restore(from: backup)
        XCTAssertEqual(result.quarantinedTaskCount, 1)
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.tasks["TASK-ONE"]?.status, .failed)
        let receipt = snapshot.receipts.values.first { $0.kind == .restored }
        XCTAssertEqual(receipt?.payload["external_outcome"], .string("unknown"))
        XCTAssertEqual(receipt?.payload["previous_status"], .string("waiting_capability"))
        _ = try await store.verify()
    }

    func testBackupAndArchiveFailWhileHostLockHeld() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let fd = open(f.directory.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = flock(fd, LOCK_UN); _ = close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        do { _ = try await f.store.backup(to: f.directory.appendingPathComponent("backup")); XCTFail("live host must exclude maintenance") }
        catch { XCTAssertTrue(String(describing: error).contains("host.lock is held")) }
        do { _ = try await f.store.archiveTerminalTasks(updatedBeforeEpoch: 2_000); XCTFail("live host must exclude archive") }
        catch { XCTAssertTrue(String(describing: error).contains("host.lock is held")) }
    }

    func testCorruptBackupFailsBeforePublishingAnyRuntime() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        let backup = f.directory.appendingPathComponent("backup.json")
        _ = try await f.store.backup(to: backup)
        var bytes = try Data(contentsOf: backup)
        bytes[bytes.count / 2] ^= 1
        try bytes.write(to: backup)
        let destination = f.directory.appendingPathComponent("restored/runtime.json")
        let store = SMLRuntimeStore(fileURL: destination)
        do { _ = try await store.restore(from: backup); XCTFail("corruption must refuse") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRechecksummedButStructurallyCorruptBackupFailsBeforePublication() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        var snapshot = try await f.store.load()
        snapshot.receipts.removeAll()
        let payload = try SMLRuntimeStore.maintenanceEncode(SMLRuntimeBackupPayload(schemaVersion: 1,
            createdAtEpoch: 1_000, runtime: SMLRuntimeStore.maintenanceEncode(snapshot), archiveObjects: [:]))
        let invalid = SMLRuntimeBackupEnvelope(schemaVersion: 1, sha256: SMLRuntimeStore.maintenanceDigest(payload), payload: payload)
        let backup = f.directory.appendingPathComponent("invalid.json")
        try SMLRuntimeStore.maintenanceEncode(invalid).write(to: backup)
        let destination = f.directory.appendingPathComponent("restored/runtime.json")
        do { _ = try await SMLRuntimeStore(fileURL: destination).restore(from: backup); XCTFail("checksums alone do not prove valid history") }
        catch { XCTAssertTrue(String(describing: error).contains("receipt missing")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCorruptCurrentStoreRequiresDigestAndPreservesOriginalBytes() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        let backup = f.directory.appendingPathComponent("backup.json")
        _ = try await f.store.backup(to: backup)
        let runtimeURL = f.directory.appendingPathComponent("runtime.json")
        let corrupt = Data("{interrupted write".utf8)
        try corrupt.write(to: runtimeURL)
        do { _ = try await f.store.restore(from: backup); XCTFail("existing store requires exact replacement digest") } catch { }
        XCTAssertEqual(try Data(contentsOf: runtimeURL), corrupt)
        let report = try await f.store.restore(from: backup, replacingExpectedSHA256: SMLRuntimeStore.maintenanceDigest(corrupt))
        let quarantine = URL(fileURLWithPath: try XCTUnwrap(report.destinationPath))
        XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent("runtime.json")), corrupt)
        let recovered = try await f.store.load()
        XCTAssertEqual(recovered.tasks["TASK-ONE"]?.status, .completed)
    }

    func testCrashBeforeArchiveRootPublicationLeavesLiveEvidenceIntactAndRetryWorks() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        let before = try await f.store.load()
        let task = try XCTUnwrap(before.tasks["TASK-ONE"])
        let record = try XCTUnwrap(before.workflows.values.first)
        let archived = SMLRuntimeArchivedTask(task: task, workflow: record, receipts: task.receiptIDs.map { before.receipts[$0]! })
        // This is the crash boundary: durable objects exist, but runtime.json has its old root.
        _ = try await f.store.buildArchive([archived])
        let unchanged = try await f.store.load()
        XCTAssertEqual(unchanged, before)
        let retry = try await f.store.archiveTerminalTasks(updatedBeforeEpoch: 1_001)
        XCTAssertEqual(retry.archivedTaskCount, 1)
        XCTAssertEqual(retry.receiptCount, before.receipts.count)
        _ = try await f.store.verify()
    }

    func testArchiveCorruptionRefusesLookupBackupAndTaskIDReuse() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        _ = try await f.store.archiveTerminalTasks(updatedBeforeEpoch: 1_001)
        let snapshot = try await f.store.load()
        let root = try XCTUnwrap(snapshot.archiveRoot)
        let object = try await f.store.archiveObjectURL(root)
        try Data("corrupt".utf8).write(to: object)
        do { _ = try await f.store.archivedTask(id: "TASK-ONE"); XCTFail("corrupt index must refuse lookup") } catch { }
        do { _ = try await f.store.backup(to: f.directory.appendingPathComponent("backup.json")); XCTFail("corrupt archive must refuse backup") } catch { }
        do { _ = try await submit(f); XCTFail("corrupt index must not release identity") } catch { }
    }

    func testOlderBackupReplacementPreservesNewerTaskIdentities() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f, id: "TASK-OLD")
        let backup = f.directory.appendingPathComponent("backup.json")
        _ = try await f.store.backup(to: backup)
        _ = try await submit(f, id: "TASK-NEW")
        _ = try await f.store.archiveTerminalTasks(updatedBeforeEpoch: 1_001)
        let bytes = try Data(contentsOf: f.directory.appendingPathComponent("runtime.json"))
        _ = try await f.store.restore(from: backup, replacingExpectedSHA256: SMLRuntimeStore.maintenanceDigest(bytes))
        let newerArchive = try await f.store.archivedTask(id: "TASK-NEW")
        XCTAssertNotNil(newerArchive)
        do { _ = try await submit(f, id: "TASK-NEW"); XCTFail("older backup must not release newer archived identity") } catch { }
        _ = try await f.store.verify()
    }
    func testRestorePreservesInterruptedClaimAndItsReceipt() async throws {
        let f = try await fixture(pending: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        let claim = SMLCapabilityClaimRecord(dispatchID: "dispatch-interrupted", driverID: "fake-driver",
            instructionID: "work", stateDigest: String(repeating: "a", count: 64), commandID: "claim-command",
            actor: "operator.luke", leaseID: "old-host-session", claimedAtEpoch: 1_000)
        try await f.store.update { snapshot in
            var task = snapshot.tasks["TASK-ONE"]!
            let receipt = SMLRuntimeReceipt(id: "TASK-ONE.claim", kind: .capabilityClaimed,
                taskID: task.taskID, workflowID: task.workflowID, workflowVersion: task.workflowVersion,
                instructionID: "work", commandID: "claim-command", actor: "operator.luke",
                leaseID: "old-host-session", createdAtEpoch: 1_000,
                payload: ["dispatch_id": .string(claim.dispatchID)])
            task.capabilityClaim = claim
            task.revision += 1
            task.receiptIDs.append(receipt.id)
            snapshot.tasks[task.taskID] = task
            snapshot.receipts[receipt.id] = receipt
        }
        let backup = f.directory.appendingPathComponent("backup.json")
        _ = try await f.store.backup(to: backup)
        let restored = SMLRuntimeStore(fileURL: f.directory.appendingPathComponent("restored/runtime.json"))
        let report = try await restored.restore(from: backup)
        XCTAssertEqual(report.quarantinedTaskCount, 0)
        let state = try await restored.load()
        XCTAssertEqual(state.tasks["TASK-ONE"]?.capabilityClaim, claim)
        XCTAssertEqual(state.tasks["TASK-ONE"]?.status, .waitingCapability)
        let archive = try await restored.archiveTerminalTasks(updatedBeforeEpoch: 9_999)
        XCTAssertEqual(archive.archivedTaskCount, 0)
        XCTAssertEqual(archive.liveTaskCount, 1)
    }

    func testRestoreRepairsCorruptArchivedObjectFromVerifiedBackup() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        _ = try await f.store.archiveTerminalTasks(updatedBeforeEpoch: 1_001)
        let backup = f.directory.appendingPathComponent("backup.json")
        _ = try await f.store.backup(to: backup)
        let state = try await f.store.load()
        let object = try await f.store.archiveObjectURL(XCTUnwrap(state.archiveRoot))
        let corrupt = Data("broken archive".utf8)
        try corrupt.write(to: object)
        let bytes = try Data(contentsOf: f.directory.appendingPathComponent("runtime.json"))
        let report = try await f.store.restore(from: backup, replacingExpectedSHA256: SMLRuntimeStore.maintenanceDigest(bytes))
        let archive = try await f.store.archivedTask(id: "TASK-ONE")
        XCTAssertEqual(archive?.task.status, .completed)
        let quarantine = URL(fileURLWithPath: try XCTUnwrap(report.destinationPath))
        XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent("archive-" + object.lastPathComponent)), corrupt)
        _ = try await f.store.verify()
    }

    func testBackupNeverReplacesAnExistingDestination() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let backup = f.directory.appendingPathComponent("backup.json")
        let original = Data("keep exact original".utf8)
        try original.write(to: backup)
        do { _ = try await f.store.backup(to: backup); XCTFail("backup must be write once") } catch { }
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testRepeatedArchiveReclaimsOnlySupersededIndexNodes() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        for i in 0..<9 { _ = try await submit(f, id: "TASK-\(i)") }
        for _ in 0..<3 { _ = try await f.store.archiveTerminalTasks(updatedBeforeEpoch: 1_001, maximumTasks: 3) }
        let objectsDirectory = await f.store.archiveObjectsURL
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: objectsDirectory,
            includingPropertiesForKeys: nil))
        var leaves = 0
        var branches = 0
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let object = try JSONDecoder().decode(SMLRuntimeArchiveObject.self, from: Data(contentsOf: url))
            if object.task == nil { branches += 1 } else { leaves += 1 }
        }
        XCTAssertEqual(leaves, 9, "all task and receipt payloads survive")
        XCTAssertEqual(branches, 8, "obsolete index branches must not accumulate each batch")
        _ = try await f.store.verify()
    }

    func testHostArtifactFailureCannotPublishRestoredRuntime() async throws {
        enum FixtureError: Error { case cannotPublishConfiguration }
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        let backup = f.directory.appendingPathComponent("backup.json")
        let authority = Data("fixture authority bytes".utf8)
        _ = try await f.store.backup(to: backup, additionalFiles: { snapshot in
            XCTAssertEqual(snapshot.tasks.count, 1)
            return ["authority.json": authority]
        })
        let destination = f.directory.appendingPathComponent("restored/runtime.json")
        do {
            _ = try await SMLRuntimeStore(fileURL: destination).restore(from: backup,
                restoreAdditionalFiles: { files, quarantine in
                    XCTAssertEqual(files["authority.json"], authority)
                    XCTAssertNil(quarantine)
                    throw FixtureError.cannotPublishConfiguration
                })
            XCTFail("configuration publication failure must fail the restore")
        } catch FixtureError.cannotPublishConfiguration { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRestoreRejectsConflictingHistoriesAtTheSameRevision() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        let backup = f.directory.appendingPathComponent("backup.json")
        _ = try await f.store.backup(to: backup)
        try await f.store.update { snapshot in
            snapshot.tasks["TASK-ONE"]!.status = .failed
        }
        let url = f.directory.appendingPathComponent("runtime.json")
        let current = try Data(contentsOf: url)
        do {
            _ = try await f.store.restore(from: backup, replacingExpectedSHA256: SMLRuntimeStore.maintenanceDigest(current))
            XCTFail("equal revision is not authority to discard conflicting current evidence")
        } catch { XCTAssertTrue(String(describing: error).contains("equal revision")) }
        XCTAssertEqual(try Data(contentsOf: url), current)
    }

    func testLegacyBinaryRollbackCannotDiscardNewTaskHistory() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        var legacy = try await f.store.load()
        legacy.schemaVersion = 1
        let url = f.directory.appendingPathComponent("runtime.json")
        try JSONEncoder().encode(legacy).write(to: url)
        _ = try await submit(f)
        let current = try Data(contentsOf: url)
        do { try await f.store.restoreSchemaV1Backup(); XCTFail("legacy rollback must not release a newer task identity") }
        catch { XCTAssertTrue(String(describing: error).contains("discard task history")) }
        XCTAssertEqual(try Data(contentsOf: url), current)
    }

    func testOrdinaryStoreWritesCannotDropArchivedIdentityIndex() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f)
        _ = try await f.store.archiveTerminalTasks(updatedBeforeEpoch: 1_001)
        let before = try await f.store.load()
        var replacement = before
        replacement.archiveRoot = nil
        replacement.archivedTaskCount = 0
        do { try await f.store.save(replacement); XCTFail("ordinary save must not discard archive identity history") } catch { }
        do {
            try await f.store.update { snapshot in
                snapshot.archiveRoot = nil
                snapshot.archivedTaskCount = 0
            }
            XCTFail("ordinary update must not discard archive identity history")
        } catch { }
        let after = try await f.store.load()
        XCTAssertEqual(after, before)
    }

}
