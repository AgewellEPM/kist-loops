import XCTest
@testable import AgentCore

final class SMLRuntimeAdmissionLimitsTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let store: SMLRuntimeStore
        let runtime: SMLRuntime
        let gateway: SMLCommandGateway
    }

    private func fixture(limits: SMLRuntimeAdmissionLimits, pending: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sml-capacity-" + UUID().uuidString)
        let store = SMLRuntimeStore(fileURL: directory.appendingPathComponent("runtime.json"), clock: { 1_000 }, admissionLimits: limits)
        let runtime = SMLRuntime(store: store, clock: { 1_000 })
        let workflow = SMLWorkflow(id: "capacity.workflow", version: "1.0.0", name: "Capacity",
            source: .init(kind: .native, reference: "tests://capacity"), trigger: .init(kind: .manual),
            stateSchema: [.init(name: "input", type: .string, required: false)],
            interface: .init(inputFields: ["input"]), entrypoint: pending ? "approve" : "done",
            instructions: pending ? [.init(id: "approve", op: .waitApproval, reason: "review fixture",
                owner: "host-operator", next: "done", onFailure: "failed"),
                .init(id: "failed", op: .escalate, reason: "declined", owner: "host-operator"),
                .init(id: "done", op: .emitReceipt, receiptFields: ["task", "status"])]
                : [.init(id: "done", op: .emitReceipt, receiptFields: ["task", "status"])])
        _ = try await runtime.installWorkflow(SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(workflow),
            catalog: .init(approvalAuthorities: ["host-operator"])), role: "operator-role")
        return Fixture(directory: directory, store: store, runtime: runtime,
            gateway: SMLCommandGateway(runtime: runtime, replayGuard: store))
    }

    private func command(_ id: String, input: String? = nil) -> SMLCommandEnvelope {
        var arguments: SMLObject = ["workflow_id": .string("capacity.workflow")]
        if let input { arguments["initial_state"] = .object(["input": .string(input)]) }
        return SMLCommandEnvelope(actor: "operator.luke", role: "operator-role", task: id,
            op: SMLRuntimeCommandOperation.workflowRun, arguments: arguments, issuedAtEpoch: 1_000)
    }

    private func authority(_ command: SMLCommandEnvelope) -> SMLCommandAuthority {
        SMLCommandAuthority(authenticatedActor: command.actor, leaseID: "capacity-lease",
            roles: [command.role], tasks: [command.task], operations: SMLRuntimeCommandOperation.all,
            approvalAuthorities: ["host-operator"], scope: [:])
    }

    private func submit(_ f: Fixture, command: SMLCommandEnvelope) async throws -> SMLCommandResult {
        try await f.gateway.submit(command, authority: authority(command), nowEpoch: 1_000)
    }

    func testRepeatedCapacityRejectionsDoNotMutateReplayClaimsAndArchiveReopensAdmission() async throws {
        let f = try await fixture(limits: .init(maximumHotTasks: 1))
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await submit(f, command: command("TASK-ONE"))
        let url = f.directory.appendingPathComponent("runtime.json")
        let before = try Data(contentsOf: url)
        for i in 0..<20 {
            do { _ = try await submit(f, command: command("TASK-REJECT-\(i)")); XCTFail("full history must reject new tasks") }
            catch let error as SMLRuntimeCapacityError { XCTAssertEqual(error, .hotTasks(1)) }
        }
        XCTAssertEqual(try Data(contentsOf: url), before, "rejected traffic must not append replay claims")
        let closed = try await f.store.admissionStatus()
        XCTAssertFalse(closed.acceptingNewTasks)
        _ = try await f.store.archiveTerminalTasks(updatedBeforeEpoch: 1_001)
        let opened = try await f.store.admissionStatus()
        XCTAssertTrue(opened.acceptingNewTasks)
        _ = try await submit(f, command: command("TASK-TWO"))
        let archived = try await f.store.archivedTask(id: "TASK-ONE")
        XCTAssertNotNil(archived)
    }

    func testExistingApprovalCanFinishAtCapacityAndPendingLimitReopens() async throws {
        let f = try await fixture(limits: .init(maximumHotTasks: 4, maximumUnfinishedTasks: 1), pending: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = try await submit(f, command: command("TASK-ONE"))
        XCTAssertEqual(first.task?.status, .waitingApproval)
        do { _ = try await submit(f, command: command("TASK-TWO")); XCTFail("unfinished limit must reject") }
        catch let error as SMLRuntimeCapacityError { XCTAssertEqual(error, .unfinishedTasks(1)) }
        let snapshot = try await f.store.load()
        let approval = SMLCommandEnvelope(actor: "operator.luke", role: "operator-role", task: "TASK-ONE",
            op: SMLRuntimeCommandOperation.taskApprove,
            expectedState: ["task_revision": .number(Decimal(snapshot.tasks["TASK-ONE"]!.revision))], issuedAtEpoch: 1_000)
        let completed = try await submit(f, command: approval)
        XCTAssertEqual(completed.task?.status, .completed)
        let next = try await submit(f, command: command("TASK-TWO"))
        XCTAssertEqual(next.task?.status, .waitingApproval)
    }

    func testOversizedNewTaskFailsBeforeAnyReplayMutation() async throws {
        let f = try await fixture(limits: .init(maximumHotBytes: 4_000))
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let url = f.directory.appendingPathComponent("runtime.json")
        let before = try Data(contentsOf: url)
        XCTAssertLessThan(before.count, 4_000)
        for i in 0..<5 {
            do { _ = try await submit(f, command: command("TASK-BIG-\(i)", input: String(repeating: "x", count: 4_000))); XCTFail("prospective bytes must be checked") }
            catch let error as SMLRuntimeCapacityError { XCTAssertEqual(error, .hotBytes(4_000)) }
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAtomicCreationCheckRejectsAlreadyAdmittedCompetingTask() async throws {
        let f = try await fixture(limits: .init(maximumHotTasks: 1))
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let a = command("TASK-A")
        let b = command("TASK-B")
        let admittedA = try await SMLCommandAdmission.admit(a, authority: authority(a), nowEpoch: 1_000, replayGuard: f.store)
        let admittedB = try await SMLCommandAdmission.admit(b, authority: authority(b), nowEpoch: 1_000, replayGuard: f.store)
        _ = try await f.runtime.submit(admittedA)
        do { _ = try await f.runtime.submit(admittedB); XCTFail("stale preflight cannot exceed atomic limit") }
        catch let error as SMLRuntimeCapacityError { XCTAssertEqual(error, .hotTasks(1)) }
        let state = try await f.store.load()
        XCTAssertEqual(Set(state.tasks.keys), ["TASK-A"])
    }

    func testLimitsConfigurationIsStrictAndReportsUnqualifiedIncrease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sml-limit-config-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".kist/sml"), withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(SMLRuntimeAdmissionLimits.relativePath)
        for json in [#"{"schema_version":1,"maximum_hot_tasks":0}"#,
                     #"{"schema_version":1,"maximum_unfinished_tasks":1.5}"#,
                     #"{"schema_version":1,"maximum_hot_bytes":"4096"}"#,
                     #"{"schema_version":1,"max_tasks":3}"#] {
            try Data(json.utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            XCTAssertThrowsError(try SMLRuntimeAdmissionLimits.load(projectRoot: directory.path))
        }
        try Data(#"{"schema_version":1,"maximum_hot_tasks":501}"#.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let limits = try SMLRuntimeAdmissionLimits.load(projectRoot: directory.path)
        let store = SMLRuntimeStore(fileURL: directory.appendingPathComponent("runtime.json"), admissionLimits: limits)
        let status = try await store.admissionStatus()
        XCTAssertTrue(status.qualifiedLimitsExceeded)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        XCTAssertThrowsError(try SMLRuntimeAdmissionLimits.load(projectRoot: directory.path))
    }
}
