import XCTest
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Pins the serve-core building blocks in-process: the pending-view projection (one source of
/// truth for "what needs a human"), the pump's single-flight/no-auto-retry contract, and the
/// HTTP core's fail-closed auth + loopback binding.
final class SMLRuntimeServeCoreTests: XCTestCase {
    // MARK: - Pending view

    func testPendingViewProjectsApprovalsCapabilitiesAndStuckClaims() throws {
        let workflow = SMLWorkflow(
            id: "view.wf",
            version: "1.0.0",
            name: "View",
            source: .init(kind: .native, reference: "tests://view"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            interface: .init(),
            entrypoint: "gate-tool",
            instructions: [
                .init(id: "gate-tool", op: .waitApproval, reason: "approve tool",
                      owner: "host-operator", next: "tool", onFailure: "refused"),
                .init(id: "tool", op: .callTool, capability: "cap.a", next: "done"),
                .init(id: "refused", op: .escalate, reason: "refused", owner: "host-operator"),
                .init(id: "done", op: .complete),
            ]
        )
        let key = SMLRuntimeSnapshot.workflowStorageKey(id: "view.wf", version: "1.0.0")
        var snapshot = SMLRuntimeSnapshot(
            workflows: [key: SMLRuntimeWorkflowRecord(
                role: "workflow-agent", workflow: workflow, installedAtEpoch: 1_000
            )],
            activeWorkflowVersions: ["view.wf": "1.0.0"],
            tasks: [:],
            receipts: [:],
            replayClaims: [:]
        )
        snapshot.tasks["TASK-A"] = SMLRuntimeTask(
            taskID: "TASK-A", role: "workflow-agent", workflowID: "view.wf",
            workflowVersion: "1.0.0", revision: 2, currentInstructionID: "gate-tool",
            status: .waitingApproval, createdAtEpoch: 1_000, updatedAtEpoch: 1_005,
            waitingApprovalOwner: "host-operator"
        )
        snapshot.tasks["TASK-B"] = SMLRuntimeTask(
            taskID: "TASK-B", role: "workflow-agent", workflowID: "view.wf",
            workflowVersion: "1.0.0", revision: 4, currentInstructionID: "tool",
            status: .waitingCapability, createdAtEpoch: 1_000, updatedAtEpoch: 1_006
        )
        snapshot.tasks["TASK-C"] = SMLRuntimeTask(
            taskID: "TASK-C", role: "workflow-agent", workflowID: "view.wf",
            workflowVersion: "1.0.0", revision: 6, currentInstructionID: "tool",
            status: .waitingCapability, createdAtEpoch: 1_000, updatedAtEpoch: 1_007,
            capabilityClaim: SMLCapabilityClaimRecord(
                dispatchID: "dispatch-9", driverID: "kist-tool-driver",
                instructionID: "tool", stateDigest: String(repeating: "e", count: 64),
                commandID: "claim-9", actor: "op", leaseID: "lease-9", claimedAtEpoch: 1_006
            )
        )
        snapshot.tasks["TASK-DONE"] = SMLRuntimeTask(
            taskID: "TASK-DONE", role: "workflow-agent", workflowID: "view.wf",
            workflowVersion: "1.0.0", revision: 8, currentInstructionID: "done",
            status: .completed, createdAtEpoch: 1_000, updatedAtEpoch: 1_008
        )

        let view = SMLRuntimePendingView.build(from: snapshot)
        XCTAssertEqual(view.approvals.map(\.taskID), ["TASK-A"])
        XCTAssertEqual(view.approvals.first?.taskRevision, 2,
                       "the projection must carry the exact revision an approve must pin")
        XCTAssertEqual(view.approvals.first?.guardedInstructionID, "tool")
        XCTAssertEqual(view.capabilities.map(\.taskID), ["TASK-B"])
        XCTAssertEqual(view.stuckClaims.map(\.taskID), ["TASK-C"],
                       "a claimed-but-incomplete dispatch is STUCK, never a pump candidate")
        XCTAssertFalse(view.isEmpty)
    }

    // MARK: - Pump

    func testOperatorQueueIncludesOnlyTasksTheActorCanWatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-pending-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workflow = SMLWorkflow(
            id: "queue.wf", version: "1.0.0", name: "Queue",
            source: .init(kind: .native, reference: "tests://queue"),
            trigger: .init(kind: .manual), stateSchema: [], interface: .init(),
            entrypoint: "gate", instructions: [
                .init(id: "gate", op: .waitApproval, reason: "review",
                      owner: "operator", next: "done", onFailure: "refused"),
                .init(id: "done", op: .complete),
                .init(id: "refused", op: .escalate, reason: "refused", owner: "operator"),
            ])
        let registry = try SMLWorkflowRuntimeRegistry.compile(candidateMounts: [
            SMLWorkflowRuntimeCandidateMount(
                workflow: workflow, admissionCatalog: .init(approvalAuthorities: ["operator"]), role: "operator-role",
                actor: "operator.luke", replActions: [], apiBasePath: "/sml", apiWorkflowPath: nil,
                modelMaximumCommandRounds: 4)
        ])
        let store = SMLRuntimeStore(fileURL: directory.appendingPathComponent("runtime.json"))
        let runtime = SMLRuntime(store: store)
        let api = registry.makeAPI(
            gateway: .init(runtime: runtime, replayGuard: store),
            authorityResolver: { command in
                SMLCommandAuthority(
                    authenticatedActor: command.actor, leaseID: "queue-lease",
                    roles: ["operator-role"], tasks: ["TASK-OWNED"],
                    operations: [SMLRuntimeCommandOperation.taskWatch], scope: [:])
            }, clock: { 1_000 })
        var snapshot = SMLRuntimeSnapshot()
        snapshot.workflows[SMLRuntimeSnapshot.workflowStorageKey(id: workflow.id, version: workflow.version)] =
            .init(role: "operator-role", workflow: workflow, installedAtEpoch: 1_000)
        for taskID in ["TASK-OWNED", "TASK-OTHER"] {
            snapshot.tasks[taskID] = SMLRuntimeTask(
                taskID: taskID, role: "operator-role", workflowID: workflow.id,
                workflowVersion: workflow.version, revision: 1, currentInstructionID: "gate",
                status: .waitingApproval, createdAtEpoch: 1_000, updatedAtEpoch: 1_000,
                waitingApprovalOwner: "operator")
        }
        let view = await api.pendingView(from: snapshot)
        XCTAssertEqual(view.approvals.map(\.taskID), ["TASK-OWNED"])
    }

    private actor CountingCoordinatorProbe {
        private(set) var executed: [String] = []
        func record(_ taskID: String) { executed.append(taskID) }
    }

    func testPumpSkipsClaimedTasksAndSurvivesUnapprovedOnes() async throws {
        // Real store + real gated coordinator over an UNGATED workflow: the pump must classify
        // the refusal as skippedUnapproved (expected park) and dispatch nothing.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-pump-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 1_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 1_000 })
        let workflow = SMLWorkflow(
            id: "pump.wf", version: "1.0.0", name: "Pump",
            source: .init(kind: .native, reference: "tests://pump"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            interface: .init(),
            entrypoint: "tool",
            instructions: [
                .init(id: "tool", op: .callTool, capability: "cap.a", next: "done"),
                .init(id: "done", op: .complete),
            ]
        )
        let admitted = try SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(workflow),
            catalog: SMLExecutionAdmissionCatalog(toolCapabilities: ["cap.a"])
        )
        _ = try await runtime.installWorkflow(admitted, role: "operator-role")
        let gateway = SMLCommandGateway(runtime: runtime, replayGuard: store)
        let authority: @Sendable (SMLCommandEnvelope) -> SMLCommandAuthority = { command in
            SMLCommandAuthority(
                authenticatedActor: "operator.luke", leaseID: "lease-1",
                roles: ["operator-role"], tasks: [command.task],
                operations: SMLRuntimeCommandOperation.all, scope: [:]
            )
        }
        let start = SMLCommandEnvelope(
            commandID: "start-pump-1", actor: "operator.luke", role: "operator-role",
            task: "TASK-PUMP", op: SMLRuntimeCommandOperation.workflowRun,
            arguments: [
                "workflow_id": .string("pump.wf"),
                "workflow_version": .string("1.0.0"),
            ],
            issuedAtEpoch: 1_000
        )
        _ = try await gateway.submit(start, authority: authority(start), nowEpoch: 1_000)

        let coordinator = SMLCapabilityCoordinator(
            runtime: runtime,
            router: SMLCapabilityRouter(drivers: []),
            claimCompiler: SMLCapabilityClaimCompiler(
                actor: "operator.luke",
                commandID: { "claim-\(UUID().uuidString.lowercased())" },
                dispatchID: { "dispatch-\(UUID().uuidString.lowercased())" }
            ),
            completionCompiler: SMLCapabilityCompletionCompiler(
                actor: "operator.luke",
                commandID: { "complete-\(UUID().uuidString.lowercased())" }
            ),
            gateway: gateway,
            authorityResolver: { authority($0) },
            clock: { 1_000 }
        )
        let pump = SMLRuntimeCapabilityPump(
            store: store,
            coordinator: SMLApprovalGatedCoordinator(coordinator: coordinator, store: store)
        )
        let report = await pump.drain()
        XCTAssertEqual(report.dispatched, [])
        XCTAssertEqual(report.skippedUnapproved, ["TASK-PUMP"],
                       "an ungated/unapproved task is an expected park, not a pump failure")
        XCTAssertEqual(report.failed, [:])
    }

    // MARK: - HTTP core

    private func makeServableHost(
        directory: URL,
        configuration: SMLRuntimeHTTPCore.Configuration = .init(
            portRange: 18_850...18_899
        ),
        admissionLimits: SMLRuntimeAdmissionLimits = .init()
    ) async throws -> (core: SMLRuntimeHTTPCore, token: String) {
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 1_000 }, admissionLimits: admissionLimits
        )
        let runtime = SMLRuntime(store: store, clock: { 1_000 })
        let workflow = SMLWorkflow(
            id: "http.wf", version: "1.0.0", name: "HTTP",
            source: .init(kind: .native, reference: "tests://http"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            interface: .init(),
            entrypoint: "done",
            instructions: [.init(id: "done", op: .complete)]
        )
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            candidateMounts: [SMLWorkflowRuntimeCandidateMount(
                workflow: workflow,
                admissionCatalog: SMLExecutionAdmissionCatalog(),
                role: "workflow-agent",
                actor: "sml-runtime-exporter",
                apiBasePath: "/sml",
                apiWorkflowPath: nil,
                modelMaximumCommandRounds: 4
            )],
            commandID: { "cmd-\(UUID().uuidString.lowercased())" },
            taskID: { "TASK-\(UUID().uuidString.lowercased().prefix(8))" }
        )
        let authority: SMLWorkflowRuntimeAPI.AuthorityResolver = { command in
            SMLCommandAuthority(
                authenticatedActor: command.actor, leaseID: "lease-http",
                roles: [command.role], tasks: [command.task],
                operations: SMLRuntimeCommandOperation.all, scope: [:]
            )
        }
        let launch = try await SMLWorkflowRuntimeApp.launch(
            registry: registry,
            runtime: runtime,
            replayGuard: store,
            authorityResolver: authority,
            clock: { 1_000 }
        )
        _ = launch
        let api = registry.makeAPI(
            gateway: SMLCommandGateway(runtime: runtime, replayGuard: store),
            authorityResolver: authority,
            clock: { 1_000 }
        )
        let token = try SMLRuntimeHTTPCore.mintSessionToken(
            writingTo: directory.appendingPathComponent("session-token")
        )
        let core = SMLRuntimeHTTPCore(
            api: api, store: store, pump: nil, sessionToken: token,
            configuration: configuration
        )
        return (core, token)
    }

    private func httpGet(
        _ url: URL, token: String?
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    private func rawHTTPRequest(
        port: UInt16,
        request: String,
        shutdownWrite: Bool = true
    ) throws -> (status: Int, headers: String, body: Data) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXTestError(operation: "socket") }
        defer { _ = close(descriptor) }

        var timeout = timeval()
        timeout.tv_sec = 2
        timeout.tv_usec = 0
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO,
            &timeout, socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw POSIXTestError(operation: "setsockopt")
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXTestError(operation: "connect") }

        let bytes = Data(request.utf8)
        let sent = bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let count = write(
                    descriptor, base.advanced(by: offset), raw.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        guard sent else { throw POSIXTestError(operation: "write") }
        if shutdownWrite { _ = shutdown(descriptor, SHUT_WR) }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                response.append(contentsOf: buffer[0..<count])
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)) else {
            throw POSIXTestError(operation: "parse response")
        }
        let headers = String(
            decoding: response[..<separator.lowerBound], as: UTF8.self
        )
        let status = headers.split(separator: "\r\n").first?
            .split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? -1
        return (status, headers, Data(response[separator.upperBound...]))
    }

    func testHTTPCoreRequiresTheSessionTokenAndServesApprovalsAndCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-http-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let (core, token) = try await makeServableHost(directory: directory)
        guard let base = core.start() else {
            return XCTFail("no free loopback test port")
        }
        defer { core.stop() }

        // 401 without / with a wrong token — no route is unauthenticated.
        let (unauthorized, _) = try await httpGet(
            base.appendingPathComponent("approvals"), token: nil
        )
        XCTAssertEqual(unauthorized, 401)
        let (badToken, _) = try await httpGet(
            base.appendingPathComponent("approvals"), token: "not-the-token"
        )
        XCTAssertEqual(badToken, 401)

        // Authenticated pending view (empty) and a generated metadata route.
        let (approvalsStatus, approvalsBody) = try await httpGet(
            base.appendingPathComponent("approvals"), token: token
        )
        XCTAssertEqual(approvalsStatus, 200)
        let view = try JSONDecoder().decode(SMLRuntimePendingView.self, from: approvalsBody)
        XCTAssertTrue(view.isEmpty)

        let (healthStatus, healthBody) = try await httpGet(
            base.appendingPathComponent("health"), token: token
        )
        XCTAssertEqual(healthStatus, 200)
        let health = try XCTUnwrap(JSONSerialization.jsonObject(with: healthBody) as? [String: Any])
        XCTAssertEqual(health["status"] as? String, "ready")
        XCTAssertEqual(health["inFlightOrUnresolvedClaimCount"] as? Int, 0)
        let capacity = try XCTUnwrap(health["admission"] as? [String: Any])
        XCTAssertEqual(capacity["acceptingNewTasks"] as? Bool, true)
        let (privateHealth, _) = try await httpGet(base.appendingPathComponent("health"), token: nil)
        XCTAssertEqual(privateHealth, 401)

        let (catalogStatus, catalogBody) = try await httpGet(
            base.appendingPathComponent("sml/runtime/catalog"), token: token
        )
        XCTAssertEqual(catalogStatus, 200)
        XCTAssertTrue(
            String(decoding: catalogBody, as: UTF8.self).contains("http.wf"),
            "the generated runtime catalog must be served"
        )

        // Unknown routes are 404, not crashes.
        let (missingStatus, _) = try await httpGet(
            base.appendingPathComponent("nope"), token: token
        )
        XCTAssertEqual(missingStatus, 404)

        core.stop()
        XCTAssertEqual(core.port, 0, "a stopped core must not advertise a stale port")
        XCTAssertNil(core.start(), "an HTTP core owns exactly one session token and is single-use")
    }

    func testHTTPAdmissionBackpressureKeepsStatusAvailableAndReturnsRetryAfter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sml-http-capacity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (core, token) = try await makeServableHost(directory: directory,
            admissionLimits: .init(maximumHotTasks: 1))
        guard let base = core.start() else { return XCTFail("no free loopback test port") }
        defer { core.stop() }
        func start(_ id: String) throws -> (status: Int, headers: String, body: Data) {
            let body = "{\"task_id\":\"\(id)\",\"input\":{}}"
            return try rawHTTPRequest(port: core.port, request:
                "POST /sml/workflows/http.wf/tasks HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body)
        }
        XCTAssertTrue((200...299).contains(try start("TASK-ONE").status))
        let full = try start("TASK-TWO")
        XCTAssertEqual(full.status, 503)
        XCTAssertTrue(full.headers.contains("Retry-After: 5"))
        let (status, _) = try await httpGet(base.appendingPathComponent("approvals"), token: token)
        XCTAssertEqual(status, 200)
    }

    func testIncompleteClientDoesNotBlockStatusAndShutdownClosesClients() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-http-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (core, token) = try await makeServableHost(directory: directory, configuration: .init(
            socketTimeoutMilliseconds: 5_000, shutdownGraceMilliseconds: 200,
            maximumConcurrentConnections: 2
        ))
        guard let base = core.start() else { return XCTFail("no free loopback test port") }
        defer { core.stop() }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXTestError(operation: "socket") }
        defer { _ = close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = core.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let partial = Data("GET /approvals HTTP/1.1\r\nHost: localhost\r\n".utf8)
        let sent = partial.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        XCTAssertEqual(sent, partial.count)
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        let (status, _) = try await httpGet(base.appendingPathComponent("approvals"), token: token)
        XCTAssertEqual(status, 200)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5,
                          "an incomplete client must not monopolize the accept loop")
        let stopStart = Date()
        core.stop()
        XCTAssertLessThan(Date().timeIntervalSince(stopStart), 1.5)
        var socketState = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        XCTAssertGreaterThan(poll(&socketState, 1, 500), 0, "stop must close incomplete clients")
        var byte: UInt8 = 0
        XCTAssertEqual(read(descriptor, &byte, 1), 0)
    }

    func testSessionTokenPublicationIsOwnerOnlyAtomicAndDoesNotFollowSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-token-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let privateDirectory = directory.appendingPathComponent("serve", isDirectory: true)
        try FileManager.default.createDirectory(
            at: privateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o777))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o777))],
            ofItemAtPath: privateDirectory.path
        )
        let victim = directory.appendingPathComponent("victim")
        try Data("must-not-change".utf8).write(to: victim)
        let tokenURL = privateDirectory.appendingPathComponent("session-token")
        try FileManager.default.createSymbolicLink(
            at: tokenURL, withDestinationURL: victim
        )

        let first = try SMLRuntimeHTTPCore.mintSessionToken(writingTo: tokenURL)
        XCTAssertEqual(first.count, 64, "the bearer secret must contain 256 random bits")
        XCTAssertEqual(try String(contentsOf: tokenURL, encoding: .utf8), first)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "must-not-change",
                       "publishing a token must replace, never follow, a planted symlink")

        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: privateDirectory.path)[
                .posixPermissions
            ] as? NSNumber
        ).intValue & 0o7777
        let tokenMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: tokenURL.path)[
                .posixPermissions
            ] as? NSNumber
        ).intValue & 0o7777
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(tokenMode, 0o600)

        let second = try SMLRuntimeHTTPCore.mintSessionToken(writingTo: tokenURL)
        XCTAssertNotEqual(first, second, "each host session must rotate the bearer token")
        XCTAssertEqual(try String(contentsOf: tokenURL, encoding: .utf8), second)

        try SMLRuntimeHTTPCore.removeSessionToken(at: tokenURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenURL.path),
                       "normal shutdown must revoke the filesystem bearer credential")
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "must-not-change")
        XCTAssertNoThrow(try SMLRuntimeHTTPCore.removeSessionToken(at: tokenURL),
                         "cleanup is idempotent when the token is already absent")

        try FileManager.default.createSymbolicLink(at: tokenURL, withDestinationURL: victim)
        try SMLRuntimeHTTPCore.removeSessionToken(at: tokenURL)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "must-not-change",
                       "cleanup must unlink, never follow, a replacement symlink")
    }

    func testHTTPCoreRejectsAmbiguousOrUnboundedRequestsAndUsesOpaqueErrors() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-http-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = SMLRuntimeHTTPCore.Configuration(
            portRange: 18_900...18_949,
            maximumHeaderBytes: 1_024,
            maximumBodyBytes: 16,
            socketTimeoutMilliseconds: 150,
            shutdownGraceMilliseconds: 1_000
        )
        let (core, token) = try await makeServableHost(
            directory: directory, configuration: configuration
        )
        guard let base = core.start() else {
            return XCTFail("no free loopback hardening-test port")
        }
        defer { core.stop() }

        let duplicateLength = try rawHTTPRequest(
            port: core.port,
            request: "POST /sml/runtime/catalog HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "Authorization: Bearer \(token)\r\n"
                + "Content-Length: 0\r\n"
                + "Content-Length: 0\r\n\r\n"
        )
        XCTAssertEqual(duplicateLength.status, 400)

        let transferEncoded = try rawHTTPRequest(
            port: core.port,
            request: "POST /sml/runtime/catalog HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "Authorization: Bearer \(token)\r\n"
                + "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        )
        XCTAssertEqual(transferEncoded.status, 400)

        let oversizedBody = try rawHTTPRequest(
            port: core.port,
            request: "POST /sml/runtime/catalog HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "Authorization: Bearer \(token)\r\n"
                + "Content-Length: 17\r\n\r\n"
        )
        XCTAssertEqual(oversizedBody.status, 413)

        let duplicateAuthorization = try rawHTTPRequest(
            port: core.port,
            request: "GET /approvals HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "Authorization: Basic ignored\r\n"
                + "Authorization: Bearer \(token)\r\n\r\n"
        )
        XCTAssertEqual(duplicateAuthorization.status, 400)

        let oversizedHeader = try rawHTTPRequest(
            port: core.port,
            request: "GET /approvals HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "X-Fill: \(String(repeating: "a", count: 1_100))\r\n\r\n"
        )
        XCTAssertEqual(oversizedHeader.status, 431)

        let slowClient = try rawHTTPRequest(
            port: core.port,
            request: "GET /approvals HTTP/1.1\r\nHost: 127.0.0.1",
            shutdownWrite: false
        )
        XCTAssertEqual(slowClient.status, 408)

        let marker = "never-reflect-this-private-route"
        let missing = try rawHTTPRequest(
            port: core.port,
            request: "GET /\(marker) HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "Authorization: Bearer \(token)\r\n\r\n"
        )
        XCTAssertEqual(missing.status, 404)
        XCTAssertFalse(String(decoding: missing.body, as: UTF8.self).contains(marker),
                       "runtime errors returned to clients must not reflect internal route data")
        XCTAssertTrue(missing.headers.contains("Cache-Control: no-store"))
        XCTAssertTrue(missing.headers.contains("Content-Security-Policy: default-src 'none'"))

        XCTAssertEqual(base.host, "127.0.0.1")
    }
}

private struct POSIXTestError: Error, CustomStringConvertible {
    let operation: String
    var description: String {
        "\(operation) failed with errno \(errno)"
    }
}
