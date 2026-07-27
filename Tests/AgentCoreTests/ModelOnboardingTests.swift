import XCTest
@testable import AgentCore

/// A deterministic ChatProvider that drives the onboarding pipeline down chosen paths.
/// It answers the real probe prompts by content sniffing, and lets each test pick the
/// native-tools / completion behavior.
private struct FakeProvider: ChatProvider {
    let id: String
    var name = "Fake"
    var requiresAPIKey = true
    let keyAccount: String
    let defaultModel: String
    var availableModels: [AIModel] = []

    var completionThrows = false      // stage 2: model can't complete at all
    var emitToolCallRound1 = true     // native probe round 1 emits a tool call
    var round2Throws400 = false       // native probe round 2 rejects history (MiMo/DeepSeek signature)
    var gripToolName = "read_file"    // tool name the grip probe will emit (test hallucination by changing it)
    var decisionGarbage = false       // decision probe gets unparseable output → decision .fail

    var supportsNativeTools: Bool { true }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let joined = messages.map { $0.content }.joined(separator: "\n") + "\n" + settings.systemPrompt
        let fails = completionThrows
        let reply: String
        if joined.contains("Reply with exactly: OK") {
            reply = "OK"
        } else if joined.contains("README.md") {
            reply = "{\"thinking\":\"read the file\",\"tool\":\"\(gripToolName)\",\"parameters\":{\"path\":\"README.md\"}}"
        } else if joined.contains("42") {
            reply = decisionGarbage ? "sorry, I really can't tell what to do here"
                                    : #"{"thinking":"already known","done":true,"summary":"The answer is 42"}"#
        } else {
            reply = "OK"
        }
        return AsyncThrowingStream { c in
            if fails { c.finish(throwing: AIProviderError.transport("simulated failure")) }
            else { c.yield(.delta(reply)); c.finish() }
        }
    }

    func streamTools(messages: [ChatMessage], model: String, settings: ModelSettings,
                     apiKey: String?, tools: [ToolSpec]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let isRound2 = messages.contains { $0.role == .assistant && ($0.toolCalls?.isEmpty == false) }
            || messages.contains { $0.role == .tool }
        let emit1 = emitToolCallRound1
        let throw400 = round2Throws400
        return AsyncThrowingStream { c in
            if isRound2 {
                if throw400 { c.finish(throwing: AIProviderError.http(status: 400, body: "Param Incorrect")) }
                else { c.yield(.delta("done")); c.finish() }
            } else {
                if emit1 { c.yield(.toolCall(id: "c1", name: "get_time", argumentsJSON: "{}")); c.finish() }
                else { c.yield(.delta("no tool")); c.finish() }
            }
        }
    }
}

final class ModelOnboardingTests: XCTestCase {
    private func makeRegistry(_ fake: FakeProvider) -> ProviderRegistry {
        ProviderRegistry(providers: [fake],
                         keyStore: OverlayKeyStore(overlay: [fake.keyAccount: "k"], base: FileKeyStore(path: "/nonexistent")),
                         retryDelaysNanoseconds: [],
                         retrySleep: { _ in })
    }

