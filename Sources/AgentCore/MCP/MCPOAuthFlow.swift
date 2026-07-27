import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Orchestrates the one-time interactive OAuth authorize for a remote MCP server: discover metadata →
/// (dynamic client registration if needed) → PKCE + state → open the browser → catch the loopback
/// redirect → verify state → exchange the code → persist the token. Called by a `kist mcp auth <server>`
/// entry point. The browser-open and metadata/registration/token HTTP calls all go through the same
/// https-or-loopback + SSRF discipline as the transport.
public enum MCPOAuthFlow {

    public enum FlowError: Error, LocalizedError {
        case metadataUnavailable, registrationFailed(String), stateMismatch, noCode(String), notInteractive
        public var errorDescription: String? {
            switch self {
            case .metadataUnavailable: return "could not fetch/parse the OAuth authorization-server metadata"
            case .registrationFailed(let m): return "dynamic client registration failed: \(m)"
            case .stateMismatch: return "OAuth state mismatch (possible CSRF) — aborted"
            case .noCode(let m): return "no authorization code returned: \(m)"
            case .notInteractive: return "OAuth authorize needs a loopback listener (unavailable on this platform)"
            }
        }
    }

    /// Fetch + parse RFC 8414 metadata from a discovery URL (typically `<issuer>/.well-known/oauth-authorization-server`).
    public static func discoverMetadata(_ url: URL, session: URLSession = MCPOAuth.secureSession) async throws -> MCPOAuth.Metadata {
        guard MCPOAuth.secureURL(url.absoluteString) != nil else { throw FlowError.metadataUnavailable }
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let m = MCPOAuth.parseMetadata(data) else { throw FlowError.metadataUnavailable }
        return m
    }

    /// Dynamic client registration (RFC 7591): POST the redirect_uri, get a client_id. Used when the user
    /// has no pre-registered client id.
    public static func registerClient(registrationEndpoint: URL, redirectURI: String, session: URLSession = MCPOAuth.secureSession) async throws -> String {
        guard MCPOAuth.secureURL(registrationEndpoint.absoluteString) != nil else { throw FlowError.registrationFailed("insecure registration endpoint") }
        var req = URLRequest(url: registrationEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "redirect_uris": [redirectURI],
            "token_endpoint_auth_method": "none",       // public client (PKCE)
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "client_name": "kist",
        ])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cid = obj["client_id"] as? String, !cid.isEmpty else {
            throw FlowError.registrationFailed("no client_id in response")
        }
        return cid
    }

    /// Run the full interactive authorize and store the token for `serverName`. `clientID` may be nil to
    /// trigger dynamic registration. `openBrowser` is injectable for testing (defaults to the OS opener).
    public static func authorize(serverName: String, metadata: MCPOAuth.Metadata, clientID providedID: String?,
                                 scope: String?, store: OAuthTokenStore,
                                 openBrowser: (URL) -> Void = defaultOpenBrowser) async throws {
        #if canImport(Darwin) || canImport(Glibc)
        let (port, fd) = try OAuthCallbackServer.bind()
        defer { close(fd) }   // own the listener fd — closed on EVERY path incl. registration/exchange throws (DeepSeek)
        let redirectURI = "http://127.0.0.1:\(port)/cb"
        let clientID: String
        if let providedID, !providedID.isEmpty {
            clientID = providedID
        } else if let reg = metadata.registrationEndpoint {
            clientID = try await registerClient(registrationEndpoint: reg, redirectURI: redirectURI)
        } else {
            throw FlowError.registrationFailed("no client_id and no registration endpoint")
        }

        let verifier = MCPOAuth.generateCodeVerifier()
        let challenge = MCPOAuth.codeChallenge(for: verifier)
        let state = MCPOAuth.generateCodeVerifier()   // reuse the CSPRNG for a high-entropy state
        guard let authURL = MCPOAuth.authorizationURL(metadata: metadata, clientID: clientID, redirectURI: redirectURI,
                                                      scope: scope, state: state, codeChallenge: challenge) else {
            throw FlowError.metadataUnavailable
        }
        openBrowser(authURL)
        let cb = await OAuthCallbackServer.waitForCallback(fd: fd)
        guard cb.state == state else { throw FlowError.stateMismatch }        // CSRF check
        guard let code = cb.code, cb.error == nil else { throw FlowError.noCode(cb.error ?? "no code") }

        let token = try await MCPOAuth.exchangeAuthorizationCode(tokenEndpoint: metadata.tokenEndpoint, code: code,
                                                                 codeVerifier: verifier, clientID: clientID, redirectURI: redirectURI)
        await store.set(token, tokenEndpoint: metadata.tokenEndpoint, clientID: clientID, for: serverName)
        #else
        throw FlowError.notInteractive
        #endif
    }

    /// Open a URL in the user's browser (macOS `open`, Linux `xdg-open`).
    public static func defaultOpenBrowser(_ url: URL) {
        #if canImport(Darwin) || canImport(Glibc)
        let opener = FileManager.default.isExecutableFile(atPath: "/usr/bin/open") ? "/usr/bin/open" : "/usr/bin/xdg-open"
        let p = Process(); p.executableURL = URL(fileURLWithPath: opener); p.arguments = [url.absoluteString]
        try? p.run()
        #endif
    }
}
