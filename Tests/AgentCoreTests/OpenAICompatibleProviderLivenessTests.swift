import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AgentCore

final class OpenAICompatibleProviderLivenessTests: XCTestCase {
    func testKeepalivesWithoutParsedProgressTimeOutWaitingForFirstEvent() async throws {
        SSEProtocolState.shared.reset(to: .emptyKeepalives)
        let provider = makeProvider(first: 0.05, idle: 0.2)

        do {
            let stream = try await provider.stream(
                messages: [.init(role: .user, content: "hello")],
                model: "test-model",
                settings: .init(),
                apiKey: nil
            )
            for try await _ in stream {}
            XCTFail("expected first-event timeout")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, .streamTimedOut(
                provider: "test-openai",
                model: "test-model",
                phase: .firstEvent
            ))
        }

        let transportCancelled = await waitForTransportCancellation()
        XCTAssertTrue(transportCancelled)
    }

    func testParsedReasoningStartsIdleWatchdog() async throws {
        SSEProtocolState.shared.reset(to: .oneReasoningFrame)
        let provider = makeProvider(first: 0.2, idle: 0.05)
        var sawReasoning = false

        do {
            let stream = try await provider.stream(
                messages: [.init(role: .user, content: "think")],
                model: "test-model",
                settings: .init(),
                apiKey: nil
            )
            for try await event in stream {
                if case .reasoning = event { sawReasoning = true }
            }
            XCTFail("expected idle timeout")
        } catch let error as AIProviderError {
            XCTAssertTrue(sawReasoning)
            XCTAssertEqual(error, .streamTimedOut(
                provider: "test-openai",
                model: "test-model",
                phase: .idle
            ))
        }

        let transportCancelled = await waitForTransportCancellation()
        XCTAssertTrue(transportCancelled)
    }

    func testReasoningAndDeltaProgressResetIdleWatchdogUntilDone() async throws {
        SSEProtocolState.shared.reset(to: .progressThenDone)
        let provider = makeProvider(first: 0.08, idle: 0.08)
        let stream = try await provider.stream(
            messages: [.init(role: .user, content: "finish")],
            model: "test-model",
            settings: .init(),
            apiKey: nil
        )
        var eventCount = 0

        for try await _ in stream { eventCount += 1 }

        XCTAssertGreaterThanOrEqual(eventCount, 3)
    }

    private func makeProvider(first: TimeInterval, idle: TimeInterval) -> OpenAICompatibleProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingSSEURLProtocol.self]
        return OpenAICompatibleProvider(
            id: "test-openai",
            name: "Test OpenAI",
            iconName: "cpu",
            keyAccount: "test-openai",
            endpoint: "https://example.test/v1/chat/completions",
            defaultModel: "test-model",
            availableModels: [.init(id: "test-model")],
            requiresAPIKey: false,
            session: URLSession(configuration: configuration),
            firstEventTimeout: first,
            idleEventTimeout: idle
        )
    }

    private func waitForTransportCancellation() async -> Bool {
        for _ in 0..<20 {
            if SSEProtocolState.shared.stopCount > 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

private final class SSEProtocolState: @unchecked Sendable {
    enum Scenario: Sendable {
        case emptyKeepalives
        case oneReasoningFrame
        case progressThenDone
    }

    static let shared = SSEProtocolState()
    private let lock = NSLock()
    private var storedScenario: Scenario = .emptyKeepalives
    private var storedStopCount = 0

    var scenario: Scenario {
        lock.lock()
        defer { lock.unlock() }
        return storedScenario
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStopCount
    }

    func reset(to scenario: Scenario) {
        lock.lock()
        storedScenario = scenario
        storedStopCount = 0
        lock.unlock()
    }

    func markStopped() {
        lock.lock()
        storedStopCount += 1
        lock.unlock()
    }
}

private final class StreamingSSEURLProtocol: URLProtocol, @unchecked Sendable {
    private var worker: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let scenario = SSEProtocolState.shared.scenario
        worker = Task { [weak self] in
            guard let self else { return }
            switch scenario {
            case .emptyKeepalives:
                send(": keepalive\n\ndata: {}\n\n")
            case .oneReasoningFrame:
                send("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}\n\n")
            case .progressThenDone:
                send("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"one\"}}]}\n\n")
                guard await pause() else { return }
                send("data: {\"choices\":[{\"delta\":{\"content\":\"two\"}}]}\n\n")
                guard await pause() else { return }
                send("data: {\"choices\":[{\"delta\":{\"content\":\"three\"}}]}\n\n")
                guard await pause() else { return }
                send("data: [DONE]\n\n")
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        worker?.cancel()
        worker = nil
        SSEProtocolState.shared.markStopped()
    }

    private func send(_ value: String) {
        guard !Task.isCancelled else { return }
        client?.urlProtocol(self, didLoad: Data(value.utf8))
    }

    private func pause() async -> Bool {
        do {
            try await Task.sleep(nanoseconds: 40_000_000)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
