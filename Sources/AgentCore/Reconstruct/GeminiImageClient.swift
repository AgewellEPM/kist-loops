import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux: URLSession lives here
#endif

/// The production backend for `GeminiVisualComparator`: base64-encodes the reference + rendered screenshots
/// and POSTs them to Gemini's OpenAI-compatible vision endpoint, returning the model's text. This is the
/// wired version of the path validated live (identical images → SIMILARITY 100, different → 0 + a diff).
///
/// The HTTP transport is injectable so the payload construction + response extraction are unit-tested
/// without a network; the default transport uses URLSession. Fail-soft: any error (unreadable image,
/// transport failure, unparseable response) returns nil, which the comparator reads as a FAILED comparison
/// (never a match) — the fail-closed fidelity guarantee holds end to end.
public struct GeminiImageClient: Sendable {
    public typealias Transport = @Sendable (_ url: URL, _ headers: [String: String], _ body: Data) async throws -> Data

    public let apiKey: String
    public let model: String
    public let endpoint: URL
    private let transport: Transport

    public init(apiKey: String,
                model: String = "gemini-2.5-flash",
                endpoint: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!,
                transport: @escaping Transport = GeminiImageClient.urlSessionTransport) {
        self.apiKey = apiKey; self.model = model; self.endpoint = endpoint; self.transport = transport
    }

    /// The closure shape `GeminiVisualComparator` wants. Wire with:
    ///   GeminiVisualComparator(compareImages: client.compareImages)
    public var compareImages: GeminiVisualComparator.CompareImages {
        { ref, rendered, prompt in await self.send(referencePath: ref, renderedPath: rendered, prompt: prompt) }
    }

    func send(referencePath: String, renderedPath: String, prompt: String) async -> String? {
        guard let body = try? Self.payload(model: model, prompt: prompt,
                                           referencePath: referencePath, renderedPath: renderedPath) else { return nil }
        let headers = ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json"]
        guard let data = try? await transport(endpoint, headers, body) else { return nil }
        return Self.extractContent(data)
    }

    // MARK: - payload / parsing (pure, tested)

    static func payload(model: String, prompt: String, referencePath: String, renderedPath: String) throws -> Data {
        let refURL = try dataURL(referencePath)
        let renURL = try dataURL(renderedPath)
        let msg: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": refURL]],
                    ["type": "image_url", "image_url": ["url": renURL]],
                ]
            ]]
        ]
        return try JSONSerialization.data(withJSONObject: msg)
    }

    /// Read an image file and return a `data:image/<mime>;base64,…` URL. Throws if the file can't be read.
    static func dataURL(_ path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return "data:\(mime(forPath: path));base64," + data.base64EncodedString()
    }

    static func mime(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// Pull `choices[0].message.content` (string) from an OpenAI-compatible response. nil on any mismatch.
    static func extractContent(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    /// Default transport. Throws on non-2xx so callers fail-soft to nil.
    @Sendable public static func urlSessionTransport(url: URL, headers: [String: String], body: Data) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "GeminiImageClient", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "http \(http.statusCode)"])
        }
        return data
    }
}
