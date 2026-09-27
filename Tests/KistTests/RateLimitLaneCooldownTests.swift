import XCTest
import AgentCore
@testable import Kist

/// 0.17.59 — 5th reproduction of the rate-limit routing bug (2026-08-14): a REPL media turn
/// rerouted to gemini, gemini answered `rateLimited`, and the turn died terminally. Root causes
/// pinned here: (1) the literal summary "provider 'x' error: rateLimited" was never classified
/// as transient; (2) the media lane had no substitution and neither read nor wrote the
/// cross-process cooldown ledger; (3) the auto-router tiers were cooldown-blind.
final class RateLimitLaneCooldownTests: XCTestCase {

    // MARK: — Classifier: the EXACT observed failure string is transient

    func testExactObservedRateLimitedSummaryClassifiesAsTransient() {
        // Verbatim shape from the 2026-08-14 screenshot. "ratelimited" (one word, the enum case
        // as rendered) was missing from the pattern list, so NO lane substituted on this error.
        let summary = "The step didn't complete: provider 'gemini' error: rateLimited. "
            + "Nothing was committed — retry or tell me a different approach."
        XCTAssertEqual(KistREPL.modelSubstitutionReason(success: false, summary: summary),
                       "provider/transient failure")
        XCTAssertTrue(KistREPL.transientProviderFailure(summary: summary))
    }

    func testTransientHelperExcludesProtocolAndRefusalFailures() {
        XCTAssertFalse(KistREPL.transientProviderFailure(
            summary: "The model rejected the request as malformed."))
        XCTAssertFalse(KistREPL.transientProviderFailure(
            summary: "I cannot help with that request."))
        XCTAssertTrue(KistREPL.transientProviderFailure(
            summary: "request timed out while contacting the provider"))
    }

    // MARK: — Media-lane vision pick (cooldown-aware, fail-open)

    func testChooseVisionProviderSkipsCoolingPreferredEngine() {
        let pick = KistREPL.chooseVisionProvider(candidates: ["gemini", "openai"],
                                                 mustUseGemini: false,
                                                 coolingDown: { $0 == "gemini" })
        XCTAssertEqual(pick, "openai")
    }

    func testChooseVisionProviderFailsOpenWhenEverythingIsCooling() {
        // The cooldown store may only reduce eagerness, never block the last resort.
        let pick = KistREPL.chooseVisionProvider(candidates: ["gemini", "openai"],
                                                 mustUseGemini: false,
                                                 coolingDown: { _ in true })
        XCTAssertEqual(pick, "gemini")
    }

    func testChooseVisionProviderRestrictsGeminiOnlyMedia() {
        // Video/audio + Files-API refs are gemini-only: a cooling gemini is still the only option.
        XCTAssertEqual(KistREPL.chooseVisionProvider(candidates: ["gemini", "openai"],
                                                     mustUseGemini: true,
                                                     coolingDown: { $0 == "gemini" }), "gemini")
        XCTAssertNil(KistREPL.chooseVisionProvider(candidates: ["openai"],
                                                   mustUseGemini: true,
                                                   coolingDown: { _ in false }))
    }

    // MARK: — Media-turn substitution (parity with the text-turn lane)

    private let rateLimitedSummary = "provider 'gemini' error: rateLimited"
    private let safeTrajectory = [ActionRecord(tool: "read_file", argsFingerprint: "a.swift", success: true)]

    func testMediaSubstitutionRetriesOnNextWarmVisionCandidate() {
        let sub = KistREPL.mediaSubstitutionDecision(
            success: false, summary: rateLimitedSummary, trajectory: [],
            failedProviderId: "gemini", candidates: ["gemini", "openai", "grok"],
            mustUseGemini: false, coolingDown: { _ in false })
        XCTAssertEqual(sub?.replacement, "openai")
        XCTAssertEqual(sub?.reason, "provider/transient failure")
    }

    func testMediaSubstitutionSkipsCoolingCandidates() {
        let sub = KistREPL.mediaSubstitutionDecision(
            success: false, summary: rateLimitedSummary, trajectory: safeTrajectory,
            failedProviderId: "gemini", candidates: ["gemini", "openai", "grok"],
            mustUseGemini: false, coolingDown: { $0 == "openai" })
        XCTAssertEqual(sub?.replacement, "grok")
    }

    func testMediaSubstitutionHasNoLaneForGeminiOnlyMedia() {
        // Gemini failed and the media is gemini-only: nothing to retry on (the cooldown was
        // still recorded by the caller so other lanes learn — see the per-site pin below).
        XCTAssertNil(KistREPL.mediaSubstitutionDecision(
            success: false, summary: rateLimitedSummary, trajectory: [],
            failedProviderId: "gemini", candidates: ["gemini", "openai"],
            mustUseGemini: true, coolingDown: { _ in false }))
    }

    func testMediaSubstitutionRefusesUnsafeTrajectoryAndSuccess() {
        let mutating = [ActionRecord(tool: "write_file", argsFingerprint: "a.swift", success: true)]
        XCTAssertNil(KistREPL.mediaSubstitutionDecision(
            success: false, summary: rateLimitedSummary, trajectory: mutating,
            failedProviderId: "gemini", candidates: ["gemini", "openai"],
            mustUseGemini: false, coolingDown: { _ in false }))
        XCTAssertNil(KistREPL.mediaSubstitutionDecision(
            success: true, summary: "done", trajectory: [],
            failedProviderId: "gemini", candidates: ["gemini", "openai"],
            mustUseGemini: false, coolingDown: { _ in false }))
    }

    // MARK: — Auto-router tiers skip cooling providers (fail-open per tier)

