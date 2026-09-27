import XCTest
@testable import AgentCore

/// Host-owned final review on the HEALTHY plan ordering (0.17.63): mutate, then run the sealed
/// check as the LAST step. Nothing invalidates that check, so the host must still replay it once
/// under its own custody to mint the final deterministic replay receipt. Before this, the branch
/// never opened and a finished build was rejected as "final deterministic replay receipt is
/// missing or unbound" (live 2026-09-27: files committed, council 4/4 SHIP, exit 1).
final class PlanExecuteHostReceiptTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-receipt-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private let objective = "Create hello.txt and prove the project still builds with swift test."

    private let plan = """
    {"steps":[
      {"id":"E1","intent":"create artifact","tool":"write_file","arguments":{"path":"hello.txt","content":"hello\\n"}},
      {"id":"E2","intent":"verify","tool":"run_command","arguments":{"executable":"swift","args":["test"],"cwd":".","allowed_exit_codes":[0]},"dependsOn":["E1"]}
    ]}
    """

    func testMutationThenPassingCheckAsLastStepGetsOneHostReplayAndAFinalReceipt() async throws {
        let provider = HRScriptedProvider(responses: [
            plan, #"{"done":true,"reason":"host-authenticated evidence passed"}"#,
        ])
        let commands = HRCommandTool()
        let store = AtomicReasoningControlStore(
            directory: URL(fileURLWithPath: root).appendingPathComponent(".kist/reasoning", isDirectory: true))
        let outcome = await PlanExecuteLoop(
            providers: ProviderRegistry(providers: [provider], keyStore: HRNullKeys()),
            providerId: provider.id, model: "c1",
            tools: ToolRegistry([WriteFileTool(), commands]),
            context: ToolContext(projectRoot: root, shell: ShellPolicy(enabled: true, autoApprove: true)),
            requireApproval: false, maxReplans: 0, verifyGoal: true,
            completionContract: .derive(canonicalRequest: objective),
            hostOwnedFinalReview: true, functionalObjective: objective,
            hostContractID: "host-receipt-contract", reasoningStore: store
        ).run(goal: objective)

        XCTAssertTrue(outcome.success, outcome.message)
        XCTAssertEqual(outcome.replansUsed, 0, "the host replay is not a replan")
        XCTAssertEqual(commands.invocations.filter { $0 == "swift test" }.count, 2,
                       "the plan runs the check once, the host replays it exactly once")
        let receipt = try XCTUnwrap(outcome.finalVerificationReceipt, "host replay mints the final receipt")
        XCTAssertEqual(receipt.missionInstanceID, outcome.missionInstanceID)
        XCTAssertEqual(try String(contentsOfFile: root + "/hello.txt"), "hello\n")

        let checkpoint = try XCTUnwrap(outcome.checkpointId)
        let loaded = try await store.load(runID: checkpoint)
        let state = try XCTUnwrap(loaded)
        XCTAssertEqual(state.verificationControl?.attemptsStarted, 1, "exactly one host replay attempt")
    }

    func testHostReceiptRequestPointsAtTheLastPassedCheck() {
        let verifier = CompletionVerifier()
        let passed = ActionRecord(
            tool: "run_command", argsFingerprint: "executable=swift&args=[\"test\"]", success: true,
            effectObservation: ToolEffectObservation(mutation: .none, verification: .buildOrTest))
        let write = ActionRecord(
            tool: "write_file", argsFingerprint: "path=hello.txt", success: true,
            effectObservation: ToolEffectObservation(mutation: .source))
        let request = verifier.hostReceiptReplayRequest(in: [write, passed])
        XCTAssertEqual(request?.lastPassedTool, "run_command")
        XCTAssertEqual(request?.lastPassedFingerprint, "executable=swift&args=[\"test\"]")
        XCTAssertEqual(request?.lastPassedStep, 2)
        XCTAssertNil(verifier.hostReceiptReplayRequest(in: [write]), "no passed check → nothing to replay")
        XCTAssertNil(verifier.invalidatedVerification(in: [write, passed]),
                     "the healthy ordering has no invalidation — that is exactly the gap this request fills")
    }
}

// MARK: - fixtures (private to this file; PlanExecuteLoopTests keeps its own)

private struct HRNullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private final class HRScriptedProvider: ChatProvider, @unchecked Sendable {
    let id = "host-receipt-script", name = "HostReceipt", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "host-receipt-script", defaultModel = "c1"
    let availableModels = [AIModel(id: "c1")]
    private let lock = NSLock(); private let responses: [String]; private var idx = 0
    init(responses: [String]) { self.responses = responses }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock(); let r = idx < responses.count ? responses[idx] : "still not a plan"; idx += 1; lock.unlock()
        return AsyncThrowingStream { c in c.yield(.delta(r)); c.finish() }
    }
}

/// `run_command` stand-in that reports a clean `swift test` and records every invocation.
private final class HRCommandTool: AgentTool, @unchecked Sendable {
    let name = "run_command"
    let description = "scripted verification command"
    let parameters = [
        ToolParameter(name: "executable", type: "string", description: "program", required: true),
        ToolParameter(name: "args", type: "array", description: "argv", required: false),
        ToolParameter(name: "cwd", type: "string", description: "working directory", required: false),
        ToolParameter(name: "allowed_exit_codes", type: "array", description: "accepted statuses", required: false),
    ]
    private let lock = NSLock(); private var calls: [String] = []
    var invocations: [String] { lock.lock(); defer { lock.unlock() }; return calls }

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let executable = arguments["executable"] as? String ?? ""
        let args = (arguments["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        lock.lock(); calls.append(([executable] + args).joined(separator: " ")); lock.unlock()
        let metadata = [
            "exit_code": "0", "stdout": "ok", "stderr": "",
            "allowed_exit_codes": "0", "exit_code_allowed": "true",
            "verification_eligible": String(executable == "swift"),
            "timed_out": "false", "was_signalled": "false", "semantic_status": "clean_exit",
        ]
        return makePlanTestTrustedCommandResult(
            arguments: arguments, output: "ok", metadata: metadata, exitCode: 0)
    }
}
