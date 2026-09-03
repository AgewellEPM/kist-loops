import XCTest
@testable import Kist
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The P3 milestone live-fire: spawns the REAL kist binary in `--sml-runtime-serve` mode against
/// a fixture project and drives the whole approve-everything loop over loopback HTTP — a
/// CALL_TOOL workflow parks at its injected gate, `GET /approvals` names it with the exact
/// revision, approving with a stale revision is refused, approving with the right revision
/// dispatches the REAL list_files tool exactly once (receipts prove it), and SIGTERM shuts the
/// host down cleanly, releasing the lock and preserving state for a durable one-shot follow-up.
final class KistSMLRuntimeServeTests: XCTestCase {
    private var projectRoot: URL!
    private var serveProcess: Process?

    private var kistExecutableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KistTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent(".build/debug/kist")
    }

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: kistExecutableURL.path) else {
            throw XCTSkip("kist executable is not present in the SwiftPM products directory")
        }
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-serve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        projectRoot = URL(fileURLWithPath: raw.resolvingSymlinksInPath().path, isDirectory: true)
        try writeFixtures()
    }

    override func tearDownWithError() throws {
        if let process = serveProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: projectRoot)
    }

    private func writeFixtures() throws {
        // A workflow whose single external step lists the project directory through the REAL
        // headless list_files tool, then emits a receipt from the tool's output field.
        try """
        {
          "ir_version": 1,
          "id": "serve.listing",
          "version": "1.0.0",
          "name": "Serve listing",
          "source": {"kind": "native", "reference": "tests://serve"},
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
        """.write(to: projectRoot.appendingPathComponent("wf.json"),
                  atomically: true, encoding: .utf8)

        let smlDir = projectRoot.appendingPathComponent(".kist/sml", isDirectory: true)
        try FileManager.default.createDirectory(at: smlDir, withIntermediateDirectories: true)
        let authority = """
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
        """
        let authorityURL = smlDir.appendingPathComponent("authority.json")
        try authority.write(to: authorityURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: authorityURL.path
        )
        try """
        {
          "schema_version": 1,
          "tool_capabilities": ["list_files"],
          "approval_authorities": ["host-operator"]
        }
        """.write(to: smlDir.appendingPathComponent("catalog.json"),
                  atomically: true, encoding: .utf8)
    }

    // MARK: - HTTP helpers

    private func requestJSON(
        _ method: String,
        _ url: URL,
        token: String,
        body: [String: Any]? = nil
    ) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, object)
    }

    private func reserveLoopbackPort() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServeSocketTestError.socket }
        var shouldClose = true
        defer { if shouldClose { _ = close(descriptor) } }
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0,
              fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw ServeSocketTestError.closeOnExec
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            throw ServeSocketTestError.bind
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { throw ServeSocketTestError.getsockname }
        shouldClose = false
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }

    // MARK: - The milestone

    func testServeModeRunsTheFullApproveEverythingLoopEndToEnd() async throws {
        let reservation = try reserveLoopbackPort()
        let port = reservation.port
        _ = close(reservation.descriptor)
        let process = Process()
        process.executableURL = kistExecutableURL
        process.arguments = [
            "--sml-runtime-serve", "wf.json",
            "--sml-port", String(port),
            "--project", projectRoot.path,
        ]
        process.currentDirectoryURL = projectRoot
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        serveProcess = process

        // Wait for the host to announce readiness (bounded).
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let tokenURL = projectRoot.appendingPathComponent(".kist/sml/serve/session-token")
        var token: String?
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: tokenURL),
               let candidate = String(data: data, encoding: .utf8), !candidate.isEmpty {
                var probe = URLRequest(url: base.appendingPathComponent("approvals"))
                probe.setValue("Bearer \(candidate)", forHTTPHeaderField: "Authorization")
                if let (_, response) = try? await URLSession.shared.data(for: probe),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    token = candidate
                    break
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let token else {
            let output = String(
                decoding: stdout.fileHandleForReading.availableData, as: UTF8.self
            )
            return XCTFail("serve host never became ready; output: \(output)")
        }

        // 1) Start a task: it must park at the injected approval gate, NOT execute.
        let start = try await requestJSON(
            "POST",
            base.appendingPathComponent("sml/workflows/serve.listing/tasks"),
            token: token,
            body: ["task_id": "TASK-SERVE-1"]
        )
        XCTAssertEqual(start.0, 201, "workflow.run must create the task: \(start.1)")

        let pending = try await requestJSON(
            "GET", base.appendingPathComponent("approvals"), token: token
        )
        let approvals = pending.1["approvals"] as? [[String: Any]] ?? []
        XCTAssertEqual(approvals.count, 1, "the task must be pending approval: \(pending.1)")
        let approval = approvals[0]
        XCTAssertEqual(approval["task_id"] as? String, "TASK-SERVE-1")
        XCTAssertEqual(approval["guarded_instruction_id"] as? String, "list")
        let revision = approval["task_revision"] as? Int ?? -1
        XCTAssertGreaterThanOrEqual(revision, 1)

        // 2) Stale revision must be refused — and the task must stay parked.
        let stale = try await requestJSON(
            "POST",
            base.appendingPathComponent("sml/workflows/serve.listing/tasks/TASK-SERVE-1/approve"),
            token: token,
            body: ["task_revision": revision + 7]
        )
        XCTAssertTrue([409, 422].contains(stale.0),
                      "a stale revision must not approve: \(stale.0) \(stale.1)")

        // 3) Correct revision approves; the pump dispatches the REAL tool; task completes.
        let approve = try await requestJSON(
            "POST",
            base.appendingPathComponent("sml/workflows/serve.listing/tasks/TASK-SERVE-1/approve"),
            token: token,
            body: ["task_revision": revision]
        )
        XCTAssertEqual(approve.0, 200, "approve must succeed: \(approve.1)")

        var completed = false
        var lastWatch: [String: Any] = [:]
        for _ in 0..<50 {
            let watch = try await requestJSON(
                "GET",
                base.appendingPathComponent("sml/workflows/serve.listing/tasks/TASK-SERVE-1"),
                token: token
            )
            lastWatch = watch.1
            if let result = watch.1["result"] as? [String: Any],
               let task = result["task"] as? [String: Any],
               task["status"] as? String == "completed" {
                completed = true
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(completed, "the approved task must complete: \(lastWatch)")

        // 4) Receipts prove EXACTLY ONE dispatch of the real tool.
        let receipts = try await requestJSON(
            "GET",
            base.appendingPathComponent(
                "sml/workflows/serve.listing/tasks/TASK-SERVE-1/receipts"
            ),
            token: token
        )
        let receiptList = ((receipts.1["result"] as? [String: Any])?["receipts"]
                           as? [[String: Any]]) ?? []
        let kinds = receiptList.compactMap { $0["kind"] as? String }
        XCTAssertEqual(kinds.filter { $0 == "capability_claimed" }.count, 1,
                       "exactly one capability claim: \(kinds)")
        XCTAssertEqual(kinds.filter { $0 == "step_recorded" }.count, 1,
                       "exactly one recorded step: \(kinds)")
        XCTAssertTrue(kinds.contains("approved"))
        // The workflow's terminal instruction is EMIT_RECEIPT, so the terminal receipt kind is
        // receipt_emitted (COMPLETE would mint "completed"); the completed STATUS was asserted
        // via watch above.
        XCTAssertTrue(kinds.contains("receipt_emitted"), "terminal receipt: \(kinds)")

        let auditURL = projectRoot.appendingPathComponent(".kist/audit/tools.jsonl")
        let auditLines = try String(contentsOf: auditURL, encoding: .utf8)
            .split(separator: "\n")
        let auditEntries = try auditLines.map {
            try JSONDecoder().decode(AuditEntry.self, from: Data($0.utf8))
        }
        XCTAssertEqual(auditEntries.map(\.tool), ["list_files"])
        XCTAssertEqual(auditEntries.map(\.outcome), ["ok"])
        XCTAssertEqual(auditEntries.map(\.success), [true])
        XCTAssertEqual(auditEntries.first?.argKeys, ["path"])

        // 5) Graceful shutdown releases the lock and preserves state for the next host.
        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       "SIGTERM must drain and exit 0")
        serveProcess = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenURL.path),
                       "normal shutdown must remove the per-session bearer credential")

        let store = SMLRuntimeStore(
            fileURL: projectRoot.appendingPathComponent(".kist/sml/runtime.json")
        )
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.tasks["TASK-SERVE-1"]?.status, .completed,
                       "state must survive the host")
        let lockEnvironment = try await SMLRuntimeDurableHostEnvironment.acquire(
            projectRoot: projectRoot.path
        )
        lockEnvironment.lock.release()
    }

    func testOccupiedPortFailsClosedAndCleansTokenAndHostLock() async throws {
        let reservation = try reserveLoopbackPort()
        defer { _ = close(reservation.descriptor) }
        let process = Process()
        process.executableURL = kistExecutableURL
        process.arguments = [
            "--sml-runtime-serve", "wf.json",
            "--sml-port", String(reservation.port),
            "--project", projectRoot.path,
        ]
        process.currentDirectoryURL = projectRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 2)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(text.contains("no free loopback port"), "unexpected output: \(text)")

        let tokenURL = projectRoot.appendingPathComponent(".kist/sml/serve/session-token")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenURL.path),
                       "failed startup must revoke the minted session secret")
        let environment = try await SMLRuntimeDurableHostEnvironment.acquire(
            projectRoot: projectRoot.path
        )
        environment.lock.release()
    }
}

private enum ServeSocketTestError: Error {
    case socket
    case closeOnExec
    case bind
    case getsockname
}
