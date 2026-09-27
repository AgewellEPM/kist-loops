import XCTest
import AgentCore
@testable import Kist

/// Build-lane provider resilience (0.17.63). Born from the 2026-09-27 run-log census: every
/// `intent=build` turn exited 1/2 for weeks while chat/research turns completed. The build lane
/// ran the pinned planner (a drained OpenAI account) with no fallback and refused the whole run
/// on its first live failure — "he researches fine but can't code".
final class BuildLaneResilienceTests: XCTestCase {
    private let truthTeam = RoleBindings(
        default: ProviderBinding(providerId: "openai", model: "gpt-5.5"),
        [.planner: ProviderBinding(providerId: "openai", model: "gpt-5.5"),
         .worker: ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro"),
         .coder: ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro"),
         .critic: ProviderBinding(providerId: "openai", model: "gpt-5.5")])

    private func usable(_ ids: Set<String>) -> (String) -> Bool { { ids.contains($0.lowercased()) } }
    private func benched(_ ids: Set<String>) -> (String) -> Bool { { ids.contains($0.lowercased()) } }

    // MARK: up-front warming (known-benched providers)

    func testBenchedPlannerAndCriticMoveToWarmProvidersCoderUntouched() {
        let warmed = KistRunner.warmRoleBindings(
            truthTeam, benched: benched(["openai"]),
            usable: usable(["openai", "deepseek", "gemini", "grok"]),
            benchReason: { _ in "quota" })
        XCTAssertEqual(warmed.roles.binding(for: .planner).providerId, "gemini")
        XCTAssertEqual(warmed.roles.binding(for: .critic).providerId, "gemini")
        XCTAssertEqual(warmed.roles.binding(for: .coder), truthTeam.binding(for: .coder), "a warm pin is never touched")
        XCTAssertEqual(warmed.roles.binding(for: .worker), truthTeam.binding(for: .worker))
        XCTAssertEqual(warmed.substitutions.map(\.role), [.planner, .critic])
        XCTAssertEqual(warmed.substitutions.first?.reason, "quota")
        XCTAssertEqual(warmed.stranded, [])
    }

    func testCriticNeverLandsOnTheCoderProvider() {
        // gemini gone too: planner takes deepseek (next warm), so the critic must skip deepseek
        // (the coder) and take grok — the independent-review invariant survives substitution.
        let warmed = KistRunner.warmRoleBindings(
            truthTeam, benched: benched(["openai", "gemini"]),
            usable: usable(["openai", "deepseek", "gemini", "grok"]))
        XCTAssertEqual(warmed.roles.binding(for: .planner).providerId, "deepseek")
        XCTAssertEqual(warmed.roles.binding(for: .critic).providerId, "grok")
        XCTAssertNotEqual(warmed.roles.binding(for: .critic).providerId,
                          warmed.roles.binding(for: .coder).providerId)
    }

    func testSubstituteMustBeConfiguredNotJustWarm() {
        // gemini is warm but has no key → skipped; codex-cli is keyless and registered → chosen.
        let warmed = KistRunner.warmRoleBindings(
            truthTeam, benched: benched(["openai"]),
            usable: usable(["openai", "deepseek", "codex-cli"]))
        XCTAssertEqual(warmed.roles.binding(for: .planner).providerId, "codex-cli")
    }

    func testFailOpenKeepsThePinWhenNothingWarmIsConfigured() {
        let warmed = KistRunner.warmRoleBindings(
            truthTeam, benched: benched(["openai"]),
            usable: usable(["openai", "deepseek"]))
        // planner: deepseek is warm+usable → substituted. critic: only deepseek remains and it is
        // the coder → stranded, pin kept (the run then fails loudly on the real error, as before).
        XCTAssertEqual(warmed.roles.binding(for: .planner).providerId, "deepseek")
        XCTAssertEqual(warmed.roles.binding(for: .critic), truthTeam.binding(for: .critic))
        XCTAssertEqual(warmed.stranded, [.critic])
    }

    func testNothingBenchedIsAByteForByteNoOp() {
        let warmed = KistRunner.warmRoleBindings(
            truthTeam, benched: { _ in false }, usable: usable(["openai", "deepseek", "gemini"]))
        XCTAssertEqual(warmed.roles, truthTeam)
        XCTAssertTrue(warmed.substitutions.isEmpty)
        XCTAssertTrue(warmed.stranded.isEmpty)
    }

