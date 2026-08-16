import Foundation
import XCTest
@testable import AgentCore

final class BuilderReviewProviderRouteTests: XCTestCase {
    private enum ReceiptMode: Sendable { case actual, missing, mismatch, failedDiagnostics }

    func testCouncilCarriesEveryActualResolvedReviewerRoute() async throws {
        let registry = makeRegistry(providerID: "route-reviewer")
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try BuilderTrustedTelemetryBinding(
                contractFingerprint: String(repeating: "a", count: 64),
                nodeID: "review", attempt: 1, stage: .review),
            registerBudgetAuthority: false
        ) {
            await CouncilPromotionJudge(
                providers: registry,
                roles: RoleBindings(default: ProviderBinding(
                    providerId: "route-reviewer", model: "dead-model")))
                .judge(PromotionContext(
                    goal: "review actual route", diffSummary: "one file changed",
                    testsPassed: true, testSummary: "tests passed",
                    signoffSummary: "verified"))
        }
        let verdict = try captured.0.get()
        XCTAssertEqual(verdict.votes.count, 4)
        XCTAssertTrue(verdict.votes.allSatisfy {
            $0.providerID == "route-reviewer" && $0.modelID == "live-model"
        })
        let successfulCompletions = captured.1.filter {
            $0.kind == .provider && $0.success && $0.name == "completion"
        }
        XCTAssertEqual(successfulCompletions.count, 4)
        XCTAssertTrue(successfulCompletions.allSatisfy {
            $0.providerID == "route-reviewer" && $0.modelID == "live-model"
        })
    }

    func testBuilderAcceptsActualProviderRegistryRoute() async throws {
        let receipt = try await runBuilderReview(mode: .actual)
        XCTAssertTrue(receipt.accepted)
        XCTAssertEqual(receipt.review.provider, "route-reviewer")
        XCTAssertEqual(receipt.review.model, "live-model")
    }

    func testBuilderRejectsReviewWithoutProviderInvocation() async throws {
        await assertReviewDenied(mode: .missing)
    }

    func testBuilderRejectsReceiptThatMismatchesActualProviderRoute() async throws {
        await assertReviewDenied(mode: .mismatch)
    }

    func testRejectedEmptyRouteSurfacesActualLensFailure() async {
        do {
            _ = try await runBuilderReview(mode: .failedDiagnostics)
            XCTFail("failed reviewer calls cannot approve")
        } catch let error as BuilderRunError {
            guard case .reviewRejected(let reasons) = error else {
                return XCTFail("expected reviewRejected, got \(error)")
            }
            XCTAssertTrue(reasons.joined(separator: " ").contains("qwen transport failed"))
            XCTAssertFalse(reasons.joined(separator: " ").contains("no trusted provider-route"))
        } catch {
            XCTFail("expected BuilderRunError, got \(error)")
        }
    }

    func testFailedCouncilCallsRemainCapturedInReviewTaskLocalScope() async throws {
        let registry = ProviderRegistry(
            providers: [FailingReviewProvider()], retryDelaysNanoseconds: [])
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try BuilderTrustedTelemetryBinding(
                contractFingerprint: String(repeating: "b", count: 64),
                nodeID: "failed-review", attempt: 1, stage: .review),
            registerBudgetAuthority: false
        ) {
            await CouncilPromotionJudge(
                providers: registry,
                roles: RoleBindings(default: ProviderBinding(
                    providerId: "failing-reviewer", model: "review-model")))
                .judge(PromotionContext(
                    goal: "surface failures", diffSummary: "diff",
                    testsPassed: true, testSummary: "passed",
                    signoffSummary: "verified"))
        }
        let verdict = try captured.0.get()
        let expectedFailure = "FAILED: \(AIProviderError.invalidAPIKey)"
        XCTAssertEqual(verdict.votes.count, 4)
        XCTAssertTrue(verdict.votes.allSatisfy {
            $0.failed && $0.reason == expectedFailure
                && $0.providerID == nil && $0.modelID == nil
        })
        let attempts = captured.1.filter { $0.kind == .provider }
        XCTAssertEqual(attempts.count, 4)
        XCTAssertTrue(attempts.allSatisfy {
            !$0.success && $0.providerID == "failing-reviewer"
                && $0.modelID == "review-model"
        })
    }

    func testCLIReviewerNameRequiresSealedCLIInvocation() async throws {
        do {
            _ = try await runBuilderReview(mode: .actual, providerID: "claude-cli")
            XCTFail("a generic provider cannot impersonate a trusted CLI reviewer")
        } catch let error as BuilderRunError {
            guard case .reviewRejected(let reasons) = error else {
                return XCTFail("expected reviewRejected, got \(error)")
            }
            XCTAssertTrue(reasons.joined(separator: " ").contains("trusted provider-route"))
        } catch {
            XCTFail("expected BuilderRunError, got \(error)")
        }
    }

    private func assertReviewDenied(mode: ReceiptMode) async {
        do {
            _ = try await runBuilderReview(mode: mode)
            XCTFail("review must be denied without an exact actual provider route")
        } catch let error as BuilderRunError {
            guard case .reviewRejected(let reasons) = error else {
                return XCTFail("expected reviewRejected, got \(error)")
            }
            XCTAssertTrue(reasons.joined(separator: " ").contains("trusted provider-route"))
        } catch {
            XCTFail("expected BuilderRunError, got \(error)")
        }
    }

    private func runBuilderReview(
        mode: ReceiptMode, providerID: String = "route-reviewer"
    ) async throws -> BuilderFinalReceipt {
        let fixture = BuilderRunTestFixtures.makeStore("builder-review-route")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registry = makeRegistry(providerID: providerID)
        let run = try BuilderRun(
            contract: BuilderRunTestFixtures.contract(id: "review-route-contract"),
            graph: try BuilderGraph(nodes: [
                BuilderNode(id: "build", objective: "build")
            ]),
            store: fixture.store,
            execute: { BuilderRunTestFixtures.worker(for: $0) },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in
                let completion: ProviderRegistry.RoutedCompletion?
                if mode == .missing || mode == .failedDiagnostics {
                    completion = nil
                } else {
                    completion = try await registry.completeWithRoute(
                        providerId: providerID, model: "dead-model",
                        messages: [ChatMessage(role: .user, content: "review")])
                }
                return BuilderReviewReceipt(
                    provider: mode == .failedDiagnostics ? ""
                        : (completion?.providerId ?? providerID),
                    model: mode == .mismatch ? "mismatched-model"
                        : (mode == .failedDiagnostics ? ""
                            : (completion?.model ?? "live-model")),
                    accepted: mode != .failedDiagnostics,
                    checks: [.init(
                        name: "review", passed: mode != .failedDiagnostics,
                        details: mode == .failedDiagnostics
                            ? "all reviewer calls failed" : "approved")],
                    findings: mode == .failedDiagnostics
                        ? ["Correctness: FAILED: qwen transport failed"] : [],
                    votes: mode == .failedDiagnostics
                        ? [.init(
                            lens: "Correctness", accepted: false,
                            reason: "FAILED: qwen transport failed", failed: true)] : nil)
            })
        return try await run.run()
    }

    private func makeRegistry(providerID: String) -> ProviderRegistry {
        ProviderRegistry(
            providers: [ResolvedReviewProvider(id: providerID)],
            retryDelaysNanoseconds: [],
            modelListFetch: { _, _ in .success(["live-model"]) })
    }
}

