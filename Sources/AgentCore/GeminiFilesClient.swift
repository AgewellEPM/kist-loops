import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A minimal HTTP seam so the Files-API state machine is testable without a network. Returns the
/// body + the response (status + headers).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Default transport over URLSession.
public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.transport("non-HTTP response")
        }
        return (data, http)
    }
}

/// Uploads media to the Gemini Files API and returns a `fileUri` usable as a `file_data` part —
/// the path for video, audio, and any file too big to inline. The flow (per Google's docs):
///   1. start a resumable upload  → response carries the upload URL header
///   2. upload + finalize the bytes → response carries the File (uri, name, state)
///   3. poll the File until `state == ACTIVE` (video/audio is processed server-side)
///
/// Files live ~48h server-side and are scoped to the key's project. Network + sleep are injected so
/// the whole state machine runs deterministically under test.
public struct GeminiFilesClient: Sendable {
    private let apiKey: String
    private let transport: HTTPTransport
    private let base: String
    private let pollIntervalNanos: UInt64
    private let maxPolls: Int
    private let sleep: @Sendable (UInt64) async -> Void

    public init(apiKey: String,
                transport: HTTPTransport = URLSessionTransport(),
                base: String = "https://generativelanguage.googleapis.com",
                pollIntervalNanos: UInt64 = 1_000_000_000,
                maxPolls: Int = 60,
                sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }) {
        self.apiKey = apiKey
        self.transport = transport
        self.base = base
        self.pollIntervalNanos = pollIntervalNanos
        self.maxPolls = maxPolls
        self.sleep = sleep
    }

    public struct RemoteFile: Sendable, Equatable { public let uri: String; public let name: String; public let state: String }

    public enum FilesError: Error, Equatable { case noUploadURL, badResponse(String), processingFailed, timedOut }

    /// Upload `data` and return its `fileUri` once the file is ACTIVE.
    public func upload(data: Data, mimeType: String, displayName: String) async throws -> String {
        let uploadURL = try await startResumable(byteCount: data.count, mimeType: mimeType, displayName: displayName)
        var file = try await finalize(uploadURL: uploadURL, data: data)
        var polls = 0
        while file.state != "ACTIVE" {
            if file.state == "FAILED" { throw FilesError.processingFailed }
            if polls >= maxPolls { throw FilesError.timedOut }
            await sleep(pollIntervalNanos)
            polls += 1
            file = try await fetch(name: file.name)
        }
        return file.uri
    }

    /// Delete an uploaded file so it doesn't linger (Files API quota / 48h retention). Accepts the
    /// uri returned by `upload` (or a "files/<id>" name); best-effort, ignores not-found.
    public func delete(uri: String) async throws {
        guard let r = uri.range(of: "files/") else { return }
        let name = String(uri[r.lowerBound...]).split(separator: "?").first.map(String.init) ?? ""
        guard !name.isEmpty, let url = URL(string: "\(base)/v1beta/\(name)?key=\(apiKey)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await transport.send(req)
    }

    // MARK: steps

    private func startResumable(byteCount: Int, mimeType: String, displayName: String) async throws -> String {
        var req = URLRequest(url: URL(string: "\(base)/upload/v1beta/files?key=\(apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        req.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        req.setValue(String(byteCount), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        req.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": displayName]])
        let (_, resp) = try await transport.send(req)
        // The header name varies in case across stacks; scan case-insensitively.
        guard let url = headerValue(resp, "X-Goog-Upload-URL"), !url.isEmpty else { throw FilesError.noUploadURL }
        return url
    }

    private func finalize(uploadURL: String, data: Data) async throws -> RemoteFile {
        var req = URLRequest(url: URL(string: uploadURL)!)
        req.httpMethod = "POST"
        req.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        req.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        req.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        req.httpBody = data
        let (body, _) = try await transport.send(req)
        return try Self.parseFile(body)
    }

    private func fetch(name: String) async throws -> RemoteFile {
        // `name` is like "files/abc123"; the GET is base/v1beta/<name>.
        var req = URLRequest(url: URL(string: "\(base)/v1beta/\(name)?key=\(apiKey)")!)
        req.httpMethod = "GET"
        let (body, _) = try await transport.send(req)
        return try Self.parseFile(body)
    }

    private func headerValue(_ resp: HTTPURLResponse, _ field: String) -> String? {
        if let v = resp.value(forHTTPHeaderField: field) { return v }
        for (k, v) in resp.allHeaderFields {
            if let ks = k as? String, ks.caseInsensitiveCompare(field) == .orderedSame { return v as? String }
        }
        return nil
    }

    /// Parse a `{"file": {...}}` or bare `{...}` File object. Exposed for tests.
    static func parseFile(_ data: Data) throws -> RemoteFile {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FilesError.badResponse("not JSON")
        }
        let file = (root["file"] as? [String: Any]) ?? root
        guard let uri = file["uri"] as? String, let name = file["name"] as? String else {
            throw FilesError.badResponse("missing uri/name")
        }
        let state = (file["state"] as? String) ?? "PROCESSING"
        return RemoteFile(uri: uri, name: name, state: state)
    }
}
