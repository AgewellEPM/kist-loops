import XCTest
import Foundation
@testable import AgentCore

/// The closed plan→execute loop: propose → validate(+repair) → approve → execute, driven by a
/// scripted planner so it's deterministic and offline.
final class PlanExecuteLoopTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "pxl-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }

    private func loop(_ responses: [String], interactor: RuntimeInteractor = AutoApproveInteractor(),
                      requireApproval: Bool = false, maxReplans: Int = 2, verifyGoal: Bool = false,
                      sink: RuntimeEventSink = NullEventSink()) -> PlanExecuteLoop {
        let registry = ProviderRegistry(providers: [PlanScriptedProvider(responses)], keyStore: PXLNullKeys())
        return PlanExecuteLoop(providers: registry, providerId: "planscript", model: nil,
                               tools: .headless(), context: ToolContext(projectRoot: root),
                               sink: sink, interactor: interactor, requireApproval: requireApproval,
                               maxReplans: maxReplans, verifyGoal: verifyGoal)
    }

    private func writePlan(id: String, path: String, content: String) -> String {
        #"{"steps":[{"id":"\#(id)","intent":"write","tool":"write_file","arguments":{"path":"\#(path)","content":"\#(content)"}}]}"#
    }

    private func functionalEvidenceSignatures(_ objective: String) -> [String] {
        PlanExecuteLoop.functionalEvidenceRequirements(from: objective).map { requirement in
            let input = requirement.input == .fixtureFile ? "fixture" : "stdin"
            return "\(input)|\(requirement.validity.rawValue)|\(requirement.expectedExitCode)|\(requirement.requiresLineNumberEvidence)"
        }.sorted()
    }

    private let validPlan = """
    {"goal":"write","steps":[
      {"id":"E1","intent":"write","tool":"write_file","arguments":{"path":"a.txt","content":"hi"},"dependsOn":[]}
    ]}
    """

    func testValidPlanIsProposedAndExecuted() async {
        let out = await loop([validPlan]).run(goal: "write a.txt")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.plan?.steps.count, 1)
        XCTAssertTrue(out.execution?.success ?? false)
        XCTAssertEqual(try? String(contentsOfFile: root + "/a.txt", encoding: .utf8), "hi")
    }

    func testInvalidPlanGetsRepairedThenExecutes() async {
        let cyclic = #"{"goal":"g","steps":[{"id":"A","tool":"list_files","dependsOn":["B"]},{"id":"B","tool":"list_files","dependsOn":["A"]}]}"#
        let out = await loop([cyclic, validPlan]).run(goal: "do it")
        XCTAssertTrue(out.success, out.message)   // recovered on the 2nd (repaired) attempt
        XCTAssertEqual(out.plan?.steps.map(\.id), ["E1"])
    }

    func testUnparseableThenValid() async {
        let out = await loop(["I think we should start by exploring the repo.", validPlan]).run(goal: "x")
        XCTAssertTrue(out.success, out.message)
    }

    func testNeverValidFailsAfterRepairs() async {
        let cyclic = #"{"goal":"g","steps":[{"id":"A","tool":"list_files","dependsOn":["B"]},{"id":"B","tool":"list_files","dependsOn":["A"]}]}"#
        // maxPlanRepairs defaults to 2 → 3 attempts, all invalid.
        let out = await loop([cyclic, cyclic, cyclic]).run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertNil(out.execution)                       // never reached execution
        XCTAssertTrue(out.message.contains("could not produce"), out.message)
    }

    func testDeclinedPlanIsNotExecuted() async {
        let sink = PXLRecordingSink()
        let out = await loop([validPlan], interactor: PXLDeclining(), requireApproval: true, sink: sink).run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertNotNil(out.plan)                          // a plan WAS produced…
        XCTAssertNil(out.execution)                        // …but never executed
        XCTAssertTrue(out.message.contains("declined"), out.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/a.txt"))
        // R3 (review catch): planReady armed the sink's per-step state — a silent return left the
        // live line claiming a plan was executing. The decline is a TERMINAL event.
        XCTAssertTrue(sink.saw { if case .cancelled = $0 { return true }; return false },
                      "declining the plan must emit a terminal event")
    }

    // MARK: - Structured run-command preflight and repair

    func testRawShellPlanFailsClosedAndReplansToStructuredArguments() async {
        // A legacy raw command never reaches execution. Validation gives actionable feedback and the
        // next planner response uses one structured executable invocation.
        let lumpy = #"{"steps":[{"id":"E1","intent":"do everything","tool":"run_command","arguments":{"command":"mkdir x && cd x && npm init && npm test"}}]}"#
        let structured = #"{"steps":[{"id":"E1","intent":"make directory","tool":"run_command","arguments":{"executable":"/bin/mkdir","args":["x"],"cwd":"."}}]}"#
        let capt = CapturingProvider(id: "capt", responses: [lumpy, structured])
        let registry = ProviderRegistry(providers: [capt], keyStore: PXLNullKeys())
        let out = await PlanExecuteLoop(providers: registry, providerId: "capt", model: nil,
                                        tools: .headless(),
                                        context: ToolContext(
                                            projectRoot: root,
                                            shell: ShellPolicy(enabled: true, autoApprove: true)),
                                        requireApproval: false, verifyGoal: false).run(goal: "do it")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.plan?.steps.map(\.id), ["E1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/x"),
                      "the structured repaired plan executed")
        let feedback = capt.lastMessages.contains {
            $0.content.contains("invalid arguments")
                && $0.content.contains("raw 'command' is forbidden")
                && $0.content.contains("'executable'")
                && $0.content.contains("'args'")
        }
        XCTAssertTrue(feedback, "preflight must explain how to replace legacy raw command arguments")
    }

    func testLintExhaustionFailsClosedWithoutExecutingLumpyPlan() async {
        // Every attempt trips the empty-intent lint. Exhausting bounded decomposition must preserve
        // the rejected plan for diagnosis but never execute it or mint accepted evidence.
        let lintOnly = #"{"steps":[{"id":"E1","intent":"  ","tool":"write_file","arguments":{"path":"ok.txt","content":"done"}}]}"#
        let sink = PXLRecordingSink()
        let out = await loop([lintOnly, lintOnly, lintOnly], sink: sink).run(goal: "write ok.txt")
        XCTAssertFalse(out.success)
        XCTAssertNotNil(out.plan, "the rejected plan remains available as repair context")
        XCTAssertNil(out.execution)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/ok.txt"))
        XCTAssertTrue(out.message.contains("refusing to execute lumpy plan"), out.message)
        XCTAssertTrue(sink.saw {
            if case .failed(let reason) = $0 { return reason.contains("singular-step decomposition exhausted") }
            return false
        })
    }

    func testGoalNotMetWithReplansExhaustedEmitsFailed() async {
        // R3 (review catch): this exit returned silently while its step-failed sibling emitted
        // .failed — the sink's plan state stayed armed and the run ended with no verdict line.
        let sink = PXLRecordingSink()
        let notDone = #"{"done":false,"reason":"missing tests"}"#
        let out = await loop([validPlan, notDone], maxReplans: 0, verifyGoal: true, sink: sink).run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("goal not fully met"), out.message)
        XCTAssertTrue(sink.saw { if case .failed(let r) = $0 { return r.contains("goal not fully met") }; return false },
                      "replans-exhausted must emit the same terminal .failed as its step-failed sibling")
    }

    func testApprovedPlanExecutes() async {
        let out = await loop([validPlan], interactor: AutoApproveInteractor(), requireApproval: true).run(goal: "x")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(try? String(contentsOfFile: root + "/a.txt", encoding: .utf8), "hi")
    }

    func testPlannerErrorIsReported() async {
        let registry = ProviderRegistry(providers: [PXLFailingProvider()], keyStore: PXLNullKeys())
        let l = PlanExecuteLoop(providers: registry, providerId: "pxlfail", model: nil,
                                tools: .headless(), context: ToolContext(projectRoot: root))
        let out = await l.run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("planner error"), out.message)
    }

    func testPlannerPromptDocumentsSchemaAndTools() {
        let p = PlanExecuteLoop.plannerSystemPrompt(tools: .headless(), projectRoot: "/tmp")
        XCTAssertTrue(p.contains("\"steps\""))
        XCTAssertTrue(p.contains("${E1}"))          // documents the ref syntax
        XCTAssertTrue(p.contains("Capability negotiation:"))
        XCTAssertTrue(p.contains("CAPABILITY NEGOTIATION"))
        XCTAssertTrue(p.contains("Filesystem"))
        XCTAssertTrue(p.contains("write_file"))     // advertises tools
        XCTAssertTrue(p.contains(#"{"executable":"...","args":[],"cwd":".","stdin_path":"fixtures/valid.ndjson","allowed_exit_codes":[0]}"#))
        XCTAssertTrue(p.contains("intent/description") && p.contains("not evidence"))
        XCTAssertTrue(p.contains("aliases and casing variants are rejected"))
    }

    // MARK: - Phase 1.4b: replan on failure + verify-the-goal gate

    func testReplanAfterFailureSucceeds() async {
        // Plan A reads a missing file (runtime failure) → R3 step-repair abstains ("{}") → replan →
        // Plan B writes a real file. Each failed step consumes one repair response from the script.
        let planA = #"{"steps":[{"id":"E1","intent":"read missing","tool":"read_file","arguments":{"path":"missing.txt"}}]}"#
        let planB = writePlan(id: "E1", path: "ok.txt", content: "recovered")
        let out = await loop([planA, "{}", planB]).run(goal: "produce ok.txt")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.replansUsed, 1)                                  // recovered after one replan
        XCTAssertEqual(try? String(contentsOfFile: root + "/ok.txt", encoding: .utf8), "recovered")
    }

    func testFailedPlanSideEffectsRemainInVerificationHistoryAcrossReplan() async {
        // Plan 1 leaves a source file behind and fails. Its repaired retry also fails. Plan 2 only
        // writes a README. Verifying plan 2 in isolation would accept and launder the source side effect;
        // the turn-scoped attempt history must keep it incomplete.
        let plan1 = #"{"steps":[{"id":"E1","intent":"partial source write","tool":"run_command","arguments":{"executable":"touch","args":["Sources/ReplanLeak.swift"]}}]}"#
        let plan2 = writePlan(id: "E1", path: "README.md", content: "done")
        let done = #"{"done":true,"reason":"looks complete"}"#
        let provider = PlanScriptedProvider([plan1, "{}", plan2, done])
        let registry = ProviderRegistry(providers: [provider], keyStore: PXLNullKeys())
        let loop = PlanExecuteLoop(
            providers: registry, providerId: "planscript", model: nil,
            tools: ToolRegistry([ReplanPartialFailureRunCommandTool(), WriteFileTool()]),
            context: ToolContext(projectRoot: root), requireApproval: false,
            maxReplans: 1, verifyGoal: true
        )

        let out = await loop.run(goal: "make the requested source change")

        XCTAssertFalse(out.success, "the clean-looking final plan must not erase prior-plan side effects")
        XCTAssertTrue(out.message.contains("source mutation failed"), out.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/Sources/ReplanLeak.swift"),
                      "the failed prior plan really changed the workspace")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/README.md"),
                      "the final successful non-source plan did run")
    }

    func testVerifyNotDoneTriggersReplan() async {
        // Plan 1 succeeds, but the verify gate says NOT done → replan → Plan 2 adds the missing file.
        let plan1 = writePlan(id: "E1", path: "one.txt", content: "1")
        let verdictNotDone = #"{"done":false,"reason":"two.txt is still missing"}"#
        let plan2 = writePlan(id: "E1", path: "two.txt", content: "2")
        let verdictDone = #"{"done":true,"reason":"both files exist"}"#
        let out = await loop([plan1, verdictNotDone, plan2, verdictDone], verifyGoal: true).run(goal: "create one.txt and two.txt")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.replansUsed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/one.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/two.txt"))   // the replan-added file
    }

    func testPostVerificationHelperMutationGetsOneDeterministicReplayBeforeCritic() async {
        let mutationPlan = """
        {"steps":[
          {"id":"E1","intent":"edit parser","tool":"write_file","arguments":{"path":"Parser.swift","content":"struct Parser {}"}}
        ]}
        """
        let verifyThenMutatePlan = """
        {"steps":[
          {"id":"E1","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"]}},
          {"id":"E2","intent":"create stdin helper","tool":"write_file","arguments":{"path":"stdin-helper.swift","content":"print(\\\"ok\\\")"},"dependsOn":["E1"]}
        ]}
        """
        let provider = CountingProvider(id: "planscript", responses: [
            mutationPlan, verifyThenMutatePlan,
            #"{"done":true,"reason":"fresh deterministic proof and final review passed"}"#
        ])
        let verifier = PXLCountingVerifierTool()
        let sink = PXLRecordingSink()
        let registry = ProviderRegistry(providers: [provider], keyStore: PXLNullKeys())
        let out = await PlanExecuteLoop(
            providers: registry, providerId: "planscript", model: nil,
            tools: ToolRegistry([WriteFileTool(), verifier]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)), sink: sink,
            requireApproval: false, maxReplans: 1, verifyGoal: true
        ).run(goal: "build and verify receipt-ledger")

        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(verifier.count, 2,
                       "swift test runs once in the plan and exactly once again after helper mutation")
        XCTAssertEqual(out.replansUsed, 1,
                       "the parser mutation invalidates its pending plan before fresh verification")
        XCTAssertEqual(provider.count, 3,
                       "initial mutation plan, revision-bound verification plan, then critic")
        XCTAssertTrue(sink.saw {
            if case .actionStarted(_, _, let description) = $0 {
                return description.contains("re-verify")
                    && description.contains("stdin-helper.swift")
                    && description.contains("swift")
                    && description.contains("test")
            }
            return false
        })
    }

    func testTwoFreshIdenticalMissionsEachReceiveOneIndependentReplay() async throws {
        try "valid\n".write(toFile: root + "/valid.ndjson", atomically: true, encoding: .utf8)
        try "invalid\n".write(toFile: root + "/invalid.ndjson", atomically: true, encoding: .utf8)
        let store = AtomicReasoningControlStore(
            directory: URL(fileURLWithPath: root).appendingPathComponent(
                ".kist/reasoning", isDirectory: true))

        let first = await runMissionScopedVerificationAudit(root: root, store: store)
        let second = await runMissionScopedVerificationAudit(root: root, store: store)

        XCTAssertTrue(first.outcome.success, first.outcome.message)
        XCTAssertTrue(second.outcome.success, second.outcome.message)
        XCTAssertNotEqual(first.outcome.missionInstanceID, second.outcome.missionInstanceID)
        XCTAssertNotEqual(first.outcome.checkpointId, second.outcome.checkpointId)
        XCTAssertEqual(first.swiftTestInvocations, 2)
        XCTAssertEqual(second.swiftTestInvocations, 2)
        for result in [first, second] {
            let mission = try XCTUnwrap(result.outcome.missionInstanceID)
            XCTAssertEqual(result.outcome.finalVerificationReceipt?.missionInstanceID, mission)
            XCTAssertTrue(result.outcome.supportingCommandReceipts.allSatisfy {
                $0.missionInstanceID == mission
            })
            let checkpoint = try XCTUnwrap(result.outcome.checkpointId)
            let loaded = try await store.load(runID: checkpoint)
            let state = try XCTUnwrap(loaded)
            XCTAssertEqual(state.missionInstanceID, mission)
            XCTAssertEqual(
                state.projectIdentity,
                try AcceptedRunReceipt.computeProjectIdentity(projectRoot: root))
            XCTAssertEqual(state.verificationControl?.attemptsStarted, 1)
            XCTAssertEqual(state.verificationControl?.seenReplayStateKeys.count, 1)
        }
    }

    func testExplicitResumePreservesSeenReplayAndBlocksDuplicateReplay() async throws {
        try "valid\n".write(toFile: root + "/valid.ndjson", atomically: true, encoding: .utf8)
        try "invalid\n".write(toFile: root + "/invalid.ndjson", atomically: true, encoding: .utf8)
        let store = AtomicReasoningControlStore(
            directory: URL(fileURLWithPath: root).appendingPathComponent(
                ".kist/reasoning", isDirectory: true))
        let first = await runMissionScopedVerificationAudit(
            root: root, store: store, maxReplans: 1)
        XCTAssertTrue(first.outcome.success, first.outcome.message)
        let mission = try XCTUnwrap(PlanExecuteMissionID(
            rawValue: try XCTUnwrap(first.outcome.missionInstanceID)))

        let resumed = await runMissionScopedVerificationAudit(
            root: root, store: store, launchMode: .resume(mission), maxReplans: 1)

        XCTAssertFalse(resumed.outcome.success)
        XCTAssertTrue(resumed.outcome.message.contains(
            "deterministic verification already attempted"), resumed.outcome.message)
        XCTAssertEqual(resumed.outcome.missionInstanceID, mission.rawValue)
        XCTAssertEqual(resumed.swiftTestInvocations, 1,
                       "resume may execute the base verification but must not launch a second replay")
        let checkpoint = try XCTUnwrap(first.outcome.checkpointId)
        let loaded = try await store.load(runID: checkpoint)
        let state = try XCTUnwrap(loaded)
        XCTAssertEqual(state.verificationControl?.attemptsStarted, 1)
        XCTAssertEqual(state.verificationControl?.seenReplayStateKeys.count, 1)
    }

    func testCopiedMissionCheckpointCannotResumeInAnotherPhysicalProject() async throws {
        try "valid\n".write(toFile: root + "/valid.ndjson", atomically: true, encoding: .utf8)
        try "invalid\n".write(toFile: root + "/invalid.ndjson", atomically: true, encoding: .utf8)
        let sourceStore = AtomicReasoningControlStore(
            directory: URL(fileURLWithPath: root).appendingPathComponent(
                ".kist/reasoning", isDirectory: true))
        let first = await runMissionScopedVerificationAudit(root: root, store: sourceStore)
        XCTAssertTrue(first.outcome.success, first.outcome.message)
        let mission = try XCTUnwrap(PlanExecuteMissionID(
            rawValue: try XCTUnwrap(first.outcome.missionInstanceID)))

        let targetURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pxl-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: targetURL) }
        try FileManager.default.createDirectory(
            at: targetURL.appendingPathComponent(".kist", isDirectory: true),
            withIntermediateDirectories: true)
        try "valid\n".write(
            to: targetURL.appendingPathComponent("valid.ndjson"),
            atomically: true, encoding: .utf8)
        try "invalid\n".write(
            to: targetURL.appendingPathComponent("invalid.ndjson"),
            atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: root).appendingPathComponent(
                ".kist/reasoning", isDirectory: true),
            to: targetURL.appendingPathComponent(".kist/reasoning", isDirectory: true))
        let targetStore = AtomicReasoningControlStore(
            directory: targetURL.appendingPathComponent(".kist/reasoning", isDirectory: true))
        let resumed = await runMissionScopedVerificationAudit(
            root: targetURL.path, store: targetStore, launchMode: .resume(mission))

        XCTAssertFalse(resumed.outcome.success)
        XCTAssertTrue(resumed.outcome.message.contains("different physical project"),
                      resumed.outcome.message)
        XCTAssertEqual(resumed.providerCalls, 0)
        XCTAssertEqual(resumed.commandInvocations, 0)
    }

    func testWrongOrMalformedMissionTokenCannotResume() async throws {
        XCTAssertNil(PlanExecuteMissionID(rawValue: ""))
        XCTAssertNil(PlanExecuteMissionID(rawValue: String(repeating: "G", count: 64)))
        let store = AtomicReasoningControlStore(
            directory: URL(fileURLWithPath: root).appendingPathComponent(
                ".kist/reasoning", isDirectory: true))
        let wrong = try XCTUnwrap(PlanExecuteMissionID(
            rawValue: String(repeating: "b", count: 64)))

        let result = await runMissionScopedVerificationAudit(
            root: root, store: store, launchMode: .resume(wrong))

        XCTAssertFalse(result.outcome.success)
        XCTAssertTrue(result.outcome.message.contains("checkpoint was not found"),
                      result.outcome.message)
        XCTAssertEqual(result.providerCalls, 0)
        XCTAssertEqual(result.commandInvocations, 0)
    }

    func testParallelIdenticalFreshMissionsAreIsolated() async throws {
        try "valid\n".write(toFile: root + "/valid.ndjson", atomically: true, encoding: .utf8)
        try "invalid\n".write(toFile: root + "/invalid.ndjson", atomically: true, encoding: .utf8)
        let projectRoot = try XCTUnwrap(root)
        let store = AtomicReasoningControlStore(
            directory: URL(fileURLWithPath: projectRoot).appendingPathComponent(
                ".kist/reasoning", isDirectory: true))

        async let first = runMissionScopedVerificationAudit(root: projectRoot, store: store)
        async let second = runMissionScopedVerificationAudit(root: projectRoot, store: store)
        let results = await [first, second]

        XCTAssertTrue(results.allSatisfy(\.outcome.success),
                      results.map(\.outcome.message).joined(separator: " | "))
        XCTAssertEqual(Set(results.compactMap(\.outcome.missionInstanceID)).count, 2)
        XCTAssertEqual(Set(results.compactMap(\.outcome.checkpointId)).count, 2)
        XCTAssertTrue(results.allSatisfy { $0.swiftTestInvocations == 2 })
        for result in results {
            let checkpoint = try XCTUnwrap(result.outcome.checkpointId)
            let loaded = try await store.load(runID: checkpoint)
            let state = try XCTUnwrap(loaded)
            XCTAssertEqual(state.missionInstanceID, result.outcome.missionInstanceID)
            XCTAssertEqual(state.verificationControl?.attemptsStarted, 1)
        }
    }

    func testReplanReconfigurationDoesNotResetMissionReplayCap() throws {
        let mission = String(repeating: "c", count: 64)
        var state = ReasoningControlState(
            id: "plan-mission-" + mission, route: .planned,
            goalFingerprint: "goal", missionInstanceID: mission)
        try state.configureVerificationControl(
            missionInstanceID: mission,
            completionContractFingerprint: "completion", obligationsFingerprint: "obligations",
            executionPolicyFingerprint: "policy", workspaceManifestDigest: "manifest",
            attemptLimit: 1)
        try state.beginVerificationReplay(stateKey: "first")
        state.replanCount = 1

        try state.configureVerificationControl(
            missionInstanceID: mission,
            completionContractFingerprint: "completion", obligationsFingerprint: "obligations",
            executionPolicyFingerprint: "policy", workspaceManifestDigest: "manifest",
            attemptLimit: 1)

        XCTAssertEqual(state.verificationControl?.attemptsStarted, 1)
        XCTAssertThrowsError(try state.beginVerificationReplay(stateKey: "second"))
        XCTAssertEqual(state.verificationControl?.attemptsStarted, 1)
    }

    func testPlannerEnrichmentCanChangeButCanonicalObjectiveCannot() async throws {
        let store = AtomicReasoningControlStore(
            directory: URL(fileURLWithPath: root).appendingPathComponent(
                ".kist/reasoning", isDirectory: true))
        let mission = PlanExecuteMissionID.fresh()
        let canonical = "Inspect the existing project without changing it."

        func run(_ enrichment: String, canonicalObjective: String,
                 launchMode: PlanExecuteLaunchMode) async -> PlanOutcome {
            let provider = PlanScriptedProvider(["not a plan"])
            return await PlanExecuteLoop(
                providers: ProviderRegistry(providers: [provider], keyStore: PXLNullKeys()),
                providerId: provider.id, model: nil, tools: ToolRegistry([]),
                context: ToolContext(projectRoot: root), requireApproval: false,
                maxPlanRepairs: 0, maxReplans: 0, verifyGoal: false,
                launchMode: launchMode,
                freshMissionInstanceID: launchMode == .fresh ? mission : nil,
                functionalObjective: canonical + "\n\n" + enrichment,
                canonicalFunctionalObjective: canonicalObjective,
                reasoningStore: store
            ).run(goal: "planner memory \(enrichment)", checkpointGoal: canonical)
        }

        let first = await run("effort=A", canonicalObjective: canonical, launchMode: .fresh)
        XCTAssertFalse(first.success)
        let runID = try XCTUnwrap(first.checkpointId)
        let loadedFirstState = try await store.load(runID: runID)
        let firstState = try XCTUnwrap(loadedFirstState)
        let firstPolicy = firstState.verificationControl?.executionPolicyFingerprint

        let resumed = await run(
            "effort=B", canonicalObjective: canonical, launchMode: .resume(mission))
        XCTAssertFalse(resumed.success)
        XCTAssertFalse(resumed.message.contains("different goal"), resumed.message)
        XCTAssertFalse(resumed.message.contains("canonical functional objective"), resumed.message)
        let loadedResumedState = try await store.load(runID: runID)
        let resumedState = try XCTUnwrap(loadedResumedState)
        XCTAssertEqual(resumedState.verificationControl?.executionPolicyFingerprint, firstPolicy)

        let changed = await run(
            "effort=C", canonicalObjective: "Change a different project.",
            launchMode: .resume(mission))
        XCTAssertFalse(changed.success)
        XCTAssertTrue(changed.message.contains("different goal")
            || changed.message.contains("canonical functional objective"), changed.message)
    }

    func testRecordedMutationAdvancesManifestAndForcesFreshPlan() async throws {
        let firstPlan = #"{"steps":[{"id":"E1","intent":"create artifact","tool":"write_file","arguments":{"path":"generated.txt","content":"recorded\n"}},{"id":"E2","intent":"read artifact","tool":"read_file","arguments":{"path":"generated.txt"},"dependsOn":["E1"]}]}"#
        let replacementPlan = #"{"steps":[{"id":"R1","intent":"read recorded artifact","tool":"read_file","arguments":{"path":"generated.txt"}}]}"#
        let provider = PlanScriptedProvider([firstPlan, replacementPlan])
        let store = AtomicReasoningControlStore(
            directory: URL(fileURLWithPath: root).appendingPathComponent(
                ".kist/reasoning", isDirectory: true))
        let outcome = await PlanExecuteLoop(
            providers: ProviderRegistry(providers: [provider], keyStore: PXLNullKeys()),
            providerId: provider.id, model: nil,
            tools: ToolRegistry([WriteFileTool(), ReadFileTool()]),
            context: ToolContext(projectRoot: root), requireApproval: false,
            maxPlanRepairs: 0, maxReplans: 1, verifyGoal: false,
            reasoningStore: store
        ).run(goal: "Create generated.txt and read it back.")

        XCTAssertTrue(outcome.success, outcome.message)
        XCTAssertEqual(outcome.replansUsed, 1)
        XCTAssertEqual(try String(contentsOfFile: root + "/generated.txt"), "recorded\n")
        let runID = try XCTUnwrap(outcome.checkpointId)
        let loadedState = try await store.load(runID: runID)
        let state = try XCTUnwrap(loadedState)
        let receipts = state.workspaceActionReceipts ?? []
        XCTAssertEqual(receipts.count, 2, "obsolete pending read must not execute")
        XCTAssertTrue(receipts.allSatisfy(\.hasValidReceiptDigest))
        XCTAssertEqual(state.workspaceManifestRevision, 2)
        XCTAssertEqual(state.lastAcknowledgedGovernedWorkspaceDigest,
                       PlanExecuteLoop.governedWorkspaceDigest(projectRoot: root))
        XCTAssertEqual(state.executablePlanSnapshots?.last?.workspaceManifestDigest,
                       state.workspaceManifestDigest)
        XCTAssertNil(state.activeWorkspaceAction)
    }

    func testFailedMutatingToolStillCommitsWorkspaceReceipt() async throws {
        let plan = #"{"steps":[{"id":"E1","intent":"attempt write","tool":"write_file","arguments":{"path":"denied.txt","content":"x"}}]}"#
        let provider = PlanScriptedProvider([plan])
        let store = AtomicReasoningControlStore(
            directory: URL(fileURLWithPath: root).appendingPathComponent(
                ".kist/reasoning", isDirectory: true))
        let outcome = await PlanExecuteLoop(
            providers: ProviderRegistry(providers: [provider], keyStore: PXLNullKeys()),
            providerId: provider.id, model: nil,
            tools: ToolRegistry([PXLFailingWriteTool()]),
            context: ToolContext(projectRoot: root), requireApproval: false,
            maxPlanRepairs: 0, maxReplans: 0, verifyGoal: false,
            reasoningStore: store
        ).run(goal: "Write denied.txt.")

        XCTAssertFalse(outcome.success)
        let runID = try XCTUnwrap(outcome.checkpointId)
        let loadedState = try await store.load(runID: runID)
        let state = try XCTUnwrap(loadedState)
        let receipt = try XCTUnwrap(state.workspaceActionReceipts?.only)
        XCTAssertFalse(receipt.success)
        XCTAssertTrue(receipt.hasValidReceiptDigest)
        XCTAssertEqual(state.workspaceManifestRevision, 1)
        XCTAssertNil(state.activeWorkspaceAction)
        XCTAssertEqual(state.lastAcknowledgedGovernedWorkspaceDigest,
                       PlanExecuteLoop.governedWorkspaceDigest(projectRoot: root))
    }

    func testExternalWorkspaceDriftBlocksResumeBeforePlanning() async throws {
        let store = AtomicReasoningControlStore(
            directory: URL(fileURLWithPath: root).appendingPathComponent(
                ".kist/reasoning", isDirectory: true))
        let mission = PlanExecuteMissionID.fresh()
        let canonical = "Inspect the project."
        let first = await PlanExecuteLoop(
            providers: ProviderRegistry(
                providers: [PlanScriptedProvider(["not a plan"])], keyStore: PXLNullKeys()),
            providerId: "planscript", model: nil, tools: ToolRegistry([]),
            context: ToolContext(projectRoot: root), requireApproval: false,
            maxPlanRepairs: 0, maxReplans: 0, verifyGoal: false,
            freshMissionInstanceID: mission,
            canonicalFunctionalObjective: canonical, reasoningStore: store
        ).run(goal: canonical, checkpointGoal: canonical)
        XCTAssertFalse(first.success)

        try "external".write(toFile: root + "/unrecorded.txt", atomically: true,
                             encoding: .utf8)
        let resumed = await PlanExecuteLoop(
            providers: ProviderRegistry(
                providers: [PlanScriptedProvider(["should not be called"])], keyStore: PXLNullKeys()),
            providerId: "planscript", model: nil, tools: ToolRegistry([]),
            context: ToolContext(projectRoot: root), requireApproval: false,
            maxPlanRepairs: 0, maxReplans: 0, verifyGoal: false,
            launchMode: .resume(mission),
            canonicalFunctionalObjective: canonical, reasoningStore: store
        ).run(goal: canonical, checkpointGoal: canonical)

        XCTAssertFalse(resumed.success)
        XCTAssertTrue(resumed.message.contains("reconciliation required"), resumed.message)
    }

    func testVerificationOnlyAuditReplaysAfterOpaqueAppChecksAndReachesBoundReview() async {
        XCTAssertNoThrow(try "valid\n".write(
            toFile: root + "/valid.ndjson", atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "invalid\n".write(
            toFile: root + "/invalid.ndjson", atomically: true, encoding: .utf8))
        let plan = """
        {"steps":[
          {"id":"E1","intent":"build","tool":"run_command","arguments":{"executable":"swift","args":["build"],"cwd":"."}},
          {"id":"E2","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"],"cwd":"."},"dependsOn":["E1"]},
          {"id":"E3","intent":"valid fixture","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--input","valid.ndjson"],"cwd":"."},"dependsOn":["E2"]},
          {"id":"E4","intent":"expected invalid fixture","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--input","invalid.ndjson"],"cwd":".","allowed_exit_codes":[1]},"dependsOn":["E3"]},
          {"id":"E5","intent":"stdin fixture","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":[],"cwd":".","stdin_path":"valid.ndjson"},"dependsOn":["E4"]},
          {"id":"E6","intent":"hash source","tool":"run_command","arguments":{"executable":"shasum","args":["-a","256","Package.swift"],"cwd":"."},"dependsOn":["E5"]}
        ]}
        """
        let provider = CapturingProvider(id: "planscript", responses: [
            plan, #"{"done":true,"reason":"fresh host-bound audit passed"}"#,
        ])
        let commands = PXLVerificationAuditCommandTool()
        let registry = ProviderRegistry(providers: [provider], keyStore: PXLNullKeys())
        let contract = PlanExecuteCompletionContract.derive(canonicalRequest:
            "Verify the existing project without editing unless a deterministic check fails. Run swift build, swift test, valid fixture input with exit 0, invalid fixture input with expected exit 1 and a line-numbered error, and structured stdin.")
        let out = await PlanExecuteLoop(
            providers: registry, providerId: "planscript", model: nil,
            tools: ToolRegistry([commands]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)),
            requireApproval: false, maxReplans: 1, verifyGoal: true,
            completionContract: contract
        ).run(goal: "MEMORY WRAPPER THAT MUST NOT ALTER THE CONTRACT\nGOAL: verify receipt-ledger")

        XCTAssertEqual(contract.kind, .verificationOnly)
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(commands.invocations.filter { $0.hasPrefix("swift test") }.count, 2,
                       "the exact typed test must run once in-plan and once after opaque app checks")
        XCTAssertTrue(commands.invocations.last?.hasPrefix("swift test") == true,
                      "host replay, not planner ordering, must bind the final revision")
        let reviewPrompt = provider.lastMessages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(reviewPrompt.contains("Completion contract: verification-only [\(contract.fingerprint)]"),
                      reviewPrompt)
        XCTAssertTrue(reviewPrompt.contains("Host verification receipt:")
            && reviewPrompt.contains("swift") && reviewPrompt.contains("test"), reviewPrompt)
        XCTAssertTrue(reviewPrompt.contains("Governed workspace digest:"), reviewPrompt)
    }

    func testDelegationContractOutranksChildVerificationWordingAndPlanExecuteFailsClosed() async {
        let request = "delegate a reviewer to verify the parser fix without edits"
        let contract = PlanExecuteCompletionContract.derive(canonicalRequest: request)
        XCTAssertEqual(contract.requestedIntent, .delegate)
        XCTAssertEqual(contract.expectedOutcome, .delegation)
        XCTAssertEqual(contract.kind, .delegation)

        let provider = CapturingProvider(id: "planscript", responses: [])
        let out = await PlanExecuteLoop(
            providers: ProviderRegistry(providers: [provider], keyStore: PXLNullKeys()),
            providerId: "planscript", model: nil,
            tools: ToolRegistry([WriteFileTool()]),
            context: ToolContext(projectRoot: root),
            requireApproval: false, maxReplans: 0, verifyGoal: false,
            completionContract: contract
        ).run(goal: request)

        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("host-bound delegation grant"), out.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/delegated.txt"),
                       "PlanExecute must execute zero parent-local mutation for delegation")
    }

    func testHostOwnedReviewClauseRepairsToFunctionalPlanAndReachesOuterBoundary() async {
        let original = """
        Verify the existing project without editing files. Run swift build, swift test, valid and invalid fixture inputs with actual/allowed exit 0 and 1, require a line-numbered invalid-fixture error, and structured stdin. Require independent final review by a concrete provider:model different from every producer. Emit BuilderRun verification and reviewer identities; fail closed rather than self-review.
        """
        let functional = PlanExecuteCompletionContract.functionalObjective(from: original)
        XCTAssertTrue(functional.contains("valid and invalid fixture inputs")
            && functional.contains("structured stdin"), functional)
        XCTAssertFalse(functional.lowercased().contains("final review"), functional)
        XCTAssertFalse(functional.lowercased().contains("reviewer identit"), functional)

        let forbidden = """
        {"steps":[
          {"id":"E1","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"]}},
          {"id":"E2","intent":"independent final review","tool":"generate","arguments":{"prompt":"review as a distinct provider"},"dependsOn":["E1"]}
        ]}
        """
        let functionalPlan = """
        {"steps":[
          {"id":"E1","intent":"build","tool":"run_command","arguments":{"executable":"swift","args":["build"]}},
          {"id":"E2","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"]},"dependsOn":["E1"]},
          {"id":"E3","intent":"valid fixture","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--input","valid.ndjson"]},"dependsOn":["E2"]},
          {"id":"E4","intent":"expected invalid fixture","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--input","invalid.ndjson"],"allowed_exit_codes":[1]},"dependsOn":["E3"]},
          {"id":"E5","intent":"stdin fixture","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":[],"stdin_path":"valid.ndjson"},"dependsOn":["E4"]}
        ]}
        """
        let rawStdinSecret = "RAW-STDIN-SECRET-MUST-NOT-REACH-CRITIC\n"
        XCTAssertNoThrow(try rawStdinSecret.write(
            toFile: root + "/valid.ndjson", atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "invalid\n".write(
            toFile: root + "/invalid.ndjson", atomically: true, encoding: .utf8))
        let provider = CapturingProvider(id: "planscript", responses: [
            forbidden, functionalPlan,
            #"{"done":true,"reason":"typed host facts suffice without raw stdin or outer review"}"#,
        ])
        let commands = PXLVerificationAuditCommandTool()
        let registry = ProviderRegistry(providers: [provider], keyStore: PXLNullKeys())
        let contract = PlanExecuteCompletionContract.derive(canonicalRequest: original)
        let out = await PlanExecuteLoop(
            providers: registry, providerId: "planscript", model: nil,
            tools: ToolRegistry([commands]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)),
            requireApproval: false, maxReplans: 0, verifyGoal: true,
            completionContract: contract, hostOwnedFinalReview: true,
            functionalObjective: functional, hostContractID: "builder-contract-live"
        ).run(goal: original)

        XCTAssertTrue(out.success, out.message)
        XCTAssertFalse(out.plan?.steps.contains(where: {
            ["generate", "grounded_answer"].contains($0.tool)
                || $0.intent.lowercased().contains("final review")
        }) ?? true, "producer plan reaching the outer boundary must contain no self-review step")
        XCTAssertTrue(provider.messageCalls.dropLast().flatMap { $0 }.contains {
            $0.content.contains("outer BuilderRun host")
        }, "invalid self-review plan must be repaired with explicit host-ownership steering")
        let innerCritic = provider.lastMessages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(innerCritic.contains("INNER FUNCTIONAL SEMANTIC CHECK"), innerCritic)
        XCTAssertTrue(innerCritic.contains("Absence of") && innerCritic.contains("expected"), innerCritic)
        XCTAssertTrue(innerCritic.contains("HOST-AUTHENTICATED FUNCTIONAL EVIDENCE"), innerCritic)
        XCTAssertTrue(innerCritic.contains("build.clean-exit"), innerCritic)
        XCTAssertTrue(innerCritic.contains("fixture-file.valid.exit-0"), innerCritic)
        XCTAssertTrue(innerCritic.contains("fixture-file.invalid.exit-1"), innerCritic)
        XCTAssertTrue(innerCritic.contains("expected-domain-failure.fixture-file.invalid.exit-1"),
                      innerCritic)
        XCTAssertTrue(innerCritic.contains("structured-stdin.valid.exit-0"), innerCritic)
        XCTAssertTrue(innerCritic.contains(#""actual_exit_code":1"#), innerCritic)
        XCTAssertTrue(innerCritic.contains(#""allowed_exit_codes":[1]"#), innerCritic)
        XCTAssertTrue(innerCritic.contains(#""line_number_evidence":true"#), innerCritic)
        XCTAssertTrue(innerCritic.contains(
            #""stdin_source_kind":"\#(PlanStandardInputSourceKind.governedPath.rawValue)""#),
            innerCritic)
        XCTAssertTrue(innerCritic.contains(#""stdin_relative_path":"valid.ndjson""#),
                      innerCritic)
        XCTAssertTrue(innerCritic.contains(#""stdin_sha256":"#)
            && innerCritic.contains(#""replay_ordinal":"#), innerCritic)
        XCTAssertTrue(innerCritic.contains("stdin-bearing command output suppressed"), innerCritic)
        XCTAssertTrue(innerCritic.contains("MUST NOT be requested"), innerCritic)
        XCTAssertFalse(innerCritic.contains(rawStdinSecret.trimmingCharacters(
            in: .whitespacesAndNewlines)), innerCritic)
        XCTAssertTrue(commands.invocations.contains { $0.contains("valid.ndjson") })
        XCTAssertTrue(commands.invocations.contains { $0.contains("invalid.ndjson") })
        guard let receipt = out.finalVerificationReceipt else {
            return XCTFail("outer capture must receive the exact post-frontier replay receipt")
        }
        XCTAssertEqual(receipt.contractID, "builder-contract-live")
        XCTAssertEqual(receipt.stepID, "E2")
        XCTAssertEqual(receipt.tool, "run_command")
        XCTAssertEqual(receipt.invocation.executable, "swift")
        XCTAssertEqual(receipt.invocation.argv, ["test"])
        XCTAssertFalse(receipt.invocation.hasStandardInput)
        XCTAssertEqual(receipt.expectedExitCode, 0)
        XCTAssertEqual(receipt.actualExitCode, 0)
        XCTAssertTrue(receipt.freshAfterMutationFrontier)
        XCTAssertFalse(receipt.commandFingerprint.isEmpty)
        XCTAssertFalse(receipt.outputDigest.isEmpty)
        XCTAssertTrue(receipt.boundedRedactedOutputExcerpt.contains("ok"))
    }

    func testFunctionalEvidenceReviewSectionRejectsIncompleteReceiptMapping() throws {
        let obligations = [
            PlanSupportingObligation(id: "fixture-file.valid.exit-0", kind: .fixtureFileInput),
        ]
        let obligationsFingerprint = PlanExecuteLoop.supportingObligationsFingerprint(obligations)
        let finalReceipt = PlanFinalVerificationReceipt(
            missionInstanceID: "mission",
            contractID: "contract", stepID: "E2", tool: "run_command",
            invocation: PlanFinalVerificationInvocation(
                executable: "swift", argv: ["test"], hasStandardInput: false),
            commandFingerprint: "final-command",
            expectedExitCode: 0, actualExitCode: 0,
            outputDigest: PlanExecuteLoop.secureDigest("ok"),
            boundedRedactedOutputExcerpt: "ok",
            governedWorkspaceDigest: "workspace",
            completionContractFingerprint: "completion",
            executionPolicyFingerprint: "policy",
            verifiedAt: Date(), freshAfterMutationFrontier: true,
            captureOrdinal: 9, obligationsFingerprint: obligationsFingerprint,
            workspaceManifestDigest: "manifest",
            trustedCommandReference: makePlanTestTrustedCommandReference(
                arguments: ["executable": "swift", "args": ["test"]],
                stdout: "ok", exitCode: 0))

        let result = PlanExecuteLoop.makeFunctionalEvidenceReviewSection(
            requiredObligations: obligations, requirements: [],
            supportingReceipts: [], finalReceipt: finalReceipt,
            missionInstanceID: "mission", contractID: "contract",
            completionContractFingerprint: "completion",
            obligationsFingerprint: obligationsFingerprint,
            executionPolicyFingerprint: "policy",
            workspaceManifestDigest: "manifest",
            governedWorkspaceDigest: "workspace")
        guard case .failure(let error) = result else {
            return XCTFail("an uncovered host obligation must fail closed")
        }
        XCTAssertTrue(error.description.contains("no valid bound command receipt"),
                      error.description)
    }

    func testMissingExitOrLineEvidenceFailsBeforeInnerCritic() async {
        XCTAssertNoThrow(try "valid\n".write(
            toFile: root + "/valid.ndjson", atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "invalid\n".write(
            toFile: root + "/invalid.ndjson", atomically: true, encoding: .utf8))
        let original = """
        Verify without editing. Run swift build, swift test, valid fixture input with exit 0,
        invalid fixture input with allowed exit 1 and line-numbered errors, and structured stdin
        with exit 0. Require authoritative final review by a distinct provider:model.
        """
        let plan = """
        {"steps":[
          {"id":"E1","intent":"build","tool":"run_command","arguments":{"executable":"swift","args":["build"],"allowed_exit_codes":[0]}},
          {"id":"E2","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"],"allowed_exit_codes":[0]},"dependsOn":["E1"]},
          {"id":"E3","intent":"valid fixture","tool":"run_command","arguments":{"executable":"./app","args":["--input","valid.ndjson"],"allowed_exit_codes":[0]},"dependsOn":["E2"]},
          {"id":"E4","intent":"invalid fixture","tool":"run_command","arguments":{"executable":"./app","args":["--input","invalid.ndjson"],"allowed_exit_codes":[1]},"dependsOn":["E3"]},
          {"id":"E5","intent":"stdin","tool":"run_command","arguments":{"executable":"./app","args":[],"stdin_path":"valid.ndjson","allowed_exit_codes":[0]},"dependsOn":["E4"]}
        ]}
        """
        let variants = [
            ("missing-line", PXLVerificationAuditCommandTool(includeLineNumberEvidence: false)),
            ("missing-exit", PXLVerificationAuditCommandTool(
                omitExpectedDomainExitMetadata: true)),
        ]
        for (label, commands) in variants {
            let provider = CapturingProvider(id: "planscript", responses: [
                plan, #"{"done":true,"reason":"must never be called"}"#,
            ])
            let functional = PlanExecuteCompletionContract.functionalObjective(from: original)
            let out = await PlanExecuteLoop(
                providers: ProviderRegistry(providers: [provider], keyStore: PXLNullKeys()),
                providerId: "planscript", model: "c1", tools: ToolRegistry([commands]),
                context: ToolContext(projectRoot: root,
                                     shell: ShellPolicy(enabled: true, autoApprove: true)),
                requireApproval: false, maxReplans: 0, verifyGoal: true,
                completionContract: .derive(canonicalRequest: original),
                hostOwnedFinalReview: true, functionalObjective: functional,
                hostContractID: "missing-host-evidence-\(label)"
            ).run(goal: original)

            XCTAssertFalse(out.success, "\(label): \(out.message)")
            XCTAssertEqual(provider.messageCalls.count, 1,
                           "\(label) must stop before the inner critic")
        }
    }

    func testFunctionalEvidenceCompilerScopesExactLivePromptByteForByte() {
        let prefixed = "/plan-execute Verification-only audit of the existing receipt-ledger project. Do not edit or write any file. Run swift build, swift test, valid fixture input with exit 0, invalid fixture input with allowed exit 1 and line-numbered errors, and structured stdin with exit 0. Require fresh digest-bound deterministic evidence and authoritative final review by a concrete provider:model different from every planner/worker/coder producer. Fail closed on unknown identity, self-review, stale evidence, any workspace mutation, or missing review receipt."
        let withoutPrefix = String(prefixed.dropFirst("/plan-execute ".count))
        let expected = [
            "fixture|valid|0|false",
            "fixture|invalid|1|true",
            "stdin|valid|0|false",
        ].sorted()

        for objective in [prefixed, withoutPrefix] {
            let requirements = PlanExecuteLoop.functionalEvidenceRequirements(from: objective)
            XCTAssertEqual(functionalEvidenceSignatures(objective), expected, objective)
            XCTAssertNil(PlanExecuteLoop.functionalEvidenceCompilationIssue(
                objective: objective, requirements: requirements), objective)
        }
    }

    func testFunctionalEvidenceCompilerIsClauseScopedAndOrderIndependent() {
        let expected = [
            "fixture|valid|0|false",
            "fixture|invalid|1|true",
            "stdin|valid|0|false",
        ].sorted()
        let objectives = [
            "Run valid fixture input, invalid fixture input with allowed exit 1 and line-numbered errors, and structured stdin with exit 0.",
            "Run structured stdin with exit 0, invalid fixture input with allowed exit 1 and line-numbered errors, and valid fixture input.",
        ]

        for objective in objectives {
            let requirements = PlanExecuteLoop.functionalEvidenceRequirements(from: objective)
            XCTAssertEqual(functionalEvidenceSignatures(objective), expected, objective)
            XCTAssertNil(PlanExecuteLoop.functionalEvidenceCompilationIssue(
                objective: objective, requirements: requirements), objective)
        }
    }

    func testFunctionalEvidenceCompilerBindsCompactPairedExits() {
        let objective = "Run valid and invalid fixture inputs with exits 0 and 1, and structured stdin with exit 0."
        let requirements = PlanExecuteLoop.functionalEvidenceRequirements(from: objective)
        XCTAssertEqual(functionalEvidenceSignatures(objective), [
            "fixture|valid|0|false",
            "fixture|invalid|1|false",
            "stdin|valid|0|false",
        ].sorted())
        XCTAssertNil(PlanExecuteLoop.functionalEvidenceCompilationIssue(
            objective: objective, requirements: requirements))
    }

    func testFunctionalEvidenceCompilerFailsClosedOnAmbiguousOrConflictingExits() {
        let objectives = [
            "Run invalid fixture input with allowed exit 1 and expected exit 0.",
            "Run valid and invalid fixture inputs with exit 0.",
            "Run structured stdin with exit 0 and exit 1.",
            "Run invalid fixture input with allowed exit.",
            "Run invalid fixture input with exit 1, invalid fixture input with exit 0.",
        ]

        for objective in objectives {
            let requirements = PlanExecuteLoop.functionalEvidenceRequirements(from: objective)
            XCTAssertNotNil(PlanExecuteLoop.functionalEvidenceCompilationIssue(
                objective: objective, requirements: requirements), objective)
        }
    }

    func testConflictingFunctionalEvidenceExitsFailBeforeToolExecution() async {
        let original = "Verify without edits. Run invalid fixture input with allowed exit 1 and expected exit 0."
        let provider = CapturingProvider(id: "planscript", responses: [validPlan])
        let commands = PXLVerificationAuditCommandTool()
        let out = await PlanExecuteLoop(
            providers: ProviderRegistry(providers: [provider], keyStore: PXLNullKeys()),
            providerId: "planscript", model: nil,
            tools: ToolRegistry([commands]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)),
            requireApproval: false, maxReplans: 0, verifyGoal: false,
            completionContract: .derive(canonicalRequest: original),
            hostOwnedFinalReview: true, functionalObjective: original
        ).run(goal: original)

        XCTAssertFalse(out.success)
        XCTAssertTrue(commands.invocations.isEmpty,
                      "conflicting deterministic obligations must fail before tool execution")
    }

    func testRunCommandPlanValidationRejectsArgumentAliases() {
        let plan = ExecutablePlan(goal: "stdin", steps: [PlanStep(
            id: "E1", intent: "stdin", tool: "run_command",
            argumentsJSON: #"{"executable":"./app","args":[],"standard_input":"valid\n","allowedExitCodes":[0]}"#)])
        let errors = plan.validate()
        XCTAssertTrue(errors.contains { error in
            guard case .invalidArguments(_, let reason) = error else { return false }
            return reason.contains("allowedExitCodes") && reason.contains("standard_input")
                && reason.contains("aliases and casing variants are rejected")
        }, "run_command aliases must fail deterministic plan validation: \(errors)")
    }

    func testMissingStdinDescriptionReplansToCanonicalPlanAndPersistsRedactedReceipt() async throws {
        let governedPayload = "GOVERNED-STDIN-PAYLOAD-DO-NOT-CHECKPOINT\n"
        try governedPayload.write(toFile: root + "/valid.ndjson", atomically: true, encoding: .utf8)
        try "invalid\n".write(toFile: root + "/invalid.ndjson", atomically: true, encoding: .utf8)
        let original = "Verification-only audit without editing files. Run swift build, swift test, valid fixture input with exit 0, invalid fixture input with allowed exit 1 and line-numbered errors, and structured stdin with exit 0. Require authoritative final review by a distinct provider:model."
        let missingStdin = """
        {"steps":[
          {"id":"E1","intent":"build","tool":"run_command","arguments":{"executable":"swift","args":["build"],"cwd":".","allowed_exit_codes":[0]}},
          {"id":"E2","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"],"cwd":".","allowed_exit_codes":[0]},"dependsOn":["E1"]},
          {"id":"E3","intent":"valid fixture","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--input","valid.ndjson"],"cwd":".","allowed_exit_codes":[0]},"dependsOn":["E2"]},
          {"id":"E4","intent":"invalid fixture","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--input","invalid.ndjson"],"cwd":".","allowed_exit_codes":[1]},"dependsOn":["E3"]},
          {"id":"E5","intent":"description only: structured stdin SECRET-DESCRIPTION-PAYLOAD","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":[],"cwd":".","allowed_exit_codes":[0]},"dependsOn":["E4"]}
        ]}
        """
        let canonical = """
        {"steps":[
          {"id":"E1","intent":"build","tool":"run_command","arguments":{"executable":"swift","args":["build"],"cwd":".","allowed_exit_codes":[0]}},
          {"id":"E2","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"],"cwd":".","allowed_exit_codes":[0]},"dependsOn":["E1"]},
          {"id":"E3","intent":"valid fixture","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--input","valid.ndjson"],"cwd":".","allowed_exit_codes":[0]},"dependsOn":["E2"]},
          {"id":"E4","intent":"invalid fixture","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--input","invalid.ndjson"],"cwd":".","allowed_exit_codes":[1]},"dependsOn":["E3"]},
          {"id":"E5","intent":"valid stdin","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":[],"cwd":".","stdin_path":"valid.ndjson","allowed_exit_codes":[0]},"dependsOn":["E4"]}
        ]}
        """
        let provider = CapturingProvider(id: "planscript", responses: [
            missingStdin, canonical, #"{"done":true,"reason":"all functional evidence passed"}"#,
        ])
        let commands = PXLVerificationAuditCommandTool()
        let store = AtomicReasoningControlStore(
            directory: URL(fileURLWithPath: root)
                .appendingPathComponent(".kist", isDirectory: true)
                .appendingPathComponent("reasoning", isDirectory: true))
        let functional = PlanExecuteCompletionContract.functionalObjective(from: original)
        let out = await PlanExecuteLoop(
            providers: ProviderRegistry(providers: [provider], keyStore: PXLNullKeys()),
            providerId: "planscript", model: "c1", tools: ToolRegistry([commands]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)),
            requireApproval: false, maxReplans: 1, verifyGoal: true,
            completionContract: .derive(canonicalRequest: original),
            hostOwnedFinalReview: true, functionalObjective: functional,
            hostContractID: "stdin-convergence-contract", reasoningStore: store
        ).run(goal: original)

        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.replansUsed, 1, "one bounded repair must converge")
        let repairPrompt = provider.messageCalls.dropFirst().first?
            .map(\.content).joined(separator: "\n") ?? ""
        XCTAssertTrue(repairPrompt.contains(#"{"executable":"...","args":[],"cwd":".","stdin_path":"fixtures/valid.ndjson","allowed_exit_codes":[0]}"#), repairPrompt)
        XCTAssertTrue(repairPrompt.contains("intent/description is not stdin evidence"), repairPrompt)

        let checkpointID = try XCTUnwrap(out.checkpointId)
        let loadedOptional = try await store.load(runID: checkpointID)
        let loaded = try XCTUnwrap(loadedOptional)
        let receipts = try XCTUnwrap(loaded.rejectedPlanAttemptReceipts)
        XCTAssertEqual(receipts.count, 1)
        let receipt = receipts[0]
        XCTAssertEqual(receipt.ordinal, 1)
        XCTAssertEqual(receipt.providerID, "planscript")
        XCTAssertEqual(receipt.modelID, "c1")
        XCTAssertFalse(receipt.planFingerprint.isEmpty)
        XCTAssertTrue(receipt.validationErrors.joined(separator: "\n").contains("valid stdin"))
        let stdinStep = try XCTUnwrap(receipt.stepSummaries.first { $0.stepID == "E5" })
        XCTAssertFalse(stdinStep.stdinPresent)
        XCTAssertNil(stdinStep.stdinByteCount)
        XCTAssertNil(stdinStep.stdinSHA256)
        XCTAssertEqual(stdinStep.argumentTypes["allowed_exit_codes"], "array")
        let receiptJSON = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        XCTAssertFalse(receiptJSON.contains("SECRET-DESCRIPTION-PAYLOAD"), receiptJSON)
        let checkpointJSON = String(decoding: try JSONEncoder().encode(loaded), as: UTF8.self)
        XCTAssertFalse(checkpointJSON.contains(governedPayload), checkpointJSON)
        XCTAssertEqual(loaded.executablePlanSnapshots?.count, 1,
                       "the rejected plan must not enter executable snapshot history")
    }

    func testDurablePlanRejectsInlineStdinBeforeCheckpointPersistence() async throws {
        let secret = "INLINE-DURABLE-SECRET-MUST-NEVER-PERSIST"
        let plan = """
        {"steps":[
          {"id":"E1","intent":"direct bytes","tool":"run_command","arguments":{"executable":"/bin/cat","args":[],"stdin":"\(secret)"}}
        ]}
        """
        let provider = CapturingProvider(id: "planscript", responses: [plan])
        let directory = URL(fileURLWithPath: root)
            .appendingPathComponent(".kist", isDirectory: true)
            .appendingPathComponent("reasoning", isDirectory: true)
        let store = AtomicReasoningControlStore(directory: directory)
        let out = await PlanExecuteLoop(
            providers: ProviderRegistry(providers: [provider], keyStore: PXLNullKeys()),
            providerId: "planscript", model: "c1",
            tools: ToolRegistry([PXLVerificationAuditCommandTool()]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)),
            requireApproval: false, maxReplans: 0, verifyGoal: false,
            reasoningStore: store
        ).run(goal: "run one structured command")

        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("durable PlanExecute requires governed stdin_path"), out.message)
        let checkpointID = try XCTUnwrap(out.checkpointId)
        let loadedOptional = try await store.load(runID: checkpointID)
        let loaded = try XCTUnwrap(loadedOptional)
        XCTAssertTrue(loaded.executablePlanSnapshots?.isEmpty == true)
        let receipt = try XCTUnwrap(loaded.rejectedPlanAttemptReceipts?.first)
        XCTAssertTrue(receipt.stepSummaries.first?.stdinPresent == true)
        XCTAssertEqual(receipt.stepSummaries.first?.stdinByteCount, secret.utf8.count)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        let durableBytes = try files.reduce(into: Data()) {
            $0.append(try Data(contentsOf: $1))
        }
        XCTAssertFalse(String(decoding: durableBytes, as: UTF8.self).contains(secret))
    }

    func testLegacyInlineCheckpointCannotResumeWithoutMissionMigrationToken() async throws {
        let secret = "LEGACY-INLINE-COMMAND-MUST-NOT-EXECUTE"
        try "safe governed bytes\n".write(
            toFile: root + "/valid.ndjson", atomically: true, encoding: .utf8)
        let directory = URL(fileURLWithPath: root)
            .appendingPathComponent(".kist", isDirectory: true)
            .appendingPathComponent("reasoning", isDirectory: true)
        let store = AtomicReasoningControlStore(directory: directory)
        let missionID = try XCTUnwrap(PlanExecuteMissionID(
            rawValue: String(repeating: "a", count: 64)))
        let checkpointID = "plan-mission-" + missionID.rawValue
        let legacyPlan = ExecutablePlan(goal: "resume", steps: [PlanStep(
            id: "E1", intent: "legacy inline", tool: "run_command",
            argumentsJSON:
                "{\"executable\":\"/bin/cat\",\"args\":[],\"stdin\":\"\(secret)\"}")])
        var state = ReasoningControlState(id: checkpointID, route: .planned)
        state.executablePlanSnapshots = [DurableExecutablePlanSnapshot(
            id: "legacy-plan", generation: 0, plan: legacyPlan)]
        state.approvedExecutablePlanIDs = ["legacy-plan"]
        _ = try await store.save(state)

        let replacement = """
        {"steps":[
          {"id":"E2","intent":"governed replacement","tool":"run_command","arguments":{"executable":"/bin/cat","args":[],"cwd":".","stdin_path":"valid.ndjson","allowed_exit_codes":[0]}}
        ]}
        """
        let provider = CapturingProvider(id: "planscript", responses: [replacement])
        let commands = PXLVerificationAuditCommandTool()
        let out = await PlanExecuteLoop(
            providers: ProviderRegistry(providers: [provider], keyStore: PXLNullKeys()),
            providerId: "planscript", model: "c1", tools: ToolRegistry([commands]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)),
            requireApproval: false, maxReplans: 1, verifyGoal: false,
            launchMode: .resume(missionID), reasoningStore: store
        ).run(goal: "run one structured command")

        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("legacy checkpoint has no mission instance ID"), out.message)
        XCTAssertTrue(commands.invocations.isEmpty,
                      "legacy tokenless state must stop before any tool execution")
        XCTAssertTrue(provider.messageCalls.isEmpty,
                      "legacy tokenless state must stop before planner execution")
        let loadedOptional = try await store.load(runID: checkpointID)
        let loaded = try XCTUnwrap(loadedOptional)
        XCTAssertEqual(loaded.executablePlanSnapshots?.count, 1)
        let durableJSON = String(decoding: try JSONEncoder().encode(loaded), as: UTF8.self)
        XCTAssertFalse(durableJSON.contains(secret))
    }

    func testHostOwnedInnerCriticStillRejectsMissingFunctionalFixtureEvidence() async {
        let original = """
        Verify the receipt-ledger without editing files. Run swift build, swift test, valid and invalid fixture inputs, and structured stdin. Require independent final review by a distinct provider:model.
        """
        let functional = PlanExecuteCompletionContract.functionalObjective(from: original)
        let incompletePlan = """
        {"steps":[
          {"id":"E1","intent":"build","tool":"run_command","arguments":{"executable":"swift","args":["build"]}},
          {"id":"E2","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"]},"dependsOn":["E1"]}
        ]}
        """
        let provider = CapturingProvider(id: "planscript", responses: [
            incompletePlan, #"{"done":false,"reason":"valid/invalid fixtures and stdin were not exercised"}"#,
        ])
        let registry = ProviderRegistry(
            providers: [provider], keyStore: PXLNullKeys())
        let out = await PlanExecuteLoop(
            providers: registry, providerId: "planscript", model: nil,
            tools: ToolRegistry([PXLVerificationAuditCommandTool()]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)),
            requireApproval: false, maxReplans: 0, verifyGoal: true,
            completionContract: .derive(canonicalRequest: original),
            hostOwnedFinalReview: true, functionalObjective: functional
        ).run(goal: original)

        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("typed functional evidence plan preflight unmet"), out.message)
        XCTAssertTrue(out.message.contains("valid fixture/file input"), out.message)
        XCTAssertTrue(out.message.contains("invalid fixture/file input"), out.message)
        XCTAssertEqual(provider.messageCalls.count, 1,
                       "typed evidence must fail before a semantic critic can accept prose")
    }

    func testStructuredStdinCannotSatisfyExplicitFixtureObligations() async {
        XCTAssertNoThrow(try "valid\n".write(
            toFile: root + "/valid.ndjson", atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "invalid\n".write(
            toFile: root + "/invalid.ndjson", atomically: true, encoding: .utf8))
        let original = """
        Verify the existing project without editing files. Run swift build and swift test. Exercise valid fixture input with exit 0 and invalid fixture input with allowed exit 1 and a line-numbered error. Also exercise valid stdin with exit 0 and invalid stdin with allowed exit 1.
        """
        let planUsingOnlyStdin = """
        {"steps":[
          {"id":"E1","intent":"build","tool":"run_command","arguments":{"executable":"swift","args":["build"]}},
          {"id":"E2","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"]},"dependsOn":["E1"]},
          {"id":"E3","intent":"valid stdin","tool":"run_command","arguments":{"executable":".build/debug/app","args":[],"stdin_path":"valid.ndjson"},"dependsOn":["E2"]},
          {"id":"E4","intent":"invalid stdin","tool":"run_command","arguments":{"executable":".build/debug/app","args":[],"stdin_path":"invalid.ndjson","allowed_exit_codes":[1]},"dependsOn":["E3"]}
        ]}
        """
        let provider = CapturingProvider(id: "planscript", responses: [planUsingOnlyStdin])
        let commands = PXLVerificationAuditCommandTool()
        let out = await PlanExecuteLoop(
            providers: ProviderRegistry(providers: [provider], keyStore: PXLNullKeys()),
            providerId: "planscript", model: nil,
            tools: ToolRegistry([commands]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)),
            requireApproval: false, maxReplans: 0, verifyGoal: true,
            completionContract: .derive(canonicalRequest: original),
            hostOwnedFinalReview: true,
            functionalObjective: PlanExecuteCompletionContract.functionalObjective(from: original),
            hostContractID: "builder-contract-stdin-regression"
        ).run(goal: original)

        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("valid fixture/file input"), out.message)
        XCTAssertTrue(out.message.contains("invalid fixture/file input"), out.message)
        XCTAssertFalse(out.message.contains("valid stdin with configured"), out.message)
        XCTAssertFalse(out.message.contains("invalid stdin with configured"), out.message)
        XCTAssertNil(out.finalVerificationReceipt,
                     "a failed typed functional gate cannot export a final receipt")
        XCTAssertTrue(commands.invocations.isEmpty,
                      "fixture-as-stdin must be rejected before build or app execution")
        XCTAssertEqual(provider.messageCalls.count, 1,
                       "the deterministic gate must reject before model review")
    }

    func testVerifierRecipeSurvivesFailedPlanAndVerifierlessReplacementPlan() async {
        XCTAssertNoThrow(try "valid\n".write(
            toFile: root + "/valid.ndjson", atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "invalid\n".write(
            toFile: root + "/invalid.ndjson", atomically: true, encoding: .utf8))
        let original = """
        Verify the existing project without editing files. Run swift build and swift test. Exercise valid fixture input with exit 0, invalid fixture input with allowed exit 1 and a line-numbered error, and structured stdin. Require independent final review by a distinct provider:model.
        """
        let planA = """
        {"steps":[
          {"id":"E1","intent":"build","tool":"run_command","arguments":{"executable":"swift","args":["build"]}},
          {"id":"E2","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"]},"dependsOn":["E1"]},
          {"id":"E3","intent":"discover optional index","tool":"read_file","arguments":{"path":"missing-index.txt"},"dependsOn":["E2"]},
          {"id":"E4","intent":"valid fixture","tool":"run_command","arguments":{"executable":".build/debug/app","args":["--input","valid.ndjson"]},"dependsOn":["E3"]},
          {"id":"E5","intent":"invalid fixture","tool":"run_command","arguments":{"executable":".build/debug/app","args":["--input","invalid.ndjson"],"allowed_exit_codes":[1]},"dependsOn":["E4"]},
          {"id":"E6","intent":"stdin","tool":"run_command","arguments":{"executable":".build/debug/app","args":[],"stdin_path":"valid.ndjson"},"dependsOn":["E5"]}
        ]}
        """
        let planCWithoutVerifier = """
        {"steps":[
          {"id":"E1","intent":"valid fixture","tool":"run_command","arguments":{"executable":".build/debug/app","args":["--input","valid.ndjson"]}},
          {"id":"E2","intent":"invalid fixture","tool":"run_command","arguments":{"executable":".build/debug/app","args":["--input","invalid.ndjson"],"allowed_exit_codes":[1]},"dependsOn":["E1"]},
          {"id":"E3","intent":"stdin","tool":"run_command","arguments":{"executable":".build/debug/app","args":[],"stdin_path":"valid.ndjson"},"dependsOn":["E2"]}
        ]}
        """
        let provider = CapturingProvider(id: "planscript", responses: [
            planA,
            #"{"path":"still-missing-index.txt"}"#,
            planCWithoutVerifier,
            #"{"done":true,"reason":"functional probes and retained exact verifier passed"}"#,
        ])
        let commands = PXLVerificationAuditCommandTool()
        let contract = PlanExecuteCompletionContract.derive(canonicalRequest: original)
        let out = await PlanExecuteLoop(
            providers: ProviderRegistry(providers: [provider], keyStore: PXLNullKeys()),
            providerId: "planscript", model: nil,
            tools: ToolRegistry([commands, ReadFileTool()]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)),
            requireApproval: false, maxReplans: 1, verifyGoal: true,
            completionContract: contract, hostOwnedFinalReview: true,
            functionalObjective: PlanExecuteCompletionContract.functionalObjective(from: original),
            hostContractID: "builder-contract-retained-recipe"
        ).run(goal: original)

        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.replansUsed, 1)
        XCTAssertEqual(commands.invocations.filter { $0.hasPrefix("swift test") }.count, 2,
                       "Plan A's exact test must survive and replay after verifier-less Plan C")
        XCTAssertFalse(out.plan?.steps.contains(where: {
            $0.tool == "run_command"
                && $0.argumentsJSON.contains("swift") && $0.argumentsJSON.contains("test")
        }) ?? true, "the successful replacement plan intentionally contains no verifier")
        XCTAssertEqual(out.finalVerificationReceipt?.contractID,
                       "builder-contract-retained-recipe")
        XCTAssertEqual(out.finalVerificationReceipt?.stepID, "E2",
                       "receipt must retain the original verifier step identity")
    }

    func testWorkspaceNameManifestShowsFixturesAndExcludesEphemeralHiddenAndSecrets() throws {
        try FileManager.default.createDirectory(
            atPath: root + "/fixtures", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root + "/.build/debug", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root + "/.kist", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root + "/cache", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root + "/.hidden", withIntermediateDirectories: true)
        try "v1".write(toFile: root + "/fixtures/valid.ndjson", atomically: true, encoding: .utf8)
        try "i1".write(toFile: root + "/fixtures/invalid.ndjson", atomically: true, encoding: .utf8)
        try "binary".write(toFile: root + "/.build/debug/app", atomically: true, encoding: .utf8)
        try "state".write(toFile: root + "/.kist/state.json", atomically: true, encoding: .utf8)
        try "cached".write(toFile: root + "/cache/result", atomically: true, encoding: .utf8)
        try "hidden".write(toFile: root + "/.hidden/file", atomically: true, encoding: .utf8)
        try "SECRET".write(toFile: root + "/credentials.json", atomically: true, encoding: .utf8)

        let first = try PlanExecuteLoop.governedWorkspaceNameManifest(projectRoot: root)
        XCTAssertEqual(first.names, ["fixtures/invalid.ndjson", "fixtures/valid.ndjson"])
        XCTAssertFalse(first.names.contains { $0.contains(".build") || $0.contains(".kist")
            || $0.contains("cache") || $0.contains("hidden") || $0.contains("credential") })

        try "different contents do not belong in this manifest".write(
            toFile: root + "/fixtures/valid.ndjson", atomically: true, encoding: .utf8)
        let contentChanged = try PlanExecuteLoop.governedWorkspaceNameManifest(projectRoot: root)
        XCTAssertEqual(contentChanged, first, "manifest is names-only and content-insensitive")

        try "new".write(toFile: root + "/fixtures/third.ndjson", atomically: true, encoding: .utf8)
        let nameChanged = try PlanExecuteLoop.governedWorkspaceNameManifest(projectRoot: root)
        XCTAssertNotEqual(nameChanged.digest, first.digest)
        XCTAssertTrue(nameChanged.names.contains("fixtures/third.ndjson"))
        XCTAssertThrowsError(try PlanExecuteLoop.governedWorkspaceNameManifest(
            projectRoot: root, maxEntries: 1))
        XCTAssertThrowsError(try PlanExecuteLoop.governedWorkspaceNameManifest(
            projectRoot: root, maxUTF8Bytes: 5))
    }

    func testVerificationOnlyAuditFailsClosedWhenShellIsDisabled() {
        let contract = PlanExecuteCompletionContract.derive(canonicalRequest:
            "Verify this project without editing files.")
        let passedTest = ActionRecord(
            tool: "run_command", argsFingerprint: #"args=["test"]&executable=swift"#,
            success: true,
            effectObservation: CommandClassifier.observe(arguments: [
                "executable": "swift", "args": ["test"],
            ]))
        let verdict = PlanExecuteLoop.completionVerdict(
            verifier: CompletionVerifier(), trajectory: [passedTest], canRunCommands: false,
            contract: contract, missionDigestAvailable: true, workspaceUnchanged: true)

        guard case .needsVerification(let reason) = verdict else {
            return XCTFail("shell-disabled verification-only work must fail closed")
        }
        XCTAssertTrue(reason.contains("shell/build execution is unavailable"), reason)
    }

    func testVerificationOnlyAuditFailsClosedOnRealDigestChangeWithoutReplay() async {
        let plan = """
        {"steps":[
          {"id":"E1","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"],"cwd":"."}},
          {"id":"E2","intent":"exercise app","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--mutate-source"],"cwd":"."},"dependsOn":["E1"]}
        ]}
        """
        let provider = CapturingProvider(id: "planscript", responses: [plan])
        let commands = PXLVerificationAuditCommandTool(mutateOnAppRun: true)
        let registry = ProviderRegistry(providers: [provider], keyStore: PXLNullKeys())
        let contract = PlanExecuteCompletionContract.derive(canonicalRequest:
            "Verify this project without editing files.")
        let digestBefore = PlanExecuteLoop.governedWorkspaceDigest(projectRoot: root)
        let out = await PlanExecuteLoop(
            providers: registry, providerId: "planscript", model: nil,
            tools: ToolRegistry([commands]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)),
            requireApproval: false, maxReplans: 0, verifyGoal: true,
            completionContract: contract
        ).run(goal: "wrapped verification goal")

        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("changed the governed workspace"), out.message)
        XCTAssertEqual(commands.invocations.filter { $0.hasPrefix("swift test") }.count, 1,
                       "a real digest departure must not be laundered by host replay")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/Sources/Unexpected.swift"))
        XCTAssertNotEqual(PlanExecuteLoop.governedWorkspaceDigest(projectRoot: root), digestBefore,
                          "the governed digest must observe the source created by the opaque command")
    }

    func testVerificationOnlyAuditRejectsObservedABAWorkspaceCycle() async {
        let mutate = """
        {"steps":[
          {"id":"E1","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"]}},
          {"id":"E2","intent":"mutate","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--mutate-source"]},"dependsOn":["E1"]}
        ]}
        """
        let restore = """
        {"steps":[
          {"id":"E1","intent":"restore","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--restore-source"]}}
        ]}
        """
        let provider = CapturingProvider(id: "planscript", responses: [mutate, restore])
        let commands = PXLVerificationAuditCommandTool(mutateOnAppRun: true)
        let registry = ProviderRegistry(providers: [provider], keyStore: PXLNullKeys())
        let contract = PlanExecuteCompletionContract.derive(canonicalRequest:
            "Verification-only audit without changing files.")
        let out = await PlanExecuteLoop(
            providers: registry, providerId: "planscript", model: nil,
            tools: ToolRegistry([commands]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)),
            requireApproval: false, maxReplans: 1, verifyGoal: true,
            completionContract: contract
        ).run(goal: "wrapped verification goal")

        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("changed the governed workspace"), out.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/Sources/Unexpected.swift"),
                       "the bytes returned to A, but the observed A-B-A history must remain fail-closed")
    }

    func testDistinctWorkspaceStatesEachReceiveOneDeterministicReplayAcrossReplans() async {
        func mutation(_ file: String) -> String {
            """
            {"steps":[
              {"id":"E1","intent":"write revision","tool":"write_file","arguments":{"path":"\(file)","content":"struct Revision {}"}},
            ]}
            """
        }
        let initialVerification = """
        {"steps":[
          {"id":"E1","intent":"verify revision","tool":"run_command","arguments":{"executable":"swift","args":["test"]}},
          {"id":"E2","intent":"exercise fixture","tool":"run_command","arguments":{"executable":"./receipt-ledger","args":["valid.ndjson"]},"dependsOn":["E1"]}
        ]}
        """
        let provider = CountingProvider(id: "planscript", responses: [
            mutation("GenerationA.swift"),
            initialVerification,
            #"{"done":false,"reason":"second revision required"}"#,
            mutation("GenerationB.swift"),
            #"{"done":true,"reason":"current bound revision accepted"}"#,
        ])
        let commands = PXLGenerationCommandTool()
        let registry = ProviderRegistry(providers: [provider], keyStore: PXLNullKeys())
        let out = await PlanExecuteLoop(
            providers: registry, providerId: "planscript", model: nil,
            tools: ToolRegistry([WriteFileTool(), commands]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)), requireApproval: false,
            maxReplans: 2, verifyGoal: true
        ).run(goal: "verify two receipt-ledger revisions")

        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.replansUsed, 2)
        XCTAssertEqual(commands.verifierCount, 3,
                       "the first state runs planned plus host verification; the next gets one retained host replay")
        XCTAssertEqual(commands.fixtureCount, 1)
        XCTAssertEqual(provider.count, 5,
                       "mutation, revision-bound verification/review, then changed mutation/review")
    }

    func testIdenticalWorkspaceVerificationStateCannotMintReplayByReplanning() async {
        let mutationPlan = """
        {"steps":[
          {"id":"E1","intent":"write revision","tool":"write_file","arguments":{"path":"Generation.swift","content":"struct Revision {}"}}
        ]}
        """
        let verificationPlan = """
        {"steps":[
          {"id":"E1","intent":"verify revision","tool":"run_command","arguments":{"executable":"swift","args":["test"]}},
          {"id":"E2","intent":"exercise fixture","tool":"run_command","arguments":{"executable":"./receipt-ledger","args":["valid.ndjson"]},"dependsOn":["E1"]}
        ]}
        """
        let provider = CountingProvider(id: "planscript", responses: [
            mutationPlan, verificationPlan,
            #"{"done":false,"reason":"repeat it"}"#, verificationPlan,
        ])
        let commands = PXLGenerationCommandTool()
        let registry = ProviderRegistry(providers: [provider], keyStore: PXLNullKeys())
        let out = await PlanExecuteLoop(
            providers: registry, providerId: "planscript", model: nil,
            tools: ToolRegistry([WriteFileTool(), commands]),
            context: ToolContext(projectRoot: root,
                                 shell: ShellPolicy(enabled: true, autoApprove: true)), requireApproval: false,
            maxReplans: 2, verifyGoal: true
        ).run(goal: "verify one unchanged receipt-ledger revision")

        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("already attempted"), out.message)
        XCTAssertEqual(commands.verifierCount, 3,
                       "the repeated plan runs its own check but cannot mint a second host replay")
        XCTAssertEqual(commands.fixtureCount, 2)
        XCTAssertEqual(provider.count, 4, "the unchanged second state fails before another critic call")
    }

    func testReplanBudgetExhaustedReturnsFailure() async {
        // Both attempts fail at runtime (each followed by an abstaining "{}" R3 step-repair);
        // maxReplans=1 → one replan, then give up.
        let failA = #"{"steps":[{"id":"E1","intent":"read","tool":"read_file","arguments":{"path":"nope1.txt"}}]}"#
        let failB = #"{"steps":[{"id":"E1","intent":"read","tool":"read_file","arguments":{"path":"nope2.txt"}}]}"#
        let out = await loop([failA, "{}", failB, "{}"], maxReplans: 1).run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertEqual(out.replansUsed, 1)
        XCTAssertTrue(out.message.contains("plan failed"), out.message)
    }

    func testVerifyDisabledSkipsGate() async {
        // verifyGoal:false → a mechanically-successful plan is done immediately (no verify call).
        let out = await loop([writePlan(id: "E1", path: "v.txt", content: "x")], verifyGoal: false).run(goal: "x")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.replansUsed, 0)
    }

    func testVerifyGoalNotMetWithoutBudgetReturnsHonestFailure() async {
        // Plan succeeds but verify says not done, and there's no replan budget → honest partial fail.
        let plan = writePlan(id: "E1", path: "p.txt", content: "x")
        let notDone = #"{"done":false,"reason":"missing the summary"}"#
        let out = await loop([plan, notDone], maxReplans: 0, verifyGoal: true).run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("goal not fully met"), out.message)
        XCTAssertTrue(out.message.contains("missing the summary"))
    }

    func testUnparseableVerifyFailsClosed() async {
        let plan = writePlan(id: "E1", path: "p.txt", content: "x")
        let out = await loop([plan, "I am unsure how to evaluate this."], maxReplans: 0, verifyGoal: true).run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("verification unavailable"), out.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/p.txt"))
    }

    func testParseVerdict() {
        XCTAssertEqual(PlanExecuteLoop.parseVerdict(#"{"done":true,"reason":"ok"}"#)?.done, true)
        XCTAssertEqual(PlanExecuteLoop.parseVerdict(#"{"done":false,"reason":"more"}"#)?.reason, "more")
        XCTAssertEqual(PlanExecuteLoop.parseVerdict("Verdict: NOT_DONE — needs tests")?.done, false)  // NOT_DONE not tricked by substring DONE
        XCTAssertEqual(PlanExecuteLoop.parseVerdict("All good. DONE.")?.done, true)
        XCTAssertNil(PlanExecuteLoop.parseVerdict("I am unsure how to evaluate this."))   // → caller fails closed
    }

    // MARK: - Phase 2: cross-vendor role binding (planner vs critic)

    func testCriticUsesADifferentVendorThanPlanner() async {
        // planner→"plannerco" (emits the plan), critic→"criticco" (emits the verdict). If role
        // binding works, the verify call hits criticco, NOT a 2nd planner call. Proven by call counts.
        let planner = CountingProvider(id: "plannerco", responses: [writePlan(id: "E1", path: "team.txt", content: "x")])
        let critic  = CountingProvider(id: "criticco",  responses: [#"{"done":true,"reason":"looks complete"}"#])
        let registry = ProviderRegistry(providers: [planner, critic], keyStore: PXLNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"),
                                 [.critic: ProviderBinding(providerId: "criticco")])
        let loop = PlanExecuteLoop(providers: registry, roles: roles, tools: .headless(),
                                   context: ToolContext(projectRoot: root), requireApproval: false, verifyGoal: true)
        let out = await loop.run(goal: "make team.txt")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(planner.count, 1, "planner should be called once (the plan)")
        XCTAssertEqual(critic.count, 1, "critic should be called once (the verify) — proves it's a separate vendor")
    }

    func testCriticVendorCanVetoAndForceReplan() async {
        // A separate critic vendor returns NOT_DONE → the planner vendor replans.
        let planner = CountingProvider(id: "plannerco", responses: [
            writePlan(id: "E1", path: "a.txt", content: "1"),
            writePlan(id: "E1", path: "b.txt", content: "2"),
        ])
        let critic = CountingProvider(id: "criticco", responses: [
            #"{"done":false,"reason":"need b.txt too"}"#,
            #"{"done":true,"reason":"ok now"}"#,
        ])
        let registry = ProviderRegistry(providers: [planner, critic], keyStore: PXLNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"),
                                 [.critic: ProviderBinding(providerId: "criticco")])
        let out = await PlanExecuteLoop(providers: registry, roles: roles, tools: .headless(),
                                        context: ToolContext(projectRoot: root), requireApproval: false, verifyGoal: true).run(goal: "x")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.replansUsed, 1)            // the critic's veto forced one replan
        XCTAssertEqual(planner.count, 2)              // initial plan + replan
        XCTAssertEqual(critic.count, 2)               // verified twice
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/b.txt"))
    }

    func testCoderVendorGeneratesContentThatFlowsIntoAWrite() async {
        // The full team: planner plans a generate→write DAG, the CODER vendor produces the content,
        // ${E1} flows it into write_file. Proves the coder is a real third teammate.
        let plan = """
        {"steps":[
          {"id":"E1","intent":"draft","tool":"generate","arguments":{"prompt":"write a greeting"}},
          {"id":"E2","intent":"save","tool":"write_file","arguments":{"path":"greeting.txt","content":"${E1}"},"dependsOn":["E1"]}
        ]}
        """
        let planner = CountingProvider(id: "plannerco", responses: [plan])
        let coder   = CountingProvider(id: "coderco",   responses: ["Hello from the coder vendor!"])
        let registry = ProviderRegistry(providers: [planner, coder], keyStore: PXLNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"),
                                 [.coder: ProviderBinding(providerId: "coderco")])
        let out = await PlanExecuteLoop(providers: registry, roles: roles, tools: .headless(),
                                        context: ToolContext(projectRoot: root), requireApproval: false,
                                        verifyGoal: false).run(goal: "make a greeting file")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(coder.count, 1, "the generate step must run on the CODER vendor")
        XCTAssertEqual(try? String(contentsOfFile: root + "/greeting.txt", encoding: .utf8),
                       "Hello from the coder vendor!")   // coder output flowed via ${E1} into the file
    }

    // MARK: - Phase 3: observability + cost governance

    func testZeroBudgetHaltsBeforeAnyWork() async {
        let registry = ProviderRegistry(providers: [PlanScriptedProvider([validPlan])], keyStore: PXLNullKeys())
        let loop = PlanExecuteLoop(providers: registry, providerId: "planscript", model: nil,
                                   tools: .headless(), context: ToolContext(projectRoot: root),
                                   requireApproval: false, budget: BudgetLedger(maxTokens: 0))
        let out = await loop.run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("budget exceeded"), out.message)
        XCTAssertNil(out.plan)   // halted before producing a plan
    }

    func testBudgetCeilingHaltsReplanLoop() async {
        // A plan that fails at runtime triggers a replan; a tiny budget (exceeded after the first
        // planner call's estimate) makes the next iteration halt with an honest budget failure.
        let failPlan = #"{"steps":[{"id":"E1","intent":"read","tool":"read_file","arguments":{"path":"missing.txt"}}]}"#
        let registry = ProviderRegistry(providers: [PlanScriptedProvider([failPlan, failPlan])], keyStore: PXLNullKeys())
        let loop = PlanExecuteLoop(providers: registry, providerId: "planscript", model: nil,
                                   tools: .headless(), context: ToolContext(projectRoot: root),
                                   requireApproval: false, verifyGoal: false, budget: BudgetLedger(maxTokens: 5))
        let out = await loop.run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("budget exceeded"), out.message)
    }

    func testTraceRecordsSpansPerRoleAndVendor() async {
        let planner = CountingProvider(id: "plannerco", responses: [writePlan(id: "E1", path: "t.txt", content: "x")])
        let critic  = CountingProvider(id: "criticco",  responses: [#"{"done":true,"reason":"ok"}"#])
        let registry = ProviderRegistry(providers: [planner, critic], keyStore: PXLNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"),
                                 [.critic: ProviderBinding(providerId: "criticco")])
        let recorder = TraceRecorder(traceId: "t1")
        let out = await PlanExecuteLoop(providers: registry, roles: roles, tools: .headless(),
                                        context: ToolContext(projectRoot: root), requireApproval: false,
                                        verifyGoal: true, recorder: recorder).run(goal: "make t.txt")
        XCTAssertTrue(out.success, out.message)
        let byRole = await recorder.tokensByRole()
        let byVendor = await recorder.tokensByVendor()
        XCTAssertNotNil(byRole["planner"])               // planner span recorded
        XCTAssertNotNil(byRole["critic"])                // critic span recorded (verify gate)
        XCTAssertNotNil(byVendor["plannerco"])           // attributed to the planner vendor
        XCTAssertNotNil(byVendor["criticco"])            // attributed to the critic vendor
    }

    // MARK: - Phase 4: cross-run memory

    func testRunRecordsEpisodeOnCompletion() async {
        let mem = ProjectMemory(root: root)
        let registry = ProviderRegistry(providers: [PlanScriptedProvider([validPlan])], keyStore: PXLNullKeys())
        let loop = PlanExecuteLoop(providers: registry, providerId: "planscript", model: nil,
                                   tools: .headless(), context: ToolContext(projectRoot: root),
                                   requireApproval: false, verifyGoal: false, memory: mem)
        let out = await loop.run(goal: "write a.txt then read it")
        XCTAssertTrue(out.success, out.message)
        let episodes = mem.recentEpisodes()
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.goal, "write a.txt then read it")
        XCTAssertEqual(episodes.first?.success, true)
    }

    func testMemoryContextInjectedIntoPlanner() async throws {
        try "Build: swift build".write(toFile: root + "/AGENTS.md", atomically: true, encoding: .utf8)
        let mem = ProjectMemory(root: root)
        mem.recordEpisode(Episode(goal: "earlier task", success: false, summary: "it failed",
                                  at: Date().addingTimeInterval(-1)))
        let capt = CapturingProvider(id: "capt", responses: [validPlan])
        let registry = ProviderRegistry(providers: [capt], keyStore: PXLNullKeys())
        let loop = PlanExecuteLoop(providers: registry, providerId: "capt", model: nil,
                                   tools: .headless(), context: ToolContext(projectRoot: root),
                                   requireApproval: false, verifyGoal: false, memory: mem)
        _ = await loop.run(goal: "do the thing")
        // The planner saw the project facts AND the prior episode as advisory context.
        let injected = capt.lastMessages.contains { $0.content.contains("PROJECT MEMORY") && $0.content.contains("swift build") }
        let sawEpisode = capt.lastMessages.contains { $0.content.contains("[failed] earlier task") }
        XCTAssertTrue(injected, "memory facts must be injected into the planner context")
        XCTAssertTrue(sawEpisode, "recent episodes must be injected")
    }

    func testNoMemoryMeansNoInjectionOrRecord() async {
        // Without a ProjectMemory, behavior is unchanged: no .mythos dir created.
        let out = await loop([validPlan]).run(goal: "x")
        XCTAssertTrue(out.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.mythos"))
    }

    func testReplanPromptsCarryContext() {
        let exec = PlanExecution(success: false,
                                 stepResults: [StepResult(stepId: "E1", tool: "read_file", success: false, output: "no such file", error: "no such file")],
                                 outputs: ["E1": "no such file"], failedStepId: "E1")
        let f = PlanExecuteLoop.replanFromFailure(goal: "do it", exec: exec)
        XCTAssertTrue(f.contains("FAILED at step E1"))
        XCTAssertTrue(f.contains("do it"))
        let v = PlanExecuteLoop.replanFromVerify(goal: "do it", reason: "missing x")
        XCTAssertTrue(v.contains("NOT yet fully met"))
        XCTAssertTrue(v.contains("missing x"))
    }

    func testReplanFromValidationFailureCarriesUsefulReason() {
        let exec = PlanExecution(success: false, stepResults: [], outputs: [:], failedStepId: nil)
        let f = PlanExecuteLoop.replanFromFailure(goal: "do it", exec: exec)
        XCTAssertTrue(f.contains("FAILED at step validation"))
        XCTAssertTrue(f.contains("plan validation failed before any executable step"))
        XCTAssertTrue(f.contains("do it"))
    }
}

// MARK: - Test doubles (local to avoid cross-file private collisions)

private struct PXLNullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private struct PXLDeclining: RuntimeInteractor {
    func requestApproval(planSummary: String) async -> Bool { false }
    func requestInput(question: String) async -> String { "" }
}

/// Thread-safe event recorder — lets tests pin TERMINAL events (the sink contract), not just outcomes.
private final class PXLRecordingSink: RuntimeEventSink, @unchecked Sendable {
    private let lock = NSLock(); private var _events: [RuntimeEvent] = []
    func emit(_ event: RuntimeEvent) { lock.lock(); _events.append(event); lock.unlock() }
    func saw(_ predicate: (RuntimeEvent) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }; return _events.contains(where: predicate)
    }
    var planReadySummaries: [String] {
        lock.lock(); defer { lock.unlock() }
        return _events.compactMap { if case .planReady(let s, _) = $0 { return s }; return nil }
    }
}

private func runMissionScopedVerificationAudit(
    root: String,
    store: AtomicReasoningControlStore,
    launchMode: PlanExecuteLaunchMode = .fresh,
    maxReplans: Int = 0
) async -> (outcome: PlanOutcome, swiftTestInvocations: Int,
            providerCalls: Int, commandInvocations: Int) {
    let objective = """
    Verify the existing project without editing files. Run swift build and swift test. Exercise a
    valid fixture with exit 0, an invalid fixture with allowed exit 1 and line-numbered errors, and
    nonempty structured stdin with exit 0.
    """
    let plan = """
    {"steps":[
      {"id":"E1","intent":"build","tool":"run_command","arguments":{"executable":"swift","args":["build"],"cwd":".","allowed_exit_codes":[0]}},
      {"id":"E2","intent":"test","tool":"run_command","arguments":{"executable":"swift","args":["test"],"cwd":".","allowed_exit_codes":[0]},"dependsOn":["E1"]},
      {"id":"E3","intent":"valid fixture","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--input","valid.ndjson"],"cwd":".","allowed_exit_codes":[0]},"dependsOn":["E2"]},
      {"id":"E4","intent":"invalid fixture","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":["--input","invalid.ndjson"],"cwd":".","allowed_exit_codes":[1]},"dependsOn":["E3"]},
      {"id":"E5","intent":"structured stdin","tool":"run_command","arguments":{"executable":".build/debug/receipt-ledger","args":[],"cwd":".","stdin_path":"valid.ndjson","allowed_exit_codes":[0]},"dependsOn":["E4"]}
    ]}
    """
    let provider = CapturingProvider(id: "mission-script", responses: [
        plan, #"{"done":true,"reason":"mission-bound deterministic evidence passed"}"#,
    ])
    let commands = PXLVerificationAuditCommandTool()
    let outcome = await PlanExecuteLoop(
        providers: ProviderRegistry(providers: [provider], keyStore: PXLNullKeys()),
        providerId: "mission-script", model: "c1", tools: ToolRegistry([commands]),
        context: ToolContext(projectRoot: root,
                             shell: ShellPolicy(enabled: true, autoApprove: true)),
        requireApproval: false, maxReplans: maxReplans, verifyGoal: true,
        launchMode: launchMode,
        completionContract: .derive(canonicalRequest: objective),
        hostOwnedFinalReview: true, functionalObjective: objective,
        hostContractID: "mission-isolation-contract", reasoningStore: store
    ).run(goal: objective)
    let invocations = commands.invocations
    return (outcome, invocations.filter { $0.hasPrefix("swift test") }.count,
            provider.messageCalls.count, invocations.count)
}

private final class PlanScriptedProvider: ChatProvider {
    let id = "planscript", name = "PlanScript", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "planscript", defaultModel = "p1"
    let availableModels = [AIModel(id: "p1")]
    private let responses: PXLResponses
    init(_ responses: [String]) { self.responses = PXLResponses(responses) }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let r = await responses.next()
        return AsyncThrowingStream { c in c.yield(.delta(r)); c.finish() }
    }
}

private actor PXLResponses {
    private let responses: [String]; private var idx = 0
    init(_ responses: [String]) { self.responses = responses }
    func next() -> String { defer { idx += 1 }; return idx < responses.count ? responses[idx] : "still not a plan" }
}

private struct ReplanPartialFailureRunCommandTool: AgentTool {
    let name = "run_command"
    let description = "writes source before failing, for replan evidence tests"
    let parameters = [
        ToolParameter(name: "executable", type: "string", description: "program", required: true),
        ToolParameter(name: "args", type: "array", description: "argv", required: false),
    ]

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        if arguments["executable"] as? String == "touch",
           arguments["args"] as? [String] == ["Sources/ReplanLeak.swift"] {
            try FileManager.default.createDirectory(atPath: context.projectRoot + "/Sources",
                                                    withIntermediateDirectories: true)
            try "broken".write(toFile: context.projectRoot + "/Sources/ReplanLeak.swift",
                               atomically: true, encoding: .utf8)
            return .failure("failed after partial source write")
        }
        return .failure("repair did not reconcile partial write")
    }
}

private struct PXLFailingWriteTool: AgentTool {
    let name = "write_file"
    let description = "fails a write after invocation for WAL receipt coverage"
    let parameters = [
        ToolParameter(name: "path", type: "string", description: "path", required: true),
        ToolParameter(name: "content", type: "string", description: "content", required: true),
    ]

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        .failure("simulated write failure")
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private final class PXLCountingVerifierTool: AgentTool, @unchecked Sendable {
    let name = "run_command"
    let description = "deterministic verifier probe"
    let parameters: [ToolParameter] = []
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        lock.lock(); calls += 1; lock.unlock()
        let metadata = [
            "exit_code": "0", "stdout": "8 tests passed", "stderr": "",
            "allowed_exit_codes": "0", "exit_code_allowed": "true",
            "verification_eligible": "true",
        ]
        return makePlanTestTrustedCommandResult(
            arguments: arguments, output: "8 tests passed", metadata: metadata)
    }
}

private final class PXLGenerationCommandTool: AgentTool, @unchecked Sendable {
    let name = "run_command"
    let description = "counts structured verifier and fixture commands"
    let parameters = [
        ToolParameter(name: "executable", type: "string", description: "program", required: true),
        ToolParameter(name: "args", type: "array", description: "argv", required: false),
    ]
    private let lock = NSLock()
    private var verifierCalls = 0
    private var fixtureCalls = 0
    var verifierCount: Int { lock.lock(); defer { lock.unlock() }; return verifierCalls }
    var fixtureCount: Int { lock.lock(); defer { lock.unlock() }; return fixtureCalls }

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        lock.lock()
        if arguments["executable"] as? String == "swift" { verifierCalls += 1 }
        else { fixtureCalls += 1 }
        lock.unlock()
        let verifier = arguments["executable"] as? String == "swift"
        let metadata = [
            "exit_code": "0", "stdout": "ok", "stderr": "",
            "allowed_exit_codes": "0", "exit_code_allowed": "true",
            "verification_eligible": String(verifier),
        ]
        return makePlanTestTrustedCommandResult(
            arguments: arguments, output: "ok", metadata: metadata)
    }
}

