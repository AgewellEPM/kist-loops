import XCTest
@testable import AgentCore

final class ProviderHealthTests: XCTestCase {
    func testDefaultLiveProbeTimeoutAllowsFullProviderLatency() {
        XCTAssertEqual(ProviderHealthChecker.defaultLiveProbeTimeoutNanoseconds, 120_000_000_000)
    }

    func testCatalogReportFlagsMissingKeysAndToolMode() {
        let registry = ProviderRegistry(
            providers: [
                HealthProvider(id: "keyed", requiresKey: true, native: true),
                HealthProvider(id: "local", requiresKey: false, native: false),
            ],
            keyStore: HealthKeys(keys: [:])
        )

        let report = ProviderHealthChecker.catalogReport(registry)

        XCTAssertEqual(report.rows.first { $0.providerId == "keyed" }?.state, .missingKey)
        XCTAssertEqual(report.rows.first { $0.providerId == "keyed" }?.toolMode, .native)
        XCTAssertEqual(report.rows.first { $0.providerId == "local" }?.state, .ready)
        XCTAssertEqual(report.rows.first { $0.providerId == "local" }?.toolMode, .text)
        XCTAssertTrue(report.render().contains("provider health"))
    }

    func testCatalogReportFlagsDefaultModelNotInCatalog() {
        let registry = ProviderRegistry(
            providers: [HealthProvider(id: "stale", requiresKey: false, defaultModel: "missing", models: ["other"])],
            keyStore: HealthKeys(keys: [:])
        )

        let row = ProviderHealthChecker.catalogReport(registry).rows.first

        XCTAssertEqual(row?.state, .staleCatalog)
        XCTAssertEqual(row?.detail, "default model is not in availableModels")
    }

    func testLiveProbeClassifies404AsStaleCatalog() async {
        let registry = ProviderRegistry(
            providers: [HealthProvider(id: "grok", requiresKey: false, failure: .http(status: 404, body: "model does not exist"))],
            keyStore: HealthKeys(keys: [:])
        )

        let report = await ProviderHealthChecker.liveProbe(registry, bindings: [ProviderBinding(providerId: "grok")])

        XCTAssertEqual(report.rows.first?.state, .staleCatalog)
    }

    func testLiveProbeTreatsReachableEmptyResponseAsFailed() async {
        let registry = ProviderRegistry(
            providers: [HealthProvider(id: "gemini", requiresKey: false, response: "")],
            keyStore: HealthKeys(keys: [:])
        )

        let report = await ProviderHealthChecker.liveProbe(registry, bindings: [ProviderBinding(providerId: "gemini")])

        XCTAssertEqual(report.rows.first?.state, .failed)
        XCTAssertTrue(report.rows.first?.detail.contains("empty completion") == true)
    }

    func testLiveProbeRetriesEmptyTinyProbeWithExpandedBudget() async {
        let registry = ProviderRegistry(
            providers: [HealthProvider(id: "deepseek", requiresKey: false, response: "OK", minTokensForResponse: 64)],
            keyStore: HealthKeys(keys: [:])
        )

        let report = await ProviderHealthChecker.liveProbe(
            registry,
            bindings: [ProviderBinding(providerId: "deepseek")],
            maxTokens: 4
        )

        XCTAssertEqual(report.rows.first?.state, .ready)
        XCTAssertTrue(report.rows.first?.detail.contains("expanded probe budget") == true)
    }

    func testLiveProbeTreatsNonOKResponseAsReachableButNotOK() async {
        let registry = ProviderRegistry(
            providers: [HealthProvider(id: "weird", requiresKey: false, response: "not the requested token")],
            keyStore: HealthKeys(keys: [:])
        )

        let report = await ProviderHealthChecker.liveProbe(
            registry,
            bindings: [ProviderBinding(providerId: "weird")],
            maxTokens: 32
        )

        XCTAssertEqual(report.rows.first?.state, .ready)
        XCTAssertTrue(report.rows.first?.detail.contains("non-OK response") == true)
        XCTAssertFalse(report.rows.first?.detail.contains("live probe OK") == true)
    }

    func testLiveProbeStillFailsWhenExpandedProbeIsEmpty() async {
        let registry = ProviderRegistry(
            providers: [HealthProvider(id: "silent", requiresKey: false, response: "OK", minTokensForResponse: 512)],
            keyStore: HealthKeys(keys: [:])
        )

        let report = await ProviderHealthChecker.liveProbe(
            registry,
            bindings: [ProviderBinding(providerId: "silent")],
            maxTokens: 4
        )

        XCTAssertEqual(report.rows.first?.state, .failed)
        XCTAssertTrue(report.rows.first?.detail.contains("empty completion") == true)
    }

    func testLiveProbeTimesOutHungProviderWithoutBlockingOthers() async {
        let registry = ProviderRegistry(
            providers: [
                HealthProvider(id: "hung", requiresKey: false, hang: true),
                HealthProvider(id: "fast", requiresKey: false, response: "OK"),
            ],
            keyStore: HealthKeys(keys: [:])
        )

        let report = await ProviderHealthChecker.liveProbe(
            registry,
            bindings: [
                ProviderBinding(providerId: "hung"),
                ProviderBinding(providerId: "fast"),
            ],
            timeoutNanoseconds: 20_000_000
        )

        let hung = report.rows.first { $0.providerId == "hung" }
        let fast = report.rows.first { $0.providerId == "fast" }
        XCTAssertEqual(hung?.state, .failed)
        XCTAssertTrue(hung?.detail.contains("timed out") == true)
        XCTAssertEqual(fast?.state, .ready)
    }
}

private struct HealthKeys: KeyStore {
    let keys: [String: String]
    func key(forAccount account: String) -> String? { keys[account] }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private struct HealthProvider: ChatProvider {
    let id: String
    let name: String
    let iconName = "cpu"
    let requiresAPIKey: Bool
    let keyAccount: String
    let defaultModel: String
    let availableModels: [AIModel]
    let native: Bool
    let failure: AIProviderError?
    let response: String
    let hang: Bool
    let minTokensForResponse: Int?

    init(id: String, requiresKey: Bool, native: Bool = false,
         defaultModel: String = "m1", models: [String] = ["m1"],
         failure: AIProviderError? = nil,
         response: String = "OK",
         hang: Bool = false,
         minTokensForResponse: Int? = nil) {
        self.id = id
        self.name = id
        self.requiresAPIKey = requiresKey
        self.keyAccount = "\(id)_key"
        self.defaultModel = defaultModel
        self.availableModels = models.map { AIModel(id: $0) }
        self.native = native
        self.failure = failure
        self.response = response
        self.hang = hang
        self.minTokensForResponse = minTokensForResponse
    }

    var supportsNativeTools: Bool { native }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        if let failure { throw failure }
        if hang {
            return AsyncThrowingStream { _ in }
        }
        let response = minTokensForResponse.map { settings.maxTokens < $0 } == true ? "" : self.response
        return AsyncThrowingStream { continuation in
            if !response.isEmpty { continuation.yield(.delta(response)) }
            continuation.finish()
        }
    }
}
