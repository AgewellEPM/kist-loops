import XCTest
import AgentCore
@testable import Kist

final class CoboloRevisionBehaviorTests: XCTestCase {
    private let target = "src/revision.cbl"
    private let expectedOutput = "EXPECTED"

    func testCriticRejectionProducesAcceptedBoundedRevision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let harness = CoboloFakeRuntime(mode: .rejectFirstCritic, expectedOutput: expectedOutput)

        let status = await run(root: root, maxRevisions: 3, harness: harness)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(harness.snapshot().generationCount, 2)
        XCTAssertEqual(harness.snapshot().criticCount, 2)
        XCTAssertTrue(try targetContents(root: root).contains("REVISION2"))
        XCTAssertEqual(try persistedRevisionCount(root: root), 1)
    }

    func testCompileFailureProducesAcceptedBoundedRevision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let harness = CoboloFakeRuntime(mode: .failFirstCompile, expectedOutput: expectedOutput)

        let status = await run(root: root, maxRevisions: 3, harness: harness)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(harness.snapshot().generationCount, 2)
        XCTAssertGreaterThanOrEqual(harness.snapshot().compileCount, 2)
        XCTAssertTrue(try targetContents(root: root).contains("REVISION2"))
        XCTAssertEqual(try persistedRevisionCount(root: root), 1)
    }

    func testRevisionExhaustionPreservesTarget() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let original = try targetContents(root: root)
        let harness = CoboloFakeRuntime(mode: .alwaysRejectCritic, expectedOutput: expectedOutput)

        let status = await run(root: root, maxRevisions: 2, harness: harness)

        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(harness.snapshot().generationCount, 3, "initial attempt plus exactly two revisions")
        XCTAssertEqual(harness.snapshot().criticCount, 3)
        XCTAssertEqual(try targetContents(root: root), original)
        XCTAssertEqual(try persistedRevisionCount(root: root), 2)
    }

    func testResumeDoesNotResetExhaustedRevisionCap() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let original = try targetContents(root: root)
        let harness = CoboloFakeRuntime(mode: .alwaysRejectCritic, expectedOutput: expectedOutput)

        let firstStatus = await run(root: root, maxRevisions: 1, harness: harness)
        let exhausted = harness.snapshot()
        let resumedStatus = await run(root: root, maxRevisions: 1, harness: harness)

        XCTAssertNotEqual(firstStatus, 0)
        XCTAssertNotEqual(resumedStatus, 0)
        XCTAssertEqual(exhausted.generationCount, 2)
        XCTAssertEqual(harness.snapshot(), exhausted, "resume must not regenerate or re-review past the durable cap")
        XCTAssertEqual(try targetContents(root: root), original)
        XCTAssertEqual(try persistedRevisionCount(root: root), 1)
    }

    func testResumeRejectsChangedRevisionCapAndIdentityPlan() async throws {
        try await assertContractDriftRejected { opts, plan in
            var changed = opts
            changed.cobolMaxRevisions = opts.cobolMaxRevisions - 1
            return (changed, plan)
        }
        try await assertContractDriftRejected { opts, plan in
            let changedPlan = CoboloIdentityPlan(
                driver: plan.driver,
                coder: plan.coder,
                cobol: plan.cobol,
                critic: plan.critic,
                promotion: ProviderBinding(providerId: "anthropic", model: "promotion-v2")
            )
            return (opts, changedPlan)
        }
    }

    private func assertContractDriftRejected(
        mutate: (KistOptions, CoboloIdentityPlan) -> (KistOptions, CoboloIdentityPlan)
    ) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let harness = CoboloFakeRuntime(mode: .approve, expectedOutput: expectedOutput)
        let plan = identityPlan()
        let opts = options(maxRevisions: 3)
        let stopBeforePromotion: () throws -> Void = { throw CoboloFixtureError.stopBeforePromotion }

        let interrupted = await run(
            root: root, opts: opts, plan: plan, harness: harness,
            beforePromotion: stopBeforePromotion
        )
        XCTAssertNotEqual(interrupted, 0)
        let beforeResume = harness.snapshot()

        let (changedOptions, changedPlan) = mutate(opts, plan)
        let resumed = await run(root: root, opts: changedOptions, plan: changedPlan, harness: harness)

        XCTAssertNotEqual(resumed, 0)
        XCTAssertEqual(harness.snapshot(), beforeResume,
                       "contract drift must fail before any resumed tool or model work")
        XCTAssertEqual(try targetContents(root: root), "ORIGINAL\n")
    }

    private func run(
        root: String,
        maxRevisions: Int,
        harness: CoboloFakeRuntime
    ) async -> Int32 {
        await run(root: root, opts: options(maxRevisions: maxRevisions),
                  plan: identityPlan(), harness: harness)
    }

    private func run(
        root: String,
        opts: KistOptions,
        plan: CoboloIdentityPlan,
        harness: CoboloFakeRuntime,
        beforePromotion: (() throws -> Void)? = nil
    ) async -> Int32 {
        let dependencies = CoboloDependencies(
            environment: [:],
            identityPlan: plan,
            executeTool: { name, arguments, context, logicalStage in
                harness.executeTool(name: name, arguments: arguments,
                                    context: context, logicalStage: logicalStage)
            },
            complete: { invocation in
                try harness.complete(invocation)
            },
            beforePromotion: beforePromotion
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
            opts, goal: "Build a deterministic revision program", registry: ProviderRegistry(),
            root: root, tools: .headless(), context: context, roles: roles,
            providerId: plan.driver.providerId, model: plan.driver.model,
            budget: BudgetLedger(maxTokens: 500_000),
            executionContract: coboloExecutionContractFixture(
                root: root, options: opts, identityPlan: plan),
            dependencies: dependencies
        )
    }

    private func options(maxRevisions: Int) -> KistOptions {
        var opts = KistOptions.parse([
            "--cobolo", "--cobol-target", target,
            "--cobol-expect", expectedOutput,
            "Build a deterministic revision program"
        ])
        opts.cobolMaxRevisions = maxRevisions
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
            .appendingPathComponent("kist-cobolo-revision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("ORIGINAL\n".utf8).write(to: root.appendingPathComponent(target))
        return root.path
    }

    private func targetContents(root: String) throws -> String {
        try String(contentsOfFile: (root as NSString).appendingPathComponent(target), encoding: .utf8)
    }

    private func persistedRevisionCount(root: String) throws -> Int {
        let runs = (root as NSString).appendingPathComponent(".kist/cobolo-runs")
        let runIDs = try FileManager.default.contentsOfDirectory(atPath: runs)
        guard runIDs.count == 1 else {
            throw CoboloFixtureError.invalidState("expected one durable run, found \(runIDs.count)")
        }
        let statePath = (runs as NSString).appendingPathComponent("\(runIDs[0])/state.json")
        let state = try CoboloRunStore.decoder.decode(
            CoboloRunState.self, from: Data(contentsOf: URL(fileURLWithPath: statePath)))
        return max(0, state.attemptsStarted - 1)
    }
}

