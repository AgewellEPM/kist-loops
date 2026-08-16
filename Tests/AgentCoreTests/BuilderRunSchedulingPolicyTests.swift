import XCTest
@testable import AgentCore

enum BuilderRunTestFixtures {
    struct StoreFixture {
        let root: URL
        let store: BuilderJSONStore
    }

    static func makeStore(_ prefix: String) -> StoreFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        return StoreFixture(root: root,
                            store: BuilderJSONStore(fileURL: root.appendingPathComponent("run.json")))
    }

    static func contract(id: String = UUID().uuidString,
                         hint: BuilderRouteHint = .init(),
                         checkpointIdentity: String? = nil,
                         maxTokens: Int? = nil) -> BuilderContract {
        BuilderContract(id: id, objective: "verify the requested result without editing",
                        constraints: ["do not edit files"], capabilities: ["read"],
                        doneWhen: ["verification passes"],
                        routeHint: hint, checkpointIdentity: checkpointIdentity,
                        maxTokens: maxTokens, completionMode: .verificationOnly)
    }

    static func worker(for request: BuilderExecutionRequest,
                       provider: String = "builder-provider",
                       model: String = "builder-model") -> BuilderWorkerReceipt {
        worker(for: request, provider: provider, model: model, checkName: "worker")
    }

    static func worker(for request: BuilderExecutionRequest,
                       provider: String = "builder-provider",
                       model: String = "builder-model",
                       checkName: String) -> BuilderWorkerReceipt {
        BuilderWorkerReceipt(
            nodeID: request.node.id, provider: provider, model: model,
            artifacts: [.init(path: "\(request.node.id).artifact", kind: "test")],
            changedPaths: [],
            checks: [.init(name: checkName, passed: true, details: "worker completed")],
            usage: .init(inputTokens: 2, outputTokens: 3, wallTimeSeconds: 0.01,
                         aggregateTokens: 5, unmeteredStages: nil)
        )
    }

    static func passingVerification(
        _ request: BuilderVerificationRequest,
        subjectOverride: String? = nil
    ) async -> BuilderVerifierReceipt {
        switch request {
        case .node(_, let node, _, _):
            return .init(scope: .node(node.id), provider: "deterministic", model: "v1",
                         deterministic: true, passed: true,
                         checks: [.init(name: "node", passed: true, details: "node passed")])
        case .final(let contract, _, _):
            BuilderTrustedTelemetry.recordProvider(
                providerID: "deterministic", modelID: "v1",
                inputTokens: 1, outputTokens: 1, elapsedMilliseconds: 1,
                outputDigest: String(repeating: "d", count: 64))
            let fingerprint = BuilderEvidenceDigest.sha256(String(
                decoding: try! BuilderDurableIO.canonicalData(contract), as: UTF8.self))
            let subject = subjectOverride
                ?? BuilderEvidenceDigest.sha256("read-only-fixture:\(contract.id)")
            let result = await ToolRegistry([RunCommandTool()]).execute(
                name: "run_command",
                arguments: [
                    "executable": "/usr/bin/printf",
                    "args": ["%s", "verified"],
                ],
                context: ToolContext(
                    projectRoot: NSTemporaryDirectory(),
                    shell: ShellPolicy(
                        enabled: true, autoApprove: true, allow: ["printf"])))
            guard result.success, let reference = result.trustedCommandReference else {
                return .init(
                    scope: .final, provider: "deterministic", model: "v1",
                    deterministic: true, passed: false,
                    checks: [.init(name: "final-command", passed: false)])
            }
            let command = BuilderCommandEvidenceReceipt.boundPrehashed(
                tool: "run_command", verifierStatus: .passed,
                exitCode: reference.exitCode, allowedExitCodes: "0",
                semanticStatus: "clean_exit",
                argsFingerprint: reference.gateArgumentsDigest,
                outputDigest: reference.stdoutDigest,
                boundedRedactedOutputExcerpt: result.output,
                subjectDigestAfter: subject,
                contractFingerprint: fingerprint,
                trustedCommandReference: reference)
            return .init(
                scope: .final, provider: "deterministic", model: "v1",
                deterministic: true, passed: true,
                checks: [.init(name: "final", passed: true, details: "final passed")],
                verificationSubject: "fixture://\(contract.id)",
                baselineDigest: subject, subjectDigest: subject,
                contractFingerprint: fingerprint, completionMode: .verificationOnly,
                commandEvidence: [command])
        }
    }

    static func approvedReview(provider: String = "review-provider",
                               model: String = "review-model") -> BuilderReviewReceipt {
        BuilderTrustedTelemetry.recordProvider(
            providerID: provider, modelID: model,
            inputTokens: 1, outputTokens: 1, elapsedMilliseconds: 1,
            outputDigest: String(repeating: "e", count: 64))
        return .init(provider: provider, model: model, accepted: true,
              checks: [.init(name: "review", passed: true, details: "approved")],
              usage: .init(inputTokens: 1, outputTokens: 1, wallTimeSeconds: 0.01,
                           aggregateTokens: 2, unmeteredStages: nil),
              evidencePacketDigest: "test-evidence-packet")
    }
}

