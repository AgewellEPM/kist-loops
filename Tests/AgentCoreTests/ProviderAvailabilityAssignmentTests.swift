import XCTest
@testable import AgentCore

/// Availability gate inside the Captain's interactive selector (routing audit 2026-08-25, site:
/// CaptainIntelligence.assignInteractive/choose). Before this, the engine scored known-down
/// providers like live ones and kept nominating a dead session default, which the caller's
/// stability guard then pinned forever.
final class ProviderAvailabilityAssignmentTests: XCTestCase {
    private func team() -> ProjectSnapshot {
        ProjectSnapshot(
            repo: "/repo", trackedFileCount: 120, directorySnapshot: "Sources\nTests",
            knownDirectories: ["", "Sources", "Tests"], manifests: ["Package.swift"],
            testEntrypoints: ["swift test"], languages: ["Swift"], changedFiles: [],
            providers: [
                .init(binding: ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro"),
                      displayName: "DeepSeek",
                      capabilities: ModelCapabilities(nativeTools: true, reasoning: true,
                                                      contextWindowTokens: 128_000, codeExecution: true,
                                                      structuredOutput: true),
                      keyed: true),
                .init(binding: ProviderBinding(providerId: "openai", model: "gpt-5"),
                      displayName: "OpenAI",
                      capabilities: ModelCapabilities(nativeTools: true, reasoning: true,
                                                      contextWindowTokens: 200_000,
                                                      structuredOutput: true),
                      keyed: true),
            ])
    }

    func testUnavailableCandidateNeverWinsSelection() {
        // A coding turn would normally pick deepseek (strongest coder prior). With deepseek benched,
        // the selector must land on a warm candidate instead.
        let a = ModelAssignmentEngine.assignInteractive(
            turn: "implement the parser refactor and fix the routing code",
            snapshot: team(),
            fallback: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"),
            unavailable: { $0 == "deepseek" })
        XCTAssertNotEqual(a.binding.providerId, "deepseek",
                          "a benched provider must not be nominated no matter its score")
    }

    func testUnavailableFallbackLosesItsIncumbentBaseline() {
        // The dead-ollama trap: an ordinary turn, fallback provider known down. The incumbent
        // baseline must shrink so ANY warm keyed candidate out-scores it — otherwise the caller's
        // stability guard pins the dead provider forever.
        let a = ModelAssignmentEngine.assignInteractive(
            turn: "hello there",
            snapshot: team(),
            fallback: ProviderBinding(providerId: "ollama", model: "gemma3:4b"),
            unavailable: { $0 == "ollama" })
        XCTAssertNotEqual(a.binding.providerId, "ollama",
                          "a down fallback must lose to a warm candidate")
    }

    func testAllUnavailableFailsOpenToFallback() {
        // Availability may only reduce eagerness, never strand the turn with no binding at all.
        let a = ModelAssignmentEngine.assignInteractive(
            turn: "hello there",
            snapshot: team(),
            fallback: ProviderBinding(providerId: "ollama", model: "gemma3:4b"),
            unavailable: { _ in true })
        XCTAssertEqual(a.binding.providerId, "ollama", "everything benched → the fallback stands")
    }

    func testDownIncumbentLosesEvenToAWeakWarmCandidate() {
        // Codex P2 (2026-08-25): the reduced incumbent baseline could still out-score a weak warm
        // candidate (and a promoted scoreBoost widened the gap). A down fallback may only stand when
        // EVERY candidate is also unavailable — a live weak model beats a dead favourite.
        let weakTeam = ProjectSnapshot(
            repo: "/repo", trackedFileCount: 10, directorySnapshot: "Sources",
            knownDirectories: ["", "Sources"], manifests: ["Package.swift"],
            testEntrypoints: ["swift test"], languages: ["Swift"], changedFiles: [],
            providers: [
                .init(binding: ProviderBinding(providerId: "mlx", model: "tiny-3b"),
                      displayName: "MLX",
                      capabilities: ModelCapabilities(nativeTools: false, contextWindowTokens: 8_000),
                      keyed: false),
            ])
        let a = ModelAssignmentEngine.assignInteractive(
            turn: "hello there",
            snapshot: weakTeam,
            fallback: ProviderBinding(providerId: "ollama", model: "gemma3:4b"),
            unavailable: { $0 == "ollama" })
        XCTAssertEqual(a.binding.providerId, "mlx",
                       "a down incumbent may only stand when everything is down")
    }

    func testAvailableFallbackKeepsExistingBehavior() {
        // No availability signal → selection identical to before the gate existed.
        let a = ModelAssignmentEngine.assignInteractive(
            turn: "implement the parser refactor and fix the routing code",
            snapshot: team(),
            fallback: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"))
        XCTAssertEqual(a.binding.providerId, "deepseek",
                       "gate off ⇒ the coding turn still picks the project's coder")
    }
}
