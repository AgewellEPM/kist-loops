import XCTest
import AgentCore
@testable import ConnectorKit

final class ConnectorManifestTests: XCTestCase {
    func testManifestRoundTripsWithAuthByEnvReference() throws {
        let m = ConnectorManifest(
            name: "scribe", baseURL: "https://api.example/v1",
            auth: .bearerEnv("SCRIBE_API_KEY"),
            actions: [ConnectorAction(name: "get", method: "get", path: "/documents/{id}")])
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ConnectorManifest.self, from: data)
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.actions.first?.method, "GET", "method is normalized upper-case")
        // The token itself is NEVER in the manifest — only the env var name.
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("Bearer"))
    }
}

final class RESTConnectorTests: XCTestCase {
    private func connector(auth: ConnectorManifest.Auth, env: [String: String] = [:],
                           baseURL: String = "https://api.example/v1", insecure: Bool = false) -> RESTConnector {
        let m = ConnectorManifest(name: "c", baseURL: baseURL, auth: auth,
            actions: [ConnectorAction(name: "get_doc", method: "GET", path: "/documents/{id}"),
                      ConnectorAction(name: "make", method: "POST", path: "/documents")],
            allowInsecureHTTP: insecure)
        return RESTConnector(manifest: m, env: env)
    }

    func testUnknownActionThrows() {
        let c = connector(auth: .none)
        XCTAssertThrowsError(try c.buildRequest(action: "nope", input: [:])) { e in
            guard case ConnectorError.unknownAction = e else { return XCTFail("\(e)") }
        }
    }

    func testMissingAuthEnvThrowsFailClosed() {
        let c = connector(auth: .bearerEnv("SCRIBE_API_KEY"), env: [:])  // env var unset
        XCTAssertThrowsError(try c.buildRequest(action: "get_doc", input: ["id": "1"])) { e in
            guard case ConnectorError.authMissing = e else { return XCTFail("\(e)") }
        }
    }

    func testInsecureURLRefusedUnlessAllowed() {
        let http = connector(auth: .none, baseURL: "http://api.example/v1")
        XCTAssertThrowsError(try http.buildRequest(action: "get_doc", input: ["id": "1"])) { e in
            guard case ConnectorError.insecureURL = e else { return XCTFail("\(e)") }
        }
        let allowed = connector(auth: .none, baseURL: "http://localhost/v1", insecure: true)
        XCTAssertNoThrow(try allowed.buildRequest(action: "get_doc", input: ["id": "1"]))
    }

    func testPathParamsFilledAndAuthHeaderSetWithoutLeakingToken() throws {
        let c = connector(auth: .bearerEnv("TOK"), env: ["TOK": "secret-123"])
        let (req, summary) = try c.buildRequest(action: "get_doc", input: ["id": "abc"])
        XCTAssertEqual(req.url?.absoluteString, "https://api.example/v1/documents/abc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer secret-123")
        // The redacted summary references only the env var, never the token value.
        XCTAssertEqual(summary, "bearer($TOK)")
        XCTAssertFalse(summary.contains("secret-123"))
    }
}

final class AutoTunerTests: XCTestCase {
    func testBacksOffWhenFailing() {
        let t = AutoTuner()
        let start = ConnectorLevel(concurrency: 4, retries: 1, backoffMs: 250)
        let after = t.adjust(start, errorRate: 0.5, p50ms: 1200)
        XCTAssertEqual(after.concurrency, 3)
        XCTAssertGreaterThan(after.backoffMs, start.backoffMs)
        XCTAssertEqual(after.retries, 2)
    }

    func testScalesUpWhenHealthy() {
        let t = AutoTuner(maxConcurrency: 8)
        let after = t.adjust(ConnectorLevel(concurrency: 2, retries: 1, backoffMs: 400), errorRate: 0.0, p50ms: 100)
        XCTAssertEqual(after.concurrency, 3)
        XCTAssertLessThan(after.backoffMs, 400)
    }

    func testStaysBoundedAtExtremes() {
        let t = AutoTuner(minConcurrency: 1, maxConcurrency: 4)
        var lo = ConnectorLevel(concurrency: 1, retries: 5, backoffMs: 8000)
        lo = t.adjust(lo, errorRate: 0.9, p50ms: 5000)
        XCTAssertGreaterThanOrEqual(lo.concurrency, 1)
        XCTAssertLessThanOrEqual(lo.backoffMs, 8000)
        var hi = ConnectorLevel(concurrency: 4, retries: 0, backoffMs: 100)
        hi = t.adjust(hi, errorRate: 0.0, p50ms: 50)
        XCTAssertLessThanOrEqual(hi.concurrency, 4)
    }
}

