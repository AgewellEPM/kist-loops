import XCTest
@testable import AgentCore

final class SpawnAgentPromptBriefTests: XCTestCase {
    func testSpawnAgentSendsCompiledSelfContainedBriefToSubAgent() async throws {
        let provider = BriefCaptureProvider()
        let registry = ProviderRegistry(providers: [provider], keyStore: BriefNullKeyStore())
        let spawn = SpawnAgentTool(
            providers: registry,
            providerId: "capture",
            model: nil,
            baseTools: .headless(),
            maxIterations: 2
        )

        let result = try await spawn.execute(arguments: [
            "role": "researcher",
            "task": "deep dive the latest model-role routing design and report source limits",
        ], context: ToolContext(projectRoot: NSTemporaryDirectory()))

        XCTAssertTrue(result.success, result.error ?? "")
        let userPrompt = await provider.lastUserPrompt()
        XCTAssertTrue(userPrompt.contains("TASK BRIEF"))
        XCTAssertTrue(userPrompt.contains("Original user request:"))
        XCTAssertTrue(userPrompt.contains("deep dive the latest model-role routing design"))
        XCTAssertTrue(userPrompt.contains("Suggested role: worker"))
        XCTAssertTrue(userPrompt.contains("Treat this as self-contained"))
        XCTAssertTrue(userPrompt.contains("use web_search or another available search-capable MCP/tool"))
    }
}

private struct BriefNullKeyStore: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private final class BriefCaptureProvider: ChatProvider {
    let id = "capture"
    let name = "Capture"
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount = "capture"
    let defaultModel = "capture-1"
    let availableModels = [AIModel(id: "capture-1")]

    private let store = BriefMessageStore()

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        await store.record(messages)
        return AsyncThrowingStream { continuation in
            continuation.yield(.delta(#"{"done":true,"summary":"captured"}"#))
            continuation.finish()
        }
    }

    func lastUserPrompt() async -> String {
        await store.lastUserPrompt()
    }
}

private actor BriefMessageStore {
    private var batches: [[ChatMessage]] = []

    func record(_ messages: [ChatMessage]) {
        batches.append(messages)
    }

    func lastUserPrompt() -> String {
        batches.last?.last(where: { $0.role == .user })?.content ?? ""
    }
}
