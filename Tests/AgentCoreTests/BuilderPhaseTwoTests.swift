import XCTest
@testable import AgentCore

final class BuilderPhaseTwoTests: XCTestCase {
    private func assertAsyncThrows<T>(
        _ body: () async throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected async operation to throw", file: file, line: line)
        } catch {}
    }

    private func assertAsyncNoThrow<T>(
        _ body: () async throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do { _ = try await body() }
        catch { XCTFail("Unexpected async error: \(error)", file: file, line: line) }
    }

    private func digest(_ value: Character) -> String {
        String(repeating: String(value), count: 64)
    }

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("builder-phase-two-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func contract(toolLimit: Int = 20, tokenLimit: Int = 10_000,
                          timeLimit: Int = 60) throws -> BuilderExecutionContract {
        let total = try BuilderResourceBudget(
            maxToolCalls: toolLimit, maxTokens: tokenLimit, maxWallTimeSeconds: timeLimit)
        let stages = try [BuilderExecutionStage.build, .verification, .review].map {
            BuilderStageBudget(stage: $0, limit: try BuilderResourceBudget(
                maxToolCalls: toolLimit, maxTokens: tokenLimit, maxWallTimeSeconds: timeLimit))
        }
        let criteria = [
            try BuilderStageCriterion(id: "build", stage: .build, kind: .artifactDigest,
                                      statement: "Mutation is digest-bound."),
            try BuilderStageCriterion(id: "verify", stage: .verification,
                                      kind: .deterministicCommand,
                                      statement: "Deterministic verification passes."),
            try BuilderStageCriterion(id: "review", stage: .review, kind: .modelJudgment,
                                      statement: "Independent review accepts."),
        ]
        return try BuilderExecutionContract(
            builderContractID: "builder-1", builderNodeID: "build",
            mutations: [BuilderMutationOperation(
                kind: .modify, path: "Sources/App.swift", preimageSHA256: digest("a"))],
            criteria: criteria,
            budgets: BuilderBudgetPolicy(total: total, stages: stages),
            identities: BuilderIdentityPlan(
                producers: [BuilderModelIdentity(providerID: "anthropic", modelID: "builder")],
                reviewers: [BuilderModelIdentity(providerID: "openai", modelID: "reviewer")]),
            lineage: BuilderLineageEnvelope())
    }

    private func trustedBudgetObservations(
        _ count: Int,
        contract: BuilderExecutionContract,
        stage: BuilderExecutionStage = .build,
        time: Int = 0
    ) async throws -> [BuilderTrustedBudgetObservation] {
        let binding = try BuilderTrustedTelemetryBinding(
            contractFingerprint: contract.fingerprint(), nodeID: "build",
            attempt: 1, stage: stage)
        let (_, telemetry) = try await BuilderTrustedTelemetry.withScope(binding: binding) {
            for index in 0..<count {
                BuilderTrustedTelemetry.recordTool(
                    name: "shell", argumentsDigest: String(repeating: "a", count: 64),
                    success: true, elapsedMilliseconds: time + index)
            }
        }
        return try telemetry.compactMap { try $0.accountableBudgetObservation() }
    }

    private func baseline(_ contract: BuilderExecutionContract,
                          stage: BuilderExecutionStage = .build,
                          workspace: Character = "b", warnings: [String] = []) throws -> BuilderStageBaseline {
        try BuilderStageBaseline(
            contractFingerprint: contract.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: 1, stage: stage, workspaceDigest: digest(workspace),
            pathStates: stage == .build
                ? [BuilderObservedPathState(path: "Sources/App.swift", digest: digest("a"))] : [],
            warnings: warnings)
    }

    private func stageObservation(_ contract: BuilderExecutionContract,
                                  baseline: BuilderStageBaseline,
                                  warning: String? = nil) throws -> BuilderStageObservation {
        let isBuild = baseline.stage == .build
        let criterionID = baseline.stage == .verification ? "verify" : baseline.stage.rawValue
        let role: BuilderObservedIdentityRole = isBuild ? .producer : .reviewer
        let identity = isBuild ? contract.identities.producers[0] : contract.identities.reviewers[0]
        return try BuilderStageObservation(
            contractFingerprint: contract.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: 1, stage: baseline.stage,
            workspaceDigestBefore: baseline.workspaceDigest,
            workspaceDigestAfter: isBuild ? digest("c") : baseline.workspaceDigest,
            operations: isBuild ? [BuilderObservedMutation(
                kind: .modify, path: "Sources/App.swift",
                preimageSHA256: digest("a"), postimageSHA256: digest("c"))] : [],
            criteria: [BuilderCriterionObservation(
                criterionID: criterionID, passed: true, evidenceDigest: digest("d"))],
            identities: [.init(role: role, identity: identity)], lineage: contract.lineage,
            baselineWarnings: baseline.warnings,
            currentWarnings: baseline.warnings + (warning.map { [$0] } ?? []))
    }

    func testBudgetLedgerRecordsTrustedUsageDurably() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try contract()
        let file = root.appendingPathComponent("budget.json")
        let ledger = try BuilderBudgetLedger(fileURL: file, contract: value)
        for observation in try await trustedBudgetObservations(2, contract: value) {
            _ = try await ledger.record(observation)
        }
        let reopened = try BuilderBudgetLedger(fileURL: file, contract: value)
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.total.toolCalls, 2)
        XCTAssertEqual(snapshot.sequence, 2)
    }

    func testBudgetLedgerConcurrentObservationsAreNotLost() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try contract(toolLimit: 100)
        let ledger = try BuilderBudgetLedger(fileURL: root.appendingPathComponent("budget.json"), contract: value)
        let observations = try await trustedBudgetObservations(20, contract: value)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for observation in observations {
                group.addTask {
                    _ = try await ledger.record(observation)
                }
            }
            try await group.waitForAll()
        }
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.total.toolCalls, 20)
    }

    func testBudgetLedgerDuplicateIsIdempotentAndConflictFails() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try contract()
        let ledger = try BuilderBudgetLedger(fileURL: root.appendingPathComponent("budget.json"), contract: value)
        let minted = try await trustedBudgetObservations(1, contract: value)
        let first = try XCTUnwrap(minted.first)
        _ = try await ledger.record(first)
        _ = try await ledger.record(first)
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.total.toolCalls, 1)
        await assertAsyncThrows {
            let forged = try BuilderTrustedBudgetObservation(
                id: first.id, contractFingerprint: value.fingerprint(), nodeID: "build",
                attempt: 1, stage: .build, source: .tool("shell"), toolCalls: 2)
            try await ledger.record(forged)
        }
    }

    func testBudgetLedgerPersistsTotalBreachAcrossRestart() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try contract(toolLimit: 1)
        let file = root.appendingPathComponent("budget.json")
        let ledger = try BuilderBudgetLedger(fileURL: file, contract: value)
        let over = try await trustedBudgetObservations(2, contract: value)
        _ = try await ledger.record(over[0])
        await assertAsyncThrows {
            try await ledger.record(over[1])
        }
        let reopened = try BuilderBudgetLedger(fileURL: file, contract: value)
        let laterMinted = try await trustedBudgetObservations(1, contract: value)
        let later = try XCTUnwrap(laterMinted.first)
        await assertAsyncThrows {
            try await reopened.record(later)
        }
        let snapshot = try await reopened.snapshot()
        XCTAssertNotNil(snapshot.breach)
    }

    func testBudgetLedgerRejectsTamperedCanonicalFile() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try contract(); let file = root.appendingPathComponent("budget.json")
        _ = try await BuilderBudgetLedger(fileURL: file, contract: value).snapshot()
        var bytes = try Data(contentsOf: file); bytes.append(0x20)
        try bytes.write(to: file)
        let reopened = try BuilderBudgetLedger(fileURL: file, contract: value)
        await assertAsyncThrows { try await reopened.snapshot() }
    }

    func testBudgetObservationRejectsReceiptLikeNegativeAndUnboundValues() throws {
        let value = try contract()
        XCTAssertThrowsError(try BuilderTrustedBudgetObservation(
            id: "bad", contractFingerprint: value.fingerprint(), nodeID: "build", attempt: 1,
            stage: .build, source: .clock, tokens: 100, wallTimeMilliseconds: 1))
        XCTAssertThrowsError(try BuilderTrustedBudgetObservation(
            id: "bad", contractFingerprint: value.fingerprint(), nodeID: "build", attempt: 0,
            stage: .build, source: .tool("shell"), toolCalls: 1))
    }

    func testContractVerifierAcceptsExactBoundMutation() throws {
        let value = try contract(); let base = try baseline(value)
        XCTAssertNoThrow(try BuilderContractVerifier().verify(
            contract: value, baseline: base, observation: stageObservation(value, baseline: base)))
    }

    func testContractVerifierAcceptsDeterministicCommandOnlyVerification() throws {
        let value = try contract()
        let base = try baseline(value, stage: .verification)
        let observation = try BuilderStageObservation(
            contractFingerprint: value.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: 1, stage: .verification,
            workspaceDigestBefore: base.workspaceDigest,
            workspaceDigestAfter: base.workspaceDigest,
            operations: [],
            criteria: [BuilderCriterionObservation(
                criterionID: "verify", passed: true, evidenceDigest: digest("d"))],
            identities: [], lineage: value.lineage)

        XCTAssertNoThrow(try BuilderContractVerifier().verify(
            contract: value, baseline: base, observation: observation))
    }

    func testContractVerifierRejectsUndeclaredModelTelemetryDuringVerification() throws {
        let value = try contract()
        let base = try baseline(value, stage: .verification)
        let undeclared = try BuilderModelIdentity(
            providerID: "google", modelID: "undeclared-reviewer")
        let observation = try BuilderStageObservation(
            contractFingerprint: value.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: 1, stage: .verification,
            workspaceDigestBefore: base.workspaceDigest,
            workspaceDigestAfter: base.workspaceDigest,
            operations: [],
            criteria: [BuilderCriterionObservation(
                criterionID: "verify", passed: true, evidenceDigest: digest("d"))],
            identities: [.init(role: .reviewer, identity: undeclared)],
            lineage: value.lineage)

        XCTAssertThrowsError(try BuilderContractVerifier().verify(
            contract: value, baseline: base, observation: observation)) { error in
            XCTAssertEqual(
                error as? BuilderContractVerifierError,
                .identityMismatch(BuilderObservedIdentityRole.reviewer.rawValue))
        }
    }

    func testContractVerifierStillRequiresModelIdentityDuringReview() throws {
        let value = try contract()
        let base = try baseline(value, stage: .review)
        let observation = try BuilderStageObservation(
            contractFingerprint: value.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: 1, stage: .review,
            workspaceDigestBefore: base.workspaceDigest,
            workspaceDigestAfter: base.workspaceDigest,
            operations: [],
            criteria: [BuilderCriterionObservation(
                criterionID: "review", passed: true, evidenceDigest: digest("d"))],
            identities: [], lineage: value.lineage)

        XCTAssertThrowsError(try BuilderContractVerifier().verify(
            contract: value, baseline: base, observation: observation)) { error in
            XCTAssertEqual(
                error as? BuilderContractVerifierError,
                .identityMismatch(BuilderObservedIdentityRole.reviewer.rawValue))
        }
    }

    func testContractVerifierRejectsMutationPreimageMismatch() throws {
        let value = try contract(); let base = try baseline(value)
        let bad = try BuilderStageObservation(
            contractFingerprint: value.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: 1, stage: .build,
            workspaceDigestBefore: base.workspaceDigest, workspaceDigestAfter: digest("c"),
            operations: [BuilderObservedMutation(kind: .modify, path: "Sources/App.swift",
                preimageSHA256: digest("e"), postimageSHA256: digest("c"))],
            criteria: [BuilderCriterionObservation(
                criterionID: "build", passed: true, evidenceDigest: digest("d"))],
            identities: [.init(role: .producer, identity: value.identities.producers[0])],
            lineage: value.lineage)
        XCTAssertThrowsError(try BuilderContractVerifier().verify(
            contract: value, baseline: base, observation: bad))
    }

    func testContractVerifierRejectsMissingCriterionAndWrongIdentity() throws {
        let value = try contract(); let base = try baseline(value)
        let bad = try BuilderStageObservation(
            contractFingerprint: value.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: 1, stage: .build,
            workspaceDigestBefore: base.workspaceDigest, workspaceDigestAfter: digest("c"),
            operations: [BuilderObservedMutation(kind: .modify, path: "Sources/App.swift",
                preimageSHA256: digest("a"), postimageSHA256: digest("c"))],
            criteria: [], identities: [.init(role: .reviewer, identity: value.identities.reviewers[0])],
            lineage: value.lineage)
        XCTAssertThrowsError(try BuilderContractVerifier().verify(
            contract: value, baseline: base, observation: bad))
    }

    func testContractVerifierRejectsNewWarningButAllowsBaselineWarning() throws {
        let value = try contract(); let base = try baseline(value, warnings: ["existing"])
        XCTAssertNoThrow(try BuilderContractVerifier().verify(
            contract: value, baseline: base,
            observation: stageObservation(value, baseline: base)))
        XCTAssertThrowsError(try BuilderContractVerifier().verify(
            contract: value, baseline: base,
            observation: stageObservation(value, baseline: base, warning: "new warning")))
    }

    func testContractVerifierRejectsLineageSubstitution() throws {
        let value = try contract(); let base = try baseline(value)
        let substituted = try BuilderLineageEnvelope(captainDecisionDigest: digest("f"))
        let good = try stageObservation(value, baseline: base)
        let bad = try BuilderStageObservation(
            contractFingerprint: good.contractFingerprint, builderContractID: good.builderContractID,
            nodeID: good.nodeID, attempt: good.attempt, stage: good.stage,
            workspaceDigestBefore: good.workspaceDigestBefore,
            workspaceDigestAfter: good.workspaceDigestAfter, operations: good.operations,
            criteria: good.criteria, identities: good.identities, lineage: substituted)
        XCTAssertThrowsError(try BuilderContractVerifier().verify(
            contract: value, baseline: base, observation: bad))
    }

    func testRollbackVerifierRequiresExactPathsAndRetainsActualWorkspaceDigest() throws {
        let value = try contract(); let base = try baseline(value)
        let good = try BuilderRollbackObservation(
            contractFingerprint: value.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: 1, workspaceDigestAfter: base.workspaceDigest,
            restoredPathStates: base.pathStates)
        XCTAssertNoThrow(try BuilderContractVerifier().verifyRollback(
            contract: value, baseline: base, observation: good))
        let driftPreserved = try BuilderRollbackObservation(
            contractFingerprint: value.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: 1, workspaceDigestAfter: digest("e"),
            restoredPathStates: base.pathStates)
        XCTAssertNoThrow(try BuilderContractVerifier().verifyRollback(
            contract: value, baseline: base, observation: driftPreserved))
        let wrongPath = try BuilderRollbackObservation(
            contractFingerprint: value.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: 1, workspaceDigestAfter: digest("e"),
            restoredPathStates: [BuilderObservedPathState(
                path: "Sources/App.swift", digest: digest("f"))])
        XCTAssertThrowsError(try BuilderContractVerifier().verifyRollback(
            contract: value, baseline: base, observation: wrongPath))
    }

    func testCheckpointStoreEnforcesMonotonicLifecycle() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try contract(); let store = try BuilderPipelineCheckpointStore(directoryURL: root, contract: value)
        _ = try await store.prepare(nodeID: "build", attempt: 1, baseline: baseline(value))
        _ = try await store.transition(nodeID: "build", attempt: 1, to: .running,
                                       currentWorkspaceDigest: digest("b"))
        _ = try await store.transition(nodeID: "build", attempt: 1, to: .verifying,
                                       currentWorkspaceDigest: digest("c"))
        _ = try await store.transition(nodeID: "build", attempt: 1, to: .committed,
                                       currentWorkspaceDigest: digest("c"))
        let loaded = try await store.load(nodeID: "build")
        XCTAssertEqual(loaded?.phase, .committed)
    }

    func testCheckpointStoreRejectsBackwardAndSkippedTransitions() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try contract(); let store = try BuilderPipelineCheckpointStore(directoryURL: root, contract: value)
        _ = try await store.prepare(nodeID: "build", attempt: 1, baseline: baseline(value))
        await assertAsyncThrows {
            try await store.transition(
                nodeID: "build", attempt: 1, to: .committed,
                currentWorkspaceDigest: self.digest("c"))
        }
        _ = try await store.transition(nodeID: "build", attempt: 1, to: .running,
                                       currentWorkspaceDigest: digest("b"))
        await assertAsyncThrows {
            try await store.transition(
                nodeID: "build", attempt: 1, to: .prepared,
                currentWorkspaceDigest: self.digest("b"))
        }
    }

    func testCheckpointAllowsFinalizedRollbackBeforeEvidenceRelease() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try contract()
        let store = try BuilderPipelineCheckpointStore(directoryURL: root, contract: value)
        _ = try await store.prepare(nodeID: "build", attempt: 1, baseline: baseline(value))
        for phase in [BuilderPipelineCheckpointPhase.running, .verifying, .committed,
                      .reviewApproved, .finalized, .rollingBack, .rolledBack] {
            _ = try await store.transition(
                nodeID: "build", attempt: 1, to: phase,
                currentWorkspaceDigest: digest("c"))
        }
        let rolledBack = try await store.load(nodeID: "build")
        XCTAssertEqual(rolledBack?.phase, .rolledBack)
    }

    func testCheckpointStorePersistsCrashStateAndRejectsTamper() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try contract(); var store = try BuilderPipelineCheckpointStore(directoryURL: root, contract: value)
        _ = try await store.prepare(nodeID: "build", attempt: 1, baseline: baseline(value))
        _ = try await store.transition(nodeID: "build", attempt: 1, to: .running,
                                       currentWorkspaceDigest: digest("b"))
        store = try BuilderPipelineCheckpointStore(directoryURL: root, contract: value)
        let loaded = try await store.load(nodeID: "build")
        XCTAssertEqual(loaded?.phase, .running)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil).first)
        var bytes = try Data(contentsOf: file); bytes.append(0x0a); try bytes.write(to: file)
        store = try BuilderPipelineCheckpointStore(directoryURL: root, contract: value)
        await assertAsyncThrows { try await store.load(nodeID: "build") }
    }

    func testCheckpointNextAttemptRequiresProvenRollback() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try contract(); let store = try BuilderPipelineCheckpointStore(directoryURL: root, contract: value)
        let first = try baseline(value)
        _ = try await store.prepare(nodeID: "build", attempt: 1, baseline: first)
        await assertAsyncThrows {
            try await store.prepare(nodeID: "build", attempt: 2,
                baseline: BuilderStageBaseline(contractFingerprint: value.fingerprint(),
                    builderContractID: "builder-1", nodeID: "build", attempt: 2, stage: .build,
                    workspaceDigest: self.digest("b"), pathStates: first.pathStates))
        }
        _ = try await store.transition(nodeID: "build", attempt: 1, to: .rollingBack,
                                       currentWorkspaceDigest: digest("b"))
        _ = try await store.transition(nodeID: "build", attempt: 1, to: .rolledBack,
                                       currentWorkspaceDigest: digest("b"))
        let second = try BuilderStageBaseline(
            contractFingerprint: value.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: 2, stage: .build, workspaceDigest: digest("b"),
            pathStates: first.pathStates)
        await assertAsyncNoThrow {
            try await store.prepare(nodeID: "build", attempt: 2, baseline: second)
        }
    }

    func testBuilderRunWithMutationContractFailsClosedWithoutObservationSource() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sealed = try SealedBuilderExecutionContract.issue(contract())
        let builder = BuilderContract(id: "builder-1", objective: "Build",
                                      allowedPaths: ["Sources"], capabilities: ["read", "write"],
                                      doneWhen: ["verified"],
                                      executionContract: sealed)
        let run = try BuilderRun(
            contract: builder,
            graph: BuilderGraph(nodes: [BuilderNode(
                id: "build", objective: "Build",
                resources: [.init(path: "Sources", access: .write)])]),
            store: BuilderJSONStore(fileURL: root.appendingPathComponent("run.json")),
            graphExecutionPolicy: BuilderGraphExecutionPolicy(
                nodeClasses: ["build": .mutation]),
            execute: { _ in XCTFail("execute must not run"); throw PhaseTwoFailure.unused },
            verify: { _ in throw PhaseTwoFailure.unused },
            review: { _ in throw PhaseTwoFailure.unused })
        do { _ = try await run.run(); XCTFail("run must fail closed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("trusted")) }
    }

    func testSyntheticRollbackSourceCannotLaunchMutationOrDependentNode() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let execution = try contract()
        let sealed = try SealedBuilderExecutionContract.issue(execution)
        let source = PhaseTwoSource(contract: execution, injectWarning: true)
        let calls = PhaseTwoCalls()
        let builder = BuilderContract(
            id: "builder-1", objective: "Build", allowedPaths: ["Sources"],
            capabilities: ["read", "write"], doneWhen: ["verified"],
            executionContract: sealed)
        let graph = try BuilderGraph(nodes: [
            BuilderNode(
                id: "build", objective: "Build",
                resources: [.init(path: "Sources", access: .write)], retryLimit: 0),
            BuilderNode(id: "dependent", objective: "Dependent", dependencies: ["build"], retryLimit: 0),
        ])
        do {
            let run = try BuilderRun(
                contract: builder, graph: graph,
                store: BuilderJSONStore(fileURL: root.appendingPathComponent("run.json")),
                graphExecutionPolicy: .init(nodeClasses: [
                    "build": .mutation, "dependent": .readOnly,
                ]),
                stageObservationSource: source,
                execute: { request in
                    await calls.add(request.node.id)
                    return BuilderWorkerReceipt(
                        nodeID: request.node.id, provider: "anthropic", model: "builder",
                        changedPaths: request.node.id == "build" ? ["Sources/App.swift"] : [])
                },
                verify: { request in
                    let nodeID: String
                    switch request {
                    case .node(_, let node, _, _): nodeID = node.id
                    case .final: nodeID = "final"
                    }
                    return BuilderVerifierReceipt(
                        scope: nodeID == "final" ? .final : .node(nodeID),
                        provider: "openai", model: "reviewer", deterministic: true,
                        passed: true,
                        checks: [BuilderCheckReceipt(name: "check", passed: true)])
                },
                review: { _ in throw PhaseTwoFailure.unused })
            _ = try await run.run()
            XCTFail("synthetic mutation evidence must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("trusted"))
        }
        let executed = await calls.values()
        let rollbackCount = await source.rollbackCount()
        XCTAssertTrue(executed.isEmpty)
        XCTAssertEqual(rollbackCount, 0)
    }
}

