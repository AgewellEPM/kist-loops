import Foundation

/// The closed outbound HTTP method set accepted from OpenAPI. TRACE is deliberately absent.
public enum SMLHTTPMethod: String, Sendable, Codable, Equatable, CaseIterable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case options = "OPTIONS"

    public var isReadOnly: Bool { self == .get || self == .head }
}

public enum SMLHTTPParameterLocation: String, Sendable, Codable, Equatable {
    case path
    case query
    case header
}

public struct SMLHTTPServerSpec: Sendable, Codable, Equatable {
    public let scheme: String
    public let host: String
    public let port: Int?
    public let basePath: String

    public init(scheme: String, host: String, port: Int? = nil, basePath: String = "") {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.basePath = basePath
    }

    enum CodingKeys: String, CodingKey {
        case scheme, host, port
        case basePath = "base_path"
    }

    public var origin: String {
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        let authority = port.map { "\(renderedHost):\($0)" } ?? renderedHost
        return "\(scheme)://\(authority)"
    }
}

public struct SMLHTTPParameterSpec: Sendable, Codable, Equatable {
    public let name: String
    public let location: SMLHTTPParameterLocation
    public let required: Bool
    public let stateField: String
    public let valueType: SMLStateType
    public let explode: Bool

    public init(
        name: String,
        location: SMLHTTPParameterLocation,
        required: Bool,
        stateField: String,
        valueType: SMLStateType = .string,
        explode: Bool = false
    ) {
        self.name = name
        self.location = location
        self.required = required
        self.stateField = stateField
        self.valueType = valueType
        self.explode = explode
    }

    enum CodingKeys: String, CodingKey {
        case name, location, required, explode
        case stateField = "state_field"
        case valueType = "value_type"
    }
}

public enum SMLHTTPAuthenticationKind: String, Sendable, Codable, Equatable {
    case apiKeyHeader = "api_key_header"
    case bearer
    case basic
    case oauth2Bearer = "oauth2_bearer"
    case openIDBearer = "openid_bearer"
}

/// One scheme in an OpenAPI security-requirement alternative. An alternative is satisfied only
/// when every scheme in it has a matching host credential; alternatives preserve OpenAPI's OR.
public struct SMLHTTPAuthenticationSchemeSpec: Sendable, Codable, Equatable {
    public let credentialID: String
    public let kind: SMLHTTPAuthenticationKind
    public let headerName: String?
    public let requiredScopes: [String]

    public init(
        credentialID: String,
        kind: SMLHTTPAuthenticationKind,
        headerName: String? = nil,
        requiredScopes: [String] = []
    ) {
        self.credentialID = credentialID
        self.kind = kind
        self.headerName = headerName
        self.requiredScopes = requiredScopes.sorted()
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case credentialID = "credential_id"
        case headerName = "header_name"
        case requiredScopes = "required_scopes"
    }
}

public struct SMLHTTPAuthenticationRequirement: Sendable, Codable, Equatable {
    public let schemes: [SMLHTTPAuthenticationSchemeSpec]

    public init(schemes: [SMLHTTPAuthenticationSchemeSpec]) {
        self.schemes = schemes.sorted { $0.credentialID < $1.credentialID }
    }
}

public struct SMLHTTPRequestBodySpec: Sendable, Codable, Equatable {
    public let required: Bool
    public let stateField: String
    public let valueType: SMLStateType
    public let maximumBytes: Int

    public init(
        required: Bool,
        stateField: String = "request_body",
        valueType: SMLStateType = .object,
        maximumBytes: Int
    ) {
        self.required = required
        self.stateField = stateField
        self.valueType = valueType
        self.maximumBytes = maximumBytes
    }

    enum CodingKeys: String, CodingKey {
        case required
        case stateField = "state_field"
        case valueType = "value_type"
        case maximumBytes = "maximum_bytes"
    }
}

