import XCTest
@testable import AgentCore

/// Pins the "configure" half of Drop-a-Key/Drop-a-Doc: onboarding persists a verified model's stops,
/// and the agent loop injects them at generation time so a local model halts at its real turn boundary.
final class LocalModelProfileStoreTests: XCTestCase {

    private func tempStore() -> (LocalModelProfileStore, String) {
        let dir = NSTemporaryDirectory() + "prof-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (LocalModelProfileStore(path: dir + "/model-profiles.json"), dir)
    }

    func testRecordThenLookupExact() {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tpl = LocalModelTemplate.from(chatTemplate: "<|im_end|>", eosToken: nil, modelName: "qwen", source: "t")
        XCTAssertTrue(store.record(providerId: "ollama", model: "qwen2-7b", template: tpl, verifiedReady: true))
        XCTAssertEqual(store.stops(providerId: "ollama", model: "qwen2-7b"), tpl.stopSequences)
        XCTAssertTrue(tpl.stopSequences.contains("<|im_end|>"))
    }

    func testProviderWideFallbackWhenModelNotMatched() {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tpl = LocalModelTemplate.from(chatTemplate: "<|eot_id|>", eosToken: nil, modelName: nil, source: "t")
        store.record(providerId: "local", model: nil, template: tpl, verifiedReady: true)   // provider-wide entry
        // a specific model with no exact entry falls back to the provider-wide stops
        XCTAssertEqual(store.stops(providerId: "local", model: "some-unseen-model"), tpl.stopSequences)
    }

    func testExactBeatsProviderWide() {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        store.record(providerId: "local", model: nil,
                     template: LocalModelTemplate.from(chatTemplate: "<|eot_id|>", eosToken: nil, modelName: nil, source: "t"), verifiedReady: true)
        store.record(providerId: "local", model: "m",
                     template: LocalModelTemplate.from(chatTemplate: "<|im_end|>", eosToken: nil, modelName: nil, source: "t"), verifiedReady: true)
        XCTAssertEqual(store.stops(providerId: "local", model: "m"), ["<|im_end|>", "<|endoftext|>"])
    }

    func testMissingStoreIsFailSoft() {
        let store = LocalModelProfileStore(path: "/no/such/dir/profiles.json")
        XCTAssertNil(store.stops(providerId: "x", model: "y"))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testRecordPersistsAcrossInstances() {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        store.record(providerId: "ollama", model: "llama3",
                     template: LocalModelTemplate.from(chatTemplate: "<|eot_id|>", eosToken: nil, modelName: nil, source: "gguf"), verifiedReady: true)
        let reopened = LocalModelProfileStore(path: store.path)   // fresh instance, same file
        XCTAssertEqual(reopened.stops(providerId: "ollama", model: "llama3"), ["<|eot_id|>", "<|end_of_text|>"])
    }

    func testColonBearingProviderAndModelKeysDoNotAlias() {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertTrue(store.record(providerId: "a", model: "b:c",
                                   template: LocalModelTemplate(family: .unknown, eosToken: "ONE", source: "t"),
                                   verifiedReady: true))
        XCTAssertTrue(store.record(providerId: "a:b", model: "c",
                                   template: LocalModelTemplate(family: .unknown, eosToken: "TWO", source: "t"),
                                   verifiedReady: true))

        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(store.stops(providerId: "a", model: "b:c"), ["ONE"])
        XCTAssertEqual(store.stops(providerId: "a:b", model: "c"), ["TWO"])
    }

    func testConcurrentRecordsDoNotClobberEachOther() async {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let count = 24

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<count {
                group.addTask {
                    store.record(providerId: "local", model: "m\(i)",
                                 template: LocalModelTemplate(family: .unknown, eosToken: "STOP-\(i)", source: "t"),
                                 verifiedReady: true)
                }
            }
            for await saved in group { XCTAssertTrue(saved) }
        }

        XCTAssertEqual(store.all().count, count)
        for i in 0..<count {
            XCTAssertEqual(store.stops(providerId: "local", model: "m\(i)"), ["STOP-\(i)"])
        }
    }

