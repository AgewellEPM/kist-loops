import XCTest
@testable import AgentCore

/// Local Ollama embeddings client — request shape + response parsing, verified with an
/// injected transport (no real Ollama server is contacted).
final class OllamaEmbeddingsTests: XCTestCase {

    private final class CapturingTransport: HTTPTransport, @unchecked Sendable {
        var lastRequest: URLRequest?
        let status: Int
        let body: Data
        init(status: Int = 200, body: Data) { self.status = status; self.body = body }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lastRequest = request
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }
    }

    func testRequestHitsApiEmbedWithModelAndBatchInput() async throws {
        let json = #"{"embeddings":[[0.1,0.2],[0.3,0.4]]}"#.data(using: .utf8)!
        let t = CapturingTransport(body: json)
        let client = OllamaEmbeddingClient(model: "nomic-embed-text", transport: t, baseURL: "http://127.0.0.1:11434")
        let vectors = try await client.embeddings(for: ["a", "b"])
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0], [0.1, 0.2])
        // request shape
        let req = try XCTUnwrap(t.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:11434/api/embed")
        XCTAssertEqual(req.httpMethod, "POST")
        let sentBody = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(sentBody?["model"] as? String, "nomic-embed-text")
        XCTAssertEqual(sentBody?["input"] as? [String], ["a", "b"], "must send a BATCH input array")
    }

    func testEmptyInputShortCircuits() async throws {
        let client = OllamaEmbeddingClient(transport: CapturingTransport(body: Data()))
        let v = try await client.embeddings(for: [])
        XCTAssertEqual(v, [])
    }

    func testHttpErrorThrows() async {
        let t = CapturingTransport(status: 500, body: "boom".data(using: .utf8)!)
        let client = OllamaEmbeddingClient(transport: t)
        do { _ = try await client.embeddings(for: ["x"]); XCTFail("expected throw") }
        catch let e as OllamaEmbeddingClient.EmbeddingError {
            guard case .http(500, _) = e else { return XCTFail("expected http(500), got \(e)") }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    func testCountMismatchThrows() async {
        // Server returned 1 vector for 2 inputs → must fail (order/count contract).
        let json = #"{"embeddings":[[0.1,0.2]]}"#.data(using: .utf8)!
        let client = OllamaEmbeddingClient(transport: CapturingTransport(body: json))
        do { _ = try await client.embeddings(for: ["a", "b"]); XCTFail("expected throw") }
        catch let e as OllamaEmbeddingClient.EmbeddingError {
            guard case .badResponse = e else { return XCTFail("expected badResponse, got \(e)") }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    func testParseHandlesIntAndDoubleNumbers() throws {
        let json = #"{"embeddings":[[1,2,3]]}"#.data(using: .utf8)!   // JSON ints
        let v = try OllamaEmbeddingClient.parse(json, expected: 1)
        XCTAssertEqual(v, [[1.0, 2.0, 3.0]])
    }

    func testOllamaHostEnvOverride() {
        setenv("OLLAMA_HOST", "http://box.local:9999", 1)
        defer { unsetenv("OLLAMA_HOST") }
        XCTAssertEqual(OllamaEmbeddingClient.defaultBaseURL(), "http://box.local:9999")
        setenv("OLLAMA_HOST", "box.local:9999", 1)   // no scheme → http:// prepended
        XCTAssertEqual(OllamaEmbeddingClient.defaultBaseURL(), "http://box.local:9999")
    }

    func testConformsToEmbeddingProviding() {
        let client: EmbeddingProviding = OllamaEmbeddingClient(transport: CapturingTransport(body: Data()))
        XCTAssertNotNil(client)   // swappable anywhere GeminiEmbeddingClient is used
    }
}
