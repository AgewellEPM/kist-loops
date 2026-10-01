import XCTest
@testable import AgentCore

final class OllamaIdleLifecycleTests: XCTestCase {
    func testBothProtocolsRequestNoIdleWeightResidency() throws {
        for provider in [OllamaProvider(), OllamaProvider.cobol()] {
            let model = provider.defaultModel
            let settings = ModelSettings(maxTokens: 17)
            let text = provider.makeBody(messages: [.init(role: .user, content: "hello")], model: model, settings: settings)
            let native = try provider.makeBodyTools(messages: [.init(role: .user, content: "hello")], model: model,
                                                     settings: settings, tools: [])
            for body in [text, native] {
                XCTAssertEqual(body["keep_alive"] as? Int, 0)
                XCTAssertEqual(body["model"] as? String, model)
                XCTAssertEqual((body["options"] as? [String: Any])?["num_predict"] as? Int, 17)
            }
        }
    }
}
