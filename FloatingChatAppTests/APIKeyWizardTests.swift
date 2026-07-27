import XCTest
@testable import FloatingChatApp

/// In-memory keychain so the wizard tests never touch the real login Keychain.
private final class FakeKeychain: KeychainStoring {
    private var store: [String: String] = [:]
    func save(key: String, value: String) throws { store[key] = value }
    func get(key: String) -> String? { store[key] }
    func delete(key: String) throws { store[key] = nil }
    func exists(key: String) -> Bool { !(store[key] ?? "").isEmpty }
}

@MainActor
final class APIKeyWizardTests: XCTestCase {

    func testReload_coversEveryRegisteredProvider() {
        let model = APIKeyWizardModel(keychain: FakeKeychain())
        let providerIds = Set(ProviderManager.shared.availableProviders.map { $0.id })
        let rowIds = Set(model.rows.map { $0.id })
        XCTAssertEqual(rowIds, providerIds, "the wizard must list every registered provider")
        // The new cheap open-source providers are present.
        XCTAssertTrue(rowIds.contains("moonshot"))
        XCTAssertTrue(rowIds.contains("zhipu"))
        XCTAssertTrue(rowIds.contains("gemini"))
    }

    func testSaveKey_storesAndMarksHasKey_andClearsInput() {
        let fake = FakeKeychain()
        let model = APIKeyWizardModel(keychain: fake)
        guard let idx = model.rows.firstIndex(where: { $0.id == "anthropic" }) else {
            return XCTFail("anthropic row missing")
        }
        model.rows[idx].keyInput = "sk-ant-test123"
        model.saveKey(for: "anthropic")

        XCTAssertTrue(model.rows[idx].hasStoredKey)
        XCTAssertEqual(model.rows[idx].keyInput, "", "secret must be cleared from the field after saving")
        XCTAssertEqual(fake.get(key: "anthropic_api_key"), "sk-ant-test123")
    }

    func testClearKey_removesIt() {
        let fake = FakeKeychain()
        try? fake.save(key: "openai_api_key", value: "sk-existing")
        let model = APIKeyWizardModel(keychain: fake)
        XCTAssertTrue(model.rows.first { $0.id == "openai" }?.hasStoredKey ?? false)

        model.clearKey(for: "openai")
        XCTAssertFalse(model.rows.first { $0.id == "openai" }?.hasStoredKey ?? true)
        XCTAssertNil(fake.get(key: "openai_api_key"))
    }

    func testHasAnyUsableProvider_trueWhenLocalPresentOrKeySaved() {
        // Local providers (Ollama/MLX) need no key, so there's always a usable one.
        let model = APIKeyWizardModel(keychain: FakeKeychain())
        XCTAssertTrue(model.hasAnyUsableProvider)
    }

    func testSaveEmptyKey_isIgnored() {
        let fake = FakeKeychain()
        let model = APIKeyWizardModel(keychain: fake)
        guard let idx = model.rows.firstIndex(where: { $0.id == "gemini" }) else { return XCTFail() }
        model.rows[idx].keyInput = "   "
        model.saveKey(for: "gemini")
        XCTAssertFalse(model.rows[idx].hasStoredKey)
        XCTAssertNil(fake.get(key: "gemini_api_key"))
    }
}

// MARK: - New providers (Moonshot / Zhipu)

final class NewProvidersTests: XCTestCase {

    func testMoonshotRegisteredWithModels() {
        XCTAssertTrue(ProviderManager.shared.availableProviders.contains { $0.id == "moonshot" })
        let p = MoonshotProvider()
        XCTAssertFalse(p.availableModels.isEmpty)
        XCTAssertTrue(p.requiresAPIKey)
    }

    func testZhipuRegisteredWithModels() {
        XCTAssertTrue(ProviderManager.shared.availableProviders.contains { $0.id == "zhipu" })
        let p = ZhipuProvider()
        XCTAssertFalse(p.availableModels.isEmpty)
        XCTAssertTrue(p.requiresAPIKey)
    }

    @MainActor
    func testGetProvider_routesNewProvidersWithModelOverride() {
        let engine = AgentLoopEngine.shared
        let kimi = engine.getProvider(for: AgentConfig(id: "a", name: "a", provider: "moonshot", model: "kimi-k2-turbo-preview", role: .coder, color: "#000", systemPrompt: nil))
        XCTAssertEqual(kimi.selectedModel?.id, "kimi-k2-turbo-preview")
        let glm = engine.getProvider(for: AgentConfig(id: "b", name: "b", provider: "glm", model: "glm-4.5", role: .coder, color: "#000", systemPrompt: nil))
        XCTAssertEqual(glm.selectedModel?.id, "glm-4.5")
    }

    func testGLM52_isDefaultAndListed() {
        XCTAssertEqual(ZhipuProvider.defaultModelId, "glm-5.2")
        XCTAssertTrue(ZhipuProvider().availableModels.contains { $0.id == "glm-5.2" })
    }

    func testMiMoRegisteredWithModel() {
        XCTAssertTrue(ProviderManager.shared.availableProviders.contains { $0.id == "mimo" })
        XCTAssertEqual(MiMoProvider.defaultModelId, "mimo-v2.5-pro")
        XCTAssertTrue(MiMoProvider().availableModels.contains { $0.id == "mimo-v2.5-pro" })
    }

    @MainActor
    func testGetProvider_routesMiMoAndGLM52() {
        let engine = AgentLoopEngine.shared
        let mimo = engine.getProvider(for: AgentConfig(id: "a", name: "a", provider: "xiaomi", model: "mimo-v2.5-pro", role: .coder, color: "#000", systemPrompt: nil))
        XCTAssertEqual(mimo.selectedModel?.id, "mimo-v2.5-pro")
        let glm52 = engine.getProvider(for: AgentConfig(id: "b", name: "b", provider: "glm", model: "glm-5.2", role: .coder, color: "#000", systemPrompt: nil))
        XCTAssertEqual(glm52.selectedModel?.id, "glm-5.2")
    }
}
