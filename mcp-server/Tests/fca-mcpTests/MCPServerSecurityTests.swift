import Foundation
import XCTest
@testable import fca_mcp

final class MCPServerSecurityTests: XCTestCase {
    private func temporaryDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "fca-mcp-security-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func testToolAuthenticationIsRequiredAndConstantContractAcceptsBearer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let server = MCPServer(authToken: "secret-token", allowedRoots: [root])
        // P1-E: on the default local-stdio transport a client that presents NO _meta.authorization is
        // trusted (a standard stdio client like Claude Code cannot echo a token over a private OS pipe) —
        // so no-auth is accepted. A token, when configured, is validated ONLY when actually presented:
        // wrong → rejected, correct → accepted.
        XCTAssertTrue(server.isAuthorized(params: [:]))
        XCTAssertFalse(server.isAuthorized(params: ["_meta": ["authorization": "Bearer wrong"]]))
        XCTAssertTrue(server.isAuthorized(params: ["_meta": ["authorization": "Bearer secret-token"]]))
    }

    func testProjectRootMustBeInsideServerOwnedRootAndNeverFilesystemRoot() throws {
        let root = try temporaryDirectory()
        let child = root + "/child"
        try FileManager.default.createDirectory(atPath: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let server = MCPServer(authToken: "secret", allowedRoots: [root, "/"])
        XCTAssertEqual(server.authorizedProjectRoot(child), child)
        XCTAssertNil(server.authorizedProjectRoot("/"))
        XCTAssertNil(server.authorizedProjectRoot("/tmp"))
    }
}
