import XCTest
@testable import AgentCore

private actor ScriptedTransport: HTTPTransport {
    private var responses: [(Data, HTTPURLResponse)]
    private(set) var sentCount = 0
    init(_ responses: [(Data, HTTPURLResponse)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sentCount += 1
        guard !responses.isEmpty else { throw AIProviderError.transport("no scripted response") }
        return responses.removeFirst()
    }
}

private func resp(_ url: String, _ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}
private func json(_ s: String) -> Data { s.data(using: .utf8)! }

final class GeminiFilesClientTests: XCTestCase {

    func testUploadResumableThenPollsUntilActive() async throws {
        let uploadURL = "https://up.example/abc"
        let transport = ScriptedTransport([
            // 1. start → header carries the upload URL
            (Data(), resp("https://g/files", 200, headers: ["X-Goog-Upload-URL": uploadURL])),
            // 2. finalize → file is still PROCESSING
            (json(#"{"file":{"uri":"https://g/files/v1","name":"files/v1","state":"PROCESSING"}}"#), resp(uploadURL, 200)),
            // 3. poll → PROCESSING
            (json(#"{"uri":"https://g/files/v1","name":"files/v1","state":"PROCESSING"}"#), resp("https://g/files/v1", 200)),
            // 4. poll → ACTIVE
            (json(#"{"uri":"https://g/files/v1","name":"files/v1","state":"ACTIVE"}"#), resp("https://g/files/v1", 200)),
        ])
        var slept = 0
        let client = GeminiFilesClient(apiKey: "k", transport: transport, maxPolls: 10,
                                       sleep: { _ in slept += 1 })

        let uri = try await client.upload(data: Data([1, 2, 3]), mimeType: "video/mp4", displayName: "clip.mp4")
        XCTAssertEqual(uri, "https://g/files/v1")
        let sent = await transport.sentCount
        XCTAssertEqual(sent, 4)          // start + finalize + 2 polls
        XCTAssertEqual(slept, 2)         // slept once before each poll
    }

    func testDeleteSendsRequestForFileUriAndIsBestEffort() async throws {
        // A files/ uri → one DELETE request.
        let t1 = ScriptedTransport([(Data(), resp("https://g", 200))])
        try await GeminiFilesClient(apiKey: "k", transport: t1)
            .delete(uri: "https://generativelanguage.googleapis.com/v1beta/files/abc123")
        let s1 = await t1.sentCount; XCTAssertEqual(s1, 1)

        // No "files/" in the uri → nothing to delete, no request, no crash.
        let t2 = ScriptedTransport([])
        try await GeminiFilesClient(apiKey: "k", transport: t2).delete(uri: "https://example.com/nope")
        let s2 = await t2.sentCount; XCTAssertEqual(s2, 0)

        // Transport error on delete is swallowed (best-effort cleanup must never fail the caller).
        let t3 = ScriptedTransport([])   // empty → send throws
        try await GeminiFilesClient(apiKey: "k", transport: t3)
            .delete(uri: "https://g/v1beta/files/xyz")   // does not throw
    }

    func testUploadFailsWhenNoUploadURLHeader() async {
        let transport = ScriptedTransport([(Data(), resp("https://g/files", 200))])  // no header
        let client = GeminiFilesClient(apiKey: "k", transport: transport, sleep: { _ in })
        do {
            _ = try await client.upload(data: Data([1]), mimeType: "image/png", displayName: "x.png")
            XCTFail("expected noUploadURL")
        } catch {
            XCTAssertEqual(error as? GeminiFilesClient.FilesError, .noUploadURL)
        }
    }

    func testUploadThrowsOnProcessingFailed() async {
        let uploadURL = "https://up.example/abc"
        let transport = ScriptedTransport([
            (Data(), resp("https://g/files", 200, headers: ["X-Goog-Upload-URL": uploadURL])),
            (json(#"{"file":{"uri":"u","name":"files/v","state":"FAILED"}}"#), resp(uploadURL, 200)),
        ])
        let client = GeminiFilesClient(apiKey: "k", transport: transport, sleep: { _ in })
        do {
            _ = try await client.upload(data: Data([1]), mimeType: "video/mp4", displayName: "x.mp4")
            XCTFail("expected processingFailed")
        } catch {
            XCTAssertEqual(error as? GeminiFilesClient.FilesError, .processingFailed)
        }
    }

    func testUploadTimesOutAfterMaxPolls() async {
        let uploadURL = "https://up.example/abc"
        // finalize PROCESSING, then always PROCESSING on polls → must time out.
        var scripted: [(Data, HTTPURLResponse)] = [
            (Data(), resp("https://g/files", 200, headers: ["X-Goog-Upload-URL": uploadURL])),
            (json(#"{"file":{"uri":"u","name":"files/v","state":"PROCESSING"}}"#), resp(uploadURL, 200)),
        ]
        for _ in 0..<5 { scripted.append((json(#"{"uri":"u","name":"files/v","state":"PROCESSING"}"#), resp("https://g/files/v", 200))) }
        let transport = ScriptedTransport(scripted)
        let client = GeminiFilesClient(apiKey: "k", transport: transport, maxPolls: 3, sleep: { _ in })
        do {
            _ = try await client.upload(data: Data([1]), mimeType: "video/mp4", displayName: "x.mp4")
            XCTFail("expected timedOut")
        } catch {
            XCTAssertEqual(error as? GeminiFilesClient.FilesError, .timedOut)
        }
    }

    func testParseFileHandlesWrappedAndBareShapes() throws {
        let wrapped = try GeminiFilesClient.parseFile(json(#"{"file":{"uri":"u1","name":"files/a","state":"ACTIVE"}}"#))
        XCTAssertEqual(wrapped, .init(uri: "u1", name: "files/a", state: "ACTIVE"))
        let bare = try GeminiFilesClient.parseFile(json(#"{"uri":"u2","name":"files/b"}"#))
        XCTAssertEqual(bare.state, "PROCESSING")   // default when absent
    }
}
