import Foundation
import XCTest
@testable import AgentCore
@testable import Kist

final class CoboloInterruptedRollbackReconciliationTests: XCTestCase {
    private let target = "src/recovered.cbl"
    private let expectedOutput = "COBOLO-RECOVERY-OK"

    func testResumeReconcilesStalePromotedStateAfterExistingTargetWasRestored() async throws {
        let root = try makeRoot(existingTarget: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloInterruptedRollbackRuntime(expectedOutput: expectedOutput)

        let initial = await run(root: root, runtime: runtime)
        XCTAssertNotEqual(initial, 0)
        XCTAssertEqual(try targetContents(root: root), "ORIGINAL\n")
        try forgeLostPromotedCheckpoint(root: root)

        let beforeResume = runtime.snapshot()
        let resumed = await run(root: root, runtime: runtime)
        let afterResume = runtime.snapshot()

        XCTAssertEqual(resumed, 0)
        XCTAssertTrue(try targetContents(root: root).contains("GENERATED"))
        XCTAssertEqual(afterResume.generationCount, beforeResume.generationCount,
                       "resume must reuse the durable candidate rather than spend another attempt")
        XCTAssertEqual(afterResume.semanticCount, beforeResume.semanticCount + 1,
                       "reconciliation must force a fresh semantic review")
        XCTAssertEqual(afterResume.promotionCount, beforeResume.promotionCount + 1,
                       "reconciliation must force a fresh independent promotion review")
        let state = try persistedState(root: root)
        XCTAssertEqual(state.stage, .completed)
        XCTAssertNotNil(state.acceptance)
    }

    func testResumeReconcilesStalePromotedStateAfterMissingTargetWasRemoved() async throws {
        let root = try makeRoot(existingTarget: false)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloInterruptedRollbackRuntime(expectedOutput: expectedOutput)

        let initial = await run(root: root, runtime: runtime)
        XCTAssertNotEqual(initial, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetPath(root: root)))
        try forgeLostPromotedCheckpoint(root: root)

        let beforeResume = runtime.snapshot()
        let resumed = await run(root: root, runtime: runtime)
        let afterResume = runtime.snapshot()

        XCTAssertEqual(resumed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetPath(root: root)))
        XCTAssertTrue(try targetContents(root: root).contains("GENERATED"))
        XCTAssertEqual(afterResume.generationCount, beforeResume.generationCount)
        XCTAssertEqual(afterResume.semanticCount, beforeResume.semanticCount + 1)
        XCTAssertEqual(afterResume.promotionCount, beforeResume.promotionCount + 1)
        XCTAssertEqual(try persistedState(root: root).stage, .completed)
    }

    func testResumeRejectsStalePromotedStateWhenTargetMatchesNeitherCandidateNorBaseline() async throws {
        let root = try makeRoot(existingTarget: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloInterruptedRollbackRuntime(expectedOutput: expectedOutput)

        let initial = await run(root: root, runtime: runtime)
        XCTAssertNotEqual(initial, 0)
        try forgeLostPromotedCheckpoint(root: root)
        try Data("UNRELATED-WRITER\n".utf8).write(
            to: URL(fileURLWithPath: targetPath(root: root)), options: .atomic)
        let beforeResume = runtime.snapshot()

        let resumed = await run(root: root, runtime: runtime)
        let afterResume = runtime.snapshot()

        XCTAssertNotEqual(resumed, 0)
        XCTAssertEqual(try targetContents(root: root), "UNRELATED-WRITER\n")
        XCTAssertEqual(afterResume.generationCount, beforeResume.generationCount)
        XCTAssertEqual(afterResume.semanticCount, beforeResume.semanticCount,
                       "unknown target drift must fail before model review")
        XCTAssertEqual(afterResume.promotionCount, beforeResume.promotionCount,
                       "unknown target drift must fail before promotion review")
    }

    private func run(root: String, runtime: CoboloInterruptedRollbackRuntime) async -> Int32 {
        let plan = identityPlan()
        let dependencies = CoboloDependencies(
            environment: [:],
            identityPlan: plan,
            executeTool: { name, arguments, context, stage in
                runtime.executeTool(name: name, arguments: arguments,
                                    context: context, logicalStage: stage)
            },
            complete: { invocation in try runtime.complete(invocation) }
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
            options(), goal: "Recover an interrupted COBOL publication",
            registry: ProviderRegistry(), root: root, tools: .headless(), context: context,
            roles: roles, providerId: plan.driver.providerId, model: plan.driver.model,
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
            "Recover an interrupted COBOL publication"
        ])
        opts.cobolMaxRevisions = 1
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

    private func makeRoot(existingTarget: Bool) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-cobolo-interrupted-rollback-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        if existingTarget {
            try Data("ORIGINAL\n".utf8).write(to: root.appendingPathComponent(target))
        }
        return root.path
    }

    private func targetPath(root: String) -> String {
        (root as NSString).appendingPathComponent(target)
    }

    private func targetContents(root: String) throws -> String {
        try String(contentsOfFile: targetPath(root: root), encoding: .utf8)
    }

    private func statePath(root: String) throws -> String {
        let runs = (root as NSString).appendingPathComponent(".kist/cobolo-runs")
        let runIDs = try FileManager.default.contentsOfDirectory(atPath: runs)
        guard runIDs.count == 1 else {
            throw CoboloInterruptedRollbackFixtureError.invalidState(
                "expected one run directory, found \(runIDs.count)")
        }
        return (runs as NSString).appendingPathComponent("\(runIDs[0])/state.json")
    }

    private func persistedState(root: String) throws -> CoboloRunState {
        try CoboloRunStore.decoder.decode(
            CoboloRunState.self,
            from: Data(contentsOf: URL(fileURLWithPath: try statePath(root: root)))
        )
    }

    private func forgeLostPromotedCheckpoint(root: String) throws {
        var state = try persistedState(root: root)
        guard let candidate = state.candidateSHA256 else {
            throw CoboloInterruptedRollbackFixtureError.invalidState(
                "rolled-back fixture lacks a candidate digest")
        }
        state.stage = .promoted
        state.promotedSHA256 = candidate
        state.rollback = nil
        state.lastError = "simulated crash after physical rollback and before rollback state save"
        state.updatedAt = Date()
        try CoboloRunStore.encoder.encode(state).write(
            to: URL(fileURLWithPath: try statePath(root: root)), options: .atomic)
    }
}