    func testRegistryWiringTreatsKeylessProvidersAsUsableAndKeyedWithoutKeyAsNot() {
        let registry = ProviderRegistry(providers: [
            stubProvider("openai", requiresAPIKey: true),      // keyed, no key in this registry
            stubProvider("gemini", requiresAPIKey: false),     // keyless → usable
        ])
        let usable = KistRunner.providerUsable(registry)
        XCTAssertFalse(usable("openai"))
        XCTAssertTrue(usable("gemini"))
        XCTAssertFalse(usable("nonexistent"))
    }

    // MARK: inner critic must be a declared producer provider

    func testCriticOnAThirdProviderFollowsThePlannerUnlessPinned() {
        let warmed = RoleBindings(
            default: ProviderBinding(providerId: "deepseek"),
            [.planner: ProviderBinding(providerId: "deepseek"),
             .worker: ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro"),
             .coder: ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro"),
             .critic: ProviderBinding(providerId: "claude-cli")])
        let aligned = KistRunner.alignInnerCriticWithProducers(warmed, criticPinnedExplicitly: false)
        XCTAssertTrue(aligned.moved)
        XCTAssertEqual(aligned.roles.binding(for: .critic), warmed.binding(for: .planner))
        let pinned = KistRunner.alignInnerCriticWithProducers(warmed, criticPinnedExplicitly: true)
        XCTAssertFalse(pinned.moved, "an explicit --critic is the operator's call")
        XCTAssertEqual(pinned.roles, warmed)
    }

    func testCriticAlreadyOnAProducerProviderIsLeftAlone() {
        let aligned = KistRunner.alignInnerCriticWithProducers(truthTeam, criticPinnedExplicitly: false)
        XCTAssertFalse(aligned.moved, "openai critic with openai planner is already producer-bound")
        XCTAssertEqual(aligned.roles, truthTeam)
    }

    // MARK: substitution after a LIVE failure (provider was not benched yet)

    func testPlannerSubstituteAfterLiveFailureSkipsTheFailedAndBenchedProviders() {
        let substitute = KistRunner.warmPlannerSubstitute(
            afterFailing: "openai", roles: truthTeam,
            benched: benched(["gemini"]),
            usable: usable(["openai", "deepseek", "gemini", "grok"]))
        XCTAssertEqual(substitute?.providerId, "deepseek")
    }

    func testPlannerSubstituteIsNilWhenNothingWarmRemains() {
        XCTAssertNil(KistRunner.warmPlannerSubstitute(
            afterFailing: "openai", roles: truthTeam,
            benched: benched(["deepseek", "gemini"]),
            usable: usable(["openai", "deepseek", "gemini"])))
    }

    // MARK: failure classification (what earns a cooldown + one retry)

