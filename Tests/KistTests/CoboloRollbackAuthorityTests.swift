import Foundation
import XCTest
@testable import AgentCore
@testable import Kist

final class CoboloRollbackAuthorityTests: XCTestCase {
    private let target = "src/authority.cbl"
    private let expectedOutput = "COBOLO-AUTHORITY-OK"
    private let goal = "Build rollback-authoritative COBOL"

    func testPostFinalVerificationRollbackClearsTargetEvidenceAndRemainsResumable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloRollbackAuthorityRuntime(
            expectedOutput: expectedOutput, target: target,
            initialAction: .driftDuringPostPromotionRun)

        let failed = await run(root: root, runtime: runtime)
        XCTAssertNotEqual(failed, 0)
        XCTAssertNil(runtime.snapshot().fixtureError)
        XCTAssertEqual(try targetContents(root: root), "ORIGINAL\n")
        let rolledBack = try persistedState(root: root)
        XCTAssertNil(rolledBack.acceptance)
        XCTAssertFalse(rolledBack.verifications.contains { $0.sourcePath == target },
                       "rollback must not persist verification receipts for bytes it removed")

        let receipt = try receiptPath(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt),
                       "rolled-back acceptance must not leave a receipt")
        let resumed = await run(root: root, runtime: runtime)

        XCTAssertEqual(resumed, 0)
        XCTAssertEqual(runtime.snapshot().secondGenerationTarget, "ORIGINAL\n")
        XCTAssertTrue(try targetContents(root: root).contains("GENERATED"))
        XCTAssertEqual(try persistedState(root: root).stage, .completed)
    }

    func testInterruptedRollbackReconciliationRevokesStaleAcceptanceReceipt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloRollbackAuthorityRuntime(
            expectedOutput: expectedOutput, target: target)

        let initial = await run(root: root, runtime: runtime)
        XCTAssertEqual(initial, 0)
        let receipt = try receiptPath(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt))
        try Data("ORIGINAL\n".utf8).write(
            to: URL(fileURLWithPath: targetPath(root: root)), options: .atomic)
        runtime.failNextSemanticReview()
        let beforeResume = runtime.snapshot()

        let resumed = await run(root: root, runtime: runtime)
        let afterResume = runtime.snapshot()

        XCTAssertNotEqual(resumed, 0)
        XCTAssertEqual(try targetContents(root: root), "ORIGINAL\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt),
                       "a reconciled baseline must not retain an acceptance receipt")
        XCTAssertEqual(afterResume.semanticCount, beforeResume.semanticCount + 1)
        XCTAssertEqual(afterResume.promotionCount, beforeResume.promotionCount)
        let state = try persistedState(root: root)
        XCTAssertNil(state.acceptance)
        XCTAssertNotEqual(state.stage, .completed)
    }

    func testPublishedPromotionApprovedCandidateWithCopybookDriftRollsBackWithoutAcceptance() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloRollbackAuthorityRuntime(
            expectedOutput: expectedOutput, target: target,
            initialAction: .failPostPromotionRun)

        let initial = await run(root: root, runtime: runtime)
        XCTAssertNotEqual(initial, 0)
        XCTAssertEqual(try targetContents(root: root), "ORIGINAL\n")
        let beforeState = try persistedState(root: root)
        let staleCandidate = try forgePublishedPromotionApproved(root: root)
        let receipt = try receiptPath(root: root)
        try Data("{\"stale_acceptance\":true}\n".utf8).write(
            to: URL(fileURLWithPath: receipt), options: .atomic)
        let copybookDirectory = URL(fileURLWithPath: root)
            .appendingPathComponent("copybooks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: copybookDirectory, withIntermediateDirectories: true)
        try Data("       01 DRIFT-FIELD PIC X.\n".utf8).write(
            to: copybookDirectory.appendingPathComponent("drift.cpy"), options: .atomic)
        let beforeResume = runtime.snapshot()

        let resumed = await run(root: root, runtime: runtime)
        let afterResume = runtime.snapshot()

        XCTAssertEqual(resumed, 0,
                       "fresh replanning may accept a replacement after rolling back stale bytes")
        XCTAssertEqual(afterResume.secondGenerationTarget, "ORIGINAL\n",
                       "the stale candidate must be rolled back before fresh generation")
        XCTAssertEqual(afterResume.semanticCount, beforeResume.semanticCount + 1)
        XCTAssertEqual(afterResume.promotionCount, beforeResume.promotionCount + 1)
        let state = try persistedState(root: root)
        let acceptance = try XCTUnwrap(state.acceptance)
        XCTAssertEqual(state.stage, .completed)
        XCTAssertEqual(state.attemptsStarted, beforeState.attemptsStarted + 1,
                       "repair attempts must remain monotonic across rollback and replanning")
        XCTAssertNotEqual(acceptance.candidateSHA256, staleCandidate,
                          "the physically published stale candidate must never be accepted")
        XCTAssertTrue(try targetContents(root: root).contains("GENERATED2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt))
        let exploration = try XCTUnwrap(state.exploration)
        XCTAssertTrue(exploration.files.contains { $0.path == "copybooks/drift.cpy" })
        let activePlanDigest = try XCTUnwrap(state.activePlanDigest)
        let activePlan = try XCTUnwrap(state.planReceipts.first {
            $0.receiptDigest == activePlanDigest
        })
        XCTAssertEqual(activePlan.explorationDigest, exploration.receiptDigest)
        let acceptedRevision = try XCTUnwrap(state.revisionReceipts.last {
            $0.outcome == "accepted" && $0.candidateSHA256 == acceptance.candidateSHA256
        })
        XCTAssertEqual(acceptedRevision.planDigest, activePlanDigest)
    }

    private func run(root: String, runtime: CoboloRollbackAuthorityRuntime) async -> Int32 {
        let plan = identityPlan()
        let dependencies = CoboloDependencies(
            environment: [:], identityPlan: plan,
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
            "--cobol-expect", expectedOutput, goal
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

    private func makeRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-cobolo-rollback-authority-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("ORIGINAL\n".utf8).write(to: root.appendingPathComponent(target))
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
            throw CoboloRollbackAuthorityFixtureError.invalidState(
                "expected one run directory, found \(runIDs.count)")
        }
        return (runs as NSString).appendingPathComponent("\(runIDs[0])/state.json")
    }

    private func receiptPath(root: String) throws -> String {
        ((try statePath(root: root)) as NSString)
            .deletingLastPathComponent + "/receipt.json"
    }

    private func persistedState(root: String) throws -> CoboloRunState {
        try CoboloRunStore.decoder.decode(
            CoboloRunState.self,
            from: Data(contentsOf: URL(fileURLWithPath: try statePath(root: root)))
        )
    }

    private func forgePublishedPromotionApproved(root: String) throws -> String {
        var state = try persistedState(root: root)
        guard let candidate = state.candidateSHA256 else {
            throw CoboloRollbackAuthorityFixtureError.invalidState(
                "fixture lacks a durable candidate")
        }
        let candidateURL = URL(fileURLWithPath: root).appendingPathComponent(state.candidatePath)
        let candidateData = try Data(contentsOf: candidateURL)
        guard BuilderEvidenceDigest.sha256(String(decoding: candidateData, as: UTF8.self)) == candidate else {
            throw CoboloRollbackAuthorityFixtureError.invalidState(
                "candidate bytes do not match their checkpoint")
        }
        try candidateData.write(
            to: URL(fileURLWithPath: targetPath(root: root)), options: .atomic)
        state.stage = .promotionApproved
        state.promotedSHA256 = nil
        state.promotionReview = nil
        state.acceptance = nil
        state.rollback = nil
        state.lastError = "simulated crash after publication and before promoted-state save"
        state.updatedAt = Date()
        try CoboloRunStore.encoder.encode(state).write(
            to: URL(fileURLWithPath: try statePath(root: root)), options: .atomic)
        return candidate
    }
}

private enum CoboloRollbackAuthorityFixtureError: Error {
    case invalidState(String)
    case semanticUnavailable
    case driftSetup(String)
}

private final class CoboloRollbackAuthorityRuntime: @unchecked Sendable {
    enum InitialAction: Sendable {
        case none
        case failPostPromotionRun
        case driftDuringPostPromotionRun
    }

    struct Snapshot {
        let generationCount: Int
        let semanticCount: Int
        let promotionCount: Int
        let fixtureError: String?
        let secondGenerationTarget: String?
    }

    private let lock = NSLock()
    private let expectedOutput: String
    private let target: String
    private var initialAction: InitialAction
    private var generationCount = 0
    private var semanticCount = 0
    private var promotionCount = 0
    private var shouldFailSemanticReview = false
    private var fixtureError: String?
    private var secondGenerationTarget: String?

    init(expectedOutput: String, target: String,
         initialAction: InitialAction = .none) {
        self.expectedOutput = expectedOutput
        self.target = target
        self.initialAction = initialAction
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(generationCount: generationCount,
                        semanticCount: semanticCount,
                        promotionCount: promotionCount,
                        fixtureError: fixtureError,
                        secondGenerationTarget: secondGenerationTarget)
    }

    func failNextSemanticReview() {
        lock.lock()
        shouldFailSemanticReview = true
        lock.unlock()
    }

    func executeTool(name: String, arguments: [String: Any], context: ToolContext,
                     logicalStage: String) -> CoboloToolOutcome {
        if name == "cobol_generate" {
            let generation = increment(\.generationCount)
            if generation == 2 {
                recordSecondGenerationTarget(projectRoot: context.projectRoot)
            }
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
            if stage.contains("post-promotion") {
                switch consumeInitialAction() {
                case .failPostPromotionRun:
                    return commandOutcome(success: false, exitCode: 1, stdout: "",
                                          stderr: "simulated post-promotion failure")
                case .driftDuringPostPromotionRun:
                    do {
                        try installCopybookDrift(projectRoot: context.projectRoot)
                    } catch {
                        recordFixtureError(error.localizedDescription)
                        return commandOutcome(success: false, exitCode: 1, stdout: "",
                                              stderr: "fixture could not mutate copybook inputs")
                    }
                case .none:
                    break
                }
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
                "steps": ["Generate complete COBOL", "Compile and execute it"],
                "acceptance_checks": ["exit code is zero", "stdout contains \(expectedOutput)"]
            ]))

        case .semanticCritic:
            increment(\.semanticCount)
            if consumeSemanticFailure() {
                throw CoboloRollbackAuthorityFixtureError.semanticUnavailable
            }
            return completion(for: invocation.binding, text: json([
                "contract_id": invocation.contractID,
                "candidate_sha256": invocation.candidateSHA256.map { $0 as Any } ?? NSNull(),
                "compile_evidence_digest": invocation.compileEvidenceDigest.map { $0 as Any } ?? NSNull(),
                "run_evidence_digest": invocation.runEvidenceDigest.map { $0 as Any } ?? NSNull(),
                "decision": "APPROVE",
                "reason": "candidate evidence is bound and coherent"
            ]))

        case .promotion:
            increment(\.promotionCount)
            return completion(for: invocation.binding, text: json([
                "contract_id": invocation.contractID,
                "candidate_sha256": invocation.candidateSHA256.map { $0 as Any } ?? NSNull(),
                "semantic_receipt_digest": invocation.semanticReceiptDigest.map { $0 as Any } ?? NSNull(),
                "verification_digest": invocation.verificationDigest.map { $0 as Any } ?? NSNull(),
                "decision": "APPROVE",
                "reason": "independent review approves conditional publication"
            ]))
        }
    }

    private func consumeInitialAction() -> InitialAction {
        lock.lock()
        defer { lock.unlock() }
        let action = initialAction
        initialAction = .none
        return action
    }

    private func consumeSemanticFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = shouldFailSemanticReview
        shouldFailSemanticReview = false
        return value
    }

    private func recordFixtureError(_ value: String) {
        lock.lock()
        fixtureError = value
        lock.unlock()
    }

    private func recordSecondGenerationTarget(projectRoot: String) {
        let path = (projectRoot as NSString).appendingPathComponent(target)
        let observed = try? String(contentsOfFile: path, encoding: .utf8)
        lock.lock()
        secondGenerationTarget = observed
        lock.unlock()
    }

    @discardableResult
    private func increment(
        _ keyPath: ReferenceWritableKeyPath<CoboloRollbackAuthorityRuntime, Int>
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        self[keyPath: keyPath] += 1
        return self[keyPath: keyPath]
    }

    private func installCopybookDrift(projectRoot: String) throws {
        let directory = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent("copybooks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("       01 FINAL-DRIFT PIC X.\n".utf8).write(
            to: directory.appendingPathComponent("post-final-drift.cpy"), options: .atomic)
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
        _ = FileManager.default.createFile(
            atPath: path, contents: Data("fake executable".utf8))
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
