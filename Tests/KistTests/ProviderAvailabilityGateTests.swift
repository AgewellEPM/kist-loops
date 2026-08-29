import XCTest
import AgentCore
@testable import Kist

/// Routing audit 2026-08-25: provider availability (cooldown ledger + health daemon) must gate
/// EVERY selection path, not just the explicit-switch branch. Behavior tests per selection site,
/// then one source pin per file (multi-site fix discipline: a regressed site names itself).
final class ProviderAvailabilityGateTests: XCTestCase {

    // MARK: AutoModelRouter.route() — the "stay on current model" path

    private let ollama = ProviderBinding(providerId: "ollama", model: "gemma3:4b")
    private let openaiCandidate = AutoModelRouter.Candidate(
        binding: ProviderBinding(providerId: "openai", model: "gpt-5"),
        vision: false, reasoning: true, contextTokens: 200_000, fast: false)

    private func router() -> AutoModelRouter {
        AutoModelRouter(candidates: [openaiCandidate],
                        fallback: ProviderBinding(providerId: "openai", model: "gpt-5"))
    }

    func testStayPathSwitchesOffUnavailableCurrentProvider() {
        // The dead-ollama trap: an ordinary no-signal turn must NOT stay on a provider the avoid
        // gate benched — that was the "every turn dies identically" loop.
        let d = router().route("hello there", hasMedia: false, current: ollama,
                               avoid: { $0 == "ollama" })
        XCTAssertEqual(d.binding.providerId, "openai")
        XCTAssertTrue(d.reason.contains("unavailable"), "the switch must say WHY: \(d.reason)")
    }

    func testStayPathFailsOpenWhenEverythingUnavailable() {
        let d = router().route("hello there", hasMedia: false, current: ollama, avoid: { _ in true })
        XCTAssertEqual(d.binding, ollama, "all benched → stay put (fail-open last resort)")
    }

    func testStayPathUnchangedWhenCurrentIsWarm() {
        let d = router().route("hello there", hasMedia: false, current: ollama)
        XCTAssertEqual(d.binding, ollama)
        XCTAssertEqual(d.reason, "staying on current model")
    }

    // MARK: AutoModelRouter.captainDecision() — the stability-guard fallback path

    func testCaptainDecisionRescuesFromUnavailableFallback() {
        // No signal, low confidence — normally "stay". But the fallback is benched and the
        // Captain's pick is warm: a live model beats a dead favourite.
        let a = InteractiveAssignment(binding: ProviderBinding(providerId: "openai", model: "gpt-5"),
                                      reason: "r", confidence: 0.4, wantsReasoning: false,
                                      wantsVision: false, prefersResearch: false, wantsCoding: false,
                                      tags: [])
        let d = AutoModelRouter.captainDecision(a, fallback: ollama, avoid: { $0 == "ollama" })
        XCTAssertEqual(d.binding.providerId, "openai")
        XCTAssertTrue(d.reason.contains("unavailable"), "the rescue must say WHY: \(d.reason)")
    }

    func testCaptainDecisionFailsOpenWhenPickAlsoUnavailable() {
        let a = InteractiveAssignment(binding: ProviderBinding(providerId: "openai", model: "gpt-5"),
                                      reason: "r", confidence: 0.4, wantsReasoning: false,
                                      wantsVision: false, prefersResearch: false, wantsCoding: false,
                                      tags: [])
        let d = AutoModelRouter.captainDecision(a, fallback: ollama, avoid: { _ in true })
        XCTAssertEqual(d.binding, ollama, "both cold → the fallback stands (fail-open)")
    }

    // MARK: Capsule futureEvolution derives from the run (was one hardcoded sentence forever)

    func testFutureEvolutionDerivesFromActualFailures() {
        let failures = [ActionRecord(tool: "run_command", argsFingerprint: "f", success: false),
                        ActionRecord(tool: "run_command", argsFingerprint: "g", success: false),
                        ActionRecord(tool: "edit_file", argsFingerprint: "h", success: false)]
        let line = OrganizationalLearningStore.deriveFutureEvolution(
            success: false, failures: failures, mutating: [], tools: ["run_command", "edit_file"])
        XCTAssertTrue(line.contains("run_command"), "must name the WORST failing tool: \(line)")
        XCTAssertTrue(line.contains("2"), "must carry the real failure count: \(line)")
    }

