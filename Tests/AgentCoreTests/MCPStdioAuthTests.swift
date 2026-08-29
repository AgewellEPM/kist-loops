import XCTest
@testable import AgentCore

final class MCPStdioAuthTests: XCTestCase {
    func testToolCallAddsConfiguredBearerToken() {
        let config = MCPServerConfig(
            name: "fca",
            command: "/bin/true",
            env: ["FCA_MCP_AUTH_TOKEN": "test-secret"]
        )

        let params = MCPServerConnection.toolCallParams(
            name: "agent_run",
            arguments: ["prompt": "hello"],
            config: config
        )
        let metadata = params["_meta"] as? [String: String]

        XCTAssertEqual(metadata?["authorization"], "Bearer test-secret")
    }

    func testToolCallOmitsAuthorizationWithoutToken() {
        let config = MCPServerConfig(name: "other", command: "/bin/true")

        let params = MCPServerConnection.toolCallParams(
            name: "tool",
            arguments: [:],
            config: config
        )

        XCTAssertNil(params["_meta"])
    }

    func testHostCorrelationIsSiblingMetadataPreservingFCAAuthAndIgnoringArgumentSpoof() throws {
        let mission = String(repeating: "a", count: 64)
        let forged = String(repeating: "b", count: 64)
        let config = MCPServerConfig(
            name: "fca", command: "/bin/true",
            env: ["FCA_MCP_AUTH_TOKEN": "test-secret"])
        let arguments: [String: Any] = [
            "_meta": [MCPProtocol.correlationMetadataKey: forged],
            MCPProtocol.correlationMetadataKey: forged,
        ]

        let params = MCPServerConnection.toolCallParams(
            name: "agent_run", arguments: arguments, config: config,
            correlationID: mission)
        let metadata = try XCTUnwrap(params["_meta"] as? [String: String])
        let forwardedArguments = try XCTUnwrap(params["arguments"] as? [String: Any])

        XCTAssertEqual(metadata["authorization"], "Bearer test-secret")
        XCTAssertEqual(metadata[MCPProtocol.correlationMetadataKey], mission)
        XCTAssertEqual(forwardedArguments[MCPProtocol.correlationMetadataKey] as? String, forged)
        XCTAssertNotEqual(metadata[MCPProtocol.correlationMetadataKey], forged)
    }

    func testInvalidHostCorrelationIsOmitted() {
        let params = MCPServerConnection.toolCallParams(
            name: "tool", arguments: [:],
            config: MCPServerConfig(name: "other", command: "/bin/true"),
            correlationID: "model-controlled-not-a-mission")
        XCTAssertNil(params["_meta"])
    }
}
