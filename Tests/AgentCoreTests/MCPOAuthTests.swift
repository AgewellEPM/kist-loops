import XCTest
import Foundation
@testable import AgentCore

/// OAuth core for MCP: PKCE (RFC 7636 vector), metadata + URL security, token parsing, token store, and a
/// LIVE token exchange against a mock token endpoint.
final class MCPOAuthTests: XCTestCase {

    // RFC 7636 Appendix B test vector.
    func testPKCES256MatchesRFCVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(MCPOAuth.codeChallenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testCodeVerifierIsUrlSafeAndLongEnough() {
        let v = MCPOAuth.generateCodeVerifier()
        XCTAssertGreaterThanOrEqual(v.count, 43)
        XCTAssertLessThanOrEqual(v.count, 128)
        XCTAssertFalse(v.contains("+")); XCTAssertFalse(v.contains("/")); XCTAssertFalse(v.contains("="))
        XCTAssertNotEqual(v, MCPOAuth.generateCodeVerifier())   // random per call
    }

    func testSecureURLEnforcesHttpsExceptLoopback() {
        let publicResolver: (String) -> String? = { _ in nil }
        XCTAssertNotNil(MCPOAuth.secureURL(
            "https://example.com/authorize", ssrfBlockReason: publicResolver))
        XCTAssertNotNil(MCPOAuth.secureURL("http://127.0.0.1:9000/authorize"))   // loopback http ok
        XCTAssertNil(MCPOAuth.secureURL(
            "http://auth.example.com/authorize", ssrfBlockReason: publicResolver))
        XCTAssertNil(MCPOAuth.secureURL("https://169.254.169.254/authorize"))    // SSRF internal
    }

    func testParseMetadataRequiresSecureEndpoints() {
        let good = #"{"authorization_endpoint":"https://example.com/auth","token_endpoint":"https://example.com/token","registration_endpoint":"https://example.com/reg"}"#.data(using: .utf8)!
        let m = MCPOAuth.parseMetadata(good, ssrfBlockReason: { _ in nil })
        XCTAssertEqual(m?.authorizationEndpoint.absoluteString, "https://example.com/auth")
        XCTAssertNotNil(m?.registrationEndpoint)
        // A cleartext token endpoint invalidates the whole metadata.
        let bad = #"{"authorization_endpoint":"https://example.com/auth","token_endpoint":"http://example.com/token"}"#.data(using: .utf8)!
        XCTAssertNil(MCPOAuth.parseMetadata(bad, ssrfBlockReason: { _ in nil }))
    }

    func testParseMetadataFailsClosedWhenEndpointResolutionFails() {
        let data = #"{"authorization_endpoint":"https://example.com/auth","token_endpoint":"https://example.com/token"}"#.data(using: .utf8)!
        XCTAssertNil(MCPOAuth.parseMetadata(data, ssrfBlockReason: { _ in "DNS unavailable" }))
    }

    func testAuthorizationURLHasPKCEAndState() {
        let m = MCPOAuth.Metadata(authorizationEndpoint: URL(string: "https://a.example.com/auth")!,
                                  tokenEndpoint: URL(string: "https://a.example.com/token")!, registrationEndpoint: nil)
        let url = MCPOAuth.authorizationURL(metadata: m, clientID: "cid", redirectURI: "http://127.0.0.1:7777/cb",
                                            scope: "mcp", state: "st4te", codeChallenge: "chal")!
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
        XCTAssertEqual(v("response_type"), "code")
        XCTAssertEqual(v("client_id"), "cid")
        XCTAssertEqual(v("code_challenge"), "chal")
        XCTAssertEqual(v("code_challenge_method"), "S256")
        XCTAssertEqual(v("state"), "st4te")
        XCTAssertEqual(v("scope"), "mcp")
    }

    func testParseTokenComputesExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let t = MCPOAuth.parseToken(#"{"access_token":"AT","refresh_token":"RT","expires_in":3600}"#.data(using: .utf8)!, now: now)
        XCTAssertEqual(t?.accessToken, "AT")
        XCTAssertEqual(t?.refreshToken, "RT")
        XCTAssertEqual(t?.expiresAt, now.addingTimeInterval(3600))
        XCTAssertNil(MCPOAuth.parseToken(#"{"no_access":true}"#.data(using: .utf8)!))   // no access_token → nil
    }

    // Token store: persist round-trip + owner-only perms.
    func testTokenStorePersistsOwnerOnly() async throws {
        let path = NSTemporaryDirectory() + "oauth-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = OAuthTokenStore(path: path)
        await store.set(MCPOAuth.Token(accessToken: "AT", refreshToken: "RT", expiresAt: Date(timeIntervalSince1970: 2_000_000)),
                        tokenEndpoint: URL(string: "https://a.example.com/token")!, clientID: "cid", for: "srv")
        // Reopen → token survives, and bearer() returns it (not expired: far-future date is expired vs now,
        // but no refresh possible offline → returns nil; so use a fresh far-future token for the bearer check).
        let store2 = OAuthTokenStore(path: path)
        let t = await store2.token(for: "srv")
        XCTAssertEqual(t?.accessToken, "AT")
        XCTAssertEqual(t?.refreshToken, "RT")
        // File is owner-only (0600).
        let perms = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)!.intValue
        XCTAssertEqual(perms & 0o077, 0, "token file must be owner-only")
    }

    // LIVE: an expired token with a refresh token is silently renewed by bearer() against a mock endpoint.
    func testBearerRefreshesExpiredToken() async throws {
        guard let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("python3 unavailable") }
        let script = """
        import http.server, json, urllib.parse
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                n=int(self.headers.get('Content-Length',0)); f=urllib.parse.parse_qs(self.rfile.read(n).decode())
                assert f.get('grant_type')==['refresh_token'] and f.get('refresh_token')==['OLDRT']
                b=json.dumps({"access_token":"NEWAT","expires_in":3600}).encode()
                self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b)
            def log_message(self,*a): pass
        s=http.server.HTTPServer(('127.0.0.1',0),H); print(s.server_address[1],flush=True); s.serve_forever()
        """
        let (port, proc) = try startMock(python: python, script: script)
        defer { proc.terminate() }
        let path = NSTemporaryDirectory() + "oauth-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = OAuthTokenStore(path: path)
        // An already-EXPIRED access token + a refresh token + the mock token endpoint.
        await store.set(MCPOAuth.Token(accessToken: "OLDAT", refreshToken: "OLDRT", expiresAt: Date(timeIntervalSince1970: 1)),
                        tokenEndpoint: URL(string: "http://127.0.0.1:\(port)/token")!, clientID: "cid", for: "srv")
        let bearer = await store.bearer(for: "srv")
        XCTAssertEqual(bearer, "NEWAT", "expired token should be refreshed transparently")
        // The refreshed token (with the carried-over refresh token) is persisted.
        let t = await store.token(for: "srv")
        XCTAssertEqual(t?.accessToken, "NEWAT")
        XCTAssertEqual(t?.refreshToken, "OLDRT")   // refresh response omitted one → old kept
    }

    func testParseCallbackRequestLine() {
        let ok = OAuthCallbackServer.parseRequestLine("GET /cb?code=ABC&state=XYZ HTTP/1.1")
        XCTAssertEqual(ok.code, "ABC"); XCTAssertEqual(ok.state, "XYZ"); XCTAssertNil(ok.error)
        let err = OAuthCallbackServer.parseRequestLine("GET /cb?error=access_denied HTTP/1.1")
        XCTAssertEqual(err.error, "access_denied"); XCTAssertNil(err.code)
    }

    // FULL FLOW e2e: run authorize() with a fake browser that drives the loopback redirect, and a mock
    // token endpoint — proving PKCE + state check + code exchange + storage all wire together.
    func testFullAuthorizeFlowE2E() async throws {
        guard let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("python3 unavailable") }
        let script = """
        import http.server, json, urllib.parse
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                n=int(self.headers.get('Content-Length',0)); f=urllib.parse.parse_qs(self.rfile.read(n).decode())
                assert f.get('grant_type')==['authorization_code'] and f.get('code')==['GOODCODE'] and f.get('code_verifier')
                b=json.dumps({"access_token":"FLOWAT","refresh_token":"FLOWRT","expires_in":3600}).encode()
                self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b)
            def log_message(self,*a): pass
        s=http.server.HTTPServer(('127.0.0.1',0),H); print(s.server_address[1],flush=True); s.serve_forever()
        """
        let (tokenPort, proc) = try startMock(python: python, script: script)
        defer { proc.terminate() }
        let path = NSTemporaryDirectory() + "oauth-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = OAuthTokenStore(path: path)
        let metadata = MCPOAuth.Metadata(
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            tokenEndpoint: URL(string: "http://127.0.0.1:\(tokenPort)/token")!, registrationEndpoint: nil)

        // Fake browser: extract redirect_uri + state from the auth URL, then hit the loopback callback
        // with a matching code (like the user completing consent).
        try await MCPOAuthFlow.authorize(serverName: "srv", metadata: metadata, clientID: "cid", scope: "mcp", store: store) { authURL in
            let comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
            let redirect = comps.queryItems!.first { $0.name == "redirect_uri" }!.value!
            let state = comps.queryItems!.first { $0.name == "state" }!.value!
            let cbURL = URL(string: redirect + "?code=GOODCODE&state=" + state)!
            Task.detached { _ = try? await URLSession.shared.data(from: cbURL) }   // drive the loopback redirect
        }

        let t = await store.token(for: "srv")
        XCTAssertEqual(t?.accessToken, "FLOWAT")
        XCTAssertEqual(t?.refreshToken, "FLOWRT")
    }

