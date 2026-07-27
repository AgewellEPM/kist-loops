import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Google Cloud Translation v3 `translateDocument` — the ONLY path that returns a RE-RENDERED file
/// with the original layout preserved (PDF→PDF, DOCX→DOCX, PPTX, XLSX). Unlike the Gemini key, this
/// uses a GCP OAuth2 access token + project id (service account). The caller supplies the token
/// (e.g. `gcloud auth print-access-token`); we never sign JWTs here.
public struct CloudTranslationClient: Sendable {
    private let accessToken: String
    private let projectId: String
    private let location: String
    private let transport: HTTPTransport
    private let baseURL: String

    public init(accessToken: String, projectId: String, location: String = "global",
                transport: HTTPTransport = URLSessionTransport(),
                baseURL: String = "https://translation.googleapis.com/v3") {
        self.accessToken = accessToken
        self.projectId = projectId
        self.location = location
        self.transport = transport
        self.baseURL = baseURL
    }

    public enum TranslateError: Error, Equatable {
        case badURL
        case http(Int, String)
        case badResponse(String)
    }

    public struct Translated: Sendable, Equatable { public var bytes: Data; public var mimeType: String }

    public func translateDocument(data: Data, mimeType: String, targetLanguage: String,
                                  sourceLanguage: String? = nil) async throws -> Translated {
        guard let url = URL(string: "\(baseURL)/projects/\(projectId)/locations/\(location):translateDocument") else { throw TranslateError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "target_language_code": targetLanguage,
            "document_input_config": ["content": data.base64EncodedString(), "mime_type": mimeType],
        ]
        if let sourceLanguage { payload["source_language_code"] = sourceLanguage }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (body, response) = try await transport.send(req)
        guard (200..<300).contains(response.statusCode) else {
            throw TranslateError.http(response.statusCode, String((String(data: body, encoding: .utf8) ?? "").prefix(800)))
        }
        return try Self.parse(body, fallbackMime: mimeType)
    }

    /// Pull the re-rendered file out of `documentTranslation.byteStreamOutputs[0]` (base64).
    static func parse(_ body: Data, fallbackMime: String) throws -> Translated {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let dt = root["documentTranslation"] as? [String: Any] else {
            throw TranslateError.badResponse("missing documentTranslation")
        }
        let outputs = (dt["byteStreamOutputs"] as? [String]) ?? (dt["byte_stream_outputs"] as? [String]) ?? []
        guard let b64 = outputs.first, let bytes = Data(base64Encoded: b64), !bytes.isEmpty else {
            throw TranslateError.badResponse("no translated document bytes")
        }
        let mime = (dt["mimeType"] as? String) ?? (dt["mime_type"] as? String) ?? fallbackMime
        return Translated(bytes: bytes, mimeType: mime)
    }

    /// Cloud Translation v3 document mime types we accept by extension.
    public static func mimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "pdf":  return "application/pdf"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        default:     return nil
        }
    }
}
