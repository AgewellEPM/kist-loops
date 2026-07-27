import Foundation

/// Client for Moondream — a tiny, fast vision model used as the agent's cheap "eyes". Its killer feature
/// for the desktop hands is POINTING: given a screenshot and a target name ("the attack button"), it
/// returns coordinates, so the big decision model doesn't have to eyeball pixels. It also does VQA
/// (`query`) and `caption`.
///
/// Works against the Moondream Cloud API (default, needs a key) OR a LOCAL Moondream server (set
/// `MOONDREAM_BASE_URL`, e.g. http://localhost:2020/v1 — no key) — the always-on local-perception path.
/// Network is injectable (`HTTPTransport`) so tests never spend and never require a running model.
public struct MoondreamClient: Sendable {

    public enum MoondreamError: Error, LocalizedError, CustomStringConvertible, Equatable {
        case badURL
        case http(Int, String)
        case decode(String)
        public var description: String {
            switch self {
            case .badURL: return "invalid or disallowed Moondream endpoint URL (https anywhere; http only to loopback)"
            case .http(let code, let body): return "Moondream HTTP \(code): \(body.prefix(300))"
            case .decode(let m): return "Moondream response decode failed: \(m)"
            }
        }
        // ToolRegistry surfaces errors via localizedDescription, so mirror description there.
        public var errorDescription: String? { description }
    }

    /// A point in NORMALIZED [0,1] image coordinates, as Moondream returns them.
    public struct NormPoint: Sendable, Equatable { public let x: Double; public let y: Double }

    private let transport: HTTPTransport
    private let baseURL: String
    private let apiKey: String?

    public init(apiKey: String? = ProcessInfo.processInfo.environment["MOONDREAM_API_KEY"],
                baseURL: String = ProcessInfo.processInfo.environment["MOONDREAM_BASE_URL"] ?? "https://api.moondream.ai/v1",
                transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        // Trim a trailing slash so path joins are predictable.
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.transport = transport
    }

    /// Point at every instance of `object` in the image. Returns normalized points (possibly empty).
    public func point(imageData: Data, mime: String, object: String) async throws -> [NormPoint] {
        let data = try await post(path: "point", body: ["image_url": Self.dataURL(imageData, mime: mime), "object": object])
        return try Self.parsePoints(data)
    }

    /// Ask a free-form question about the image.
    public func query(imageData: Data, mime: String, question: String) async throws -> String {
        let data = try await post(path: "query", body: ["image_url": Self.dataURL(imageData, mime: mime), "question": question])
        return try Self.parseStringField(data, key: "answer")
    }

    /// Caption the image.
    public func caption(imageData: Data, mime: String, length: String = "normal") async throws -> String {
        let data = try await post(path: "caption", body: ["image_url": Self.dataURL(imageData, mime: mime), "length": length])
        return try Self.parseStringField(data, key: "caption")
    }

    // MARK: - Transport

    private func post(path: String, body: [String: Any]) async throws -> Data {
        let request = try Self.buildRequest(baseURL: baseURL, path: path, apiKey: apiKey, body: body)
        let (data, http) = try await transport.send(request)
        guard (200...299).contains(http.statusCode) else {
            throw MoondreamError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: - Pure, testable helpers

    static func buildRequest(baseURL: String, path: String, apiKey: String?, body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/\(path)"), let scheme = url.scheme?.lowercased(), let host = url.host else {
            throw MoondreamError.badURL
        }
        // Scheme guard: https to any host; plaintext http ONLY to loopback, so a misconfigured
        // MOONDREAM_BASE_URL can't ship screenshots (or the auth key) in the clear to a remote host.
        switch scheme {
        case "https": break
        case "http": guard isLoopback(host) else { throw MoondreamError.badURL }
        default: throw MoondreamError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Moondream-Auth") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]" || h.hasSuffix(".localhost")
    }

    static func dataURL(_ data: Data, mime: String) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// Parse `{"points":[{"x":0.5,"y":0.5}, ...]}`. Missing/empty points ⇒ empty array (not an error —
    /// "I don't see it" is a valid answer the caller handles).
    static func parsePoints(_ data: Data) throws -> [NormPoint] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MoondreamError.decode("not a JSON object")
        }
        // Absent `points` ⇒ "not visible" (empty). But a PRESENT-but-malformed `points` is a real
        // integration/model error, not "not found" — surface it instead of silently downgrading.
        guard obj["points"] != nil else { return [] }
        guard let raw = obj["points"] as? [[String: Any]] else { throw MoondreamError.decode("'points' is not an array of objects") }
        var out: [NormPoint] = []
        for p in raw {
            guard let x = numeric(p["x"]), let y = numeric(p["y"]) else {
                throw MoondreamError.decode("a point is missing finite x/y")
            }
            out.append(NormPoint(x: x, y: y))
        }
        return out
    }

    static func parseStringField(_ data: Data, key: String) throws -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MoondreamError.decode("not a JSON object")
        }
        guard let s = obj[key] as? String else { throw MoondreamError.decode("missing '\(key)'") }
        return s
    }

    /// Convert normalized [0,1] points to integer PIXEL coordinates for an image of `width`x`height`,
    /// clamped into range so a slightly-out-of-bounds normalized value never yields an off-image pixel.
    static func pixels(from points: [NormPoint], width: Int, height: Int) -> [(x: Int, y: Int)] {
        points.compactMap { p in
            guard p.x.isFinite, p.y.isFinite else { return nil }
            // Clamp the NORMALIZED value to [0,1] BEFORE scaling. A finite-but-huge value (1e20) would
            // otherwise overflow Int on conversion and trap; clamped first, nx*width is always in range.
            let nx = min(max(0.0, p.x), 1.0)
            let ny = min(max(0.0, p.y), 1.0)
            let x = min(Int((nx * Double(width)).rounded()), max(0, width - 1))
            let y = min(Int((ny * Double(height)).rounded()), max(0, height - 1))
            return (x, y)
        }
    }

    /// Coerce to a FINITE Double (rejects nan/inf/"1e309") so a downstream Int() conversion can't trap.
    /// Rejects JSON booleans up-front: `JSONSerialization` bridges true/false to an NSNumber that would
    /// otherwise cast through `as? Double`/`as? Int` as 1.0/0.0 — a malformed point, not a coordinate.
    private static func numeric(_ any: Any?) -> Double? {
        if let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let d: Double?
        if let v = any as? Double { d = v }
        else if let i = any as? Int { d = Double(i) }
        else if let s = any as? String { d = Double(s) }
        else { d = nil }
        guard let value = d, value.isFinite else { return nil }
        return value
    }
}
