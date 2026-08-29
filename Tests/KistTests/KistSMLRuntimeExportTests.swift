import XCTest
import AgentCore
@testable import Kist

final class KistSMLRuntimeExportTests: XCTestCase {
    func testRuntimeExportDispatchesBeforeProviderRegistryStartup() throws {
        let source = kistRunnerFamilySource()
        let dispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeExport != nil"))
        let configLoad = try XCTUnwrap(source.range(of: "let config = KistConfig.load()"))

        XCTAssertLessThan(
            dispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime export must not initialize providers, keychain, MCP, tools, or REPL"
        )
    }

    func testLangGraphManifestExportPrintsHostRuntimePackage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        let json = try await KistRunner.renderSMLRuntimeHostExport(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let export = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostExport.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(export.schemaVersion, KistRunner.SMLRuntimeHostExport.currentSchemaVersion)
        XCTAssertEqual(export.sourceFormat, .langGraphManifest)
        XCTAssertEqual(export.runtimePackage.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(export.runtimePackage.runtime.schemaVersion, SMLWorkflowRuntimeExport.currentSchemaVersion)
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.apiBasePaths, ["/source"])
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.replMounts.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.replMounts.map(\.role), ["reviewer"])
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.workflowMounts.map(\.apiRoutes.count), [7])
        XCTAssertEqual(export.runtimePackage.runtime.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(export.runtimePackage.runtime.modelRouter.maximumCommandRounds, 3)
        XCTAssertEqual(export.runtimePackage.runtime.modelTools.map(\.tool.name), [SMLWorkflowModelAdapter.toolName])
        XCTAssertEqual(
            export.runtimePackage.runtime.onyxDrivers.map(\.driverID),
            export.runtimePackage.runtime.mountContract.onyxDriverIDs
        )
        XCTAssertEqual(export.runtimePackage.runtime.planning.workflowIDs, ["langgraph.review"])

        let paths = try object(export.runtimePackage.runtime.openAPI["paths"])
        XCTAssertNotNil(paths["/source/workflows/langgraph.review/tasks"])
        XCTAssertNotNil(paths["/source/runtime/model-router"])
        XCTAssertNotNil(paths["/source/runtime/onyx-drivers"])
        XCTAssertNotNil(paths["/source/runtime/planning"])

        XCTAssertEqual(export.launchDescriptor.sourcePackageSchemaVersion, SMLWorkflowRuntimeSourcePackage.currentSchemaVersion)
        XCTAssertEqual(export.launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(export.launchDescriptor.installedWorkflowIDs, ["langgraph.review"])
        XCTAssertTrue(export.launchDescriptor.launchComplete)
        XCTAssertEqual(export.launchDescriptor.apiBasePaths, ["/source"])
        XCTAssertEqual(export.launchDescriptor.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(export.launchDescriptor.planningWorkflowIDs, ["langgraph.review"])
        let launched = try XCTUnwrap(export.launchDescriptor.workflows.first)
        XCTAssertEqual(launched.replMount.workflowID, "langgraph.review")
        XCTAssertEqual(launched.apiRoutes.count, 7)
        XCTAssertEqual(launched.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(launched.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(
            Set(launched.hostBindingChannels),
            [
                .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
                .onyxDriver, .planningWorkflow,
            ]
        )

        XCTAssertFalse(json.contains("operator.test"))
        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))
    }

    func testRuntimePackageInputUsesLiveHostOverridesInExportAndDescriptor() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)
        let sourceExport = try await KistRunner.makeSMLRuntimeHostExport(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let packageURL = directory.appendingPathComponent("review.package.json")
        try JSONEncoder().encode(sourceExport.runtimePackage).write(to: packageURL)

        let export = try await KistRunner.makeSMLRuntimeHostExport(
            sourcePath: "review.package.json",
            projectRoot: directory.path,
            roleOverride: "override-reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/override",
            title: "Override Runtime",
            version: "2026.09",
            modelMaximumCommandRoundsOverride: 2
        )

        XCTAssertEqual(export.sourceFormat, .runtimeSourcePackage)
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.apiBasePaths, ["/override"])
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.replMounts.map(\.role), ["override-reviewer"])
        XCTAssertEqual(export.runtimePackage.runtime.modelRouter.maximumCommandRounds, 2)
        XCTAssertEqual(export.launchDescriptor.sourceSummaries.map(\.apiBasePath), ["/override"])
        XCTAssertEqual(export.launchDescriptor.workflows.map(\.role), ["override-reviewer"])
        XCTAssertEqual(export.launchDescriptor.modelRouter.maximumCommandRounds, 2)

        let paths = try object(export.runtimePackage.runtime.openAPI["paths"])
        XCTAssertNotNil(paths["/override/workflows/langgraph.review/tasks"])
        XCTAssertNil(paths["/source/workflows/langgraph.review/tasks"])
    }

    func testUnsupportedRuntimeSourceFailsClosed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("unknown.json")
        try Data(#"{"hello":"world"}"#.utf8).write(to: sourceURL)

        do {
            _ = try await KistRunner.makeSMLRuntimeHostExport(
                sourcePath: "unknown.json",
                projectRoot: directory.path
            )
            XCTFail("unsupported runtime source should fail")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Expected a runtime source package, LangGraph manifest, or SML workflow JSON"))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-sml-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func langGraphReviewManifest() -> Data {
        Data("""
        {
          "manifest_version": 1,
          "id": "langgraph.review",
          "version": "1.0.0",
          "name": "LangGraph review",
          "source_reference": "graphs/review.py",
          "source_digest": "\(String(repeating: "a", count: 64))",
          "state_schema": [
            {"name":"topic","type":"string"},
            {"name":"draft","type":"string","required":false}
          ],
          "input_fields": ["topic"],
          "output_fields": ["draft"],
          "entrypoint": "plan",
          "nodes": [
            {
              "id": "plan",
              "kind": "model",
              "purpose": "review.plan",
              "output_schema": "review.plan.v1",
              "next": "write"
            },
            {
              "id": "write",
              "kind": "tool",
              "capability": "repository.write",
              "next": "receipt"
            },
            {
              "id": "receipt",
              "kind": "receipt",
              "receipt_fields": ["draft"]
            }
          ]
        }
        """.utf8)
    }

    private func object(
        _ value: SMLValue?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SMLObject {
        guard case .object(let object) = value else {
            XCTFail("expected object", file: file, line: line)
            return [:]
        }
        return object
    }
}