    func testQuotaExhaustionIsALiveFailureWithTheLongCooldown() throws {
        let error = ProviderQuotaExhaustion.classify(
            status: 429, body: #"{"error":{"type":"insufficient_quota","code":"credit_balance_exhausted"}}"#)
        let failure = try XCTUnwrap(KistRunner.buildLaneProviderFailure(error))
        XCTAssertTrue(failure.quotaExhausted)
        XCTAssertEqual(failure.cooldownTTL, ProviderQuotaExhaustion.cooldownTTL)
        XCTAssertTrue(failure.summary.contains("credits"))
    }

    func testRateLimitTransportTimeoutAnd5xxAreLiveFailuresWithDefaultCooldown() throws {
        let cases: [AIProviderError] = [
            .rateLimited, .transport("connection reset"), .http(status: 503, body: ""),
            .streamTimedOut(provider: "openai", model: "gpt-5.5", phase: .firstEvent),
        ]
        for error in cases {
            let failure = try XCTUnwrap(KistRunner.buildLaneProviderFailure(error), "\(error)")
            XCTAssertFalse(failure.quotaExhausted, "\(error)")
            XCTAssertEqual(failure.cooldownTTL, ProviderCooldownStore.defaultTTL, "\(error)")
        }
    }

    func testValidationBudgetCancellationAndBadRequestsAreNotLiveFailures() {
        XCTAssertNil(KistRunner.buildLaneProviderFailure(CancellationError()))
        XCTAssertNil(KistRunner.buildLaneProviderFailure(AIProviderError.transport("completion cancelled")),
                     "an ESC surfaces as this transport error and must not bench a healthy provider")
        XCTAssertNil(KistRunner.buildLaneProviderFailure(AIProviderError.invalidResponse("not json")))
        XCTAssertNil(KistRunner.buildLaneProviderFailure(AIProviderError.configuration("bad base url")))
        XCTAssertNil(KistRunner.buildLaneProviderFailure(AIProviderError.http(status: 400, body: "bad request")))
        XCTAssertNil(KistRunner.buildLaneProviderFailure(
            KistRunner.BuilderPreflightError.invalid("plan named a directory")))
    }

    func testSubscriptionCLIUsageLimitIsQuotaShaped() throws {
        let stderr = "You've hit your usage limit. Upgrade to Pro, visit chatgpt.com/codex/settings/usage or try again at 1:27 AM."
        let failure = try XCTUnwrap(KistRunner.buildLaneProviderFailure(
            CLIProviderError.exited(binary: "codex", code: 1, stderr: stderr)))
        XCTAssertTrue(failure.quotaExhausted)
        XCTAssertEqual(failure.cooldownTTL, ProviderQuotaExhaustion.cooldownTTL)
    }

    func testOtherCLIFailuresAreLiveButProtocolSlipsAreNot() throws {
        let exited = try XCTUnwrap(KistRunner.buildLaneProviderFailure(
            CLIProviderError.exited(binary: "claude", code: 2, stderr: "segfault")))
        XCTAssertEqual(exited.cooldownTTL, ProviderCooldownStore.defaultTTL)
        let timedOut = try XCTUnwrap(KistRunner.buildLaneProviderFailure(
            CLIProviderError.timedOut(binary: "claude", seconds: 60)))
        XCTAssertEqual(timedOut.cooldownTTL, ProviderCooldownStore.defaultTTL)
        let notRunnable = try XCTUnwrap(KistRunner.buildLaneProviderFailure(
            CLIProviderError.notRunnable(binary: "codex", detail: "not on PATH")))
        XCTAssertEqual(notRunnable.cooldownTTL, ProviderQuotaExhaustion.cooldownTTL)
        XCTAssertNil(KistRunner.buildLaneProviderFailure(
            CLIProviderError.invalidStructuredOutput(binary: "codex", detail: "not json")))
    }

    func testRejectedKeyIsSubstitutableAndBenchedForTheLongWindow() throws {
        let failure = try XCTUnwrap(KistRunner.buildLaneProviderFailure(AIProviderError.invalidAPIKey))
        XCTAssertEqual(failure.cooldownTTL, ProviderQuotaExhaustion.cooldownTTL)
    }

    // MARK: reviewer selection ranks benched providers last (fail-open)

    func testBenchedPinnedCriticYieldsToAWarmDistinctReviewer() throws {
        let registry = reviewerRegistry([("openai", "gpt-5.5"), ("gemini", "g-review"), ("grok", "x-review")])
        let selection = try XCTUnwrap(KistRunner.independentReviewerSelection(
            preferred: ProviderBinding(providerId: "openai", model: "gpt-5.5"),
            producingIdentities: Set(["deepseek:deepseek-v4-pro"]), registry: registry,
            benched: benched(["openai"])))
        XCTAssertEqual(selection.binding.providerId, "gemini", "warm alternates rank ahead of the benched pin")
    }

    func testAllBenchedFailsOpenToThePinnedCritic() throws {
        let registry = reviewerRegistry([("openai", "gpt-5.5"), ("gemini", "g-review")])
        let selection = try XCTUnwrap(KistRunner.independentReviewerSelection(
            preferred: ProviderBinding(providerId: "openai", model: "gpt-5.5"),
            producingIdentities: Set(["deepseek:deepseek-v4-pro"]), registry: registry,
            benched: benched(["openai", "gemini"])))
        XCTAssertEqual(selection.binding.providerId, "openai", "a reviewer must still exist when everything is cooling")
    }

    func testBenchedGateNeverDefeatsTheDistinctIdentityRequirement() {
        let registry = reviewerRegistry([("openai", "gpt-5.5")])
        XCTAssertNil(KistRunner.independentReviewerSelection(
            preferred: ProviderBinding(providerId: "openai", model: "gpt-5.5"),
            producingIdentities: Set(["openai:gpt-5.5"]), registry: registry,
            benched: benched(["openai"])))
    }

    // MARK: cooldown TTL from a failure summary (REPL / media / one-shot record sites)

    func testCooldownTTLIsHoursForADrainedAccountMinutesOtherwise() {
        XCTAssertEqual(KistREPL.providerCooldownTTL(forFailureSummary:
            "provider 'openai' error: The provider account is out of credits/quota (billing)"),
            ProviderQuotaExhaustion.cooldownTTL)
        XCTAssertEqual(KistREPL.providerCooldownTTL(forFailureSummary: "provider 'gemini' error: rateLimited"),
                       ProviderCooldownStore.defaultTTL)
    }

    func testDrainedAccountSummaryIsSubstitutable() {
        XCTAssertEqual(KistREPL.modelSubstitutionReason(
            success: false, summary: "provider 'openai' error: quota_exhausted: insufficient_quota"),
            "provider/transient failure")
        XCTAssertEqual(KistREPL.modelSubstitutionReason(
            success: false, summary: "The provider account is out of credits/quota (billing), not a transient rate limit (HTTP 429)."),
            "provider/transient failure")
    }

    // MARK: per-site pins (multi-site fix discipline: each lane names itself)

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KistTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    func testSiteBuilderLaunchWarmsRolesBeforePreflightAndReviewerSelection() throws {
        let src = try source("Sources/Kist/KistRunner+Builder.swift")
        let warm = try XCTUnwrap(src.range(of: "warmRoleBindings(pinnedRoles"))
        let preflight = try XCTUnwrap(src.range(of: "builderGeneratePreflightEnvelope("))
        let producers = try XCTUnwrap(src.range(of: "configuredProducerIdentities(\n            roles: roles"))
        XCTAssertLessThan(warm.lowerBound, preflight.lowerBound, "roles are warmed before the sealed planning pass")
        XCTAssertLessThan(preflight.lowerBound, producers.lowerBound,
                          "the planning pass (which may substitute the planner) runs before producer identities are fixed")
        XCTAssertTrue(src.contains("buildLaneProviderFailure(error)"), "preflight catch classifies live provider failures")
        XCTAssertTrue(src.contains("warmPlannerSubstitute("), "preflight retries once on a warm planner")
        XCTAssertTrue(src.contains("liveCooldowns.record(plannerProviderID, ttl: failure.cooldownTTL)"),
                      "a failed planner is benched cross-process with the failure's TTL")
        XCTAssertTrue(src.contains("builder could not start: \\(reason)"),
                      "a provider failure is reported as a provider failure, not as an unsafe mutation")
        let rewarm = try XCTUnwrap(src.range(of: "warmRoleBindings(teamRoles"))
        XCTAssertLessThan(preflight.lowerBound, rewarm.lowerBound, "roles are re-warmed AFTER the planning pass")
        XCTAssertLessThan(rewarm.lowerBound, producers.lowerBound,
                          "the re-warm lands before producer identities and reviewer selection are fixed")
    }

    /// (label, file, expected call-site text)
    private let reviewerSites: [(String, String, String)] = [
        ("builder launch", "Sources/Kist/KistRunner+Builder.swift", "benched: benchedProvider"),
        ("builder review", "Sources/Kist/KistRunner+BuilderReview.swift", "benched: liveProviderBenched()"),
        ("great-loop team review", "Sources/Kist/KistRunner+GreatLoop.swift", "benched: liveProviderBenched()"),
        ("autonomy mission forwarder", "Sources/Kist/KistRunner+AutonomyMission.swift", "benched: benched)"),
    ]

    func testEveryReviewerSelectionSitePassesTheLiveBenchedGate() throws {
        for (label, file, expected) in reviewerSites {
            let src = try source(file)
            XCTAssertTrue(src.contains(expected),
                          "\(label) (\(file)) must hand the live benched gate to independentReviewerSelection")
        }
    }

    /// (label, file, expected record shape)
    private let cooldownRecordSites: [(String, String, String)] = [
        ("REPL text/media hook", "Sources/Kist/KistRunner.swift",
         "ttl: KistREPL.providerCooldownTTL(forFailureSummary: summary)"),
        ("one-shot lane", "Sources/Kist/KistRunner+ReadOnlyPolicy.swift",
         "ttl: KistREPL.providerCooldownTTL(forFailureSummary: outcome.summary)"),
    ]

    func testEveryCooldownRecordSiteUsesTheSummaryDrivenTTL() throws {
        for (label, file, expected) in cooldownRecordSites {
            let src = try source(file)
            XCTAssertTrue(src.contains(expected), "\(label) (\(file)) must bench with the summary-driven TTL")
        }
    }

    // MARK: fixtures

    private func stubProvider(_ id: String, requiresAPIKey: Bool) -> any ChatProvider {
        OpenAICompatibleProvider(
            id: id, name: id, iconName: "cpu", keyAccount: id + "_key",
            endpoint: "http://127.0.0.1/" + id, defaultModel: "m",
            availableModels: [AIModel(id: "m")], requiresAPIKey: requiresAPIKey)
    }

    private func reviewerRegistry(_ identities: [(String, String)]) -> ProviderRegistry {
        let providers: [any ChatProvider] = identities.map { provider, model in
            OpenAICompatibleProvider(
                id: provider, name: provider, iconName: "cpu", keyAccount: provider + "_key",
                endpoint: "http://127.0.0.1/" + provider, defaultModel: model,
                availableModels: [AIModel(id: model)], requiresAPIKey: false)
        }
        return ProviderRegistry(providers: providers)
    }
}
