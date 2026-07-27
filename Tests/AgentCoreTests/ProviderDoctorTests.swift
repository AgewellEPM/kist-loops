import XCTest
@testable import AgentCore

final class ProviderDoctorTests: XCTestCase {

    private func grokLike() -> OpenAICompatibleProvider {
        // Mirrors the catalog's Grok, which ships the now-dead grok-2-latest.
        OpenAICompatibleProvider(id: "grok", name: "Grok", iconName: "bolt", keyAccount: "grok_api_key",
                                 endpoint: "https://api.x.ai/v1/chat/completions", defaultModel: "grok-4.3",
                                 availableModels: [AIModel(id: "grok-4.3"), AIModel(id: "grok-code-fast-1"),
                                                   AIModel(id: "grok-2-latest")])
    }

    func testModelsEndpointDerivation() {
        XCTAssertEqual(ProviderDoctor.modelsEndpoint(for: grokLike()), "https://api.x.ai/v1/models")
    }

    func testDiffFlagsDeadCatalogId() {
        // Live list no longer has grok-2-latest → it's flagged stale; default grok-4.3 is valid.
        let r = ProviderDoctor.diff(provider: grokLike(), liveModelIds: ["grok-4.3", "grok-code-fast-1", "grok-3"])
        XCTAssertEqual(r.staleCatalogIds, ["grok-2-latest"])
        XCTAssertTrue(r.defaultIsValid)
        XCTAssertEqual(r.newLiveIds, ["grok-3"])
        XCTAssertFalse(r.isHealthy)        // a dead catalog id is drift
    }

    func testDiffFlagsInvalidDefault() {
        // The exact bug we hit: default model id isn't in the provider's live list → every call 404s.
        let r = ProviderDoctor.diff(provider: grokLike(), liveModelIds: ["grok-3", "grok-code-fast-1"])
        XCTAssertFalse(r.defaultIsValid)
        XCTAssertFalse(r.isHealthy)
    }

    func testHealthyWhenCatalogMatchesLive() {
        let r = ProviderDoctor.diff(provider: grokLike(),
                                    liveModelIds: ["grok-4.3", "grok-code-fast-1", "grok-2-latest"])
        XCTAssertTrue(r.staleCatalogIds.isEmpty)
        XCTAssertTrue(r.isHealthy)
    }

    func testReasoningModelsAreFlaggedInLiveList() {
        let mimo = OpenAICompatibleProvider(id: "mimo", name: "MiMo", iconName: "cpu", keyAccount: "mimo_api_key",
                                            endpoint: "https://api.xiaomimimo.com/v1/chat/completions",
                                            defaultModel: "mimo-v2.5-pro", availableModels: [AIModel(id: "mimo-v2.5-pro")])
        let r = ProviderDoctor.diff(provider: mimo, liveModelIds: ["mimo-v2.5-pro", "mimo-v2.5"])
        XCTAssertEqual(Set(r.reasoningModelIds), ["mimo-v2.5-pro", "mimo-v2.5"])
    }

    func testParseOpenAIModelsShapeAndBareArray() {
        let openai = #"{"data":[{"id":"gpt-4o"},{"id":"gpt-5.5"}]}"#
        XCTAssertEqual(ProviderDoctor.parseModelIds(Data(openai.utf8)), ["gpt-4o", "gpt-5.5"])
        let bare = #"["a","b"]"#
        XCTAssertEqual(ProviderDoctor.parseModelIds(Data(bare.utf8)), ["a", "b"])
        XCTAssertEqual(ProviderDoctor.parseModelIds(Data("garbage".utf8)), [])
    }

    func testCheckSkipsUnkeyedProviderHonestly() async {
        let p = grokLike()
        let reports = await ProviderDoctor.check(providers: [p], apiKey: { _ in nil },
                                                 fetch: { _, _ in .success(["should-not-be-called"]) })
        XCTAssertEqual(reports.count, 1)
        XCTAssertFalse(reports[0].reachable)
        XCTAssertEqual(reports[0].error, "no API key configured")
    }

    func testCheckReportsFetchFailureAsUnreachableNotBroken() async {
        let p = grokLike()
        struct Boom: Error {}
        let reports = await ProviderDoctor.check(providers: [p], apiKey: { _ in "key" },
                                                 fetch: { _, _ in .failure(Boom()) })
        XCTAssertFalse(reports[0].reachable)
        XCTAssertNotNil(reports[0].error)
    }

    func testRenderFlagsDriftLoudly() {
        let r = ProviderDoctor.diff(provider: grokLike(), liveModelIds: ["grok-4.3"])
        let text = ProviderDoctor.render([r])
        XCTAssertTrue(text.contains("dead catalog ids"))
        XCTAssertTrue(text.contains("grok-2-latest"))
    }

    func testRenderDistinguishesSkippedFromUnreachable() {
        let p = grokLike()
        let noKey = ProviderDoctor.render([ProviderDoctor.unreachable(provider: p, error: "no API key configured")])
        XCTAssertTrue(noKey.contains("⬜️ skipped"))
        let errored = ProviderDoctor.render([ProviderDoctor.unreachable(provider: p, error: "timed out")])
        XCTAssertTrue(errored.contains("🔌 unreachable"))
        XCTAssertFalse(errored.contains("skipped"))
    }
}
