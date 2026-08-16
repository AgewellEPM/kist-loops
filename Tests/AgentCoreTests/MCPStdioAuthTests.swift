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
}
