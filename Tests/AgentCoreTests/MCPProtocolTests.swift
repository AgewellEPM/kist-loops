import XCTest
@testable import AgentCore

/// MCP spec currency: kist must OFFER the current protocol version but HONOR whatever the server
/// negotiates back — that read-back is exactly what makes offering a newer version safe for downlevel
/// servers (jeeves-floor, perslis). Both transports route their handshake through these helpers, so
/// pinning them here pins the behavior for stdio AND HTTP.
final class MCPProtocolTests: XCTestCase {

    func testOfferedVersionIsTheLatestImplementedByDefault() {
        // Absent an env override, kist offers the latest revision it actually implements (the stateful
        // handshake) — 2025-06-18. It deliberately does NOT advertise 2026-07-28 (stateless), which it
        // does not yet implement: offering a version we don't speak is a protocol lie.
        if ProcessInfo.processInfo.environment["KIST_MCP_PROTOCOL_VERSION"] == nil {
            XCTAssertEqual(MCPProtocol.offeredVersion, "2025-06-18")
        }
        XCTAssertFalse(MCPProtocol.offeredVersion.isEmpty)
    }

    func testInitializeParamsCarryOfferedVersionAndClientIdentity() {
        let p = MCPProtocol.initializeParams()
        XCTAssertEqual(p["protocolVersion"] as? String, MCPProtocol.offeredVersion)
        let client = p["clientInfo"] as? [String: String]
        XCTAssertEqual(client?["name"], "kist")
        XCTAssertNotNil(p["capabilities"])
    }

    func testDownlevelServerVersionIsHonored() {
        // A server that answers with an older revision → we adopt it (negotiation, not a hard fail).
        let v = MCPProtocol.negotiatedVersion(from: ["protocolVersion": "2025-03-26"])
        XCTAssertEqual(v, "2025-03-26")
    }

    func testMissingOrEmptyServerVersionFallsBackToOffered() {
        XCTAssertEqual(MCPProtocol.negotiatedVersion(from: [:]), MCPProtocol.offeredVersion)
        XCTAssertEqual(MCPProtocol.negotiatedVersion(from: ["protocolVersion": ""]), MCPProtocol.offeredVersion)
    }

    func testVersionHeaderNameMatchesSpec() {
        XCTAssertEqual(MCPProtocol.versionHeader, "MCP-Protocol-Version")
    }
}
