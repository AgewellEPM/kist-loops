import XCTest
@testable import Kist
import AgentCore

final class LocalFirstRoutingTests: XCTestCase {
    private let local = ProviderBinding(providerId: "ollama", model: "qwen3.5:9b-q4_K_M")
    private let cloud = ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro")
    private var config: KistConfig {
        KistConfig(provider: local.providerId, model: local.model, autoRouting: true, localFirst: true)
    }
    private var router: AutoModelRouter {
        AutoModelRouter(candidates: [
            .init(binding: local, vision: true, reasoning: true, contextTokens: 16_384, fast: true),
            .init(binding: cloud, vision: false, reasoning: true, contextTokens: 128_000, fast: false)
        ], fallback: local)
    }

    func testHardTurnEscalatesAndNextRoutineTurnReturnsLocal() {
        let route = KistRunner.interactiveAutoRoute(autoRouting: true, config: config,
            noMemory: true, root: "/unused", registry: ProviderRegistry(providers: []),
            autoRouter: router, avoidProvider: { _ in false })
        XCTAssertEqual(route("design a distributed system", false, local).binding, cloud)
        XCTAssertEqual(route("create card.json", false, cloud).binding, local)
        XCTAssertEqual(route("explain this screenshot", true, cloud).binding, local)
    }

    func testUnavailableCloudAndLocalOnlyCatalogNeverEscapeBoundary() {
        XCTAssertEqual(router.localFirstDecision("prove this theorem", hasMedia: false,
            local: local, avoid: { $0 == "deepseek" }).binding, local)
        let offline = AutoModelRouter(candidates: [router.candidates[0]], fallback: local)
        XCTAssertEqual(offline.localFirstDecision("design a system", hasMedia: false,
            local: local).binding, local)
        XCTAssertEqual(router.localFirstDecision("hello", hasMedia: false, local: local,
            avoid: { $0 == "ollama" }).binding, cloud)
    }

    func testOptInAndExplicitModelPinRemainDistinct() {
        XCTAssertNil(KistConfig.parse(["provider": "ollama", "model": local.model!]).localFirstBinding)
        var denied = config
        denied.allowedProviders = ["deepseek"]
        XCTAssertNil(denied.localFirstBinding)
        XCTAssertFalse(AutoModelRouter.routingEnabled(pickedInteractively: false, cliProvider: true,
            configProvider: true, configAutoRouting: true))
        XCTAssertFalse(AutoModelRouter.routingEnabled(pickedInteractively: false, cliProvider: false,
            cliModel: true, configProvider: true, configAutoRouting: true))
        let route = KistRunner.interactiveAutoRoute(autoRouting: false, config: config,
            noMemory: true, root: "/unused", registry: ProviderRegistry(providers: []),
            autoRouter: router, avoidProvider: { _ in false })
        XCTAssertEqual(route("hello", false, cloud).binding, cloud)
    }

    func testBuildEscalationPreservesExplicitRolesAndOrdinaryLocalWork() {
        let roles = RoleBindings(default: local)
        let opts = KistOptions(project: "/unused")
        func route(_ goal: String, _ options: KistOptions, _ team: RoleBindings) -> RoleBindings {
            KistRunner.localFirstBuildRoles(team, opts: options, goal: goal, config: config,
                router: router, avoid: { _ in false }).roles
        }
        XCTAssertEqual(route("create card.json", opts, roles), roles)
        let hard = route("refactor concurrent scheduler", opts, roles)
        for role in [AgentRole.planner, .worker, .coder] {
            XCTAssertEqual(hard.binding(for: role), cloud)
        }
        XCTAssertEqual(hard.binding(for: .critic), local)
        var pinned = opts
        pinned.providerId = "ollama"
        XCTAssertEqual(route("refactor concurrent scheduler", pinned, roles), roles)
        pinned = opts
        pinned.coderSpec = "ollama:qwen3.5:9b-q4_K_M"
        XCTAssertEqual(route("refactor concurrent scheduler", pinned, roles), roles)
        let custom = roles.binding(.coder, to: cloud)
        XCTAssertEqual(route("refactor concurrent scheduler", opts, custom), custom)
    }

