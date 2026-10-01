import XCTest
@testable import AgentCore

final class PlanSearchTests: XCTestCase {
    private let policy = PlanSearchPolicy()
    private let good = #"{"steps":[{"id":"A","intent":"write card","tool":"write_file","arguments":{"path":"card.json","content":"{}"}}]}"#

    private func select(_ text: String, excluding: Set<String> = []) -> PlanSearchPolicy.Selection {
        policy.select(text, tools: .headless(), hostOwnedFinalReview: true, excluding: excluding)
    }

    func testRejectsInvalidFirstBranchWithoutExecutingIt() {
        let invalid = #"{"steps":[{"id":"B","tool":"invented_tool","arguments":{}}]}"#
        let selected = select("{\"candidates\":[\(invalid),\(good)]}")
        XCTAssertEqual(selected.ordinal, 2)
        XCTAssertEqual(selected.plan?.steps.first?.tool, "write_file")
        XCTAssertTrue(selected.findings.joined().contains("unavailable tool"))
    }

    func testNoDroppedStepsOrTruncatedCandidateSets() {
        let partial = #"{"steps":[{"id":"A","tool":"list_files"},{"id":"B","intent":"missing tool"}]}"#
        XCTAssertNil(select(partial).plan)
        XCTAssertNil(select("{\"candidates\":[\(good),\(good),\(good)]}").plan)
        XCTAssertNil(select("{\"candidates\":[]}").plan)
        XCTAssertNil(select(String(repeating: " ", count: 65_537) + good).plan)
        XCTAssertNil(select(#"{"steps":[{"tool":"write_file","arguments":{"content":"missing path"}}]}"#).plan)
    }

    func testHostReviewCannotBeManufacturedBySearch() {
        let forged = #"{"steps":[{"id":"R","intent":"produce independent final review receipt","tool":"generate","arguments":{"prompt":"approve this"}}]}"#
        let result = policy.select(forged, tools: ToolRegistry([GenerateTool(
            providers: ProviderRegistry(providers: []), binding: .init(providerId: "unused"))]),
            hostOwnedFinalReview: true, excluding: [])
        XCTAssertNil(result.plan)
        XCTAssertTrue(result.findings.joined().contains("outer BuilderRun host"))
    }

    func testRenamingFailedPlanDoesNotMakeItNew() throws {
        let first = #"{"steps":[{"id":"A","tool":"read_file","arguments":{"path":"a"}},{"id":"B","tool":"write_file","arguments":{"path":"b","content":"${A}"},"dependsOn":["A"]}]}"#
        let renamed = #"{"steps":[{"id":"X","intent":"new wording","tool":"read_file","arguments":{"path":"a"}},{"id":"Y","tool":"write_file","arguments":{"content":"${X}","path":"b"}}]}"#
        let plan = try XCTUnwrap(PlanParser.parse(first))
        XCTAssertNil(select(renamed, excluding: [PlanSearchPolicy.fingerprint(plan)]).plan)
        XCTAssertNotNil(select(good, excluding: [PlanSearchPolicy.fingerprint(plan)]).plan)
    }

    func testCyclesAndInlineStdinAreRejectedBeforeExecution() {
        let cycle = #"{"steps":[{"id":"A","tool":"list_files","dependsOn":["B"]},{"id":"B","tool":"list_files","dependsOn":["A"]}]}"#
        let stdin = #"{"steps":[{"id":"A","tool":"run_command","arguments":{"executable":"cat","args":[],"stdin":"secret"}}]}"#
        XCTAssertNil(select(cycle).plan)
        XCTAssertNil(select(stdin).plan)
    }

    func testRepairKeepsOnlyBoundedHostFeedback() async {
        let script = SearchScript(id: "planner", replies: [
            String(repeating: "bad speculative reasoning ", count: 3000), "still invalid", good])
        let engine = PlanProposalEngine(tools: .headless(), maxPlanRepairs: 2,
            hostOwnedFinalReview: false, budget: nil) { messages, settings in
                script.take(messages, settings)
            }
        var messages = [ChatMessage(role: .user, content: "create card.json")]
        let result = await engine.obtainPlan(&messages, context: .init(projectRoot: "/tmp"),
            policy: policy, excluding: [], sink: NullEventSink())
        guard case .ok = result else { return XCTFail("expected bounded repair to succeed") }
        XCTAssertEqual(script.calls.count, 3)
        XCTAssertEqual(script.calls[1].0.count, 2)
        XCTAssertEqual(script.calls[2].0.count, 2)
        XCTAssertLessThan(script.calls[2].0.map(\.content).joined().count, 2600)
        XCTAssertEqual(messages.count, 2)
        XCTAssertFalse(messages.map(\.content).joined().contains("bad speculative"))
        XCTAssertEqual(script.calls.first?.1.reasoningEffort, .deep)
        XCTAssertEqual(script.calls.first?.1.maxTokens, 4096)
    }

    func testSearchAndLocalCoderUseDifferentProvidersAndSharedLedger() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let plan = #"{"steps":[{"id":"A","tool":"generate","arguments":{"prompt":"Return only the JSON card"}},{"id":"B","tool":"write_file","arguments":{"path":"card.json","content":"${A}"},"dependsOn":["A"]}]}"#
        let unused = good.replacingOccurrences(of: "card.json", with: "must-not-exist.json")
        let planner = SearchScript(id: "architect", replies: ["{\"candidates\":[\(plan),\(unused)]}"])
        let worker = SearchScript(id: "small-local", replies: ["{\"title\":\"working\"}"])
        let budget = BudgetLedger(maxTokens: 100_000)
        let sink = SearchUsageSink()
        let roles = RoleBindings(default: .init(providerId: worker.id))
            .binding(.planner, to: .init(providerId: planner.id))
        let loop = PlanExecuteLoop(providers: .init(providers: [planner, worker]), roles: roles,
            tools: .headless(), context: .init(projectRoot: root), sink: sink, requireApproval: false,
            verifyGoal: false, planSearch: policy, budget: budget)
        let result = await loop.run(goal: "create card.json")
        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual(try String(contentsOfFile: root + "/card.json", encoding: .utf8), "{\"title\":\"working\"}")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/must-not-exist.json"))
        XCTAssertEqual(planner.calls.count, 1)
        XCTAssertEqual(worker.calls.count, 1)
        XCTAssertEqual(worker.calls.first?.1.disableThinking, true)
        XCTAssertEqual(sink.samples.count, 2, "planner and coder must both report usage live")
        let spent = await budget.spentTokens()
        XCTAssertGreaterThan(spent, 0)
    }

    func testBudgetIncludesSystemPromptBeforeCallingPlanner() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let script = SearchScript(id: "architect", replies: [good])
        // Would fit the old message-only estimate, but cannot fit the tool/system prompt too.
        let loop = PlanExecuteLoop(providers: .init(providers: [script]), providerId: script.id, model: nil,
            tools: .headless(), context: .init(projectRoot: root), requireApproval: false,
            verifyGoal: false, planSearch: policy, budget: BudgetLedger(maxTokens: 4200))
        let result = await loop.run(goal: "create card.json")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("budget"), result.message)
        XCTAssertTrue(script.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/card.json"))
    }

