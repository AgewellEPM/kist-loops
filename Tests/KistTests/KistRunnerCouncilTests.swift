import XCTest
import AgentCore
@testable import Kist

final class KistRunnerCouncilTests: XCTestCase {

    func testAutoCouncilRolesMakesHomogeneousCouncilHeterogeneousWhenAlternatesAreAvailable() {
        let registry = ProviderRegistry(
            providers: [
                CouncilCatalogProvider("openai"),
                CouncilCatalogProvider("deepseek"),
                CouncilCatalogProvider("gemini"),
            ],
            keyStore: CouncilCatalogNullKeys()
        )
        let base = RoleBindings(default: ProviderBinding(providerId: "openai", model: "gpt-4o"))

        let roles = KistRunner.autoCouncilRoles(base, registry: registry)

        XCTAssertEqual(roles.binding(for: .planner), ProviderBinding(providerId: "openai", model: "gpt-4o"))
        XCTAssertEqual(roles.binding(for: .worker), ProviderBinding(providerId: "deepseek"))
        XCTAssertEqual(roles.binding(for: .coder), ProviderBinding(providerId: "deepseek"))
        XCTAssertEqual(roles.binding(for: .critic), ProviderBinding(providerId: "gemini"))
        XCTAssertTrue(roles.isHeterogeneous)
    }

    func testAutoCouncilRolesRespectsAlreadyHeterogeneousExplicitTeam() {
        let registry = ProviderRegistry(
            providers: [
                CouncilCatalogProvider("openai"),
                CouncilCatalogProvider("deepseek"),
                CouncilCatalogProvider("gemini"),
                CouncilCatalogProvider("mimo"),
            ],
            keyStore: CouncilCatalogNullKeys()
        )
        let explicit = RoleBindings(default: ProviderBinding(providerId: "openai"))
            .binding(.worker, to: ProviderBinding(providerId: "mimo"))
            .binding(.coder, to: ProviderBinding(providerId: "deepseek"))
            .binding(.critic, to: ProviderBinding(providerId: "gemini"))

        XCTAssertEqual(KistRunner.autoCouncilRoles(explicit, registry: registry), explicit)
    }

    func testAutoCouncilRolesLeavesSingleProviderWhenNoAlternatesAreConfigured() {
        let registry = ProviderRegistry(
            providers: [CouncilCatalogProvider("openai")],
            keyStore: CouncilCatalogNullKeys()
        )
        let base = RoleBindings(default: ProviderBinding(providerId: "openai"))

        XCTAssertEqual(KistRunner.autoCouncilRoles(base, registry: registry), base)
    }

    func testCouncilSeedsProjectTaskBoardForGoalsCommand() throws {
        let root = NSTemporaryDirectory() + "council-board-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let artifact = (root as NSString).appendingPathComponent(".mythos/council/board.md")
        let finalPlan = """
        Decision:
        - Fix the highest-risk agent loop gaps.

        Kanban Board:
        | Status | Task | Owner | Acceptance |
        | --- | --- | --- | --- |
        | Ready | Forced synthesize after long read-only loops | builder | Budget exhaustion still returns a final answer |
        | Ready | Harden Grok audit harness | critic | Shallow directory-only audits are rejected |

        Test plan:
        - swift test --filter ForcedSynthesisTests
        """

        let plan = KistRunner.seedCouncilProjectBoard(goal: "turn consensus into work",
                                                      finalPlan: finalPlan,
                                                      artifactPath: artifact,
                                                      root: root)
        let reloaded = PlanStore(projectRoot: root).load()

        XCTAssertEqual(reloaded, plan)
        XCTAssertEqual(reloaded.tasks.count, 3)
        XCTAssertTrue(reloaded.render().contains("ACTION: Forced synthesize after long read-only loops"))
        XCTAssertTrue(reloaded.render().contains("TEST: swift test --filter ForcedSynthesisTests"))
        XCTAssertTrue(reloaded.tasks.allSatisfy { $0.link == artifact })
    }
}

private struct CouncilCatalogNullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private struct CouncilCatalogProvider: ChatProvider {
    let id: String
    let name: String
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount: String
    let defaultModel: String
    let availableModels: [AIModel]

    init(_ id: String) {
        self.id = id
        self.name = id
        self.keyAccount = id
        self.defaultModel = "\(id)-default"
        self.availableModels = [AIModel(id: "\(id)-default")]
    }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.delta("ok"))
            continuation.finish()
        }
    }
}
