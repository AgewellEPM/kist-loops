import XCTest
@testable import AgentCore
@testable import Kist

final class KistBuilderRouteBehaviorV2Tests: XCTestCase {
    private struct CommandStub: AgentTool {
        let name = "run_command"
        let description = "test command"
        let parameters: [ToolParameter] = []
        func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
            ToolResult(success: true, output: "verified")
        }
    }

    private struct EnforcedTestAttestor: BuilderSandboxAttestor {
        func attest(_ request: BuilderSandboxAttestationRequest) async throws
            -> BuilderSandboxAttestation {
            try .init(
                request: request, mechanism: "route-behavior-test", enforced: true,
                evidenceDigest: BuilderEvidenceDigest.sha256("route-behavior-test"))
        }
    }

    private func root(_ label: String) throws -> (base: URL, project: URL, staging: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-route-\(label)-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (base, project, staging)
    }

    private func json(adapter: String, path: String = "Sources/Target.swift") -> String {
        let partitions = adapter == "fleet"
            ? #"[{"id":"worker-1","paths":["Sources/Target.swift"]}]"# : "[]"
        return #"{"schema_version":1,"adapter":"\#(adapter)","operations":[{"kind":"modify","path":"\#(path)"}],"verification_commands":[{"executable":"swift","arguments":["test"],"timeout_seconds":120}],"partitions":\#(partitions)}"#
    }

    private func executionContract(
        adapter: KistRunner.BuilderCompatibilityAdapter,
        plan: KistRunner.BuilderPreflightPlan,
        nodeID: String,
        contractID: String
    ) throws -> BuilderExecutionContract {
        let total = try BuilderResourceBudget(
            maxToolCalls: 100, maxTokens: 20_000, maxWallTimeSeconds: 600)
        return try BuilderExecutionContract(
            builderContractID: contractID, builderNodeID: nodeID,
            mutations: plan.operations.map {
                try BuilderMutationOperation(
                    kind: $0.kind, path: $0.path, preimageSHA256: $0.preimageSHA256)
            },
            criteria: [
                try .init(id: "build", stage: .build, kind: .artifactDigest,
                          statement: "exact staged mutation for \(adapter.rawValue)"),
                try .init(id: "verify", stage: .verification, kind: .deterministicCommand,
                          statement: "fresh deterministic command"),
                try .init(id: "review", stage: .review, kind: .modelJudgment,
                          statement: "independent review")
            ],
            budgets: try .init(total: total, stages: [
                .init(stage: .build, limit: total),
                .init(stage: .verification, limit: total),
                .init(stage: .review, limit: total),
            ]),
            identities: try .init(
                producers: [try .init(providerID: "producer", modelID: "model-a")],
                reviewers: [try .init(providerID: "reviewer", modelID: "model-b")]),
            lineage: try .init(
                captainDecisionDigest: BuilderEvidenceDigest.sha256("captain-\(adapter.rawValue)")))
    }

    private func governedHeadlessAttempt(
        project: URL,
        staging: URL,
        plan: KistRunner.BuilderPreflightPlan,
        node: BuilderNode,
        contract: BuilderExecutionContract,
        buildProbe: (@Sendable (BuilderExecutionWorkspace, ToolContext) async throws -> Void)? = nil
    ) async throws -> BuilderGovernedAttemptResult {
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: project, stagingBase: staging,
            attestor: BuilderOSProcessSandboxAttestor())
        let runtime = try BuilderExecutionGovernanceRuntime(
            sealed: try SealedBuilderExecutionContract.issue(contract),
            source: source,
            beside: staging.appendingPathComponent("headless-governance.json"))
        try runtime.ensureReady()
        let builderContract = BuilderContract(
            id: contract.builderContractID,
            objective: node.objective,
            allowedPaths: plan.allowedPaths.sorted(),
            doneWhen: ["sealed deterministic verification passes"])
        let toolContext = ToolContext(
            projectRoot: project.path,
            shell: ShellPolicy(enabled: true, autoApprove: true, allow: ["python3"]))

        return await runtime.execute(
            builderContract: builderContract,
            route: .direct,
            node: node,
            attempt: 1,
            execute: { request in
                guard let workspace = request.executionWorkspace else {
                    throw BuilderRunError.invalidConfiguration(
                        "governed headless worker has no isolated execution workspace")
                }
                if let buildProbe {
                    try await buildProbe(
                        workspace,
                        KistRunner.builderRebasedToolContext(
                            toolContext, projectRoot: workspace.rootPath,
                            governedExecutionWorkspace: true))
                }
                let stopped = HeadlessAgentLoop.Outcome(
                    success: false,
                    summary: "model stopped without running tests",
                    iterations: 4,
                    checkpointId: "checkpoint",
                    terminalStatus: .stoppedUnverified)
                guard KistRunner.builderHeadlessCanHandOffToDeterministicVerification(
                    outcome: stopped, sealedPlan: plan) else {
                    throw BuilderRunError.finalVerificationFailed(
                        "typed stopped-unverified handoff was rejected")
                }
                try Data("NEW\n".utf8).write(
                    to: URL(fileURLWithPath: workspace.rootPath)
                        .appendingPathComponent("result.txt"))
                BuilderTrustedTelemetry.recordProvider(
                    providerID: "producer",
                    modelID: "model-a",
                    inputTokens: 1,
                    outputTokens: 1,
                    elapsedMilliseconds: 1,
                    outputDigest: BuilderEvidenceDigest.sha256("headless-worker"))
                return BuilderWorkerReceipt(
                    nodeID: request.node.id,
                    provider: "producer",
                    model: "model-a",
                    changedPaths: ["result.txt"],
                    checks: [.init(
                        name: "headless completion gate",
                        passed: true,
                        details: "sealed mutation execution stopped for mandatory Builder node verification")])
            },
            verify: { request in
                guard case .node(
                    let parent, let requestNode, _, let executionWorkspace) = request,
                      let workspace = executionWorkspace else {
                    throw BuilderRunError.finalVerificationFailed(
                        "governed headless attempt did not receive its verification workspace")
                }
                return try await KistRunner.builderRunPlannedVerification(
                    plan: plan,
                    workspace: workspace,
                    context: toolContext,
                    builderContractID: parent.id,
                    contractFingerprint: try contract.fingerprint(),
                    nodeID: requestNode.id,
                    wallDeadline: Date().addingTimeInterval(30))
            })
    }

    private func assertRoute(
        _ adapter: KistRunner.BuilderCompatibilityAdapter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try root(adapter.rawValue)
        let target = fixture.project.appendingPathComponent("Sources/Target.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("let value = 1\n".utf8)
        let changed = Data("let value = 2\n".utf8)
        try original.write(to: target)
        let contractID = "route-\(adapter.rawValue)"
        var events: [String] = []

        let plan = try KistRunner.builderParsePreflightPlan(
            json(adapter: adapter.rawValue), adapter: adapter,
            projectRoot: fixture.project.path, maxPartitions: 2)
        let envelope = try KistRunner.BuilderPreflightEnvelope(
            builderContractID: contractID, goal: "mutate target",
            projectRoot: fixture.project.path, plan: plan)
        try envelope.validate(
            builderContractID: contractID, goal: "mutate target",
            projectRoot: fixture.project.path)
        events.append("sealed-preflight")

        let nodeID = adapter == .cobolo
            ? "cobolo-execution" : KistRunner.builderPlannedExecutionNodeID(for: adapter)
        let node = BuilderNode(
            id: nodeID, objective: "mutate target",
            resources: plan.allowedPaths.map { .init(path: $0, access: .write) },
            isolation: .sandbox, role: .builder, retryLimit: 0)
        let contract = try executionContract(
            adapter: adapter, plan: plan, nodeID: nodeID, contractID: contractID)
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: fixture.project, stagingBase: fixture.staging,
            attestor: EnforcedTestAttestor())
        let build = try BuilderStageContext(contract: contract, node: node, attempt: 1, stage: .build)
        let baseline = try await source.prepare(build)
        let workspace = try await source.executionWorkspace(for: build)
        events.append("workspace-issued")
        XCTAssertEqual(events, ["sealed-preflight", "workspace-issued"], file: file, line: line)

        try changed.write(to: URL(fileURLWithPath: workspace.rootPath)
            .appendingPathComponent("Sources/Target.swift"))
        events.append("staged-mutation")
        XCTAssertEqual(try Data(contentsOf: target), original, file: file, line: line)
        let worker = BuilderWorkerReceipt(
            nodeID: nodeID, provider: "producer", model: "model-a",
            changedPaths: plan.allowedPaths,
            checks: [.init(name: "route build", passed: true)])
        let buildObservation = try await source.observe(.init(
            context: build, baseline: baseline, subject: .execution(worker)))
        events.append("mutation-observed")

        let verification = try BuilderStageContext(
            contract: contract, node: node, attempt: 1, stage: .verification)
        let verificationBaseline = try await source.prepare(verification)
        let verifier = BuilderVerifierReceipt(
            scope: .node(nodeID), provider: "reviewer", model: "model-b",
            deterministic: true, passed: true,
            checks: [.init(name: "deterministic route verification", passed: true)],
            verificationSubject: workspace.rootPath,
            baselineDigest: buildObservation.workspaceDigestBefore,
            subjectDigest: buildObservation.workspaceDigestAfter,
            contractFingerprint: try contract.fingerprint(), completionMode: .build,
            verifiedAt: Date())
        let verificationObservation = try await source.observe(.init(
            context: verification, baseline: verificationBaseline,
            subject: .verification(worker, verifier)))
        events.append("verified")
        XCTAssertEqual(try Data(contentsOf: target), original, file: file, line: line)

        try await source.commit(
            context: build, verifiedWorkspaceDigest: verificationObservation.workspaceDigestAfter)
        events.append("promoted-pending-review")
        try await source.markReviewApproved(context: build)
        events.append("review-approved")
        try await source.finalize(context: build)
        try await source.verifyFinalized(context: build)
        events.append("finalized")
        XCTAssertEqual(try Data(contentsOf: target), changed, file: file, line: line)
        XCTAssertEqual(events, [
            "sealed-preflight", "workspace-issued", "staged-mutation", "mutation-observed",
            "verified", "promoted-pending-review", "review-approved", "finalized",
        ], file: file, line: line)

        let hiddenFixture = try root(adapter.rawValue + "-hidden")
        let hiddenTarget = hiddenFixture.project.appendingPathComponent("Sources/Target.swift")
        try FileManager.default.createDirectory(
            at: hiddenTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: hiddenTarget)
        let hiddenPlan = try KistRunner.builderParsePreflightPlan(
            json(adapter: adapter.rawValue), adapter: adapter,
            projectRoot: hiddenFixture.project.path, maxPartitions: 2)
        let hiddenContract = try executionContract(
            adapter: adapter, plan: hiddenPlan, nodeID: nodeID,
            contractID: contractID + "-hidden")
        let hiddenSource = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: hiddenFixture.project, stagingBase: hiddenFixture.staging,
            attestor: EnforcedTestAttestor())
        let hiddenContext = try BuilderStageContext(
            contract: hiddenContract, node: node, attempt: 1, stage: .build)
        let hiddenBaseline = try await hiddenSource.prepare(hiddenContext)
        let hiddenWorkspace = try await hiddenSource.executionWorkspace(for: hiddenContext)
        let hiddenRoot = URL(fileURLWithPath: hiddenWorkspace.rootPath)
        try changed.write(to: hiddenRoot.appendingPathComponent("Sources/Target.swift"))
        try Data("undeclared".utf8).write(to: hiddenRoot.appendingPathComponent("undeclared.txt"))
        do {
            _ = try await hiddenSource.observe(.init(
                context: hiddenContext, baseline: hiddenBaseline,
                subject: .execution(worker)))
            XCTFail("\(adapter.rawValue) accepted an undeclared staged path", file: file, line: line)
        } catch {
            XCTAssertEqual(try Data(contentsOf: hiddenTarget), original, file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: hiddenFixture.project.appendingPathComponent("undeclared.txt").path),
                file: file, line: line)
        }
    }

    func testHeadlessRouteStagesVerifiesReviewsAndRollsBackHiddenMutation() async throws {
        try await assertRoute(.headless)
    }

    func testPlanExecuteRouteStagesVerifiesReviewsAndRollsBackHiddenMutation() async throws {
        try await assertRoute(.planExecute)
    }

    func testFleetRouteUsesDisjointPlanAndRollsBackHiddenMutation() async throws {
        try await assertRoute(.fleet)
        let fixture = try root("fleet-overlap")
        let target = fixture.project.appendingPathComponent("Sources/Target.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: target)
        let overlap = #"{"schema_version":1,"adapter":"fleet","operations":[{"kind":"modify","path":"Sources/Target.swift"}],"verification_commands":[{"executable":"swift","arguments":["test"],"timeout_seconds":120}],"partitions":[{"id":"a","paths":["Sources/Target.swift"]},{"id":"b","paths":["Sources/Target.swift"]}]}"#
        XCTAssertThrowsError(try KistRunner.builderParsePreflightPlan(
            overlap, adapter: .fleet, projectRoot: fixture.project.path, maxPartitions: 2))
    }

    func testFleetWorkerInvocationAndReceiptRouteUseCoderNotPlanner() {
        let planner = ProviderBinding(providerId: "codex-cli", model: "gpt-5.6-sol")
        let coder = ProviderBinding(providerId: "claude-cli", model: nil)
        let route = KistRunner.builderFleetWorkerRoute(
            builder: coder, resolvedModel: "sonnet")

        XCTAssertEqual(route.providerID, "claude-cli")
        XCTAssertEqual(route.modelID, "sonnet")
        XCTAssertNotEqual(route.providerID, planner.providerId)
        XCTAssertNotEqual(route.modelID, planner.model)

        let explicitCoder = KistRunner.builderFleetWorkerRoute(
            builder: ProviderBinding(providerId: "claude-cli", model: "opus"),
            resolvedModel: "sonnet")
        XCTAssertEqual(explicitCoder.providerID, "claude-cli")
        XCTAssertEqual(explicitCoder.modelID, "opus")
    }

    func testMissionRouteStagesVerifiesReviewsAndRollsBackHiddenMutation() async throws {
        try await assertRoute(.mission)
    }

    func testGreatLoopRouteStagesVerifiesReviewsAndRollsBackHiddenMutation() async throws {
        try await assertRoute(.greatLoop)
    }

    func testCoboloRouteStagesVerifiesReviewsAndRollsBackHiddenMutation() async throws {
        try await assertRoute(.cobolo)
    }

    func testImplicitHeadlessBuildGetsOnlyItsSealedCreateCapability() async throws {
        let fixture = try root("implicit-headless-create")
        let goal = "Create RESULT.txt"
        let options = KistOptions.parse([goal])
        XCTAssertTrue(KistRunner.builderRunRequired(for: options, goal: goal))
        let launch = KistRunner.builderCompatibilityLaunch(for: options, goal: goal)
        XCTAssertEqual(launch.adapter, .headless)
        XCTAssertTrue(launch.mutationIntent)

        let raw = #"{"schema_version":1,"adapter":"headless","operations":[{"kind":"create","path":"RESULT.txt"}],"verification_commands":[{"executable":"python3","arguments":["-c","from pathlib import Path; assert Path('RESULT.txt').read_text() == 'HEADLESS_OK\\n'"],"timeout_seconds":30}],"partitions":[]}"#
        let plan = try KistRunner.builderParsePreflightPlan(
            raw, adapter: .headless, projectRoot: fixture.project.path, maxPartitions: 1)
        let envelope = try KistRunner.BuilderPreflightEnvelope(
            builderContractID: "implicit-headless", goal: goal,
            projectRoot: fixture.project.path, plan: plan)
        try envelope.validate(
            builderContractID: "implicit-headless", goal: goal,
            projectRoot: fixture.project.path)

        let scoped = KistRunner.builderScopedHeadlessTools(
            from: ToolRegistry([
                ReadFileTool(), WriteFileTool(), EditFileTool(), ApplyPatchTool(), CommandStub(),
            ]),
            sealedPlan: envelope.plan)
        XCTAssertTrue(scoped.names.contains("read_file"))
        XCTAssertTrue(scoped.names.contains("write_file"))
        XCTAssertFalse(scoped.names.contains("edit_file"))
        XCTAssertFalse(scoped.names.contains("apply_patch"))
        XCTAssertTrue(scoped.names.contains("run_command"))

        let context = ToolContext(projectRoot: fixture.project.path)
        let accepted = await scoped.execute(
            name: "write_file",
            arguments: ["path": "RESULT.txt", "content": "HEADLESS_OK\n"],
            context: context)
        XCTAssertTrue(accepted.success, accepted.error ?? accepted.output)
        XCTAssertEqual(
            try String(contentsOf: fixture.project.appendingPathComponent("RESULT.txt"), encoding: .utf8),
            "HEADLESS_OK\n")

        let denied = await scoped.execute(
            name: "write_file",
            arguments: ["path": "outside.txt", "content": "forbidden\n"],
            context: context)
        XCTAssertFalse(denied.success)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.project.appendingPathComponent("outside.txt").path))

        let verified = await scoped.execute(
            name: "run_command",
            arguments: [
                "executable": "python3",
                "args": ["-c", "from pathlib import Path; assert Path('RESULT.txt').read_text() == 'HEADLESS_OK\\n'"],
                "cwd": ".", "timeout": 30, "allowed_exit_codes": [0],
            ],
            context: context)
        XCTAssertTrue(verified.success)
        let unsealedCommand = await scoped.execute(
            name: "run_command",
            arguments: [
                "executable": "python3", "args": ["-c", "print('not sealed')"],
                "cwd": ".", "timeout": 30, "allowed_exit_codes": [0],
            ],
            context: context)
        XCTAssertFalse(unsealedCommand.success)
    }

    func testStoppedUnverifiedHeadlessHandsOffOnlyWithSealedMutationAndVerifier() throws {
        let fixture = try root("headless-verification-handoff")
        let target = fixture.project.appendingPathComponent("Sources/Target.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("let value = 1\n".utf8).write(to: target)
        let plan = try KistRunner.builderParsePreflightPlan(
            json(adapter: "headless"), adapter: .headless,
            projectRoot: fixture.project.path, maxPartitions: 1)
        let stopped = HeadlessAgentLoop.Outcome(
            success: false, summary: "unverified", iterations: 4,
            checkpointId: "checkpoint", terminalStatus: .stoppedUnverified)

        XCTAssertFalse(stopped.success, "generic headless behavior must remain fail-closed")
        XCTAssertTrue(KistRunner.builderHeadlessCanHandOffToDeterministicVerification(
            outcome: stopped, sealedPlan: plan))
        XCTAssertFalse(KistRunner.builderHeadlessCanHandOffToDeterministicVerification(
            outcome: stopped, sealedPlan: nil))
        XCTAssertFalse(KistRunner.builderHeadlessCanHandOffToDeterministicVerification(
            outcome: .init(
                success: false, summary: "provider failed", iterations: 1,
                checkpointId: "failed"),
            sealedPlan: plan))

        let binding = KistRunner.builderHeadlessExecutionBinding(
            builder: .init(providerId: "codex-cli", model: "gpt-5.3-codex"),
            resolvedModel: "driver-model")
        XCTAssertEqual(binding.providerId, "codex-cli")
        XCTAssertEqual(binding.model, "gpt-5.3-codex")
    }

    func testStoppedUnverifiedHeadlessRunsSealedVerifierAndBindsTrustedEvidence() async throws {
        #if os(macOS)
        let fixture = try root("headless-real-verifier")
        let target = fixture.project.appendingPathComponent("result.txt")
        try Data("OLD\n".utf8).write(to: target)
        try Data("from pathlib import Path\nraise SystemExit(0 if Path('result.txt').read_bytes() == b'NEW\\n' else 9)\n".utf8)
            .write(to: fixture.project.appendingPathComponent("test_result.py"))
        let raw = #"{"schema_version":1,"adapter":"headless","operations":[{"kind":"modify","path":"result.txt"}],"verification_commands":[{"executable":"python3","arguments":["test_result.py"],"timeout_seconds":30}],"partitions":[]}"#
        let plan = try KistRunner.builderParsePreflightPlan(
            raw, adapter: .headless, projectRoot: fixture.project.path, maxPartitions: 1)
        let nodeID = KistRunner.builderPlannedExecutionNodeID(for: .headless)
        let node = BuilderNode(
            id: nodeID, objective: "replace result",
            resources: [.init(path: "result.txt", access: .write)],
            isolation: .sandbox, role: .builder, retryLimit: 0)
        let contract = try executionContract(
            adapter: .headless, plan: plan, nodeID: nodeID,
            contractID: "headless-real-verifier")
        let stopped = HeadlessAgentLoop.Outcome(
            success: false, summary: "model stopped without running tests", iterations: 4,
            checkpointId: "checkpoint", terminalStatus: .stoppedUnverified)
        XCTAssertTrue(KistRunner.builderHeadlessCanHandOffToDeterministicVerification(
            outcome: stopped, sealedPlan: plan))

        let result = try await governedHeadlessAttempt(
            project: fixture.project,
            staging: fixture.staging,
            plan: plan,
            node: node,
            contract: contract)
        guard case .accepted(_, let proof, _, _) = result else {
            return XCTFail("governed stopped-unverified handoff was not accepted: \(result)")
        }

        XCTAssertTrue(proof.passed)
        XCTAssertEqual(proof.commandEvidence?.count, 1)
        XCTAssertTrue(proof.commandEvidence?.allSatisfy {
            $0.trustedCommandReference?.isValid == true
                && $0.isBound(
                    contractFingerprint: try! contract.fingerprint(),
                    subjectDigest: proof.subjectDigest ?? "")
        } == true)
        XCTAssertEqual(try Data(contentsOf: target), Data("OLD\n".utf8),
                       "node verification alone must not promote staged mutations")
        #else
        throw XCTSkip("OS-level Builder sandbox verification is macOS-only")
        #endif
    }

    func testStoppedUnverifiedHeadlessVerifierFailureRollsBackWithoutPromotion() async throws {
        #if os(macOS)
        let fixture = try root("headless-failed-verifier")
        let target = fixture.project.appendingPathComponent("result.txt")
        let original = Data("OLD\n".utf8)
        try original.write(to: target)
        try Data("raise SystemExit(9)\n".utf8)
            .write(to: fixture.project.appendingPathComponent("test_result.py"))
        let raw = #"{"schema_version":1,"adapter":"headless","operations":[{"kind":"modify","path":"result.txt"}],"verification_commands":[{"executable":"python3","arguments":["test_result.py"],"timeout_seconds":30}],"partitions":[]}"#
        let plan = try KistRunner.builderParsePreflightPlan(
            raw, adapter: .headless, projectRoot: fixture.project.path, maxPartitions: 1)
        let nodeID = KistRunner.builderPlannedExecutionNodeID(for: .headless)
        let node = BuilderNode(
            id: nodeID, objective: "replace result",
            resources: [.init(path: "result.txt", access: .write)],
            isolation: .sandbox, role: .builder, retryLimit: 0)
        let contract = try executionContract(
            adapter: .headless, plan: plan, nodeID: nodeID,
            contractID: "headless-failed-verifier")
        let result = try await governedHeadlessAttempt(
            project: fixture.project,
            staging: fixture.staging,
            plan: plan,
            node: node,
            contract: contract)
        guard case .terminal(_, let detail) = result else {
            return XCTFail("failing sealed verifier was not terminal after rollback: \(result)")
        }
        XCTAssertTrue(detail.contains("exit code 9"), detail)
        XCTAssertFalse(detail.contains("sandbox_apply"), detail)
        XCTAssertFalse(detail.contains("exit code 71"), detail)
        XCTAssertEqual(try Data(contentsOf: target), original)
        #else
        throw XCTSkip("OS-level Builder sandbox verification is macOS-only")
        #endif
    }

    func testOnlyMutationNodesReceiveOneBoundedNoOpRetry() throws {
        let adapters: [KistRunner.BuilderCompatibilityAdapter] = [
            .headless, .greatLoop, .planExecute, .fleet, .mission, .cobolo,
        ]
        for adapter in adapters {
            let fixture = try root("retry-\(adapter.rawValue)")
            let target = fixture.project.appendingPathComponent("Sources/Target.swift")
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("let value = 1\n".utf8).write(to: target)
            let plan = try KistRunner.builderParsePreflightPlan(
                json(adapter: adapter.rawValue), adapter: adapter,
                projectRoot: fixture.project.path, maxPartitions: 2)
            let graph = try KistRunner.builderPlannedGraph(
                adapter: adapter, goal: "mutate target", plan: plan)
            let executionIDs = KistRunner.builderPlannedExecutionNodeIDs(
                for: adapter, plan: plan)
            for node in graph.nodes {
                XCTAssertEqual(node.retryLimit, executionIDs.contains(node.id) ? 1 : 0,
                               "\(adapter.rawValue):\(node.id)")
            }
        }
        let original = "create exact file"
        XCTAssertEqual(
            KistRunner.builderBoundedMutationAttemptGoal(original, attempt: 1), original)
        let retry = KistRunner.builderBoundedMutationAttemptGoal(original, attempt: 2)
        XCTAssertTrue(retry.contains(original))
        XCTAssertTrue(retry.contains("attempt 2 of 2"))
        XCTAssertTrue(retry.contains("same sealed operations"))
        XCTAssertTrue(retry.contains("Do not widen"))
    }

    func testGovernedBuildCommandUsesOnlyAuthoritativeBuilderSandbox() async throws {
        #if os(macOS)
        let fixture = try root("governed-build-command")
        let target = fixture.project.appendingPathComponent("result.txt")
        let external = fixture.base.appendingPathComponent("outside.txt")
        try Data("OLD\n".utf8).write(to: target)
        try Data("from pathlib import Path\nraise SystemExit(0 if Path('result.txt').read_bytes() == b'NEW\\n' else 9)\n".utf8)
            .write(to: fixture.project.appendingPathComponent("test_result.py"))
        let raw = #"{"schema_version":1,"adapter":"headless","operations":[{"kind":"modify","path":"result.txt"}],"verification_commands":[{"executable":"python3","arguments":["test_result.py"],"timeout_seconds":30}],"partitions":[]}"#
        let plan = try KistRunner.builderParsePreflightPlan(
            raw, adapter: .headless, projectRoot: fixture.project.path, maxPartitions: 1)
        let nodeID = KistRunner.builderPlannedExecutionNodeID(for: .headless)
        let node = BuilderNode(
            id: nodeID, objective: "run a governed build command",
            resources: [.init(path: "result.txt", access: .write)],
            isolation: .sandbox, role: .builder, retryLimit: 0)
        let contract = try executionContract(
            adapter: .headless, plan: plan, nodeID: nodeID,
            contractID: "governed-build-command")
        let script = """
        from pathlib import Path
        import socket
        import sys
        Path("result.txt").write_text("NEW\\n")
        try:
            Path(sys.argv[1]).write_text("ESCAPE\\n")
        except OSError:
            pass
        else:
            raise SystemExit(42)
        try:
            probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            probe.bind(("127.0.0.1", 0))
        except OSError:
            pass
        else:
            probe.close()
            raise SystemExit(43)
        print("builder-sandbox-ok")
        """
        try Data(script.utf8).write(
            to: fixture.project.appendingPathComponent("build_probe.py"))

        let result = try await governedHeadlessAttempt(
            project: fixture.project,
            staging: fixture.staging,
            plan: plan,
            node: node,
            contract: contract,
            buildProbe: { _, context in
                guard !context.sandbox.enabled else {
                    throw BuilderRunError.invalidConfiguration(
                        "governed build retained the redundant generic sandbox")
                }
                let command = try await RunCommandTool().execute(
                    arguments: [
                        "executable": "python3",
                        "args": ["build_probe.py", external.path],
                        "timeout": 30,
                    ],
                    context: context)
                guard command.success else {
                    throw BuilderRunError.finalVerificationFailed(
                        command.error ?? command.output)
                }
                guard command.output.contains("builder-sandbox-ok"),
                      command.metadata["sandboxed"] == "false",
                      command.metadata["builder_os_sandboxed"] == "true" else {
                    throw BuilderRunError.finalVerificationFailed(
                        "governed command evidence did not identify the authoritative Builder sandbox")
                }
            })
        guard case .accepted = result else {
            return XCTFail("governed build command was not accepted: \(result)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path),
                       "the inherited Builder sandbox allowed an external write")
        XCTAssertEqual(try Data(contentsOf: target), Data("OLD\n".utf8),
                       "node acceptance must remain pre-publication")
        #else
        throw XCTSkip("OS-level Builder sandbox verification is macOS-only")
        #endif
    }

    func testReadOnlyProseCannotForgeMutationAuthority() {
        let goal = "Explain how to create RESULT.txt, read-only; do not change any files"
        let options = KistOptions.parse([goal])
        XCTAssertFalse(KistRunner.builderRunRequired(for: options, goal: goal))
        let launch = KistRunner.builderCompatibilityLaunch(for: options, goal: goal)
        XCTAssertFalse(launch.mutationIntent)
        let scoped = KistRunner.builderScopedHeadlessTools(
            from: ToolRegistry([
                ReadFileTool(), WriteFileTool(), EditFileTool(), ApplyPatchTool(), CommandStub(),
            ]),
            sealedPlan: nil)
        XCTAssertEqual(scoped.names, ["read_file"])
    }

    func testFleetHelpDescribesAggregateFilesystemStagingNotGitWorktrees() {
        XCTAssertTrue(KistOptions.helpText.contains("isolated staged"))
        XCTAssertTrue(KistOptions.helpText.contains("No Git repo required"))
        XCTAssertFalse(KistOptions.helpText.contains("OWN git"))
    }
}
