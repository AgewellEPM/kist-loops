import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native Gemini video generation — Veo. Veo is a LONG-RUNNING operation: submit a prompt
/// (`:predictLongRunning`) → get an operation name → poll until done → download the resulting MP4.
/// PROTOTYPE: Veo is a preview API whose response shape may shift; parsing is best-effort + defensive,
/// and the pure parsers are unit-pinned. Network injectable so tests never spend.
public struct GeminiVideoClient: Sendable {
    private let apiKey: String
    private let transport: HTTPTransport
    private let baseURL: String
    private let model: String
    private let maxPolls: Int
    private let pollSeconds: Double

    public static let defaultModel = "veo-3.1-generate-preview"

    public init(apiKey: String, model: String = defaultModel,
                transport: HTTPTransport = URLSessionTransport(),
                baseURL: String = "https://generativelanguage.googleapis.com/v1beta",
                maxPolls: Int = 60, pollSeconds: Double = 10) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.baseURL = baseURL
        self.maxPolls = maxPolls
        self.pollSeconds = pollSeconds
    }

    public enum VideoError: Error, Equatable {
        case badURL
        case http(Int, String)
        case badResponse(String)
        case timedOut
    }

    public func generate(prompt: String, aspectRatio: String = "16:9") async throws -> Data {
        let op = try await submit(prompt: prompt, aspectRatio: aspectRatio)
        for _ in 0..<maxPolls {
            if let uri = try await poll(operation: op) { return try await download(uri: uri) }
            try await Task.sleep(nanoseconds: UInt64(max(0, pollSeconds) * 1_000_000_000))
        }
        throw VideoError.timedOut
    }

    private func submit(prompt: String, aspectRatio: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/models/\(model):predictLongRunning?key=\(apiKey)") else { throw VideoError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "instances": [["prompt": prompt]],
            "parameters": ["aspectRatio": aspectRatio],
        ])
        let (body, response) = try await transport.send(req)
        guard (200..<300).contains(response.statusCode) else {
            throw VideoError.http(response.statusCode, String((String(data: body, encoding: .utf8) ?? "").prefix(800)))
        }
        return try Self.operationName(from: body)
    }

    /// One poll. Returns the video URI when done, nil while still running.
    private func poll(operation: String) async throws -> String? {
        guard let url = URL(string: "\(baseURL)/\(operation)?key=\(apiKey)") else { throw VideoError.badURL }
        let (body, response) = try await transport.send(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw VideoError.http(response.statusCode, String((String(data: body, encoding: .utf8) ?? "").prefix(400)))
        }
        guard Self.isDone(from: body) else { return nil }
        return try Self.videoURI(from: body)
    }

    private func download(uri: String) async throws -> Data {
        let sep = uri.contains("?") ? "&" : "?"
        guard let url = URL(string: "\(uri)\(sep)key=\(apiKey)") else { throw VideoError.badURL }
        let (bytes, response) = try await transport.send(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw VideoError.http(response.statusCode, "video download failed")
        }
        guard !bytes.isEmpty else { throw VideoError.badResponse("empty video download") }
        return bytes
    }

    // MARK: pure parsers (unit-pinned)

    static func operationName(from body: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = root["name"] as? String, !name.isEmpty else {
            throw VideoError.badResponse("missing operation name")
        }
        return name
    }

    static func isDone(from body: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return (root["done"] as? Bool) == true
    }

    /// Dig the MP4 URI out of `response.generateVideoResponse.generatedSamples[0].video.uri`, tolerant
    /// of the alternate `response.predictions[0].video.uri` shape.
    static func videoURI(from body: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let response = root["response"] as? [String: Any] else {
            throw VideoError.badResponse("operation has no response")
        }
        let samples = (response["generateVideoResponse"] as? [String: Any])?["generatedSamples"] as? [[String: Any]]
            ?? response["predictions"] as? [[String: Any]]
        if let video = samples?.first?["video"] as? [String: Any], let uri = video["uri"] as? String, !uri.isEmpty {
            return uri
        }
        throw VideoError.badResponse("response had no video uri")
    }
}