private final class PXLVerificationAuditCommandTool: AgentTool, @unchecked Sendable {
    let name = "run_command"
    let description = "live-shaped structured verification command probe"
    let parameters = [
        ToolParameter(name: "executable", type: "string", description: "program", required: true),
        ToolParameter(name: "args", type: "array", description: "argv", required: false),
        ToolParameter(name: "cwd", type: "string", description: "working directory", required: false),
        ToolParameter(name: "stdin", type: "string", description: "standard input", required: false),
        ToolParameter(name: "stdin_path", type: "string",
                      description: "governed standard input path", required: false),
        ToolParameter(name: "allowed_exit_codes", type: "array", description: "accepted statuses", required: false),
    ]
    private let lock = NSLock()
    private var calls: [String] = []
    private let mutateOnAppRun: Bool
    private let includeLineNumberEvidence: Bool
    private let omitExpectedDomainExitMetadata: Bool
    var invocations: [String] { lock.lock(); defer { lock.unlock() }; return calls }

    init(mutateOnAppRun: Bool = false, includeLineNumberEvidence: Bool = true,
         omitExpectedDomainExitMetadata: Bool = false) {
        self.mutateOnAppRun = mutateOnAppRun
        self.includeLineNumberEvidence = includeLineNumberEvidence
        self.omitExpectedDomainExitMetadata = omitExpectedDomainExitMetadata
    }

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let executable = arguments["executable"] as? String ?? ""
        let args = (arguments["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        let rendered = ([executable] + args).joined(separator: " ")
        lock.lock(); calls.append(rendered); lock.unlock()

        if mutateOnAppRun, args.contains("--mutate-source") {
            try FileManager.default.createDirectory(atPath: context.projectRoot + "/Sources",
                                                    withIntermediateDirectories: true)
            try "struct Unexpected {}\n".write(
                toFile: context.projectRoot + "/Sources/Unexpected.swift",
                atomically: true, encoding: .utf8)
        }
        if args.contains("--restore-source") {
            try? FileManager.default.removeItem(atPath: context.projectRoot + "/Sources/Unexpected.swift")
        }
        let allowed = arguments["allowed_exit_codes"] as? [Int] ?? [0]
        let exitCode = allowed == [1] ? 1 : 0
        let output = exitCode == 1
            ? (includeLineNumberEvidence ? "line 1: invalid amount" : "invalid amount")
            : "ok"
        var metadata = [
            "exit_code": String(exitCode),
            "stdout": output,
            "stderr": "",
            "allowed_exit_codes": allowed.map(String.init).joined(separator: ","),
            "exit_code_allowed": "true",
            "verification_eligible": String(executable == "swift" && exitCode == 0),
            "timed_out": "false",
            "was_signalled": "false",
            "semantic_status": exitCode == 0 ? "clean_exit" : "expected_domain_status",
        ]
        if omitExpectedDomainExitMetadata && exitCode == 1 {
            metadata.removeValue(forKey: "exit_code")
        }
        if let path = arguments["stdin_path"] as? String {
            let cwd = (arguments["cwd"] as? String) ?? "."
            let base = URL(fileURLWithPath: context.projectRoot).appendingPathComponent(cwd)
            let data = try Data(contentsOf: base.appendingPathComponent(path))
            let canonicalRoot = try XCTUnwrap(ToolContext.canonicalize(context.projectRoot))
            let canonicalCWD = try XCTUnwrap(ToolContext.canonicalize(base.path))
            let relative = try RunCommandTool.normalizedGovernedStdinPath(
                path, cwd: canonicalCWD, projectRoot: canonicalRoot)
            metadata["stdin_source_kind"] = PlanStandardInputSourceKind.governedPath.rawValue
            metadata["stdin_relative_path"] = relative
            metadata["stdin_byte_count"] = String(data.count)
            metadata["stdin_sha256"] = RunCommandTool.sha256(data)
        }
        return makePlanTestTrustedCommandResult(
            arguments: arguments, output: output, metadata: metadata, exitCode: exitCode)
    }
}

/// Scripted provider that records how many times it was streamed — lets a test PROVE which vendor
/// served a given call (planner vs critic).
private final class CountingProvider: ChatProvider, @unchecked Sendable {
    let id: String, name = "Counting", iconName = "cpu"
    let requiresAPIKey = false, keyAccount: String, defaultModel = "c1"
    let availableModels = [AIModel(id: "c1")]
    private let lock = NSLock(); private let responses: [String]; private var idx = 0
    init(id: String, responses: [String]) { self.id = id; self.keyAccount = id; self.responses = responses }
    var count: Int { lock.lock(); defer { lock.unlock() }; return idx }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock(); let r = idx < responses.count ? responses[idx] : "still not a plan"; idx += 1; lock.unlock()
        return AsyncThrowingStream { c in c.yield(.delta(r)); c.finish() }
    }
}