private enum CoboloInterruptedRollbackFixtureError: Error {
    case invalidState(String)
}

private final class CoboloInterruptedRollbackRuntime: @unchecked Sendable {
    struct Snapshot {
        let generationCount: Int
        let semanticCount: Int
        let promotionCount: Int
    }

    private let lock = NSLock()
    private let expectedOutput: String
    private var generationCount = 0
    private var semanticCount = 0
    private var promotionCount = 0
    private var consumedPostPromotionFailure = false

    init(expectedOutput: String) {
        self.expectedOutput = expectedOutput
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(generationCount: generationCount,
                        semanticCount: semanticCount,
                        promotionCount: promotionCount)
    }

    func executeTool(name: String, arguments: [String: Any], context: ToolContext,
                     logicalStage: String) -> CoboloToolOutcome {
        if name == "cobol_generate" {
            let generation = increment(\.generationCount)
            let source = Self.source(generation: generation, expectedOutput: expectedOutput)
            return CoboloToolOutcome(success: true, output: source, metadata: [
                "provider": "cobol",
                "model": "cobol-jeeves-ft:latest",
                "offline": "true",
                "endpoint": "http://127.0.0.1:11434",
                "source_sha256": BuilderEvidenceDigest.sha256(source),
                "compiled": "false",
                "ran": "false",
                "expect_met": "false"
            ])
        }

        guard name == "run_command" else {
            return CoboloToolOutcome(success: false, error: "unexpected tool \(name)")
        }
        let stage = logicalStage.lowercased()
        if stage.contains("preflight") {
            return commandOutcome(stdout: "/opt/homebrew/bin/cobc\n")
        }
        if stage.contains("compile") {
            materializeFakeExecutable(arguments: arguments, context: context)
            return commandOutcome(stdout: "")
        }
        if stage.contains("run") || stage.contains("replay") {
            if stage.contains("post-promotion") && consumePostPromotionFailure() {
                return commandOutcome(success: false, exitCode: 1, stdout: "",
                                      stderr: "simulated post-promotion replay failure")
            }
            return commandOutcome(stdout: expectedOutput + "\n")
        }
        return CoboloToolOutcome(success: false,
                                 error: "unexpected logical stage \(logicalStage)")
    }

