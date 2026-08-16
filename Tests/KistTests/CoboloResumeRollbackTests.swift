import XCTest
import AgentCore
@testable import Kist

final class CoboloResumeRollbackTests: XCTestCase {
    private let target = "src/rollback.cbl"
    private let expectedOutput = "EXPECTED"

    func testForgedPromotionApprovedCheckpointRequiresFreshReviews() async throws {
        let root = try makeRoot(existingTarget: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloResumeRollbackRuntime(
            mode: .failFirstSemanticReview, expectedOutput: expectedOutput)

        let interrupted = await run(root: root, runtime: runtime)

        XCTAssertNotEqual(interrupted, 0)
        XCTAssertEqual(runtime.snapshot().semanticCount, 1)
        XCTAssertEqual(runtime.snapshot().promotionCount, 0)
        XCTAssertEqual(try targetContents(root: root), "ORIGINAL\n")

        try forgePromotionApprovedStage(root: root)
        let resumed = await run(root: root, runtime: runtime)

        XCTAssertEqual(resumed, 0)
        XCTAssertEqual(runtime.snapshot().semanticCount, 2,
                       "the forged stage must not replace a fresh semantic verdict")
        XCTAssertEqual(runtime.snapshot().promotionCount, 1,
                       "the forged stage must not replace a fresh independent promotion verdict")
        XCTAssertTrue(try targetContents(root: root).contains("GENERATED"))
    }

    func testPostPromotionReplayFailureRestoresExistingTarget() async throws {
        let root = try makeRoot(existingTarget: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloResumeRollbackRuntime(
            mode: .failPostPromotionReplay, expectedOutput: expectedOutput)

        let status = await run(root: root, runtime: runtime)

        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(runtime.snapshot().postPromotionFailureCount, 1)
        XCTAssertEqual(try targetContents(root: root), "ORIGINAL\n")
        let receipt = try persistedState(root: root).rollback
        XCTAssertEqual(receipt?.action, "restore")
        XCTAssertEqual(receipt?.baselineSHA256, BuilderEvidenceDigest.sha256("ORIGINAL\n"))
        XCTAssertEqual(receipt?.succeeded, true)
        XCTAssertNil(receipt?.error)
        XCTAssertFalse(receipt?.candidateSHA256.isEmpty ?? true)
    }

    func testPostPromotionReplayFailureRemovesNewTargetForMissingBaseline() async throws {
        let root = try makeRoot(existingTarget: false)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloResumeRollbackRuntime(
            mode: .failPostPromotionReplay, expectedOutput: expectedOutput)

        let status = await run(root: root, runtime: runtime)

        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(runtime.snapshot().postPromotionFailureCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetPath(root: root)))
        let receipt = try persistedState(root: root).rollback
        XCTAssertEqual(receipt?.action, "remove")
        XCTAssertNil(receipt?.baselineSHA256)
        XCTAssertEqual(receipt?.succeeded, true)
        XCTAssertNil(receipt?.error)
        XCTAssertFalse(receipt?.candidateSHA256.isEmpty ?? true)
    }

    func testPublishedTargetIsRolledBackWhenConditionalPromotionReportsFailure() async throws {
        let root = try makeRoot(existingTarget: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloResumeRollbackRuntime(mode: .approve, expectedOutput: expectedOutput)
        let status = await run(
            root: root, runtime: runtime,
            conditionalPromotion: { confined, target, candidate, _ in
                try confined.writeData(target, candidate, createParents: true)
                throw CoboloResumeRollbackFixtureError.publicationDurabilityFailed
            })

        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(try targetContents(root: root), "ORIGINAL\n")
        let receipt = try persistedState(root: root).rollback
        XCTAssertEqual(receipt?.action, "restore")
        XCTAssertEqual(receipt?.succeeded, true)
        XCTAssertNil(receipt?.error)
    }

    func testPublishedTargetIsRolledBackWhenPromotedStateSaveFails() async throws {
        let root = try makeRoot(existingTarget: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = CoboloResumeRollbackRuntime(mode: .approve, expectedOutput: expectedOutput)
        let status = await run(
            root: root, runtime: runtime,
            beforePromotedStateSave: {
                throw CoboloResumeRollbackFixtureError.promotedStateSaveFailed
            })

        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(try targetContents(root: root), "ORIGINAL\n")
        let receipt = try persistedState(root: root).rollback
        XCTAssertEqual(receipt?.action, "restore")
        XCTAssertEqual(receipt?.succeeded, true)
        XCTAssertNil(receipt?.error)
    }

    private func run(
        root: String,
        runtime: CoboloResumeRollbackRuntime,
        conditionalPromotion: ((ConfinedRoot, String, Data,
                                ConfinedRoot.ConditionalBaseline) throws -> Data)? = nil,
        beforePromotedStateSave: (() throws -> Void)? = nil
    ) async -> Int32 {
        let plan = identityPlan()
        let dependencies = CoboloDependencies(
            environment: [:],
            identityPlan: plan,
            executeTool: { name, arguments, context, logicalStage in
                runtime.executeTool(name: name, arguments: arguments,
                                    context: context, logicalStage: logicalStage)
            },
            complete: { invocation in
                try runtime.complete(invocation)
            },
            conditionalPromotion: conditionalPromotion,
            beforePromotedStateSave: beforePromotedStateSave
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
            options(), goal: "Build rollback-safe COBOL", registry: ProviderRegistry(),
            root: root, tools: .headless(), context: context, roles: roles,
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
            "Build rollback-safe COBOL"
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
            .appendingPathComponent("kist-cobolo-rollback-\(UUID().uuidString)", isDirectory: true)
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
            throw CoboloResumeRollbackFixtureError.invalidState(
                "expected one durable run, found \(runIDs.count)")
        }
        return (runs as NSString).appendingPathComponent("\(runIDs[0])/state.json")
    }

    private func persistedState(root: String) throws -> CoboloRunState {
        try CoboloRunStore.decoder.decode(
            CoboloRunState.self,
            from: Data(contentsOf: URL(fileURLWithPath: try statePath(root: root)))
        )
    }

    private func forgePromotionApprovedStage(root: String) throws {
        let path = try statePath(root: root)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoboloResumeRollbackFixtureError.invalidState("state was not a JSON object")
        }
        object["stage"] = CoboloStage.promotionApproved.rawValue
        let forged = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try forged.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private enum CoboloResumeRollbackFixtureError: Error {
    case semanticUnavailable
    case publicationDurabilityFailed
    case promotedStateSaveFailed
    case invalidState(String)
}

private final class CoboloResumeRollbackRuntime: @unchecked Sendable {
    enum Mode: Sendable {
        case approve
        case failFirstSemanticReview
        case failPostPromotionReplay
    }

    struct Snapshot {
        let semanticCount: Int
        let promotionCount: Int
        let postPromotionFailureCount: Int
    }

    private let lock = NSLock()
    private let mode: Mode
    private let expectedOutput: String
    private var generationCount = 0
    private var semanticCount = 0
    private var promotionCount = 0
    private var postPromotionFailureCount = 0

    init(mode: Mode, expectedOutput: String) {
        self.mode = mode
        self.expectedOutput = expectedOutput
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(semanticCount: semanticCount, promotionCount: promotionCount,
                        postPromotionFailureCount: postPromotionFailureCount)
    }

    func executeTool(name: String, arguments: [String: Any], context: ToolContext,
                     logicalStage: String) -> CoboloToolOutcome {
        if name == "cobol_generate" {
            let generation = lockedIncrement(\.generationCount)
            let source = Self.source(generation: generation, expectedOutput: expectedOutput)
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
            return commandOutcome(stdout: "/opt/homebrew/bin/cobc\n")
        }
        if stage.contains("compile") {
            materializeFakeExecutable(arguments: arguments, context: context)
            return commandOutcome(stdout: "")
        }
        if stage.contains("run") || stage.contains("replay") {
            if mode == .failPostPromotionReplay && stage.contains("post-promotion") {
                lockedIncrement(\.postPromotionFailureCount)
                return commandOutcome(success: false, exitCode: 1, stdout: "",
                                      stderr: "post-promotion replay failed")
            }
            return commandOutcome(stdout: expectedOutput + "\n")
        }
        return CoboloToolOutcome(success: false, error: "unexpected logical stage \(logicalStage)")
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
                "steps": ["Generate complete COBOL source", "Compile and run it in the sandbox"],
                "acceptance_checks": ["exit code is zero", "stdout contains \(expectedOutput)"]
            ]))

        case .semanticCritic:
            let count = lockedIncrement(\.semanticCount)
            if mode == .failFirstSemanticReview && count == 1 {
                throw CoboloResumeRollbackFixtureError.semanticUnavailable
            }
            return completion(for: invocation.binding, text: json([
                "contract_id": invocation.contractID,
                "candidate_sha256": invocation.candidateSHA256.map { $0 as Any } ?? NSNull(),
                "compile_evidence_digest": invocation.compileEvidenceDigest.map { $0 as Any } ?? NSNull(),
                "run_evidence_digest": invocation.runEvidenceDigest.map { $0 as Any } ?? NSNull(),
                "decision": "APPROVE",
                "reason": "Fresh semantic review accepts the bound candidate"
            ]))

        case .promotion:
            lockedIncrement(\.promotionCount)
            return completion(for: invocation.binding, text: json([
                "contract_id": invocation.contractID,
                "candidate_sha256": invocation.candidateSHA256.map { $0 as Any } ?? NSNull(),
                "semantic_receipt_digest": invocation.semanticReceiptDigest.map { $0 as Any } ?? NSNull(),
                "verification_digest": invocation.verificationDigest.map { $0 as Any } ?? NSNull(),
                "decision": "APPROVE",
                "reason": "Fresh independent promotion review accepts the bound candidate"
            ]))
        }
    }

    private func completion(for binding: ProviderBinding, text: String) -> CoboloModelCompletion {
        CoboloModelCompletion(providerId: binding.providerId, model: binding.model ?? "", text: text)
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
              let outputFlag = argv.firstIndex(of: "-o"), outputFlag + 1 < argv.count else { return }
        let supplied = argv[outputFlag + 1]
        let path = supplied.hasPrefix("/")
            ? supplied
            : (context.projectRoot as NSString).appendingPathComponent(supplied)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: Data("fake executable".utf8))
    }

    @discardableResult
    private func lockedIncrement(
        _ keyPath: ReferenceWritableKeyPath<CoboloResumeRollbackRuntime, Int>
    ) -> Int {
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
