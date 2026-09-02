import XCTest
@testable import AgentCore

/// The capability layer is what makes "uses all AIs" HONEST: cloud models get native tool-calling,
/// local/small models fall to the universal text protocol instead of silently failing a tools API.
final class ProviderCapabilitiesTests: XCTestCase {

    private let registry = ProviderRegistry(providers: ProviderCatalog.all, keyStore: NullKeys())

    // MARK: - Per-provider capability resolution

    func testCloudOpenAICompatIsNative() {
        XCTAssertTrue(registry.capabilities(providerId: "openai", model: "gpt-4o").nativeTools)
        XCTAssertTrue(registry.capabilities(providerId: "grok", model: nil).nativeTools)
    }

    func testOpenAICompatibleVersionedAliasesUseExactThenLongestBoundaryMatch() {
        let provider = OpenAICompatibleProvider(
            id: "alias-test", name: "Alias Test", iconName: "cpu", keyAccount: "alias-test",
            endpoint: "https://example.invalid/v1/chat/completions", defaultModel: "gpt-5.5",
            availableModels: [
                AIModel(id: "gpt-5", isVision: false, isLocal: true, contextWindowTokens: 100),
                AIModel(id: "gpt-5.5", isVision: true, contextWindowTokens: 200),
                AIModel(id: "gpt-5.5-preview", isVision: false, isLocal: true,
                        contextWindowTokens: 300),
            ])

        let versioned = provider.capabilities(forModel: "gpt-5.5-2026-09-01")
        XCTAssertTrue(versioned.vision)
        XCTAssertTrue(versioned.nativeTools)
        XCTAssertEqual(versioned.contextWindowTokens, 200,
                       "the longest id prefix must win over gpt-5")

        let exact = provider.capabilities(forModel: "gpt-5.5-preview")
        XCTAssertFalse(exact.vision)
        XCTAssertFalse(exact.nativeTools)
        XCTAssertEqual(exact.contextWindowTokens, 300,
                       "exact metadata must win over the gpt-5.5 prefix")

        let sibling = provider.capabilities(forModel: "gpt-5.50-preview")
        XCTAssertFalse(sibling.vision)
        XCTAssertTrue(sibling.nativeTools)
        XCTAssertNil(sibling.contextWindowTokens,
                     "a sibling id must not inherit gpt-5.5 or gpt-5 metadata")
    }

    func testDeepSeekDefaultsToTextProtocol() {
        // DeepSeek is OpenAI-compatible, but its native multi-turn tool history can 400. Keep it
        // useful by defaulting to Mythos's text protocol; explicit --tools native can still test it.
        XCTAssertFalse(registry.capabilities(providerId: "deepseek", model: nil).nativeTools)
        XCTAssertFalse(registry.usesNativeTools(providerId: "deepseek", model: nil, mode: .auto))
        XCTAssertTrue(registry.usesNativeTools(providerId: "deepseek", model: nil, mode: .native))
    }

    func testMLXLocalDegradesToText() {
        // THE honesty fix: a local MLX model must NOT be force-routed to native tool-calling.
        XCTAssertFalse(registry.capabilities(providerId: "mlx", model: "mlx-community/Llama-3.2-3B-Instruct-4bit").nativeTools)
        // Even with no explicit model (resolves to the local default) it stays text.
        XCTAssertFalse(registry.capabilities(providerId: "mlx", model: nil).nativeTools)
    }

    func testOllamaLocalIsText() {
        XCTAssertFalse(registry.capabilities(providerId: "ollama", model: "llama3.1").nativeTools)
    }

    func testMiMoDegradesToTextDespiteBeingCloud() {
        // MiMo's native tools 400 on the 2nd round (XiaomiMiMo/MiMo#44) — must route to the TEXT protocol.
        XCTAssertFalse(registry.capabilities(providerId: "mimo", model: "mimo-v2.5-pro").nativeTools)
        XCTAssertFalse(registry.capabilities(providerId: "mimo", model: nil).nativeTools)
        XCTAssertFalse(registry.usesNativeTools(providerId: "mimo", model: nil, mode: .auto),
                       "auto must NOT route MiMo to native — it dies on round 2; text exposes the same tools")
    }

    func testMiMoAdvertisesMillionTokenContextForWindowManager() {
        XCTAssertEqual(registry.capabilities(providerId: "mimo", model: "mimo-v2.5-pro").contextWindowTokens, 1_000_000)
        XCTAssertEqual(registry.capabilities(providerId: "mimo", model: nil).contextWindowTokens, 1_000_000)
    }

    func testEveryOtherChineseModelIsNativeCapable() {
        for p in ["qwen", "zhipu", "moonshot", "doubao", "hunyuan", "ernie", "yi", "stepfun", "baichuan", "minimax"] {
            XCTAssertTrue(registry.capabilities(providerId: p, model: nil).nativeTools, "\(p) should be native-capable")
        }
    }

