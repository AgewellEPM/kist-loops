import XCTest
@testable import AgentCore

final class SMLRuntimeTests: XCTestCase {
    func testStoreLoadRejectsSymlinkRuntimePath() async throws {
        let directory = temporaryDirectory("sml-runtime-symlink-load")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let targetURL = directory.appendingPathComponent("attacker.json")
        let runtimeURL = directory.appendingPathComponent("runtime.json")
        try JSONEncoder().encode(SMLRuntimeSnapshot()).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: runtimeURL,
            withDestinationURL: targetURL
        )
        let store = SMLRuntimeStore(fileURL: runtimeURL)

        do {
            _ = try await store.load()
            XCTFail("runtime store loads must not follow symbolic links")
        } catch let error as SMLRuntimeStoreError {
            guard case .io = error else {
                return XCTFail("expected an I/O refusal, got \(error)")
            }
        }
    }

    func testSchemaV2MissingAuthoritativeFieldsFailsClosed() async throws {
        let task = SMLRuntimeTask(
            taskID: "TASK-STRICT",
            role: "strict-role",
            workflowID: "strict.workflow",
            workflowVersion: "1.0.0",
            revision: 7,
            currentInstructionID: "work",
            createdAtEpoch: 1_000,
            updatedAtEpoch: 1_000
        )
        let encoded = try JSONEncoder().encode(
            SMLRuntimeSnapshot(tasks: [task.taskID: task], replayClaims: ["claim": 2_000])
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        var missingActive = root
        missingActive.removeValue(forKey: "active_workflow_versions")
        var missingReplay = root
        missingReplay.removeValue(forKey: "replay_claims")
        var missingRevision = root
        var tasks = try XCTUnwrap(missingRevision["tasks"] as? [String: Any])
        var taskObject = try XCTUnwrap(tasks[task.taskID] as? [String: Any])
        taskObject.removeValue(forKey: "task_revision")
        tasks[task.taskID] = taskObject
        missingRevision["tasks"] = tasks

        for (name, object) in [
            ("active", missingActive),
            ("replay", missingReplay),
            ("revision", missingRevision),
        ] {
            let directory = temporaryDirectory("sml-runtime-strict-v2-\(name)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let fileURL = directory.appendingPathComponent("runtime.json")
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                .write(to: fileURL)
            let store = SMLRuntimeStore(fileURL: fileURL)

            do {
                _ = try await store.load()
                XCTFail("schema v2 must require \(name)")
            } catch let error as SMLRuntimeStoreError {
                guard case .decoding = error else {
                    return XCTFail("expected a decoding refusal for \(name), got \(error)")
                }
            }
        }
    }

    func testLiteralSchemaV1MigrationCreatesExactOwnerOnlyRollbackBackup() async throws {
        let directory = temporaryDirectory("sml-runtime-schema-v1-migration")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("runtime.json")
        let fixtureBytes = Data(Self.literalSchemaV1Snapshot.utf8)
        try fixtureBytes.write(to: fileURL)

        let store = SMLRuntimeStore(fileURL: fileURL, clock: { 1_000 })
        XCTAssertEqual(
            store.schemaV1BackupURL,
            directory.appendingPathComponent("runtime.json.schema-v1.backup")
        )

        let migrated = try await store.load()
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.activeWorkflowVersions["legacy.workflow"], "1.0.0")
        XCTAssertNotNil(migrated.workflows["legacy.workflow#1.0.0"])
        XCTAssertEqual(migrated.tasks["TASK-LEGACY"]?.revision, 0)

        try await store.save(migrated)

        XCTAssertEqual(try Data(contentsOf: store.schemaV1BackupURL), fixtureBytes)
        let backupAttributes = try FileManager.default.attributesOfItem(
            atPath: store.schemaV1BackupURL.path
        )
        let backupMode = try XCTUnwrap(backupAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(backupMode.intValue & 0o777, 0o600)

        let published = try JSONDecoder().decode(
            SMLRuntimeSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(published.schemaVersion, 2)
    }

    func testSchemaV1RollbackBackupIsWriteOnceAndRestoresExactOriginalBytes() async throws {
        let directory = temporaryDirectory("sml-runtime-schema-v1-restore")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("runtime.json")
        let originalBytes = Data(Self.literalSchemaV1Snapshot.utf8)
        try originalBytes.write(to: fileURL)
        let store = SMLRuntimeStore(fileURL: fileURL, clock: { 1_000 })

        try await store.save(try await store.load())
        XCTAssertEqual(try Data(contentsOf: store.schemaV1BackupURL), originalBytes)

        let replacementText = Self.literalSchemaV1Snapshot.replacingOccurrences(
            of: "\"legacy-command\": 2000",
            with: "\"legacy-command\": 3000"
        )
        let replacementBytes = Data(replacementText.utf8)
        XCTAssertNotEqual(replacementBytes, originalBytes)
        try replacementBytes.write(to: fileURL, options: .atomic)
        try await store.save(try await store.load())

        XCTAssertEqual(
            try Data(contentsOf: store.schemaV1BackupURL),
            originalBytes,
            "a later schema-v1 publication must never replace the first rollback backup"
        )

        try await store.restoreSchemaV1Backup()
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: store.schemaV1BackupURL), originalBytes)
        let restored = try await store.load()
        XCTAssertEqual(restored.replayClaims["legacy-command"], 2_000)
    }

    func testStoreDurablyReplacesSnapshotAndKeepsOwnerOnlyMode() async throws {
        let directory = temporaryDirectory("sml-runtime-durable-save")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("runtime.json")
        let store = SMLRuntimeStore(fileURL: fileURL, clock: { 1_000 })

        let first = SMLRuntimeSnapshot(replayClaims: ["first": 2_000])
        try await store.save(first)
        let firstBytes = try Data(contentsOf: fileURL)

        let firstAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let firstMode = try XCTUnwrap(firstAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(firstMode.intValue & 0o777, 0o600)

        let second = SMLRuntimeSnapshot(replayClaims: ["second": 3_000])
        try await store.save(second)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, second)
        XCTAssertNotEqual(try Data(contentsOf: fileURL), firstBytes)
        let secondAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let secondMode = try XCTUnwrap(secondAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(secondMode.intValue & 0o777, 0o600)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasSuffix(".tmp") }
        )
    }

    func testCommandBusCreatesWatchesApprovesAndPersistsTask() async throws {
        let directory = temporaryDirectory("sml-runtime-approval")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 1_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 1_000 })

        try await install(approvalWorkflow(), role: "digital-presence-manager", runtime: runtime)

        let run = try await runtime.submit(try await admitted(
            commandID: "command-run",
            task: "TASK-1842",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: ["workflow_id": .string("website.publish")],
            store: store
        ))
        XCTAssertEqual(run.task?.status, .waitingApproval)
        XCTAssertEqual(run.task?.currentInstructionID, "approval")
        XCTAssertEqual(run.task?.waitingApprovalOwner, "production_approver")
        XCTAssertEqual(run.task?.taskRevision, 1)

        let watch = try await runtime.submit(try await admitted(
            commandID: "command-watch",
            task: "TASK-1842",
            op: SMLRuntimeCommandOperation.taskWatch,
            store: store
        ))
        XCTAssertEqual(watch.task, run.task)

        do {
            _ = try await runtime.submit(try await admitted(
                commandID: "command-record-approval",
                task: "TASK-1842",
                op: SMLRuntimeCommandOperation.taskRecordStep,
                store: store
            ))
            XCTFail("record_step must not advance an approval gate")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .unsupportedOperation(SMLRuntimeCommandOperation.taskRecordStep)
            )
        }

        let approve = try await runtime.submit(try await admitted(
            commandID: "command-approve",
            task: "TASK-1842",
            op: SMLRuntimeCommandOperation.taskApprove,
            expectedState: ["task_revision": .number(1)],
            store: store
        ))
        XCTAssertEqual(approve.task?.status, .completed)
        XCTAssertEqual(approve.task?.currentOperation, .emitReceipt)
        XCTAssertEqual(approve.task?.taskRevision, 2)

        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.tasks["TASK-1842"]?.status, .completed)
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .taskCreated })
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .checkpoint })
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .approvalRequested })
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .approved })
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .receiptEmitted })

        do {
            _ = try await admitted(
                commandID: "command-run",
                task: "TASK-9999",
                op: SMLRuntimeCommandOperation.workflowRun,
                arguments: ["workflow_id": .string("website.publish")],
                store: store
            )
            XCTFail("replay claims must survive through the durable runtime store")
        } catch {
            XCTAssertEqual(error as? SMLCommandAdmissionError, .replayedCommand)
        }
    }

    func testRawRecordStepCannotBypassClaimedCapabilityPath() async throws {
        let directory = temporaryDirectory("sml-runtime-steps")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 2_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 2_000 })

        try await install(repairWorkflow(), role: "digital-presence-manager", runtime: runtime)

        let run = try await runtime.submit(try await admitted(
            commandID: "repair-run",
            task: "TASK-200",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: ["workflow_id": .string("website.repair")],
            store: store
        ))
        XCTAssertEqual(run.task?.status, .waitingCapability)
        XCTAssertEqual(run.task?.currentInstructionID, "patch")

        do {
            _ = try await runtime.submit(try await admitted(
                commandID: "repair-patch",
                task: "TASK-200",
                op: SMLRuntimeCommandOperation.taskRecordStep,
                arguments: [
                    "outcome": .string("passed"),
                    "state_patch": .object(["verification_status": .string("patched")]),
                    "evidence": .object(["forged": .bool(true)]),
                ],
                store: store
            ))
            XCTFail("raw record_step must never bypass the opaque dispatch proof")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .unsupportedOperation(SMLRuntimeCommandOperation.taskRecordStep)
            )
        }
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.tasks["TASK-200"]?.currentInstructionID, "patch")
        XCTAssertNil(snapshot.tasks["TASK-200"]?.state["verification_status"])
        XCTAssertFalse(snapshot.receipts.values.contains { $0.kind == .stepRecorded })
    }

    func testRunMatchingUsesTypedFiltersAndFailsClosedOnAmbiguity() async throws {
        let directory = temporaryDirectory("sml-runtime-matching")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 3_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 3_000 })

        try await install(simpleWorkflow(id: "website.health"), role: "digital-presence-manager", runtime: runtime)
        try await install(simpleWorkflow(id: "seo.audit"), role: "digital-presence-manager", runtime: runtime)

        let matched = try await runtime.submit(try await admitted(
            commandID: "match-one",
            task: "TASK-MATCH-1",
            op: SMLRuntimeCommandOperation.workflowRunMatching,
            arguments: ["filters": .object(["category": .string("website")])],
            store: store
        ))
        XCTAssertEqual(matched.task?.workflowID, "website.health")

        try await install(simpleWorkflow(id: "website.performance"), role: "digital-presence-manager", runtime: runtime)
        do {
            _ = try await runtime.submit(try await admitted(
                commandID: "match-many",
                task: "TASK-MATCH-2",
                op: SMLRuntimeCommandOperation.workflowRunMatching,
                arguments: ["filters": .object(["category": .string("website")])],
                store: store
            ))
            XCTFail("ambiguous workflow filters must fail closed")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .ambiguousWorkflowMatch(["website.health", "website.performance"])
            )
        }
    }

    func testREPLCompilerAndRendererMapShellCommandsToTypedEnvelopes() throws {
        let compiler = SMLREPLCompiler(
            actor: "operator.luke",
            role: "digital-presence-manager",
            commandID: { "command-fixed" },
            taskID: { "TASK-1842" }
        )

        let run = try compiler.compile("run website.performance_repair", issuedAtEpoch: 4_000)
        XCTAssertEqual(run.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(run.task, "TASK-1842")
        XCTAssertEqual(run.arguments["workflow_id"], .string("website.performance_repair"))

        let approve = try compiler.compile("approve TASK-1842 7", issuedAtEpoch: 4_001)
        XCTAssertEqual(approve.op, SMLRuntimeCommandOperation.taskApprove)
        XCTAssertEqual(approve.task, "TASK-1842")
        XCTAssertEqual(approve.expectedState["task_revision"], .number(7))

        let output = SMLREPLRenderer.render(SMLCommandResult(
            kind: .status,
            message: "status",
            status: .init(
                workflowCount: 2,
                roleCount: 1,
                taskCount: 3,
                activeTaskCount: 1,
                receiptCount: 5
            )
        ))
        XCTAssertTrue(output.contains("workflows: 2"))
        XCTAssertTrue(output.contains("tasks: 3 active: 1"))
    }

    func testOperatorRollbackLeavesTerminalRolledBackTask() async throws {
        let directory = temporaryDirectory("sml-runtime-rollback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 5_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 5_000 })

        try await install(repairWorkflow(), role: "digital-presence-manager", runtime: runtime)
        let run = try await runtime.submit(try await admitted(
            commandID: "rollback-run",
            task: "TASK-ROLLBACK",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: ["workflow_id": .string("website.repair")],
            store: store
        ))

        let rolledBack = try await runtime.submit(try await admitted(
            commandID: "rollback-now",
            task: "TASK-ROLLBACK",
            op: SMLRuntimeCommandOperation.taskRollback,
            expectedState: [
                "task_revision": .number(Decimal(try XCTUnwrap(run.task?.taskRevision))),
            ],
            store: store
        ))
        XCTAssertEqual(rolledBack.task?.status, .rolledBack)

        do {
            _ = try await runtime.submit(try await admitted(
                commandID: "rollback-again",
                task: "TASK-ROLLBACK",
                op: SMLRuntimeCommandOperation.taskRollback,
                expectedState: [
                    "task_revision": .number(
                        Decimal(try XCTUnwrap(rolledBack.task?.taskRevision))
                    ),
                ],
                store: store
            ))
            XCTFail("a terminal rollback must not append another receipt")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .invalidTaskState("terminal task cannot be rolled back again")
            )
        }

        let status = try await runtime.status()
        XCTAssertEqual(status.status?.activeTaskCount, 0)
    }

    private func admitted(
        commandID: String,
        task: String,
        op: String,
        role: String = "digital-presence-manager",
        arguments: SMLObject = [:],
        expectedState: SMLObject = [:],
        store: SMLRuntimeStore
    ) async throws -> SMLAdmittedCommand {
        let command = SMLCommandEnvelope(
            commandID: commandID,
            actor: "operator.luke",
            role: role,
            task: task,
            op: op,
            arguments: arguments,
            expectedState: expectedState,
            issuedAtEpoch: 1_000
        )
        return try await SMLCommandAdmission.admit(
            SMLCommandCandidate(command: command, validationReport: command.validate()),
            authority: SMLCommandAuthority(
                authenticatedActor: "operator.luke",
                leaseID: "lease-1",
                roles: [role],
                tasks: [task],
                operations: SMLRuntimeCommandOperation.all,
                approvalAuthorities: ["production_approver"],
                scope: [:]
            ),
            nowEpoch: 1_000,
            replayGuard: store
        )
    }

    private func install(
        _ workflow: SMLWorkflow,
        role: String,
        runtime: SMLRuntime
    ) async throws {
        let candidate = try SMLWorkflowValidator.requireValidForImport(workflow)
        let admitted = try SMLWorkflowAdmission.admitForExecution(
            candidate,
            catalog: SMLExecutionAdmissionCatalog(
                toolCapabilities: ["repository.apply_patch"],
                verifiers: ["build_passed"],
                approvalAuthorities: ["production_approver"]
            )
        )
        _ = try await runtime.installWorkflow(admitted, role: role)
    }

    private func approvalWorkflow() -> SMLWorkflow {
        SMLWorkflow(
            id: "website.publish",
            version: "1.0.0",
            name: "Website publish",
            source: .init(kind: .jobDescription, reference: "digital-presence-manager"),
            trigger: .init(kind: .manual),
            stateSchema: [.init(name: "approved", type: .boolean, required: false)],
            entrypoint: "checkpoint",
            instructions: [
                .init(id: "checkpoint", op: .checkpoint, next: "approval"),
                .init(id: "approval", op: .waitApproval,
                      reason: "production_deployment", owner: "production_approver",
                      next: "receipt", onFailure: "refused"),
                .init(id: "receipt", op: .emitReceipt,
                      receiptFields: ["actor", "task", "workflow_id", "approved"]),
                .init(id: "refused", op: .escalate,
                      reason: "approval_refused", owner: "production_approver"),
            ]
        )
    }

    private func repairWorkflow() -> SMLWorkflow {
        SMLWorkflow(
            id: "website.repair",
            version: "1.0.0",
            name: "Website repair",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [.init(name: "verification_status", type: .string)],
            entrypoint: "patch",
            instructions: [
                .init(id: "patch", op: .callTool,
                      capability: "repository.apply_patch", next: "verify"),
                .init(id: "verify", op: .verify, verifier: "build_passed",
                      onPass: "receipt", onFailure: "rollback"),
                .init(id: "rollback", op: .rollback,
                      reason: "verification_failed", next: "escalated"),
                .init(id: "receipt", op: .emitReceipt,
                      receiptFields: ["task", "verification_status"]),
                .init(id: "escalated", op: .escalate,
                      reason: "repair_failed", owner: "production_approver"),
            ]
        )
    }

    private func simpleWorkflow(id: String) -> SMLWorkflow {
        SMLWorkflow(
            id: id,
            version: "1.0.0",
            name: id,
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            entrypoint: "done",
            instructions: [.init(id: "done", op: .complete)]
        )
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Hand-authored output from the schema-v1 runtime shape. Keeping this literal prevents the
    /// current schema-v2 encoder from accidentally making the migration regression self-fulfilling.
    private static let literalSchemaV1Snapshot = """
    {
      "schema_version": 1,
      "workflows": {
        "legacy.workflow": {
          "role": "operator-role",
          "workflow": {
            "ir_version": 1,
            "id": "legacy.workflow",
            "version": "1.0.0",
            "name": "Legacy workflow",
            "source": {
              "kind": "native",
              "reference": "literal-v1-fixture"
            },
            "trigger": {
              "kind": "manual"
            },
            "state_schema": [],
            "entrypoint": "done",
            "instructions": [
              {
                "id": "done",
                "op": "COMPLETE"
              }
            ]
          },
          "installed_at_epoch": 900
        }
      },
      "tasks": {
        "TASK-LEGACY": {
          "schema_version": 1,
          "task_id": "TASK-LEGACY",
          "role": "operator-role",
          "workflow_id": "legacy.workflow",
          "workflow_version": "1.0.0",
          "current_instruction_id": "done",
          "status": "completed",
          "created_at_epoch": 900,
          "updated_at_epoch": 901,
          "state": {},
          "retry_counts": {},
          "receipt_ids": []
        }
      },
      "receipts": {},
      "replay_claims": {
        "legacy-command": 2000
      }
    }
    """
}
