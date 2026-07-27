import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streamable-HTTP transport for a remote MCP server: JSON-RPC 2.0 over HTTP POST. Handshake is
/// `initialize` → capture the `Mcp-Session-Id` response header → `notifications/initialized`;
/// `tools/list` and `tools/call` are plain POSTs. Responses are accepted as either `application/json`
/// (single JSON-RPC object) or `text/event-stream` (SSE — the reply is the event whose id matches).
///
/// SECURITY (Codex-hardened):
///   • SSRF is re-checked at REQUEST time (host re-resolved to IPs and matched against the private/
///     link-local/CGNAT/reserved blocklist) — not just at config time — so DNS rebinding can't point an
///     authenticated request at an internal host. Redirects are refused (a 30x can't be followed).
///   • Cleartext http with auth headers is refused at config validation; auth headers ride only on the
///     configured (https) endpoint.
///   • The response body is streamed with a hard byte cap + a resource timeout, so a hostile server can't
///     exhaust memory or hang the actor.
///   • Remote error/text is sanitized before it reaches logs or the model.
/// No interactive OAuth flow yet — static bearer/token headers only.
actor MCPHTTPConnection: MCPConnection {
    let config: MCPServerConfig
    private let endpoint: URL
    private let session: URLSession
    private var sessionId: String?
    private var idCounter = 0
    private var didShutdown = false
    private let timeout: TimeInterval
    /// The config explicitly named a loopback host (a user's own local server) — so request-time SSRF
    /// re-resolution is skipped for it (loopback is expected here; rebinding only matters for public hosts).
    private let allowLoopback: Bool

    static let maxResponseBytes = 10 * 1024 * 1024   // 10 MB cap on any single response body

    /// Optional OAuth bearer source: returns the CURRENT access token (refreshing if needed) before each
    /// request. When set, it supplies `Authorization: Bearer <token>` (over any static header). Injected by
    /// the manager for OAuth-authenticated servers; nil for static-token / no-auth servers.
    private let bearerProvider: (@Sendable () async -> String?)?

    var isAlive: Bool { !didShutdown }

    init(config: MCPServerConfig, timeout: TimeInterval = 30, bearerProvider: (@Sendable () async -> String?)? = nil) {
        self.config = config
        self.endpoint = URL(string: config.url ?? "")!
        self.timeout = timeout
        self.bearerProvider = bearerProvider
        self.allowLoopback = MCPClientConfig.isLoopbackHost(URL(string: config.url ?? "")?.host ?? "")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2     // bound a slow/silent server (Codex BLOCKER)
        cfg.httpShouldSetCookies = false
        self.session = URLSession(configuration: cfg, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func start() async throws {
        let params: [String: Any] = [
            "protocolVersion": "2025-03-26",
            "capabilities": [:],
            "clientInfo": ["name": "kist", "version": "1.0"],
        ]
        _ = try await request(method: "initialize", params: params, expectResponse: true)
        _ = try? await request(method: "notifications/initialized", params: [:], expectResponse: false)
    }

    func listTools() async throws -> [RemoteToolSpec] {
        let result = try await request(method: "tools/list", params: [:], expectResponse: true)
        guard let tools = result["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            return RemoteToolSpec(name: name,
                                  description: (t["description"] as? String) ?? "",
                                  inputSchema: (t["inputSchema"] as? [String: Any]) ?? [:])
        }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await request(method: "tools/call", params: ["name": name, "arguments": arguments], expectResponse: true)
    }

    func shutdown() async {
        guard !didShutdown else { return }
        didShutdown = true
        // The DELETE carries the session id + auth headers — apply the SAME request-time SSRF guard as
        // request() so a rebinding between the last call and shutdown can't send them to an internal host
        // (MiMo MED-2). Skip only for an explicit-loopback config (the user's own local server).
        let rebindingRisk = !allowLoopback && (endpoint.host.map { WebFetchTool.ssrfBlockReason(host: $0) != nil } ?? false)
        if let sessionId, !rebindingRisk {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "DELETE"
            req.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
            applyAuthHeaders(&req, bearer: await bearerProvider?())   // OAuth-authed servers need the bearer here too (MiMo)
            _ = try? await boundedData(for: req)   // bounded (not data(for:)) so a hostile close can't OOM
        }
        session.invalidateAndCancel()
    }

    // MARK: - JSON-RPC over HTTP

    private func request(method: String, params: [String: Any], expectResponse: Bool) async throws -> [String: Any] {
        if didShutdown { throw MCPConnectionError.alreadyShuttingDown }
        // SSRF re-check at request time: ssrfBlockReason() runs getaddrinfo() and inspects EVERY resolved
        // IP against the private/link-local/reserved blocklist — so a public host that has rebound to an
        // internal IP is refused here (a residual TOCTOU vs URLSession's own resolve remains, the standard
        // limit without connecting to a pinned IP). Redirects are separately blocked (NoRedirectDelegate).
        if !allowLoopback, let host = endpoint.host, let reason = WebFetchTool.ssrfBlockReason(host: host) {
            throw MCPConnectionError.badResponse("refused (SSRF guard): \(reason)")
        }

        idCounter += 1
        let id = idCounter
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if expectResponse { body["id"] = id }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionId { req.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        let bearer = await bearerProvider?()
        applyAuthHeaders(&req, bearer: bearer)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await boundedData(for: req)
        // Capture the session id ONCE (from initialize) — a later response can't overwrite/hijack it.
        if sessionId == nil,
           let sid = (http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? http.value(forHTTPHeaderField: "mcp-session-id")),
           !sid.isEmpty {
            sessionId = sid
        }
        guard (200...299).contains(http.statusCode) else {
            // A non-2xx body is server-controlled and could ECHO our Authorization value back — redact our
            // own static header values AND the dynamic OAuth bearer before it's sanitized and surfaced.
            let body = redactSecrets(String(decoding: data.prefix(300), as: UTF8.self), bearer: bearer)
            throw MCPConnectionError.rpcError(code: http.statusCode, message: "HTTP \(http.statusCode): \(MCPOutputSanitizer.sanitize(body))")
        }
        if !expectResponse { return [:] }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let message: [String: Any]
        if contentType.contains("text/event-stream") {
            guard let m = Self.matchingSSEMessage(data, id: id) else {
                throw MCPConnectionError.badResponse("no JSON-RPC message for id \(id) in event stream")
            }
            message = m
        } else {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPConnectionError.badResponse("response is not a JSON object")
            }
            message = obj
        }
        if let err = message["error"] as? [String: Any] {
            // A 2xx JSON-RPC error message is still server-controlled and could echo our bearer — redact
            // (static headers + bearer) BEFORE sanitizing (Codex).
            let raw = redactSecrets((err["message"] as? String) ?? "unknown error", bearer: bearer)
            throw MCPConnectionError.rpcError(code: (err["code"] as? Int) ?? -1, message: MCPOutputSanitizer.sanitize(raw))
        }
        return (message["result"] as? [String: Any]) ?? [:]
    }

    /// Stream the response body with a hard byte cap so a hostile server can't exhaust memory. Returns
    /// the (capped) body + the HTTP response. Aborts if the body exceeds `maxResponseBytes`.
    private func boundedData(for req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (byteStream, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            byteStream.task.cancel()
            throw MCPConnectionError.badResponse("no HTTP response")
        }
        var data = Data()
        data.reserveCapacity(64 * 1024)
        do {
            for try await b in byteStream {
                data.append(b)
                if data.count > Self.maxResponseBytes {
                    byteStream.task.cancel()
                    throw MCPConnectionError.badResponse("response exceeded \(Self.maxResponseBytes) bytes — refusing")
                }
            }
        } catch let e as MCPConnectionError {
            throw e
        } catch {
            throw MCPConnectionError.badResponse("read failed: \(error.localizedDescription)")
        }
        return (data, http)
    }

    private func applyAuthHeaders(_ req: inout URLRequest, bearer: String? = nil) {
        for (k, v) in config.headers { req.setValue(v, forHTTPHeaderField: k) }
        // An OAuth bearer (from bearerProvider) takes precedence over any static Authorization header.
        if let bearer, !bearer.isEmpty { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    }

    /// Replace our own configured header secret VALUES with [redacted] in server-controlled text, so a
    /// server that echoes back our Authorization/API-key value can't surface it into logs or the model.
    private func redactSecrets(_ s: String, bearer: String? = nil) -> String {
        var out = s
        // Redact any configured header value AND the dynamic OAuth bearer (len >= 4 — real tokens/keys are
        // longer; a lower floor would over-match 1-3 char substrings and mangle the error). Closes the
        // short-secret + bearer echo paths (Codex).
        var secrets = Array(config.headers.values)
        if let bearer { secrets.append(bearer) }
        for v in secrets where v.count >= 4 {
            out = out.replacingOccurrences(of: v, with: "[redacted]")
        }
        return out
    }

    /// Parse an SSE body and return the JSON-RPC message whose `id` matches. Accumulates `data:` lines
    /// per event (blank-line boundary), and matches the id as either an Int or a String (per JSON-RPC).
    static func matchingSSEMessage(_ data: Data, id: Int) -> [String: Any]? {
        let text = String(decoding: data, as: UTF8.self)
        for eventBlock in text.components(separatedBy: "\n\n") {
            var dataLines: [String] = []
            for rawLine in eventBlock.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
                if line.hasPrefix("data:") { dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)) }
            }
            let joined = dataLines.joined(separator: "\n")
            guard !joined.isEmpty, let d = joined.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if (obj["id"] as? Int) == id || (obj["id"] as? String) == String(id) { return obj }
        }
        return nil
    }
}

/// Refuse HTTP redirects — a 30x to an internal host must not be followed, and auth headers must not
/// leak to a redirect target (SSRF defense-in-depth on top of the config- and request-time host guards).
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
