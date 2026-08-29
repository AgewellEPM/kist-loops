import XCTest
@testable import Kist
@testable import AgentCore

final class ProviderAllowlistTests: XCTestCase {
    func testAbsentPolicyIsUnrestrictedButMalformedPolicyFailsClosed() {
        XCTAssertNil(KistConfig.parse([:]).allowedProviders)
        let intentionalDenyAll = KistConfig.parse(["allowedProviders": []])
        XCTAssertEqual(intentionalDenyAll.allowedProviders, [])
        XCTAssertNil(intentionalDenyAll.providerPolicyError)

        let malformed: [Any] = [
            "codex-cli",
            ["codex-cli", 7] as [Any],
            ["codex-cli", "bad/provider"],
            ["   "],
        ]
        for raw in malformed {
            let config = KistConfig.parse(["allowedProviders": raw])
            XCTAssertEqual(config.allowedProviders, [], "malformed value must deny all: \(raw)")
            XCTAssertNotNil(config.providerPolicyError)
        }

        let invalidJSON = KistConfig.parseData(Data(#"{"allowedProviders":["codex-cli"],}"#.utf8))
        XCTAssertEqual(invalidJSON.allowedProviders, [])
        XCTAssertNotNil(invalidJSON.providerPolicyError)
    }

    func testPolicyPersistenceRoundTripsAndSelectByMergePreservesIt() throws {
        let directory = NSTemporaryDirectory() + "provider-allowlist-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/config.json"

        XCTAssertTrue(KistConfig.writeAllowedProviders(["CODEX-CLI", "codex-cli"], atPath: path))
        XCTAssertTrue(KistConfig.writeSelectBy(.cost, atPath: path))

        let config = KistConfig.parseData(try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(config.allowedProviders, ["codex-cli"])
        XCTAssertEqual(config.selectBy, .cost)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(object["allowedProviders"] as? [String], ["codex-cli"])
    }

    func testRegistryLookupAndExplicitSelectionCannotBypassAllowlist() {
        let config = KistConfig(allowedProviders: ["codex-cli"])
        let registry = KistRunner.makeRegistry(
            config: config,
            providers: [PolicyStubProvider("codex-cli"), PolicyStubProvider("claude-cli"),
                        PolicyStubProvider("onyx-cobol")],
            keyStore: PolicyEmptyKeyStore())

        XCTAssertEqual(registry.providers.map(\.id), ["codex-cli"])
        XCTAssertNotNil(registry.provider(id: "codex-cli"))
        XCTAssertNil(registry.provider(id: "claude-cli"))
        XCTAssertNil(registry.provider(id: "onyx-cobol"),
                     "custom providers remain implemented but are not admitted until allowlisted")

        let forbiddenCLI = KistOptions.parse(["--provider", "claude-cli", "hello"])
        XCTAssertNil(KistRunner.resolveProvider(forbiddenCLI, registry, configProvider: nil))
        let ordinary = KistOptions.parse(["hello"])
        XCTAssertNil(KistRunner.resolveProvider(ordinary, registry, configProvider: "claude-cli"))
        XCTAssertEqual(KistRunner.resolveProvider(ordinary, registry, configProvider: "codex-cli"),
                       "codex-cli")
    }

    func testProviderBackedEmbedderCannotBypassRegistryPolicy() {
        let config = KistConfig(allowedProviders: ["codex-cli"])
        let registry = KistRunner.makeRegistry(
            config: config,
            providers: [PolicyStubProvider("codex-cli"), PolicyStubProvider("ollama")],
            keyStore: PolicyEmptyKeyStore())

        XCTAssertNil(KistRunner.makeEmbedder(
            registry: registry, environment: ["KIST_EMBEDDER": "ollama"]),
            "an environment override cannot resurrect a provider excluded from the registry")
    }

    func testForbiddenProviderCannotBeReachedThroughFallback() async {
        let calls = PolicyProviderCalls()
        let config = KistConfig(allowedProviders: ["codex-cli"])
        let registry = KistRunner.makeRegistry(
            config: config,
            providers: [
                PolicyStubProvider("codex-cli", calls: calls, failure: .configuration("expected")),
                PolicyStubProvider("claude-cli", calls: calls),
            ],
            keyStore: PolicyEmptyKeyStore(),
            fallbackProviderIds: ["codex-cli": ["claude-cli"]],
            retryDelaysNanoseconds: [])

        do {
            _ = try await registry.completeWithRoute(
                providerId: "codex-cli", messages: [ChatMessage(role: .user, content: "test")],
                allowFallback: true)
            XCTFail("the admitted failing provider should surface its error")
        } catch { }

        let codexCalls = await calls.count("codex-cli")
        let claudeCalls = await calls.count("claude-cli")
        XCTAssertEqual(codexCalls, 1)
        XCTAssertEqual(claudeCalls, 0,
                       "a forbidden fallback must never be constructed or called")
    }
}

private struct PolicyEmptyKeyStore: KeyStore {
    func key(forAccount account: String) -> String? { nil }
}

private actor PolicyProviderCalls {
    private var counts: [String: Int] = [:]
    func record(_ providerID: String) { counts[providerID, default: 0] += 1 }
    func count(_ providerID: String) -> Int { counts[providerID, default: 0] }
}

private struct PolicyStubProvider: ChatProvider {
    let id: String
    let calls: PolicyProviderCalls?
    let failure: AIProviderError?
    var name: String { id }
    let iconName = "cpu"
    let requiresAPIKey = false
    var keyAccount: String { id }
    var defaultModel: String { "\(id)-model" }
    var availableModels: [AIModel] { [AIModel(id: defaultModel)] }

    init(_ id: String, calls: PolicyProviderCalls? = nil, failure: AIProviderError? = nil) {
        self.id = id
        self.calls = calls
        self.failure = failure
    }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        await calls?.record(id)
        if let failure { throw failure }
        return AsyncThrowingStream { continuation in
            continuation.yield(.delta("unexpected fallback"))
            continuation.finish()
        }
    }
}
