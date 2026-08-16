import Dispatch
import Foundation
import XCTest
@testable import AgentCore

final class CouncilPromotionConcurrencyTests: XCTestCase {
    func testLensesRunConcurrentlyAndReturnInCanonicalOrder() async {
        let probe = CouncilReviewProbe()
        let provider = ControlledCouncilProvider(probe: probe, behaviors: [
            "Correctness": .ship(delay: 240_000_000),
            "Security": .ship(delay: 40_000_000),
            "Worth": .ship(delay: 140_000_000),
            "Completeness": .ship(delay: 80_000_000),
        ])
        let started = DispatchTime.now().uptimeNanoseconds
        let verdict = await judge(provider: provider, deadline: 1)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        let maximumActive = await probe.maximumActive

        XCTAssertLessThan(elapsed, 0.42, "four serial lenses would take about 0.50 seconds")
        XCTAssertEqual(maximumActive, 4)
        XCTAssertEqual(verdict.votes.map(\.name), [
            "Correctness", "Security", "Worth", "Completeness",
        ])
        XCTAssertTrue(verdict.isShipWorthy)
    }

    func testDeadlineFailsClosedWithoutRouteAndCancelsProviderCompletion() async throws {
        let probe = CouncilReviewProbe()
        let provider = ControlledCouncilProvider(
            probe: probe, defaultBehavior: .ship(delay: 2_000_000_000))
        // Leave enough scheduling room for every routed completion to enter the
        // provider before exercising cancellation. The separate uncooperative
        // test pins the short, non-blocking fail-closed deadline behavior.
        let verdict = await judge(provider: provider, deadline: 0.3)

        XCTAssertFalse(verdict.isShipWorthy)
        XCTAssertEqual(verdict.votes.count, 4)
        XCTAssertTrue(verdict.votes.allSatisfy {
            $0.failed && !$0.shipWorthy
                && $0.reason == "review deadline exceeded after 0.300 seconds"
                && $0.providerID == nil && $0.modelID == nil
        })
        for _ in 0..<20 {
            if await probe.cancellationCount == 4 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let cancellations = await probe.cancellationCount
        XCTAssertEqual(cancellations, 4)
    }

    func testUncooperativeProviderCannotHoldStructuredCouncilOpen() async {
        let probe = CouncilReviewProbe()
        let provider = ControlledCouncilProvider(
            probe: probe, defaultBehavior: .uncooperativeShip(delay: 400_000_000))
        let started = DispatchTime.now().uptimeNanoseconds
        let verdict = await judge(provider: provider, deadline: 0.02)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        XCTAssertLessThan(elapsed, 0.20)
        XCTAssertFalse(verdict.isShipWorthy)
        XCTAssertTrue(verdict.votes.allSatisfy {
            $0.failed && $0.providerID == nil && $0.modelID == nil
        })
    }

    func testTimeoutIsNeitherApprovalNorVetoWhileHoldStillVetoesQuorum() async {
        let quorumProbe = CouncilReviewProbe()
        let quorumProvider = ControlledCouncilProvider(probe: quorumProbe, behaviors: [
            "Correctness": .ship(delay: 1_000_000),
            "Security": .ship(delay: 1_000_000),
            "Worth": .ship(delay: 1_000_000),
            "Completeness": .ship(delay: 200_000_000),
        ])
        let quorum = await judge(provider: quorumProvider, deadline: 0.03)
        XCTAssertTrue(quorum.isShipWorthy, "three real SHIP votes still satisfy the configured quorum")
        XCTAssertEqual(quorum.votes.filter(\.failed).map(\.name), ["Completeness"])

        let vetoProbe = CouncilReviewProbe()
        let vetoProvider = ControlledCouncilProvider(probe: vetoProbe, behaviors: [
            "Correctness": .ship(delay: 1_000_000),
            "Security": .hold(delay: 1_000_000),
            "Worth": .ship(delay: 1_000_000),
            "Completeness": .ship(delay: 200_000_000),
        ])
        let veto = await judge(provider: vetoProvider, deadline: 0.03)
        XCTAssertFalse(veto.isShipWorthy)
        XCTAssertTrue(veto.summary.contains("Security"))
        XCTAssertEqual(veto.votes.filter(\.failed).map(\.name), ["Completeness"])
    }

    private func judge(provider: ControlledCouncilProvider,
                       deadline: TimeInterval) async -> CouncilPromotionVerdict {
        await CouncilPromotionJudge(
            providers: ProviderRegistry(providers: [provider], retryDelaysNanoseconds: []),
            roles: RoleBindings(default: ProviderBinding(
                providerId: provider.id, model: provider.defaultModel)),
            lensDeadline: deadline
        ).judge(PromotionContext(
            goal: "exercise concurrent promotion review",
            diffSummary: "one governed file changed",
            testsPassed: true,
            testSummary: "all deterministic tests passed",
            signoffSummary: "host verification passed"))
    }
}

private enum ControlledCouncilBehavior: Sendable {
    case ship(delay: UInt64)
    case hold(delay: UInt64)
    case uncooperativeShip(delay: UInt64)
}

private actor CouncilReviewProbe {
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var cancellationCount = 0

    func started() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func finished() { active -= 1 }
    func cancelled() { cancellationCount += 1 }
}

private final class ControlledCouncilProvider: ChatProvider, @unchecked Sendable {
    let id = "controlled-council"
    let name = "controlled-council"
    let iconName = "person.3"
    let requiresAPIKey = false
    let keyAccount = "controlled-council"
    let defaultModel = "review-model"
    let availableModels = [AIModel(id: "review-model")]
    let supportsNativeTools = false
    let modelsListEndpoint: String? = nil

    private let probe: CouncilReviewProbe
    private let behaviors: [String: ControlledCouncilBehavior]
    private let defaultBehavior: ControlledCouncilBehavior

    init(probe: CouncilReviewProbe,
         behaviors: [String: ControlledCouncilBehavior] = [:],
         defaultBehavior: ControlledCouncilBehavior = .ship(delay: 0)) {
        self.probe = probe
        self.behaviors = behaviors
        self.defaultBehavior = defaultBehavior
    }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let lens = ["Correctness", "Security", "Worth", "Completeness"]
            .first { prompt.contains("Lens: \($0)") } ?? "unknown"
        let behavior = behaviors[lens] ?? defaultBehavior
        await probe.started()
        do {
            switch behavior {
            case .ship(let delay), .hold(let delay):
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            case .uncooperativeShip(let delay):
                await Self.uncancellableSleep(nanoseconds: delay)
            }
        } catch {
            await probe.cancelled()
            await probe.finished()
            throw error
        }
        await probe.finished()

        let text: String
        if case .hold = behavior {
            text = "VERDICT: HOLD\nREASON: controlled veto"
        } else {
            text = "VERDICT: SHIP\nREASON: controlled approval"
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.delta(text))
            continuation.yield(.usage(promptTokens: 10, completionTokens: 5))
            continuation.finish()
        }
    }

    private static func uncancellableSleep(nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                continuation.resume()
            }
        }
    }
}