public struct SMLHTTPEndpointSpec: Sendable, Codable, Equatable {
    public let capability: String
    public let method: SMLHTTPMethod
    public let pathTemplate: String
    public let servers: [SMLHTTPServerSpec]
    public let parameters: [SMLHTTPParameterSpec]
    public let requestBody: SMLHTTPRequestBodySpec?
    public let authentication: [SMLHTTPAuthenticationRequirement]
    public let responseStateField: String
    public let timeoutSeconds: Double
    public let maximumResponseBytes: Int

    public init(
        capability: String,
        method: SMLHTTPMethod,
        pathTemplate: String,
        servers: [SMLHTTPServerSpec],
        parameters: [SMLHTTPParameterSpec] = [],
        requestBody: SMLHTTPRequestBodySpec? = nil,
        authentication: [SMLHTTPAuthenticationRequirement] = [],
        responseStateField: String = "response_body",
        timeoutSeconds: Double = 30,
        maximumResponseBytes: Int = 64 * 1_024
    ) {
        self.capability = capability
        self.method = method
        self.pathTemplate = pathTemplate
        self.servers = servers
        self.parameters = parameters
        self.requestBody = requestBody
        self.authentication = authentication
        self.responseStateField = responseStateField
        self.timeoutSeconds = timeoutSeconds
        self.maximumResponseBytes = maximumResponseBytes
    }

    enum CodingKeys: String, CodingKey {
        case capability, method, servers, parameters, authentication
        case pathTemplate = "path_template"
        case requestBody = "request_body"
        case responseStateField = "response_state_field"
        case timeoutSeconds = "timeout_seconds"
        case maximumResponseBytes = "maximum_response_bytes"
    }
}

/// Human-reviewable, secret-free execution description for one imported API.
public struct SMLHTTPEndpointBundle: Sendable, Codable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let apiID: String
    public let sourceDigest: String
    public let endpoints: [SMLHTTPEndpointSpec]

    public init(
        schemaVersion: Int = SMLHTTPEndpointBundle.schemaVersion,
        apiID: String,
        sourceDigest: String,
        endpoints: [SMLHTTPEndpointSpec]
    ) {
        self.schemaVersion = schemaVersion
        self.apiID = apiID
        self.sourceDigest = sourceDigest
        self.endpoints = endpoints.sorted { $0.capability < $1.capability }
    }

    enum CodingKeys: String, CodingKey {
        case endpoints
        case schemaVersion = "schema_version"
        case apiID = "api_id"
        case sourceDigest = "source_digest"
    }
}

/// Import output is deliberately not a live host catalog. Operators copy the exact capability list
/// into `.kist/sml/catalog.json` after review; the importer has no authority to merge it.
public struct SMLHTTPProposedCatalogFragment: Sendable, Codable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let kind: String
    public let apiID: String
    public let sourceDigest: String
    public let toolCapabilities: [String]
    public let reviewRequired: Bool

    public init(apiID: String, sourceDigest: String, toolCapabilities: [String]) {
        schemaVersion = Self.schemaVersion
        kind = "sml_http_catalog_proposal"
        self.apiID = apiID
        self.sourceDigest = sourceDigest
        self.toolCapabilities = toolCapabilities.sorted()
        reviewRequired = true
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion = "schema_version"
        case apiID = "api_id"
        case sourceDigest = "source_digest"
        case toolCapabilities = "tool_capabilities"
        case reviewRequired = "review_required"
    }
}

public enum SMLHTTPEndpointConfigurationError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case invalidBundle(String)
    case duplicateCapability(String)
    case missingDirectory(String)
    case unreadable(path: String, reason: String)

    public var description: String {
        switch self {
        case .invalidBundle(let reason): return "invalid SML HTTP endpoint bundle: \(reason)"
        case .duplicateCapability(let capability):
            return "SML HTTP capability '\(capability)' is defined by more than one endpoint"
        case .missingDirectory(let path): return "SML HTTP endpoint directory is missing: \(path)"
        case .unreadable(let path, let reason):
            return "SML HTTP endpoint configuration is unreadable: \(path) (\(reason))"
        }
    }
}

