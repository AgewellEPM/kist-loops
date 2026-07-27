import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native Gemini text-to-speech. A one-shot `generateContent` with `responseModalities:["AUDIO"]` and a
/// `speechConfig` voice; the response carries raw PCM (16-bit, mono) as an `inlineData` part with the
/// sample rate in its mimeType (e.g. `audio/L16;codec=pcm;rate=24000`). We return PCM + rate; callers
/// wrap it in a WAV header to get a playable file. Network is injectable so tests never spend.
public struct GeminiTTSClient: Sendable {
    private let apiKey: String
    private let transport: HTTPTransport
    private let baseURL: String

    public static let defaultModel = "gemini-2.5-flash-preview-tts"
    public static let defaultVoice = "Kore"

    public init(apiKey: String,
                transport: HTTPTransport = URLSessionTransport(),
                baseURL: String = "https://generativelanguage.googleapis.com/v1beta/models") {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    public enum TTSError: Error, Equatable {
        case badURL
        case http(Int, String)
        case badResponse(String)
    }

    public struct PCM: Sendable, Equatable { public var data: Data; public var sampleRate: Int }

    public func synthesize(text: String, voice: String = defaultVoice, model: String = defaultModel) async throws -> PCM {
        guard let url = URL(string: "\(baseURL)/\(model):generateContent?key=\(apiKey)") else { throw TTSError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": text]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]],
            ],
        ])
        let (body, response) = try await transport.send(req)
        guard (200..<300).contains(response.statusCode) else {
            let t = String(data: body, encoding: .utf8) ?? ""
            throw TTSError.http(response.statusCode, String(t.prefix(800)))
        }
        return try Self.pcm(from: body)
    }

    /// Extract base64 PCM + sample rate from `candidates[0].content.parts[].inlineData`.
    static func pcm(from body: Data) throws -> PCM {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw TTSError.badResponse("missing candidates[0].content.parts")
        }
        for part in parts {
            let inline = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any])
            if let inline, let b64 = inline["data"] as? String, let bytes = Data(base64Encoded: b64), !bytes.isEmpty {
                let mime = (inline["mimeType"] as? String) ?? (inline["mime_type"] as? String) ?? ""
                return PCM(data: bytes, sampleRate: sampleRate(fromMime: mime))
            }
        }
        throw TTSError.badResponse("response had no inline audio part")
    }

    /// Parse `rate=24000` out of a PCM mimeType; default 24000 (Gemini TTS output rate).
    static func sampleRate(fromMime mime: String) -> Int {
        for token in mime.split(separator: ";") {
            let kv = token.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "rate",
               let n = Int(kv[1].trimmingCharacters(in: .whitespaces)), n > 0 { return n }
        }
        return 24000
    }

    /// Wrap raw 16-bit mono PCM in a 44-byte WAV header so the file plays anywhere.
    public static func wav(pcm: Data, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var h = Data()
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count); h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        h.append(contentsOf: Array("data".utf8)); u32(pcm.count)
        h.append(pcm)
        return h
    }
}