private enum CoboloFixtureError: Error {
    case stopBeforePromotion
    case invalidState(String)
}

private final class CoboloFakeRuntime: @unchecked Sendable {
    enum Mode: Sendable {
        case approve
        case rejectFirstCritic
        case failFirstCompile
        case alwaysRejectCritic
    }

    struct Snapshot: Equatable {
        let generationCount: Int
        let compileCount: Int
        let criticCount: Int
        let modelCount: Int
    }

    private let lock = NSLock()
    private let mode: Mode
    private let expectedOutput: String
    private var generationCount = 0
    private var compileCount = 0
    private var criticCount = 0
    private var modelCount = 0

    init(mode: Mode, expectedOutput: String) {
        self.mode = mode
        self.expectedOutput = expectedOutput
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(generationCount: generationCount, compileCount: compileCount,
                        criticCount: criticCount, modelCount: modelCount)
    }

    func executeTool(name: String, arguments: [String: Any], context: ToolContext,
                     logicalStage: String) -> CoboloToolOutcome {
        if name == "cobol_generate" {
            let number = lockedIncrement(\.generationCount)
            let source = Self.source(revision: number, expectedOutput: expectedOutput)
            return CoboloToolOutcome(
                success: true,
                output: source,
                error: nil,
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
            return CoboloToolOutcome(success: false, output: "", error: "unexpected tool \(name)", metadata: [:])
        }
        let stage = logicalStage.lowercased()
        if stage.contains("preflight") {
            return commandOutcome(stdout: "/opt/homebrew/bin/cobc\n")
        }
        if stage.contains("compile") {
            let attempt = lockedIncrement(\.compileCount)
            if mode == .failFirstCompile && attempt == 1 {
                return commandOutcome(success: false, exitCode: 1, stdout: "", stderr: "compile failed")
            }
            materializeFakeExecutable(arguments: arguments, context: context)
            return commandOutcome(stdout: "")
        }
        if stage.contains("run") || stage.contains("replay") {
            return commandOutcome(stdout: expectedOutput + "\n")
        }
        return CoboloToolOutcome(
            success: false, output: "", error: "unexpected logical stage \(logicalStage)", metadata: [:]
        )
    }

    func complete(_ invocation: CoboloModelInvocation) throws -> CoboloModelCompletion {
        _ = lockedIncrement(\.modelCount)
        switch invocation.stage {
        case .driverPlan, .coderPlan:
            let response = json([
                "contract_id": invocation.contractID,
                "exploration_digest": invocation.explorationDigest.map { $0 as Any } ?? NSNull(),
                "revision": invocation.revision.map { $0 as Any } ?? NSNull(),
                "planner_identity": identity(invocation.binding),
                "upstream_plan_digest": invocation.upstreamPlanDigest.map { $0 as Any } ?? NSNull(),
                "feedback_digest": invocation.feedbackDigest.map { $0 as Any } ?? NSNull(),
                "steps": ["Generate the complete bounded COBOL source", "Compile and run it in the sandbox"],
                "acceptance_checks": ["exit code is zero", "stdout contains \(expectedOutput)"]
            ])
            return completion(for: invocation.binding, text: response)

        case .semanticCritic:
            let reviewNumber = lockedIncrement(\.criticCount)
            let rejects = mode == .alwaysRejectCritic || (mode == .rejectFirstCritic && reviewNumber == 1)
            let response = json([
                "contract_id": invocation.contractID,
                "candidate_sha256": invocation.candidateSHA256.map { $0 as Any } ?? NSNull(),
                "compile_evidence_digest": invocation.compileEvidenceDigest.map { $0 as Any } ?? NSNull(),
                "run_evidence_digest": invocation.runEvidenceDigest.map { $0 as Any } ?? NSNull(),
                "decision": rejects ? "REJECT" : "APPROVE",
                "reason": rejects ? "Revise the candidate before promotion" : "Candidate satisfies the bound evidence"
            ])
            return completion(for: invocation.binding, text: response)

        case .promotion:
            let response = json([
                "contract_id": invocation.contractID,
                "candidate_sha256": invocation.candidateSHA256.map { $0 as Any } ?? NSNull(),
                "semantic_receipt_digest": invocation.semanticReceiptDigest.map { $0 as Any } ?? NSNull(),
                "verification_digest": invocation.verificationDigest.map { $0 as Any } ?? NSNull(),
                "decision": "APPROVE",
                "reason": "Independent promotion review accepts the bound candidate"
            ])
            return completion(for: invocation.binding, text: response)
        }
    }

    private func completion(for binding: ProviderBinding, text: String) -> CoboloModelCompletion {
        CoboloModelCompletion(providerId: binding.providerId, model: binding.model ?? "", text: text)
    }

    private func commandOutcome(success: Bool = true, exitCode: Int = 0,
                                stdout: String, stderr: String = "") -> CoboloToolOutcome {
        let eligible = success && exitCode == 0
        let metadata = [
            "sandboxed": "true",
            "timed_out": "false",
            "was_signalled": "false",
            "stdout_truncated": "false",
            "stderr_truncated": "false",
            "output_truncated": "false",
            "verification_eligible": eligible ? "true" : "false",
            "exit_code": String(exitCode),
            "exit_code_allowed": eligible ? "true" : "false",
            "allowed_exit_codes": "0",
            "semantic_status": eligible ? "success" : "failure",
            "stdout": stdout,
            "stderr": stderr
        ]
        return CoboloToolOutcome(success: success, output: stdout, error: success ? nil : stderr,
                                 metadata: metadata)
    }

    private func materializeFakeExecutable(arguments: [String: Any], context: ToolContext) {
        guard let argv = arguments["args"] as? [String],
              let outputFlag = argv.firstIndex(of: "-o"), outputFlag + 1 < argv.count else { return }
        let supplied = argv[outputFlag + 1]
        let path = supplied.hasPrefix("/")
            ? supplied
            : (context.projectRoot as NSString).appendingPathComponent(supplied)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: Data("fake executable".utf8))
    }

    private func lockedIncrement(_ keyPath: ReferenceWritableKeyPath<CoboloFakeRuntime, Int>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        self[keyPath: keyPath] += 1
        return self[keyPath: keyPath]
    }

    private func identity(_ binding: ProviderBinding) -> String {
        "\(binding.providerId):\(binding.model ?? "")"
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func source(revision: Int, expectedOutput: String) -> String {
        """
               IDENTIFICATION DIVISION.
               PROGRAM-ID. REVISION\(revision).
               PROCEDURE DIVISION.
                   DISPLAY '\(expectedOutput)'.
                   STOP RUN.
        """ + "\n"
    }
}
