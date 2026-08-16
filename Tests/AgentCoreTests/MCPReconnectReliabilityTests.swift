import Foundation
import XCTest
@testable import AgentCore

final class MCPReconnectReliabilityTests: XCTestCase {
    func testDeadCachedConnectionIsReplacedBeforeNextCall() async throws {
        let config = MCPServerConfig(name: "retry", command: "/bin/sh", args: [], env: [:])
        let factory = ReconnectFactory(startOutcomes: [true, true])
        let sleeps = ReconnectSleepRecorder()
        let manager = MCPClientManager(serversForTesting: [config],
            connectionFactory: { factory.make($0) },
            reconnectDelaysNanoseconds: [1, 2, 4, 8, 16],
            retrySleep: { await sleeps.record($0) })
        _ = await manager.discoverAndWrapTools(projectRoot: "/tmp")
        let first = try XCTUnwrap(factory.connection(at: 0))
        await first.kill()
        let result = await manager.call(server: "retry", tool: "echo", arguments: [:])
        let recordedSleeps = await sleeps.snapshot()
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(factory.creationCount, 2)
        XCTAssertEqual(recordedSleeps, [1])
        await manager.shutdownAll()
    }

    func testReconnectStopsAfterFiveBackoffAttempts() async throws {
        let config = MCPServerConfig(name: "retry", command: "/bin/sh", args: [], env: [:])
        let factory = ReconnectFactory(startOutcomes: [true, false, false, false, false, false])
        let sleeps = ReconnectSleepRecorder()
        let manager = MCPClientManager(serversForTesting: [config],
            connectionFactory: { factory.make($0) },
            reconnectDelaysNanoseconds: [1, 2, 4, 8, 16],
            retrySleep: { await sleeps.record($0) })
        _ = await manager.discoverAndWrapTools(projectRoot: "/tmp")
        let first = try XCTUnwrap(factory.connection(at: 0))
        await first.kill()
        let result = await manager.call(server: "retry", tool: "echo", arguments: [:])
        let recordedSleeps = await sleeps.snapshot()
        XCTAssertFalse(result.success)
        XCTAssertEqual(factory.creationCount, 6)
        XCTAssertEqual(recordedSleeps, [1, 2, 4, 8, 16])
        await manager.shutdownAll()
    }

    func testHTTPMissingOrScalarResultFailsClosed() {
        XCTAssertThrowsError(try MCPHTTPConnection.requiredResult(from: ["jsonrpc": "2.0", "id": 7], id: 7))
        XCTAssertThrowsError(try MCPHTTPConnection.requiredResult(from: ["result": "not-an-object"], id: 7))
        XCTAssertNoThrow(try MCPHTTPConnection.requiredResult(from: ["result": ["ok": true]], id: 7))
    }
}

private actor ReconnectSleepRecorder {
    private var values: [UInt64] = []
    func record(_ value: UInt64) { values.append(value) }
    func snapshot() -> [UInt64] { values }
}

private final class ReconnectFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let startOutcomes: [Bool]
    private var connections: [ReconnectTestConnection] = []
    init(startOutcomes: [Bool]) { self.startOutcomes = startOutcomes }
    func make(_ config: MCPServerConfig) -> any MCPConnection {
        lock.lock()
        let index = connections.count
        let succeeds = index < startOutcomes.count ? startOutcomes[index] : false
        let connection = ReconnectTestConnection(config: config, startSucceeds: succeeds)
        connections.append(connection)
        lock.unlock()
        return connection
    }
    var creationCount: Int { lock.lock(); defer { lock.unlock() }; return connections.count }
    func connection(at index: Int) -> ReconnectTestConnection? {
        lock.lock(); defer { lock.unlock() }
        return connections.indices.contains(index) ? connections[index] : nil
    }
}

private actor ReconnectTestConnection: MCPConnection {
    let config: MCPServerConfig
    private let startSucceeds: Bool
    private var alive = false
    init(config: MCPServerConfig, startSucceeds: Bool) {
        self.config = config; self.startSucceeds = startSucceeds
    }
    var isAlive: Bool { alive }
    func start() async throws {
        guard startSucceeds else { throw MCPConnectionError.serverClosed }
        alive = true
    }
    func listTools() async throws -> [RemoteToolSpec] {
        [RemoteToolSpec(name: "echo", description: "echo", inputSchema: [:])]
    }
    func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard alive else { throw MCPConnectionError.serverClosed }
        return ["content": [["type": "text", "text": "ok"]]]
    }
    func shutdown() async { alive = false }
    func kill() { alive = false }
}