/// Validated aggregate loaded from `.kist/sml/http-endpoints/*.json` through ConfinedRoot.
public struct SMLHTTPEndpointRegistry: Sendable {
    public static let relativeDirectory = ".kist/sml/http-endpoints"
    public static let maximumBundleBytes = 8 * 1_024 * 1_024

    public let endpoints: [String: SMLHTTPEndpointSpec]

    public init(bundles: [SMLHTTPEndpointBundle]) throws {
        var indexed: [String: SMLHTTPEndpointSpec] = [:]
        for bundle in bundles {
            try SMLHTTPEndpointValidation.validate(bundle)
            for endpoint in bundle.endpoints {
                guard indexed[endpoint.capability] == nil else {
                    throw SMLHTTPEndpointConfigurationError.duplicateCapability(endpoint.capability)
                }
                indexed[endpoint.capability] = endpoint
            }
        }
        endpoints = indexed
    }

    private init(validatedEndpoints: [String: SMLHTTPEndpointSpec]) {
        endpoints = validatedEndpoints
    }

    /// Keep only human-admitted capabilities before resolving credentials or constructing a
    /// driver. A bundle cannot introduce a capability name the host catalog did not grant.
    public func selecting(_ capabilities: Set<String>) -> SMLHTTPEndpointRegistry {
        SMLHTTPEndpointRegistry(validatedEndpoints: endpoints.filter {
            capabilities.contains($0.key)
        })
    }

    public static func load(projectRoot: String) throws -> SMLHTTPEndpointRegistry {
        let root: ConfinedRoot
        do { root = try ConfinedRoot(root: projectRoot, readOnly: true) }
        catch { throw SMLHTTPEndpointConfigurationError.unreadable(
            path: projectRoot, reason: String(describing: error)) }
        let type: (exists: Bool, isDir: Bool)
        do { type = try root.fileType(relativeDirectory) }
        catch { throw SMLHTTPEndpointConfigurationError.unreadable(
            path: relativeDirectory, reason: String(describing: error)) }
        guard type.exists else { return try SMLHTTPEndpointRegistry(bundles: []) }
        guard type.isDir else {
            throw SMLHTTPEndpointConfigurationError.unreadable(
                path: relativeDirectory, reason: "expected a real directory")
        }
        let entries: [(name: String, isDir: Bool)]
        do { entries = try root.entries(relativeDirectory) }
        catch { throw SMLHTTPEndpointConfigurationError.unreadable(
            path: relativeDirectory, reason: String(describing: error)) }
        var bundles: [SMLHTTPEndpointBundle] = []
        for entry in entries where entry.name.hasSuffix(".json") {
            guard !entry.isDir, Self.safeFilename(entry.name) else {
                throw SMLHTTPEndpointConfigurationError.unreadable(
                    path: entry.name, reason: "unsafe endpoint bundle filename")
            }
            let relativePath = "\(relativeDirectory)/\(entry.name)"
            do {
                let data = try root.readStableOwnerOnlyData(
                    relativePath, maxBytes: maximumBundleBytes, permissions: 0o600)
                let object = try SMLWireCodec.decodeOpenObject(from: data)
                try validateWireShape(object)
                bundles.append(try JSONDecoder().decode(SMLHTTPEndpointBundle.self, from: data))
            } catch {
                throw SMLHTTPEndpointConfigurationError.unreadable(
                    path: relativePath, reason: String(describing: error))
            }
        }
        return try SMLHTTPEndpointRegistry(bundles: bundles)
    }

