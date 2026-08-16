import XCTest
import AgentCore
@testable import Kist

private actor KistBuilderReviewProbe {
    private var calls = 0
    func record() { calls += 1 }
    func count() -> Int { calls }
}

final class KistBuilderRunCompositionTests: XCTestCase {
    func testCoboloEvidenceRejectsLegacyUnregisteredCommandReceipts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-cobolo-builder-boundary-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = "program.cbl"
        let source = "       IDENTIFICATION DIVISION.\n       PROGRAM-ID. BOUND.\n"
        try Data(source.utf8).write(to: root.appendingPathComponent(target))
        let promoted = BuilderEvidenceDigest.sha256(source)
        let observed = PlanExecuteLoop.governedWorkspaceDigest(projectRoot: root.path)
        let command = CoboloCommandReceipt(
            stage: "compile", executable: "cobc", arguments: [target], exitCode: 0,
            sandboxed: true, timedOut: false, wasSignalled: false,
            stdoutTruncated: false, stderrTruncated: false, outputTruncated: false,
            stdout: "ok", stderr: "", capturedAt: Date())
        let verification = CoboloVerificationReceipt(
            phase: "post-promotion", sourcePath: target, sourceSHA256: promoted,
            binarySHA256: "binary", compile: command,
            run: CoboloCommandReceipt(
                stage: "run", executable: "program", arguments: [], exitCode: 0,
                sandboxed: true, timedOut: false, wasSignalled: false,
                stdoutTruncated: false, stderrTruncated: false, outputTruncated: false,
                stdout: "EXPECTED", stderr: "", capturedAt: Date()),
            expectedStdout: "EXPECTED", verifiedAt: Date())
        let options = KistOptions.parse([
            "--cobolo", "--cobol-target", target,
            "--cobol-expect", "EXPECTED", "build bound COBOL",
        ])
        let identityPlan = coboloIdentityPlanFixture()
        let executionContract = coboloExecutionContractFixture(
            root: root.path, options: options, identityPlan: identityPlan,
            builderContractID: "builder-contract")
        let evidence = CoboloBuilderEvidence(
            producerIdentities: identityPlan.producerIdentities, target: target,
            promotedSHA256: promoted, observedWorkspaceDigest: observed,
            finalVerification: verification,
            reviewerIdentity: "promotion:promotion-v1",
            executionContract: executionContract)