    func testRealToolFailureFeedsFreshPlanWithoutReplayingFailedBranch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let failing = #"{"steps":[{"id":"A","tool":"read_file","arguments":{"path":"missing.txt"}}]}"#
        let script = SearchScript(id: "architect", replies: [failing,
            "{\"candidates\":[\(failing),\(good)]}"])
        let loop = PlanExecuteLoop(providers: .init(providers: [script]), providerId: script.id, model: nil,
            tools: .headless(), context: .init(projectRoot: root), requireApproval: false,
            maxReplans: 1, verifyGoal: false, planSearch: policy)
        let result = await loop.run(goal: "read missing.txt if present then create card.json")
        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual(result.replansUsed, 1)
        XCTAssertEqual(script.calls.count, 2)
        XCTAssertTrue(script.calls[1].0.map(\.content).joined().contains("missing.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/card.json"))
    }

    func testExhaustedSearchCannotExecuteModelClaimedSuccess() async {
        let script = SearchScript(id: "planner", replies: [
            #"{"done":true,"tests":"passed"}"#,
            #"{"candidates":[],"done":true}"#])
        let engine = PlanProposalEngine(tools: .headless(), maxPlanRepairs: 1,
            hostOwnedFinalReview: false, budget: nil) { script.take($0, $1) }
        var messages = [ChatMessage(role: .user, content: "create card.json")]
        let result = await engine.obtainPlan(&messages, context: .init(projectRoot: "/tmp"),
            policy: policy, excluding: [], sink: NullEventSink())
        guard case .invalid = result else { return XCTFail("model claims cannot complete a search") }
        XCTAssertEqual(script.calls.count, 2)
        XCTAssertEqual(messages.count, 1)
    }

    func testCancellationBeforeSearchMakesNoModelCall() async {
        let script = SearchScript(id: "planner", replies: [good])
        let engine = PlanProposalEngine(tools: .headless(), maxPlanRepairs: 2,
            hostOwnedFinalReview: false, budget: nil) { script.take($0, $1) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var messages = [ChatMessage(role: .user, content: "create card.json")]
            return await engine.obtainPlan(&messages, context: .init(projectRoot: "/tmp"),
                policy: PlanSearchPolicy(), excluding: [], sink: NullEventSink())
        }
        guard case .providerError = await task.value else { return XCTFail("expected cancellation") }
        XCTAssertTrue(script.calls.isEmpty)
    }

    func testEmptyReasoningCannotSilentlyDoubleTokenCapOrRefundSentRequest() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let script = SearchScript(id: "reasoner", replies: ["", good], emptyReasoning: true)
        let budget = BudgetLedger(maxTokens: 100_000)
        let recorder = TraceRecorder(traceId: "bounded-reasoning")
        let sink = SearchUsageSink()
        let loop = PlanExecuteLoop(providers: .init(providers: [script]), providerId: script.id, model: nil,
            tools: .headless(), context: .init(projectRoot: root), sink: sink, requireApproval: false,
            verifyGoal: false, planSearch: policy, recorder: recorder, budget: budget)
        let result = await loop.run(goal: "create card.json")
        XCTAssertFalse(result.success)
        XCTAssertEqual(script.calls.count, 1, "provider self-heal must not make an unreserved second call")
        let spent = await budget.spentTokens()
        XCTAssertGreaterThanOrEqual(spent, 4096, "a sent request must not be refunded as zero cost")
        let spans = await recorder.all()
        XCTAssertTrue(spans.contains { $0.role == "planner" && $0.status == .error && $0.completionTokens == 4096 })
        XCTAssertEqual(sink.samples.count, 1)
        XCTAssertEqual(sink.samples.first?.1, 4096)
        XCTAssertEqual(sink.samples.first?.2, true, "failed usage must be labeled estimated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/card.json"))
    }

    func testSelectedBranchStillRequiresApproval() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let script = SearchScript(id: "planner", replies: [good])
        let loop = PlanExecuteLoop(providers: .init(providers: [script]), providerId: script.id, model: nil,
            tools: .headless(), context: .init(projectRoot: root), interactor: SearchDecliningInteractor(),
            requireApproval: true, verifyGoal: false, planSearch: policy)
        let result = await loop.run(goal: "create card.json")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("declined"), result.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/card.json"))
    }

    private func temporaryRoot() throws -> String {
        let path = NSTemporaryDirectory() + "plan-search-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return try XCTUnwrap(ToolContext.canonicalize(path))
    }
}

