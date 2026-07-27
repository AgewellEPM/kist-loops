import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Gemini Live API (BidiGenerateContent) over a WebSocket. The Live API is a realtime, bidirectional
/// session — its unique value is streaming audio, which a terminal can't capture. This client
/// implements the wire PROTOCOL (setup → clientContent → serverContent) and exposes a text round-trip
/// (`ask`) as a transport proof and the foundation for a future voice integration.
///
/// PROTOTYPE: the message builders + parsers are pure and unit-pinned, but the live socket round-trip
/// is NOT verified here (needs a key + a live session).
public struct GeminiLiveClient: Sendable {
    private let apiKey: String
    private let model: String
    private let baseURL: String
    private let maxFrames: Int

    public static let defaultModel = "gemini-2.0-flash-live-001"

    public init(apiKey: String, model: String = defaultModel,
                baseURL: String = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
                maxFrames: Int = 200) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.maxFrames = maxFrames
    }

    public enum LiveError: Error, Equatable {
        case badURL
        case noResponse
        case transport(String)
    }

    // MARK: pure protocol (unit-pinned)

    /// The opening `setup` frame: which model + which output modalities.
    public static func setupMessage(model: String, modalities: [String] = ["TEXT"]) -> [String: Any] {
        ["setup": ["model": "models/\(model)", "generationConfig": ["responseModalities": modalities]]]
    }

    /// A user text turn with `turnComplete` so the server starts generating.
    public static func textTurnMessage(_ text: String) -> [String: Any] {
        ["clientContent": ["turns": [["role": "user", "parts": [["text": text]]]], "turnComplete": true]]
    }

    public static func isSetupComplete(_ json: [String: Any]) -> Bool {
        json["setupComplete"] != nil
    }

    public struct ServerChunk: Equatable, Sendable { public var text: String; public var turnComplete: Bool }

    /// Pull text + the turn-complete flag out of a `serverContent` frame.
    public static func parseServerContent(_ json: [String: Any]) -> ServerChunk? {
        guard let sc = json["serverContent"] as? [String: Any] else { return nil }
        var text = ""
        if let parts = (sc["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
            for p in parts { if let t = p["text"] as? String { text += t } }
        }
        let done = (sc["turnComplete"] as? Bool) == true
        return ServerChunk(text: text, turnComplete: done)
    }

    static func encode(_ message: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: message)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: live round-trip (PROTOTYPE — not unit-verified)

    /// Open a session, send `text`, accumulate the model's text until turnComplete, return it.
    public func ask(_ text: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)?key=\(apiKey)") else { throw LiveError.badURL }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        try await send(task, Self.setupMessage(model: model))
        var sentTurn = false
        var answer = ""
        for _ in 0..<maxFrames {
            let json = try await receiveJSON(task)
            if Self.isSetupComplete(json), !sentTurn {
                try await send(task, Self.textTurnMessage(text))
                sentTurn = true
                continue
            }
            if let chunk = Self.parseServerContent(json) {
                answer += chunk.text
                if chunk.turnComplete { return answer }
            }
        }
        guard !answer.isEmpty else { throw LiveError.noResponse }
        return answer
    }

    private func send(_ task: URLSessionWebSocketTask, _ message: [String: Any]) async throws {
        try await task.send(.string(try Self.encode(message)))
    }

    private func receiveJSON(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
        switch try await task.receive() {
        case .string(let s):
            return (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
        case .data(let d):
            return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        @unknown default:
            return [:]
        }
    }
}