    private func candidate(_ id: String, vision: Bool = false, reasoning: Bool = false,
                           ctx: Int = 128_000) -> AutoModelRouter.Candidate {
        AutoModelRouter.Candidate(binding: ProviderBinding(providerId: id, model: "m"),
                                  vision: vision, reasoning: reasoning,
                                  contextTokens: ctx, fast: false)
    }

    func testRouterVisionTierSkipsCoolingEngine() {
        let router = AutoModelRouter(candidates: [candidate("gemini", vision: true),
                                                  candidate("openai", vision: true)],
                                     fallback: ProviderBinding(providerId: "claude-cli"))
        let d = router.route("look at this", hasMedia: true, avoid: { $0 == "gemini" })
        XCTAssertEqual(d.binding.providerId, "openai")
        XCTAssertEqual(d.tier, .vision)
    }

    func testRouterVisionTierFailsOpenWhenAllVisionIsCooling() {
        let router = AutoModelRouter(candidates: [candidate("gemini", vision: true),
                                                  candidate("openai", vision: true)],
                                     fallback: ProviderBinding(providerId: "claude-cli"))
        let d = router.route("look at this", hasMedia: true, avoid: { _ in true })
        XCTAssertEqual(d.binding.providerId, "gemini")
    }

    func testRouterReasoningTierSkipsCoolingReasoner() {
        // The strongest reasoner is cooling — the tier picks the next warm reasoner instead.
        let router = AutoModelRouter(candidates: [candidate("openai", reasoning: true, ctx: 400_000),
                                                  candidate("deepseek", reasoning: true, ctx: 128_000)],
                                     fallback: ProviderBinding(providerId: "claude-cli"))
        let d = router.route("design a distributed consensus algorithm", hasMedia: false,
                             avoid: { $0 == "openai" })
        XCTAssertEqual(d.binding.providerId, "deepseek")
        XCTAssertEqual(d.tier, .reasoning)
    }

    func testCaptainDecisionStaysWhenPickIsCooling() {
        let fb = ProviderBinding(providerId: "claude-cli", model: "m")
        let a = InteractiveAssignment(binding: ProviderBinding(providerId: "openai", model: "m"),
                                      reason: "r", confidence: 0.9, wantsReasoning: true,
                                      wantsVision: false, prefersResearch: false,
                                      wantsCoding: false, tags: [])
        let d = AutoModelRouter.captainDecision(a, fallback: fb, avoid: { $0 == "openai" })
        XCTAssertEqual(d.binding, fb)
    }

    // MARK: — Per-site pins (multi-site fix discipline: one assertion per lane, so a
    // regressed lane names itself). Source-text pins, deliberately: the invariant is
    // "this lane consults/feeds the cooldown ledger", a property of the source itself.

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KistTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    func testSiteREPLTextTurnLaneConsultsAndFeedsCooldowns() throws {
        let src = try source("Sources/Kist/KistREPL.swift")
        XCTAssertTrue(src.contains("recordProviderCooldown?(activeBinding.providerId, oc.summary)"),
                      "REPL text-turn lane must bench a transiently-failing provider cross-process")
        XCTAssertTrue(src.contains("providerCoolingDown?(pid) != true"),
                      "REPL text-turn substitution must never pick a cooling provider")
    }

    func testSiteREPLMediaLaneConsultsAndFeedsCooldowns() throws {
        let src = try source("Sources/Kist/KistREPL+Turn.swift")
        XCTAssertTrue(src.contains("mediaSubstitutionDecision"),
                      "media lane must retry a failed media turn on a warm vision candidate")
        XCTAssertTrue(src.contains("recordProviderCooldown?(turnAuthor.providerId, oc.summary)"),
                      "media lane must bench the failed vision provider even when no substitute exists")
        XCTAssertTrue(src.contains("chooseVisionProvider"),
                      "media lane must pick its vision provider cooldown-aware, not statically")
    }

    func testSiteOneShotLaneConsultsCooldowns() throws {
        let src = try source("Sources/Kist/KistRunner+ReadOnlyPolicy.swift")
        XCTAssertTrue(src.contains("oneShotSubstitution"),
                      "one-shot lane must keep its substitution-with-cooldown path (0.17.58)")
    }

    func testSiteDefaultProviderSelectionConsultsCooldowns() throws {
        let src = kistRunnerFamilySource()
        // 0.17.60: the cooldown ledger is consulted through the COMBINED availability gate
        // (cooldowns + health daemon) — the ledger must still be inside it, and the gate must
        // be what the routing lanes receive. ProviderAvailabilityGateTests pins the health half.
        XCTAssertTrue(src.contains("cooldowns.coolingDown($0) || health.down($0)"),
                      "default provider selection must skip cooling providers (0.17.58) via the combined gate")
        XCTAssertTrue(src.contains("liveCooldowns.coolingDown($0) || providerHealth.down($0)"),
                      "REPL auto-route wiring must thread the live cooldown ledger into the combined avoid gate")
        XCTAssertTrue(src.contains("avoid: avoidProvider"),
                      "REPL auto-route wiring must hand the combined gate to the router")
        XCTAssertTrue(src.contains("repl.recordProviderCooldown"),
                      "runner must wire the REPL's cooldown-record hook")
    }

    func testSiteAutoRouterTiersAreCooldownAware() throws {
        let src = try source("Sources/Kist/AutoModelRouter.swift")
        XCTAssertTrue(src.contains("avoid: (String) -> Bool"),
                      "AutoModelRouter tiers must accept the live-cooldown gate")
    }

    func testSiteHealthSurfaceReportsCooling() throws {
        let src = try source("Sources/Kist/KistRunner+OperatorSurface.swift")
        XCTAssertTrue(src.contains("coolingDown: ProviderCooldownStore().coolingDown"),
                      "--health catalog mode must report live cooldowns, not just key presence")
    }
}
