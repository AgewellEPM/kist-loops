import XCTest
@testable import AgentCore

final class AICouncilTests: XCTestCase {

    func testCouncilRunsRoleBoundMindsAndRendersKanbanArtifact() async {
        let worker = CouncilScriptedProvider(id: "workerco", responses: [
            "- Research says agent conferences are the gap.",
            "- UX needs a visible council result and one command handoff.",
        ])
        let planner = CouncilScriptedProvider(id: "plannerco", responses: [
            "- Build the council primitive before more research UI.",
            """
            Decision:
            - Build the Agent Council command first.

            Task Analysis:
            - It turns research into a decision and task board.

            Kanban Board:
            | Status | Task | Owner | Acceptance |
            | --- | --- | --- | --- |
            | Ready | Add /council | builder | Command saves a board |

            Next Builder Brief:
            - Implement /council and tests.
            """,
        ])
        let coder = CouncilScriptedProvider(id: "coderco", responses: [
            "- Add AICouncil plus a KistREPL command.",
        ])
        let critic = CouncilScriptedProvider(id: "criticco", responses: [
            "- Risk: summary-only output. Require a kanban board.",
        ])
        let registry = ProviderRegistry(providers: [worker, planner, coder, critic], keyStore: CouncilNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"))
            .binding(.worker, to: ProviderBinding(providerId: "workerco"))
            .binding(.coder, to: ProviderBinding(providerId: "coderco"))
            .binding(.critic, to: ProviderBinding(providerId: "criticco"))
        let recorder = TraceRecorder(traceId: TraceID.make())

        let result = await AICouncil(providers: registry, roles: roles,
                                     memoryContext: "PROJECT MEMORY: keep builder handoffs explicit.",
                                     recorder: recorder).run(goal: "turn research into debate then task graph")

        XCTAssertEqual(result.minds.map(\.name), ["Researcher", "Architect", "Coder", "Critic", "UX", "Memory"])
        XCTAssertTrue(result.markdown.contains("# AI Council Result"))
        XCTAssertTrue(result.markdown.contains("## Researcher"))
        XCTAssertTrue(result.markdown.contains("## Decision, Task Analysis, And Kanban"))
        XCTAssertTrue(result.finalPlan.contains("Kanban Board"))
        XCTAssertTrue(result.builderBrief.contains("Council board"))
        XCTAssertTrue(result.builderBrief.contains("turn research into debate"))

        let summary = await recorder.summary()
        XCTAssertEqual(summary.spanCount, 6)
        XCTAssertGreaterThan(summary.tokensByVendor["workerco"] ?? 0, 0)
        XCTAssertTrue(summary.tokensByRole.keys.contains("council_final_plan"))
    }

    func testCouncilKeepsGoingWhenOneMindFails() async {
        let worker = CouncilScriptedProvider(id: "workerco", responses: ["research", "ux"])
        let planner = CouncilScriptedProvider(id: "plannerco", responses: ["architect", "Decision:\n- continue\n\nKanban Board:\n| Status | Task | Owner | Acceptance |\n| --- | --- | --- | --- |"])
        let coder = CouncilScriptedProvider(id: "coderco", responses: ["coder"])
        let critic = CouncilFailingProvider(id: "criticco")
        let registry = ProviderRegistry(providers: [worker, planner, coder, critic], keyStore: CouncilNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"))
            .binding(.worker, to: ProviderBinding(providerId: "workerco"))
            .binding(.coder, to: ProviderBinding(providerId: "coderco"))
            .binding(.critic, to: ProviderBinding(providerId: "criticco"))

        let result = await AICouncil(providers: registry, roles: roles).run(goal: "decide")

        let criticMind = result.minds.first { $0.name == "Critic" }
        XCTAssertEqual(criticMind?.failed, true)
        XCTAssertTrue(criticMind?.output.contains("FAILED") ?? false)
        XCTAssertTrue(result.finalPlan.contains("Decision"))
    }

    func testCouncilReceivesResearchDossier() async {
        let worker = CouncilScriptedProvider(id: "workerco", responses: ["research"])
        let planner = CouncilScriptedProvider(id: "plannerco", responses: [
            "architect",
            "Decision:\n- use dossier\n\nKanban Board:\n| Status | Task | Owner | Acceptance |\n| --- | --- | --- | --- |",
        ])
        let coder = CouncilScriptedProvider(id: "coderco", responses: ["coder"])
        let critic = CouncilScriptedProvider(id: "criticco", responses: ["critic"])
        let registry = ProviderRegistry(providers: [worker, planner, coder, critic], keyStore: CouncilNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"))
            .binding(.worker, to: ProviderBinding(providerId: "workerco"))
            .binding(.coder, to: ProviderBinding(providerId: "coderco"))
            .binding(.critic, to: ProviderBinding(providerId: "criticco"))

        _ = await AICouncil(providers: registry, roles: roles,
                            researchDossier: "Research dossier: [E001] primary source").run(goal: "decide")

        let workerPrompts = await worker.prompts()
        let plannerPrompts = await planner.prompts()
        XCTAssertTrue(workerPrompts.contains { $0.contains("[E001] primary source") })
        XCTAssertTrue(plannerPrompts.contains { $0.contains("Research dossier") })
    }

    func testCouncilEmitsProgressHeartbeats() async {
        let worker = CouncilScriptedProvider(id: "workerco", responses: ["research", "ux"])
        let planner = CouncilScriptedProvider(id: "plannerco", responses: [
            "architect",
            "Decision:\n- continue\n\nKanban Board:\n| Status | Task | Owner | Acceptance |\n| --- | --- | --- | --- |",
        ])
        let coder = CouncilScriptedProvider(id: "coderco", responses: ["coder"])
        let critic = CouncilScriptedProvider(id: "criticco", responses: ["critic"])
        let progress = CouncilProgressLog()
        let registry = ProviderRegistry(providers: [worker, planner, coder, critic], keyStore: CouncilNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"))
            .binding(.worker, to: ProviderBinding(providerId: "workerco"))
            .binding(.coder, to: ProviderBinding(providerId: "coderco"))
            .binding(.critic, to: ProviderBinding(providerId: "criticco"))

        _ = await AICouncil(providers: registry, roles: roles, progress: { status, message in
            await progress.record(status: status, message: message)
        }).run(goal: "decide")

        let messages = await progress.messages()
        XCTAssertTrue(messages.contains("council:council started"))
        XCTAssertTrue(messages.contains("council:Researcher started"))
        XCTAssertTrue(messages.contains("council:Final Plan Agent completed"))
        XCTAssertTrue(messages.contains("council:council completed"))
    }

    func testStructuredCriticVerdictParserFailsClosed() {
        XCTAssertEqual(AICouncil.parseCriticVerdict("""
        evidence review
        <<<CRITIC_VERDICT
        {"decision":"accept","rationale":"named source was fetched"}
        CRITIC_VERDICT>>>
        """), .init(decision: .accept, rationale: "named source was fetched"))

        XCTAssertEqual(AICouncil.parseCriticVerdict("""
        <<<CRITIC_VERDICT
        {"decision":"reject","rationale":"no primary fetch"}
        CRITIC_VERDICT>>>
        """), .init(decision: .reject, rationale: "no primary fetch"))

        XCTAssertNil(AICouncil.parseCriticVerdict("FAIL: no primary fetch"))
        XCTAssertNil(AICouncil.parseCriticVerdict("""
        <<<CRITIC_VERDICT
        {"decision":"accept","rationale":"first"}
        CRITIC_VERDICT>>>
        <<<CRITIC_VERDICT
        {"decision":"reject","rationale":"conflict"}
        CRITIC_VERDICT>>>
        """))
    }

    func testRequiredCriticRequestsVerdictBeforeProseForStagedExecution() async {
        let worker = CouncilScriptedProvider(id: "workerco", responses: ["research", "ux"])
        let planner = CouncilScriptedProvider(id: "plannerco", responses: ["architect", "Decision:\n- proceed"])
        let coder = CouncilScriptedProvider(id: "coderco", responses: ["coder"])
        let critic = CouncilScriptedProvider(id: "criticco", responses: ["""
        <<<CRITIC_VERDICT
        {"decision":"accept","rationale":"deterministic staged verification covers the remaining runtime fact"}
        CRITIC_VERDICT>>>
        - Run the frozen test after mutation.
        """])
        let registry = ProviderRegistry(providers: [worker, planner, coder, critic], keyStore: CouncilNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"))
            .binding(.worker, to: ProviderBinding(providerId: "workerco"))
            .binding(.coder, to: ProviderBinding(providerId: "coderco"))
            .binding(.critic, to: ProviderBinding(providerId: "criticco"))

        let result = await AICouncil(providers: registry, roles: roles,
                                     requireStructuredCriticVerdict: true).run(goal: "build then test")
        let prompt = await critic.prompts().first ?? ""
        XCTAssertLessThan(prompt.range(of: "Begin with exactly one")!.lowerBound,
                          prompt.range(of: "Attack the proposal")!.lowerBound)
        XCTAssertTrue(prompt.contains("ENTER staged execution"))
        XCTAssertEqual(result.minds.first(where: { $0.name == "Critic" })?.criticVerdict?.decision, .accept)
    }
}

private struct CouncilNullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private final class CouncilScriptedProvider: ChatProvider, @unchecked Sendable {
    let id: String
    let name: String
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount: String
    let defaultModel: String
    let availableModels: [AIModel]
    private let responses: CouncilResponses
    private let promptLog = CouncilPromptLog()

    init(id: String, responses: [String]) {
        self.id = id
        self.name = id
        self.keyAccount = id
        self.defaultModel = "\(id)-default"
        self.availableModels = [AIModel(id: "\(id)-default")]
        self.responses = CouncilResponses(responses)
    }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        await promptLog.record(messages.map(\.content).joined(separator: "\n"))
        let response = await responses.next()
        return AsyncThrowingStream { continuation in
            continuation.yield(.delta(response))
            continuation.finish()
        }
    }

    func prompts() async -> [String] { await promptLog.all() }
}

private actor CouncilPromptLog {
    private var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func all() -> [String] { values }
}

private actor CouncilProgressLog {
    private var values: [String] = []
    func record(status: String, message: String) { values.append("\(status):\(message)") }
    func messages() -> [String] { values }
}

private actor CouncilResponses {
    private let responses: [String]
    private var index = 0

    init(_ responses: [String]) {
        self.responses = responses
    }

    func next() -> String {
        defer { index += 1 }
        return index < responses.count ? responses[index] : "(out of script)"
    }
}

private struct CouncilFailingProvider: ChatProvider {
    let id: String
    let name: String
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount: String
    let defaultModel: String
    let availableModels: [AIModel]

    init(id: String) {
        self.id = id
        self.name = id
        self.keyAccount = id
        self.defaultModel = "\(id)-default"
        self.availableModels = [AIModel(id: "\(id)-default")]
    }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        throw AIProviderError.transport("critic down")
    }
}
