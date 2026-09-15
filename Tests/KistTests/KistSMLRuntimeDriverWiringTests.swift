import XCTest
@testable import Kist
@testable import AgentCore

final class KistSMLRuntimeDriverWiringTests: XCTestCase {
    func testLaunchProbeRejectsAmbiguousDriversAndAllowsHonestParking() throws {
        let catalog = SMLExecutionAdmissionCatalog(
            toolCapabilities: ["duplicate", "unbound"]
        )
        let ambiguous = SMLCapabilityRouter(drivers: [
            ProbeDriver(id: "driver-a", reference: "duplicate"),
            ProbeDriver(id: "driver-b", reference: "duplicate"),
        ])
        XCTAssertThrowsError(
            try KistRunner.requireDisjointSMLDrivers(router: ambiguous, catalog: catalog)
        ) { error in
            XCTAssertEqual(
                error as? SMLCapabilityRouterError,
                .ambiguousDrivers(["driver-a", "driver-b"])
            )
        }

        let disjoint = SMLCapabilityRouter(drivers: [
            ProbeDriver(id: "driver-a", reference: "duplicate"),
        ])
        XCTAssertNoThrow(
            try KistRunner.requireDisjointSMLDrivers(router: disjoint, catalog: catalog),
            "an admitted reference with no configured driver must remain visibly parked"
        )
    }

    func testHTTPDriverIsRoutedOnlyAfterExactCatalogAdmission() throws {
        let root = try makeProjectRoot(endpoint: endpoint(capability: "remote.lookup"))
        defer { try? FileManager.default.removeItem(at: root) }

        let inertDrivers = try KistRunner.buildSMLCapabilityDrivers(
            projectRoot: root.path,
            catalog: SMLExecutionAdmissionCatalog()
        )
        let inertRouter = SMLCapabilityRouter(drivers: inertDrivers)
        XCTAssertThrowsError(try inertRouter.driverID(for: SMLCapabilityRouter.probeRequest(
            operation: .callTool, reference: "remote.lookup"))) { error in
            guard case .noDriver = error as? SMLCapabilityRouterError else {
                return XCTFail("unadmitted endpoint must remain inert: \(error)")
            }
        }

        let admittedDrivers = try KistRunner.buildSMLCapabilityDrivers(
            projectRoot: root.path,
            catalog: SMLExecutionAdmissionCatalog(toolCapabilities: ["remote.lookup"])
        )
        let admittedRouter = SMLCapabilityRouter(drivers: admittedDrivers)
        XCTAssertEqual(
            try admittedRouter.driverID(for: SMLCapabilityRouter.probeRequest(
                operation: .callTool, reference: "remote.lookup")),
            "sml-http-driver"
        )
    }

