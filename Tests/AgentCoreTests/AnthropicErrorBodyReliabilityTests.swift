import Foundation
import XCTest
@testable import AgentCore

final class AnthropicErrorBodyReliabilityTests: XCTestCase {
    func testAuthenticationAndRateLimitBodiesArePreserved() {
        XCTAssertEqual(AnthropicProvider.httpError(status: 401, bodyData: Data("bad credential detail".utf8)),
                       .http(status: 401, body: "bad credential detail"))
        XCTAssertEqual(AnthropicProvider.httpError(status: 429, bodyData: Data("retry after quota reset".utf8)),
                       .http(status: 429, body: "retry after quota reset"))
    }
    func testErrorBodyIsBoundedEvenWithoutNewlines() {
        let oversized = Data(repeating: 120, count: AnthropicProvider.maxErrorBodyBytes + 10_000)
        let error = AnthropicProvider.httpError(status: 500, bodyData: oversized)
        guard case .http(let status, let body) = error else { return XCTFail("expected HTTP error") }
        XCTAssertEqual(status, 500)
        XCTAssertEqual(body.filter { $0 == "x" }.count, AnthropicProvider.maxErrorBodyBytes)
        XCTAssertTrue(body.contains("[error body truncated]"))
    }
}
