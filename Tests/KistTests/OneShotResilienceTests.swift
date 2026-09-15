import XCTest
import AgentCore
@testable import Kist

/// One-shot provider resilience (0.17.58): NL goal pins, REPL-parity
/// substitution with the cross-process cooldown gate. Born from the 2026-08-13
/// dashboard dogfood where ask-mode and vm-agent one-shots died 4× on a
/// live-rate-limited provider the router kept re-picking.
final class OneShotResilienceTests: XCTestCase {
    func testChangingProviderDoesNotInheritAnotherProvidersConfiguredModel() {
        XCTAssertNil(KistRunner.startupModel(explicit: nil, selectedProvider: "openai",
            configProvider: "ollama", configModel: "llama3.1"))
        XCTAssertEqual(KistRunner.startupModel(explicit: nil, selectedProvider: "ollama",
            configProvider: "ollama", configModel: "llama3.1"), "llama3.1")
        XCTAssertEqual(KistRunner.startupModel(explicit: "explicit", selectedProvider: "openai",
            configProvider: "ollama", configModel: "llama3.1", goalModel: "goal-model"), "explicit")
        XCTAssertEqual(KistRunner.startupModel(explicit: nil, selectedProvider: "openai",
            configProvider: "ollama", configModel: "llama3.1", goalModel: "goal-model"), "goal-model")
    }

    private let aliases = ["claude": "claude-cli", "claude-cli": "claude-cli",
                           "deepseek": "deepseek", "gemini": "gemini"]

    // MARK: goal pin

    func testGoalOpeningWithUsePinsTheProvider() {
        let pin = KistRunner.oneShotModelPin(
            goal: "use claude-cli for this turn. You are the DIRECTOR of an expert loop…",
            knownProviders: aliases)
        XCTAssertEqual(pin?.providerId, "claude-cli")
    }

    func testProseMentioningAModelDoesNotPin() {
        XCTAssertNil(KistRunner.oneShotModelPin(
            goal: "Summarize how claude-cli support is wired in the registry.",
            knownProviders: aliases))
        XCTAssertNil(KistRunner.oneShotModelPin(
            goal: "use the vm screenshot capability to inspect the guest",
            knownProviders: aliases))
    }

    func testPinOnlyReadsTheGoalHead() {
        // A directive buried deep in a long brief must not hijack routing.
        let longBrief = String(repeating: "context line. ", count: 30) + "use gemini for this."
        XCTAssertNil(KistRunner.oneShotModelPin(goal: longBrief, knownProviders: aliases))
    }

    // MARK: substitution + cooldown

    private func rateLimitedSub(coolingDown: @escaping (String) -> Bool)
        -> KistRunner.OneShotSubstitution? {
        let current = ProviderBinding(providerId: "openai")
        return KistRunner.oneShotSubstitution(
            success: false,
            summary: "The step didn't complete: provider 'openai' error: rateLimited.",
            trajectory: [ActionRecord(tool: "read_file", argsFingerprint: "a.swift", success: true)],
            current: current,
            roles: RoleBindings(default: current),
            providerHasKey: { ["openai", "deepseek", "gemini"].contains($0) },
            providerModels: ["openai": ["gpt-5.5"], "deepseek": ["deepseek-v4-pro"],
                             "gemini": ["gemini-2.5-flash"]],
            coolingDown: coolingDown)
    }

    func testRateLimitedOneShotSubstitutesAndCoolsDown() {
        let sub = rateLimitedSub(coolingDown: { _ in false })
        XCTAssertEqual(sub?.decision.replacement.providerId, "deepseek")
        XCTAssertEqual(sub?.decision.reason, "provider/transient failure")
        XCTAssertEqual(sub?.shouldCooldown, true)   // rate limits bench cross-process
    }

    func testSubstitutionSkipsProvidersAlreadyCoolingDown() {
        let sub = rateLimitedSub(coolingDown: { $0 == "deepseek" })
        XCTAssertEqual(sub?.decision.replacement.providerId, "gemini")
    }

    func testProtocolFailureSubstitutesWithoutCooldown() {
        let current = ProviderBinding(providerId: "mimo")
        let sub = KistRunner.oneShotSubstitution(
            success: false,
            summary: "The model rejected the request as malformed.",
            trajectory: [],
            current: current,
            roles: RoleBindings(default: current),
            providerHasKey: { $0 == "deepseek" },
            providerModels: ["mimo": ["mimo-v2.5-pro"], "deepseek": ["deepseek-v4-pro"]],
            coolingDown: { _ in false })
        XCTAssertEqual(sub?.decision.replacement.providerId, "deepseek")
        XCTAssertEqual(sub?.shouldCooldown, false)  // protocol faults are the scorecard's job
    }

    func testMutatingTrajectoryBlocksOneShotSubstitution() {
        let current = ProviderBinding(providerId: "openai")
        XCTAssertNil(KistRunner.oneShotSubstitution(
            success: false,
            summary: "429 rate limit",
            trajectory: [ActionRecord(tool: "write_file", argsFingerprint: "x", success: true)],
            current: current,
            roles: RoleBindings(default: current),
            providerHasKey: { _ in true },
            providerModels: ["deepseek": ["deepseek-v4-pro"]],
            coolingDown: { _ in false }))
    }
}
