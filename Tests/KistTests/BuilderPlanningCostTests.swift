import XCTest
import AgentCore
@testable import Kist

final class BuilderPlanningCostTests: XCTestCase {
    func testPreflightRejectsInterpreterFormsThatExecutionWouldDeny() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (executable, arguments) in [("python3", ["-c", "print(1)"]), ("ruby", ["-e", "puts 1"])] {
            let value: [String: Any] = ["schema_version": 1, "adapter": "headless",
                "operations": [["kind": "create", "path": "card.json"]], "partitions": [],
                "verification_commands": [["executable": executable, "arguments": arguments, "timeout_seconds": 30]]]
            let plan = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            XCTAssertThrowsError(try KistRunner.builderParsePreflightPlan(plan, adapter: .headless,
                projectRoot: root.path, maxPartitions: 1)) { error in
                XCTAssertTrue(error.localizedDescription.contains("unsafe verification command"))
                XCTAssertFalse(KistRunner.localPlanningCanEscalate(error), "Execution policy denials must not trigger a provider retry")
            }
        }
        let valid = #"{"schema_version":1,"adapter":"headless","operations":[{"kind":"create","path":"card.json"}],"verification_commands":[{"executable":"python3","arguments":["-m","json.tool","card.json"],"timeout_seconds":30}],"partitions":[]}"#
        XCTAssertEqual(try KistRunner.builderParsePreflightPlan(valid, adapter: .headless,
            projectRoot: root.path, maxPartitions: 1).verificationCommands.first?.arguments, ["-m", "json.tool", "card.json"])
    }

    func testBareInterpreterCannotBecomeASealedVerificationCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = #"{"schema_version":1,"adapter":"headless","operations":[{"kind":"create","path":"New.swift"}],"verification_commands":[{"executable":"python3","arguments":[],"timeout_seconds":30}],"partitions":[]}"#
        XCTAssertThrowsError(try KistRunner.builderParsePreflightPlan(plan, adapter: .headless,
            projectRoot: root.path, maxPartitions: 1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("verification command has no script"))
        }
        XCTAssertTrue(KistRunner.localPlanningCanEscalate(KistRunner.BuilderPreflightError.invalid(
            "planner-quality: verification command has no script, module or subcommand; initial_output{hash}")))
    }

    func testDuplicateOperationsStopAfterOneCallWithoutInventingRepairAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = DuplicatePlanProvider()
        do {
            _ = try await KistRunner.builderGeneratePreflightEnvelope(adapter: .headless,
                projectRoot: root.path, goal: "create New.swift", contractID: "bounded-duplicate",
                registry: ProviderRegistry(providers: [provider]), providerID: provider.id,
                model: provider.defaultModel, budget: BudgetLedger(maxTokens: 25_000), maxPartitions: 1)
            XCTFail("A duplicate plan must never be accepted")
        } catch {
            XCTAssertTrue(KistRunner.localPlanningCanEscalate(error), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("schema repair cannot change operations or commands"))
        }
        let count = await provider.calls.count
        XCTAssertEqual(count, 1, "An authority-preserving schema repair cannot remove a duplicate")
        let prompt = await provider.calls.prompt
        XCTAssertTrue(prompt.contains(KistRunner.builderPreflightJSONSchema),
            "A provider without structured-output support must still see the complete schema")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("New.swift").path))
    }

    func testIntentClassifierDoesNotSpendFullAgentThinkingBudget() async throws {
        let provider = DuplicatePlanProvider()
        let router = ConversationRouter(providers: ProviderRegistry(providers: [provider]),
            binding: ProviderBinding(providerId: provider.id, model: provider.defaultModel))
        _ = await router.resolve("Create a file named New.swift and implement a small testable greeting function")
        let settings = await provider.calls.settings
        XCTAssertEqual(settings?.maxTokens, 384)
        XCTAssertEqual(settings?.disableThinking, true)
        XCTAssertEqual(settings?.geminiBuiltins, false)
    }
}

private actor PlanningCalls {
    var count = 0
    var settings: ModelSettings?
    var prompt = ""
    func record(_ value: ModelSettings, messages: [ChatMessage]) {
        count += 1; settings = value; prompt = messages.map(\.content).joined(separator: "\n")
    }
}

private struct DuplicatePlanProvider: ChatProvider {
    let id = "planning-cost-test", name = "Planning cost test", keyAccount = "", defaultModel = "test"
    let requiresAPIKey = false
    let availableModels = [AIModel(id: "test")]
    let calls = PlanningCalls()
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        await calls.record(settings, messages: messages)
        return AsyncThrowingStream { continuation in
            continuation.yield(.delta(#"{"schema_version":1,"adapter":"headless","operations":[{"kind":"create","path":"New.swift"},{"kind":"create","path":"New.swift"}],"verification_commands":[{"executable":"python3","arguments":["-m","unittest"],"timeout_seconds":30}],"partitions":[]}"#))
            continuation.yield(.usage(promptTokens: 11, completionTokens: 7))
            continuation.finish()
        }
    }
}
