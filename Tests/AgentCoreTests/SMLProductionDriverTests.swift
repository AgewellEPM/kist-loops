import XCTest
@testable import AgentCore

/// Pins the four production capability drivers, one contract per site: the tool driver routes
/// through the host ToolContext and converts tool refusals into FAILED outcomes (never crashes),
/// the observation driver refuses any tool that is not type-marked read-only, the model driver
/// treats an empty/failed model response as failure (never empty state), the retrieval driver
/// fails closed on unbound sources and broken embedders, and every outcome binds dispatchID +
/// requestStateDigest so the router's replay/forgery checks hold.
final class SMLProductionDriverTests: XCTestCase {
    // MARK: - Fixtures

    private final class ArgumentCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _arguments: [String: Any] = [:]
        private var _projectRoot: String?
        var arguments: [String: Any] {
            lock.lock(); defer { lock.unlock() }
            return _arguments
        }
        var projectRoot: String? {
            lock.lock(); defer { lock.unlock() }
            return _projectRoot
        }
        func record(arguments: [String: Any], projectRoot: String) {
            lock.lock(); defer { lock.unlock() }
            _arguments = arguments
            _projectRoot = projectRoot
        }
    }

    private struct StubTool: AgentTool {
        let name: String
        let description = "stub"
        var parameters: [ToolParameter] = []
        var supportedActions: [String] { [] }
        var unsupportedActions: [String] { [] }
        var capabilityNote: String? { nil }
        var usageExamples: [String] { [] }
        var result = ToolResult(success: true, output: "stub-output")
        var thrown: StubError?
        var capture: ArgumentCapture?

        func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
            capture?.record(arguments: arguments, projectRoot: context.projectRoot)
            if let thrown { throw thrown }
            return result
        }
    }

    private struct ReadOnlyStubTool: ReadOnlyAgentTool {
        let name: String
        let description = "read-only stub"
        var parameters: [ToolParameter] = []
        var supportedActions: [String] { [] }
        var unsupportedActions: [String] { [] }
        var capabilityNote: String? { nil }
        var usageExamples: [String] { [] }
        var capture: ArgumentCapture?

        func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
            capture?.record(arguments: arguments, projectRoot: context.projectRoot)
            return ToolResult(success: true, output: "observed")
        }
    }

    enum StubError: Error, Sendable { case refused }

    private func request(
        operation: SMLInstructionOperation,
        reference: String,
        arguments: SMLObject = [:],
        state: SMLObject = [:]
    ) -> SMLCapabilityRequest {
        SMLCapabilityRequest(
            taskID: "TASK-D1",
            role: "workflow-agent",
            workflowID: "driver.test",
            workflowVersion: "1.0.0",
            taskRevision: 3,
            instructionID: "step-1",
            operation: operation,
            reference: reference,
            arguments: arguments,
            scope: [:],
            expectedState: [:],
            state: state,
            stateDigest: String(repeating: "d", count: 64)
        )
    }

    private func invocation(
        _ request: SMLCapabilityRequest,
        driverID: String
    ) -> SMLCapabilityInvocation {
        SMLCapabilityInvocation(claimed: SMLClaimedCapability(
            request: request,
            record: SMLCapabilityClaimRecord(
                dispatchID: "dispatch-77",
                driverID: driverID,
                instructionID: request.instructionID,
                stateDigest: request.stateDigest,
                commandID: "claim-cmd-1",
                actor: "operator.luke",
                leaseID: "lease-1",
                claimedAtEpoch: 2_000
            )
        ))
    }

    private func context() -> ToolContext {
        ToolContext(projectRoot: "/tmp/sml-driver-tests")
    }

    // MARK: - Support layer

    func testEvidenceDigestIsStableAcrossKeyOrder() {
        let a: SMLObject = ["x": .string("1"), "y": .number(2)]
        let b: SMLObject = ["y": .number(2), "x": .string("1")]
        XCTAssertEqual(
            SMLCapabilityDriverSupport.evidenceDigest(a),
            SMLCapabilityDriverSupport.evidenceDigest(b)
        )
        XCTAssertEqual(SMLCapabilityDriverSupport.evidenceDigest(a).count, 64)
    }

    func testInvalidOutputFieldFailsLoudly() {
        let bad = request(operation: .callTool, reference: "cap.a",
                          arguments: ["output_field": .number(7)])
        XCTAssertThrowsError(try SMLCapabilityDriverSupport.outputField(of: bad))
    }

    // MARK: - Tool driver

    func testToolDriverExecutesPatchesAndBindsDispatchIdentity() async throws {
        let capture = ArgumentCapture()
        var tool = StubTool(name: "read_file")
        tool.capture = capture
        tool.result = ToolResult(success: true, output: "file contents")
        let driver = SMLToolCapabilityDriver(
            allowedCapabilities: ["read_file"],
            registry: ToolRegistry([tool]),
            context: context(),
            clock: { 2_000 }
        )
        let request = request(
            operation: .callTool, reference: "read_file",
            arguments: ["path": .string("notes.md"), "output_field": .string("result")]
        )
        XCTAssertTrue(driver.supports(request))
        let outcome = try await driver.execute(invocation(request, driverID: driver.id))

        XCTAssertEqual(outcome.status, .passed)
        XCTAssertEqual(outcome.dispatchID, "dispatch-77")
        XCTAssertEqual(outcome.requestStateDigest, request.stateDigest)
        XCTAssertEqual(outcome.statePatch["result"], .string("file contents"))
        XCTAssertEqual(outcome.evidence.source, driver.id)
        // The tool saw the real arguments (minus the host-side output_field convention) and the
        // host ToolContext — confinement applies at the tool layer, not by driver promise.
        XCTAssertEqual(capture.arguments["path"] as? String, "notes.md")
        XCTAssertNil(capture.arguments["output_field"])
        XCTAssertEqual(capture.projectRoot, "/tmp/sml-driver-tests")
    }

    func testToolDriverCannotBypassRegistryArgumentGate() async throws {
        let capture = ArgumentCapture()
        var tool = StubTool(name: "guarded_tool")
        tool.parameters = [
            ToolParameter(
                name: "path",
                type: "string",
                description: "A required path"
            ),
        ]
        tool.capture = capture
        let driver = SMLToolCapabilityDriver(
            allowedCapabilities: ["guarded_tool"],
            registry: ToolRegistry([tool]),
            context: context()
        )
        let request = request(
            operation: .callTool,
            reference: "guarded_tool",
            arguments: ["path": .number(7)]
        )

        let outcome = try await driver.execute(invocation(request, driverID: driver.id))
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertNil(capture.projectRoot,
                     "invalid arguments must be rejected by ToolGate before AgentTool.execute")
        XCTAssertTrue(outcome.statePatch.isEmpty)
    }

    func testToolDriverConvertsAThrowingToolIntoAFailedOutcome() async throws {
        var tool = StubTool(name: "write_file")
        tool.thrown = StubError.refused
        let driver = SMLToolCapabilityDriver(
            allowedCapabilities: ["write_file"],
            registry: ToolRegistry([tool]),
            context: context()
        )
        let request = request(operation: .callTool, reference: "write_file")
        let outcome = try await driver.execute(invocation(request, driverID: driver.id))
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.statePatch.isEmpty,
                      "a refused tool must never write state")
    }

    func testToolDriverSupportsOnlyAllowedCapabilitiesAndCallToolOp() {
        let driver = SMLToolCapabilityDriver(
            allowedCapabilities: ["cap.allowed"],
            registry: ToolRegistry([]),
            context: context()
        )
        XCTAssertFalse(driver.supports(request(operation: .callTool, reference: "cap.other")))
        XCTAssertFalse(driver.supports(request(operation: .observe, reference: "cap.allowed")))
    }

    func testToolDriverUnknownToolFailsClosedWithNamedError() async {
        let driver = SMLToolCapabilityDriver(
            allowedCapabilities: ["ghost"],
            registry: ToolRegistry([]),
            context: context()
        )
        let request = request(operation: .callTool, reference: "ghost")
        do {
            _ = try await driver.execute(invocation(request, driverID: driver.id))
            XCTFail("unknown tool must throw")
        } catch let error as SMLCapabilityDriverConfigurationError {
            XCTAssertEqual(error, .unknownTool(capability: "ghost"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Observation driver

    func testObservationDriverRefusesToolsThatAreNotTypeMarkedReadOnly() async {
        let mutating = StubTool(name: "sensor.fake")
        let driver = SMLObservationCapabilityDriver(
            allowedSources: ["sensor.fake"],
            registry: ToolRegistry([mutating]),
            context: context()
        )
        let request = request(operation: .observe, reference: "sensor.fake")
        do {
            _ = try await driver.execute(invocation(request, driverID: driver.id))
            XCTFail("a non-ReadOnlyAgentTool observation source must be refused")
        } catch let error as SMLCapabilityDriverConfigurationError {
            XCTAssertEqual(error, .toolNotReadOnly(capability: "sensor.fake"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testObservationDriverRunsReadOnlyToolsAndPatchesOutput() async throws {
        let readOnly = ReadOnlyStubTool(name: "sensor.real")
        let driver = SMLObservationCapabilityDriver(
            allowedSources: ["sensor.real"],
            registry: ToolRegistry([readOnly]),
            context: context()
        )
        let request = request(operation: .observe, reference: "sensor.real",
                              arguments: ["output_field": .string("result")])
        let outcome = try await driver.execute(invocation(request, driverID: driver.id))
        XCTAssertEqual(outcome.status, .passed)
        XCTAssertEqual(outcome.statePatch["result"], .string("observed"))
    }

    func testObservationDriverCannotBypassRegistryArgumentGate() async throws {
        let capture = ArgumentCapture()
        var readOnly = ReadOnlyStubTool(name: "sensor.guarded")
        readOnly.parameters = [
            ToolParameter(
                name: "query",
                type: "string",
                description: "A required query"
            ),
        ]
        readOnly.capture = capture
        let driver = SMLObservationCapabilityDriver(
            allowedSources: ["sensor.guarded"],
            registry: ToolRegistry([readOnly]),
            context: context()
        )
        let request = request(
            operation: .observe,
            reference: "sensor.guarded",
            arguments: ["query": .bool(true)]
        )

        let outcome = try await driver.execute(invocation(request, driverID: driver.id))
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertNil(capture.projectRoot,
                     "invalid observation arguments must stop at ToolGate")
        XCTAssertTrue(outcome.statePatch.isEmpty)
    }

    // MARK: - Model driver

    func testModelDriverCollectsTextAndPatchesOutputField() async throws {
        let provider = ScriptedTextProvider(responses: ["A concise summary."])
        let driver = SMLModelCapabilityDriver(
            bindings: SMLModelPurposeBindings(purposes: [
                "summary": .init(providerId: provider.id, model: provider.defaultModel),
            ]),
            providers: ProviderRegistry(providers: [provider], retryDelaysNanoseconds: []),
            clock: { 2_000 }
        )
        let request = request(
            operation: .callModel, reference: "summary",
            arguments: [
                "prompt": .string("Summarize the state."),
                "output_field": .string("result"),
            ],
            state: ["topic": .string("drivers")]
        )
        XCTAssertTrue(driver.supports(request))
        let outcome = try await driver.execute(invocation(request, driverID: driver.id))
        XCTAssertEqual(outcome.status, .passed)
        XCTAssertEqual(outcome.statePatch["result"], .string("A concise summary."))
        // The prompt is host-shaped: explicit prompt + state snapshot, no hidden context.
        let prompt = provider.lastPrompt
        XCTAssertTrue(prompt.contains("Summarize the state."))
        XCTAssertTrue(prompt.contains("drivers"))
    }

    func testModelDriverTreatsEmptyResponseAsFailure() async throws {
        let provider = ScriptedTextProvider(responses: ["   \n"])
        let driver = SMLModelCapabilityDriver(
            bindings: SMLModelPurposeBindings(purposes: [
                "summary": .init(providerId: provider.id, model: provider.defaultModel),
            ]),
            providers: ProviderRegistry(providers: [provider], retryDelaysNanoseconds: [])
        )
        let request = request(operation: .callModel, reference: "summary",
                              arguments: ["output_field": .string("result")])
        let outcome = try await driver.execute(invocation(request, driverID: driver.id))
        XCTAssertEqual(outcome.status, .failed,
                       "whitespace-only model output must never become state")
        XCTAssertTrue(outcome.statePatch.isEmpty)
    }

    func testModelDriverSupportsOnlyBoundPurposes() {
        let driver = SMLModelCapabilityDriver(
            bindings: SMLModelPurposeBindings(purposes: [:]),
            providers: ProviderRegistry(providers: [], retryDelaysNanoseconds: [])
        )
        XCTAssertFalse(driver.supports(request(operation: .callModel, reference: "summary")))
    }

    // MARK: - Retrieval driver

    func testRetrievalDriverFailsClosedOnBrokenEmbedder() async throws {
        let driver = SMLRetrievalCapabilityDriver(
            bindings: SMLRetrievalSourceBindings(sources: [
                "kb.notes": .init(storePath: "/nonexistent/store.json",
                                  embeddingSpace: "test-space"),
            ]),
            embed: { _ in throw StubError.refused }
        )
        let request = request(operation: .retrieve, reference: "kb.notes",
                              arguments: ["output_field": .string("result")])
        let outcome = try await driver.execute(invocation(request, driverID: driver.id))
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.statePatch.isEmpty)
    }

    func testRetrievalDriverSupportsOnlyBoundSources() {
        let driver = SMLRetrievalCapabilityDriver(
            bindings: SMLRetrievalSourceBindings(sources: [:]),
            embed: { _ in [] }
        )
        XCTAssertFalse(driver.supports(request(operation: .retrieve, reference: "kb.notes")))
    }

    func testRetrievalQueryPrecedenceExplicitThenStateFieldThenReference() {
        let explicit = request(operation: .retrieve, reference: "kb",
                               arguments: ["query": .string("find X")])
        XCTAssertEqual(SMLRetrievalCapabilityDriver.query(for: explicit), "find X")

        let viaField = request(operation: .retrieve, reference: "kb",
                               arguments: ["query_field": .string("question")],
                               state: ["question": .string("what is Y")])
        XCTAssertEqual(SMLRetrievalCapabilityDriver.query(for: viaField), "what is Y")

        let fallback = request(operation: .retrieve, reference: "kb")
        XCTAssertEqual(SMLRetrievalCapabilityDriver.query(for: fallback), "kb")
    }

    // MARK: - Router disjointness (wiring contract)

    func testRouterRefusesAmbiguousDriversForOneReference() async throws {
        let toolA = StubTool(name: "cap.shared")
        let driverA = SMLToolCapabilityDriver(
            allowedCapabilities: ["cap.shared"],
            registry: ToolRegistry([toolA]),
            context: context()
        )
        let driverB = SMLToolCapabilityDriver(
            allowedCapabilities: ["cap.shared"],
            registry: ToolRegistry([toolA]),
            context: context()
        )
        let router = SMLCapabilityRouter(drivers: [driverA, driverB])
        XCTAssertThrowsError(
            try router.driverID(for: request(operation: .callTool, reference: "cap.shared")),
            "two drivers claiming one reference must be an error, not a silent first-wins"
        )
    }
}

/// Minimal text-only ChatProvider: emits scripted responses as one delta and records the prompt.
private final class ScriptedTextProvider: ChatProvider, @unchecked Sendable {
    let id = "scripted-text"
    let name = "Scripted Text"
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount = ""
    let defaultModel = "scripted-1"
    let availableModels = [AIModel(id: "scripted-1")]

    private let lock = NSLock()
    private var responses: [String]
    private var _lastPrompt = ""
    var lastPrompt: String {
        lock.lock(); defer { lock.unlock() }
        return _lastPrompt
    }

    init(responses: [String]) {
        self.responses = responses
    }

    func stream(
        messages: [ChatMessage],
        model: String,
        settings: ModelSettings,
        apiKey: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock()
        _lastPrompt = messages.last?.content ?? ""
        let next = responses.isEmpty ? "" : responses.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.delta(next))
            continuation.yield(.finish(reason: "stop"))
            continuation.finish()
        }
    }
}
