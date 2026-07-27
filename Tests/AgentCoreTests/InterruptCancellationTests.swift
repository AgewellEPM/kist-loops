import XCTest
import Foundation
@testable import AgentCore

/// esc-to-interrupt (Increment B): the REPL cancels the turn's Task on ESC; the loop must observe
/// `Task.isCancelled` and finish CLEANLY as "interrupted" + persist the checkpoint as PAUSED (resumable),
/// rather than spinning to completion or surfacing the cancellation as a provider error.
final class InterruptCancellationTests: XCTestCase {
    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "intr-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }

    /// Sleeps INSIDE stream() — which runs in the loop's task — so cancelling the task throws a
    /// CancellationError out of the model call, exercising the loop's interrupt handling.
    private final class SleepyProvider: ChatProvider, @unchecked Sendable {
        let id = "sleep", name = "sleep", iconName = "cpu"
        let requiresAPIKey = false, keyAccount = "sleep", defaultModel = "sleep-1"
        let availableModels = [AIModel(id: "sleep-1")]
        func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
            try await Task.sleep(nanoseconds: 5_000_000_000)   // cancelled long before this elapses
            return AsyncThrowingStream { c in c.yield(.delta(#"{"done":true,"summary":"ok"}"#)); c.finish() }
        }
    }
    private struct Keys: KeyStore { func key(forAccount account: String) -> String? { nil } }

    func testCancelDuringTurnFinishesInterrupted() async throws {
        let loop = HeadlessAgentLoop(providers: ProviderRegistry(providers: [SleepyProvider()], keyStore: Keys()),
                                     providerId: "sleep", model: nil, tools: .headless(),
                                     context: ToolContext(projectRoot: root), maxIterations: 4)
        let task = Task { await loop.run(goal: "do a thing") }
        try await Task.sleep(nanoseconds: 200_000_000)   // let it enter the model call
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome.summary, "interrupted")
        XCTAssertFalse(outcome.success)
    }
}