private actor BuilderSchedulingProbe {
    struct Metrics: Sendable {
        let maxActive: Int
        let starts: [String]
        let attempts: [String: [Int]]
    }

    private var active = 0
    private var maxActive = 0
    private var starts: [String] = []
    private var attempts: [String: [Int]] = [:]
    private var barrierWaiters: [CheckedContinuation<Void, Never>] = []

    func recordAttempt(_ id: String, attempt: Int) {
        starts.append(id)
        attempts[id, default: []].append(attempt)
    }

    func begin(_ id: String, attempt: Int, synchronizeAt target: Int? = nil) async {
        starts.append(id)
        attempts[id, default: []].append(attempt)
        active += 1
        maxActive = max(maxActive, active)
        guard let target else { return }
        if active >= target {
            let waiters = barrierWaiters
            barrierWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        } else {
            await withCheckedContinuation { continuation in
                barrierWaiters.append(continuation)
            }
        }
    }

    func end() { active -= 1 }

    func metrics() -> Metrics {
        Metrics(maxActive: maxActive, starts: starts, attempts: attempts)
    }
}

final class BuilderRunSchedulingPolicyTests: XCTestCase {
    func testReadyNodesActuallyOverlapButNeverExceedConfiguredParallelism() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-parallel")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let graph = try BuilderGraph(nodes: (1...4).map {
            BuilderNode(id: "n\($0)", objective: "work \($0)",
                        resources: [.init(path: "Sources/N\($0).swift", access: .read)])
        })
        let probe = BuilderSchedulingProbe()
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(
                hint: .init(estimatedFiles: 4, independentWorkstreams: 4)),
            graph: graph, store: fixture.store, maxParallelism: 2,
            execute: { request in
                await probe.begin(request.node.id, attempt: request.attempt, synchronizeAt: 2)
                await probe.end()
                return BuilderRunTestFixtures.worker(for: request)
            },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in BuilderRunTestFixtures.approvedReview() }
        )

        let receipt = try await run.run()
        let metrics = await probe.metrics()
        XCTAssertTrue(receipt.accepted)
        XCTAssertEqual(metrics.maxActive, 2)
        XCTAssertEqual(metrics.attempts.values.reduce(0) { $0 + $1.count }, 4)
    }

    func testPrefixOverlappingWriteLeasesSerializeEvenWithSpareCapacity() async throws {
        let leases = BuilderResourceLeaseTable()
        let probe = BuilderSchedulingProbe()
        let directory = try await leases.acquire(
            owner: "directory",
            claims: [.init(path: "Sources/App", access: .write)])
        let waiter = Task {
            await probe.recordAttempt("started", attempt: 1)
            let lease = try await leases.acquire(
                owner: "file",
                claims: [.init(path: "Sources/App/Feature.swift", access: .write)])
            await probe.recordAttempt("acquired", attempt: 1)
            return lease
        }
        while true {
            let metrics = await probe.metrics()
            if metrics.attempts["started"] != nil { break }
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let blockedMetrics = await probe.metrics()
        XCTAssertNil(blockedMetrics.attempts["acquired"])
        await leases.release(directory)
        let file = try await waiter.value
        let acquiredMetrics = await probe.metrics()
        XCTAssertEqual(acquiredMetrics.attempts["acquired"], [1])
        await leases.release(file)
    }

    func testOnlyFailedNodeRetriesAndAcceptedSiblingNeverReruns() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-targeted-retry")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let graph = try BuilderGraph(nodes: [
            BuilderNode(id: "a", objective: "repair a", retryLimit: 2),
            BuilderNode(id: "b", objective: "build b", retryLimit: 2),
        ])
        let probe = BuilderSchedulingProbe()
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(
                hint: .init(estimatedFiles: 2, independentWorkstreams: 2)),
            graph: graph, store: fixture.store, maxParallelism: 2,
            execute: { request in
                await probe.recordAttempt(request.node.id, attempt: request.attempt)
                return BuilderRunTestFixtures.worker(
                    for: request, checkName: "attempt-\(request.attempt)")
            },
            verify: { request in
                switch request {
                case .node(_, let node, let worker, _)
                        where node.id == "a"
                            && worker.checks.contains(where: { $0.name == "attempt-1" }):
                    return .init(scope: .node("a"), provider: "deterministic", model: "v1",
                                 deterministic: true, passed: false,
                                 checks: [.init(name: "a", passed: false, details: "repair a")],
                                 failureFingerprint: "repairable-a")
                default:
                    return await BuilderRunTestFixtures.passingVerification(request)
                }
            },
            review: { _ in BuilderRunTestFixtures.approvedReview() }
        )

        let receipt = try await run.run()
        let metrics = await probe.metrics()
        XCTAssertTrue(receipt.accepted)
        XCTAssertEqual(metrics.attempts["a"], [1, 2])
        XCTAssertEqual(metrics.attempts["b"], [1])
        let loaded = try await fixture.store.load()
        let snapshot = try XCTUnwrap(loaded)
        XCTAssertEqual(snapshot.nodeStates["a"]?.phase, .accepted)
        XCTAssertEqual(snapshot.nodeStates["b"]?.phase, .accepted)
    }

    func testIdenticalFailureFingerprintCutsOffBeforeRetryBudget() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-fingerprint")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let graph = try BuilderGraph(nodes: [
            BuilderNode(id: "n", objective: "repair", retryLimit: 5),
        ])
        let probe = BuilderSchedulingProbe()
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(), graph: graph, store: fixture.store,
            identicalFailureLimit: 2,
            execute: { request in
                await probe.recordAttempt(request.node.id, attempt: request.attempt)
                return BuilderRunTestFixtures.worker(for: request)
            },
            verify: { request in
                switch request {
                case .node(_, let node, _, _):
                    return .init(scope: .node(node.id), provider: "deterministic", model: "v1",
                                 deterministic: true, passed: false,
                                 checks: [.init(name: "same", passed: false,
                                                details: "unchanged compiler failure")],
                                 failureFingerprint: "same-failure")
                case .final(_, _, _):
                    return await BuilderRunTestFixtures.passingVerification(request)
                }
            },
            review: { _ in BuilderRunTestFixtures.approvedReview() }
        )

        do {
            _ = try await run.run()
            XCTFail("an unchanged deterministic failure must not exhaust all six attempts")
        } catch let error as BuilderRunError {
            guard case .executionFailed(let failures) = error else {
                return XCTFail("expected executionFailed, got \(error)")
            }
            XCTAssertNotNil(failures["n"])
        }
        let metrics = await probe.metrics()
        XCTAssertEqual(metrics.attempts["n"], [1, 2])
        let loaded = try await fixture.store.load()
        let snapshot = try XCTUnwrap(loaded)
        XCTAssertEqual(snapshot.nodeStates["n"]?.phase, .failed)
        XCTAssertEqual(snapshot.nodeStates["n"]?.identicalFailureCount, 2)
    }

    func testFailedBranchBlocksDescendantsWhileIndependentBranchCompletes() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("builder-descendants")
        defer {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }
        let graph = try BuilderGraph(nodes: [
            BuilderNode(id: "failed-root", objective: "root", retryLimit: 0),
            BuilderNode(id: "dependent", objective: "dependent", dependencies: ["failed-root"]),
            BuilderNode(id: "independent", objective: "independent"),
        ])
        let probe = BuilderSchedulingProbe()
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(), graph: graph, store: fixture.store,
            maxParallelism: 2,
            execute: { request in
                await probe.recordAttempt(request.node.id, attempt: request.attempt)
                return BuilderRunTestFixtures.worker(for: request)
            },
            verify: { request in
                switch request {
                case .node(_, let node, _, _) where node.id == "failed-root":
                    return .init(scope: .node(node.id), provider: "deterministic", model: "v1",
                                 deterministic: true, passed: false,
                                 checks: [.init(name: "root", passed: false, details: "root failed")],
                                 failureFingerprint: "root-failure")
                default:
                    return await BuilderRunTestFixtures.passingVerification(request)
                }
            },
            review: { _ in BuilderRunTestFixtures.approvedReview() }
        )

        do {
            _ = try await run.run()
            XCTFail("a failed root must fail the run")
        } catch let error as BuilderRunError {
            guard case .executionFailed(let failures) = error else {
                return XCTFail("expected executionFailed, got \(error)")
            }
            XCTAssertNotNil(failures["failed-root"])
        }
        let metrics = await probe.metrics()
        XCTAssertEqual(metrics.attempts["failed-root"], [1])
        XCTAssertEqual(metrics.attempts["independent"], [1])
        XCTAssertNil(metrics.attempts["dependent"])
        let loaded = try await fixture.store.load()
        let snapshot = try XCTUnwrap(loaded)
        XCTAssertEqual(snapshot.nodeStates["failed-root"]?.phase, .failed)
        XCTAssertEqual(snapshot.nodeStates["dependent"]?.phase, .blocked)
        XCTAssertEqual(snapshot.nodeStates["independent"]?.phase, .accepted)
    }
}
