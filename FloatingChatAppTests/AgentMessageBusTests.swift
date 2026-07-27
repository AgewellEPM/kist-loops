import XCTest
@testable import FloatingChatApp

@MainActor
final class AgentMessageBusTests: XCTestCase {

    private var tempDir: URL!
    private var savedProvider: (any AIProvider)!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fca-bus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedProvider = ProviderManager.shared.currentProvider
    }

    override func tearDownWithError() throws {
        ProviderManager.shared.currentProvider = savedProvider
        AgentLoopEngine.shared.reset()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Bus mechanics

    func testSend_routesToRecipientInboxOnly() {
        let bus = AgentMessageBus()
        bus.send(from: "a", to: "b", content: "hi b")
        XCTAssertEqual(bus.pendingCount(for: "b"), 1)
        XCTAssertEqual(bus.pendingCount(for: "a"), 0, "sender's own inbox must be untouched")
        XCTAssertEqual(bus.pending(for: "b").first?.content, "hi b")
        XCTAssertEqual(bus.pending(for: "b").first?.from, "a")
    }

    func testDrain_returnsAndClears() {
        let bus = AgentMessageBus()
        bus.send(from: "a", to: "b", content: "1")
        bus.send(from: "c", to: "b", content: "2")
        let drained = bus.drain(for: "b")
        XCTAssertEqual(drained.map(\.content), ["1", "2"])
        XCTAssertEqual(bus.pendingCount(for: "b"), 0, "inbox is empty after drain")
        XCTAssertTrue(bus.drain(for: "b").isEmpty)
    }

    func testLog_recordsAllDeliveries() {
        let bus = AgentMessageBus()
        bus.send(from: "a", to: "b", content: "x")
        bus.send(from: "b", to: "a", content: "y")
        XCTAssertEqual(bus.log.count, 2)
        bus.clear()
        XCTAssertTrue(bus.log.isEmpty)
        XCTAssertEqual(bus.pendingCount(for: "a"), 0)
    }

    // MARK: - Parsing

    func testParseSend_extractsTargetAndContent() {
        let r = AgentLoopEngine.parseSend("<send to=\"reviewer\">please check line 42</send>")
        XCTAssertEqual(r?.to, "reviewer")
        XCTAssertEqual(r?.content, "please check line 42")
        XCTAssertNil(AgentLoopEngine.parseSend("no send tag"))
    }

    func testParseSend_allowsExtraAttributes() {
        let r = AgentLoopEngine.parseSend("<send to=\"b\" priority=\"high\">do it</send>")
        XCTAssertEqual(r?.to, "b")
        XCTAssertEqual(r?.content, "do it")
    }

    // MARK: - Isolation

    func testBusIsolation_separateEngineInstances() {
        let parent = AgentLoopEngine(depth: 0)
        let child = AgentLoopEngine(depth: 1)
        parent.messageBus.send(from: "x", to: "y", content: "parent-only")
        XCTAssertEqual(parent.messageBus.pendingCount(for: "y"), 1)
        XCTAssertEqual(child.messageBus.pendingCount(for: "y"), 0, "a sub-team engine has its own isolated bus")
    }

    // MARK: - Integration: inbox delivered into agent context on run

    func testInbox_drainedIntoAgentContextOnRun() async {
        let engine = AgentLoopEngine.shared
        engine.reset()
        let lead = AgentConfig(id: "lead", name: "Lead", provider: "user_selected", model: "auto", role: .lead, color: "#fff", systemPrompt: nil)
        engine.setup(projectPath: tempDir.path, agents: [lead])

        // A message is waiting for the lead before it runs.
        engine.messageBus.send(from: "peer", to: "lead", content: "remember to handle the edge case")

        ProviderManager.shared.currentProvider = BusScriptedProvider(responses: ["acknowledged, done"])
        await engine.processMessage("do the task")

        let sawInbox = engine.conversationHistory.contains { message in
            if case .user(let content, _, _) = message {
                return content.contains("Message from peer") && content.contains("edge case")
            }
            return false
        }
        XCTAssertTrue(sawInbox, "the agent must see inbox messages as context on its turn")
    }

    /// True bidirectional: A messages B during the run; B replies to A; the
    /// settle pass delivers B's reply back to A even though A already had its
    /// turn (the stranding case settle fixes).
    func testBidirectional_settleDeliversReplyToAlreadyRunAgent() async {
        let engine = AgentLoopEngine.shared
        engine.reset()
        engine.persistOrchestrationCheckpoints = false

        let a = AgentConfig(id: "A", name: "A", provider: "user_selected", model: "auto", role: .lead, color: "#fff", systemPrompt: nil)
        let b = AgentConfig(id: "B", name: "B", provider: "user_selected", model: "auto", role: .coder, color: "#000", systemPrompt: nil)
        engine.projectPath = tempDir.path
        engine.agents = [a, b]
        engine.agentStates = ["A": AgentState(id: "A"), "B": AgentState(id: "B")]
        engine.currentSession = MultiAgentSession(agents: [a, b], projectPath: tempDir.path)

        ProviderManager.shared.currentProvider = BusScriptedProvider(responses: [
            "<send to=\"B\">hi B</send>",       // A turn 1: message B
            "A initial done",                    // A turn 2: finish
            "<send to=\"A\">hi A back</send>",   // B turn 1: reply A (after draining)
            "B done",                            // B turn 2: finish
            "A settled done"                     // A settle turn: drains B's reply
        ])

        let team = AgentTeam(id: "t", name: "T", description: "", iconName: "", agents: [], orchestrationMode: .sequential)
        await engine.processMessageWithTeam("start", team: team)

        let bReceived = engine.conversationHistory.contains { msg in
            if case .user(let c, _, _) = msg { return c.contains("Message from A") && c.contains("hi B") }
            return false
        }
        let aReceivedViaSettle = engine.conversationHistory.contains { msg in
            if case .user(let c, _, _) = msg { return c.contains("Message from B") && c.contains("hi A back") }
            return false
        }
        XCTAssertTrue(bReceived, "B should receive A's message during its turn")
        XCTAssertTrue(aReceivedViaSettle, "settle should deliver B's reply back to A after A already ran")
    }

    func testSettle_surfacesUnknownRecipientMessages() async {
        let engine = AgentLoopEngine.shared
        engine.reset()
        engine.persistOrchestrationCheckpoints = false
        let a = AgentConfig(id: "A", name: "A", provider: "user_selected", model: "auto", role: .lead, color: "#fff", systemPrompt: nil)
        engine.projectPath = tempDir.path
        engine.agents = [a]
        engine.agentStates = ["A": AgentState(id: "A")]
        engine.currentSession = MultiAgentSession(agents: [a], projectPath: tempDir.path)

        // Mail to a recipient that isn't on the team — must be surfaced, not lost.
        engine.messageBus.send(from: "A", to: "ghost", content: "nobody home")
        await engine.settleMessages()

        let surfaced = engine.conversationHistory.contains { msg in
            if case .error(_, let m, _, _) = msg { return m.contains("undelivered") && m.contains("ghost") }
            return false
        }
        XCTAssertTrue(surfaced, "undelivered mail to an unknown recipient must be surfaced even when no team agent has mail")
    }
}

private final class BusScriptedProvider: AIProvider {
    let id = "bus-scripted"
    let name = "BusScripted"
    let iconName = "circle"
    let supportsStreaming = true
    let requiresAPIKey = false
    let apiKeySettingKey = "k"
    let availableModels: [AIModel] = []
    var selectedModel: AIModel?
    private let responses: [String]
    private var index = 0
    init(responses: [String]) { self.responses = responses }
    func refreshModels() async -> [AIModel] { [] }
    func checkStatus() async -> Bool { true }
    func validateAPIKey(_ key: String) async -> Bool { true }
    func sendMessage(messages: [ChatMessage], settings: ModelSettings, stream: Bool) async throws -> AsyncThrowingStream<String, Error> {
        let response = index < responses.count ? responses[index] : "done"
        index += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(response)
            continuation.finish()
        }
    }
}
