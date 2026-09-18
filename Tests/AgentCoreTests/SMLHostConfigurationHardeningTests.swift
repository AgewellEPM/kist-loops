import XCTest
@testable import AgentCore

/// End-to-end adversarial coverage for the shared durable-host configuration boundary. Every
/// loader must consume the exact bytes accepted by ConfinedRoot, reject aliases and linked files,
/// reject ambiguous JSON, and bound both bytes and semantic collections before constructing live
/// host authority.
final class SMLHostConfigurationHardeningTests: XCTestCase {
    private var root: URL!
    private var sml: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-host-config-\(UUID().uuidString)", isDirectory: true)
        sml = root.appendingPathComponent(".kist/sml", isDirectory: true)
        try FileManager.default.createDirectory(at: sml, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(
        _ name: String,
        _ string: String,
        permissions: Int16 = 0o600
    ) throws -> URL {
        try write(name, Data(string.utf8), permissions: permissions)
    }

    @discardableResult
    private func write(
        _ name: String,
        _ data: Data,
        permissions: Int16 = 0o600
    ) throws -> URL {
        let url = sml.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
        return url
    }

    private let authority = #"{"schema_version":1,"actors":[{"id":"agent","roles":["worker"],"operations":[]}]}"#
    private let policy = #"{"schema_version":1}"#
    private let models = #"{"schema_version":1,"purposes":{}}"#
    private let retrieval = #"{"schema_version":1,"sources":{}}"#

    func testValidPrivateFilesLoadExactReviewedValues() throws {
        try write("catalog.json", #"{"schema_version":1,"tool_capabilities":["repo.read"]}"#)
        try write("authority.json", authority)
        try write("policy.json", #"""
        {"schema_version":1,"default":"approve_side_effects","overrides":{"CALL_TOOL:repo.read":"free_run"},"approval_owner":"ops-lead"}
        """#)
        try write("models.json", #"""
        {"schema_version":1,"purposes":{"summary":{"provider":"openai","model":"gpt-5.2","system_prompt":"Be precise.\nShow evidence.","max_tokens":8192}}}
        """#)
        try write("retrieval.json", #"""
        {"schema_version":1,"sources":{"project.notes":{"store_path":"/private/tmp/project notes.json","embedding_space":"text-v3","top_k":7}}}
        """#)

        XCTAssertEqual(
            try SMLRuntimeHostCatalogFile.load(projectRoot: root.path).toolCapabilities,
            ["repo.read"]
        )
        XCTAssertEqual(
            try SMLRuntimeAuthorityConfig.load(projectRoot: root.path)
                .actors["agent"]?.roles,
            ["worker"]
        )
        let loadedPolicy = try SMLApprovalPolicy.load(projectRoot: root.path)
        XCTAssertEqual(loadedPolicy.defaultMode, .approveSideEffects)
        XCTAssertEqual(loadedPolicy.overrides["CALL_TOOL:repo.read"], .freeRun)
        XCTAssertEqual(loadedPolicy.approvalOwner, "ops-lead")

        let model = try XCTUnwrap(
            SMLModelPurposeBindings.load(projectRoot: root.path).purposes["summary"])
        XCTAssertEqual(model.providerId, "openai")
        XCTAssertEqual(model.model, "gpt-5.2")
        XCTAssertEqual(model.systemPrompt, "Be precise.\nShow evidence.")
        XCTAssertEqual(model.maxTokens, 8_192)

        let source = try XCTUnwrap(
            SMLRetrievalSourceBindings.load(projectRoot: root.path).sources["project.notes"])
        XCTAssertEqual(source.storePath, "/private/tmp/project notes.json")
        XCTAssertEqual(source.embeddingSpace, "text-v3")
        XCTAssertEqual(source.topK, 7)
    }

    func testEveryHostTrustFileRequiresExactOwnerOnlyPermissions() throws {
        try write("catalog.json", #"{"schema_version":1}"#, permissions: 0o644)
        try write("authority.json", authority, permissions: 0o644)
        try write("policy.json", policy, permissions: 0o644)
        try write("models.json", models, permissions: 0o644)
        try write("retrieval.json", retrieval, permissions: 0o644)

        XCTAssertThrowsError(try SMLRuntimeHostCatalogFile.load(projectRoot: root.path))
        XCTAssertThrowsError(try SMLRuntimeAuthorityConfig.load(projectRoot: root.path))
        XCTAssertThrowsError(try SMLApprovalPolicy.load(projectRoot: root.path))
        XCTAssertThrowsError(try SMLModelPurposeBindings.load(projectRoot: root.path))
        XCTAssertThrowsError(try SMLRetrievalSourceBindings.load(projectRoot: root.path))
    }

    func testSymlinkLeafHardLinkAndSymlinkAncestorAreRefused() throws {
        let catalogTarget = root.appendingPathComponent("catalog-target.json")
        try Data(#"{"schema_version":1}"#.utf8).write(to: catalogTarget)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: catalogTarget.path
        )
        try FileManager.default.createSymbolicLink(
            at: sml.appendingPathComponent("catalog.json"),
            withDestinationURL: catalogTarget
        )
        XCTAssertThrowsError(try SMLRuntimeHostCatalogFile.load(projectRoot: root.path))

        let modelTarget = root.appendingPathComponent("models-target.json")
        try Data(models.utf8).write(to: modelTarget)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: modelTarget.path
        )
        try FileManager.default.linkItem(
            at: modelTarget,
            to: sml.appendingPathComponent("models.json")
        )
        XCTAssertThrowsError(try SMLModelPurposeBindings.load(projectRoot: root.path))

        let ancestorRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-host-ancestor-\(UUID().uuidString)", isDirectory: true)
        let redirectedSML = ancestorRoot.appendingPathComponent("redirected/sml", isDirectory: true)
        try FileManager.default.createDirectory(at: redirectedSML, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ancestorRoot) }
        let redirectedPolicy = redirectedSML.appendingPathComponent("policy.json")
        try Data(policy.utf8).write(to: redirectedPolicy)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: redirectedPolicy.path
        )
        try FileManager.default.createSymbolicLink(
            at: ancestorRoot.appendingPathComponent(".kist"),
            withDestinationURL: ancestorRoot.appendingPathComponent("redirected")
        )
        XCTAssertThrowsError(try SMLApprovalPolicy.load(projectRoot: ancestorRoot.path))
    }

    func testOversizedFileIsRejectedBeforeJSONDecode() throws {
        try write(
            "retrieval.json",
            Data(repeating: 0x20, count: SMLHostConfigurationFile.maximumBytes + 1)
        )
        XCTAssertThrowsError(
            try SMLRetrievalSourceBindings.load(projectRoot: root.path)
        ) { error in
            guard case SMLRetrievalSourceBindings.LoadError.unreadable = error else {
                return XCTFail("expected unreadable oversized file, got \(error)")
            }
        }
    }

    func testDuplicateAndUnknownFieldsFailClosedAtEverySchemaLayer() throws {
        try write("catalog.json", #"{"schema_version":1,"schema_version":1}"#)
        XCTAssertThrowsError(try SMLRuntimeHostCatalogFile.load(projectRoot: root.path)) { error in
            guard case SMLRuntimeHostCatalogFile.LoadError.malformed = error else {
                return XCTFail("expected malformed duplicate key, got \(error)")
            }
        }

        try write("authority.json", #"""
        {"schema_version":1,"actors":[{"id":"agent","roles":["worker"],"operations":[],"surprise":true}]}
        """#)
        XCTAssertThrowsError(try SMLRuntimeAuthorityConfig.load(projectRoot: root.path)) { error in
            guard case SMLRuntimeAuthorityConfig.LoadError.malformed = error else {
                return XCTFail("expected malformed actor field, got \(error)")
            }
        }

        try write("policy.json", #"{"schema_version":1,"implicit_free_run":true}"#)
        XCTAssertThrowsError(try SMLApprovalPolicy.load(projectRoot: root.path)) { error in
            guard case SMLApprovalPolicy.LoadError.malformed = error else {
                return XCTFail("expected malformed policy field, got \(error)")
            }
        }

        try write("models.json", #"""
        {"schema_version":1,"purposes":{"summary":{"provider":"openai","model":"gpt-5.2","fallback":"other"}}}
        """#)
        XCTAssertThrowsError(try SMLModelPurposeBindings.load(projectRoot: root.path)) { error in
            guard case SMLModelPurposeBindings.LoadError.malformed = error else {
                return XCTFail("expected malformed model field, got \(error)")
            }
        }

        try write("retrieval.json", #"""
        {"schema_version":1,"sources":{"notes":{"store_path":"notes.json","embedding_space":"v1","shell":"run"}}}
        """#)
        XCTAssertThrowsError(try SMLRetrievalSourceBindings.load(projectRoot: root.path)) { error in
            guard case SMLRetrievalSourceBindings.LoadError.malformed = error else {
                return XCTFail("expected malformed retrieval field, got \(error)")
            }
        }
    }

    func testCollectionsAndNumericBudgetsAreBoundedNotClamped() throws {
        let entries = (0...SMLHostConfigurationFile.maximumListEntries)
            .map { "\"source.\($0)\"" }
            .joined(separator: ",")
        try write(
            "catalog.json",
            "{\"schema_version\":1,\"observation_sources\":[\(entries)]}"
        )
        XCTAssertThrowsError(try SMLRuntimeHostCatalogFile.load(projectRoot: root.path))

        try write("models.json", #"""
        {"schema_version":1,"purposes":{"summary":{"provider":"openai","model":"gpt-5.2","max_tokens":255}}}
        """#)
        XCTAssertThrowsError(try SMLModelPurposeBindings.load(projectRoot: root.path)) { error in
            guard case SMLModelPurposeBindings.LoadError.malformed = error else {
                return XCTFail("expected malformed model budget, got \(error)")
            }
        }

        try write("retrieval.json", #"""
        {"schema_version":1,"sources":{"notes":{"store_path":"notes.json","embedding_space":"v1","top_k":51}}}
        """#)
        XCTAssertThrowsError(try SMLRetrievalSourceBindings.load(projectRoot: root.path)) { error in
            guard case SMLRetrievalSourceBindings.LoadError.malformed = error else {
                return XCTFail("expected malformed retrieval budget, got \(error)")
            }
        }
    }
}