    private static func safeFilename(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 192 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...90).contains($0.value)
                || (97...122).contains($0.value) || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    private static func validateWireShape(_ root: SMLObject) throws {
        try requireKeys(
            root,
            allowed: ["schema_version", "api_id", "source_digest", "endpoints"],
            path: "bundle"
        )
        guard case .array(let endpoints)? = root["endpoints"] else {
            throw SMLHTTPEndpointConfigurationError.invalidBundle("endpoints must be an array")
        }
        for (endpointIndex, value) in endpoints.enumerated() {
            let endpoint = try object(value, path: "endpoints[\(endpointIndex)]")
            try requireKeys(
                endpoint,
                allowed: ["capability", "method", "path_template", "servers", "parameters",
                          "request_body", "authentication", "response_state_field",
                          "timeout_seconds", "maximum_response_bytes"],
                path: "endpoints[\(endpointIndex)]"
            )
            if case .array(let servers)? = endpoint["servers"] {
                for (index, value) in servers.enumerated() {
                    try requireKeys(
                        try object(value, path: "servers[\(index)]"),
                        allowed: ["scheme", "host", "port", "base_path"],
                        path: "servers[\(index)]"
                    )
                }
            }
            if case .array(let parameters)? = endpoint["parameters"] {
                for (index, value) in parameters.enumerated() {
                    try requireKeys(
                        try object(value, path: "parameters[\(index)]"),
                        allowed: ["name", "location", "required", "state_field", "value_type",
                                  "explode"],
                        path: "parameters[\(index)]"
                    )
                }
            }
            if let value = endpoint["request_body"] {
                try requireKeys(
                    try object(value, path: "request_body"),
                    allowed: ["required", "state_field", "value_type", "maximum_bytes"],
                    path: "request_body"
                )
            }
            if case .array(let requirements)? = endpoint["authentication"] {
                for (requirementIndex, value) in requirements.enumerated() {
                    let requirement = try object(
                        value, path: "authentication[\(requirementIndex)]")
                    try requireKeys(
                        requirement, allowed: ["schemes"],
                        path: "authentication[\(requirementIndex)]")
                    if case .array(let schemes)? = requirement["schemes"] {
                        for (schemeIndex, value) in schemes.enumerated() {
                            try requireKeys(
                                try object(value, path: "schemes[\(schemeIndex)]"),
                                allowed: ["credential_id", "kind", "header_name",
                                          "required_scopes"],
                                path: "schemes[\(schemeIndex)]"
                            )
                        }
                    }
                }
            }
        }
    }

    private static func object(_ value: SMLValue, path: String) throws -> SMLObject {
        guard case .object(let object) = value else {
            throw SMLHTTPEndpointConfigurationError.invalidBundle("\(path) must be an object")
        }
        return object
    }

    private static func requireKeys(
        _ object: SMLObject,
        allowed: Set<String>,
        path: String
    ) throws {
        guard let unknown = object.keys.first(where: { !allowed.contains($0) }) else { return }
        throw SMLHTTPEndpointConfigurationError.invalidBundle(
            "unknown field '\(unknown)' at \(path)")
    }
}

enum SMLHTTPEndpointValidation {
    static let maximumRequestBytes = 4 * 1_024 * 1_024
    // HTTP response bodies are materialized into one SML string state value. Keep the transport
    // limit aligned with that state boundary; larger results need an artifact-backed capability.
    static let maximumResponseBytes = 64 * 1_024