    private func draft(defaultModel: String, isLocal: Bool = false) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(id: "fake", name: "Fake", iconName: "plus.app", keyAccount: "custom_fake_api_key",
                                 endpoint: "https://fake.test/v1/chat/completions", defaultModel: defaultModel,
                                 availableModels: [AIModel(id: defaultModel)],
                                 requiresAPIKey: true, isLocal: isLocal, nativeToolsSupported: true)
    }

    private func fetch(_ ids: [String]) -> ModelOnboarding.ModelsFetch {
        { _, _ in .success(ids) }
    }

    func testFullPassWhenEverythingWorks() async {
        let fake = FakeProvider(id: "fake", keyAccount: "custom_fake_api_key", defaultModel: "good-model")
        let result = await ModelOnboarding.run(provider: draft(defaultModel: "good-model"),
                                               registry: makeRegistry(fake),
                                               fetch: fetch(["good-model"]))
        XCTAssertEqual(result.verdict, .pass)
        XCTAssertTrue(result.provider.nativeToolsSupported, "round-2 OK → native tools stay on")
        XCTAssertNil(result.healedModelId, "exact id needs no heal")
        XCTAssertEqual(result.provider.defaultModel, "good-model")
    }

    func testSelfHealsModelId() async {
        let fake = FakeProvider(id: "fake", keyAccount: "custom_fake_api_key", defaultModel: "good-model")
        let result = await ModelOnboarding.run(provider: draft(defaultModel: "bad-model"),
                                               registry: makeRegistry(fake),
                                               fetch: fetch(["good-model"]))
        XCTAssertEqual(result.healedModelId, "good-model")
        XCTAssertEqual(result.provider.defaultModel, "good-model")
        XCTAssertTrue(result.provider.availableModels.contains { $0.id == "good-model" })
    }

    func testCompletionFailureIsFailVerdict() async {
        let fake = FakeProvider(id: "fake", keyAccount: "custom_fake_api_key",
                                defaultModel: "good-model", completionThrows: true)
        let result = await ModelOnboarding.run(provider: draft(defaultModel: "good-model"),
                                               registry: makeRegistry(fake),
                                               fetch: fetch(["good-model"]))
        XCTAssertEqual(result.verdict, .fail, "no usable completion must not pass")
        XCTAssertTrue(result.stages.contains { $0.name == "completion" && $0.status == .fail })
        XCTAssertFalse(result.stages.contains { $0.name == "tool-grip" }, "should short-circuit before probes")
    }

    func testNativeToolsAutoDisabledOnRound2_400() async {
        let fake = FakeProvider(id: "fake", keyAccount: "custom_fake_api_key",
                                defaultModel: "good-model", round2Throws400: true)
        let result = await ModelOnboarding.run(provider: draft(defaultModel: "good-model"),
                                               registry: makeRegistry(fake),
                                               fetch: fetch(["good-model"]))
        XCTAssertEqual(result.verdict, .partial, "drives the loop but native tools broken → text protocol")
        XCTAssertFalse(result.provider.nativeToolsSupported, "round-2 400 must flip native tools OFF")
        let native = result.stages.first { $0.name == "native-tools" }
        XCTAssertEqual(native?.status, .partial)
        XCTAssertTrue(native?.detail.contains("400") ?? false)
    }

    func testHallucinatedToolNameFailsGripAndVerdict() async {
        // Grip probe must reject a tool the real registry doesn't have (Codex Finding 3).
        let fake = FakeProvider(id: "fake", keyAccount: "custom_fake_api_key",
                                defaultModel: "good-model", gripToolName: "totally_made_up_tool")
        let result = await ModelOnboarding.run(provider: draft(defaultModel: "good-model"),
                                               registry: makeRegistry(fake),
                                               fetch: fetch(["good-model"]))
        let grip = result.stages.first { $0.name == "tool-grip" }
        XCTAssertEqual(grip?.status, .fail)
        XCTAssertTrue(grip?.detail.contains("unknown tool") ?? false)
        XCTAssertEqual(result.verdict, .fail, "a core probe failing must be a hard FAIL, never partial")
    }

    func testDecisionFailureIsHardFail() async {
        // A model that can act (grip) but won't follow a finish instruction must still hard-fail.
        let fake = FakeProvider(id: "fake", keyAccount: "custom_fake_api_key",
                                defaultModel: "good-model", decisionGarbage: true)
        let result = await ModelOnboarding.run(provider: draft(defaultModel: "good-model"),
                                               registry: makeRegistry(fake),
                                               fetch: fetch(["good-model"]))
        XCTAssertEqual(result.stages.first { $0.name == "decision" }?.status, .fail)
        XCTAssertEqual(result.verdict, .fail, "core decision-probe failure = hard FAIL, never partial")
    }

    func testNoModelsListSkipsHealButStillRuns() async {
        let fake = FakeProvider(id: "fake", keyAccount: "custom_fake_api_key", defaultModel: "entered-model")
        let result = await ModelOnboarding.run(
            provider: draft(defaultModel: "entered-model"),
            registry: makeRegistry(fake),
            fetch: { _, _ in .failure(AIProviderError.transport("no /models")) })
        XCTAssertNil(result.healedModelId)
        XCTAssertEqual(result.provider.defaultModel, "entered-model")
        XCTAssertTrue(result.stages.contains { $0.name == "model-id" && $0.status == .skipped })
        XCTAssertEqual(result.verdict, .pass, "completion + grip + decision + native all fine")
    }
}
