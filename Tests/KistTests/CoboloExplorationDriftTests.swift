import Foundation
import XCTest
import AgentCore
@testable import Kist

final class CoboloExplorationDriftTests: XCTestCase {
    private let target = "src/drift.cbl"
    private let copybook = "copybooks/rates.cpy"
    private let expectedOutput = "EXPECTED"
    private let goal = "Build exploration-bound COBOL"

    func testJournalOneAheadConsumesLostAttemptWithoutRepeatingItsModelWork() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloExplorationDriftRuntime(
            expectedOutput: expectedOutput,
            rejectFirstCritic: false,
            stopFirstRevisionOneCoder: false
        )
        let memory = CoboloMemoryAttemptJournal()
        let crashJournal = CoboloCrashAfterAdvanceJournal(base: memory)

        let interrupted = await run(
            root: root, runtime: runtime, attemptJournal: crashJournal)

        XCTAssertNotEqual(interrupted, 0)
        XCTAssertEqual(try persistedState(root: root).attemptsStarted, 0)
        let beforeResume = runtime.snapshot()
        XCTAssertEqual(beforeResume.generationCount, 0)
        XCTAssertEqual(beforeResume.plans.filter {
            $0.role == "driver" && $0.revision == 0
        }.count, 1)

        let resumed = await run(
            root: root, runtime: runtime, attemptJournal: crashJournal)

