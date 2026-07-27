import Foundation

/// The universal connector surface: a uniform way for the AI system to call ANY
/// external API in real time. Concrete connectors are REST (manifest-driven) or MCP
/// (bridged to kist's MCP client). The AI drives these via tool-calling; every call
/// is audited and the levels are auto-tuned.
public struct ConnectorAction: Codable, Sendable, Equatable {
    public let name: String
    public let method: String        // GET / POST / PUT / PATCH / DELETE
    public let path: String          // e.g. "/v1/items/{id}"; {param} filled from input
    public let description: String
    public init(name: String, method: String, path: String, description: String = "") {
        self.name = name
        self.method = method.uppercased()
        self.path = path
        self.description = description
    }
}

public struct ConnectorResult: Sendable, Equatable {
    public let statusCode: Int
    public let body: String
    public var ok: Bool { (200..<300).contains(statusCode) }
    public init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }
}

public enum ConnectorError: Error, CustomStringConvertible, Equatable {
    case unknownAction(String)
    case authMissing(env: String)
    case insecureURL(String)
    case badURL(String)
    case transport(String)

    public var description: String {
        switch self {
        case let .unknownAction(a): return "connector has no action “\(a)”"
        case let .authMissing(env): return "auth env var \(env) is not set (secrets never live in manifests)"
        case let .insecureURL(u): return "refusing non-HTTPS URL \(u) (set allowInsecureHTTP for localhost dev)"
        case let .badURL(u): return "invalid URL \(u)"
        case let .transport(m): return "connector transport error: \(m)"
        }
    }
}

/// A live connector. `invoke` performs the real call; the registry/audit/tuner wrap it.
public protocol Connector: Sendable {
    var name: String { get }
    func actions() -> [ConnectorAction]
    func invoke(action: String, input: [String: String]) async throws -> ConnectorResult
}
