import XCTest
import AgentCore
@testable import Kist

/// The CONFIGURED default provider yields to a warm one when it is benched (0.17.63). Every
/// one-shot run used to start on the drained OpenAI pinned in captain config, fail, and only then
/// substitute — the same class of bug the build lane's role warming fixed. `--provider` stays
/// absolute; the config pin is a standing preference.
final class ConfiguredDefaultBenchedTests: XCTestCase {
    private func registry(_ ids: [String]) -> ProviderRegistry {
        ProviderRegistry(providers: ids.map { id in
            OpenAICompatibleProvider(
                id: id, name: id, iconName: "cpu", keyAccount: id + "_key",
                endpoint: "http://127.0.0.1/" + id, defaultModel: "m",
                availableModels: [AIModel(id: "m")], requiresAPIKey: false)
        })
    }

    func testWarmConfiguredDefaultIsUsedAsIs() {
        let picked = KistRunner.resolveProvider(
            KistOptions.parse(["hello"]), registry(["openai", "gemini", "deepseek"]),
            configProvider: "openai", benched: { _ in false })
        XCTAssertEqual(picked, "openai")
    }

    func testBenchedConfiguredDefaultYieldsToTheStrongestWarmProvider() {
        let picked = KistRunner.resolveProvider(
            KistOptions.parse(["hello"]), registry(["openai", "gemini", "deepseek"]),
            configProvider: "openai", benched: { $0 == "openai" })
        XCTAssertEqual(picked, "gemini", "strongest warm keyed provider leads this run")
    }

    func testExplicitProviderFlagIsAbsoluteEvenWhenBenched() {
        let picked = KistRunner.resolveProvider(
            KistOptions.parse(["--provider", "openai", "hello"]), registry(["openai", "gemini"]),
            configProvider: nil, benched: { $0 == "openai" })
        XCTAssertEqual(picked, "openai")
    }

    func testEverythingBenchedFailsOpenToTheStrongestEligible() {
        let picked = KistRunner.resolveProvider(
            KistOptions.parse(["hello"]), registry(["openai", "gemini", "deepseek"]),
            configProvider: "deepseek", benched: { _ in true })
        XCTAssertEqual(picked, "openai", "fail-open: the full eligible set competes by strength")
    }

    func testUnknownConfiguredProviderIsStillAnError() {
        XCTAssertNil(KistRunner.resolveProvider(
            KistOptions.parse(["hello"]), registry(["gemini"]),
            configProvider: "nonexistent", benched: { _ in false }))
    }
}
