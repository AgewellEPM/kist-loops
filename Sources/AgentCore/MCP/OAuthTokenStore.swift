import Foundation

/// Persists OAuth records per MCP server to an OWNER-ONLY file (`~/.kist/mcp-oauth.json`, mode 0600) so a
/// one-time `authorize` survives across sessions, AND acts as the refresh-aware bearer source for the HTTP
/// transport. Access/refresh tokens are secrets — the file is created and re-chmod'd to 0600 on every
/// write, and refused on load if it's group/world-readable. Each record keeps the token endpoint +
/// client id needed to refresh, so `bearer(for:)` can silently renew an expired access token.
public actor OAuthTokenStore {
    private let path: String
    private var records: [String: Record] = [:]   // server name → record
    private var refreshing: [String: Task<String?, Never>] = [:]   // in-flight refresh per server (coalesce)

    struct Record: Sendable {
        var token: MCPOAuth.Token
        let tokenEndpoint: URL
        let clientID: String
    }
    struct Persisted: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAtEpoch: Double?
        var tokenEndpoint: String
        var clientID: String
    }

    public init(path: String? = nil) {
        let resolvedPath = path
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kist/mcp-oauth.json")
        self.path = resolvedPath
        self.records = Self.loadRecords(at: resolvedPath)
    }

    public func token(for server: String) -> MCPOAuth.Token? { records[server]?.token }

    /// Store the result of an authorize/refresh, keeping the endpoint+client id needed for future refresh.
    public func set(_ token: MCPOAuth.Token, tokenEndpoint: URL, clientID: String, for server: String) {
        records[server] = Record(token: token, tokenEndpoint: tokenEndpoint, clientID: clientID)
        save()
    }

    public func remove(_ server: String) { records[server] = nil; save() }

    /// The CURRENT access token for a server, refreshing it first if it's expired and a refresh token
    /// exists. Returns nil if there's no record or refresh failed. This is the bearer source for the
    /// HTTP transport (MCPHTTPConnection.bearerProvider).
    public func bearer(for server: String) async -> String? {
        guard let rec = records[server] else { return nil }
        guard rec.token.isExpired, let refresh = rec.token.refreshToken else { return rec.token.accessToken }
        // COALESCE: if a refresh for this server is already in flight, await it instead of submitting the
        // same rotating refresh token twice (double-spend) — the actor suspends during the network call
        // (Codex). Both callers get the same result.
        if let inflight = refreshing[server] { return await inflight.value }
        let task = Task<String?, Never> { await self.performRefresh(server: server, rec: rec, refresh: refresh) }
        refreshing[server] = task
        let result = await task.value
        refreshing[server] = nil
        return result
    }

    private func performRefresh(server: String, rec: Record, refresh: String) async -> String? {
        guard let fresh = try? await MCPOAuth.refreshToken(tokenEndpoint: rec.tokenEndpoint, refreshToken: refresh, clientID: rec.clientID) else {
            return nil   // refresh failed → no bearer; the caller sees an auth error and can re-authorize
        }
        // A refresh response may omit a new refresh_token — keep the old one.
        let merged = MCPOAuth.Token(accessToken: fresh.accessToken,
                                    refreshToken: fresh.refreshToken ?? refresh, expiresAt: fresh.expiresAt)
        records[server] = Record(token: merged, tokenEndpoint: rec.tokenEndpoint, clientID: rec.clientID)
        save()
        return merged.accessToken
    }

    // MARK: - Persistence

    private static func loadRecords(at path: String) -> [String: Record] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        // Refuse a token file that isn't owner-only (a group/world-readable secret file is a leak).
        if let perms = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue,
           (perms & 0o077) != 0 { return [:] }
        guard let data = FileManager.default.contents(atPath: path),
              let raw = try? JSONDecoder().decode([String: Persisted].self, from: data) else { return [:] }
        return raw.compactMapValues { p in
            guard let ep = URL(string: p.tokenEndpoint) else { return nil }
            return Record(token: MCPOAuth.Token(accessToken: p.accessToken, refreshToken: p.refreshToken,
                                                expiresAt: p.expiresAtEpoch.map { Date(timeIntervalSince1970: $0) }),
                          tokenEndpoint: ep, clientID: p.clientID)
        }
    }

    private func save() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let raw = records.mapValues { r in
            Persisted(accessToken: r.token.accessToken, refreshToken: r.token.refreshToken,
                      expiresAtEpoch: r.token.expiresAt?.timeIntervalSince1970,
                      tokenEndpoint: r.tokenEndpoint.absoluteString, clientID: r.clientID)
        }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
