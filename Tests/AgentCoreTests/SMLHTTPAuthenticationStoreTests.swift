import XCTest
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class SMLHTTPAuthenticationStoreTests: XCTestCase {
    func testLoadsOwnerOnlyCredentialAndSatisfiesScopes() throws {
        let fixture = try authenticationFixture(
            #"{"schema_version":1,"credentials":{"service.oauth":{"value":"token-value","scopes":["read","write"]}}}"#,
            permissions: 0o600
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try SMLHTTPAuthenticationStore.load(projectRoot: fixture.root.path)
        let endpoint = authenticatedEndpoint(
            .init(
                credentialID: "service.oauth",
                kind: .oauth2Bearer,
                requiredScopes: ["read"])
        )

        XCTAssertEqual(
            try store.headers(for: endpoint),
            ["Authorization": "Bearer token-value"]
        )
    }

    func testRefusesGroupReadableSymlinkAndHardLinkedCredentialFiles() throws {
        let groupReadable = try authenticationFixture(
            #"{"schema_version":1,"credentials":{}}"#,
            permissions: 0o640
        )
        defer { try? FileManager.default.removeItem(at: groupReadable.root) }
        XCTAssertThrowsError(try SMLHTTPAuthenticationStore.load(
            projectRoot: groupReadable.root.path)) { error in
            guard case .unsafeFile = error as? SMLHTTPAuthenticationStore.LoadError else {
                return XCTFail("expected unsafe file, got \(error)")
            }
        }

        let symlinkRoot = try emptyAuthenticationRoot()
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        let target = symlinkRoot.appendingPathComponent("target.json")
        try Data(#"{"schema_version":1,"credentials":{}}"#.utf8).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(
            at: authenticationURL(symlinkRoot), withDestinationURL: target)
        XCTAssertThrowsError(try SMLHTTPAuthenticationStore.load(projectRoot: symlinkRoot.path))

        let hardLinkRoot = try emptyAuthenticationRoot()
        defer { try? FileManager.default.removeItem(at: hardLinkRoot) }
        let auth = authenticationURL(hardLinkRoot)
        try Data(#"{"schema_version":1,"credentials":{}}"#.utf8).write(to: auth)
        XCTAssertEqual(chmod(auth.path, 0o600), 0)
        XCTAssertEqual(link(auth.path, hardLinkRoot.appendingPathComponent("second-link").path), 0)
        XCTAssertThrowsError(try SMLHTTPAuthenticationStore.load(projectRoot: hardLinkRoot.path))
    }

    func testRefusesSymlinkedCredentialAncestor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-http-auth-root-\(UUID().uuidString)", isDirectory: true)
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-http-auth-external-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: external.appendingPathComponent("sml", isDirectory: true),
            withIntermediateDirectories: true)
        let externalAuth = external.appendingPathComponent("sml/http-auth.json")
        try Data(#"{"schema_version":1,"credentials":{}}"#.utf8).write(to: externalAuth)
        XCTAssertEqual(chmod(externalAuth.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".kist"), withDestinationURL: external)

        XCTAssertThrowsError(try SMLHTTPAuthenticationStore.load(projectRoot: root.path)) { error in
            guard case .unsafeFile = error as? SMLHTTPAuthenticationStore.LoadError else {
                return XCTFail("expected unsafe ancestor rejection, got \(error)")
            }
        }
    }

    func testRejectsUnknownFieldsMixedCredentialKindsAndInsufficientScopes() throws {
        let unknown = try authenticationFixture(
            #"{"schema_version":1,"credentials":{"service.key":{"value":"secret","extra":true}}}"#,
            permissions: 0o600
        )
        defer { try? FileManager.default.removeItem(at: unknown.root) }
        XCTAssertThrowsError(try SMLHTTPAuthenticationStore.load(projectRoot: unknown.root.path))

        let mixed = try authenticationFixture(
            #"{"schema_version":1,"credentials":{"service.key":{"value":"secret","username":"u","password":"p"}}}"#,
            permissions: 0o600
        )
        defer { try? FileManager.default.removeItem(at: mixed.root) }
        XCTAssertThrowsError(try SMLHTTPAuthenticationStore.load(projectRoot: mixed.root.path))

        let controlScope = try authenticationFixture(
            #"{"schema_version":1,"credentials":{"service.key":{"value":"secret","scopes":["read\nadmin"]}}}"#,
            permissions: 0o600
        )
        defer { try? FileManager.default.removeItem(at: controlScope.root) }
        XCTAssertThrowsError(try SMLHTTPAuthenticationStore.load(
            projectRoot: controlScope.root.path))

        let controlValue = try authenticationFixture(
            #"{"schema_version":1,"credentials":{"service.key":{"value":"token\u0085admin"}}}"#,
            permissions: 0o600
        )
        defer { try? FileManager.default.removeItem(at: controlValue.root) }
        XCTAssertThrowsError(try SMLHTTPAuthenticationStore.load(
            projectRoot: controlValue.root.path))

        let scoped = try authenticationFixture(
            #"{"schema_version":1,"credentials":{"service.oauth":{"value":"token","scopes":["read"]}}}"#,
            permissions: 0o600
        )
        defer { try? FileManager.default.removeItem(at: scoped.root) }
        let store = try SMLHTTPAuthenticationStore.load(projectRoot: scoped.root.path)
        XCTAssertThrowsError(try store.headers(for: authenticatedEndpoint(.init(
            credentialID: "service.oauth",
            kind: .oauth2Bearer,
            requiredScopes: ["admin"]
        )))) { error in
            XCTAssertEqual(error as? SMLHTTPExecutionError, .missingCredentials("secure.call"))
        }
    }

    func testMissingFileMeansNoCredentialsAndDoesNotCreateAnything() throws {
        let root = try emptyAuthenticationRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SMLHTTPAuthenticationStore.load(projectRoot: root.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: authenticationURL(root).path))
        XCTAssertThrowsError(try store.headers(for: authenticatedEndpoint(.init(
            credentialID: "missing", kind: .bearer))))
    }

    private func authenticatedEndpoint(
        _ scheme: SMLHTTPAuthenticationSchemeSpec
    ) -> SMLHTTPEndpointSpec {
        SMLHTTPEndpointSpec(
            capability: "secure.call",
            method: .get,
            pathTemplate: "/secure",
            servers: [.init(scheme: "https", host: "example.com")],
            authentication: [.init(schemes: [scheme])]
        )
    }

    private func authenticationFixture(
        _ contents: String,
        permissions: mode_t
    ) throws -> (root: URL, file: URL) {
        let root = try emptyAuthenticationRoot()
        let file = authenticationURL(root)
        try Data(contents.utf8).write(to: file)
        guard chmod(file.path, permissions) == 0 else {
            throw NSError(domain: "SMLHTTPAuthenticationStoreTests", code: Int(errno))
        }
        return (root, file)
    }

    private func emptyAuthenticationRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-http-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".kist/sml", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func authenticationURL(_ root: URL) -> URL {
        root.appendingPathComponent(SMLHTTPAuthenticationStore.relativePath)
    }
}
