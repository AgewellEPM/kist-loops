import XCTest
@testable import AgentCore

/// Pins the deny-by-default contract of the durable-host authority file: an actor absent from
/// authority.json holds NOTHING, a grant never exceeds what the file literally says (no wildcard
/// path exists anywhere), typo'd operation names fail the LOAD, and the file itself must be an
/// owner-only regular file. The offline export path's rubber-stamp resolver is intentionally NOT
/// under test here — these gates exist precisely because live hosts must never use it.
final class SMLRuntimeAuthorityConfigTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-authority-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func writeAuthority(_ json: String, mode: Int16 = 0o600) throws -> URL {
        let url = scratch.appendingPathComponent("authority.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
        return url
    }

    private let validJSON = """
    {
      "schema_version": 1,
      "actors": [
        {
          "id": "operator-alice",
          "roles": ["workflow-agent"],
          "operations": ["workflow.run", "task.watch", "receipts.list"],
          "approval_authorities": ["ops-lead"]
        }
      ]
    }
    """

    private func envelope(
        actor: String = "operator-alice",
        role: String = "workflow-agent",
        task: String = "TASK-1",
        op: String = SMLRuntimeCommandOperation.workflowRun,
        scope: SMLObject = [:],
        issuedAtEpoch: Double = 1_000
    ) -> SMLCommandEnvelope {
        SMLCommandEnvelope(
            commandID: "cmd-\(UUID().uuidString.lowercased())",
            actor: actor,
            role: role,
            task: task,
            op: op,
            arguments: [:],
            scope: scope,
            expectedState: [:],
            issuedAtEpoch: issuedAtEpoch
        )
    }

    // MARK: - Load gates

    func testValidFileLoadsGrantsExactly() throws {
        let url = try writeAuthority(validJSON)
        let config = try SMLRuntimeAuthorityConfig.load(fileURL: url)
        let grant = try XCTUnwrap(config.actors["operator-alice"])
        XCTAssertEqual(grant.roles, ["workflow-agent"])
        XCTAssertEqual(
            grant.operations,
            [SMLRuntimeCommandOperation.workflowRun,
             SMLRuntimeCommandOperation.taskWatch,
             SMLRuntimeCommandOperation.receiptsList]
        )
        XCTAssertEqual(grant.approvalAuthorities, ["ops-lead"])
        XCTAssertTrue(grant.scopeTemplate.isEmpty, "omitted scope_template must default to empty")
    }

    func testMissingFileFailsClosedWithGuidance() {
        XCTAssertThrowsError(
            try SMLRuntimeAuthorityConfig.load(fileURL: scratch.appendingPathComponent("absent.json"))
        ) { error in
            guard case SMLRuntimeAuthorityConfig.LoadError.missing = error else {
                return XCTFail("expected .missing, got \(error)")
            }
        }
    }

    func testGroupOrWorldAccessiblePermissionsFailClosed() throws {
        let url = try writeAuthority(validJSON, mode: 0o644)
        XCTAssertThrowsError(try SMLRuntimeAuthorityConfig.load(fileURL: url)) { error in
            guard case SMLRuntimeAuthorityConfig.LoadError.insecurePermissions = error else {
                return XCTFail("expected .insecurePermissions, got \(error)")
            }
        }
    }

    func testUnknownOperationNameFailsTheLoadNotTheRuntime() throws {
        let url = try writeAuthority("""
        {
          "schema_version": 1,
          "actors": [
            {"id": "a", "roles": ["r"], "operations": ["workflow.rnu"]}
          ]
        }
        """)
        XCTAssertThrowsError(try SMLRuntimeAuthorityConfig.load(fileURL: url)) { error in
            guard case SMLRuntimeAuthorityConfig.LoadError.unknownOperation(_, let op) = error else {
                return XCTFail("expected .unknownOperation, got \(error)")
            }
            XCTAssertEqual(op, "workflow.rnu")
        }
    }

    func testEmptyRolesAndDuplicateActorsAndNoActorsFailClosed() throws {
        let emptyRoles = try writeAuthority("""
        {"schema_version": 1, "actors": [{"id": "a", "roles": [], "operations": []}]}
        """)
        XCTAssertThrowsError(try SMLRuntimeAuthorityConfig.load(fileURL: emptyRoles)) { error in
            guard case SMLRuntimeAuthorityConfig.LoadError.emptyRoles = error else {
                return XCTFail("expected .emptyRoles, got \(error)")
            }
        }

        let duplicate = try writeAuthority("""
        {"schema_version": 1, "actors": [
          {"id": "a", "roles": ["r"], "operations": []},
          {"id": "a", "roles": ["r"], "operations": []}
        ]}
        """)
        XCTAssertThrowsError(try SMLRuntimeAuthorityConfig.load(fileURL: duplicate)) { error in
            guard case SMLRuntimeAuthorityConfig.LoadError.duplicateActorID = error else {
                return XCTFail("expected .duplicateActorID, got \(error)")
            }
        }

        let noActors = try writeAuthority("""
        {"schema_version": 1, "actors": []}
        """)
        XCTAssertThrowsError(try SMLRuntimeAuthorityConfig.load(fileURL: noActors)) { error in
            guard case SMLRuntimeAuthorityConfig.LoadError.noActors = error else {
                return XCTFail("expected .noActors, got \(error)")
            }
        }
    }