    static func validate(_ bundle: SMLHTTPEndpointBundle) throws {
        guard bundle.schemaVersion == SMLHTTPEndpointBundle.schemaVersion,
              SMLValidationSupport.identifierIsValid(bundle.apiID, maximumLength: 96),
              isDigest(bundle.sourceDigest),
              !bundle.endpoints.isEmpty,
              bundle.endpoints.count <= 1_024 else {
            throw SMLHTTPEndpointConfigurationError.invalidBundle("invalid envelope fields")
        }
        var capabilities = Set<String>()
        for endpoint in bundle.endpoints {
            guard SMLValidationSupport.identifierIsValid(endpoint.capability),
                  capabilities.insert(endpoint.capability).inserted,
                  validPathTemplate(endpoint.pathTemplate),
                  !endpoint.servers.isEmpty,
                  endpoint.servers.count <= 16,
                  endpoint.parameters.count <= 128,
                  SMLValidationSupport.identifierIsValid(
                    endpoint.responseStateField, allowDot: false),
                  endpoint.timeoutSeconds.isFinite,
                  (0.1...60).contains(endpoint.timeoutSeconds),
                  (1...maximumResponseBytes).contains(endpoint.maximumResponseBytes) else {
                throw SMLHTTPEndpointConfigurationError.invalidBundle(
                    "invalid endpoint '\(endpoint.capability)'")
            }
            var serverIdentities = Set<String>()
            for server in endpoint.servers {
                try validateServer(server)
                guard serverIdentities.insert("\(server.origin)\(server.basePath)").inserted else {
                    throw SMLHTTPEndpointConfigurationError.invalidBundle(
                        "duplicate server for '\(endpoint.capability)'")
                }
            }
            try validateParameters(endpoint.parameters, pathTemplate: endpoint.pathTemplate)
            var occupiedStateFields = Set(endpoint.parameters.map(\.stateField))
            if let body = endpoint.requestBody {
                guard SMLValidationSupport.identifierIsValid(body.stateField, allowDot: false),
                      (1...maximumRequestBytes).contains(body.maximumBytes),
                      !endpoint.method.isReadOnly,
                      occupiedStateFields.insert(body.stateField).inserted else {
                    throw SMLHTTPEndpointConfigurationError.invalidBundle(
                        "invalid request body for '\(endpoint.capability)'")
                }
            }
            guard occupiedStateFields.insert(endpoint.responseStateField).inserted else {
                throw SMLHTTPEndpointConfigurationError.invalidBundle(
                    "response state field collides for '\(endpoint.capability)'")
            }
            try validateAuthentication(endpoint.authentication)
            try validateHeaderOwnership(endpoint)
        }
    }

    private static func validateServer(_ server: SMLHTTPServerSpec) throws {
        let loopback = server.host == "127.0.0.1" || server.host == "::1"
        guard (server.scheme == "https" || (server.scheme == "http" && loopback)),
              validHost(server.host),
              server.port.map({ (1...65_535).contains($0) }) ?? true,
              validBasePath(server.basePath) else {
            throw SMLHTTPEndpointConfigurationError.invalidBundle(
                "server '\(server.origin)' is not a secure pinned origin")
        }
    }

    private static func validateParameters(
        _ parameters: [SMLHTTPParameterSpec],
        pathTemplate: String
    ) throws {
        var identities = Set<String>()
        var stateFields = Set<String>()
        let placeholders = Set(pathTemplatePlaceholders(pathTemplate))
        var declaredPath = Set<String>()
        for parameter in parameters {
            let identityName = parameter.location == .header
                ? parameter.name.lowercased() : parameter.name
            let identity = "\(parameter.location.rawValue):\(identityName)"
            guard !parameter.name.isEmpty, parameter.name.utf8.count <= 128,
                  identities.insert(identity).inserted,
                  SMLValidationSupport.identifierIsValid(parameter.stateField, allowDot: false),
                  stateFields.insert(parameter.stateField).inserted,
                  parameter.valueType != .object,
                  parameter.location == .query || parameter.valueType != .array,
                  parameter.location != .path || parameter.required,
                  parameter.location != .header || (validHeaderName(parameter.name)
                      && !reservedHeader(parameter.name)) else {
                throw SMLHTTPEndpointConfigurationError.invalidBundle(
                    "invalid HTTP parameter '\(identity)'")
            }
            if parameter.location == .path { declaredPath.insert(parameter.name) }
        }
        guard placeholders == declaredPath else {
            throw SMLHTTPEndpointConfigurationError.invalidBundle(
                "path placeholders do not exactly match required path parameters")
        }
    }

