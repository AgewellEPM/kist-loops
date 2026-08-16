import XCTest
@testable import AgentCore

final class BuilderExecutionContractTests: XCTestCase {
    private enum Unused: Error { case closure }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func budget(stages: [BuilderExecutionStage] = [.build, .verification, .review]) throws -> BuilderBudgetPolicy {
        let total = try BuilderResourceBudget(maxToolCalls: 100, maxTokens: 100_000, maxWallTimeSeconds: 3_600)
        return try BuilderBudgetPolicy(total: total, stages: try stages.map {
            BuilderStageBudget(stage: $0, limit: try BuilderResourceBudget(
                maxToolCalls: 20, maxTokens: 25_000, maxWallTimeSeconds: 900))
        })
    }

    private func identityPlan() throws -> BuilderIdentityPlan {
        try BuilderIdentityPlan(
            producers: [BuilderModelIdentity(providerID: "anthropic", modelID: "claude-builder")],
            reviewers: [BuilderModelIdentity(providerID: "openai", modelID: "gpt-reviewer")])
    }

    private func defaultCriteria() throws -> [BuilderStageCriterion] {
        [try BuilderStageCriterion(id: "build-output", stage: .build, kind: .artifactDigest,
                                   statement: "The declared mutation has a content digest."),
         try BuilderStageCriterion(id: "deterministic-check", stage: .verification,
                                   kind: .deterministicCommand,
                                   statement: "The canonical verification command passes."),
         try BuilderStageCriterion(id: "independent-review", stage: .review,
                                   kind: .modelJudgment,
                                   statement: "A distinct reviewer accepts the verified result.")]
    }

    private func contract(builderContractID: String = "builder-1", nodeID: String = "build",
                          mutations: [BuilderMutationOperation]? = nil,
                          criteria: [BuilderStageCriterion]? = nil,
                          budgets: BuilderBudgetPolicy? = nil,
                          identities: BuilderIdentityPlan? = nil,
                          lineage: BuilderLineageEnvelope? = nil) throws -> BuilderExecutionContract {
        let resolvedMutations = try mutations ?? [BuilderMutationOperation(
            kind: .modify, path: "Sources/App.swift", preimageSHA256: digest("a"))]
        let resolvedCriteria = try criteria ?? defaultCriteria()
        let resolvedBudgets = try budgets ?? budget()
        let resolvedIdentities = try identities ?? identityPlan()
        let resolvedLineage: BuilderLineageEnvelope
        if let lineage { resolvedLineage = lineage }
        else { resolvedLineage = try BuilderLineageEnvelope() }
        return try BuilderExecutionContract(
            builderContractID: builderContractID, builderNodeID: nodeID,
            mutations: resolvedMutations, criteria: resolvedCriteria,
            budgets: resolvedBudgets, identities: resolvedIdentities,
            lineage: resolvedLineage)
    }

