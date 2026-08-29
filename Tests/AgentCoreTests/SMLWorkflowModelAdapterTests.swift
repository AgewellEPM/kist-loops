import XCTest
@testable import AgentCore

final class SMLWorkflowModelAdapterTests: XCTestCase {
    func testProseWithoutToolCallIsAdvisoryAndCannotMutateRuntime() async throws {
        let fixture = try await makeFixture(
            provider: ScriptedWorkflowProvider([.answer("I think we should start.")])
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let step = try await fixture.adapter.step(
            messages: [ChatMessage(role: .user, content: "begin")],
            requestBudget: ProviderRequestBudget(limit: 1)
        )
        XCTAssertEqual(step.disposition, .advisoryOnly)
        XCTAssertEqual(step.advisoryText, "I think we should start.")
        XCTAssertNil(step.command)
        let snapshot = try await fixture.store.load()
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testOneNativeCommandCrossesREPLAdmissionAndRuntimeExactlyOnce() async throws {
        let provider = ScriptedWorkflowProvider([
            .textAndCall(
                "Requesting the admitted start.",
                name: SMLWorkflowModelAdapter.toolName,
                arguments: #"{"line":"start TASK-MODEL {\"value\":\"hello\"}"}"#
            ),
        ])
        let fixture = try await makeFixture(provider: provider)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let budget = ProviderRequestBudget(limit: 1)
        let step = try await fixture.adapter.step(
            messages: [ChatMessage(role: .user, content: "begin")],
            requestBudget: budget
        )
        XCTAssertEqual(step.disposition, .commandExecuted)
        XCTAssertEqual(step.command?.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(step.command?.task, "TASK-MODEL")
        XCTAssertEqual(step.result?.task?.status, .waitingCapability)
        XCTAssertEqual(step.transcriptMessages.count, 2)
        XCTAssertEqual(
            step.transcriptMessages.last?.toolCallId,
            step.transcriptMessages.first?.toolCalls?.first?.id
        )
        let consumed = await budget.consumedCount()
        XCTAssertEqual(consumed, 1)

        let capture = provider.capture()
        XCTAssertEqual(capture.toolNames, [SMLWorkflowModelAdapter.toolName])
        XCTAssertEqual(capture.toolChoice, .any)
        XCTAssertFalse(capture.geminiBuiltins)
        let toolDescription = try XCTUnwrap(capture.toolDescriptions.first)
        XCTAssertTrue(toolDescription.contains("Structured REPL commands:"))
        XCTAssertTrue(toolDescription.contains("json:workflow_input fields:value"))
        XCTAssertTrue(toolDescription.contains("REPL examples:"))
        XCTAssertTrue(toolDescription.contains(#"start TASK-ID {"value":"value"}"#))
        XCTAssertFalse(toolDescription.contains("approve TASK_ID"))
        XCTAssertFalse(toolDescription.contains("json:expected_state fields:task_revision"))
        XCTAssertFalse(toolDescription.contains("help [local]"))
        XCTAssertFalse(toolDescription.contains("attachment [local]"))
        XCTAssertTrue(capture.systemPrompt.contains("prose is advisory"))
        XCTAssertTrue(capture.systemPrompt.contains("Workflow graph:"))
        XCTAssertTrue(capture.systemPrompt.contains("work CALL_TOOL [tool.execute] -> receipt"))
        XCTAssertTrue(capture.systemPrompt.contains("Structured REPL commands:"))
        XCTAssertTrue(capture.systemPrompt.contains("json:workflow_input fields:value"))
        XCTAssertTrue(capture.systemPrompt.contains("REPL examples:"))
        XCTAssertTrue(capture.systemPrompt.contains(#"start TASK-ID {"value":"value"}"#))
        XCTAssertFalse(capture.systemPrompt.contains("approve TASK_ID"))
        XCTAssertFalse(capture.systemPrompt.contains("json:expected_state fields:task_revision"))
        XCTAssertFalse(capture.systemPrompt.contains("help [local]"))
        XCTAssertFalse(capture.systemPrompt.contains("attachment [local]"))
    }

    func testMultipleWrongAndMalformedCallsAreAtomicNoOps() async throws {
        let cases: [ScriptedWorkflowProvider.Step] = [
            .calls([
                (SMLWorkflowModelAdapter.toolName, #"{"line":"start TASK-A {\"value\":\"x\"}"}"#),
                (SMLWorkflowModelAdapter.toolName, #"{"line":"watch TASK-A"}"#),
            ]),
            .call(name: "run_command", arguments: #"{"line":"start TASK-B {\"value\":\"x\"}"}"#),
            .call(
                name: SMLWorkflowModelAdapter.toolName,
                arguments: #"{"line":"start TASK-C {\"value\":\"x\"}","line":"watch TASK-C"}"#
            ),
        ]

        for (index, script) in cases.enumerated() {
            let fixture = try await makeFixture(provider: ScriptedWorkflowProvider([script]))
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            do {
                _ = try await fixture.adapter.step(
                    messages: [ChatMessage(role: .user, content: "case \(index)")],
                    requestBudget: ProviderRequestBudget(limit: 1)
                )
                XCTFail("case \(index) should fail closed")
            } catch { }
            let snapshot = try await fixture.store.load()
            XCTAssertTrue(snapshot.tasks.isEmpty, "case \(index) must not partially execute")
        }
    }

    func testPartialStreamFailureDiscardsBufferedToolCall() async throws {
        let provider = ScriptedWorkflowProvider([
            .toolThenFailure(
                name: SMLWorkflowModelAdapter.toolName,
                arguments: #"{"line":"start TASK-PARTIAL {\"value\":\"x\"}"}"#
            ),
        ])
        let fixture = try await makeFixture(provider: provider)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.adapter.step(
                messages: [ChatMessage(role: .user, content: "begin")],
                requestBudget: ProviderRequestBudget(limit: 1)
            )
            XCTFail("failed stream must not execute a buffered call")
        } catch { }
        let snapshot = try await fixture.store.load()
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testUnsafeFinishReasonDiscardsBufferedToolCall() async throws {
        let provider = ScriptedWorkflowProvider([
            .toolThenFinish(
                name: SMLWorkflowModelAdapter.toolName,
                arguments: #"{"line":"start TASK-TRUNCATED {\"value\":\"x\"}"}"#,
                reason: "length"
            ),
        ])
        let fixture = try await makeFixture(provider: provider)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.adapter.step(
                messages: [ChatMessage(role: .user, content: "begin")],
                requestBudget: ProviderRequestBudget(limit: 1)
            )
            XCTFail("truncated stream must not execute a buffered call")
        } catch let error as SMLWorkflowModelError {
            XCTAssertEqual(error, .unsafeFinishReason("length"))
        }
        let snapshot = try await fixture.store.load()
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testMissingFinishEventDiscardsBufferedToolCall() async throws {
        let provider = ScriptedWorkflowProvider([
            .toolWithoutFinish(
                name: SMLWorkflowModelAdapter.toolName,
                arguments: #"{"line":"start TASK-NO-FINISH {\"value\":\"x\"}"}"#
            ),
        ])
        let fixture = try await makeFixture(provider: provider)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.adapter.step(
                messages: [ChatMessage(role: .user, content: "begin")],
                requestBudget: ProviderRequestBudget(limit: 1)
            )
            XCTFail("a stream without an explicit finish must not execute its buffered call")
        } catch let error as SMLWorkflowModelError {
            XCTAssertEqual(error, .unsafeFinishReason("missing_finish"))
        }
        let snapshot = try await fixture.store.load()
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testDefaultModelAuthorityDoesNotExposeApprovalCommands() async throws {
        let provider = ScriptedWorkflowProvider([
            .call(
                name: SMLWorkflowModelAdapter.toolName,
                arguments: #"{"line":"approve TASK-FORGED"}"#
            ),
        ])
        let fixture = try await makeFixture(provider: provider)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.adapter.step(
                messages: [ChatMessage(role: .user, content: "approve it")],
                requestBudget: ProviderRequestBudget(limit: 1)
            )
            XCTFail("approval is not in the default model surface")
        } catch let error as SMLWorkflowREPLCompileError {
            XCTAssertEqual(error, .actionDenied("approve"))
        }
        let snapshot = try await fixture.store.load()
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testNonNativeProviderIsRejectedBeforeRequestOrMutation() async throws {
        let provider = NonNativeWorkflowProvider()
        let fixture = try await makeFixture(provider: provider)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let budget = ProviderRequestBudget(limit: 1)

        do {
            _ = try await fixture.adapter.step(
                messages: [ChatMessage(role: .user, content: "begin")],
                requestBudget: budget
            )
            XCTFail("text-only providers must not fall into tolerant prose parsing")
        } catch let error as SMLWorkflowModelError {
            XCTAssertEqual(
                error,
                .nativeToolsRequired(provider: "text-only", model: "text-1")
            )
        }
        let consumed = await budget.consumedCount()
        XCTAssertEqual(consumed, 0)
        let snapshot = try await fixture.store.load()
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testRuntimeModelRouterLetsOneModelSelectMountedWorkflow() async throws {
        let provider = ScriptedWorkflowProvider([
            .textAndCall(
                "Routing the review workflow through the registry.",
                name: SMLWorkflowRuntimeModelAdapter.toolName,
                arguments: #"{"workflow_id":"model.review","line":"start TASK-REVIEW {\"value\":\"hello\"}"}"#
            ),
        ])
        let fixture = try await makeRuntimeFixture(provider: provider)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let budget = ProviderRequestBudget(limit: 1)
        let turn = try await fixture.session.submit(
            "start the review workflow",
            requestBudget: budget
        )

        XCTAssertEqual(turn.steps.count, 1)
        XCTAssertEqual(turn.steps.first?.disposition, .commandExecuted)
        XCTAssertEqual(turn.steps.first?.command?.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(turn.steps.first?.command?.task, "TASK-REVIEW")
        XCTAssertEqual(
            turn.steps.first?.command?.arguments["workflow_id"],
            .string("model.review")
        )
        XCTAssertEqual(turn.steps.first?.result?.task?.workflowID, "model.review")
        XCTAssertEqual(turn.taskIDsByWorkflowID["model.review"], "TASK-REVIEW")
        let consumed = await budget.consumedCount()
        XCTAssertEqual(consumed, 1)

        let capture = provider.capture()
        XCTAssertEqual(capture.toolNames, [SMLWorkflowRuntimeModelAdapter.toolName])
        XCTAssertEqual(capture.toolChoice, .any)
        XCTAssertFalse(capture.geminiBuiltins)
        let toolDescription = try XCTUnwrap(capture.toolDescriptions.first)
        XCTAssertTrue(toolDescription.contains("model.workflow@1.0.0"))
        XCTAssertTrue(toolDescription.contains("model.review@1.0.0"))
        XCTAssertTrue(toolDescription.contains("Structured REPL commands:"))
        XCTAssertTrue(toolDescription.contains("json:workflow_input fields:value"))
        XCTAssertTrue(toolDescription.contains(#"start TASK-ID {"value":"value"}"#))
        XCTAssertFalse(toolDescription.contains("approve TASK_ID"))
        XCTAssertFalse(toolDescription.contains("json:expected_state fields:task_revision"))
        XCTAssertFalse(toolDescription.contains("help [local]"))
        XCTAssertFalse(toolDescription.contains("attachment [local]"))
        XCTAssertTrue(capture.systemPrompt.contains("mounted workflow_id"))
        XCTAssertTrue(capture.systemPrompt.contains("model.workflow@1.0.0"))
        XCTAssertTrue(capture.systemPrompt.contains("model.review@1.0.0"))
        XCTAssertTrue(capture.systemPrompt.contains("Allowed REPL grammar:"))
        XCTAssertTrue(capture.systemPrompt.contains("start [TASK_ID] [JSON_INPUT_OBJECT]"))
        XCTAssertTrue(capture.systemPrompt.contains("Structured REPL commands:"))
        XCTAssertTrue(capture.systemPrompt.contains("json:workflow_input fields:value"))
        XCTAssertTrue(capture.systemPrompt.contains("REPL examples:"))
        XCTAssertTrue(capture.systemPrompt.contains(#"start TASK-ID {"value":"value"}"#))
        XCTAssertFalse(capture.systemPrompt.contains("approve TASK_ID"))
        XCTAssertFalse(capture.systemPrompt.contains("json:expected_state fields:task_revision"))
        XCTAssertFalse(capture.systemPrompt.contains("help [local]"))
        XCTAssertFalse(capture.systemPrompt.contains("attachment [local]"))
        XCTAssertTrue(capture.systemPrompt.contains("API routes:"))
        XCTAssertTrue(
            capture.systemPrompt.contains(
                "POST /model/workflows/model.review/tasks [host_command_gateway] -> start_workflow_task_ModelReview"
            )
        )
        XCTAssertTrue(capture.systemPrompt.contains("model tool: propose_sml_command via propose_sml_runtime_command"))
        XCTAssertTrue(capture.systemPrompt.contains("onyx driver: onyx.model.review."))
        XCTAssertTrue(
            capture.systemPrompt.contains(
                "work:CALL_TOOL ref:tool.execute unit:external_capability"
            )
        )
        XCTAssertTrue(capture.systemPrompt.contains("Decomposable units:"))
        XCTAssertTrue(capture.systemPrompt.contains("\nnone\n"))
    }

    func testRuntimeModelRouterFailsClosedOnUnknownWorkflowAndLocalCommands() async throws {
        let cases: [(ScriptedWorkflowProvider.Step, (Error) -> Bool)] = [
            (
                .call(
                    name: SMLWorkflowRuntimeModelAdapter.toolName,
                    arguments: #"{"workflow_id":"missing.workflow","line":"start TASK-MISSING {\"value\":\"x\"}"}"#
                ),
                { error in
                    error as? SMLWorkflowRuntimeRegistryError == .unknownWorkflow("missing.workflow")
                }
            ),
            (
                .call(
                    name: SMLWorkflowRuntimeModelAdapter.toolName,
                    arguments: #"{"workflow_id":"model.workflow","line":"schema"}"#
                ),
                { error in
                    error as? SMLWorkflowModelError == .nonCommandProposal
                }
            ),
            (
                .call(
                    name: SMLWorkflowRuntimeModelAdapter.toolName,
                    arguments: #"{"workflow_id":"model.workflow","line":"attachment"}"#
                ),
                { error in
                    error as? SMLWorkflowModelError == .nonCommandProposal
                }
            ),
            (
                .call(
                    name: SMLWorkflowRuntimeModelAdapter.toolName,
                    arguments: #"{"workflow_id":"model.workflow","line":"approve TASK-FORGED {\"task_revision\":0}"}"#
                ),
                { error in
                    error as? SMLWorkflowREPLCompileError == .actionDenied("approve")
                }
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            let fixture = try await makeRuntimeFixture(
                provider: ScriptedWorkflowProvider([testCase.0])
            )
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            do {
                _ = try await fixture.session.submit(
                    "case \(index)",
                    requestBudget: ProviderRequestBudget(limit: 1)
                )
                XCTFail("runtime model router case \(index) should fail closed")
            } catch {
                XCTAssertTrue(testCase.1(error), "unexpected error for case \(index): \(error)")
            }
            let snapshot = try await fixture.store.load()
            XCTAssertTrue(snapshot.tasks.isEmpty, "case \(index) must not partially execute")
        }
    }

    private struct Fixture {
        let directory: URL
        let store: SMLRuntimeStore
        let adapter: SMLWorkflowModelAdapter
    }

    private struct RuntimeFixture {
        let directory: URL
        let store: SMLRuntimeStore
        let session: SMLWorkflowRuntimeModelSession
    }

    private func makeFixture(provider: any ChatProvider) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-model-\(UUID().uuidString)", isDirectory: true)
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 1_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 1_000 })
        let workflow = capabilityWorkflow()
        let admitted = try SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(workflow),
            catalog: SMLExecutionAdmissionCatalog(toolCapabilities: ["tool.execute"])
        )
        _ = try await runtime.installWorkflow(admitted, role: "model-role")
        let surface = try SMLWorkflowSurface.compile(admitted: admitted, role: "model-role")
        let registry = ProviderRegistry(
            providers: [provider],
            retryDelaysNanoseconds: []
        )
        let gateway = SMLCommandGateway(runtime: runtime, replayGuard: store)
        let adapter = SMLWorkflowModelAdapter(
            surface: surface,
            actor: "model.onyx",
            binding: ProviderBinding(providerId: provider.id, model: provider.defaultModel),
            providers: registry,
            gateway: gateway,
            authorityResolver: { command in
                SMLCommandAuthority(
                    authenticatedActor: "model.onyx",
                    leaseID: "model-lease",
                    roles: ["model-role"],
                    tasks: [command.task],
                    operations: [
                        SMLRuntimeCommandOperation.workflowInspect,
                        SMLRuntimeCommandOperation.workflowRun,
                        SMLRuntimeCommandOperation.taskWatch,
                        SMLRuntimeCommandOperation.receiptsList,
                    ],
                    scope: [:]
                )
            },
            clock: { 1_000 }
        )
        return Fixture(directory: directory, store: store, adapter: adapter)
    }

    private func makeRuntimeFixture(provider: any ChatProvider) async throws -> RuntimeFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-runtime-model-\(UUID().uuidString)", isDirectory: true)
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 1_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 1_000 })
        let workflows = [
            capabilityWorkflow(),
            capabilityWorkflow(
                id: "model.review",
                name: "Review workflow",
                sourceReference: "review"
            ),
        ]
        let admitted = try workflows.map {
            try SMLWorkflowAdmission.admitForExecution(
                SMLWorkflowValidator.requireValidForImport($0),
                catalog: SMLExecutionAdmissionCatalog(toolCapabilities: ["tool.execute"])
            )
        }
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            admitted: admitted,
            role: "model-role",
            actor: "model.onyx",
            apiBasePath: "/model"
        )
        _ = try await registry.installAll(into: runtime)
        let providerRegistry = ProviderRegistry(
            providers: [provider],
            retryDelaysNanoseconds: []
        )
        let gateway = SMLCommandGateway(runtime: runtime, replayGuard: store)
        let session = registry.makeModelRouterSession(
            binding: ProviderBinding(providerId: provider.id, model: provider.defaultModel),
            providers: providerRegistry,
            gateway: gateway,
            authorityResolver: { command in
                SMLCommandAuthority(
                    authenticatedActor: "model.onyx",
                    leaseID: "runtime-model-lease",
                    roles: ["model-role"],
                    tasks: [command.task],
                    operations: [command.op],
                    scope: [:]
                )
            },
            clock: { 1_000 }
        )
        return RuntimeFixture(directory: directory, store: store, session: session)
    }

    private func capabilityWorkflow(
        id: String = "model.workflow",
        name: String = "Model workflow",
        sourceReference: String = "test"
    ) -> SMLWorkflow {
        SMLWorkflow(
            id: id,
            version: "1.0.0",
            name: name,
            source: .init(kind: .langGraph, reference: sourceReference),
            trigger: .init(kind: .manual),
            stateSchema: [
                .init(name: "value", type: .string),
                .init(name: "result", type: .string, required: false),
            ],
            interface: .init(inputFields: ["value"], outputFields: ["result"]),
            entrypoint: "work",
            instructions: [
                .init(id: "work", op: .callTool, capability: "tool.execute", next: "receipt"),
                .init(id: "receipt", op: .emitReceipt, receiptFields: ["result"]),
            ]
        )
    }
}

private final class ScriptedWorkflowProvider: ChatProvider, @unchecked Sendable {
    enum Step {
        case answer(String)
        case call(name: String, arguments: String)
        case textAndCall(String, name: String, arguments: String)
        case calls([(String, String)])
        case toolThenFailure(name: String, arguments: String)
        case toolThenFinish(name: String, arguments: String, reason: String)
        case toolWithoutFinish(name: String, arguments: String)
    }

    struct Capture {
        let toolNames: [String]
        let toolDescriptions: [String]
        let toolChoice: ToolChoice
        let geminiBuiltins: Bool
        let systemPrompt: String
    }

    let id = "onyx-test"
    let name = "Onyx Test"
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount = "onyx-test"
    let defaultModel = "onyx-1"
    let availableModels = [AIModel(id: "onyx-1")]
    var supportsNativeTools: Bool { true }

    private let lock = NSLock()
    private var steps: [Step]
    private var lastCapture = Capture(
        toolNames: [],
        toolDescriptions: [],
        toolChoice: .auto,
        geminiBuiltins: true,
        systemPrompt: ""
    )

    init(_ steps: [Step]) { self.steps = steps }

    func stream(
        messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func streamTools(
        messages: [ChatMessage],
        model: String,
        settings: ModelSettings,
        apiKey: String?,
        tools: [ToolSpec]
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let step = nextStep(settings: settings, tools: tools)
        return AsyncThrowingStream { continuation in
            switch step {
            case .answer(let text):
                continuation.yield(.delta(text))
                continuation.finish()
            case .call(let name, let arguments):
                continuation.yield(.toolCall(id: "call-1", name: name, argumentsJSON: arguments))
                continuation.yield(.finish(reason: "stop"))
                continuation.finish()
            case .textAndCall(let text, let name, let arguments):
                continuation.yield(.delta(text))
                continuation.yield(.toolCall(id: "call-1", name: name, argumentsJSON: arguments))
                continuation.yield(.finish(reason: "stop"))
                continuation.finish()
            case .calls(let calls):
                for (index, call) in calls.enumerated() {
                    continuation.yield(.toolCall(
                        id: "call-\(index)", name: call.0, argumentsJSON: call.1
                    ))
                }
                continuation.yield(.finish(reason: "stop"))
                continuation.finish()
            case .toolThenFailure(let name, let arguments):
                continuation.yield(.toolCall(id: "call-1", name: name, argumentsJSON: arguments))
                continuation.finish(throwing: AIProviderError.invalidResponse("truncated"))
            case .toolThenFinish(let name, let arguments, let reason):
                continuation.yield(.toolCall(id: "call-1", name: name, argumentsJSON: arguments))
                continuation.yield(.finish(reason: reason))
                continuation.finish()
            case .toolWithoutFinish(let name, let arguments):
                continuation.yield(.toolCall(id: "call-1", name: name, argumentsJSON: arguments))
                continuation.finish()
            }
        }
    }

    func capture() -> Capture {
        lock.lock()
        defer { lock.unlock() }
        return lastCapture
    }

    private func nextStep(settings: ModelSettings, tools: [ToolSpec]) -> Step {
        lock.lock()
        defer { lock.unlock() }
        let step = steps.isEmpty ? .answer("done") : steps.removeFirst()
        lastCapture = Capture(
            toolNames: tools.map(\.name),
            toolDescriptions: tools.map(\.description),
            toolChoice: settings.toolChoice,
            geminiBuiltins: settings.geminiBuiltins,
            systemPrompt: settings.systemPrompt
        )
        return step
    }
}

private struct NonNativeWorkflowProvider: ChatProvider {
    let id = "text-only"
    let name = "Text only"
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount = "text-only"
    let defaultModel = "text-1"
    let availableModels = [AIModel(id: "text-1")]

    func stream(
        messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.delta("must not be called"))
            continuation.finish()
        }
    }
}