    func testHTTPAndBuiltInToolNameCollisionAbortsLaunch() throws {
        let root = try makeProjectRoot(endpoint: endpoint(capability: "read_file"))
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try KistRunner.buildSMLCapabilityDrivers(
            projectRoot: root.path,
            catalog: SMLExecutionAdmissionCatalog(toolCapabilities: ["read_file"])
        )) { error in
            guard case SMLRuntimeCapabilityStackError.httpToolCollision("read_file") = error else {
                return XCTFail("expected an explicit registry collision, got \(error)")
            }
        }
    }

    func testUnadmittedAuthenticatedEndpointDoesNotDemandCredentials() throws {
        let secureEndpoint = SMLHTTPEndpointSpec(
            capability: "remote.secure",
            method: .get,
            pathTemplate: "/secure",
            servers: [.init(scheme: "https", host: "example.com")],
            authentication: [.init(schemes: [.init(
                credentialID: "remote.token", kind: .bearer)])]
        )
        let root = try makeProjectRoot(endpoint: secureEndpoint)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNoThrow(try KistRunner.buildSMLCapabilityDrivers(
            projectRoot: root.path,
            catalog: SMLExecutionAdmissionCatalog()
        ))
        XCTAssertThrowsError(try KistRunner.buildSMLCapabilityDrivers(
            projectRoot: root.path,
            catalog: SMLExecutionAdmissionCatalog(toolCapabilities: ["remote.secure"])
        )) { error in
            XCTAssertEqual(
                error as? SMLHTTPExecutionError,
                .missingCredentials("remote.secure")
            )
        }
    }

    func testUnknownEndpointBundleFieldAbortsLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-http-wiring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            SMLHTTPEndpointRegistry.relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let malformed = #"{"schema_version":1,"api_id":"test.api","source_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","endpoints":[],"surprise":true}"#
        let malformedURL = directory.appendingPathComponent("test.json")
        try Data(malformed.utf8).write(to: malformedURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: malformedURL.path)

        XCTAssertThrowsError(try KistRunner.buildSMLCapabilityDrivers(
            projectRoot: root.path,
            catalog: SMLExecutionAdmissionCatalog()
        ))
    }

    func testConfiguredRetrievalRequiresAndUsesARealEmbeddingProvider() throws {
        let root = try makeProjectRoot(endpoint: endpoint(capability: "unused.http"))
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SMLRetrievalSourceBindings.relativePath)
        try Data(#"{"schema_version":1,"sources":{"notes":{"store_path":"vectors.json","embedding_space":"test:host","top_k":5}}}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        let catalog = SMLExecutionAdmissionCatalog(retrievalSources: ["notes"])
        XCTAssertThrowsError(try KistRunner.buildSMLCapabilityDrivers(projectRoot: root.path, catalog: catalog)) { error in
            XCTAssertTrue(String(describing: error).contains("configured embedding provider"))
        }
        let drivers = try KistRunner.buildSMLCapabilityDrivers(projectRoot: root.path,
            catalog: catalog, embeddingProvider: HostTestEmbedder())
        XCTAssertEqual(try SMLCapabilityRouter(drivers: drivers).driverID(for:
            SMLCapabilityRouter.probeRequest(operation: .retrieve, reference: "notes")), "kist-retrieval-driver")
        let loaded = try SMLRetrievalSourceBindings.load(projectRoot: root.path)
        XCTAssertEqual(loaded.sources["notes"]?.storePath, root.appendingPathComponent("vectors.json").path)
    }

    func testModelTypeMappingsLoadAndUnknownAdmittedSchemaAbortsLaunch() throws {
        let root = try makeProjectRoot(endpoint: endpoint(capability: "unused.http"))
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SMLModelPurposeBindings.relativePath)
        try Data(#"{"schema_version":1,"purposes":{"summary":{"provider":"codex-cli","model":"test-model"}},"output_schemas":{"summary.v1":"object"}}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        let bindings = try SMLModelPurposeBindings.load(projectRoot: root.path)
        XCTAssertEqual(bindings.outputSchemas["summary.v1"], .object)
        XCTAssertEqual(bindings.outputSchemas["text"], .string)
        XCTAssertNoThrow(try KistRunner.buildSMLCapabilityDrivers(projectRoot: root.path,
            catalog: SMLExecutionAdmissionCatalog(modelPurposes: ["summary"], modelOutputSchemas: ["summary.v1"])))
        XCTAssertThrowsError(try KistRunner.buildSMLCapabilityDrivers(projectRoot: root.path,
            catalog: SMLExecutionAdmissionCatalog(modelPurposes: ["summary"], modelOutputSchemas: ["missing.v1"]))) { error in
            XCTAssertTrue(String(describing: error).contains("output_schemas"))
        }
    }

    private func endpoint(capability: String) -> SMLHTTPEndpointSpec {
        SMLHTTPEndpointSpec(
            capability: capability,
            method: .get,
            pathTemplate: "/lookup",
            servers: [.init(scheme: "https", host: "example.com")]
        )
    }

    private func makeProjectRoot(endpoint: SMLHTTPEndpointSpec) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-http-wiring-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent(
            SMLHTTPEndpointRegistry.relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let bundle = SMLHTTPEndpointBundle(
            apiID: "test.api",
            sourceDigest: String(repeating: "a", count: 64),
            endpoints: [endpoint]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bundleURL = directory.appendingPathComponent("test.json")
        try encoder.encode(bundle).write(to: bundleURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: bundleURL.path)
        return root
    }
}

private struct ProbeDriver: SMLInstructionDriver {
    let id: String
    let reference: String

    func supports(_ request: SMLCapabilityRequest) -> Bool {
        request.operation == .callTool && request.reference == reference
    }

    func execute(
        _ invocation: SMLCapabilityInvocation
    ) async throws -> SMLCapabilityOutcome {
        throw ProbeDriverError.executionMustNotBeCalledByLaunchProbe
    }
}

private enum ProbeDriverError: Error {
    case executionMustNotBeCalledByLaunchProbe
}

private struct HostTestEmbedder: EmbeddingProviding {
    func embeddingSpaceID() async throws -> String { "test:host" }
    func embeddings(for texts: [String]) async throws -> [[Float]] { texts.map { _ in [1, 0] } }
}
