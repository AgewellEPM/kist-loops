import XCTest
@testable import AgentCore

final class SpawnAgentPromptBriefTests: XCTestCase {
    func testSpawnAgentSendsCompiledSelfContainedBriefToSubAgent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-brief-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "local routing evidence".write(to: root.appendingPathComponent("evidence.txt"),
                                            atomically: true, encoding: .utf8)

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
        ], context: ToolContext(projectRoot: root.path))

        XCTAssertTrue(result.success, result.error ?? "")
        let userPrompt = await provider.initialUserPrompt()
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
        let call = await store.record(messages)
        return AsyncThrowingStream { continuation in
            if call == 1 {
                continuation.yield(.delta(#"{"tool":"read_file","parameters":{"path":"evidence.txt"}}"#))
            } else {
                continuation.yield(.delta(#"{"done":true,"summary":"captured"}"#))
            }
            continuation.finish()
        }
    }

    func initialUserPrompt() async -> String {
        await store.initialUserPrompt()
    }
}

private actor BriefMessageStore {
    private var batches: [[ChatMessage]] = []

    func record(_ messages: [ChatMessage]) -> Int {
        batches.append(messages)
        return batches.count
    }

    func initialUserPrompt() -> String {
        batches.first?.last(where: { $0.role == .user })?.content ?? ""
    }
}