    func testMiMoStillForceableToNativeAndAlwaysReachableViaText() {
        XCTAssertFalse(registry.usesNativeTools(providerId: "mimo", model: nil, mode: .text))
        // --tools native is an explicit user override (their risk) — it must still be honored.
        XCTAssertTrue(registry.usesNativeTools(providerId: "mimo", model: nil, mode: .native))
    }

    func testAnthropicAndGeminiAreNative() {
        XCTAssertTrue(registry.capabilities(providerId: "anthropic", model: nil).nativeTools)
        XCTAssertTrue(registry.capabilities(providerId: "gemini", model: nil).nativeTools)
    }

    func testGeminiAdvertisesMultimodalRoutingCapabilities() {
        let caps = registry.capabilities(providerId: "gemini", model: "gemini-3.1-pro")
        XCTAssertTrue(caps.nativeTools)
        XCTAssertTrue(caps.vision)
        XCTAssertTrue(caps.video)
        XCTAssertTrue(caps.audio)
        XCTAssertTrue(caps.structuredOutput)
        XCTAssertEqual(caps.contextWindowTokens, 1_000_000)
        XCTAssertTrue(caps.summaryFlags.contains("video"))
        XCTAssertTrue(caps.summaryFlags.contains("audio"))
        XCTAssertTrue(caps.summaryFlags.contains("structured-output"))
    }

    func testProviderHealthRendersCapabilityFlags() {
        let keyed = ProviderRegistry(providers: ProviderCatalog.all, keyStore: AllKeys())
        let report = ProviderHealthChecker.catalogReport(keyed)
        let rendered = report.render()
        XCTAssertTrue(rendered.contains("gemini:gemini-2.5-flash"))
        XCTAssertTrue(rendered.contains("video"))
        XCTAssertTrue(rendered.contains("structured-output"))
    }

    func testUnknownProviderIsTextSafest() {
        XCTAssertFalse(registry.capabilities(providerId: "does-not-exist", model: nil).nativeTools)
    }

    // MARK: - ToolMode routing matrix

    func testAutoFollowsCapability() {
        XCTAssertTrue(registry.usesNativeTools(providerId: "openai", model: "gpt-4o", mode: .auto))
        XCTAssertFalse(registry.usesNativeTools(providerId: "mlx", model: nil, mode: .auto))
    }

    func testNativeForcesNativeEvenForLocal() {
        XCTAssertTrue(registry.usesNativeTools(providerId: "mlx", model: nil, mode: .native))
    }

    func testTextForcesTextEvenForCloud() {
        XCTAssertFalse(registry.usesNativeTools(providerId: "openai", model: "gpt-4o", mode: .text))
        XCTAssertFalse(registry.usesNativeTools(providerId: "gemini", model: nil, mode: .text))
    }

    func testToolModeParsesAllCases() {
        XCTAssertEqual(ToolMode(rawValue: "auto"), .auto)
        XCTAssertEqual(ToolMode(rawValue: "native"), .native)
        XCTAssertEqual(ToolMode(rawValue: "text"), .text)
        XCTAssertNil(ToolMode(rawValue: "bogus"))
        XCTAssertEqual(Set(ToolMode.allCases), [.auto, .native, .text])
    }

    // MARK: - MIMO_BASE_URL override contract (Token-Plan dedicated endpoints)

    func testResolveEndpointFallsBackWhenBaseAbsentOrBlank() {
        let fb = "https://api.xiaomimimo.com/v1/chat/completions"
        XCTAssertEqual(ProviderCatalog.resolveEndpoint(base: nil, fallback: fb), fb)
        XCTAssertEqual(ProviderCatalog.resolveEndpoint(base: "", fallback: fb), fb)
        XCTAssertEqual(ProviderCatalog.resolveEndpoint(base: "   ", fallback: fb), fb)
    }

    func testResolveEndpointAppendsChatCompletionsToBase() {
        // A Token-Plan dedicated base (…/v1) gets the chat-completions path appended, trailing slash or not.
        let fb = "https://api.xiaomimimo.com/v1/chat/completions"
        XCTAssertEqual(ProviderCatalog.resolveEndpoint(base: "https://token-plan-sgp.xiaomimimo.com/v1", fallback: fb),
                       "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions")
        XCTAssertEqual(ProviderCatalog.resolveEndpoint(base: "https://token-plan-sgp.xiaomimimo.com/v1/", fallback: fb),
                       "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions")
    }

    func testResolveEndpointPassesThroughFullChatCompletionsURL() {
        let fb = "https://api.xiaomimimo.com/v1/chat/completions"
        let full = "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions"
        XCTAssertEqual(ProviderCatalog.resolveEndpoint(base: full, fallback: fb), full)
    }
}

private struct NullKeys: KeyStore {
    func key(forAccount account: String) -> String? { account == "openai_api_key" ? "k" : nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private struct AllKeys: KeyStore {
    func key(forAccount account: String) -> String? { "k" }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}