    func testFutureEvolutionIsEmptyWhenRunCarriesNoSignal() {
        let mutating = [ActionRecord(tool: "edit_file", argsFingerprint: "h", success: true)]
        let line = OrganizationalLearningStore.deriveFutureEvolution(
            success: true, failures: [], mutating: mutating, tools: ["edit_file"])
        XCTAssertEqual(line, "", "an honest blank beats an invented priority")
    }

    func testFutureEvolutionDiffersAcrossDifferentRuns() {
        // The actual user-facing regression: two different runs must not produce the same line.
        let failing = OrganizationalLearningStore.deriveFutureEvolution(
            success: false, failures: [ActionRecord(tool: "web_search", argsFingerprint: "f", success: false)],
            mutating: [], tools: ["web_search"])
        let readingOnly = OrganizationalLearningStore.deriveFutureEvolution(
            success: true, failures: [], mutating: [], tools: ["read_file"],
            objective: "fix the parser bug in the tokenizer")
        XCTAssertNotEqual(failing, readingOnly)
        XCTAssertFalse(failing.isEmpty)
        XCTAssertFalse(readingOnly.isEmpty)
    }

    func testFutureEvolutionRecordsNoFalseDebtForReadOnlyTurns() {
        // Codex P2 (2026-08-25): a chat/review turn that inspects source and answers is COMPLETE —
        // "convert reading into action" only applies when the user asked for mutation.
        let chat = OrganizationalLearningStore.deriveFutureEvolution(
            success: true, failures: [], mutating: [], tools: ["read_file"],
            objective: "what does the conversation router do here?")
        XCTAssertEqual(chat, "", "an answered read-only turn is not unfinished work")
        let unknown = OrganizationalLearningStore.deriveFutureEvolution(
            success: true, failures: [], mutating: [], tools: ["read_file"])
        XCTAssertEqual(unknown, "", "unknown objective must not invent debt")
    }

    // MARK: Per-site source pins — one assertion per gate site, each names its file

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KistTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    func testSiteKistRunnerBuildsCombinedAvoidGate() throws {
        let src = try source("Sources/Kist/KistRunner.swift")
        XCTAssertTrue(src.contains("ProviderHealthFileStore()"),
                      "KistRunner must read the health daemon's snapshot on the request path")
        XCTAssertTrue(src.contains("repl.providerCoolingDown = avoidProvider"),
                      "the REPL's consult side must use the COMBINED gate, not cooldowns alone")
        XCTAssertFalse(src.contains("avoid: liveCooldowns.coolingDown"),
                       "no routing lane may bypass health by consulting cooldowns alone")
    }

    func testSiteProviderSelectionGatesLocalFallback() throws {
        let src = try source("Sources/Kist/KistRunner+ProviderSelection.swift")
        XCTAssertTrue(src.contains("ProviderHealthFileStore"),
                      "resolveProvider must consult daemon health")
        XCTAssertTrue(src.contains("locals.first(where: { !benchedGate($0.id) })"),
                      "the last-resort local fallback must prefer a WARM local provider")
    }

    func testSiteAutoModelRouterGatesStayAndFallbackPaths() throws {
        let src = try source("Sources/Kist/AutoModelRouter.swift")
        XCTAssertTrue(src.contains("avoid(stayTarget.providerId)"),
                      "route()'s stay path must consult avoid()")
        XCTAssertTrue(src.contains("avoid(fallback.providerId)"),
                      "captainDecision()'s stability default must consult avoid()")
    }

    func testSiteCaptainIntelligenceGatesSelection() throws {
        let src = try source("Sources/AgentCore/CaptainIntelligence.swift")
        XCTAssertTrue(src.contains("unavailable(candidate.binding.providerId)"),
                      "choose() must skip benched candidates during scoring")
        XCTAssertTrue(src.contains("unavailable(fallback.providerId)"),
                      "an unavailable incumbent must lose its baseline")
    }