        XCTAssertEqual(resumed, 0)
        let afterResume = runtime.snapshot()
        XCTAssertEqual(afterResume.plans.filter {
            $0.role == "driver" && $0.revision == 0
        }.count, 1, "journal-ahead recovery must not repeat the consumed revision")
        XCTAssertEqual(afterResume.plans.filter {
            $0.role == "driver" && $0.revision == 1
        }.count, 1)
        XCTAssertEqual(afterResume.generationCount, 1)
        XCTAssertEqual(try persistedState(root: root).attemptsStarted, 2)
    }

    func testMissingJournalForExistingRunFailsBeforeFreshModelWork() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloExplorationDriftRuntime(
            expectedOutput: expectedOutput,
            rejectFirstCritic: false,
            stopFirstRevisionOneCoder: false
        )
        let memory = CoboloMemoryAttemptJournal()
        let crashJournal = CoboloCrashAfterAdvanceJournal(base: memory)
        let interrupted = await run(
            root: root, runtime: runtime, attemptJournal: crashJournal)
        XCTAssertNotEqual(interrupted, 0)
        let beforeResume = runtime.snapshot()
        memory.removeAllForTesting()

        let resumed = await run(
            root: root, runtime: runtime, attemptJournal: memory)

        XCTAssertNotEqual(resumed, 0)
        XCTAssertEqual(runtime.snapshot(), beforeResume)
    }

    func testCopybookDriftReplansSamePendingRevisionWithoutResettingAttempts() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloExplorationDriftRuntime(
            expectedOutput: expectedOutput,
            rejectFirstCritic: true,
            stopFirstRevisionOneCoder: true
        )

        let interrupted = await run(root: root, runtime: runtime)

        XCTAssertNotEqual(interrupted, 0)
        XCTAssertEqual(try persistedState(root: root).attemptsStarted, 1)
        XCTAssertEqual(runtime.snapshot().generationCount, 1)
        XCTAssertEqual(
            runtime.snapshot().plans.filter { $0.role == "driver" && $0.revision == 1 }.count,
            1
        )

        try Data("       78 OVERTIME-RATE VALUE 2.00.\n".utf8)
            .write(to: URL(fileURLWithPath: root).appendingPathComponent(copybook), options: .atomic)
        let resumed = await run(root: root, runtime: runtime)

        XCTAssertEqual(resumed, 0)
        let snapshot = runtime.snapshot()
        let revisionOneDrivers = snapshot.plans.filter {
            $0.role == "driver" && $0.revision == 1
        }
        XCTAssertEqual(revisionOneDrivers.count, 2,
                       "copybook drift must retire the saved revision-1 plan")
        XCTAssertEqual(Set(revisionOneDrivers.map(\.explorationDigest)).count, 2,
                       "fresh planning must bind the changed exploration")
        XCTAssertEqual(snapshot.plans.filter { $0.role == "driver" && $0.revision == 0 }.count, 1,
                       "resume must not reset planning to revision 0")
        XCTAssertEqual(snapshot.generationCount, 2)
        XCTAssertEqual(try persistedState(root: root).attemptsStarted, 2,
                       "the consumed attempt must remain counted across exploration drift")
    }

    func testMarkdownDriftReusesSavedSameRevisionPlan() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloExplorationDriftRuntime(
            expectedOutput: expectedOutput,
            rejectFirstCritic: true,
            stopFirstRevisionOneCoder: true
        )

        let interrupted = await run(root: root, runtime: runtime)

        XCTAssertNotEqual(interrupted, 0)
        XCTAssertEqual(try persistedState(root: root).attemptsStarted, 1)
        let savedDriver = try XCTUnwrap(runtime.snapshot().plans.first {
            $0.role == "driver" && $0.revision == 1
        })

        try Data("documentation-only change\n".utf8)
            .write(to: URL(fileURLWithPath: root).appendingPathComponent("README.md"), options: .atomic)
        let resumed = await run(root: root, runtime: runtime)

        XCTAssertEqual(resumed, 0)
        let snapshot = runtime.snapshot()
        let revisionOneDrivers = snapshot.plans.filter {
            $0.role == "driver" && $0.revision == 1
        }
        XCTAssertEqual(revisionOneDrivers, [savedDriver],
                       "non-governed markdown must not invalidate the saved plan")
        XCTAssertEqual(snapshot.plans.filter { $0.role == "coder" && $0.revision == 1 }.count, 2,
                       "only the interrupted coder plan should be retried")
        XCTAssertEqual(snapshot.generationCount, 2)
        XCTAssertEqual(try persistedState(root: root).attemptsStarted, 2)
    }

    func testCompletedCopybookDriftFailsBeforeAnyFreshModelCall() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloExplorationDriftRuntime(
            expectedOutput: expectedOutput,
            rejectFirstCritic: false,
            stopFirstRevisionOneCoder: false
        )

        let initial = await run(root: root, runtime: runtime)
        XCTAssertEqual(initial, 0)
        XCTAssertEqual(try persistedState(root: root).stage, .completed)

        let cleanReplay = await run(root: root, runtime: runtime)
        XCTAssertEqual(cleanReplay, 0,
                       "the loop's own promoted target must not be mistaken for external drift")
        let beforeDriftResume = runtime.snapshot()
        let acceptedTarget = try String(
            contentsOf: URL(fileURLWithPath: root).appendingPathComponent(target),
            encoding: .utf8
        )

        try Data("       78 OVERTIME-RATE VALUE 3.00.\n".utf8)
            .write(to: URL(fileURLWithPath: root).appendingPathComponent(copybook), options: .atomic)
        let driftedReplay = await run(root: root, runtime: runtime)

        XCTAssertNotEqual(driftedReplay, 0)
        XCTAssertEqual(runtime.snapshot(), beforeDriftResume,
                       "completed exploration drift must fail before planner, critic, or promotion calls")
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(target),
                       encoding: .utf8),
            acceptedTarget
        )
    }

    private func run(
        root: String, runtime: CoboloExplorationDriftRuntime,
        attemptJournal: (any CoboloAttemptJournal)? = nil
    ) async -> Int32 {
        let plan = identityPlan()
        let dependencies = CoboloDependencies(
            environment: [:],
            identityPlan: plan,
            executeTool: { name, arguments, context, logicalStage in
                runtime.executeTool(
                    name: name,
                    arguments: arguments,
                    context: context,
                    logicalStage: logicalStage
                )
            },
            complete: { invocation in
                try runtime.complete(invocation)
            },
            attemptJournal: attemptJournal
        )
        let roles = RoleBindings(default: plan.driver)
            .binding(.worker, to: plan.driver)
            .binding(.coder, to: plan.coder)
            .binding(.critic, to: plan.critic)
        let context = ToolContext(
            projectRoot: root,
            shell: ShellPolicy(enabled: true, autoApprove: true, sandboxed: true),
            sandbox: .confined(denyNetwork: true, confineWrites: true)
        )
        return await KistRunner.runCobolo(
            options(), goal: goal, registry: ProviderRegistry(), root: root,
            tools: .headless(), context: context, roles: roles,
            providerId: plan.driver.providerId, model: plan.driver.model,
            budget: BudgetLedger(maxTokens: 500_000),
            executionContract: coboloExecutionContractFixture(
                root: root, options: options(), identityPlan: plan),
            dependencies: dependencies
        )
    }

    private func options() -> KistOptions {
        var opts = KistOptions.parse([
            "--cobolo", "--cobol-target", target,
            "--cobol-expect", expectedOutput,
            goal
        ])
        opts.cobolMaxRevisions = 2
        return opts
    }

    private func identityPlan() -> CoboloIdentityPlan {
        CoboloIdentityPlan(
            driver: ProviderBinding(providerId: "deepseek", model: "driver-v1"),
            coder: ProviderBinding(providerId: "mimo", model: "coder-v1"),
            cobol: ProviderBinding(providerId: "cobol", model: "cobol-jeeves-ft:latest"),
            critic: ProviderBinding(providerId: "gemini", model: "critic-v1"),
            promotion: ProviderBinding(providerId: "openai", model: "promotion-v1")
        )
    }

    private func makeRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-cobolo-exploration-drift-\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("copybooks", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("ORIGINAL\n".utf8).write(to: root.appendingPathComponent(target))
        try Data("       78 OVERTIME-RATE VALUE 1.50.\n".utf8)
            .write(to: root.appendingPathComponent(copybook))
        try Data("initial docs\n".utf8).write(to: root.appendingPathComponent("README.md"))
        return root.path
    }

    private func persistedState(root: String) throws -> CoboloRunState {
        let runs = URL(fileURLWithPath: root).appendingPathComponent(".kist/cobolo-runs")
        let runIDs = try FileManager.default.contentsOfDirectory(
            at: runs, includingPropertiesForKeys: nil
        ).filter { $0.hasDirectoryPath }
        guard runIDs.count == 1 else {
            throw CoboloExplorationDriftFixtureError.invalidState(
                "expected one durable run, found \(runIDs.count)"
            )
        }
        return try CoboloRunStore.decoder.decode(
            CoboloRunState.self,
            from: Data(contentsOf: runIDs[0].appendingPathComponent("state.json"))
        )
    }
}

