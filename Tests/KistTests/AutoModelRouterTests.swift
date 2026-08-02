import XCTest
import AgentCore
@testable import Kist

final class AutoModelRouterTests: XCTestCase {

    // MARK: C4 — the Captain-interactive stability guard (pure policy)

    private func assignment(binding: String, confidence: Double, reasoning: Bool = false,
                            research: Bool = false, coding: Bool = false) -> InteractiveAssignment {
        InteractiveAssignment(binding: ProviderBinding(providerId: binding, model: "m"), reason: "r",
                              confidence: confidence, wantsReasoning: reasoning, wantsVision: false,
                              prefersResearch: research, wantsCoding: coding, tags: [])
    }
    private let fb = ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash")

    func testCaptainGuardSwitchesOnExplicitCodingTurn() {
        // The common case: an explicit coding turn WITH a confident, different pick DOES switch (the bug was
        // that coding turns were muted). Reason is captain-attributed.
        let d = AutoModelRouter.captainDecision(assignment(binding: "deepseek", confidence: 0.7, coding: true), fallback: fb)
        XCTAssertEqual(d.binding.providerId, "deepseek")
        XCTAssertTrue(d.reason.contains("captain"))
    }

    func testCaptainGuardSwitchesOnReasoningAndResearch() {
        XCTAssertEqual(AutoModelRouter.captainDecision(assignment(binding: "mimo", confidence: 0.6, reasoning: true), fallback: fb).binding.providerId, "mimo")
        XCTAssertEqual(AutoModelRouter.captainDecision(assignment(binding: "openai", confidence: 0.6, research: true), fallback: fb).binding.providerId, "openai")
    }

    func testCaptainGuardStaysWhenNoSignal() {
        // No capability signal (a plain turn, even if the engine named a different model) ⇒ STAY on fallback.
        let d = AutoModelRouter.captainDecision(assignment(binding: "deepseek", confidence: 0.9), fallback: fb)
        XCTAssertEqual(d.binding, fb)
        XCTAssertEqual(d.reason, "staying on current model")
    }

    func testCaptainGuardStaysOnLowConfidenceOrSameBinding() {
        // Low confidence ⇒ stay.
        XCTAssertEqual(AutoModelRouter.captainDecision(assignment(binding: "deepseek", confidence: 0.3, coding: true), fallback: fb).binding, fb)
        // Same-as-fallback pick (exact binding) ⇒ stay (no pointless rebuild).
        let same = InteractiveAssignment(binding: fb, reason: "r", confidence: 0.9, wantsReasoning: false,
                                         wantsVision: false, prefersResearch: false, wantsCoding: true, tags: [])
        XCTAssertEqual(AutoModelRouter.captainDecision(same, fallback: fb).binding, fb)
    }

    /// Codex HIGH regression (2026-07-03): "stay" must mean stay on the CURRENT model, not the STARTUP
    /// default. A no-signal turn AFTER a switch must NOT route back. This pins the contract that the caller
    /// threads the current active binding as `fallback` — proven by simulating two turns.
    func testCaptainGuardStaysOnCurrentModelNotStartupAfterSwitch() {
        let deepseek = ProviderBinding(providerId: "deepseek", model: "m")
        // Turn 1: explicit coding signal, confident, different ⇒ switch gemini(startup) → deepseek.
        let turn1 = AutoModelRouter.captainDecision(assignment(binding: "deepseek", confidence: 0.7, coding: true), fallback: fb)
        XCTAssertEqual(turn1.binding, deepseek, "turn 1 switches to the confident coding pick")
        // Turn 2: a plain "thanks" (no signal). The CURRENT model is now deepseek, so it must be threaded as
        // fallback. Result MUST be deepseek — NOT the startup gemini (that route-back was the churn bug).
        let turn2 = AutoModelRouter.captainDecision(assignment(binding: "gemini", confidence: 0.9), fallback: deepseek)
        XCTAssertEqual(turn2.binding, deepseek, "a no-signal turn stays on the CURRENT model, never flips to startup")
    }

    /// Codex MED: the switch floor is `>= 0.5` — pin the exact boundary so a refactor can't drift it.
    func testCaptainGuardSwitchBoundaryAtConfidenceThreshold() {
        XCTAssertEqual(AutoModelRouter.captainDecision(assignment(binding: "deepseek", confidence: 0.50, coding: true), fallback: fb).binding.providerId,
                       "deepseek", "exactly 0.50 with a signal + different model DOES switch")
        XCTAssertEqual(AutoModelRouter.captainDecision(assignment(binding: "deepseek", confidence: 0.49, coding: true), fallback: fb).binding,
                       fb, "just below 0.50 stays on the current model")
    }

