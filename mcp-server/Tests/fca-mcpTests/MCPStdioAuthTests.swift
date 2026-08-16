import Foundation
import XCTest
@testable import fca_mcp

/// Regression tests for Codex finding P1-E: a standard stdio MCP client
/// (Claude Code) never negotiates or echoes `_meta.authorization`, so the old
/// policy rejected EVERY `tools/call` — including unconditionally when no token
/// was configured. The fix treats a local stdio connection as trusted-local:
/// a missing `_meta.authorization` is accepted, while any network transport (if
/// one is ever added) still fails closed.
///
/// Per multi-site discipline these assertions name each site explicitly:
///   - the pure `MCPServer.authorize(...)` decision, and
///   - the instance `MCPServer.isAuthorized(params:)` seam that `tools/call`
///     actually calls,
/// so a failure tells you which site regressed without re-running the bug.
final class MCPStdioAuthTests: XCTestCase {
    private func temporaryDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "fca-mcp-stdio-auth-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    // MARK: - Site 1: pure decision, local stdio

    /// THE finding, pinned at the pure decision: local stdio + no token + no
    /// presented authorization must be ACCEPTED (previously rejected).
    func testAuthorize_localStdio_noToken_noAuthorization_isAccepted() {
        XCTAssertTrue(
            MCPServer.authorize(transport: .localStdio, expectedToken: nil, presentedAuthorization: nil),
            "local stdio with no token and no _meta.authorization must be accepted (finding P1-E)"
        )
    }

    /// Setting FCA_MCP_AUTH_TOKEN in the child env must NOT silently break a
    /// standard client that cannot echo it: token configured + nothing presented
    /// is still accepted on local stdio.
    func testAuthorize_localStdio_tokenConfigured_noAuthorization_isAccepted() {
        XCTAssertTrue(
            MCPServer.authorize(transport: .localStdio, expectedToken: "secret-token", presentedAuthorization: nil),
            "local stdio must stay usable even when a token is configured but the client sends nothing"
        )
    }

    /// Defense-in-depth opt-in: a client that DOES present a token still gets it
    /// validated. A correct one is accepted; a wrong one is rejected.
    func testAuthorize_localStdio_tokenConfigured_matchingAndWrongPresented() {
        XCTAssertTrue(
            MCPServer.authorize(transport: .localStdio, expectedToken: "secret-token", presentedAuthorization: "Bearer secret-token"),
            "local stdio with a configured token and a matching presented token must be accepted"
        )
        XCTAssertFalse(
            MCPServer.authorize(transport: .localStdio, expectedToken: "secret-token", presentedAuthorization: "Bearer wrong"),
            "local stdio with a configured token and a WRONG presented token must be rejected"
        )
    }

    // MARK: - Site 2: pure decision, network transport (fails closed)

    /// If a network transport is ever added it must NOT inherit local-trusted
    /// behavior: a missing/nil token or missing/wrong presented token rejects.
    func testAuthorize_network_failsClosed() {
        // No token configured -> reject even if something is presented.
        XCTAssertFalse(
            MCPServer.authorize(transport: .network, expectedToken: nil, presentedAuthorization: "Bearer anything"),
            "network with no configured token must reject"
        )
        // Token configured but nothing presented -> reject.
        XCTAssertFalse(
            MCPServer.authorize(transport: .network, expectedToken: "secret-token", presentedAuthorization: nil),
            "network with a configured token but no presented token must reject"
        )
        // Wrong presented token -> reject.
        XCTAssertFalse(
            MCPServer.authorize(transport: .network, expectedToken: "secret-token", presentedAuthorization: "Bearer wrong"),
            "network with a wrong presented token must reject"
        )
        // Correct presented token -> accept.
        XCTAssertTrue(
            MCPServer.authorize(transport: .network, expectedToken: "secret-token", presentedAuthorization: "Bearer secret-token"),
            "network with a matching presented token must accept"
        )
    }

    // MARK: - Site 3: instance seam that tools/call actually invokes

    /// The `tools/call` handler gates on `isAuthorized(params:)`. Pin the same
    /// invariant at that seam so the wiring (transport propagation into the
    /// decision) can't regress independently of the pure function.
    func testIsAuthorized_localStdioInstance_acceptsMissingAuthorization() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Default transport is .localStdio. No token configured: a standard
        // client's params (no `_meta`) must be authorized.
        let noToken = MCPServer(authToken: nil, allowedRoots: [root])
        XCTAssertTrue(
            noToken.isAuthorized(params: [:]),
            "local stdio instance with no token must authorize a tools/call carrying no _meta.authorization (finding P1-E)"
        )

        // Token configured: a client that can't echo it (no `_meta`) is still
        // authorized on local stdio, but a wrong presented token is rejected and
        // a matching one accepted.
        let withToken = MCPServer(authToken: "secret-token", allowedRoots: [root])
        XCTAssertTrue(
            withToken.isAuthorized(params: [:]),
            "local stdio instance with a token must still authorize a standard client that presents no _meta.authorization"
        )
        XCTAssertFalse(
            withToken.isAuthorized(params: ["_meta": ["authorization": "Bearer wrong"]]),
            "local stdio instance must reject a WRONG presented token"
        )
        XCTAssertTrue(
            withToken.isAuthorized(params: ["_meta": ["authorization": "Bearer secret-token"]]),
            "local stdio instance must accept a MATCHING presented token"
        )
    }

    /// The network seam, driven through a constructed instance, must fail closed
    /// for a missing token — mirroring the pure-decision assertion above at the
    /// instance level.
    func testIsAuthorized_networkInstance_rejectsMissingToken() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let network = MCPServer(authToken: "secret-token", allowedRoots: [root], transport: .network)
        XCTAssertFalse(
            network.isAuthorized(params: [:]),
            "network instance must reject a tools/call with no presented token"
        )
        XCTAssertFalse(
            network.isAuthorized(params: ["_meta": ["authorization": "Bearer wrong"]]),
            "network instance must reject a wrong presented token"
        )
        XCTAssertTrue(
            network.isAuthorized(params: ["_meta": ["authorization": "Bearer secret-token"]]),
            "network instance must accept a matching presented token"
        )
    }
}
