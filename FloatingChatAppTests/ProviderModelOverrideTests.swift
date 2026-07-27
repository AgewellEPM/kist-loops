import XCTest
@testable import FloatingChatApp

/// Per-agent model selection must work for EVERY provider (multi-site contract),
/// not just Gemini — getProvider applies a non-persisting modelOverride.
@MainActor
final class ProviderModelOverrideTests: XCTestCase {

    private func agent(provider: String, model: String) -> AgentConfig {
        AgentConfig(id: "a", name: "a", provider: provider, model: model, role: .coder, color: "#000", systemPrompt: nil)
    }

    func testGetProvider_honorsPerAgentModelForEveryProvider() {
        let engine = AgentLoopEngine.shared
        // (provider id, a concrete model the agent asks for)
        let sites: [(String, String)] = [
            ("anthropic", "claude-sonnet-4-5-20250514"),
            ("openai", "gpt-4o-mini"),
            ("gemini", "gemini-2.5-pro"),
            ("deepseek", "deepseek-reasoner"),
            ("grok", "grok-2-latest"),
            ("ollama", "llama3.1:70b"),
            ("mlx", "mlx-community/Qwen2.5-7B-Instruct-4bit")
        ]
        for (provider, model) in sites {
            let resolved = engine.getProvider(for: agent(provider: provider, model: model))
            XCTAssertEqual(resolved.selectedModel?.id, model,
                           "provider '\(provider)' must honor the agent's model '\(model)'")
        }
    }

    func testGetProvider_userSelectedDefersToUISelection() {
        let engine = AgentLoopEngine.shared
        // user_selected must NOT apply the agent.model — it defers to the user's
        // currently-selected provider+model.
        let resolved = engine.getProvider(for: agent(provider: "user_selected", model: "totally-made-up-model"))
        XCTAssertNotEqual(resolved.selectedModel?.id, "totally-made-up-model")
    }

    func testGetProvider_emptyOrAutoModelUsesProviderDefault() {
        let engine = AgentLoopEngine.shared
        // "auto"/"" => no override; provider falls back to its own default.
        let auto = engine.getProvider(for: agent(provider: "openai", model: "auto"))
        XCTAssertNotEqual(auto.selectedModel?.id, "auto", "'auto' must not be treated as a literal model id")
    }
}