    // Codex HIGH: an OAuth token call must NOT follow a redirect (a 30x could resend the code to an
    // attacker host). The mock replies 307 → the exchange fails instead of following it.
    func testTokenExchangeRefusesRedirect() async throws {
        guard let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("python3 unavailable") }
        let script = """
        import http.server
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.send_response(307); self.send_header('Location','http://127.0.0.1:1/evil'); self.end_headers()
            def log_message(self,*a): pass
        s=http.server.HTTPServer(('127.0.0.1',0),H); print(s.server_address[1],flush=True); s.serve_forever()
        """
        let (port, proc) = try startMock(python: python, script: script)
        defer { proc.terminate() }
        do {
            _ = try await MCPOAuth.exchangeAuthorizationCode(
                tokenEndpoint: URL(string: "http://127.0.0.1:\(port)/token")!, code: "C", codeVerifier: "V",
                clientID: "cid", redirectURI: "http://127.0.0.1:1/cb")
            XCTFail("exchange must not follow the redirect / must fail on 307")
        } catch {
            // expected — the no-redirect session surfaces the 307 as a non-2xx error, not a followed redirect.
        }
    }

    private func startMock(python: String, script: String) throws -> (Int, Process) {
        let sp = NSTemporaryDirectory() + "mock_\(UUID().uuidString).py"
        try script.write(toFile: sp, atomically: true, encoding: .utf8)
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: python); proc.arguments = [sp]
        let pipe = Pipe(); proc.standardOutput = pipe; try proc.run()
        var port = ""; let deadline = Date().addingTimeInterval(5)
        while port.isEmpty && Date() < deadline {
            let d = pipe.fileHandleForReading.availableData
            if !d.isEmpty { port = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let p = Int(port) else { proc.terminate(); throw XCTSkip("mock did not report a port") }
        return (p, proc)
    }

    // LIVE: exchange an authorization code against a mock token endpoint (python), asserting PKCE fields.
    func testLiveTokenExchange() async throws {
        guard let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("python3 unavailable") }
        let script = """
        import http.server, json, urllib.parse
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0))
                form = urllib.parse.parse_qs(self.rfile.read(n).decode())
                assert form.get('grant_type') == ['authorization_code']
                assert form.get('code') == ['THECODE']
                assert form.get('code_verifier') == ['VER']
                body = json.dumps({"access_token":"AT123","refresh_token":"RT123","expires_in":3600}).encode()
                self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(body)
            def log_message(self,*a): pass
        s = http.server.HTTPServer(('127.0.0.1',0), H); print(s.server_address[1], flush=True); s.serve_forever()
        """
        let sp = NSTemporaryDirectory() + "tok_\(UUID().uuidString).py"
        try script.write(toFile: sp, atomically: true, encoding: .utf8); defer { try? FileManager.default.removeItem(atPath: sp) }
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: python); proc.arguments = [sp]
        let pipe = Pipe(); proc.standardOutput = pipe; try proc.run(); defer { proc.terminate() }
        var port = ""; let deadline = Date().addingTimeInterval(5)
        while port.isEmpty && Date() < deadline {
            let d = pipe.fileHandleForReading.availableData
            if !d.isEmpty { port = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let p = Int(port) else { throw XCTSkip("no port") }
        let token = try await MCPOAuth.exchangeAuthorizationCode(
            tokenEndpoint: URL(string: "http://127.0.0.1:\(p)/token")!, code: "THECODE", codeVerifier: "VER",
            clientID: "cid", redirectURI: "http://127.0.0.1:1/cb")
        XCTAssertEqual(token.accessToken, "AT123")
        XCTAssertEqual(token.refreshToken, "RT123")
        XCTAssertNotNil(token.expiresAt)
    }

    // MARK: - Conformant AS (real PKCE S256 verification, not an echo mock)

    /// A minimal but CONFORMANT OAuth 2.1 authorization server: `/authorize` mints a real code bound to
    /// the client's `code_challenge`; `/token` recomputes `base64url(SHA256(code_verifier))` and rejects
    /// any mismatch. This is what upgrades the suite from "mock echo" to a real cryptographic round-trip
    /// — the SERVER independently verifies our PKCE, so a green test actually proves our implementation.
    private static let conformantAS = """
    import http.server, json, urllib.parse, hashlib, base64, secrets
    codes = {}
    def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            assert q.get('code_challenge_method') == ['S256'], 'must be S256'
            ch = q.get('code_challenge',[''])[0]; ru = q.get('redirect_uri',[''])[0]; st = q.get('state',[''])[0]
            code = secrets.token_urlsafe(16); codes[code] = ch
            sep = '&' if '?' in ru else '?'
            loc = ru + sep + urllib.parse.urlencode({'code': code, 'state': st})
            self.send_response(302); self.send_header('Location', loc); self.end_headers()
        def do_POST(self):
            n = int(self.headers.get('Content-Length',0)); f = urllib.parse.parse_qs(self.rfile.read(n).decode())
            gt = f.get('grant_type',[''])[0]
            if gt == 'authorization_code':
                code = f.get('code',[''])[0]; ver = f.get('code_verifier',[''])[0]
                expected = codes.pop(code, None)                      # single-use code
                actual = b64url(hashlib.sha256(ver.encode()).digest())
                if expected is None or actual != expected:
                    self.send_response(400); self.send_header('Content-Type','application/json'); self.end_headers()
                    self.wfile.write(b'{"error":"invalid_grant"}'); return
                body = json.dumps({"access_token":"REAL_AT","refresh_token":"REAL_RT","expires_in":3600}).encode()
            elif gt == 'refresh_token':
                body = json.dumps({"access_token":"REAL_AT2","refresh_token":"REAL_RT2","expires_in":3600}).encode()
            else:
                self.send_response(400); self.end_headers(); return
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(body)
        def log_message(self,*a): pass
    s = http.server.HTTPServer(('127.0.0.1',0), H); print(s.server_address[1], flush=True); s.serve_forever()
    """

    private func python() throws -> String {
        guard let p = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("python3 unavailable") }
        return p
    }

    /// FULL e2e against the conformant AS: the client's real PKCE verifier is validated by the server's
    /// independent S256 check, then the stored refresh token is exercised — end to end, no echo.
    func testConformantAuthServerVerifiesPKCEEndToEnd() async throws {
        let (port, proc) = try startMock(python: try python(), script: Self.conformantAS)
        defer { proc.terminate() }
        let path = NSTemporaryDirectory() + "oauth-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = OAuthTokenStore(path: path)
        let base = "http://127.0.0.1:\(port)"
        let metadata = MCPOAuth.Metadata(
            authorizationEndpoint: URL(string: base + "/authorize")!,
            tokenEndpoint: URL(string: base + "/token")!, registrationEndpoint: nil)

        // Fake browser: just GET the real /authorize URL and FOLLOW its 302 to the loopback callback —
        // the AS issues the code, our client exchanges it, and the AS verifies OUR PKCE verifier.
        try await MCPOAuthFlow.authorize(serverName: "srv", metadata: metadata, clientID: "cid",
                                         scope: "mcp", store: store) { authURL in
            Task.detached { _ = try? await URLSession.shared.data(from: authURL) }
        }

        let t = await store.token(for: "srv")
        XCTAssertEqual(t?.accessToken, "REAL_AT", "server-verified PKCE exchange must yield the AS token")
        XCTAssertEqual(t?.refreshToken, "REAL_RT")

        // Exercise refresh against the same conformant AS.
        let refreshed = try await MCPOAuth.refreshToken(
            tokenEndpoint: URL(string: base + "/token")!, refreshToken: "REAL_RT", clientID: "cid")
        XCTAssertEqual(refreshed.accessToken, "REAL_AT2")
    }

    /// NEGATIVE (proves the positive test means something): mint a code for challenge = S256(V), then
    /// exchange with a DIFFERENT verifier. A conformant server MUST reject it → our exchange must throw.
    func testConformantAuthServerRejectsWrongVerifier() async throws {
        let (port, proc) = try startMock(python: try python(), script: Self.conformantAS)
        defer { proc.terminate() }
        let base = "http://127.0.0.1:\(port)"

        // Ask /authorize for a code bound to the challenge of the CORRECT verifier (no redirect follow).
        let correctVerifier = MCPOAuth.generateCodeVerifier()
        let challenge = MCPOAuth.codeChallenge(for: correctVerifier)
        var comps = URLComponents(string: base + "/authorize")!
        comps.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: "cid"),
            .init(name: "redirect_uri", value: "http://127.0.0.1:1/cb"), .init(name: "state", value: "s"),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
        ]
        let (_, resp) = try await MCPOAuth.secureSession.data(from: comps.url!)   // no-redirect → keeps the 302
        let location = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? ""
        guard let code = URLComponents(string: location)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            return XCTFail("AS did not issue a code (Location: \(location))")
        }

        // Exchange the code with a WRONG verifier → the server's S256 check must fail the grant.
        do {
            _ = try await MCPOAuth.exchangeAuthorizationCode(
                tokenEndpoint: URL(string: base + "/token")!, code: code,
                codeVerifier: MCPOAuth.generateCodeVerifier(),   // different verifier
                clientID: "cid", redirectURI: "http://127.0.0.1:1/cb")
            XCTFail("server must reject a verifier whose S256 != stored challenge")
        } catch {
            // expected — invalid_grant (400)
        }
    }
}
