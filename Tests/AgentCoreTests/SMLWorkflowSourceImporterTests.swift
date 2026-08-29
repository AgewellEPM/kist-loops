import XCTest
@testable import AgentCore

final class SMLWorkflowSourceImporterTests: XCTestCase {
    func testLangGraphManifestImportsLaunchesAndExposesRuntimeSurfaces() async throws {
        let manifest = langGraphReviewManifest()

        let workflow = try SMLWorkflowSourceImporter.langGraphWorkflow(from: manifest)

        XCTAssertEqual(workflow.id, "langgraph.review")
        XCTAssertEqual(workflow.source.kind, .langGraph)
        XCTAssertEqual(workflow.source.reference, "graphs/review.py")
        XCTAssertEqual(workflow.source.digest, String(repeating: "a", count: 64))
        XCTAssertEqual(workflow.instructions.map(\.op), [.callModel, .callTool, .emitReceipt])
        XCTAssertEqual(workflow.interface.inputFields, ["topic"])
        XCTAssertEqual(workflow.interface.outputFields, ["draft"])

        let catalog = SMLExecutionAdmissionCatalog(
            toolCapabilities: ["repository.write"],
            modelPurposes: ["review.plan"],
            modelOutputSchemas: ["review.plan.v1"]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 4_400 }
        )
        let runtime = SMLRuntime(store: store, clock: { 4_400 })
        let authority: @Sendable (SMLCommandEnvelope) async throws -> SMLCommandAuthority = {
            command in
            SMLCommandAuthority(
                authenticatedActor: "operator.luke",
                leaseID: "source-lease",
                roles: [command.role],
                tasks: [command.task],
                operations: [command.op],
                scope: command.scope
            )
        }

        let sourceMount = SMLWorkflowRuntimeSourceMount(
            document: .langGraphManifest(manifest),
            admissionCatalog: catalog,
            role: "reviewer",
            actor: "operator.luke",
            apiBasePath: "/source"
        )
        let launch = try await SMLWorkflowRuntimeApp.launch(
            sourceMounts: [sourceMount],
            runtime: runtime,
            replayGuard: store,
            authorityResolver: authority,
            commandID: { "source-command" },
            taskID: { "TASK-SOURCE-GENERATED" },
            clock: { 4_400 }
        )

        XCTAssertEqual(launch.installedWorkflows.map(\.id), ["langgraph.review"])
        XCTAssertEqual(launch.mountContract.workflowMounts.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(
            try launch.app.resolveWorkflowMount(workflowID: "langgraph.review").apiRoutes.count,
            7
        )

        let started = try await launch.app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/source/workflows/langgraph.review/tasks",
                body: [
                    "task_id": .string("TASK-SOURCE"),
                    "input": .object(["topic": .string("release")]),
                ]
            )
        )
        XCTAssertEqual(started.statusCode, 201)
        XCTAssertEqual(started.kind, .workflow)
        XCTAssertEqual(started.route?.operationID, "start_workflow_task_LanggraphReview")
        XCTAssertEqual(started.command?.role, "reviewer")
        XCTAssertEqual(started.result?.task?.workflowID, "langgraph.review")
    }

    func testLangGraphManifestFailsClosedOnUnknownKeysAndRawPython() throws {
        let unknownRootKey = data("""
        {
          "manifest_version": 1,
          "id": "langgraph.review",
          "version": "1.0.0",
          "name": "LangGraph review",
          "source_reference": "graphs/review.py",
          "state_schema": [],
          "input_fields": [],
          "output_fields": [],
          "entrypoint": "done",
          "nodes": [{"id":"done","kind":"complete"}],
          "python": "print('not allowed')"
        }
        """)

        XCTAssertThrowsError(
            try SMLWorkflowSourceImporter.workflow(from: .langGraphManifest(unknownRootKey))
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowSourceImportError,
                .unknownKey(path: "$", key: "python")
            )
        }

        XCTAssertThrowsError(
            try SMLWorkflowSourceImporter.workflow(
                from: .langGraphPython(
                    reference: "graphs/review.py",
                    source: Data("print('raw graph')".utf8)
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowSourceImportError,
                .unsupportedSource(
                    "raw LangGraph Python import requires an explicit langgraph_manifest; code is referenced and digested, not executed"
                )
            )
        }
    }

    func testLangGraphManifestFailsClosedOnUnknownNodeKind() throws {
        let unknownKind = data("""
        {
          "manifest_version": 1,
          "id": "langgraph.review",
          "version": "1.0.0",
          "name": "LangGraph review",
          "source_reference": "graphs/review.py",
          "state_schema": [],
          "input_fields": [],
          "output_fields": [],
          "entrypoint": "shell",
          "nodes": [{"id":"shell","kind":"shell"}]
        }
        """)

        XCTAssertThrowsError(
            try SMLWorkflowSourceImporter.workflow(from: .langGraphManifest(unknownKind))
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowSourceImportError,
                .invalidField(path: "$.nodes[0].kind", reason: "unknown LangGraph node kind shell")
            )
        }
    }

    private func langGraphReviewManifest() -> Data {
        data("""
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
        """)
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
