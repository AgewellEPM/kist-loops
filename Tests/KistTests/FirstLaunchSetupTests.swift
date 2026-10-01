import XCTest
import AgentCore
@testable import Kist

final class FirstLaunchSetupTests: XCTestCase {
    func testOnlyNewInteractiveSessionOrExplicitSetupShowsPicker() {
        let empty = KistConfig.parse([:])
        XCTAssertTrue(FirstLaunchSetup.shouldRun(arguments: [], isTTY: true, nested: false, config: empty))
        let saved = KistConfig.parse(["provider": "ollama", "model": "chosen"])
        XCTAssertFalse(FirstLaunchSetup.shouldRun(arguments: [], isTTY: true, nested: false, config: saved))
        XCTAssertTrue(FirstLaunchSetup.shouldRun(arguments: ["--setup"], isTTY: true, nested: false, config: saved))
        for arguments in [["--help"], ["--version"], ["fix this"], ["-p", "ollama"]] {
            XCTAssertFalse(FirstLaunchSetup.shouldRun(arguments: arguments, isTTY: true, nested: false, config: empty))
        }
        XCTAssertFalse(FirstLaunchSetup.shouldRun(arguments: [], isTTY: false, nested: false, config: empty))
        XCTAssertFalse(FirstLaunchSetup.shouldRun(arguments: ["--setup"], isTTY: true, nested: true, config: empty))
        XCTAssertFalse(FirstLaunchSetup.shouldRun(arguments: [], isTTY: true, nested: false,
                                                 config: KistConfig.parse(["allowedProviders": "bad"])))
    }

    func testLocalChoiceUsesExistingPickerAndRetainsDownloadInformation() {
        let config = KistConfig.parse(["allowedProviders": ["ollama"]])
        let entries = FirstLaunchSetup.entries(registry: KistRunner.makeRegistry(config: config), locals: [
            .init(model: "qwen2.5-coder:1.5b", installed: false, bytes: 986_062_089),
            .init(model: "installed:latest", installed: true, bytes: 500_000_000)
        ])
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].label.contains("no API charges"))
        XCTAssertTrue(entries[0].label.contains("download"))
        var picker = ModelPickerState(all: entries)
        picker.moveDown()
        XCTAssertEqual(picker.current?.model, "installed:latest")
        XCTAssertTrue(picker.current?.label.contains("installed") == true)
        let cloudOnly = KistRunner.makeRegistry(config: KistConfig.parse(["allowedProviders": ["openai"]]))
        XCTAssertFalse(FirstLaunchSetup.entries(registry: cloudOnly, locals: [
            .init(model: "local", installed: true, bytes: 1)
        ]).contains { $0.providerId == "ollama" })
    }

    func testLocalSelectionPersistsAcrossReposWithoutWideningProviderPolicy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.json")
        try Data(#"{"fetchAllowedHosts":["docs.swift.org"],"custom":42,"localFirst":true}"#.utf8).write(to: path)
        XCTAssertTrue(KistConfig.writeStartupSelection(provider: "ollama", model: "qwen2.5-coder:1.5b",
                                                       localOnly: true, atPath: path.path))
        let data = try Data(contentsOf: path)
        let saved = KistConfig.parseData(data)
        XCTAssertEqual(saved.model, "qwen2.5-coder:1.5b")
        XCTAssertEqual(saved.allowedProviders, ["ollama"])
        XCTAssertFalse(saved.localFirst)
        XCTAssertEqual(saved.autoRouting, false)
        XCTAssertEqual(saved.fetchAllowedHosts, ["docs.swift.org"])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["custom"] as? Int, 42)
        XCTAssertFalse(KistConfig.writeStartupSelection(provider: "openai", model: "cloud",
                                                        localOnly: false, atPath: path.path))
        XCTAssertEqual(KistConfig.parseData(try Data(contentsOf: path)).allowedProviders, ["ollama"])
    }

    func testMalformedConfigurationAndMissingLauncherFailWithoutSelectingModel() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let original = Data("not json".utf8)
        try original.write(to: path)
        XCTAssertFalse(KistConfig.writeStartupSelection(provider: "ollama", model: "local", localOnly: true, atPath: path.path))
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertThrowsError(try FirstLaunchLocalBridge(environment: [:]).prepare(model: "local"))
    }

    func testManagedContextIsSharedByBudgetAndWireRequest() {
        let provider = OllamaProvider(runtimeContextTokens: 16_384)
        let capabilities = provider.capabilities(forModel: "qwen2.5-coder:1.5b")
        XCTAssertEqual(capabilities.contextWindowTokens, 16_384)
        let body = provider.makeBody(messages: [], model: "qwen2.5-coder:1.5b", settings: ModelSettings())
        XCTAssertEqual((body["options"] as? [String: Any])?["num_ctx"] as? Int, 16_384)
        XCTAssertLessThan(ContextWindowManager.forModel(capabilities: capabilities).maxCharacters, 80_000)
        XCTAssertNil(OllamaProvider(runtimeContextTokens: -1).runtimeContextTokens)
    }

    func testSetupHelperUsesLiteralArgumentsAndPropagatesFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("helper with spaces.py")
        let record = directory.appendingPathComponent("arguments.json")
        try """
        import json, os, sys
        from pathlib import Path
        if sys.argv[1] == 'inventory':
            print(json.dumps([{'model':'fixture:small','installed':False,'bytes':123}]))
        else:
            Path(os.environ['PROBE_RECORD']).write_text(json.dumps(sys.argv[2:]))
            sys.exit(7)
        """.write(to: script, atomically: true, encoding: .utf8)
        let bridge = FirstLaunchLocalBridge(environment: [
            "KIST_LOCAL_SETUP_HELPER": script.path, "KIST_LOCAL_SETUP_PYTHON": "/usr/bin/python3",
            "PROBE_RECORD": record.path
        ])
        XCTAssertEqual(try bridge.inventory(), [.init(model: "fixture:small", installed: false, bytes: 123)])
        let literal = "model with spaces; $(not-a-command)"
        XCTAssertThrowsError(try bridge.prepare(model: literal))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: record)), [literal])
    }
}
