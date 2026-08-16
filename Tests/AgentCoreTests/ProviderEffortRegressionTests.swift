import XCTest
@testable import AgentCore

final class ProviderEffortRegressionTests: XCTestCase {
    func testProviderEffortMappingTable() {
        struct Mapping {
            let provider: String
            let model: String
            let effort: ProviderReasoningEffort
            let application: ProviderEffortApplication
            let control: ProviderReasoningNativeControl?
            let budget: Int?
        }
        let mappings: [Mapping] = [
            .init(provider: "openai", model: "gpt-5.6", effort: .none,
                  application: .applied, control: .openAIReasoningEffort("none"), budget: nil),
            .init(provider: "openai", model: "gpt-5.6", effort: .light,
                  application: .applied, control: .openAIReasoningEffort("low"), budget: nil),
            .init(provider: "openai", model: "gpt-5.6", effort: .deep,
                  application: .applied, control: .openAIReasoningEffort("high"), budget: nil),
            .init(provider: "google", model: "gemini-3-pro", effort: .light,
                  application: .applied, control: .geminiThinkingLevel("low"), budget: nil),
            .init(provider: "google", model: "gemini-2.5-flash", effort: .none,
                  application: .applied, control: .geminiThinkingBudget(0), budget: 0),
            .init(provider: "anthropic", model: "claude-fable-5", effort: .deep,
                  application: .applied,
                  control: .anthropic(thinking: nil, effort: "high"), budget: nil),
            .init(provider: "mimo", model: "mimo-v2", effort: .none,
                  application: .applied, control: .mimoThinking("disabled"), budget: nil),
            .init(provider: "openai", model: "o3", effort: .none,
                  application: .unsupported, control: nil, budget: nil),
            .init(provider: "anthropic", model: "claude-opus-4-6", effort: .light,
                  application: .providerManaged, control: nil, budget: nil),
        ]

        for mapping in mappings {
            let resolved = ProviderEffortMapper.resolve(
                providerID: mapping.provider, modelID: mapping.model,
                requested: mapping.effort, base: ModelSettings())
            XCTAssertEqual(resolved.record.application, mapping.application,
                           "\(mapping.provider)/\(mapping.model)/\(mapping.effort)")
            XCTAssertEqual(resolved.record.nativeControl, mapping.control)
            XCTAssertEqual(resolved.record.effectiveThinkingBudget, mapping.budget)
            XCTAssertEqual(resolved.settings.reasoningEffort, mapping.effort)
            XCTAssertEqual(resolved.settings.providerReasoningControl, mapping.control)
        }
    }

    func testExplicitNeutralEffortOverridesLegacyThinkingBoolean() {
        let deep = ProviderEffortMapper.resolve(
            providerID: "openai", modelID: "gpt-5.6", requested: .deep,
            base: ModelSettings(disableThinking: true, thinkingBudget: 777))
        XCTAssertFalse(deep.settings.disableThinking)
        XCTAssertNil(deep.settings.thinkingBudget)
        XCTAssertEqual(deep.settings.providerReasoningControl,
                       .openAIReasoningEffort("high"))

        let none = ProviderEffortMapper.resolve(
            providerID: "openai", modelID: "gpt-5.6", requested: .none,
            base: ModelSettings(disableThinking: false))
        XCTAssertTrue(none.settings.disableThinking)
        XCTAssertEqual(none.settings.providerReasoningControl,
                       .openAIReasoningEffort("none"))
    }

    func testLegacyLoopCheckpointDecodesWithoutProviderEffortRecords() throws {
        let checkpoint = LoopCheckpoint(id: "legacy", goal: "goal",
                                        providerId: "openai", model: "gpt-5",
                                        projectRoot: "/tmp/project", messages: [])
        let encoded = try JSONEncoder().encode(checkpoint)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "providerEffortRecords")
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(LoopCheckpoint.self, from: legacy)
        XCTAssertNil(decoded.providerEffortRecords)
        XCTAssertEqual(decoded.id, "legacy")
        XCTAssertEqual(decoded.goal, "goal")
    }
}
