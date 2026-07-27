import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Executes a `ConnectorManifest`'s actions as real HTTP. Fail-closed and
/// secret-safe: HTTPS required (unless allowInsecureHTTP for localhost dev), auth
/// resolved from env at call time, missing token throws rather than sending an
/// unauthenticated request.
public struct RESTConnector: Connector {
    public let manifest: ConnectorManifest
    private let env: [String: String]
    private let timeout: TimeInterval

    public init(manifest: ConnectorManifest,
                env: [String: String] = ProcessInfo.processInfo.environment,
                timeout: TimeInterval = 30) {
        self.manifest = manifest
        self.env = env
        self.timeout = timeout
    }

    public var name: String { manifest.name }
    public func actions() -> [ConnectorAction] { manifest.actions }

    public func invoke(action: String, input: [String: String]) async throws -> ConnectorResult {
        guard let act = manifest.actions.first(where: { $0.name == action }) else {
            throw ConnectorError.unknownAction(action)
        }
        // Fill {param} path placeholders from input (percent-encoded).
        var path = act.path
        for (k, v) in input {
            let enc = v.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? v
            path = path.replacingOccurrences(of: "{\(k)}", with: enc)
        }
        let urlString = manifest.baseURL + path
        guard let url = URL(string: urlString) else { throw ConnectorError.badURL(urlString) }
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "https" || (manifest.allowInsecureHTTP && scheme == "http") else {
            throw ConnectorError.insecureURL(urlString)
        }

        var req = URLRequest(url: url)
        req.httpMethod = act.method
        req.timeoutInterval = timeout

        switch manifest.auth {
        case .none:
            break
        case let .bearerEnv(e):
            guard let t = env[e], !t.isEmpty else { throw ConnectorError.authMissing(env: e) }
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        case let .headerEnv(name, e):
            guard let v = env[e], !v.isEmpty else { throw ConnectorError.authMissing(env: e) }
            req.setValue(v, forHTTPHeaderField: name)
        }

        // Non-GET/DELETE: send the input map as a JSON body.
        if act.method != "GET" && act.method != "DELETE" {
            req.httpBody = try? JSONSerialization.data(withJSONObject: input)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return ConnectorResult(statusCode: status, body: String(data: data, encoding: .utf8) ?? "")
        } catch {
            throw ConnectorError.transport(error.localizedDescription)
        }
    }

    /// Build the URLRequest WITHOUT executing — pure, for tests and dry inspection.
    /// Returns the request and a redacted auth summary (never the token itself).
    public func buildRequest(action: String, input: [String: String]) throws -> (URLRequest, authSummary: String) {
        guard let act = manifest.actions.first(where: { $0.name == action }) else {
            throw ConnectorError.unknownAction(action)
        }
        var path = act.path
        for (k, v) in input {
            let enc = v.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? v
            path = path.replacingOccurrences(of: "{\(k)}", with: enc)
        }
        let urlString = manifest.baseURL + path
        guard let url = URL(string: urlString) else { throw ConnectorError.badURL(urlString) }
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "https" || (manifest.allowInsecureHTTP && scheme == "http") else {
            throw ConnectorError.insecureURL(urlString)
        }
        var req = URLRequest(url: url)
        req.httpMethod = act.method
        var summary = "none"
        switch manifest.auth {
        case .none: break
        case let .bearerEnv(e):
            guard let t = env[e], !t.isEmpty else { throw ConnectorError.authMissing(env: e) }
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            summary = "bearer($\(e))"
        case let .headerEnv(name, e):
            guard let v = env[e], !v.isEmpty else { throw ConnectorError.authMissing(env: e) }
            req.setValue(v, forHTTPHeaderField: name)
            summary = "\(name)($\(e))"
        }
        return (req, summary)
    }
}
