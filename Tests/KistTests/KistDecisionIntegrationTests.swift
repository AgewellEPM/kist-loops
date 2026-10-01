import XCTest
@testable import AgentCore
@testable import Kist

final class KistDecisionIntegrationTests: XCTestCase {
    func testChatCanUseAdvisoryDecisionWithoutAWriteOrBuildMission() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.resolvingSymlinksInPath().path
        let provider = DecisionIntegrationProvider(review: true)
        let loop = KistRunner.makeLoop(registry: ProviderRegistry(providers: [provider]),
            providerId: provider.id, model: provider.defaultModel, context: ToolContext(projectRoot: root),
            tools: .headless(), checkpoints: LoopCheckpointStore(directory: root + "/checkpoints"),
            maxIterations: 3, budget: BudgetLedger(maxTokens: 100_000), toolMode: .text, delegationDepth: 0)
        let outcome = await loop.run(goal: "Classify this ticket and decide its route: refund the duplicate charge.")
        XCTAssertTrue(outcome.success, outcome.summary)
        let observed = await provider.observations()
        XCTAssertEqual(observed.decisions, 1); XCTAssertTrue(observed.resultSeen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.kist/decision-tools"))
    }

    func testDefinitionRequestsUseOrdinaryAgentAndSourceBuildsKeepBuilder() {
        let options = KistOptions(project: "/tmp/decision-fixture")
        XCTAssertFalse(KistRunner.builderRunRequired(for: options, goal: "Create a reusable decision_tool named triage"))
        XCTAssertTrue(KistRunner.builderRunRequired(for: options, goal: "Create a Swift API server"))
    }

    func testNestedDecisionCannotEscapeTheParentRequestCeiling() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.resolvingSymlinksInPath().path
        let provider = DecisionIntegrationProvider()
        let checkpoints = LoopCheckpointStore(directory: root + "/checkpoints")
        let loop = KistRunner.makeLoop(registry: ProviderRegistry(providers: [provider]),
            providerId: provider.id, model: provider.defaultModel, context: ToolContext(projectRoot: root),
            tools: .headless(), checkpoints: checkpoints, maxIterations: 2,
            budget: BudgetLedger(maxTokens: 100_000), toolMode: .text, delegationDepth: 0)
        let outcome = await loop.run(goal: "Create a reusable decision tool called triage and run it.")
        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.summary.contains("request limit"))
        let cp = try checkpoints.load(id: outcome.checkpointId)
        XCTAssertEqual(cp.providerRequestsConsumed, 2)
        let observed = await provider.observations()
        XCTAssertEqual(observed.decisions, 0, "no nested inference after the parent limit")
        XCTAssertEqual(cp.trajectory?.last?.success, false)
    }

    func testNormalAgentDesignsAndRunsDecisionToolWithSharedDurableRequestBudget() async throws {
        let temporary = NSTemporaryDirectory() + "kist-decision-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: temporary, withIntermediateDirectories: true)
        let root = try XCTUnwrap(ToolContext.canonicalize(temporary))
        defer { try? FileManager.default.removeItem(atPath: root) }
        let provider = DecisionIntegrationProvider()
        let checkpoints = LoopCheckpointStore(directory: root + "/checkpoints")
        let trace = TraceRecorder(traceId: "decision-integration")
        let loop = KistRunner.makeLoop(registry: ProviderRegistry(providers: [provider]),
            providerId: provider.id, model: provider.defaultModel, context: ToolContext(projectRoot: root),
            tools: .headless(), checkpoints: checkpoints, maxIterations: 4,
            budget: BudgetLedger(maxTokens: 100_000), toolMode: .text, delegationDepth: 0, traceRecorder: trace)
        let outcome = await loop.run(goal: "Create a reusable decision tool called triage and run it on a refund ticket.")
        let observed = await provider.observations()
        XCTAssertTrue(outcome.success, outcome.summary)
        let cp = try checkpoints.load(id: outcome.checkpointId)
        XCTAssertEqual(cp.providerRequestsConsumed, 4, "3 agent requests plus 1 nested decision request")
        XCTAssertEqual(cp.trajectory?.filter { $0.tool == "decision_tool" && $0.success }.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/decision-tools/triage.json"))
        XCTAssertEqual(observed.decisions, 1)
        XCTAssertTrue(observed.schemaSeen)
        XCTAssertTrue(observed.resultSeen)
        let spans = await trace.all()
        XCTAssertEqual(spans.filter { $0.kind == .llmCall }.count, 4)
        XCTAssertEqual(spans.filter { $0.role == "decision" }.count, 1)
        XCTAssertTrue(KistREPL.renderSimpleSummary(projectRoot: root, spans: spans, trajectory: [], color: false).contains("4 model call(s)"))
    }
}

private actor DecisionIntegrationProvider: ChatProvider {
    nonisolated let id = "decision-fixture", name = "Decision fixture", iconName = "cpu"
    nonisolated let requiresAPIKey = false, keyAccount = "", defaultModel = "fixture"
    nonisolated let availableModels: [AIModel] = []
    private var main = 0, decisions = 0
    private var schemaSeen = false, resultSeen = false
    private let review: Bool
    init(review: Bool = false) { self.review = review }
    func observations() -> (decisions: Int, schemaSeen: Bool, resultSeen: Bool) { (decisions, schemaSeen, resultSeen) }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let text: String
        if settings.systemPrompt.hasPrefix("Evaluate the supplied decision questions.") {
            decisions += 1
            text = #"{"answers":{"team":{"probabilities":{"billing":0.95,"other":0.05}}}}"#
        } else {
            let instructions = settings.systemPrompt + messages.map(\.content).joined(separator: "\n")
            schemaSeen = schemaSeen || (instructions.contains("## decision_tool") && instructions.contains("## decide"))
            main += 1
            switch review && main > 1 ? 3 : main {
            case 1 where review:
                text = #"{"tool":"decide","parameters":{"state":{"ticket":"Refund the duplicate charge"},"questions":{"team":{"type":"choice","instructions":"Route the ticket","criteria":{"billing":"Payments","other":"Other"}}}}}"#
            case 1: text = #"{"tool":"decision_tool","parameters":{"action":"create","name":"triage","questions":{"team":{"type":"choice","instructions":"Route the ticket","criteria":{"billing":"Refunds and payments","other":"Other topics"}}}}}"#
            case 2: text = #"{"tool":"decision_tool","parameters":{"action":"run","name":"triage","state":{"ticket":"Please refund this duplicate payment"}}}"#
            default:
                resultSeen = messages.contains { $0.content.contains("kist.decision.v1") && $0.content.contains("billing") }
                text = #"{"done":true,"summary":"Created triage and observed billing from its decision result."}"#
            }
        }
        return AsyncThrowingStream { continuation in continuation.yield(.delta(text)); continuation.finish() }
    }
}