    func complete(_ invocation: CoboloModelInvocation) throws -> CoboloModelCompletion {
        switch invocation.stage {
        case .driverPlan, .coderPlan:
            return completion(for: invocation.binding, text: json([
                "contract_id": invocation.contractID,
                "exploration_digest": invocation.explorationDigest.map { $0 as Any } ?? NSNull(),
                "revision": invocation.revision.map { $0 as Any } ?? NSNull(),
                "planner_identity": identity(invocation.binding),
                "upstream_plan_digest": invocation.upstreamPlanDigest.map { $0 as Any } ?? NSNull(),
                "feedback_digest": invocation.feedbackDigest.map { $0 as Any } ?? NSNull(),
                "steps": ["Generate complete COBOL source", "Compile and execute in the sandbox"],
                "acceptance_checks": ["exit code is zero", "stdout contains \(expectedOutput)"]
            ]))

        case .semanticCritic:
            increment(\.semanticCount)
            return completion(for: invocation.binding, text: json([
                "contract_id": invocation.contractID,
                "candidate_sha256": invocation.candidateSHA256.map { $0 as Any } ?? NSNull(),
                "compile_evidence_digest": invocation.compileEvidenceDigest.map { $0 as Any } ?? NSNull(),
                "run_evidence_digest": invocation.runEvidenceDigest.map { $0 as Any } ?? NSNull(),
                "decision": "APPROVE",
                "reason": "bound candidate and execution evidence are coherent"
            ]))

        case .promotion:
            increment(\.promotionCount)
            return completion(for: invocation.binding, text: json([
                "contract_id": invocation.contractID,
                "candidate_sha256": invocation.candidateSHA256.map { $0 as Any } ?? NSNull(),
                "semantic_receipt_digest": invocation.semanticReceiptDigest.map { $0 as Any } ?? NSNull(),
                "verification_digest": invocation.verificationDigest.map { $0 as Any } ?? NSNull(),
                "decision": "APPROVE",
                "reason": "fresh independent review approves conditional publication"
            ]))
        }
    }

    private func consumePostPromotionFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumedPostPromotionFailure else { return false }
        consumedPostPromotionFailure = true
        return true
    }

    @discardableResult
    private func increment(
        _ keyPath: ReferenceWritableKeyPath<CoboloInterruptedRollbackRuntime, Int>
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        self[keyPath: keyPath] += 1
        return self[keyPath: keyPath]
    }

    private func commandOutcome(success: Bool = true, exitCode: Int = 0,
                                stdout: String, stderr: String = "") -> CoboloToolOutcome {
        let eligible = success && exitCode == 0
        return CoboloToolOutcome(success: success, output: stdout,
                                 error: success ? nil : stderr, metadata: [
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
        ])
    }

    private func materializeFakeExecutable(arguments: [String: Any], context: ToolContext) {
        guard let argv = arguments["args"] as? [String],
              let outputFlag = argv.firstIndex(of: "-o"), outputFlag + 1 < argv.count else {
            return
        }
        let supplied = argv[outputFlag + 1]
        let path = supplied.hasPrefix("/")
            ? supplied
            : (context.projectRoot as NSString).appendingPathComponent(supplied)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path,
                                       contents: Data("fake executable".utf8))
    }

    private func completion(for binding: ProviderBinding,
                            text: String) -> CoboloModelCompletion {
        CoboloModelCompletion(providerId: binding.providerId,
                              model: binding.model ?? "", text: text)
    }

    private func identity(_ binding: ProviderBinding) -> String {
        "\(binding.providerId):\(binding.model ?? "")"
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func source(generation: Int, expectedOutput: String) -> String {
        """
               IDENTIFICATION DIVISION.
               PROGRAM-ID. GENERATED\(generation).
               PROCEDURE DIVISION.
                   DISPLAY '\(expectedOutput)'.
                   STOP RUN.
        """ + "\n"
    }
}
