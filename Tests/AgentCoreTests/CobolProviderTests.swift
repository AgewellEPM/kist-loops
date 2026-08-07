import XCTest
@testable import AgentCore

/// The offline COBOL model as a first-class provider (Luke sync audit 2026-08-06: "hooked up",
/// not just reachable via `-p ollama -m …`).
final class CobolProviderTests: XCTestCase {

    func testCatalogExposesCobolProvider() {
        let cobol = ProviderCatalog.all.first { $0.id == "cobol" }
        XCTAssertNotNil(cobol, "kist -p cobol must resolve a first-class provider")
        XCTAssertEqual(cobol?.defaultModel, "cobol-jeeves-ft:latest")
        XCTAssertFalse(cobol?.requiresAPIKey ?? true, "the offline COBOL model needs no key")
        XCTAssertTrue(cobol?.availableModels.contains { $0.id == "cobol-jeeves:latest" } ?? false,
                      "both the fine-tuned and base cobol-jeeves models are offered")
    }

    // It's a SPECIALIST — must not become the general default. The strongest-leads/cheapest picks
    // draw from keyed-cloud + subscription CLIs; cobol (a bare local, not a CLIChatProvider) is
    // never in that eligible pool, so it can only be reached by an explicit -p cobol.
    func testCobolIsNotInTheDefaultEligiblePool() {
        let registry = ProviderRegistry(providers: ProviderCatalog.all, keyStore: NullKeyStoreForCobolTest())
        let subscriptionReady = registry.providers.filter { p in
            !p.requiresAPIKey && (p as? CLIChatProvider)?.isLocallyAvailable() == true
        }
        let keyedCloud = registry.providers.filter { $0.requiresAPIKey && registry.hasKey(for: $0) }
        let eligible = (subscriptionReady + keyedCloud).map(\.id)
        XCTAssertFalse(eligible.contains("cobol"), "the COBOL specialist must never auto-lead the default")
    }

    // Under cost mode it's priced as free (local), never sorted as an unpriced 'expensive' vendor.
    func testCobolIsPricedFreeForCostMode() {
        XCTAssertEqual(ProviderCostRank.marginalPerMillion("cobol"), 0.0)
    }

    // The generic Ollama provider is unchanged by the parameterization.
    func testDefaultOllamaProviderUnchanged() {
        let o = OllamaProvider()
        XCTAssertEqual(o.id, "ollama")
        XCTAssertEqual(o.defaultModel, "llama3.1")
    }
}

private struct NullKeyStoreForCobolTest: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}