private final class CoboloCrashAfterAdvanceJournal: CoboloAttemptJournal, @unchecked Sendable {
    private let base: CoboloMemoryAttemptJournal
    private let lock = NSLock()
    private var shouldCrash = true

    init(base: CoboloMemoryAttemptJournal) {
        self.base = base
    }

    func load(binding: CoboloAttemptJournalBinding) throws -> CoboloAttemptAnchor? {
        try base.load(binding: binding)
    }

    func create(binding: CoboloAttemptJournalBinding) throws -> CoboloAttemptAnchor {
        try base.create(binding: binding)
    }

    func advance(binding: CoboloAttemptJournalBinding, expectedHighWater: Int,
                 revision: Int, planDigest: String) throws -> CoboloAttemptAnchor {
        let advanced = try base.advance(
            binding: binding, expectedHighWater: expectedHighWater,
            revision: revision, planDigest: planDigest)
        let crash = lock.withLock { () -> Bool in
            guard shouldCrash else { return false }
            shouldCrash = false
            return true
        }
        if crash { throw CoboloExplorationDriftFixtureError.stopAfterJournalAdvance }
        return advanced
    }
}

private struct CoboloExplorationPlanCall: Equatable, Sendable {
    let role: String
    let revision: Int
    let explorationDigest: String
}

