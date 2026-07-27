import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OAuth 2.1 (authorization-code + PKCE) for remote MCP servers that require it — the interactive
/// alternative to a static bearer token. The security-critical pieces (PKCE, the authorization URL, the
/// token exchange/refresh) live here as small, testable units; the browser + loopback-callback glue and
/// token persistence are separate. Same network discipline as the HTTP transport: token/metadata calls
/// require https (except loopback) and are SSRF-guarded.
public enum MCPOAuth {

    /// A URLSession that REFUSES HTTP redirects — an OAuth metadata/registration/token call must NEVER
    /// follow a 30x (a malicious endpoint could redirect the authorization code / refresh token to a
    /// cleartext or internal host). This is the default session for all OAuth HTTP below (Codex HIGH).
    public static let secureSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg, delegate: OAuthNoRedirectDelegate(), delegateQueue: nil)
    }()

    // MARK: - PKCE (RFC 7636, S256)

    /// A high-entropy code verifier: 32 CSPRNG bytes → base64url (43 chars, within the RFC's 43–128).
    /// Uses SystemRandomNumberGenerator EXPLICITLY (documented cryptographically secure on every Swift
    /// platform — arc4random on Darwin, getrandom on Linux) rather than relying on the default generator
    /// being CSPRNG, since PKCE verifiers + OAuth state require crypto entropy (RFC 7636 §4.1; MiMo).
    public static func generateCodeVerifier() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<bytes.count { bytes[i] = rng.next() }
        return base64url(Data(bytes))
    }

    /// S256 challenge = base64url(SHA256(verifier)).
    public static func codeChallenge(for verifier: String) -> String {
        base64url(MythosCrypto.sha256(Data(verifier.utf8)))
    }

    /// base64url without padding (RFC 4648 §5): +/ → -_, strip '='.
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Authorization Server Metadata (RFC 8414)

    public struct Metadata: Sendable, Equatable {
        public let authorizationEndpoint: URL
        public let tokenEndpoint: URL
        public let registrationEndpoint: URL?
    }

    /// Parse the JSON metadata document. Endpoints must be https (or loopback) — a metadata doc can't
    /// point the flow at a cleartext or internal endpoint.
    public static func parseMetadata(_ data: Data) -> Metadata? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authStr = obj["authorization_endpoint"] as? String, let auth = secureURL(authStr),
              let tokenStr = obj["token_endpoint"] as? String, let token = secureURL(tokenStr) else { return nil }
        let reg = (obj["registration_endpoint"] as? String).flatMap(secureURL)
        return Metadata(authorizationEndpoint: auth, tokenEndpoint: token, registrationEndpoint: reg)
    }

    /// An https URL (or explicit loopback) whose host passes the SSRF guard — nil otherwise.
    public static func secureURL(_ s: String) -> URL? {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return nil }
        let loopback = MCPClientConfig.isLoopbackHost(host)
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        if !loopback, WebFetchTool.ssrfBlockReason(host: host) != nil { return nil }
        return url
    }

    // MARK: - Authorization request URL

    /// Build the browser authorization URL. `state` is CSRF protection (caller must verify it on callback).
    public static func authorizationURL(metadata: Metadata, clientID: String, redirectURI: String,
                                        scope: String?, state: String, codeChallenge: String) -> URL? {
        guard var comps = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else { return nil }
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
        comps.queryItems = (comps.queryItems ?? []) + items
        return comps.url
    }

    // MARK: - Token exchange / refresh

    public struct Token: Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresAt: Date?
        public var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }
        public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
            self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        }
    }

    /// Parse a token endpoint response body ({access_token, refresh_token, expires_in, ...}). `now` is
    /// injectable for deterministic expiry tests.
    public static func parseToken(_ data: Data, now: Date = Date()) -> Token? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, !access.isEmpty else { return nil }
        let expiresAt = (obj["expires_in"] as? Int).map { now.addingTimeInterval(TimeInterval($0)) }
        return Token(accessToken: access, refreshToken: obj["refresh_token"] as? String, expiresAt: expiresAt)
    }

    /// Exchange an authorization code for tokens (grant_type=authorization_code + PKCE verifier).
    public static func exchangeAuthorizationCode(tokenEndpoint: URL, code: String, codeVerifier: String,
                                                 clientID: String, redirectURI: String,
                                                 session: URLSession = MCPOAuth.secureSession) async throws -> Token {
        try await tokenRequest(tokenEndpoint: tokenEndpoint, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": clientID, "code_verifier": codeVerifier,
        ], session: session)
    }

    /// Refresh an access token (grant_type=refresh_token).
    public static func refreshToken(tokenEndpoint: URL, refreshToken: String, clientID: String,
                                    session: URLSession = MCPOAuth.secureSession) async throws -> Token {
        try await tokenRequest(tokenEndpoint: tokenEndpoint, form: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID,
        ], session: session)
    }

    private static func tokenRequest(tokenEndpoint: URL, form: [String: String], session: URLSession) async throws -> Token {
        // Re-guard the endpoint at call time (https-or-loopback + SSRF) — never send a code/refresh token
        // to a cleartext or internal host.
        guard secureURL(tokenEndpoint.absoluteString) != nil else {
            throw MCPConnectionError.badResponse("token endpoint refused (must be https/loopback, non-internal)")
        }
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = form.map { "\(formEncode($0.key))=\(formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MCPConnectionError.rpcError(code: code, message: "token endpoint HTTP \(code)")
        }
        guard let token = parseToken(data) else { throw MCPConnectionError.badResponse("token response missing access_token") }
        return token
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Refuse HTTP redirects for OAuth calls — never resend an authorization code / refresh token to a
/// redirect target (which could be cleartext or internal).
private final class OAuthNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