    func testCapacityFallbackCannotTurnDenialIntoAuthority() {
        XCTAssertNotNil(KistREPL.modelSubstitutionReason(success: false,
            summary: "Provider configuration error: local context capacity estimate exceeded: 17000"))
        XCTAssertNil(KistREPL.modelSubstitutionReason(success: false,
            summary: "authorization denied; local context capacity estimate exceeded: 17000"))
    }

    func testLocalPlannerDoesNotReserveCloudThinkingOverhead() {
        let registry = ProviderRegistry(providers: [OllamaProvider()])
        XCTAssertTrue(registry.capabilities(providerId: "ollama", model: local.model).reasoning)
        XCTAssertEqual(KistRunner.builderPreflightFramingAllowance(providerID: "ollama",
            model: local.model, registry: registry), 0)
        XCTAssertEqual(KistRunner.builderPreflightFramingAllowance(providerID: "deepseek",
            model: "deepseek-v4-pro", registry: registry), 32_768)
    }

    func testUnspecifiedLocalRoleUsesConfiguredModelInsteadOfLegacyLlama() {
        XCTAssertEqual(KistRunner.configuredLocalProvider(OllamaProvider(), config: config).defaultModel, local.model)
        XCTAssertEqual(KistRunner.configuredLocalProvider(OllamaProvider(), config: .init()).defaultModel, "llama3.1")
        XCTAssertEqual(KistRunner.configuredLocalProvider(OllamaProvider.cobol(), config: config).id, "cobol")
        XCTAssertTrue((KistRunner.configuredLocalProvider(OllamaProvider(), config: config) as? OllamaProvider)?.automaticAcquisition == true)
        XCTAssertFalse((KistRunner.configuredLocalProvider(OllamaProvider(), config: .init()) as? OllamaProvider)?.automaticAcquisition == true)
    }

    func testPlanningQualityRetryExcludesAuthorityBudgetAndCancellation() {
        XCTAssertTrue(KistRunner.localPlanningCanEscalate(KistRunner.BuilderPreflightError.invalid(
            "planner-quality: duplicate or conflicting operation for card.json; initial_output{hash}")))
        XCTAssertTrue(KistRunner.localPlanningCanEscalate(KistRunner.BuilderPreflightError.invalid(
            "single schema-repair pass failed: builder preflight rejected: duplicate or conflicting operation for card.json; initial_output{hash}")))
        XCTAssertTrue(KistRunner.localPlanningCanEscalate(AIProviderError.configuration(
            "local context capacity estimate exceeded: 17000 tokens")))
        for reason in ["protected or non-normal path: .kist/plan.json", "path escapes project root: ../other",
                       "unsafe or malformed verification command", "schema repair changed or invented mutation authority",
                       "untyped schema repair requires explicit host authority delegation"] {
            XCTAssertFalse(KistRunner.localPlanningCanEscalate(KistRunner.BuilderPreflightError.invalid(
                "single schema-repair pass failed: builder preflight rejected: " + reason)))
        }
        XCTAssertFalse(KistRunner.localPlanningCanEscalate(KistRunner.BuilderPreflightError.budget("insufficient tokens")))
        XCTAssertFalse(KistRunner.localPlanningCanEscalate(CancellationError()))
    }

    func testWireIdentityPreservesQuantizationTagAndRemainsExact() throws {
        let registry = ProviderRegistry(providers: [OllamaProvider()])
        let declared = try KistRunner.builderWireProducers(RoleBindings(default: local), registry: registry)
        XCTAssertEqual(declared, ["ollama:qwen3.5:9b-q4_K_M"])
        let identity = try KistRunner.builderModelIdentity(XCTUnwrap(declared.first))
        XCTAssertEqual(identity, try BuilderModelIdentity(providerID: "ollama", modelID: "qwen3.5:9b-q4_K_M"))
        XCTAssertNotEqual(identity, try BuilderModelIdentity(providerID: "ollama", modelID: "qwen3.5:9b-q4_k_m"),
            "Do not weaken strict telemetry identity matching to hide the contract bug")
    }
}