private final class FailingReviewProvider: ChatProvider, @unchecked Sendable {
    let id = "failing-reviewer"
    let name = "failing-reviewer"
    let iconName = "xmark.seal"
    let requiresAPIKey = false
    let keyAccount = "failing-reviewer"
    let defaultModel = "review-model"
    let availableModels = [AIModel(id: "review-model")]
    let supportsNativeTools = false
    let modelsListEndpoint: String? = nil

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        throw AIProviderError.invalidAPIKey
    }
}

private final class ResolvedReviewProvider: ChatProvider, @unchecked Sendable {
    let id: String
    let name: String
    let iconName = "checkmark.seal"
    let requiresAPIKey = false
    let keyAccount: String
    let defaultModel = "dead-model"
    let availableModels = [AIModel(id: "dead-model"), AIModel(id: "live-model")]
    let supportsNativeTools = false
    let modelsListEndpoint: String? = "https://example.invalid/models"

    init(id: String) { self.id = id; self.name = id; self.keyAccount = id }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard model == "live-model" else {
            throw AIProviderError.http(status: 404, body: "model not found")
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.delta("VERDICT: SHIP\nREASON: actual route reviewed"))
            continuation.yield(.usage(promptTokens: 7, completionTokens: 5))
            continuation.finish()
        }
    }
}
