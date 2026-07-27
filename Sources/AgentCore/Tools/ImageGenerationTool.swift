import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal OpenAI Images API client. Network is injectable so `generate_image` tests never spend.
public struct OpenAIImageClient: Sendable {
    private let apiKey: String
    private let transport: HTTPTransport
    private let baseURL: String

    public init(apiKey: String,
                transport: HTTPTransport = URLSessionTransport(),
                baseURL: String = "https://api.openai.com/v1/images/generations") {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    public enum ImageError: Error, Equatable {
        case badURL
        case http(Int, String)
        case badResponse(String)
        case badImageURL
    }

    public func generate(prompt: String, model: String = "gpt-image-1", size: String = "1024x1024") async throws -> Data {
        guard let url = URL(string: baseURL) else { throw ImageError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "size": size,
            "n": 1,
        ])
        let (body, response) = try await transport.send(req)
        guard (200..<300).contains(response.statusCode) else {
            let text = String(data: body, encoding: .utf8) ?? ""
            throw ImageError.http(response.statusCode, String(text.prefix(800)))
        }
        return try await Self.imageData(from: body, transport: transport)
    }

    static func imageData(from body: Data, transport: HTTPTransport) async throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = root["data"] as? [[String: Any]],
              let first = data.first else {
            throw ImageError.badResponse("missing data[0]")
        }
        if let b64 = first["b64_json"] as? String, let bytes = Data(base64Encoded: b64) {
            return bytes
        }
        if let urlString = first["url"] as? String, let url = URL(string: urlString) {
            let (bytes, response) = try await transport.send(URLRequest(url: url))
            guard (200..<300).contains(response.statusCode) else {
                throw ImageError.http(response.statusCode, "image URL download failed")
            }
            return bytes
        }
        throw ImageError.badResponse("missing b64_json/url")
    }
}

/// Agent tool: prompt -> image generation -> PNG file inside the project. Backed by Gemini's native
/// image model ("Nano Banana") when a Gemini key is present, else OpenAI images — same tool either way.
public struct GenerateImageTool: AgentTool {
    public let name = "generate_image"
    public let description = """
    Generate an image from a prompt using an image model and save it as a PNG in the project. Use when \
    the user asks to create artwork, UI mockups, illustrations, icons, textures, or concept images.
    """
    public let parameters = [
        ToolParameter(name: "prompt", type: "string", description: "Detailed image prompt to generate.", required: true),
        ToolParameter(name: "out", type: "string", description: "Project-relative PNG output path. Default: generated-images/<prompt-slug>.png", required: false),
        ToolParameter(name: "size", type: "string", description: "Image size (OpenAI only), e.g. 1024x1024, 1024x1536, 1536x1024. Default 1024x1024.", required: false),
        ToolParameter(name: "model", type: "string", description: "Override the image model id. Default depends on provider.", required: false),
    ]

    private let generate: @Sendable (_ prompt: String, _ model: String, _ size: String) async throws -> Data
    private let defaultModel: String

    /// Gemini "Nano Banana" native image generation (preferred when a Gemini key exists).
    public init(geminiKey: String) {
        let client = GeminiEditImageClient(apiKey: geminiKey)
        self.defaultModel = GeminiEditImageClient.defaultModel
        self.generate = { prompt, model, _ in try await client.generate(prompt: prompt, model: model) }
    }

    public init(apiKey: String) {
        let client = OpenAIImageClient(apiKey: apiKey)
        self.defaultModel = "gpt-image-1"
        self.generate = { prompt, model, size in try await client.generate(prompt: prompt, model: model, size: size) }
    }

    public init(defaultModel: String = "gpt-image-1",
                generate: @escaping @Sendable (_ prompt: String, _ model: String, _ size: String) async throws -> Data) {
        self.defaultModel = defaultModel
        self.generate = generate
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let prompt = try requireString("prompt", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .failure("prompt is empty") }
        let size = (arguments["size"] as? String) ?? "1024x1024"
        guard Self.allowedSizes.contains(size) else {
            return .failure("unsupported size '\(size)' (use \(Self.allowedSizes.sorted().joined(separator: ", ")))")
        }
        let model = (arguments["model"] as? String) ?? defaultModel
        let out = (arguments["out"] as? String) ?? "generated-images/\(Self.slug(prompt)).png"
        guard (out as NSString).pathExtension.lowercased() == "png" else {
            return .failure("out must end in .png")
        }
        let bytes = try await generate(prompt, model, size)
        guard !bytes.isEmpty else { return .failure("image generation returned no data") }
        // Symlink-safe atomic write inside the project root (was a raw FileManager write — the same
        // symlink-escape class Codex caught in translate_document; edit/audio/video were fixed, this wasn't).
        try context.confinedRoot().writeData(out, bytes, createParents: true)
        return ToolResult(success: true,
                          output: "generated image → \(out) (\(bytes.count) bytes)",
                          metadata: ["path": out, "bytes": String(bytes.count), "model": model, "size": size])
    }

    static let allowedSizes: Set<String> = ["1024x1024", "1024x1536", "1536x1024", "auto"]

    static func slug(_ prompt: String) -> String {
        let words = prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(8)
        let joined = words.joined(separator: "-")
        return joined.isEmpty ? "image" : String(joined.prefix(80))
    }
}