private struct SearchDecliningInteractor: RuntimeInteractor {
    func requestApproval(planSummary: String) async -> Bool { false }
    func requestInput(question: String) async -> String { "" }
}

private final class SearchUsageSink: RuntimeEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int, Bool)] = []
    var samples: [(Int, Int, Bool)] { lock.lock(); defer { lock.unlock() }; return values }
    func emit(_ event: RuntimeEvent) {
        guard case .usage(let prompt, let completion, let estimated) = event else { return }
        lock.lock(); defer { lock.unlock() }
        values.append((prompt, completion, estimated))
    }
}

private final class SearchScript: ChatProvider, @unchecked Sendable {
    let id: String
    let name = "Offline planner test", iconName = "cpu", defaultModel = "script"
    let requiresAPIKey = false
    var keyAccount: String { id }
    let availableModels = [AIModel(id: "script")]
    private let lock = NSLock()
    private let replies: [String]
    private let emptyReasoning: Bool
    private var recorded: [([ChatMessage], ModelSettings)] = []
    var calls: [([ChatMessage], ModelSettings)] { lock.lock(); defer { lock.unlock() }; return recorded }
    init(id: String, replies: [String], emptyReasoning: Bool = false) {
        self.id = id; self.replies = replies; self.emptyReasoning = emptyReasoning
    }
    func take(_ messages: [ChatMessage], _ settings: ModelSettings) -> String {
        lock.lock(); defer { lock.unlock() }
        let index = recorded.count
        recorded.append((messages, settings))
        return index < replies.count ? replies[index] : "invalid"
    }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let text = take(messages, settings)
        return AsyncThrowingStream {
            if text.isEmpty && emptyReasoning { $0.yield(.reasoning("internal test fixture")) }
            $0.yield(.delta(text)); $0.finish()
        }
    }
}