final class ConnectorAuditTests: XCTestCase {
    override func setUp() { super.setUp(); ForgeSeal.forceEphemeralKeyForTesting() }
    override func tearDown() { ForgeSeal.resetCacheForTesting(); super.tearDown() }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("caudit-\(UUID().uuidString).jsonl")
    }

    func testInputHashDistinguishesEmbeddedFieldSeparators() {
        XCTAssertNotEqual(ConnectorAudit.hashInput(["a": "1&b=2"]),
                          ConnectorAudit.hashInput(["a": "1", "b": "2"]))
        XCTAssertEqual(ConnectorAudit.hashInput(["a": "1", "b": "2"]),
                       ConnectorAudit.hashInput(["b": "2", "a": "1"]))
    }

    func testConcurrentRecordsPreserveOneCompleteSequence() async throws {
        let url = tempFile()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let audit = ConnectorAudit(fileURL: url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    _ = try audit.record(connector: "c", action: "a", input: ["id": String(index)],
                                     statusCode: 200, ok: true, atEpoch: Double(index))
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(audit.entries().map(\.seq), Array(0..<16))
        XCTAssertNil(audit.verifyChain())
    }

    struct FixtureConnector: Connector {
        let name = "fixture"
        let handler: @Sendable () async throws -> ConnectorResult
        func actions() -> [ConnectorAction] { [] }
        func invoke(action: String, input: [String: String]) async throws -> ConnectorResult { try await handler() }
    }

    func testAuditedInvocationPersistsIntentBeforeCallingAndResultAfterward() async throws {
        let url = tempFile()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let audit = ConnectorAudit(fileURL: url)
        let connector = FixtureConnector {
            XCTAssertEqual(audit.entries().map(\.phase), ["started"])
            return ConnectorResult(statusCode: 201, body: "created")
        }
        let result = try await AuditedConnector(connector, audit: audit).invoke(action: "create", input: [:])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(audit.entries().map(\.phase), ["started", "completed"])
    }

    func testConcurrentIdenticalInvocationsHaveDistinctIntentResultPairs() async throws {
        let url = tempFile()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let audit = ConnectorAudit(fileURL: url)
        let fixture = FixtureConnector {
            try await Task.sleep(nanoseconds: 20_000_000)
            return ConnectorResult(statusCode: 201, body: "created")
        }
        let audited = AuditedConnector(fixture, audit: audit)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try await audited.invoke(action: "create", input: ["name": "same"]) }
            }
            try await group.waitForAll()
        }
        let entries = audit.entries()
        XCTAssertEqual(entries.count, 16)
        XCTAssertEqual(Set(entries.map(\.inputHash)).count, 1)
        let invocations = Dictionary(grouping: entries, by: { $0.invocationID ?? "" })
        XCTAssertEqual(invocations.count, 8)
        for (id, pair) in invocations {
            XCTAssertNotNil(UUID(uuidString: id))
            XCTAssertEqual(pair.map(\.phase), ["started", "completed"])
        }
        XCTAssertNil(audit.verifyChain())
    }

    func testUnavailableAuditPreventsInvocation() async {
        let audit = ConnectorAudit(fileURL: tempFile().appendingPathComponent("missing/audit.jsonl"))
        let connector = FixtureConnector {
            XCTFail("connector must not run without a saved intent")
            return ConnectorResult(statusCode: 200, body: "")
        }
        do {
            _ = try await AuditedConnector(connector, audit: audit).invoke(action: "create", input: [:])
            XCTFail("missing audit destination must fail")
        } catch { }
    }

    func testSealedChainAndSecretRedaction() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        let audit = ConnectorAudit(fileURL: url)
        try audit.record(connector: "scribe", action: "get_doc", input: ["id": "1", "token": "SECRET"],
                         statusCode: 200, ok: true, atEpoch: 1)
        try audit.record(connector: "scribe", action: "make", input: ["title": "x"],
                         statusCode: 201, ok: true, atEpoch: 2)
        XCTAssertEqual(audit.entries().count, 2)
        XCTAssertNil(audit.verifyChain(), "chain intact")
        // The raw secret never appears on disk — only its hash.
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("SECRET"), "input values must not be stored raw")
    }

    func testTamperBreaksTheChain() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        let audit = ConnectorAudit(fileURL: url)
        try audit.record(connector: "c", action: "a", input: [:], statusCode: 500, ok: false, atEpoch: 1)
        // Flip ok=false→ok=true on disk without re-sealing.
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"ok\":false", with: "\"ok\":true")
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(audit.verifyChain(), 0, "tampered entry breaks the seal")
        XCTAssertEqual(audit.entries().count, 0)
        XCTAssertThrowsError(try audit.record(connector: "c", action: "a", input: [:], statusCode: 200, ok: true, atEpoch: 2))
    }
}

final class ConnectorRegistryTests: XCTestCase {
    func testLoadsRESTAndMCPFromDir() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rest = ConnectorManifest(name: "scribe", baseURL: "https://api.example/v1",
            auth: .bearerEnv("K"), actions: [ConnectorAction(name: "g", method: "GET", path: "/x")])
        try JSONEncoder().encode(rest).write(to: dir.appendingPathComponent("scribe.json"))
        let mcp = MCPConnectorRef(name: "fs", server: "mcp-filesystem", tools: ["read_file"])
        try JSONEncoder().encode(mcp).write(to: dir.appendingPathComponent("fs.mcp.json"))

        let reg = ConnectorRegistry.load(fromDir: dir)
        XCTAssertEqual(reg.names, ["fs", "scribe"])
        XCTAssertNotNil(reg.connector("scribe"))
        XCTAssertEqual(reg.mcp["fs"]?.server, "mcp-filesystem")
    }
}
