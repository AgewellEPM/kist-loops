import XCTest
@testable import Kist
@testable import AgentCore

/// The actual default pick under each policy (Luke 2026-08-06: by cost or by power), plus config
/// parse/write round-trip for the `/cost`·`/power` persistence.
final class ProviderPickByPolicyTests: XCTestCase {

    func testPowerPicksStrongestCostPicksCheapest() {
        // A realistic eligible set: a flat-rate sub + premium API + cheap API.
        let eligible: [any ChatProvider] = [
            StubProvider("claude-cli"), StubProvider("openai"), StubProvider("deepseek"), StubProvider("gemini"),
        ]
        // POWER → claude-cli (rank 100).
        XCTAssertEqual(KistRunner.pickByPolicy(eligible, policy: .power, verdicts: [:])?.id, "claude-cli")
        // COST → claude-cli too (flat-rate sub = $0 marginal, and tie-break power keeps it above local).
        XCTAssertEqual(KistRunner.pickByPolicy(eligible, policy: .cost, verdicts: [:])?.id, "claude-cli")
    }

    func testCostPrefersCheapAPIWhenNoFlatRateSub() {
        // No subscription CLI, no local → cost must pick the cheapest PAID API, power the strongest.
        let eligible: [any ChatProvider] = [
            StubProvider("openai"), StubProvider("gemini"), StubProvider("deepseek"), StubProvider("mimo"),
        ]
        XCTAssertEqual(KistRunner.pickByPolicy(eligible, policy: .power, verdicts: [:])?.id, "openai")   // rank 95
        XCTAssertEqual(KistRunner.pickByPolicy(eligible, policy: .cost, verdicts: [:])?.id, "mimo")      // cheapest
    }

    func testEmptyEligibleIsNil() {
        XCTAssertNil(KistRunner.pickByPolicy([], policy: .power, verdicts: [:]))
        XCTAssertNil(KistRunner.pickByPolicy([], policy: .cost, verdicts: [:]))
    }

    func testConfigParsesSelectBy() {
        XCTAssertEqual(KistConfig.parse(["selectBy": "cost"]).selectBy, .cost)
        XCTAssertEqual(KistConfig.parse(["selectBy": "power"]).selectBy, .power)
        XCTAssertNil(KistConfig.parse([:]).selectBy)
        XCTAssertNil(KistConfig.parse(["selectBy": "banana"]).selectBy)
    }

    func testWriteSelectByMergesPreservingOtherFields() throws {
        let dir = NSTemporaryDirectory() + "selectby-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        setenv("XDG_CONFIG_HOME", dir, 1)
        defer { unsetenv("XDG_CONFIG_HOME") }

        // Seed a config with a hand-set provider; writing selectBy must NOT clobber it.
        let p = KistConfig.path()
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try #"{"provider":"deepseek","model":"deepseek-v4-pro"}"#.write(toFile: p, atomically: true, encoding: .utf8)

        XCTAssertTrue(KistConfig.writeSelectBy(.cost))
        let reloaded = KistConfig.load()
        XCTAssertEqual(reloaded.selectBy, .cost)
        XCTAssertEqual(reloaded.provider, "deepseek", "writing selectBy must preserve the pinned provider")
        XCTAssertEqual(reloaded.model, "deepseek-v4-pro")
    }
}

private struct StubProvider: ChatProvider {
    let id: String
    var name: String { id }
    let iconName = "cpu"
    let requiresAPIKey = false
    var keyAccount: String { id }
    var defaultModel: String { "\(id)-default" }
    var availableModels: [AIModel] { [AIModel(id: "\(id)-default")] }
    init(_ id: String) { self.id = id }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