/// Records the messages it was last streamed — lets a test assert what context the planner saw.
private final class CapturingProvider: ChatProvider, @unchecked Sendable {
    let id: String, name = "Capt", iconName = "cpu"
    let requiresAPIKey = false, keyAccount: String, defaultModel = "c1"
    let availableModels = [AIModel(id: "c1")]
    private let lock = NSLock(); private let responses: [String]; private var idx = 0
    private var _last: [ChatMessage] = []
    private var _messageCalls: [[ChatMessage]] = []
    var lastMessages: [ChatMessage] { lock.lock(); defer { lock.unlock() }; return _last }
    var messageCalls: [[ChatMessage]] { lock.lock(); defer { lock.unlock() }; return _messageCalls }
    init(id: String, responses: [String]) { self.id = id; self.keyAccount = id; self.responses = responses }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock(); _last = messages; _messageCalls.append(messages); let r = idx < responses.count ? responses[idx] : "still not a plan"; idx += 1; lock.unlock()
        return AsyncThrowingStream { c in c.yield(.delta(r)); c.finish() }
    }
}

private struct PXLFailingProvider: ChatProvider {
    let id = "pxlfail", name = "Fail", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "pxlfail", defaultModel = "x"
    let availableModels = [AIModel(id: "x")]
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        throw AIProviderError.transport("boom")
    }
}
