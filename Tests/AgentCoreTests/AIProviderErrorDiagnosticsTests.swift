import XCTest
@testable import AgentCore

final class AIProviderErrorDiagnosticsTests: XCTestCase {
    func testEveryCaseHasAUsefulLocalizedDescription() {
        let errors: [AIProviderError] = [
            .missingAPIKey(provider: "anthropic"),
            .invalidAPIKey,
            .rateLimited,
            .invalidResponse("missing choices"),
            .http(status: 502, body: "bad gateway"),
            .transport("connection reset"),
            .configuration("missing project identifier"),
            .streamTimedOut(provider: "ollama", model: "qwen3", phase: .firstEvent),
        ]

        for error in errors {
            let description = error.localizedDescription
            XCTAssertFalse(description.isEmpty)
            XCTAssertFalse(description.contains("AgentCore.AIProviderError error"), description)
        }
    }

    func testStreamTimeoutPreservesProviderModelAndPhase() {
        let description = AIProviderError.streamTimedOut(
            provider: "openai", model: "gpt-test", phase: .idle).localizedDescription

        XCTAssertTrue(description.contains("provider: openai"), description)
        XCTAssertTrue(description.contains("model: gpt-test"), description)
        XCTAssertTrue(description.contains("phase: idle"), description)
    }

    func testTransportAndConfigurationContextIsRedactedSingleLineAndBounded() {
        let secret = "sk-" + String(repeating: "a", count: 48)
        let longContext = "Authorization: Bearer \(secret)\n" + String(repeating: "x", count: 2_000)

        for error in [AIProviderError.transport(longContext), .configuration(longContext)] {
            let description = error.localizedDescription
            XCTAssertFalse(description.contains(secret), description)
            XCTAssertFalse(description.contains("\n"), description)
            XCTAssertTrue(description.contains("[truncated]"), description)
            XCTAssertLessThan(description.count, 400)
        }
    }

    func testInvalidResponseContextIsRedactedAndBounded() {
        let secret = "sk-" + String(repeating: "b", count: 48)
        let description = AIProviderError.invalidResponse(
            "invalid payload api_key=\(secret) " + String(repeating: "z", count: 2_000)
        ).localizedDescription

        XCTAssertFalse(description.contains(secret), description)
        XCTAssertTrue(description.contains("invalid payload"), description)
        XCTAssertTrue(description.contains("[truncated]"), description)
        XCTAssertLessThan(description.count, 400)
    }

    func testHTTPDiagnosticKeepsStatusButNeverEchoesBody() {
        let secret = "server echoed Authorization: Bearer top-secret-token"
        let description = AIProviderError.http(
            status: 503, body: secret + String(repeating: "x", count: 10_000)
        ).localizedDescription

        XCTAssertTrue(description.contains("503"), description)
        XCTAssertTrue(description.contains("response body omitted"), description)
        XCTAssertFalse(description.contains("top-secret-token"), description)
        XCTAssertLessThan(description.count, 160)
    }

    func testOpaqueAuthorizationBearerHeadersAreRedactedAndBounded() {
        let token = "opaque.oauth.token_ABC1234567890+/="
        let headers = [
            "Authorization: Bearer \(token)",
            "authorization : bearer    \(token)",
            "AUTHORIZATION:\tBEARER\t\(token)",
        ]

        for header in headers {
            XCTAssertEqual(SecretMasker.mask(header), SecretMasker.marker)
            let context = header + " " + String(repeating: "x", count: 2_000)
            for error in [
                AIProviderError.transport(context),
                .configuration(context),
                .invalidResponse(context),
            ] {
                let description = error.localizedDescription
                XCTAssertFalse(description.contains(token), description)
                XCTAssertTrue(description.contains(SecretMasker.marker), description)
                XCTAssertTrue(description.contains("[truncated]"), description)
                XCTAssertLessThan(description.count, 400)
            }
        }
    }
}
