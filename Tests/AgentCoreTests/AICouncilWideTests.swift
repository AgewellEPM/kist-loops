import XCTest
@testable import AgentCore

/// "Dig in deep" — the WIDE council (2026-07-29): ask EVERY reachable model the same question in
/// parallel, then synthesize agree/disagree. These pin the fan-out, the graceful degradation of a
/// hung/failing mind, the maxMinds cap, and the narrow phrase trigger.
final class AICouncilWideTests: XCTestCase {

    // MARK: phrase trigger

    func testLooksLikeDigDeepFiresOnExplicitAsksOnly() {
        for yes in ["dig in deep on the auth design", "DIG DEEP here",
                    "consult the minds about this", "ask all the models what they think",
                    "can every model weigh in?", "council of models please", "ask everyone"] {
            XCTAssertTrue(AICouncil.looksLikeDigDeep(yes), "should trigger: \(yes)")
        }
        for no in ["digging a hole in the yard", "remind me to buy milk",
                   "the model railway is cool", "I really dig it", "what model are you"] {
            XCTAssertFalse(AICouncil.looksLikeDigDeep(no), "should NOT trigger: \(no)")
        }
    }

    // MARK: fan-out + synthesis

    func testRunWideAsksEveryReachableModelAndSynthesizes() async {
        let a = WideScriptedProvider(id: "alpha", responses: ["alpha answer AAA", "Decision:\n- merged verdict ZZZ\n\nAgreement:\n- all agree on basics.\n\nConfidence: high — consistent."])
        let b = WideScriptedProvider(id: "bravo", responses: ["bravo answer BBB"])
        let c = WideScriptedProvider(id: "charlie", responses: ["charlie answer CCC"])
        let registry = ProviderRegistry(providers: [a, b, c], keyStore: WideNullKeys())
        // planner = alpha ⇒ alpha is both a mind AND the synthesizer (2 calls; fan-out completes first).
        let roles = RoleBindings(default: ProviderBinding(providerId: "alpha"))

        let result = await AICouncil(providers: registry, roles: roles).runWide(goal: "what should we build next")

        XCTAssertEqual(Set(result.minds.map(\.name)), ["alpha", "bravo", "charlie"],
                       "every reachable model must appear as a mind")
        XCTAssertTrue(result.minds.allSatisfy { !$0.failed }, "all minds answered")
        XCTAssertTrue(result.minds.contains { $0.output.contains("bravo answer BBB") }, "each mind's own answer is kept")
        XCTAssertTrue(result.finalPlan.contains("merged verdict ZZZ"), "synthesis must produce ONE merged verdict, not a re-list")
    }

    func testRunWideDegradesGracefullyWhenAMindFails() async {
        let a = WideScriptedProvider(id: "alpha", responses: ["alpha answer", "Decision:\n- merged from two."])
        let b = WideScriptedProvider(id: "bravo", responses: ["bravo answer"])
        let down = WideFailingProvider(id: "charlie")
        let registry = ProviderRegistry(providers: [a, b, down], keyStore: WideNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "alpha"))

        let result = await AICouncil(providers: registry, roles: roles).runWide(goal: "decide")

        let charlie = result.minds.first { $0.name == "charlie" }
        XCTAssertEqual(charlie?.failed, true, "a failing provider becomes a failed mind, not a crash")
        XCTAssertTrue(charlie?.output.contains("FAILED") ?? false)
        XCTAssertTrue(result.finalPlan.contains("merged from two"), "synthesis still runs from the surviving minds")
    }

    func testRunWideCapsAtMaxMinds() async {
        let a = WideScriptedProvider(id: "alpha", responses: ["a", "Decision:\n- capped."])
        let b = WideScriptedProvider(id: "bravo", responses: ["b"])
        let c = WideScriptedProvider(id: "charlie", responses: ["c"])
        let d = WideScriptedProvider(id: "delta", responses: ["d"])
        let registry = ProviderRegistry(providers: [a, b, c, d], keyStore: WideNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "alpha"))

        let result = await AICouncil(providers: registry, roles: roles).runWide(goal: "decide", maxMinds: 2)

        XCTAssertEqual(result.minds.count, 2, "maxMinds must cap the panel size")
    }
}

private struct WideNullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private final class WideScriptedProvider: ChatProvider, @unchecked Sendable {
    let id: String
    let name: String
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount: String
    let defaultModel: String
    let availableModels: [AIModel]
    private let responses: WideResponses

    init(id: String, responses: [String]) {
        self.id = id
        self.name = id
        self.keyAccount = id
        self.defaultModel = "\(id)-default"
        self.availableModels = [AIModel(id: "\(id)-default")]
        self.responses = WideResponses(responses)
    }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let response = await responses.next()
        return AsyncThrowingStream { continuation in
            continuation.yield(.delta(response))
            continuation.finish()
        }
    }
}

private struct WideFailingProvider: ChatProvider {
    let id: String
    let name: String
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount: String
    let defaultModel: String
    let availableModels: [AIModel]

    init(id: String) {
        self.id = id
        self.name = id
        self.keyAccount = id
        self.defaultModel = "\(id)-default"
        self.availableModels = [AIModel(id: "\(id)-default")]
    }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        throw AIProviderError.transport("charlie down")
    }
}

private actor WideResponses {
    private let responses: [String]
    private var index = 0
    init(_ responses: [String]) { self.responses = responses }
    func next() -> String {
        defer { index += 1 }
        return index < responses.count ? responses[index] : "(out of script)"
    }
}