    private static func validateAuthentication(
        _ requirements: [SMLHTTPAuthenticationRequirement]
    ) throws {
        guard requirements.count <= 16 else {
            throw SMLHTTPEndpointConfigurationError.invalidBundle("too many auth alternatives")
        }
        for requirement in requirements {
            guard requirement.schemes.count <= 8 else {
                throw SMLHTTPEndpointConfigurationError.invalidBundle("too many auth schemes")
            }
            var ids = Set<String>()
            var headerNames = Set<String>()
            for scheme in requirement.schemes {
                guard SMLValidationSupport.identifierIsValid(scheme.credentialID),
                      ids.insert(scheme.credentialID).inserted,
                      scheme.requiredScopes.count <= 128,
                      Set(scheme.requiredScopes).count == scheme.requiredScopes.count,
                      scheme.requiredScopes.allSatisfy({
                          !$0.isEmpty && $0.utf8.count <= 256
                              && !$0.unicodeScalars.contains(where: {
                                  $0.value < 0x20 || $0.value == 0x7f
                                      || ($0.value >= 0x80 && $0.value <= 0x9f)
                              })
                      }) else {
                    throw SMLHTTPEndpointConfigurationError.invalidBundle("invalid auth scheme")
                }
                if scheme.kind == .apiKeyHeader {
                    guard let header = scheme.headerName, validHeaderName(header),
                          !reservedHeader(header),
                          headerNames.insert(header.lowercased()).inserted else {
                        throw SMLHTTPEndpointConfigurationError.invalidBundle(
                            "invalid API-key header")
                    }
                } else if scheme.headerName != nil {
                    throw SMLHTTPEndpointConfigurationError.invalidBundle(
                        "unexpected auth header override")
                } else if !headerNames.insert("authorization").inserted {
                    throw SMLHTTPEndpointConfigurationError.invalidBundle(
                        "authentication schemes collide on Authorization")
                }
            }
        }
    }

    private static func validateHeaderOwnership(_ endpoint: SMLHTTPEndpointSpec) throws {
        let parameterNames = Set(endpoint.parameters.compactMap {
            $0.location == .header ? $0.name.lowercased() : nil
        })
        for requirement in endpoint.authentication {
            let authNames = Set(requirement.schemes.map { scheme in
                scheme.kind == .apiKeyHeader
                    ? (scheme.headerName ?? "").lowercased()
                    : "authorization"
            })
            guard parameterNames.isDisjoint(with: authNames) else {
                throw SMLHTTPEndpointConfigurationError.invalidBundle(
                    "HTTP parameter and authentication headers collide")
            }
        }
    }

    static func validHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    static func reservedHeader(_ value: String) -> Bool {
        ["authorization", "proxy-authorization", "cookie", "host", "content-length",
         "transfer-encoding", "connection", "expect", "upgrade", "accept", "content-type",
         "user-agent"].contains(value.lowercased())
    }

    static func pathTemplatePlaceholders(_ path: String) -> [String] {
        var values: [String] = []
        var cursor = path.startIndex
        while let open = path[cursor...].firstIndex(of: "{") {
            guard let close = path[open...].firstIndex(of: "}") else { break }
            values.append(String(path[path.index(after: open)..<close]))
            cursor = path.index(after: close)
        }
        return values
    }

    private static func validPathTemplate(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 2_048,
              !path.contains("?"), !path.contains("#"), !path.contains("%"),
              !path.contains("//"), !path.split(separator: "/").contains(".."),
              validPathBytes(path) else {
            return false
        }
        let placeholders = pathTemplatePlaceholders(path)
        guard Set(placeholders).count == placeholders.count,
              placeholders.allSatisfy({ !$0.isEmpty && !$0.contains("{") && !$0.contains("}") })
        else { return false }
        var depth = 0
        for scalar in path.unicodeScalars {
            if scalar == "{" { depth += 1 }
            if scalar == "}" { depth -= 1 }
            if depth < 0 || depth > 1 { return false }
        }
        return depth == 0
    }

    private static func validBasePath(_ path: String) -> Bool {
        path.isEmpty || (path.hasPrefix("/") && path != "/" && path.utf8.count <= 1_024
            && !path.hasSuffix("/")
            && !path.contains("?") && !path.contains("#") && !path.contains("%")
            && !path.contains("//") && !path.split(separator: "/").contains("..")
            && !path.contains("{") && !path.contains("}") && validPathBytes(path))
    }

    private static func validPathBytes(_ path: String) -> Bool {
        let allowed = Set(("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
            + "-._~!$&'()*+,;=:@/{}").utf8)
        return path.utf8.allSatisfy(allowed.contains)
    }

    private static func validHost(_ host: String) -> Bool {
        !host.hasPrefix("*.") && WebFetchTool.normalizedHostPattern(host) == host
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }
}
