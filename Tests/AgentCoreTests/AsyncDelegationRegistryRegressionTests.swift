import XCTest
@testable import AgentCore

final class AsyncDelegationRegistryRegressionTests: XCTestCase {
    func testBackgroundHandleJoinsStructuredResult() async throws {
        let registry = AsyncDelegationRegistry(clock: { 123 })
        let request = DelegationRequest(role: "builder", task: "build",
                                        capabilityCeiling: ceiling())
        let handle = try await registry.spawn(request) { context in
            let artifact = ReasoningArtifactReference(id: "artifact", path: "out.swift",
                                                      revision: "sha")
            let check = ReasoningCheckReceipt(id: "check", name: "tests", state: .passed)
            let evidence = ReasoningEvidenceReference(id: "evidence", kind: .check,
                                                      summary: "tests passed", at: 1)
            let risk = ReasoningRiskReceipt(id: "risk", level: .low, summary: "none")
            let progress = ReasoningProgressReceipt(
                id: "progress", evidence: .delegationCompleted(
                    effectID: "delegated", childID: context.handle.id,
                    artifactIDs: [artifact.id]), at: 2)
            return DelegationResult(handleID: context.handle.id, summary: "complete",
                                    artifacts: [artifact], checks: [check], evidence: [evidence],
                                    risks: [risk], progress: [progress],
                                    childCheckpointID: "child-checkpoint", tokensSpent: 40)
        }

        XCTAssertEqual(handle.createdAt, 123)
        let result = try await registry.join(handle)
        XCTAssertEqual(result.handleID, handle.id)
        XCTAssertEqual(result.artifacts.map(\.id), ["artifact"])
        XCTAssertEqual(result.checks.map(\.id), ["check"])
        XCTAssertEqual(result.evidence.map(\.id), ["evidence"])
        XCTAssertEqual(result.risks.map(\.id), ["risk"])
        XCTAssertEqual(result.progress.map(\.id), ["progress"])
        XCTAssertEqual(result.childCheckpointID, "child-checkpoint")
        XCTAssertEqual(result.tokensSpent, 40)
        let snapshot = try await registry.snapshot(handle)
        XCTAssertEqual(snapshot.status, .completed)
    }

    func testSteeringReachesRunningChildBeforeJoin() async throws {
        let registry = AsyncDelegationRegistry()
        let handle = try await registry.spawn(.init(
            role: "worker", task: "wait for direction", capabilityCeiling: ceiling())) { context in
            while true {
                try Task.checkCancellation()
                if let message = await context.steering.next() {
                    return DelegationResult(handleID: context.handle.id,
                                            summary: "steered: \(message)")
                }
                await Task.yield()
            }
        }
        try await registry.steer(handle, message: "use the safer parser")
        let result = try await registry.join(handle)
        XCTAssertEqual(result.summary, "steered: use the safer parser")
    }

    func testCancellationMakesJoinFailClosed() async throws {
        let registry = AsyncDelegationRegistry()
        let handle = try await registry.spawn(.init(
            role: "worker", task: "long task", capabilityCeiling: ceiling())) { context in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return DelegationResult(handleID: context.handle.id, summary: "too late")
        }
        try await registry.cancel(handle)
        do {
            _ = try await registry.join(handle)
            XCTFail("cancelled work must not project a successful result")
        } catch let error as DelegationRegistryError {
            guard case .cancelled(let id) = error else {
                return XCTFail("expected cancelled, got \(error)")
            }
            XCTAssertEqual(id, handle.id)
        }
    }

    func testCapabilityCeilingRejectsToolPathBudgetDepthAndApprovalEscalation() async throws {
        let parent = ceiling()
        let child = DelegationCapabilityCeiling(
            allowedToolNames: ["read_file", "run_command"],
            allowedMCPServers: ["approved", "unapproved"],
            allowedProjectPaths: ["/outside"], maxIterations: 20,
            maxTokens: nil, maxDelegationDepth: 2, requiresMutationApproval: false)
        XCTAssertFalse(parent.permits(child))
        let registry = AsyncDelegationRegistry()
        do {
            _ = try await registry.spawn(.init(role: "worker", task: "escalate",
                                                capabilityCeiling: child),
                                         parentCeiling: parent) { context in
                DelegationResult(handleID: context.handle.id, summary: "wrong")
            }
            XCTFail("a child must not widen inherited ceilings")
        } catch let error as DelegationRegistryError {
            guard case .capabilityEscalation = error else {
                return XCTFail("expected capabilityEscalation, got \(error)")
            }
        }
    }

    func testDepthBeyondChildCeilingIsRejectedBeforeSpawn() async throws {
        let registry = AsyncDelegationRegistry()
        let bounded = DelegationCapabilityCeiling(
            allowedToolNames: ["read_file"], allowedProjectPaths: ["/repo"],
            maxIterations: 2, maxDelegationDepth: 1)
        do {
            _ = try await registry.spawn(.init(role: "worker", task: "too deep", depth: 2,
                                                capabilityCeiling: bounded)) { context in
                DelegationResult(handleID: context.handle.id, summary: "wrong")
            }
            XCTFail("depth escalation must be rejected")
        } catch let error as DelegationRegistryError {
            XCTAssertEqual(error, .depthExceeded(2))
        }
    }

    private func ceiling() -> DelegationCapabilityCeiling {
        DelegationCapabilityCeiling(allowedToolNames: ["read_file", "write_file"],
                                    allowedMCPServers: ["approved"],
                                    allowedProjectPaths: ["/repo"], maxIterations: 10,
                                    maxTokens: 100, maxDelegationDepth: 1,
                                    requiresMutationApproval: true)
    }
}
