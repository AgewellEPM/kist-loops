import XCTest
@testable import AgentCore

private actor BuilderEventRecorder {
    private var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

final class BuilderRunPersistenceReviewTests: XCTestCase {
    private func succeeds(_ run: BuilderRun) async -> Bool {
        do { _ = try await run.run(); return true } catch { return false }
    }

    func testJSONStoreAtomicallyReplacesStateProducedByBuilderRun() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-store")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "n", objective: "build")])
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(id: "store-contract",
                                                      checkpointIdentity: "checkpoint-1",
                                                      maxTokens: 1_000),
            graph: graph, store: fixture.store,
            execute: { BuilderRunTestFixtures.worker(for: $0) },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in BuilderRunTestFixtures.approvedReview() }
        )
        _ = try await run.run()
        let firstLoaded = try await fixture.store.load()
        var replacement = try XCTUnwrap(firstLoaded)
        replacement.updatedAt = Date(timeIntervalSince1970: 123_456)
        replacement.sequence += 1

        try await fixture.store.save(replacement)
        let secondLoaded = try await fixture.store.load()
        let decoded = try XCTUnwrap(secondLoaded)
        XCTAssertEqual(decoded, replacement)
        XCTAssertEqual(decoded.usage, replacement.usage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
    }

    func testFinalVerificationCompletesBeforeIndependentReview() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-review-order")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let events = BuilderEventRecorder()
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "n", objective: "build")])
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(), graph: graph, store: fixture.store,
            execute: { request in
                await events.append("execute")
                return BuilderRunTestFixtures.worker(for: request)
            },
            verify: { request in
                switch request {
                case .node:
                    await events.append("verify-node")
                case .final:
                    await events.append("verify-final")
                }
                return await BuilderRunTestFixtures.passingVerification(request)
            },
            review: { request in
                await events.append("review")
                XCTAssertEqual(request.verification.scope, .final)
                XCTAssertTrue(request.verification.deterministic)
                XCTAssertTrue(request.verification.passed)
                return BuilderRunTestFixtures.approvedReview()
            }
        )

        _ = try await run.run()
        let order = await events.snapshot()
        XCTAssertEqual(order, [
            "execute", "verify-node", "verify-final", "review",
            "verify-final", "verify-final",
        ])
    }

    func testFailedFinalVerificationPreventsReviewAndTypedCompletion() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-final-gate")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let events = BuilderEventRecorder()
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "n", objective: "build")])
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(), graph: graph, store: fixture.store,
            execute: { BuilderRunTestFixtures.worker(for: $0) },
            verify: { request in
                switch request {
                case .node:
                    return await BuilderRunTestFixtures.passingVerification(request)
                case .final:
                    await events.append("verify-final-failed")
                    return .init(scope: .final, provider: "deterministic", model: "v1",
                                 deterministic: true, passed: false,
                                 checks: [.init(name: "final", passed: false,
                                                details: "integration check failed")],
                                 failureFingerprint: "integration-failure")
                }
            },
            review: { _ in
                await events.append("review")
                return BuilderRunTestFixtures.approvedReview()
            }
        )

        do {
            _ = try await run.run()
            XCTFail("worker success without a final proof must not complete")
        } catch let error as BuilderRunError {
            guard case .finalVerificationFailed(let reason) = error else {
                return XCTFail("expected finalVerificationFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("integration check failed"))
        }
        let recordedEvents = await events.snapshot()
        XCTAssertEqual(recordedEvents, ["verify-final-failed"])
        let loaded = try await fixture.store.load()
        XCTAssertNil(try XCTUnwrap(loaded).finalReceipt)
    }

    func testSameProviderModelIdentityCannotApproveBuilderWork() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-review-identity")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "n", objective: "build")])
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(), graph: graph, store: fixture.store,
            execute: { BuilderRunTestFixtures.worker(for: $0, provider: "OpenAI", model: "GPT-5") },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in
                BuilderRunTestFixtures.approvedReview(provider: " openai ", model: "gpt-5")
            }
        )

        var rejectedIdentity: String?
        do {
            _ = try await run.run()
            XCTFail("the builder identity must not review itself")
        } catch let error as BuilderRunError {
            guard case .reviewerNotIndependent(let identity) = error else {
                return XCTFail("expected reviewerNotIndependent, got \(error)")
            }
            rejectedIdentity = identity
        }
        XCTAssertEqual(rejectedIdentity, "openai:gpt-5")
        let loaded = try await fixture.store.load()
        XCTAssertNil(try XCTUnwrap(loaded).finalReceipt)
    }

    func testDistinctReviewerApprovalProducesAndPersistsCompletionReceipt() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-distinct-review")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "n", objective: "build")])
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(
                hint: .init(preferred: .highAssurance, risk: .critical)),
            graph: graph, store: fixture.store,
            execute: { BuilderRunTestFixtures.worker(for: $0, provider: "openai", model: "gpt-5") },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in
                BuilderRunTestFixtures.approvedReview(provider: "anthropic", model: "claude")
            }
        )

        let final = try await run.run()
        XCTAssertTrue(final.accepted)
        XCTAssertEqual(final.route, .highAssurance)
        XCTAssertEqual(final.review.provider, "anthropic")
        XCTAssertEqual(final.review.model, "claude")
        XCTAssertEqual(final.review.workerIdentities, ["openai:gpt-5"])
        XCTAssertEqual(final.review.reviewerIdentity, "anthropic:claude")
        let loaded = try await fixture.store.load()
        let persisted = try XCTUnwrap(try XCTUnwrap(loaded).finalReceipt)
        XCTAssertTrue(persisted.accepted)
        XCTAssertEqual(persisted.contractID, final.contractID)
        XCTAssertEqual(
            persisted.workers.map { "\($0.provider):\($0.model)" },
            ["openai:gpt-5"])
        XCTAssertEqual(persisted.review.workerIdentities, ["openai:gpt-5"])
        XCTAssertEqual(persisted.review.reviewerIdentity, "anthropic:claude")
        let reopenedStore = BuilderJSONStore(fileURL: fixture.store.fileURL)
        let reopenedValue = try await reopenedStore.load()
        let reopened = try XCTUnwrap(reopenedValue)
        let roundTripped = try XCTUnwrap(reopened.finalReceipt)
        XCTAssertEqual(roundTripped.workers.first?.provider, "openai")
        XCTAssertEqual(roundTripped.workers.first?.model, "gpt-5")
        XCTAssertEqual(roundTripped.review.workerIdentities, ["openai:gpt-5"])
        XCTAssertEqual(roundTripped.review.reviewerIdentity, "anthropic:claude")
    }

    func testReviewerMustDifferFromEveryProducingWorker() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-all-worker-identities")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let graph = try BuilderGraph(nodes: [
            BuilderNode(id: "first", objective: "first"),
            BuilderNode(id: "second", objective: "second"),
        ])
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(), graph: graph, store: fixture.store,
            execute: { request in
                let identity = request.node.id == "first"
                    ? ("openai", "gpt-5") : ("anthropic", "claude")
                return BuilderRunTestFixtures.worker(
                    for: request, provider: identity.0, model: identity.1)
            },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in
                BuilderRunTestFixtures.approvedReview(provider: "anthropic", model: "claude")
            }
        )

        do {
            _ = try await run.run()
            XCTFail("matching any producing worker must fail independent review")
        } catch let error as BuilderRunError {
            guard case .reviewerNotIndependent(let identity) = error else {
                return XCTFail("expected reviewerNotIndependent, got \(error)")
            }
            XCTAssertEqual(identity, "anthropic:claude")
        }
    }

    func testVerificationOnlyNoOpPersistsDigestBoundReviewAndReverifiesAfterReview() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-verification-only")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let events = BuilderEventRecorder()
        let subject = BuilderEvidenceDigest.sha256("verification-only-subject")
        let contract = BuilderContract(
            objective: "verify without editing", doneWhen: ["checks pass"],
            completionMode: .verificationOnly, producerIdentities: ["planner:plan-model"])
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "verify", objective: "verify")])
        let run = try BuilderRun(
            contract: contract, graph: graph, store: fixture.store,
            execute: { request in
                BuilderWorkerReceipt(nodeID: request.node.id, provider: "coder", model: "code-model")
            },
            verify: { request in
                switch request {
                case .node(_, let node, _, _):
                    return .init(scope: .node(node.id), provider: "host", model: "deterministic",
                                 deterministic: true, passed: true)
                case .final:
                    await events.append("verify-final")
                    return await BuilderRunTestFixtures.passingVerification(
                        request, subjectOverride: subject)
                }
            },
            review: { _ in
                await events.append("review")
                return BuilderRunTestFixtures.approvedReview(provider: "reviewer", model: "review-model")
            })

        let final = try await run.run()
        let recordedEvents = await events.snapshot()
        XCTAssertEqual(recordedEvents, [
            "verify-final", "review", "verify-final", "verify-final",
        ])
        XCTAssertEqual(final.verification.verificationSubject, "fixture://\(contract.id)")
        XCTAssertEqual(final.verification.subjectDigest, subject)
        XCTAssertEqual(final.review.workerIdentities, ["coder:code-model", "planner:plan-model"])
        XCTAssertEqual(final.review.reviewerIdentity, "reviewer:review-model")
        let loaded = try await fixture.store.load()
        let persisted = try XCTUnwrap(try XCTUnwrap(loaded).finalReceipt)
        XCTAssertEqual(persisted.verification.subjectDigest, subject)
        XCTAssertEqual(persisted.review.reviewerIdentity, "reviewer:review-model")
    }

    func testLegacyBuildContractWithoutGovernanceIsRejectedBeforeReview() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-build-noop")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "build", objective: "build")])
        do {
            _ = try BuilderRun(
                contract: BuilderContract(objective: "build", doneWhen: ["built"]),
                graph: graph, store: fixture.store,
                execute: { request in
                    BuilderWorkerReceipt(
                        nodeID: request.node.id, provider: "coder", model: "model")
                },
                verify: { await BuilderRunTestFixtures.passingVerification($0) },
                review: { _ in
                    XCTFail("ungoverned build must not reach review")
                    return BuilderRunTestFixtures.approvedReview()
                })
            XCTFail("legacy mutation input must fail closed at admission")
        } catch let error as BuilderRunError {
            guard case .invalidConfiguration(let reason) = error else {
                return XCTFail("expected invalidConfiguration, got \(error)")
            }
            XCTAssertTrue(reason.contains("graph execution policy"))
        }
    }

    func testDeclaredProducerCannotActAsFinalReviewer() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-declared-producer")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "verify", objective: "verify")])
        let contract = BuilderContract(
            objective: "verify", constraints: ["do not edit"], capabilities: ["read"],
            doneWhen: ["verified"], completionMode: .verificationOnly,
            producerIdentities: ["planner:planner-model"])
        let run = try BuilderRun(
            contract: contract, graph: graph, store: fixture.store,
            execute: { BuilderRunTestFixtures.worker(for: $0, provider: "coder", model: "code-model") },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in
                BuilderRunTestFixtures.approvedReview(provider: "planner", model: "planner-model")
            })
        do {
            _ = try await run.run()
            XCTFail("declared producer must not review its own run")
        } catch let error as BuilderRunError {
            guard case .reviewerNotIndependent(let identity) = error else {
                return XCTFail("expected reviewerNotIndependent, got \(error)")
            }
            XCTAssertEqual(identity, "planner:planner-model")
        }
    }

    func testDigestChangeDuringIndependentReviewFailsStaleProofGate() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-review-drift")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let events = BuilderEventRecorder()
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "build", objective: "build")])
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(), graph: graph, store: fixture.store,
            execute: { BuilderRunTestFixtures.worker(for: $0) },
            verify: { request in
                switch request {
                case .node:
                    return await BuilderRunTestFixtures.passingVerification(request)
                case .final:
                    let count = await events.snapshot().filter { $0 == "verify" }.count
                    await events.append("verify")
                    let subject = BuilderEvidenceDigest.sha256(
                        count == 0 ? "digest-a" : "digest-b")
                    return await BuilderRunTestFixtures.passingVerification(
                        request, subjectOverride: subject)
                }
            },
            review: { _ in BuilderRunTestFixtures.approvedReview() })
        do {
            _ = try await run.run()
            XCTFail("digest drift must reject completion")
        } catch let error as BuilderRunError {
            guard case .finalVerificationFailed(let reason) = error else {
                return XCTFail("expected finalVerificationFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("changed during independent review"))
        }
    }

    func testRejectedReviewAttemptPersistsIdentityVotesAndEvidencePacket() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-review-attempt")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "build", objective: "build")])
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(), graph: graph, store: fixture.store,
            execute: { BuilderRunTestFixtures.worker(for: $0) },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in
                BuilderTrustedTelemetry.recordProvider(
                    providerID: "gemini", modelID: "review",
                    inputTokens: 1, outputTokens: 1, elapsedMilliseconds: 1,
                    outputDigest: String(repeating: "f", count: 64))
                return BuilderReviewReceipt(
                    provider: "gemini", model: "review", accepted: false,
                    checks: [.init(name: "review", passed: false, details: "held")],
                    findings: ["held"],
                    evidencePacketDigest: String(repeating: "a", count: 64),
                    votes: [.init(
                        lens: "Correctness", accepted: false, reason: "held", failed: false)])
            })
        do { _ = try await run.run(); XCTFail("HOLD must reject") }
        catch let error as BuilderRunError {
            guard case .reviewRejected = error else { return XCTFail("unexpected \(error)") }
        }
        let loadedValue = try await fixture.store.load()
        let loaded = try XCTUnwrap(loadedValue)
        let attempt = try XCTUnwrap(loaded.reviewAttempt)
        XCTAssertEqual(attempt.reviewerIdentity, "gemini:review")
        XCTAssertEqual(attempt.evidencePacketDigest, String(repeating: "a", count: 64))
        XCTAssertEqual(attempt.votes.map(\.lens), ["Correctness"])
        XCTAssertFalse(attempt.accepted)
    }

    func testFreshRunRejectsExistingSnapshotBeforeWorkerExecution() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-fresh-collision")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let mission = String(repeating: "a", count: 64)
        let contract = BuilderRunTestFixtures.contract(
            id: "fresh-collision", checkpointIdentity: mission, maxTokens: 1_000)
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "n", objective: "build")])
        let first = try BuilderRun(
            contract: contract, graph: graph, store: fixture.store,
            execute: { BuilderRunTestFixtures.worker(for: $0) },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in BuilderRunTestFixtures.approvedReview() })
        _ = try await first.run()

        let events = BuilderEventRecorder()
        let colliding = try BuilderRun(
            contract: contract, graph: graph, store: fixture.store,
            execute: { request in
                await events.append("execute")
                return BuilderRunTestFixtures.worker(for: request)
            },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in BuilderRunTestFixtures.approvedReview() })
        do {
            _ = try await colliding.run()
            XCTFail("fresh run must not overwrite an existing snapshot")
        } catch let error as BuilderRunError {
            guard case .persistedStateMismatch = error else {
                return XCTFail("expected persistedStateMismatch, got \(error)")
            }
        }
        let recorded = await events.snapshot()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testConcurrentFreshRunsHaveExactlyOneCreatorAndWorker() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-concurrent-create")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let mission = String(repeating: "b", count: 64)
        let contract = BuilderRunTestFixtures.contract(
            id: "concurrent-create", checkpointIdentity: mission, maxTokens: 1_000)
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "n", objective: "build")])
        let events = BuilderEventRecorder()
        let makeRun: () throws -> BuilderRun = {
            try BuilderRun(
                contract: contract, graph: graph, store: fixture.store,
                execute: { request in
                    await events.append("execute")
                    return BuilderRunTestFixtures.worker(for: request)
                },
                verify: { await BuilderRunTestFixtures.passingVerification($0) },
                review: { _ in BuilderRunTestFixtures.approvedReview() })
        }
        let first = try makeRun()
        let second = try makeRun()
        async let firstSucceeded = succeeds(first)
        async let secondSucceeded = succeeds(second)
        let results = await (firstSucceeded, secondSucceeded)
        XCTAssertEqual([results.0, results.1].filter { $0 }.count, 1)
        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, ["execute"])
    }

    func testExplicitResumeRequiresExactCheckpointIdentity() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-exact-resume")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let mission = String(repeating: "c", count: 64)
        let graph = try BuilderGraph(nodes: [BuilderNode(id: "n", objective: "build")])
        let originalContract = BuilderRunTestFixtures.contract(
            id: "exact-resume", checkpointIdentity: mission, maxTokens: 1_000)
        let original = try BuilderRun(
            contract: originalContract, graph: graph, store: fixture.store,
            execute: { BuilderRunTestFixtures.worker(for: $0) },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in BuilderRunTestFixtures.approvedReview() })
        _ = try await original.run()

        let exact = try BuilderRun(
            contract: originalContract, graph: graph, store: fixture.store,
            resumeExisting: true,
            execute: { BuilderRunTestFixtures.worker(for: $0) },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in BuilderRunTestFixtures.approvedReview() })
        let resumed = try await exact.run()
        XCTAssertTrue(resumed.accepted)

        let mismatch = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(
                id: "exact-resume", checkpointIdentity: String(repeating: "d", count: 64),
                maxTokens: 1_000),
            graph: graph, store: fixture.store, resumeExisting: true,
            execute: { BuilderRunTestFixtures.worker(for: $0) },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in BuilderRunTestFixtures.approvedReview() })
        do {
            _ = try await mismatch.run()
            XCTFail("resume must reject a different checkpoint identity")
        } catch let error as BuilderRunError {
            guard case .persistedStateMismatch = error else {
                return XCTFail("expected persistedStateMismatch, got \(error)")
            }
        }
    }

    func testReviewAttemptPersistsOnlyCanonicalMissionIdentity() async throws {
        func heldAttempt(checkpointIdentity: String, prefix: String) async throws
            -> BuilderReviewAttemptReceipt {
            let fixture = BuilderRunTestFixtures.makeStore(prefix)
            defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
            let graph = try BuilderGraph(nodes: [BuilderNode(id: "n", objective: "build")])
            let run = try BuilderRun(
                contract: BuilderRunTestFixtures.contract(
                    id: prefix, checkpointIdentity: checkpointIdentity, maxTokens: 1_000),
                graph: graph, store: fixture.store,
                execute: { BuilderRunTestFixtures.worker(for: $0) },
                verify: { await BuilderRunTestFixtures.passingVerification($0) },
                review: { _ in
                    BuilderTrustedTelemetry.recordProvider(
                        providerID: "gemini", modelID: "review",
                        inputTokens: 1, outputTokens: 1, elapsedMilliseconds: 1,
                        outputDigest: String(repeating: "f", count: 64))
                    return BuilderReviewReceipt(
                        provider: "gemini", model: "review", accepted: false,
                        checks: [.init(name: "review", passed: false, details: "held")],
                        findings: ["held"],
                        evidencePacketDigest: String(repeating: "a", count: 64))
                })
            do { _ = try await run.run(); XCTFail("HOLD must reject") }
            catch let error as BuilderRunError {
                guard case .reviewRejected = error else { throw error }
            }
            let loaded = try await fixture.store.load()
            return try XCTUnwrap(try XCTUnwrap(loaded).reviewAttempt)
        }

        let mission = String(repeating: "e", count: 64)
        let canonical = try await heldAttempt(
            checkpointIdentity: mission, prefix: "builder-mission-attempt")
        XCTAssertEqual(canonical.missionInstanceID, mission)
        let headless = try await heldAttempt(
            checkpointIdentity: "last", prefix: "builder-headless-attempt")
        XCTAssertNil(headless.missionInstanceID)
    }

    func testLegacyReviewReceiptDecodesWithoutIdentityAuditFields() throws {
        let data = try XCTUnwrap("""
        {"provider":"reviewer","model":"model","accepted":true,"checks":[],"findings":[],
         "usage":{"inputTokens":0,"outputTokens":0,"wallTimeSeconds":0}}
        """.data(using: .utf8))
        let receipt = try JSONDecoder().decode(BuilderReviewReceipt.self, from: data)
        XCTAssertNil(receipt.workerIdentities)
        XCTAssertNil(receipt.reviewerIdentity)
    }

    func testUsageReceiptRepresentsExplicitlyUnmeteredStagesWithoutInventingTotal() {
        let usage = BuilderUsageReceipt(inputTokens: 10, outputTokens: 5,
                                        wallTimeSeconds: 1,
                                        aggregateTokens: nil,
                                        unmeteredStages: ["mission.research"])
        XCTAssertNil(usage.aggregateTokens)
        XCTAssertEqual(usage.unmeteredStages, ["mission.research"])
    }
}