private struct CoboloExplorationDriftSnapshot: Equatable, Sendable {
    let plans: [CoboloExplorationPlanCall]
    let generationCount: Int
    let semanticCount: Int
    let promotionCount: Int
}

private enum CoboloExplorationDriftFixtureError: Error {
    case stopAfterRevisionOneDriver
    case stopAfterJournalAdvance
    case invalidInvocation(String)
    case invalidState(String)
}

private final class CoboloExplorationDriftRuntime: @unchecked Sendable {
    private let expectedOutput: String
    private let rejectFirstCritic: Bool
    private let stopFirstRevisionOneCoder: Bool
    private let lock = NSLock()
    private var plans: [CoboloExplorationPlanCall] = []
    private var generationCount = 0
    private var semanticCount = 0
    private var promotionCount = 0
    private var stoppedRevisionOneCoder = false

    init(expectedOutput: String, rejectFirstCritic: Bool,
         stopFirstRevisionOneCoder: Bool) {
        self.expectedOutput = expectedOutput
        self.rejectFirstCritic = rejectFirstCritic
        self.stopFirstRevisionOneCoder = stopFirstRevisionOneCoder
    }

    func snapshot() -> CoboloExplorationDriftSnapshot {
        lock.withLock {
            CoboloExplorationDriftSnapshot(
                plans: plans,
                generationCount: generationCount,
                semanticCount: semanticCount,
                promotionCount: promotionCount
            )
        }
    }

    func executeTool(name: String, arguments: [String: Any], context: ToolContext,
                     logicalStage: String) -> CoboloToolOutcome {
        if name == "cobol_generate" {
            let generation = lock.withLock { () -> Int in
                generationCount += 1
                return generationCount
            }
            let source = """
                   IDENTIFICATION DIVISION.
                   PROGRAM-ID. GENERATED-\(generation).
                   PROCEDURE DIVISION.
                       DISPLAY "\(expectedOutput)".
                       STOP RUN.
            """ + "\n"
            return CoboloToolOutcome(
                success: true,
                output: source,
                metadata: [
                    "provider": "cobol",
                    "model": "cobol-jeeves-ft:latest",
                    "offline": "true",
                    "endpoint": "http://127.0.0.1:11434",
                    "source_sha256": BuilderEvidenceDigest.sha256(source),
                    "compiled": "false",
                    "ran": "false",
                    "expect_met": "false"
                ]
            )
        }

        guard name == "run_command" else {
            return CoboloToolOutcome(success: false, error: "unexpected tool \(name)")
        }
        let stage = logicalStage.lowercased()
        if stage.contains("preflight") {
            return commandOutcome(stdout: "GnuCOBOL 3.2.0\n")
        }
        if stage.contains("compile") {
            guard materializeBinary(arguments: arguments, context: context) else {
                return commandOutcome(success: false, exitCode: 1,
                                      stderr: "fixture could not materialize binary")
            }
            return commandOutcome(stdout: "")
        }
        if stage.contains("run") || stage.contains("replay") {
            return commandOutcome(stdout: expectedOutput + "\n")
        }
        return CoboloToolOutcome(success: false, error: "unexpected logical stage \(logicalStage)")
    }