    func testUnsupportedSchemaVersionFailsClosed() throws {
        let url = try writeAuthority("""
        {"schema_version": 2, "actors": [{"id": "a", "roles": ["r"], "operations": []}]}
        """)
        XCTAssertThrowsError(try SMLRuntimeAuthorityConfig.load(fileURL: url)) { error in
            guard case SMLRuntimeAuthorityConfig.LoadError.unsupportedSchemaVersion(2) = error else {
                return XCTFail("expected .unsupportedSchemaVersion(2), got \(error)")
            }
        }
    }

    // MARK: - Deny-by-default resolution + admission

    func testUnknownActorResolvesToNothing() async throws {
        let url = try writeAuthority(validJSON)
        let config = try SMLRuntimeAuthorityConfig.load(fileURL: url)
        let lease = SMLRuntimeLeaseRegistry.Session()
        do {
            _ = try await config.resolveAuthority(
                for: envelope(actor: "stranger"),
                lease: lease
            )
            XCTFail("unknown actor must resolve to nothing")
        } catch let error as SMLRuntimeAuthorityConfig.ResolutionError {
            XCTAssertEqual(error, .unknownActor("stranger"))
        }
    }

    func testGrantsNeverExceedTheFileNoWildcardPathExists() async throws {
        let url = try writeAuthority(validJSON)
        let config = try SMLRuntimeAuthorityConfig.load(fileURL: url)
        let lease = SMLRuntimeLeaseRegistry.Session()

        // Operation outside the granted set: resolved authority must deny at admission.
        // (Bind the task first — the admission gate checks task before operation, and this
        // assertion pins the OPERATION gate specifically.)
        await lease.adopt(taskID: "TASK-1")
        let rollback = envelope(op: SMLRuntimeCommandOperation.taskRollback)
        let authority = try await config.resolveAuthority(for: rollback, lease: lease)
        XCTAssertThrowsError(
            try SMLCommandAdmission.preflight(rollback, authority: authority, nowEpoch: 1_000)
        ) { error in
            XCTAssertEqual(error as? SMLCommandAdmissionError, .operationDenied)
        }

        // Role outside the granted set.
        let wrongRole = envelope(role: "admin-role")
        let roleAuthority = try await config.resolveAuthority(for: wrongRole, lease: lease)
        XCTAssertThrowsError(
            try SMLCommandAdmission.preflight(wrongRole, authority: roleAuthority, nowEpoch: 1_000)
        ) { error in
            XCTAssertEqual(error as? SMLCommandAdmissionError, .roleDenied)
        }
    }

    func testScopeKeyOutsideTemplateIsDenied() async throws {
        let url = try writeAuthority(validJSON)
        let config = try SMLRuntimeAuthorityConfig.load(fileURL: url)
        let lease = SMLRuntimeLeaseRegistry.Session()
        let scoped = envelope(scope: ["tenant": .string("acme")])
        let authority = try await config.resolveAuthority(for: scoped, lease: lease)
        XCTAssertThrowsError(
            try SMLCommandAdmission.preflight(scoped, authority: authority, nowEpoch: 1_000)
        ) { error in
            XCTAssertEqual(error as? SMLCommandAdmissionError, .scopeDenied(path: "scope.tenant"))
        }
    }

    func testGrantedCommandPassesPreflight() async throws {
        let url = try writeAuthority(validJSON)
        let config = try SMLRuntimeAuthorityConfig.load(fileURL: url)
        let lease = SMLRuntimeLeaseRegistry.Session()
        let run = envelope()
        let authority = try await config.resolveAuthority(for: run, lease: lease)
        XCTAssertNoThrow(
            try SMLCommandAdmission.preflight(run, authority: authority, nowEpoch: 1_000)
        )
    }

    func testStaleCommandIsRejectedByRealClockWindow() async throws {
        let url = try writeAuthority(validJSON)
        let config = try SMLRuntimeAuthorityConfig.load(fileURL: url)
        let lease = SMLRuntimeLeaseRegistry.Session()
        let stale = envelope(issuedAtEpoch: 1_000)
        let authority = try await config.resolveAuthority(for: stale, lease: lease)
        XCTAssertThrowsError(
            try SMLCommandAdmission.preflight(stale, authority: authority, nowEpoch: 1_000 + 301)
        ) { error in
            XCTAssertEqual(error as? SMLCommandAdmissionError, .commandExpired)
        }
    }
}
