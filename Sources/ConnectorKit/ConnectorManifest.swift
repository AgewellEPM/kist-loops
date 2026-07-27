import Foundation

/// A declarative description of a REST API — the "auto-connect any API" unit. Drop a
/// manifest JSON into the connectors dir and it becomes a live connector. SECRETS
/// NEVER LIVE HERE: auth references an ENVIRONMENT VARIABLE that holds the token, so
/// manifests are safe to commit and share.
public struct ConnectorManifest: Codable, Sendable, Equatable {
    public let name: String
    public let baseURL: String
    public let auth: Auth
    public let actions: [ConnectorAction]
    public var allowInsecureHTTP: Bool

    public init(name: String, baseURL: String, auth: Auth, actions: [ConnectorAction],
                allowInsecureHTTP: Bool = false) {
        self.name = name
        self.baseURL = baseURL
        self.auth = auth
        self.actions = actions
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    /// How to authenticate — always by reference to an env var, never a literal token.
    /// Human-writable JSON via a `type` discriminator:
    ///   {"type":"none"}
    ///   {"type":"bearer","env":"SCRIBE_API_KEY"}
    ///   {"type":"header","name":"X-Api-Key","env":"OTONIS_API_KEY"}
    public enum Auth: Sendable, Equatable, Codable {
        case none
        case bearerEnv(String)
        case headerEnv(name: String, env: String)

        enum CodingKeys: String, CodingKey { case type, env, name }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch (try? c.decode(String.self, forKey: .type)) ?? "none" {
            case "bearer": self = .bearerEnv(try c.decode(String.self, forKey: .env))
            case "header": self = .headerEnv(name: try c.decode(String.self, forKey: .name),
                                             env: try c.decode(String.self, forKey: .env))
            default: self = .none
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .none:
                try c.encode("none", forKey: .type)
            case let .bearerEnv(env):
                try c.encode("bearer", forKey: .type); try c.encode(env, forKey: .env)
            case let .headerEnv(name, env):
                try c.encode("header", forKey: .type)
                try c.encode(name, forKey: .name); try c.encode(env, forKey: .env)
            }
        }
    }

    enum CodingKeys: String, CodingKey { case name, baseURL, auth, actions, allowInsecureHTTP }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        auth = try c.decodeIfPresent(Auth.self, forKey: .auth) ?? .none
        actions = try c.decodeIfPresent([ConnectorAction].self, forKey: .actions) ?? []
        allowInsecureHTTP = try c.decodeIfPresent(Bool.self, forKey: .allowInsecureHTTP) ?? false
    }

    public static func load(_ url: URL) -> ConnectorManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ConnectorManifest.self, from: data)
    }
}