    func testSiteConversationRouterClassifierFailureIsLoud() throws {
        let src = try source("Sources/Kist/ConversationRouter.swift")
        XCTAssertTrue(src.contains("onClassifierUnavailable"),
                      "classifier failure must surface, not silently disable escalation")
        XCTAssertFalse(src.contains("try? await providers.complete"),
                       "the silent try? swallow must not come back")
    }

    func testSiteLearningStoreFutureEvolutionNotHardcoded() throws {
        let src = try source("Sources/Kist/UX/OrganizationalLearningStore.swift")
        XCTAssertFalse(src.contains("Persistent research memory linked to benchmarks"),
                       "the eternal hardcoded futureEvolution sentence must not come back")
        XCTAssertTrue(src.contains("deriveFutureEvolution"),
                      "futureEvolution must derive from the run's trajectory")
    }

    func testSiteDashboardImpactNotHardcodedHigh() throws {
        let src = try source("Sources/Kist/KistREPL+Dashboard.swift")
        XCTAssertFalse(src.contains("estimatedImpact: \"High\""),
                       "estimatedImpact must derive from the capsule, not claim High forever")
    }

    // MARK: Codex P2 sweep (2026-08-25) — the two fallback lanes the first pass missed

    func testSiteRegistryFallbackChainIsHealthGated() throws {
        let core = try source("Sources/AgentCore/ProviderCatalog.swift")
        XCTAssertTrue(core.contains("providerUnavailable"),
                      "the registry's cross-provider fallback chain must accept an availability gate")
        XCTAssertTrue(core.contains("[primary] + warmUsable + benchedUsable + unusable"),
                      "chain RANKS (warm+usable, then benched-configured, then unconfigured) — never drops the only configured fallback")
        let runner = try source("Sources/Kist/KistRunner.swift")
        XCTAssertTrue(runner.contains("providerUnavailable: { cooldowns.coolingDown($0) || health.down($0) }"),
                      "makeRegistry must wire the LIVE combined gate into the registry")
    }

    func testSiteLocalFallbackExcludesUnreadyCLIsAndSpecialists() throws {
        // Codex P2 (2026-08-25): requiresAPIKey==false is not "usable" — a logged-out CLI fails
        // auth, and the COBOL specialist only knows COBOL. Neither may become the session default.
        let src = try source("Sources/Kist/KistRunner+ProviderSelection.swift")
        XCTAssertTrue(src.contains("p.id != \"cobol\""),
                      "explicit-only specialist must stay out of the last-resort pool")
        XCTAssertTrue(src.contains("cli.isLocallyAvailable()"),
                      "a subscription CLI must prove local readiness before entering the last-resort pool")
    }

    func testSiteOneShotSubstitutionIsHealthGated() throws {
        let src = try source("Sources/Kist/KistRunner+OneShotResilience.swift")
        XCTAssertTrue(src.contains("cooldowns.coolingDown($0) || health.down($0)"),
                      "one-shot substitution must not retry onto a daemon-known-down provider")
    }

    func testSiteClassifierCancellationIsNotAnOutage() throws {
        let src = try source("Sources/Kist/ConversationRouter.swift")
        XCTAssertTrue(src.contains("error is CancellationError"),
                      "ESC mid-classification must not report the classifier provider as down")
    }

    func testCancelledClassifierDoesNotAnnounceOutage() async {
        let registry = ProviderRegistry(providers: [CancellingProvider()], keyStore: NullKeys())
        var router = ConversationRouter(providers: registry,
                                        binding: ProviderBinding(providerId: "cancel-test"))
        var announced: String?
        router.onClassifierUnavailable = { announced = $0 }
        let proposal = await router.propose(
            "Refactor the persistence layer and add a caching module and a migration runner")
        XCTAssertNil(proposal)
        XCTAssertNil(announced, "an intentional interruption is not a provider outage")
    }
}

private struct NullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
}

private struct CancellingProvider: ChatProvider {
    let id = "cancel-test"
    let name = "Cancel Test"
    let requiresAPIKey = false
    let keyAccount = "cancel-test"
    let defaultModel = "cancel-test"
    let availableModels = [AIModel(id: "cancel-test")]

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        throw CancellationError()
    }
}