    func complete(_ invocation: CoboloModelInvocation) throws -> CoboloModelCompletion {
        switch invocation.stage {
        case .driverPlan, .coderPlan:
            guard let revision = invocation.revision,
                  let explorationDigest = invocation.explorationDigest else {
                throw CoboloExplorationDriftFixtureError.invalidInvocation(
                    "plan invocation lacked revision or exploration"
                )
            }
            let role = invocation.stage == .driverPlan ? "driver" : "coder"
            let shouldStop = lock.withLock { () -> Bool in
                plans.append(CoboloExplorationPlanCall(
                    role: role,
                    revision: revision,
                    explorationDigest: explorationDigest
                ))
                if role == "coder", revision == 1, stopFirstRevisionOneCoder,
                   !stoppedRevisionOneCoder {
                    stoppedRevisionOneCoder = true
                    return true
                }
                return false
            }
            if shouldStop {
                throw CoboloExplorationDriftFixtureError.stopAfterRevisionOneDriver
            }
            return completion(for: invocation.binding, text: try json([
                "contract_id": invocation.contractID,
                "exploration_digest": explorationDigest,
                "revision": revision,
                "planner_identity": identity(invocation.binding),
                "upstream_plan_digest": invocation.upstreamPlanDigest.map { $0 as Any } ?? NSNull(),
                "feedback_digest": invocation.feedbackDigest.map { $0 as Any } ?? NSNull(),
                "steps": ["Generate complete bounded COBOL source", "Compile and run in the sandbox"],
                "acceptance_checks": ["exit code is zero", "stdout contains \(expectedOutput)"]
            ]))

        case .semanticCritic:
            let reject = lock.withLock { () -> Bool in
                semanticCount += 1
                return rejectFirstCritic && semanticCount == 1
            }
            return completion(for: invocation.binding, text: try json([
                "contract_id": invocation.contractID,
                "candidate_sha256": invocation.candidateSHA256.map { $0 as Any } ?? NSNull(),
                "compile_evidence_digest": invocation.compileEvidenceDigest.map { $0 as Any } ?? NSNull(),
                "run_evidence_digest": invocation.runEvidenceDigest.map { $0 as Any } ?? NSNull(),
                "decision": reject ? "REJECT" : "APPROVE",
                "reason": reject ? "exercise revision planning" : "candidate satisfies bound evidence"
            ]))

        case .promotion:
            lock.withLock { promotionCount += 1 }
            return completion(for: invocation.binding, text: try json([
                "contract_id": invocation.contractID,
                "candidate_sha256": invocation.candidateSHA256.map { $0 as Any } ?? NSNull(),
                "semantic_receipt_digest": invocation.semanticReceiptDigest.map { $0 as Any } ?? NSNull(),
                "verification_digest": invocation.verificationDigest.map { $0 as Any } ?? NSNull(),
                "decision": "APPROVE",
                "reason": "independent promotion review accepts the bound candidate"
            ]))
        }
    }

    private func completion(for binding: ProviderBinding, text: String) -> CoboloModelCompletion {
        CoboloModelCompletion(providerId: binding.providerId, model: binding.model ?? "", text: text)
    }

    private func identity(_ binding: ProviderBinding) -> String {
        "\(binding.providerId.lowercased()):\((binding.model ?? "unknown").lowercased())"
    }

    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw CoboloExplorationDriftFixtureError.invalidInvocation("JSON was not UTF-8")
        }
        return value
    }

    private func materializeBinary(arguments: [String: Any], context: ToolContext) -> Bool {
        guard let values = arguments["args"] as? [String],
              let outputFlag = values.firstIndex(of: "-o"),
              values.indices.contains(outputFlag + 1) else {
            return false
        }
        let url = URL(fileURLWithPath: context.projectRoot)
            .appendingPathComponent(values[outputFlag + 1])
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture-binary".utf8).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func commandOutcome(success: Bool = true, exitCode: Int32 = 0,
                                stdout: String = "", stderr: String = "") -> CoboloToolOutcome {
        let eligible = success && exitCode == 0
        return CoboloToolOutcome(
            success: success,
            output: stdout,
            error: success ? nil : stderr,
            metadata: [
                "exit_code": String(exitCode),
                "sandboxed": "true",
                "timed_out": "false",
                "was_signalled": "false",
                "stdout_truncated": "false",
                "stderr_truncated": "false",
                "output_truncated": "false",
                "verification_eligible": eligible ? "true" : "false",
                "stdout": stdout,
                "stderr": stderr,
                "exit_code_allowed": eligible ? "true" : "false",
                "allowed_exit_codes": "0",
                "semantic_status": eligible ? "success" : "failure"
            ]
        )
    }
}
