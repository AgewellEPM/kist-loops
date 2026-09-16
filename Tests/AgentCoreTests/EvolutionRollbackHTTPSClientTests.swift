import Foundation
import XCTest
@testable import AgentCore

final class EvolutionRollbackHTTPSClientTests: XCTestCase {
    private final class StubURLProtocol: URLProtocol {
        static var status = 200
        static var body = Data()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: Self.status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func request() throws -> EvolutionRollbackCASReadRequest {
        try EvolutionRollbackCASReadRequest(
            anchorNamespaceDigest: String(repeating: "a", count: 64),
            projectIdentityDigest: String(repeating: "b", count: 64),
            challenge: String(repeating: "c", count: 32))
    }

    func testConfigurationRejectsPlainHTTPAndEmbeddedCredentials() throws {
        XCTAssertThrowsError(try EvolutionRollbackHTTPSCASClient.Configuration(
            baseURL: URL(string: "http://witness.example")!))
        XCTAssertThrowsError(try EvolutionRollbackHTTPSCASClient.Configuration(
            baseURL: URL(string: "https://user:password@witness.example")!))
        XCTAssertNoThrow(try EvolutionRollbackHTTPSCASClient.Configuration(
            baseURL: URL(string: "http://127.0.0.1:8080")!, allowInsecureLoopback: true))
    }

    func testResponseLimitIsAppliedBeforeWitnessDecoding() async throws {
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data(repeating: 0x41, count: 128)
        let configuration = try EvolutionRollbackHTTPSCASClient.Configuration(
            baseURL: URL(string: "https://witness.example")!, maximumResponseBytes: 64)
        let client = EvolutionRollbackHTTPSCASClient(configuration: configuration, session: session())
        do {
            _ = try await client.readCurrent(request())
            XCTFail("oversized witness response must be rejected")
        } catch let error as EvolutionRollbackHTTPClientError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testNonSuccessStatusDoesNotDecodeAsWitness() async throws {
        StubURLProtocol.status = 409
        StubURLProtocol.body = Data("conflict".utf8)
        let configuration = try EvolutionRollbackHTTPSCASClient.Configuration(
            baseURL: URL(string: "https://witness.example")!)
        let client = EvolutionRollbackHTTPSCASClient(configuration: configuration, session: session())
        do {
            _ = try await client.readCurrent(request())
            XCTFail("HTTP conflict must be surfaced")
        } catch let error as EvolutionRollbackHTTPClientError {
            XCTAssertEqual(error, .httpStatus(409))
        }
    }
}