    // Mirrors Luke's setup: a fast vision flash model, a strong reasoning model, a mid model.
    private func router() -> AutoModelRouter {
        let candidates: [AutoModelRouter.Candidate] = [
            .init(binding: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"),
                  vision: true, reasoning: false, contextTokens: 1_000_000, fast: true),
            .init(binding: ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro"),
                  vision: false, reasoning: true, contextTokens: 128_000, fast: false),
            .init(binding: ProviderBinding(providerId: "mimo", model: "mimo-v2.5-pro"),
                  vision: false, reasoning: false, contextTokens: 64_000, fast: false),
        ]
        return AutoModelRouter(candidates: candidates,
                               fallback: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"))
    }

    // The three behaviours from the approved preview.
    func testMediaRoutesToVision() {
        let d = router().route("what is in this?", hasMedia: true)
        XCTAssertEqual(d.tier, .vision)
        XCTAssertEqual(d.binding.providerId, "gemini")
    }

    func testReasoningRequestRoutesToStrongModel() {
        let d = router().route("design a fault-tolerant queue", hasMedia: false)
        XCTAssertEqual(d.tier, .reasoning)
        XCTAssertEqual(d.binding.providerId, "deepseek")
    }

    func testPlainRequestStaysOnCurrentModel() {
        // Plain turns stay on the session's current model (the fallback), not the first fast candidate.
        // Here fallback == gemini, so it returns gemini — the DEDICATED proof is the next test.
        let d = router().route("explain this stack trace", hasMedia: false)
        XCTAssertEqual(d.tier, .fast)
        XCTAssertEqual(d.binding, router().fallback, "plain turn returns the fallback (current model)")
    }

    /// Codex MED regression (2026-07-03): when a `current` model is threaded (e.g. after `/model deepseek`
    /// then `/model auto`), a plain turn must STAY on `current`, NOT flip back to the startup fallback.
    func testPlainRequestStaysOnThreadedCurrentNotStartupFallback() {
        let deepseek = ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro")
        let d = router().route("thanks", hasMedia: false, current: deepseek)
        XCTAssertEqual(d.tier, .fast)
        XCTAssertEqual(d.binding, deepseek, "stays on the CURRENT model, not the startup gemini fallback")
        // Reasoning/vision signals still override `current` (a real capability switch is not churn).
        XCTAssertEqual(router().route("design a fault-tolerant queue", hasMedia: false, current: deepseek).binding.providerId,
                       "deepseek", "a reasoning turn still routes to the strong model")
        XCTAssertEqual(router().route("look at this", hasMedia: true, current: deepseek).tier, .vision,
                       "a media turn still routes to vision")
    }

    func testPlainRequestStaysOnCaptainNotFastModel() {
        // The real proof: Captain = MiMo (fallback) AND a DIFFERENT fast model (gemini-flash) is
        // available. A plain turn must stay on MiMo — it must NOT flip to the fast gemini candidate.
        let candidates: [AutoModelRouter.Candidate] = [
            .init(binding: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"),
                  vision: true, reasoning: false, contextTokens: 1_000_000, fast: true),
            .init(binding: ProviderBinding(providerId: "mimo", model: "mimo-v2.5-pro"),
                  vision: false, reasoning: false, contextTokens: 64_000, fast: false),
        ]
        let router = AutoModelRouter(candidates: candidates,
                                     fallback: ProviderBinding(providerId: "mimo", model: "mimo-v2.5-pro"))
        let d = router.route("explain this stack trace", hasMedia: false)
        XCTAssertEqual(d.binding.providerId, "mimo",
                       "a plain turn must stay on the Captain (MiMo), NOT flip to the fast gemini candidate")
        XCTAssertEqual(d.tier, .fast)
    }

    // A one-provider setup never routes to anything unconfigured — it always returns that provider.
    func testSingleProviderAlwaysUsable() {
        let only = AutoModelRouter(
            candidates: [.init(binding: ProviderBinding(providerId: "ollama", model: "llama3.1"),
                               vision: false, reasoning: false, contextTokens: 8_000, fast: true)],
            fallback: ProviderBinding(providerId: "ollama", model: "llama3.1"))
        XCTAssertEqual(only.route("design a distributed consensus algorithm", hasMedia: false).binding.providerId, "ollama")
        XCTAssertEqual(only.route("hi", hasMedia: true).binding.providerId, "ollama")
    }

    // Empty candidate set falls back instead of crashing.
    func testNoCandidatesFallsBack() {
        let r = AutoModelRouter(candidates: [], fallback: ProviderBinding(providerId: "openai", model: "gpt-5.5"))
        XCTAssertEqual(r.route("anything", hasMedia: true).binding.providerId, "openai")
    }

    func testReasoningKeywordDetection() {
        XCTAssertTrue(AutoModelRouter.looksLikeReasoning("design a fault-tolerant queue"))
        XCTAssertTrue(AutoModelRouter.looksLikeReasoning("optimize this O(n^2) algorithm"))
        XCTAssertTrue(AutoModelRouter.looksLikeReasoning("prove that this terminates"))
        // Plain chatter stays on the fast tier.
        XCTAssertFalse(AutoModelRouter.looksLikeReasoning("explain this stack trace"))
        XCTAssertFalse(AutoModelRouter.looksLikeReasoning("what's the weather like"))
    }

    func testFastModelHeuristic() {
        XCTAssertTrue(AutoModelRouter.isFastModel("gemini-2.5-flash", contextTokens: 1_000_000))
        XCTAssertTrue(AutoModelRouter.isFastModel("gpt-5-mini", contextTokens: 128_000))
        XCTAssertTrue(AutoModelRouter.isFastModel("llama-3.2-3b-instruct", contextTokens: 8_000))
        XCTAssertFalse(AutoModelRouter.isFastModel("deepseek-v4-pro", contextTokens: 128_000))
    }

    func testStartupHeaderAbbreviatesHomePath() {
        let home = NSHomeDirectory()
        XCTAssertEqual(StartupHeader.abbreviate(home), "~")
        XCTAssertEqual(StartupHeader.abbreviate(home + "/Downloads/mythos-stage2-mm"), "~/…/mythos-stage2-mm")
    }

    // config.provider used to silently disable the Captain even with "autoRouting": true in the
    // config file (the field wasn't parsed at all) — every session pinned to the default provider.
    // One assertion per pin site: legacy default, config provider, config flag, picker, CLI flag.
    func testRoutingEnabledHonorsConfigAutoRouting() {
        // Legacy: nothing configured → routing on; config provider alone → pinned.
        XCTAssertTrue(AutoModelRouter.routingEnabled(pickedInteractively: false, cliProvider: false,
                                                     configProvider: false, configAutoRouting: nil))
        XCTAssertFalse(AutoModelRouter.routingEnabled(pickedInteractively: false, cliProvider: false,
                                                      configProvider: true, configAutoRouting: nil))
        // The fix: default provider + "autoRouting": true → Captain keeps choosing per turn.
        XCTAssertTrue(AutoModelRouter.routingEnabled(pickedInteractively: false, cliProvider: false,
                                                     configProvider: true, configAutoRouting: true))
        // Explicit "autoRouting": false pins even with no provider configured.
        XCTAssertFalse(AutoModelRouter.routingEnabled(pickedInteractively: false, cliProvider: false,
                                                      configProvider: false, configAutoRouting: false))
        // Interactive picker and CLI --provider ALWAYS win over the config flag.
        XCTAssertFalse(AutoModelRouter.routingEnabled(pickedInteractively: true, cliProvider: false,
                                                      configProvider: false, configAutoRouting: true))
        XCTAssertFalse(AutoModelRouter.routingEnabled(pickedInteractively: false, cliProvider: true,
                                                      configProvider: false, configAutoRouting: true))
    }

    func testConfigParsesAutoRouting() {
        let c = KistConfig.parse(["provider": "gemini", "autoRouting": true])
        XCTAssertEqual(c.provider, "gemini")
        XCTAssertEqual(c.autoRouting, true)
        XCTAssertNil(KistConfig.parse([:]).autoRouting)
        XCTAssertEqual(KistConfig.parse(["autoRouting": false]).autoRouting, false)
    }

    func testStartupHeaderShowsModeAndHint() {
        let auto = StartupHeader.render(mode: "auto-routing", projectRoot: "/tmp/x", planMode: false, color: false)
        XCTAssertTrue(auto.contains("kist · v0.17.0 · auto-routing"))
        XCTAssertTrue(auto.contains("auto-routing"))
        XCTAssertTrue(auto.contains("/model to pin"))
        let pinned = StartupHeader.render(mode: "gemini-2.5-flash", projectRoot: "/tmp/x", planMode: false, color: false)
        XCTAssertTrue(pinned.contains("/model to change"))
    }
}