    // END-TO-END: the loop must inject a matching profile's stops into the generation settings.
    func testLoopInjectsProfileStopsIntoSettings() async {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        store.record(providerId: "local", model: "weak-1b",
                     template: LocalModelTemplate.from(chatTemplate: "<|im_end|>", eosToken: nil, modelName: nil, source: "t"), verifiedReady: true)

        let provider = StopCaptureProvider()
        let registry = ProviderRegistry(providers: [provider], keyStore: NullKeyStore())
        let root = ToolContext.canonicalize(dir) ?? dir
        _ = await HeadlessAgentLoop(providers: registry, providerId: "local", model: "weak-1b",
                                    tools: .headless(), context: ToolContext(projectRoot: root),
                                    maxIterations: 2, modelProfiles: store).run(goal: "go")
        let seen = await provider.lastStops()
        XCTAssertEqual(seen, ["<|im_end|>", "<|endoftext|>"], "the loop must inject the verified profile's stop sequences")
    }

    func testLoopWithoutProfileLeavesStopsEmpty() async {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let provider = StopCaptureProvider()
        let registry = ProviderRegistry(providers: [provider], keyStore: NullKeyStore())
        let root = ToolContext.canonicalize(dir) ?? dir
        _ = await HeadlessAgentLoop(providers: registry, providerId: "local", model: "no-profile",
                                    tools: .headless(), context: ToolContext(projectRoot: root),
                                    maxIterations: 2, modelProfiles: store).run(goal: "go")
        let seen = await provider.lastStops()
        XCTAssertTrue(seen.isEmpty, "no profile ⇒ no injected stops (provider/server-side stops apply)")
    }

    func testLoopInjectsProfileStopsIntoFinalSynthesisPass() async {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        store.record(providerId: "local", model: "weak-1b",
                     template: LocalModelTemplate.from(chatTemplate: "<|im_end|>", eosToken: nil, modelName: nil, source: "t"), verifiedReady: true)

        let provider = ScriptedStopCaptureProvider(responses: [
            "not a protocol action 1",
            "not a protocol action 2",
            "not a protocol action 3",
            #"{"done":true,"summary":"final"}"#,
        ])
        let registry = ProviderRegistry(providers: [provider], keyStore: NullKeyStore())
        let root = ToolContext.canonicalize(dir) ?? dir
        _ = await HeadlessAgentLoop(providers: registry, providerId: "local", model: "weak-1b",
                                    tools: .headless(), context: ToolContext(projectRoot: root),
                                    maxIterations: 4, modelProfiles: store).run(goal: "go")

        let seen = await provider.allStops()
        XCTAssertEqual(seen, [
            ["<|im_end|>", "<|endoftext|>"],
            ["<|im_end|>", "<|endoftext|>"],
            ["<|im_end|>", "<|endoftext|>"],
            ["<|im_end|>", "<|endoftext|>"],
        ])
    }
}

private struct NullKeyStore: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

/// Text-path provider that records the stop sequences it was handed, then finishes.
private final class StopCaptureProvider: ChatProvider, @unchecked Sendable {
    let id = "local", name = "Local", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "local", defaultModel = "l1"
    let availableModels = [AIModel(id: "l1")]
    private let box = Box()
    private actor Box { var stops: [String] = []; func set(_ s: [String]) { stops = s }; func get() -> [String] { stops } }
    func lastStops() async -> [String] { await box.get() }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        await box.set(settings.stopSequences)
        return AsyncThrowingStream { c in c.yield(.delta(#"{"done":true,"summary":"ok"}"#)); c.finish() }
    }
}

/// Text-path provider that records every stop sequence it was handed, returning scripted responses.
private final class ScriptedStopCaptureProvider: ChatProvider, @unchecked Sendable {
    let id = "local", name = "Local", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "local", defaultModel = "l1"
    let availableModels = [AIModel(id: "l1")]
    private let box: Box

    init(responses: [String]) {
        self.box = Box(responses: responses)
    }

    private actor Box {
        var responses: [String]
        var index = 0
        var stops: [[String]] = []

        init(responses: [String]) { self.responses = responses }

        func next(stops newStops: [String]) -> String {
            stops.append(newStops)
            let response = index < responses.count ? responses[index] : (responses.last ?? #"{"done":true,"summary":"ok"}"#)
            index += 1
            return response
        }

        func allStops() -> [[String]] { stops }
    }

    func allStops() async -> [[String]] { await box.allStops() }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let response = await box.next(stops: settings.stopSequences)
        return AsyncThrowingStream { c in c.yield(.delta(response)); c.finish() }
    }
}
