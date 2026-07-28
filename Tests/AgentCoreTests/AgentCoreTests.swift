import XCTest
@testable import AgentCore

final class AgentCoreTests: XCTestCase {

    func testCatalogHasOpenAICompatibleProviders() {
        // MLX is also OpenAI-compatible (local), so it's in this set too.
        let ids = Set(ProviderCatalog.openAICompatible.map { $0.id })
        XCTAssertEqual(ids, [
            "mimo", "zhipu", "moonshot", "deepseek", "qwen", "doubao", "hunyuan", "ernie",
            "yi", "stepfun", "baichuan", "minimax", "openai", "grok", "mlx",
        ])
    }

    func testMakeBody_mapsRolesAndSettings() {
        let p = ProviderCatalog.openAICompatible.first { $0.id == "mimo" }!
        var s = ModelSettings(); s.maxTokens = 1234; s.systemPrompt = "SYS"; s.temperature = 0.5
        let body = p.makeBody(messages: [
            .init(role: .system, content: "ignored-extra"),
            .init(role: .user, content: "hi"),
            .init(role: .assistant, content: "yo")
        ], model: "mimo-v2.5-pro", settings: s, stream: true)
        let msgs = body["messages"] as? [[String: Any]]
        // settings.systemPrompt becomes the system message; the .system ChatMessage is dropped.
        XCTAssertEqual(msgs?.first?["role"] as? String, "system")
        XCTAssertEqual(msgs?.first?["content"] as? String, "SYS")
        XCTAssertEqual(msgs?.count, 3)
        XCTAssertEqual(msgs?[2]["role"] as? String, "assistant")
        // mimo-v2.5-pro is a reasoning model → its budget is floored (Layer A) so hidden reasoning can't
        // truncate the answer to empty. 1234 < floor ⇒ the request carries the floor.
        XCTAssertEqual(body["max_tokens"] as? Int, OpenAICompatibleProvider.reasoningTokenFloor)
        XCTAssertEqual(body["model"] as? String, "mimo-v2.5-pro")
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testMiMoThinkingDisabledOnlyWhenAgenticLoopRequestsIt() {
        let mimo = ProviderCatalog.openAICompatible.first { $0.id == "mimo" }!
        let deepseek = ProviderCatalog.openAICompatible.first { $0.id == "deepseek" }!
        let settings = ModelSettings(disableThinking: true)

        let mimoBody = mimo.makeBody(messages: [.init(role: .user, content: "hi")],
                                     model: "mimo-v2.5-pro", settings: settings, stream: true)
        let thinking = mimoBody["thinking"] as? [String: String]
        XCTAssertEqual(thinking?["type"], "disabled")

        let mimoNativeBody = mimo.makeBodyTools(messages: [.init(role: .user, content: "hi")],
                                                model: "mimo-v2.5-pro", settings: settings, tools: [], stream: true)
        let nativeThinking = mimoNativeBody["thinking"] as? [String: String]
        XCTAssertEqual(nativeThinking?["type"], "disabled")

        let normalMiMoBody = mimo.makeBody(messages: [.init(role: .user, content: "hi")],
                                           model: "mimo-v2.5-pro", settings: ModelSettings(), stream: true)
        XCTAssertNil(normalMiMoBody["thinking"])

        let deepseekBody = deepseek.makeBody(messages: [.init(role: .user, content: "hi")],
                                             model: "deepseek-chat", settings: settings, stream: true)
        XCTAssertNil(deepseekBody["thinking"], "thinking disable is a MiMo-specific request knob")
    }

    func testOpenAIPremiumModelsUseMaxCompletionTokens() {
        let openai = ProviderCatalog.openAICompatible.first { $0.id == "openai" }!
        var settings = ModelSettings()
        settings.maxTokens = 4321

        let textBody = openai.makeBody(messages: [.init(role: .user, content: "hi")],
                                       model: "gpt-5.5", settings: settings, stream: true)
        // gpt-5 / o-series are premium reasoning models: budget key is max_completion_tokens AND the
        // reasoning floor applies through it (4321 < floor ⇒ floored). Both contracts in one assertion.
        XCTAssertNil(textBody["max_tokens"])
        XCTAssertEqual(textBody["max_completion_tokens"] as? Int, OpenAICompatibleProvider.reasoningTokenFloor)
        XCTAssertNil(textBody["temperature"])
        XCTAssertNil(textBody["top_p"])

        let nativeBody = openai.makeBodyTools(messages: [.init(role: .user, content: "hi")],
                                              model: "o3", settings: settings, tools: [], stream: true)
        XCTAssertNil(nativeBody["max_tokens"])
        XCTAssertEqual(nativeBody["max_completion_tokens"] as? Int, OpenAICompatibleProvider.reasoningTokenFloor)
        XCTAssertNil(nativeBody["temperature"])
        XCTAssertNil(nativeBody["top_p"])
    }

    func testNonOpenAICompatibleProvidersKeepMaxTokens() {
        let deepseek = ProviderCatalog.openAICompatible.first { $0.id == "deepseek" }!
        var settings = ModelSettings()
        settings.maxTokens = 2222

        let body = deepseek.makeBody(messages: [.init(role: .user, content: "hi")],
                                     model: "deepseek-v4-pro", settings: settings, stream: true)
        XCTAssertEqual(body["max_tokens"] as? Int, 2222)
        XCTAssertNil(body["max_completion_tokens"])
    }

    func testGemini3ModelsOmitUnsupportedSamplingControls() {
        var settings = ModelSettings()
        settings.temperature = 0
        settings.topP = 0.1
        settings.maxTokens = 99

        let body = GeminiProvider().makeBody(messages: [.init(role: .user, content: "hi")],
                                             model: "gemini-3.1-pro", settings: settings)
        let generationConfig = body["generationConfig"] as? [String: Any]
        XCTAssertEqual(generationConfig?["maxOutputTokens"] as? Int, 99)
        XCTAssertNil(generationConfig?["temperature"])
        XCTAssertNil(generationConfig?["topP"])

        let older = GeminiProvider().makeBody(messages: [.init(role: .user, content: "hi")],
                                              model: "gemini-2.5-pro", settings: settings)
        let olderConfig = older["generationConfig"] as? [String: Any]
        XCTAssertEqual(olderConfig?["temperature"] as? Double, 0)
        XCTAssertEqual(olderConfig?["topP"] as? Double, 0.1)
    }

    func testEvents_parsesDeltaFinishUsageAndTolerates() {
        XCTAssertEqual(OpenAICompatibleProvider.events(fromSSE: "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}"), [.delta("hello")])
        XCTAssertEqual(OpenAICompatibleProvider.events(fromSSE: "{\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"}}]}"), [.reasoning("think")])
        XCTAssertEqual(OpenAICompatibleProvider.events(fromSSE: "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"), [.finish(reason: "stop")])
        XCTAssertEqual(OpenAICompatibleProvider.events(fromSSE: "{\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":5}}"), [.usage(promptTokens: 3, completionTokens: 5)])
        XCTAssertEqual(OpenAICompatibleProvider.events(fromSSE: "[DONE]"), [])
        XCTAssertEqual(OpenAICompatibleProvider.events(fromSSE: "not json"), [])
    }

    func testOpenAIToolAccumulatorReassemblesFragmentedArguments() {
        var acc = OpenAIToolCallAccumulator()

        XCTAssertEqual(acc.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"path\":\""}}]}}]}"#), [])
        XCTAssertEqual(acc.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"a.txt\"}"}}]}}]}"#), [])

        XCTAssertEqual(acc.finishToolCalls(), [
            .toolCall(id: "call_1", name: "read_file", argumentsJSON: #"{"path":"a.txt"}"#)
        ])
    }

    func testOpenAIToolAccumulatorKeepsInterleavedCallsSeparate() {
        var acc = OpenAIToolCallAccumulator()

        _ = acc.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\"path\":\"a"}},{"index":1,"id":"c2","function":{"name":"read_file","arguments":"{\"path\":\"b"}}]}}]}"#)
        _ = acc.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":".txt\"}"}},{"index":0,"function":{"arguments":".txt\"}"}}]}}]}"#)

        XCTAssertEqual(acc.finishToolCalls(), [
            .toolCall(id: "c1", name: "read_file", argumentsJSON: #"{"path":"a.txt"}"#),
            .toolCall(id: "c2", name: "read_file", argumentsJSON: #"{"path":"b.txt"}"#),
        ])
    }

    func testResolvedModel_honorsRequestedElseDefault() {
        let p = ProviderCatalog.openAICompatible.first { $0.id == "zhipu" }!
        XCTAssertEqual(p.resolvedModel("glm-4.6"), "glm-4.6")
        XCTAssertEqual(p.resolvedModel(nil), "glm-5.2")
        XCTAssertEqual(p.resolvedModel("auto"), "glm-5.2")
    }

    func testFileKeyStore_envFallback() {
        setenv("MIMO_API_KEY", "sk-test-env", 1)
        defer { unsetenv("MIMO_API_KEY") }
        let store = FileKeyStore(path: "/nonexistent/keys.json")
        XCTAssertEqual(store.key(forAccount: "mimo_api_key"), "sk-test-env")
        XCTAssertNil(store.key(forAccount: "no_such_key"))
    }

    func testFileKeyStoreRefusesGroupOrWorldReadableFiles() throws {
        let path = NSTemporaryDirectory() + "agentcore-keys-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #"{"mimo_api_key":"sk-from-file"}"#.write(toFile: path, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        XCTAssertFalse(FileKeyStore.isOwnerOnlySecretFile(path: path))
        XCTAssertNil(FileKeyStore(path: path).key(forAccount: "mimo_api_key"))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        XCTAssertTrue(FileKeyStore.isOwnerOnlySecretFile(path: path))
        XCTAssertEqual(FileKeyStore(path: path).key(forAccount: "mimo_api_key"), "sk-from-file")
    }

    #if canImport(Security)
    func testKeychainStoreFallsBackToOwnerOnlyFile() throws {
        let path = NSTemporaryDirectory() + "agentcore-keys-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #"{"mimo_api_key":"sk-from-file"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        let store = KeychainKeyStore(service: "com.agentcore.test.\(UUID().uuidString)",
                                     fileFallback: FileKeyStore(path: path))

        XCTAssertEqual(store.key(forAccount: "mimo_api_key"), "sk-from-file")
    }
    #endif

    func testRegistry_resolvesProviderAndKey() {
        // Deterministic in-test store (ignores ambient env, which may carry real keys).
        let reg = ProviderRegistry(keyStore: DictKeyStore(keys: ["deepseek_api_key": "sk-x"]))
        let ds = reg.provider(id: "deepseek")
        XCTAssertNotNil(ds)
        XCTAssertTrue(reg.hasKey(for: ds!))
        XCTAssertFalse(reg.hasKey(for: reg.provider(id: "grok")!))  // not in the dict
    }

    func testCatalogAll_hasExpectedProviders() {
        let ids = Set(ProviderCatalog.all.map { $0.id })
        XCTAssertEqual(ids, [
            "mimo", "zhipu", "moonshot", "deepseek", "qwen", "doubao", "hunyuan", "ernie",
            "yi", "stepfun", "baichuan", "minimax", "openai", "grok", "mlx",
            "anthropic", "gemini", "ollama",
            "claude-cli", "codex-cli",
        ])
        XCTAssertEqual(ProviderCatalog.all.count, 20)
    }

    func testCLIProviders_needNoKeyAndStayOffNativeTools() {
        // Subscription CLIs must never demand a key (the CLI holds the auth) and must never
        // claim native tool-calling (kist speaks the text protocol to them).
        for id in ["claude-cli", "codex-cli"] {
            let p = ProviderCatalog.all.first { $0.id == id }
            XCTAssertNotNil(p, "\(id) missing from catalog")
            XCTAssertFalse(p!.requiresAPIKey, "\(id) must not require an API key")
            XCTAssertFalse(p!.supportsNativeTools, "\(id) must use the text-protocol path")
        }
    }

    func testCLIProviderFlatten_preservesSystemPromptAndRoles() {
        let msgs = [ChatMessage(role: .user, content: "hi"),
                    ChatMessage(role: .assistant, content: "hello")]
        let flat = CLIChatProvider.flatten(msgs, systemPrompt: "be terse")
        XCTAssertTrue(flat.hasPrefix("[System]\nbe terse"), "settings systemPrompt must lead the prompt")
        XCTAssertTrue(flat.contains("[User]\nhi"))
        XCTAssertTrue(flat.contains("[Assistant]\nhello"))
    }

    func testProcessGroupRunner_stagedStdinReachesChild() {
        // The CLI providers deliver the whole prompt on stdin — pin that staged stdin actually
        // arrives (and that nil stdin still yields instant EOF, the pre-existing contract).
        let fed = ProcessGroupRunner.run(
            launchPath: "/bin/cat", launchArgs: [], cwd: "/",
            env: ["PATH": "/usr/bin:/bin"], timeoutSeconds: 10, capPerStream: 64 * 1024,
            stdinData: Data("stdin round-trip proof".utf8))
        XCTAssertEqual(fed.exitCode, 0)
        XCTAssertEqual(fed.stdout, "stdin round-trip proof")
        let empty = ProcessGroupRunner.run(
            launchPath: "/bin/cat", launchArgs: [], cwd: "/",
            env: ["PATH": "/usr/bin:/bin"], timeoutSeconds: 10, capPerStream: 64 * 1024)
        XCTAssertEqual(empty.exitCode, 0)
        XCTAssertEqual(empty.stdout, "")
    }

    func testCatalogDefaultsArePremiumTier() {
        let defaults = Dictionary(uniqueKeysWithValues: ProviderCatalog.all.map { ($0.id, $0.defaultModel) })
        XCTAssertEqual(defaults["openai"], "gpt-5.5")
        XCTAssertEqual(defaults["grok"], "grok-4.3")
        XCTAssertEqual(defaults["deepseek"], "deepseek-v4-pro")
        XCTAssertEqual(defaults["anthropic"], "claude-fable-5")
        XCTAssertEqual(defaults["gemini"], "gemini-2.5-flash")
        XCTAssertEqual(defaults["hunyuan"], "hunyuan-pro")
        XCTAssertEqual(defaults["doubao"], "doubao-pro-128k")
        XCTAssertEqual(defaults["moonshot"], "kimi-k2-turbo-preview")
    }

    func testLocalProviders_needNoKey() {
        let reg = ProviderRegistry(keyStore: DictKeyStore(keys: [:]))
        XCTAssertTrue(reg.hasKey(for: reg.provider(id: "mlx")!))    // local, no key required
        XCTAssertTrue(reg.hasKey(for: reg.provider(id: "ollama")!))
        XCTAssertFalse(reg.hasKey(for: reg.provider(id: "anthropic")!))
    }

    func testAnthropicEvents_parsesDeltaAndStop() {
        XCTAssertEqual(AnthropicProvider.events(fromSSE: "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}"), [.delta("hi")])
        XCTAssertEqual(AnthropicProvider.events(fromSSE: "{\"type\":\"message_stop\"}"), [.finish(reason: nil)])
    }

    func testGeminiEvents_parsesParts() {
        XCTAssertEqual(GeminiProvider.events(fromSSE: "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"yo\"}]}}]}"), [.delta("yo")])
    }

    func testGeminiEvents_emitsFinishAndUsage() {
        let chunk = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"end\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":7,\"candidatesTokenCount\":3}}"
        XCTAssertEqual(GeminiProvider.events(fromSSE: chunk),
                       [.delta("end"), .finish(reason: "STOP"), .usage(promptTokens: 7, completionTokens: 3)])
    }

    func testAnthropicEvents_messageStartEmitsInputUsage() {
        XCTAssertEqual(AnthropicProvider.events(fromSSE: "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":42}}}"),
                       [.usage(promptTokens: 42, completionTokens: 0)])
    }

    // Vision is genuinely wired (userContent encodes Anthropic image blocks — see ProviderVisionEncodingTests),
    // so claiming it is HONEST, not over-claiming. Every Claude model advertises vision so the REPL can
    // auto-route images to Claude (previously deferred with a now-removed stale comment).
    func testAnthropicModels_advertiseVisionSinceEncoderIsWired() {
        XCTAssertTrue(AnthropicProvider().availableModels.allSatisfy { $0.isVision })
    }

    func testOllamaEvents_parsesNDJSONLine() {
        XCTAssertEqual(OllamaProvider.events(fromLine: "{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"done\":false}"), [.delta("ok")])
    }

    func testOllamaBody_forwardsMaxTokens() {
        var s = ModelSettings(); s.maxTokens = 777
        let body = OllamaProvider().makeBody(messages: [.init(role: .user, content: "hi")], model: "llama3.1", settings: s)
        let options = body["options"] as? [String: Any]
        XCTAssertEqual(options?["num_predict"] as? Int, 777)
    }

    func testProviderErrorRetryable() {
        XCTAssertTrue(AIProviderError.rateLimited.isRetryable)
        XCTAssertTrue(AIProviderError.http(status: 503, body: "").isRetryable)
        XCTAssertFalse(AIProviderError.invalidAPIKey.isRetryable)
    }
}

/// Deterministic key store for tests (no env/keychain).
private struct DictKeyStore: KeyStore {
    let keys: [String: String]
    func key(forAccount account: String) -> String? { keys[account] }
}
