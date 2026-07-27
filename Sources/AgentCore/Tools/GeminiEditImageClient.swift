import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native Gemini image generation — "Nano Banana" (`gemini-*-image` models). A one-shot
/// `generateContent` call with `responseModalities:["TEXT","IMAGE"]`; the response carries the image
/// as an `inlineData` part (base64). Network is injectable so `generate_image` tests never spend.
public struct GeminiEditImageClient: Sendable {
    private let apiKey: String
    private let transport: HTTPTransport
    private let baseURL: String

    public static let defaultModel = "gemini-2.5-flash-image"

    public init(apiKey: String,
                transport: HTTPTransport = URLSessionTransport(),
                baseURL: String = "https://generativelanguage.googleapis.com/v1beta/models") {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    public enum ImageError: Error, Equatable {
        case badURL
        case http(Int, String)
        case badResponse(String)
    }

    public func generate(prompt: String, model: String = defaultModel) async throws -> Data {
        try await run(parts: [["text": prompt]], model: model)
    }

    /// Edit an existing image: the input image is sent alongside the instruction; the model returns
    /// the edited result as a new inline image.
    public func edit(prompt: String, imageData: Data, mimeType: String, model: String = defaultModel) async throws -> Data {
        let parts: [[String: Any]] = [
            ["text": prompt],
            ["inline_data": ["mime_type": mimeType, "data": imageData.base64EncodedString()]],
        ]
        return try await run(parts: parts, model: model)
    }

    private func run(parts: [[String: Any]], model: String) async throws -> Data {
        guard let url = URL(string: "\(baseURL)/\(model):generateContent?key=\(apiKey)") else { throw ImageError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": parts]],
            "generationConfig": ["responseModalities": ["TEXT", "IMAGE"]],
        ])
        let (body, response) = try await transport.send(req)
        guard (200..<300).contains(response.statusCode) else {
            let text = String(data: body, encoding: .utf8) ?? ""
            throw ImageError.http(response.statusCode, String(text.prefix(800)))
        }
        return try Self.imageData(from: body)
    }

    /// Pull the first inline image out of `candidates[0].content.parts[]` (snake or camel case).
    static func imageData(from body: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw ImageError.badResponse("missing candidates[0].content.parts")
        }
        for part in parts {
            let inline = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any])
            if let inline, let b64 = inline["data"] as? String, let bytes = Data(base64Encoded: b64), !bytes.isEmpty {
                return bytes
            }
        }
        throw ImageError.badResponse("response had no inline image part")
    }
}