private enum PhaseTwoFailure: Error { case unused }

private actor PhaseTwoCalls {
    private var calls: [String] = []
    func add(_ value: String) { calls.append(value) }
    func values() -> [String] { calls }
}

private actor PhaseTwoSource: BuilderStageObservationSource {
    let contract: BuilderExecutionContract
    let injectWarning: Bool
    private var rollbacks = 0
    init(contract: BuilderExecutionContract, injectWarning: Bool) {
        self.contract = contract; self.injectWarning = injectWarning
    }
    func rollbackCount() -> Int { rollbacks }

    func prepare(_ context: BuilderStageContext) async throws -> BuilderStageBaseline {
        let workspace: Character = context.stage == .build ? "b" : "c"
        return try BuilderStageBaseline(
            contractFingerprint: contract.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: context.attempt, stage: context.stage,
            workspaceDigest: String(repeating: String(workspace), count: 64),
            pathStates: context.stage == .build
                ? [BuilderObservedPathState(path: "Sources/App.swift",
                    digest: String(repeating: "a", count: 64))] : [])
    }

    func observe(_ request: BuilderStageObservationRequest) async throws -> BuilderStageObservation {
        let build = request.context.stage == .build
        let criterion = request.context.stage == .verification ? "verify" : request.context.stage.rawValue
        return try BuilderStageObservation(
            contractFingerprint: contract.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: request.context.attempt, stage: request.context.stage,
            workspaceDigestBefore: request.baseline.workspaceDigest,
            workspaceDigestAfter: build ? String(repeating: "c", count: 64) : request.baseline.workspaceDigest,
            operations: build ? [BuilderObservedMutation(
                kind: .modify, path: "Sources/App.swift",
                preimageSHA256: String(repeating: "a", count: 64),
                postimageSHA256: String(repeating: "c", count: 64))] : [],
            criteria: [BuilderCriterionObservation(
                criterionID: criterion, passed: true,
                evidenceDigest: String(repeating: "d", count: 64))],
            identities: [.init(role: build ? .producer : .reviewer,
                identity: build ? contract.identities.producers[0] : contract.identities.reviewers[0])],
            lineage: contract.lineage, baselineWarnings: [],
            currentWarnings: injectWarning && build ? ["new warning"] : [])
    }

    func rollback(_ request: BuilderRollbackRequest) async throws -> BuilderRollbackObservation {
        rollbacks += 1
        return try BuilderRollbackObservation(
            contractFingerprint: contract.fingerprint(), builderContractID: "builder-1",
            nodeID: "build", attempt: request.context.attempt,
            workspaceDigestAfter: request.baseline.workspaceDigest,
            restoredPathStates: request.baseline.pathStates)
    }
}