    private func run(contract: BuilderContract, graph: BuilderGraph) throws -> BuilderRun {
        try BuilderRun(
            contract: contract, graph: graph,
            store: BuilderJSONStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)),
            graphExecutionPolicy: BuilderGraphExecutionPolicy(nodeClasses:
                Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, .mutation) })),
            execute: { _ in throw Unused.closure },
            verify: { _ in throw Unused.closure },
            review: { _ in throw Unused.closure })
    }

    func testCanonicalEncodingAndFingerprintIgnoreInputOrdering() throws {
        let operations = [try BuilderMutationOperation(kind: .delete, path: "Z.txt"),
                          try BuilderMutationOperation(kind: .create, path: "A.txt")]
        let criteria = try defaultCriteria()
        let total = try BuilderResourceBudget(maxToolCalls: 100, maxTokens: 100_000, maxWallTimeSeconds: 3_600)
        let stageBudgets = try [BuilderExecutionStage.review, .build, .verification].map {
            BuilderStageBudget(stage: $0, limit: try BuilderResourceBudget(
                maxToolCalls: 20, maxTokens: 25_000, maxWallTimeSeconds: 900))
        }
        let identitiesA = try BuilderIdentityPlan(
            producers: [BuilderModelIdentity(providerID: "mistral", modelID: "coder-b"),
                        BuilderModelIdentity(providerID: "anthropic", modelID: "coder-a")],
            reviewers: [BuilderModelIdentity(providerID: "openai", modelID: "review-b"),
                        BuilderModelIdentity(providerID: "google", modelID: "review-a")])
        let identitiesB = try BuilderIdentityPlan(
            producers: identitiesA.producers.reversed(), reviewers: identitiesA.reviewers.reversed())
        let first = try contract(mutations: operations, criteria: criteria.reversed(),
                                 budgets: BuilderBudgetPolicy(total: total, stages: stageBudgets),
                                 identities: identitiesA)
        let second = try contract(mutations: operations.reversed(), criteria: criteria,
                                  budgets: BuilderBudgetPolicy(total: total, stages: stageBudgets.reversed()),
                                  identities: identitiesB)
        XCTAssertEqual(try first.canonicalData(), try second.canonicalData())
        XCTAssertEqual(try first.fingerprint(), try second.fingerprint())
    }

    func testCanonicalEncodingRepresentsAbsenceAsNull() throws {
        let value = try contract(mutations: [BuilderMutationOperation(kind: .create, path: "New.swift")])
        let json = String(decoding: try value.canonicalData(), as: UTF8.self)
        XCTAssertTrue(json.contains(#""preimageSHA256":null"#))
        XCTAssertTrue(json.contains(#""captainDecisionDigest":null"#))
        XCTAssertTrue(json.contains(#""research":null"#))
        XCTAssertTrue(json.contains(#""taskBoard":null"#))
        XCTAssertFalse(json.contains("unknown"))
    }

    func testSealRoundTripBindsContractAndBuilderNode() throws {
        let value = try contract()
        let sealed = try SealedBuilderExecutionContract.issue(value)
        XCTAssertEqual(sealed.fingerprint, try value.fingerprint())
        XCTAssertNoThrow(try sealed.validate(builderContractID: "builder-1", graphNodeIDs: ["build"]))
    }

    func testTamperedContractCannotReuseSeal() throws {
        let original = try contract()
        let sealed = try SealedBuilderExecutionContract.issue(original)
        let changedCriteria = try defaultCriteria() + [BuilderStageCriterion(
            id: "extra", stage: .build, kind: .artifactDigest, statement: "Extra bound evidence exists.")]
        let changed = try contract(criteria: changedCriteria)
        let forged = SealedBuilderExecutionContract(
            contract: changed, fingerprint: sealed.fingerprint, seal: sealed.seal)
        XCTAssertThrowsError(try forged.validate(builderContractID: "builder-1", graphNodeIDs: ["build"]))
    }

    func testMutationPathsNormalizeProjectRelatively() throws {
        let operation = try BuilderMutationOperation(
            kind: .modify, path: "./Sources//Feature\\Main.swift", preimageSHA256: digest("a"))
        XCTAssertEqual(operation.path, "Sources/Feature/Main.swift")
        XCTAssertNoThrow(try BuilderMutationOperation(kind: .delete, path: "Sources/Old.swift"))
    }

    func testMutationPathsRejectAbsoluteHomeAndTraversalForms() {
        for path in ["/tmp/escape", "C:\\temp\\escape", "~/escape", "Sources/../escape", "file://escape"] {
            XCTAssertThrowsError(try BuilderMutationOperation(kind: .modify, path: path), path)
        }
    }

    func testDuplicateAndConflictingMutationPathsAreRejected() throws {
        let first = try BuilderMutationOperation(kind: .create, path: "Sources//Same.swift")
        let second = try BuilderMutationOperation(kind: .modify, path: "./Sources/Same.swift")
        XCTAssertThrowsError(try contract(mutations: [first, second]))
    }

    func testMutationPreimageRulesAndDigestValidation() {
        XCTAssertNoThrow(try BuilderMutationOperation(
            kind: .modify, path: "A.swift", preimageSHA256: digest("a")))
        XCTAssertThrowsError(try BuilderMutationOperation(
            kind: .create, path: "A.swift", preimageSHA256: digest("a")))
        XCTAssertThrowsError(try BuilderMutationOperation(
            kind: .modify, path: "A.swift", preimageSHA256: "ABC"))
        XCTAssertThrowsError(try BuilderMutationOperation(
            kind: .modify, path: "A.swift", preimageSHA256: String(repeating: "0", count: 64)))
    }

    func testCriteriaRejectEmptyDuplicateAndNoRequiredEntries() throws {
        XCTAssertThrowsError(try BuilderStageCriterion(
            id: "", stage: .build, kind: .artifactDigest, statement: "evidence"))
        let criterion = try BuilderStageCriterion(
            id: "same", stage: .build, kind: .artifactDigest, statement: "evidence")
        XCTAssertThrowsError(try contract(criteria: [criterion, criterion]))
        let advisory = try BuilderStageCriterion(
            id: "advisory", stage: .build, kind: .artifactDigest,
            statement: "advisory only", required: false)
        XCTAssertThrowsError(try contract(criteria: [advisory]))
    }

    func testCriteriaRequireStageBudget() throws {
        let council = try BuilderStageCriterion(
            id: "council", stage: .council, kind: .lineageReceipt,
            statement: "Council lineage is present.")
        XCTAssertThrowsError(try contract(criteria: try defaultCriteria() + [council]))
    }

    func testBudgetsRequirePositiveLimits() {
        XCTAssertThrowsError(try BuilderResourceBudget(maxToolCalls: 0, maxTokens: 1, maxWallTimeSeconds: 1))
        XCTAssertThrowsError(try BuilderResourceBudget(maxToolCalls: 1, maxTokens: 0, maxWallTimeSeconds: 1))
        XCTAssertThrowsError(try BuilderResourceBudget(maxToolCalls: 1, maxTokens: 1, maxWallTimeSeconds: 0))
    }

    func testStageBudgetsRejectDuplicatesAndLimitsAboveTotal() throws {
        let total = try BuilderResourceBudget(maxToolCalls: 10, maxTokens: 1_000, maxWallTimeSeconds: 60)
        let normal = BuilderStageBudget(stage: .build, limit: try BuilderResourceBudget(
            maxToolCalls: 5, maxTokens: 500, maxWallTimeSeconds: 30))
        XCTAssertThrowsError(try BuilderBudgetPolicy(total: total, stages: [normal, normal]))
        let excessive = BuilderStageBudget(stage: .build, limit: try BuilderResourceBudget(
            maxToolCalls: 11, maxTokens: 500, maxWallTimeSeconds: 30))
        XCTAssertThrowsError(try BuilderBudgetPolicy(total: total, stages: [excessive]))
    }

    func testIdentityFieldsRejectEmptyAndPlaceholderValues() {
        XCTAssertThrowsError(try BuilderModelIdentity(providerID: "", modelID: "model"))
        XCTAssertThrowsError(try BuilderModelIdentity(providerID: "unknown", modelID: "model"))
        XCTAssertThrowsError(try BuilderModelIdentity(providerID: "openai", modelID: "default"))
    }

    func testIdentityPlanRejectsDuplicatesAndReviewerProducerAliases() throws {
        let producer = try BuilderModelIdentity(providerID: "anthropic", modelID: "same-model")
        XCTAssertThrowsError(try BuilderIdentityPlan(producers: [producer, producer], reviewers: [
            BuilderModelIdentity(providerID: "openai", modelID: "reviewer")]))
        XCTAssertThrowsError(try BuilderIdentityPlan(producers: [producer], reviewers: [
            BuilderModelIdentity(providerID: "proxy", modelID: "SAME-MODEL")]))
    }

    func testLineageAllowsExplicitAbsence() throws {
        let lineage = try BuilderLineageEnvelope()
        XCTAssertNil(lineage.captainDecisionDigest)
        XCTAssertNil(lineage.research)
        XCTAssertNil(lineage.peelReceiptDigest)
        XCTAssertNil(lineage.councilArtifactDigest)
        XCTAssertNil(lineage.taskBoard)
        XCTAssertNoThrow(try contract(lineage: lineage))
    }

    func testLineageEnforcesResearchPeelCouncilAndTaskBoardOrder() throws {
        let research = try BuilderResearchLineage(runID: "run-1", dossierDigest: digest("a"))
        let taskBoard = try BuilderTaskBoardLineage(
            version: 1, taskIDs: ["task-1"], handoffDigest: digest("d"))
        XCTAssertThrowsError(try BuilderLineageEnvelope(peelReceiptDigest: digest("b")))
        XCTAssertThrowsError(try BuilderLineageEnvelope(
            research: research, councilArtifactDigest: digest("c")))
        XCTAssertThrowsError(try BuilderLineageEnvelope(taskBoard: taskBoard))
        XCTAssertNoThrow(try BuilderLineageEnvelope(
            captainDecisionDigest: digest("e"), research: research,
            peelReceiptDigest: digest("b"), councilArtifactDigest: digest("c"), taskBoard: taskBoard))
    }

    func testLineageRejectsInvalidDigestsAndResearchIDs() {
        XCTAssertThrowsError(try BuilderResearchLineage(runID: "../run", dossierDigest: digest("a")))
        XCTAssertThrowsError(try BuilderResearchLineage(runID: "run-1", dossierDigest: "BAD"))
        XCTAssertThrowsError(try BuilderLineageEnvelope(
            captainDecisionDigest: String(repeating: "0", count: 64)))
    }

    func testTaskBoardLineageRequiresVersionAndUniqueTasks() {
        XCTAssertThrowsError(try BuilderTaskBoardLineage(
            version: 0, taskIDs: ["task-1"], handoffDigest: digest("a")))
        XCTAssertThrowsError(try BuilderTaskBoardLineage(
            version: 1, taskIDs: ["task-1", "task-1"], handoffDigest: digest("a")))
        XCTAssertThrowsError(try BuilderTaskBoardLineage(
            version: 1, taskIDs: [], handoffDigest: digest("a")))
    }

    func testUnsupportedSchemaVersionFailsClosedOnDecode() throws {
        let data = try contract().canonicalData()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 2
        let unsupported = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try JSONDecoder().decode(BuilderExecutionContract.self, from: unsupported))
    }

    func testBuilderRunAcceptsValidAttachmentAndRejectsContractOrNodeMismatch() throws {
        let sealed = try SealedBuilderExecutionContract.issue(contract())
        let graph = try BuilderGraph(nodes: [BuilderNode(
            id: "build", objective: "Build",
            resources: [.init(path: "Sources", access: .write)])])
        let valid = BuilderContract(
            id: "builder-1", objective: "Build", allowedPaths: ["Sources"],
            capabilities: ["read", "write"], doneWhen: ["verified"],
            executionContract: sealed)
        XCTAssertNoThrow(try run(contract: valid, graph: graph))

        let wrongContract = BuilderContract(
            id: "builder-2", objective: "Build", allowedPaths: ["Sources"],
            capabilities: ["read", "write"], doneWhen: ["verified"],
            executionContract: sealed)
        XCTAssertThrowsError(try run(contract: wrongContract, graph: graph))

        let wrongGraph = try BuilderGraph(nodes: [BuilderNode(id: "other", objective: "Other")])
        XCTAssertThrowsError(try run(contract: valid, graph: wrongGraph))
    }
}
