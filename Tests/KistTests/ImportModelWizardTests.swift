import XCTest
@testable import Kist

/// The pure URL helpers behind `/model import` — endpoint normalization + id suggestion. The interactive
/// flow (network discovery, key prompt, onboarding) is exercised end-to-end live, not here.
final class ImportModelWizardTests: XCTestCase {

    func testModelsEndpointFromBaseVariants() {
        XCTAssertEqual(ImportModelWizard.modelsEndpoint(fromBase: "https://api.together.xyz/v1"),
                       "https://api.together.xyz/v1/models")
        XCTAssertEqual(ImportModelWizard.modelsEndpoint(fromBase: "https://api.together.xyz/v1/"),
                       "https://api.together.xyz/v1/models")            // trailing slash tolerated
        XCTAssertEqual(ImportModelWizard.modelsEndpoint(fromBase: "https://host.com/v1/chat/completions"),
                       "https://host.com/v1/models")                    // chat endpoint → models
        XCTAssertEqual(ImportModelWizard.modelsEndpoint(fromBase: "https://host.com/v2"),
                       "https://host.com/v2/models")                    // any /vN
        XCTAssertEqual(ImportModelWizard.modelsEndpoint(fromBase: "https://host.com"),
                       "https://host.com/v1/models")                    // bare host → /v1/models
        XCTAssertEqual(ImportModelWizard.modelsEndpoint(fromBase: "https://host.com/openai/v1/models"),
                       "https://host.com/openai/v1/models")             // already /models → unchanged
    }

    func testSuggestedIdFromHost() {
        XCTAssertEqual(ImportModelWizard.suggestedId(fromURL: "https://api.together.xyz/v1"), "together")
        XCTAssertEqual(ImportModelWizard.suggestedId(fromURL: "https://api.fireworks.ai/inference/v1"), "fireworks")
        XCTAssertEqual(ImportModelWizard.suggestedId(fromURL: "http://localhost:1234/v1"), "local")
        XCTAssertEqual(ImportModelWizard.suggestedId(fromURL: "https://api.openai.com/v1"), "openai")
        XCTAssertEqual(ImportModelWizard.suggestedId(fromURL: "garbage"), "garbage")
        XCTAssertFalse(ImportModelWizard.suggestedId(fromURL: "https://api.x.ai/v1").isEmpty)
    }
}