        XCTAssertThrowsError(try KistRunner.builderValidatedCoboloEvidence(
            evidence, root: root.path, contractFingerprint: "contract",
            builderContractID: "builder-contract", builderNodeID: "cobolo-execution",
            expectedExecutionContract: executionContract)) { error in
            guard case BuilderRunError.finalVerificationFailed = error else {
                return XCTFail("expected finalVerificationFailed, got \(error)")
            }
        }
    }

    func testOuterReviewBudgetDeniesBeforeAnyFourLensInvocation() async {
        let budget = BudgetLedger(maxTokens: 1)
        let roles = RoleBindings(
            default: ProviderBinding(providerId: "gemini", model: "reviewer"))
        let result = await KistRunner.runBudgetedBuilderShipReview(
            goal: "review the complete build", registry: ProviderRegistry(), roles: roles,
            root: NSTemporaryDirectory(), budget: budget,
            reviewerProviderID: "gemini", verifiedExecution: true)

        XCTAssertNil(result.decision,
                     "budget denial must return before runShipReview can invoke a lens")
        XCTAssertTrue(result.denialReason?.contains("before invocation") == true)
        XCTAssertEqual(result.usage.aggregateTokens, 0)
        let spent = await budget.spentTokens()
        XCTAssertEqual(spent, 0)
    }

    func testAggregateRunUsageIncludesOuterReview() {
        let final = BuilderFinalReceipt(
            contractID: "contract", route: .direct,
            workers: [BuilderWorkerReceipt(
                nodeID: "build", provider: "worker", model: "model",
                usage: .init(inputTokens: 10, outputTokens: 5, aggregateTokens: 15))],
            verification: BuilderVerifierReceipt(
                scope: .final, provider: "kist", model: "deterministic",
                deterministic: true, passed: true),
            review: BuilderReviewReceipt(
                provider: "critic", model: "reviewer", accepted: true,
                usage: .init(inputTokens: 40, outputTokens: 20, aggregateTokens: 60)),
            accepted: true, completedAt: Date())

        let usage = KistRunner.builderAggregateRunUsage(final)
        XCTAssertEqual(usage.inputTokens, 50)
        XCTAssertEqual(usage.outputTokens, 25)
        XCTAssertEqual(usage.aggregateTokens, 75)
    }

    func testDefaultAndReadOnlyPlanUseCanonicalHeadlessSelection() {
        let ordinary = KistRunner.builderCompatibilityLaunch(for: KistOptions.parse(["build it"]))
        XCTAssertFalse(KistOptions.parse(["build it"]).headless,
                       "default Captain auto-routing must remain unforced")
        XCTAssertEqual(ordinary.adapter, .headless)
        XCTAssertEqual(ordinary.routeHint.preferred, .direct)

        let readOnlyPlan = KistRunner.builderCompatibilityLaunch(
            for: KistOptions.parse(["--plan", "inspect then propose"]))
        XCTAssertEqual(readOnlyPlan.adapter, .headless)
        XCTAssertEqual(readOnlyPlan.routeHint.preferred, .direct)
    }

    func testImmutablePreflightUsesPlannerWhileCoderAndCriticRemainDistinct() throws {
        let registry = reviewerRegistry([
            ("codex-cli", "gpt-5.6-sol"),
            ("claude-cli", "sonnet"),
            ("deepseek", "deepseek-reasoner"),
        ])
        let roles = RoleBindings(
            default: ProviderBinding(providerId: "codex-cli", model: "gpt-5.6-sol"),
            [
                .planner: ProviderBinding(providerId: "codex-cli", model: "gpt-5.6-sol"),
                .coder: ProviderBinding(providerId: "claude-cli", model: "sonnet"),
                .critic: ProviderBinding(providerId: "deepseek", model: "deepseek-reasoner"),
            ])

        let preflight = try XCTUnwrap(
            KistRunner.builderPreflightBinding(roles: roles, registry: registry))
        XCTAssertEqual(preflight.providerId, "codex-cli")
        XCTAssertEqual(preflight.model, "gpt-5.6-sol")
        XCTAssertEqual(roles.binding(for: .coder).providerId, "claude-cli")
        XCTAssertEqual(roles.binding(for: .critic).providerId, "deepseek")
        XCTAssertNotEqual(preflight.providerId, roles.binding(for: .coder).providerId)
    }

    func testExplicitHeadlessForcesTypedDirectBuilderRouteAndDecisionReceipt() {
        let goal = "production security migration that heuristics would escalate"
        let options = KistOptions.parse(["--headless", goal])
        let launch = KistRunner.builderCompatibilityLaunch(for: options, goal: goal)

        XCTAssertTrue(KistRunner.builderRunRequired(for: options, goal: goal),
                      "an explicit route selector must enter the sealed BuilderRun path")
        XCTAssertEqual(launch.adapter, .headless)
        XCTAssertEqual(launch.routeHint.preferred, .direct)
        XCTAssertEqual(launch.routeHint.resolve(), .direct)
        XCTAssertTrue(launch.leanHeadless,
                      "explicit direct runs must use the least-privilege scoped tool registry")
        XCTAssertTrue(launch.mutationIntent,
                      "the host-owned build route must mint mutation intent before provider output")

        let receipt = KistRunner.builderCaptainDecisionReceipt(
            contractID: "sealed-contract", goal: goal, launch: launch)
        XCTAssertEqual(receipt.adapter, "headless")
        XCTAssertEqual(receipt.route, "direct")
        XCTAssertEqual(receipt.builderContractID, "sealed-contract")
        XCTAssertEqual(receipt.objectiveDigest, BuilderEvidenceDigest.sha256(goal))
        XCTAssertFalse(receipt.digest.isEmpty)
    }

    func testExplicitHeadlessPreservesNoEditAuthorityBoundary() {
        let goal = "Audit the project read-only without editing"
        let options = KistOptions.parse(["--headless", goal])
        let launch = KistRunner.builderCompatibilityLaunch(for: options, goal: goal)

        XCTAssertEqual(launch.adapter, .headless)
        XCTAssertFalse(launch.mutationIntent,
                       "a route flag cannot override the user's explicit no-edit contract")
        XCTAssertTrue(KistRunner.builderRunRequired(for: options, goal: goal),
                      "verification-only headless runs still require deterministic proof and review")
    }

    func testReadOnlyAnswerAndResearchBypassBuilderWhileExplicitPlanExecuteStaysGated() {
        let fetch = KistOptions.parse(["Use fetch_url on https://example.com and report the title"])
        XCTAssertFalse(KistRunner.builderRunRequired(for: fetch, goal: fetch.goal ?? ""))

        let research = KistOptions.parse(["Research current Swift concurrency guidance with sources"])
        XCTAssertFalse(KistRunner.builderRunRequired(for: research, goal: research.goal ?? ""))

        let plannedFetch = KistOptions.parse([
            "--plan-execute", "Use fetch_url on https://example.com and report the title",
        ])
        XCTAssertTrue(KistRunner.builderRunRequired(
            for: plannedFetch, goal: plannedFetch.goal ?? ""),
            "an explicit plan-execute route must not be downgraded by prose classification")

        let dogfood = KistOptions.parse([
            "--plan-execute",
            "Modify exactly artifact.txt, run its test, require independent review and receipts",
        ])
        XCTAssertTrue(KistRunner.builderRunRequired(
            for: dogfood, goal: dogfood.goal ?? ""),
            "review wording must not downgrade an explicit mutation route to read-only")

        let planOnly = KistOptions.parse([
            "--plan", "--plan-execute", "Modify exactly artifact.txt",
        ])
        XCTAssertFalse(KistRunner.builderRunRequired(
            for: planOnly, goal: planOnly.goal ?? ""),
            "explicit plan mode remains read-only even when plan-execute is also present")

        let build = KistOptions.parse(["Build a receipt parser"])
        XCTAssertTrue(KistRunner.builderRunRequired(for: build, goal: build.goal ?? ""))

        let verification = KistOptions.parse([
            "--plan-execute", "Audit the existing project read-only",
        ])
        XCTAssertTrue(KistRunner.builderRunRequired(
            for: verification, goal: verification.goal ?? ""))
    }

    func testRequiredCouncilCriticFailsClosed() {
        let failedCritic = CouncilMindResult(
            name: "Critic", role: AgentRole.critic.rawValue, binding: nil,
            output: "FAILED: rateLimited", failed: true)
        let failed = CouncilRunResult(
            goal: "research", minds: [failedCritic], finalPlan: "fallback",
            markdown: "artifact", builderBrief: "do not build")
        XCTAssertEqual(KistRunner.requiredCouncilCriticFailure(failed),
                       "required critic failed: FAILED: rateLimited")

        let missing = CouncilRunResult(
            goal: "research", minds: [], finalPlan: "fallback",
            markdown: "artifact", builderBrief: "do not build")
        XCTAssertEqual(KistRunner.requiredCouncilCriticFailure(missing),
                       "required critic did not run")

        let acceptedCritic = CouncilMindResult(
            name: "Critic", role: AgentRole.critic.rawValue, binding: nil,
            output: "Evidence is sufficient", failed: false,
            criticVerdict: .init(decision: .accept, rationale: "primary evidence is present"))
        let accepted = CouncilRunResult(
            goal: "research", minds: [acceptedCritic], finalPlan: "plan",
            markdown: "artifact", builderBrief: "build")
        XCTAssertNil(KistRunner.requiredCouncilCriticFailure(accepted))

        let proseOnly = CouncilMindResult(
            name: "Critic", role: AgentRole.critic.rawValue, binding: nil,
            output: "Evidence is sufficient", failed: false)
        let incomplete = CouncilRunResult(
            goal: "research", minds: [proseOnly], finalPlan: "plan",
            markdown: "artifact", builderBrief: "build")
        XCTAssertEqual(KistRunner.requiredCouncilCriticFailure(incomplete),
                       "required critic did not return a valid structured verdict")

        let rejectingCritic = CouncilMindResult(
            name: "Critic", role: AgentRole.critic.rawValue, binding: nil,
            output: "Named URL was not fetched", failed: false,
            criticVerdict: .init(decision: .reject, rationale: "named URL was not fetched"))
        let rejected = CouncilRunResult(
            goal: "research", minds: [rejectingCritic], finalPlan: "plan",
            markdown: "artifact", builderBrief: "build")
        XCTAssertEqual(KistRunner.requiredCouncilCriticFailure(rejected),
                       "required critic rejected the research: named URL was not fetched")
    }

    func testPlanExecuteSelectsPlannedCompatibilityAdapter() {
        let launch = KistRunner.builderCompatibilityLaunch(
            for: KistOptions.parse(["--plan-execute", "build it"]))
        XCTAssertEqual(launch.adapter, .planExecute)
        XCTAssertEqual(launch.routeHint.preferred, .planned)
        XCTAssertEqual(launch.routeHint.resolve(), .planned)
    }

    func testFleetSelectsFleetCompatibilityAdapterAndCarriesWidth() {
        var options = KistOptions.parse(["--fleet", "build independent parts"])
        options.agents = 3
        let launch = KistRunner.builderCompatibilityLaunch(for: options)
        XCTAssertEqual(launch.adapter, .fleet)
        XCTAssertEqual(launch.routeHint.preferred, .fleet)
        XCTAssertEqual(launch.routeHint.independentWorkstreams, 3)
        XCTAssertEqual(launch.routeHint.resolve(), .fleet)
    }

    func testGreatLoopKeepsAdaptiveRouteHintAndCompatibilityAdapter() {
        let launch = KistRunner.builderCompatibilityLaunch(
            for: KistOptions.parse(["--loop", "keep building"]))
        XCTAssertEqual(launch.adapter, .greatLoop)
        XCTAssertEqual(launch.routeHint.preferred, .highAssurance)
    }

    func testMissionSelectsHighAssuranceCompatibilityAdapter() {
        let launch = KistRunner.builderCompatibilityLaunch(
            for: KistOptions.parse(["--mission", "ship a critical migration"]))
        XCTAssertEqual(launch.adapter, .mission)
        XCTAssertEqual(launch.routeHint.preferred, .highAssurance)
        XCTAssertTrue(launch.routeHint.requiresResearch)
        XCTAssertTrue(launch.routeHint.requiresSimulation)
        XCTAssertEqual(launch.routeHint.risk, .critical)
    }

    func testExistingRoutePrecedenceSelectsExactlyOneCompatibilityAdapter() {
        var options = KistOptions.parse(["build it"])
        options.greatLoop = true
        options.planExecute = true
        options.fleet = true
        options.mission = true
        XCTAssertEqual(KistRunner.builderCompatibilityLaunch(for: options).adapter, .mission)
        options.mission = false
        XCTAssertEqual(KistRunner.builderCompatibilityLaunch(for: options).adapter, .fleet)
        options.fleet = false
        XCTAssertEqual(KistRunner.builderCompatibilityLaunch(for: options).adapter, .planExecute)
        options.planExecute = false
        XCTAssertEqual(KistRunner.builderCompatibilityLaunch(for: options).adapter, .greatLoop)
    }

    func testCouncilExecuteHandoffUsesCanonicalPlannedCompatibilityPath() throws {
        let runner = kistRunnerFamilySource()
        let start = try XCTUnwrap(runner.range(of: "let builderGoal ="))
        let handoff = String(runner[start.lowerBound...].prefix(2_400))
        XCTAssertTrue(handoff.contains("planExecute = true"),
                      "the council builder brief must select the planned compatibility route")
        XCTAssertTrue(handoff.contains("runBuilderCompatibility("),
                      "council-execute must enter the canonical BuilderRun launcher")
        XCTAssertFalse(handoff.contains("return await runPlanExecute("),
                       "the council must not bypass BuilderRun with a direct legacy call")
    }

    func testContractIdentityIsStableAcrossExplicitResumeSelection() {
        let ordinary = KistOptions.parse(["build the parser"])
        let resumed = KistOptions.parse(["--resume", "checkpoint-7", "build the parser"])
        let ordinaryAdapter = KistRunner.builderCompatibilityLaunch(for: ordinary).adapter
        let resumedAdapter = KistRunner.builderCompatibilityLaunch(for: resumed).adapter
        let first = KistRunner.builderCompatibilityContractID(
            root: "/tmp/project", goal: "build the parser", adapter: ordinaryAdapter)
        let second = KistRunner.builderCompatibilityContractID(
            root: "/tmp/project", goal: "build the parser", adapter: resumedAdapter)

        XCTAssertEqual(resumed.resumeId, "checkpoint-7")
        XCTAssertEqual(ordinaryAdapter, .headless)
        XCTAssertEqual(resumedAdapter, .headless)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, KistRunner.builderCompatibilityContractID(
            root: "/tmp/project", goal: "build the parser", adapter: .headless))
        XCTAssertNotEqual(first, KistRunner.builderCompatibilityContractID(
            root: "/tmp/project", goal: "build another parser", adapter: .headless))
    }

    func testAdapterExitSuccessWithoutFinalTypedProofCannotSucceed() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kist-builder-proof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BuilderJSONStore(fileURL: root.appendingPathComponent("run.json"))
        let policy = BuilderGraphExecutionPolicy(nodeClasses: ["build": .readOnly])
        var contract = BuilderContract(
            id: "kist-proof", objective: "build", doneWhen: ["typed proof exists"],
            routeHint: .init(preferred: .direct), checkpointIdentity: nil, maxTokens: 100,
            completionMode: .verificationOnly)
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "build", objective: "build")])
        contract.governanceAdmission = try BuilderGraphGovernanceAdmission.make(
            graph: graph, policy: policy, providerIdentity: nil)
        let reviewProbe = KistBuilderReviewProbe()
        let run = try BuilderRun(
            contract: contract, graph: graph, store: store,
            graphExecutionPolicy: policy,
            readOnlyObservationSourceProvider:
                KistRunner.BuilderProjectReadOnlyObservationProvider(projectRoot: root.path),
            execute: { request in
                BuilderWorkerReceipt(
                    nodeID: request.node.id, provider: "builder", model: "model",
                    checks: [.init(name: "adapter exit", passed: true, details: "exit 0")],
                    usage: .init(aggregateTokens: nil,
                                 unmeteredStages: ["fleet.execution"]))
            },
            verify: { request in
                switch request {
                case .node(_, let node, let worker, _):
                    return .init(scope: .node(node.id), provider: "kist", model: "deterministic",
                                 deterministic: true, passed: true, checks: worker.checks)
                case .final:
                    return .init(scope: .final, provider: "kist", model: "deterministic",
                                 deterministic: true, passed: false,
                                 checks: [.init(name: "typed final proof", passed: false,
                                                details: "missing")],
                                 failureFingerprint: "missing-final-proof")
                }
            },
            review: { _ in
                await reviewProbe.record()
                return .init(provider: "critic", model: "other", accepted: true)
            }
        )

        do {
            _ = try await run.run()
            XCTFail("adapter exit zero must not substitute for BuilderFinalReceipt")
        } catch let error as BuilderRunError {
            guard case .finalVerificationFailed = error else {
                return XCTFail("expected finalVerificationFailed, got \(error)")
            }
        }
        let reviewCalls = await reviewProbe.count()
        XCTAssertEqual(reviewCalls, 0)
        let loaded = try await store.load()
        XCTAssertNil(try XCTUnwrap(loaded).finalReceipt)
    }

    func testCompatibilityRequiresDistinctCriticIdentity() {
        let builder = ProviderBinding(providerId: "openai", model: "gpt-5")
        XCTAssertNil(KistRunner.independentReviewIdentities(
            builder: builder,
            reviewer: ProviderBinding(providerId: "openai", model: "gpt-5")))
        XCTAssertNotNil(KistRunner.independentReviewIdentities(
            builder: builder,
            reviewer: ProviderBinding(providerId: "anthropic", model: "claude")))
    }

    func testReviewerSelectionFallsBackToDistinctAvailableProviderDeterministically() {
        let registry = reviewerRegistry([
            ("openai", "gpt-worker"),
            ("gemini", "gemini-review"),
            ("anthropic", "claude-review"),
        ])
        let selection = KistRunner.independentReviewerSelection(
            preferred: ProviderBinding(providerId: "openai", model: "gpt-worker"),
            producingIdentities: Set(["openai:gpt-worker"]), registry: registry)

        XCTAssertEqual(selection?.identity, "anthropic:claude-review")
        XCTAssertEqual(selection?.workerIdentities, ["openai:gpt-worker"])
    }

    func testReviewerSelectionFailsClosedWhenNoDistinctIdentityIsAvailable() {
        let registry = reviewerRegistry([("openai", "gpt-worker")])
        let selection = KistRunner.independentReviewerSelection(
            preferred: ProviderBinding(providerId: "openai", model: "gpt-worker"),
            producingIdentities: Set(["openai:gpt-worker"]), registry: registry)
        XCTAssertNil(selection)
    }

    func testVerificationOnlyClassificationRequiresVerificationLeadAndExplicitNoEditClause() {
        XCTAssertEqual(KistRunner.builderCompletionMode(
            for: "Verify the existing project without editing unless a deterministic check fails"),
            .verificationOnly)
        XCTAssertEqual(KistRunner.builderCompletionMode(for: "Audit this project read-only"),
                       .verificationOnly)
        XCTAssertEqual(KistRunner.builderCompletionMode(for: "Verify and fix every failing test"), .build)
        XCTAssertEqual(KistRunner.builderCompletionMode(
            for: "Build the parser but do not edit README"), .build)
    }

    func testAuthoritativeReviewRoutesEveryLensThroughSelectedConcreteIdentity() throws {
        let registry = reviewerRegistry([("anthropic", "claude-worker"), ("gemini", "gemini-review")])
        let producingRoles = RoleBindings(
            default: ProviderBinding(providerId: "anthropic", model: "claude-worker"),
            [.critic: ProviderBinding(providerId: "gemini", model: "gemini-review")])
        XCTAssertEqual(KistRunner.configuredProducerIdentities(
            roles: producingRoles, registry: registry), Set(["anthropic:claude-worker"]))
        let selection = try XCTUnwrap(KistRunner.independentReviewerSelection(
            preferred: ProviderBinding(providerId: "gemini", model: "gemini-review"),
            producingIdentities: Set(["anthropic:claude-worker"]), registry: registry))
        let reviewRoles = KistRunner.independentReviewRoles(selection)
        for role in AgentRole.allCases {
            XCTAssertEqual(reviewRoles.binding(for: role), selection.binding)
        }
        XCTAssertEqual(selection.identity, "gemini:gemini-review")
    }

    func testAcceptedRunRecordKeepsMissionSeparateFromContractProducerAndReviewer() {
        let missionInstanceID = String(repeating: "b", count: 64)
        let launch = KistRunner.builderCompatibilityLaunch(
            for: KistOptions.parse(["--plan-execute", "verify without editing"]))
        let final = BuilderFinalReceipt(
            contractID: "contract", route: .planned,
            workers: [BuilderWorkerReceipt(nodeID: "verify", provider: "anthropic", model: "claude")],
            verification: BuilderVerifierReceipt(
                scope: .final, provider: "kist", model: "deterministic",
                deterministic: true, passed: true,
                verificationSubject: "/tmp/project", subjectDigest: "abc123",
                verifiedAt: Date(timeIntervalSince1970: 1_000)),
            review: BuilderReviewReceipt(
                provider: "gemini", model: "gemini-review", accepted: true,
                workerIdentities: ["anthropic:claude"],
                reviewerIdentity: "gemini:gemini-review"),
            accepted: true, completedAt: Date(timeIntervalSince1970: 1_001))
        let payload = KistRunner.builderRunRecordPayload(
            contractID: "contract", missionInstanceID: missionInstanceID,
            launch: launch, outcome: "accepted", detail: "approved",
            finalReceipt: final)

        XCTAssertEqual(payload["missionInstanceID"] as? String, missionInstanceID)
        XCTAssertNotEqual(payload["missionInstanceID"] as? String, "contract")
        XCTAssertEqual(payload["reviewerIdentity"] as? String, "gemini:gemini-review")
        XCTAssertEqual(payload["producerIdentities"] as? [String], ["anthropic:claude"])
        XCTAssertNotEqual(payload["missionInstanceID"] as? String,
                          payload["reviewerIdentity"] as? String)
        XCTAssertFalse((payload["producerIdentities"] as? [String] ?? []).contains(missionInstanceID))
        XCTAssertEqual(payload["verificationSubject"] as? String, "/tmp/project")
        XCTAssertEqual(payload["verificationDigest"] as? String, "abc123")
        XCTAssertNotNil(payload["verifiedAt"] as? String)
    }

    func testTypedPlanCommandEvidencePreservesExpectedExitAndExcludesFreeFormTools() {
        let fingerprint = "objective-sha"
        let rows = [
            StepResult(stepId: "test", tool: "run_command", success: true,
                       output: "8 tests passed", error: nil,
                       metadata: ["exit_code": "0", "allowed_exit_codes": "0", "verification_eligible": "true"],
                       effectObservation: .init(verification: .buildOrTest),
                       executionPhase: 1, argsFingerprint: "swift test"),
            StepResult(stepId: "invalid", tool: "run_command", success: true,
                       output: "line 1 invalid", error: nil,
                       metadata: ["exit_code": "1", "allowed_exit_codes": "1", "verification_eligible": "false", "semantic_status": "expected_domain_status"],
                       effectObservation: .init(verification: .nonVerifyingCommand),
                       executionPhase: 2, argsFingerprint: "invalid fixture"),
            StepResult(stepId: "planned-review", tool: "grounded_answer", success: true,
                       output: "SHIP", error: nil, argsFingerprint: "unproven")]
        let execution = PlanExecution(success: true, stepResults: rows, attemptResults: rows,
                                      outputs: [:], failedStepId: nil)
        let receipts = KistRunner.builderCommandEvidence(
            execution: execution, contractFingerprint: fingerprint, subjectDigest: "digest")
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts.map(\.verifierStatus), [.passed, .expectedDomainStatus])
        XCTAssertEqual(receipts.map(\.exitCode), [0, 1])
        XCTAssertTrue(receipts.allSatisfy {
            $0.isBound(contractFingerprint: fingerprint, subjectDigest: "digest")
        })
        XCTAssertFalse(receipts.contains { $0.tool == "grounded_answer" })
    }

    func testPublicBuilderRouteSurfaceUsesNamedSafeSelectorsOnly() {
        XCTAssertFalse(KistOptions.helpText.contains("--builder-run"))
        XCTAssertFalse(KistOptions.helpText.contains("--builder-route"))
        XCTAssertTrue(KistOptions.helpText.contains("--headless"))
        XCTAssertTrue(KistOptions.helpText.contains("--plan-execute"))
        XCTAssertTrue(KistOptions.helpText.contains("--fleet"))
        let unknown = KistOptions.parse(["--builder-run", "goal"])
        XCTAssertEqual(unknown.goal, "--builder-run goal")
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func reviewerRegistry(_ identities: [(String, String)]) -> ProviderRegistry {
        let providers: [any ChatProvider] = identities.map { provider, model in
            OpenAICompatibleProvider(
                id: provider, name: provider, iconName: "cpu", keyAccount: provider + "_key",
                endpoint: "http://127.0.0.1/" + provider, defaultModel: model,
                availableModels: [AIModel(id: model)], requiresAPIKey: false)
        }
        return ProviderRegistry(providers: providers)
    }
}
