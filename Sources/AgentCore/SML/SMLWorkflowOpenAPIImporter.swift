import Foundation

public struct SMLWorkflowOpenAPIImportResult: Sendable {
    public let endpointBundle: SMLHTTPEndpointBundle
    public let proposedCatalog: SMLHTTPProposedCatalogFragment
    public let wrapperWorkflows: [SMLWorkflow]

    public init(
        endpointBundle: SMLHTTPEndpointBundle,
        proposedCatalog: SMLHTTPProposedCatalogFragment,
        wrapperWorkflows: [SMLWorkflow]
    ) {
        self.endpointBundle = endpointBundle
        self.proposedCatalog = proposedCatalog
        self.wrapperWorkflows = wrapperWorkflows
    }
}

/// OpenAPI is imported as a capability catalog, never executed as code. The result is a secret-free
/// endpoint bundle, an explicitly PROPOSED host-catalog fragment, and one optional wrapper workflow
/// per operation. Durable loading applies the normal P1 approval transform to those workflows.
public enum SMLWorkflowOpenAPIImporter {
    private static let rootKeys: Set<String> = [
        "openapi", "info", "jsonSchemaDialect", "servers", "paths", "webhooks",
        "components", "security", "tags", "externalDocs",
    ]
    private static let pathItemKeys: Set<String> = [
        "$ref", "summary", "description", "get", "put", "post", "delete", "options",
        "head", "patch", "trace", "servers", "parameters",
    ]
    private static let operationKeys: Set<String> = [
        "tags", "summary", "description", "externalDocs", "operationId", "parameters",
        "requestBody", "responses", "callbacks", "deprecated", "security", "servers",
    ]
    private static let componentKeys: Set<String> = [
        "schemas", "responses", "parameters", "examples", "requestBodies", "headers",
        "securitySchemes", "links", "callbacks", "pathItems",
    ]

    private struct ParsedParameter {
        let name: String
        let location: SMLHTTPParameterLocation
        let required: Bool
        let valueType: SMLStateType
        let explode: Bool

        var identity: String { "\(location.rawValue):\(name)" }
    }

    public static func importDocument(
        _ data: Data,
        apiID: String,
        sourceReference: String,
        limits: SMLWireCodec.Limits = .standard
    ) throws -> SMLWorkflowOpenAPIImportResult {
        guard SMLValidationSupport.identifierIsValid(apiID, maximumLength: 96),
              !sourceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceReference.utf8.count <= 2_048,
              !sourceReference.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f
              }) else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: "api_id", reason: "api id or source reference is invalid")
        }
        let root = try SMLWireCodec.decodeArbitraryJSONObject(from: data, limits: limits)
        try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
            root, path: "$", allowed: rootKeys)
        try SMLWorkflowOpenAPIImportSupport.validateAllReferences(in: root)

        let version = try SMLWorkflowOpenAPIImportSupport.string(
            root["openapi"], path: "$.openapi")
        guard supportedOpenAPIVersion(version) else {
            throw SMLWorkflowOpenAPIImportError.unsupportedVersion(version)
        }
        let info = try SMLWorkflowOpenAPIImportSupport.object(root["info"], path: "$.info")
        try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
            info,
            path: "$.info",
            allowed: ["title", "summary", "description", "termsOfService", "contact",
                      "license", "version"]
        )
        let title = try SMLWorkflowOpenAPIImportSupport.string(info["title"], path: "$.info.title")
        guard title.utf8.count <= 256 else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: "$.info.title", reason: "title exceeds 256 bytes")
        }
        _ = try SMLWorkflowOpenAPIImportSupport.string(info["version"], path: "$.info.version")
        if let value = root["components"] {
            let components = try SMLWorkflowOpenAPIImportSupport.object(
                value, path: "$.components")
            try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
                components, path: "$.components", allowed: componentKeys)
        }

        let rootServers = try SMLWorkflowOpenAPIImportSupport.servers(
            root["servers"], root: root, path: "$.servers")
        let paths = try SMLWorkflowOpenAPIImportSupport.object(root["paths"], path: "$.paths")
        guard !paths.isEmpty, paths.count <= 1_024 else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: "$.paths", reason: "paths must contain 1...1024 entries")
        }

        let sourceDigest = SMLWorkflowOpenAPIImportSupport.digestHex(data)
        var endpoints: [SMLHTTPEndpointSpec] = []
        var workflows: [SMLWorkflow] = []
        var operationIDs = Set<String>()

        for pathTemplate in paths.keys.sorted() {
            guard pathTemplate.hasPrefix("/") else {
                throw SMLWorkflowOpenAPIImportError.invalidDocument(
                    path: "$.paths.\(pathTemplate)", reason: "path keys must be absolute")
            }
            let pathLocation = "$.paths.\(pathTemplate)"
            let pathItem = try SMLWorkflowOpenAPIImportSupport.resolvedObject(
                paths[pathTemplate], root: root, path: pathLocation)
            try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
                pathItem, path: pathLocation, allowed: pathItemKeys)
            if pathItem["trace"] != nil {
                throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                    path: "\(pathLocation).trace", reason: "TRACE is never executable")
            }
            let pathServers = try SMLWorkflowOpenAPIImportSupport.servers(
                pathItem["servers"], root: root, path: "\(pathLocation).servers")
            let inheritedServers = pathServers.isEmpty ? rootServers : pathServers
            let inheritedParameters = try parameters(
                pathItem["parameters"], root: root, path: "\(pathLocation).parameters")

            for method in SMLHTTPMethod.allCases {
                let methodKey = method.rawValue.lowercased()
                guard let operationValue = pathItem[methodKey] else { continue }
                let operationPath = "\(pathLocation).\(methodKey)"
                let operation = try SMLWorkflowOpenAPIImportSupport.resolvedObject(
                    operationValue, root: root, path: operationPath)
                try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
                    operation, path: operationPath, allowed: operationKeys)
                let responses = try SMLWorkflowOpenAPIImportSupport.object(
                    operation["responses"], path: "\(operationPath).responses")
                guard !responses.isEmpty, responses.count <= 256 else {
                    throw SMLWorkflowOpenAPIImportError.invalidDocument(
                        path: "\(operationPath).responses",
                        reason: "responses must contain 1...256 entries")
                }
                let operationID = try SMLWorkflowOpenAPIImportSupport.string(
                    operation["operationId"], path: "\(operationPath).operationId")
                guard SMLValidationSupport.identifierIsValid(operationID) else {
                    throw SMLWorkflowOpenAPIImportError.invalidDocument(
                        path: "\(operationPath).operationId",
                        reason: "operationId must be an exact SML identifier (1...128 ASCII letters, numbers, '.', '_', or '-')")
                }
                guard operationIDs.insert(operationID).inserted else {
                    throw SMLWorkflowOpenAPIImportError.duplicateOperationID(operationID)
                }

                let operationServers = try SMLWorkflowOpenAPIImportSupport.servers(
                    operation["servers"], root: root, path: "\(operationPath).servers")
                let servers = operationServers.isEmpty ? inheritedServers : operationServers
                guard !servers.isEmpty else {
                    throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                        path: operationPath,
                        reason: "a pinned absolute server URL is required")
                }

                var merged = Dictionary(uniqueKeysWithValues: inheritedParameters.map {
                    ($0.identity, $0)
                })
                for parameter in try parameters(
                    operation["parameters"], root: root,
                    path: "\(operationPath).parameters") {
                    merged[parameter.identity] = parameter
                }
                var usedStateFields = Set<String>()
                let endpointParameters = merged.values.sorted { $0.identity < $1.identity }.map {
                    parameter -> SMLHTTPParameterSpec in
                    let field = SMLWorkflowOpenAPIImportSupport.stableStateField(
                        location: parameter.location,
                        name: parameter.name,
                        used: &usedStateFields)
                    return SMLHTTPParameterSpec(
                        name: parameter.name,
                        location: parameter.location,
                        required: parameter.required,
                        stateField: field,
                        valueType: parameter.valueType,
                        explode: parameter.explode)
                }

                let maximumRequestBytes = try boundedInteger(
                    operation["x-kist-maximum-request-bytes"],
                    path: "\(operationPath).x-kist-maximum-request-bytes",
                    defaultValue: 1 * 1_024 * 1_024,
                    allowed: 1...SMLHTTPEndpointValidation.maximumRequestBytes)
                let requestBody = try requestBody(
                    operation["requestBody"],
                    root: root,
                    path: "\(operationPath).requestBody",
                    maximumBytes: maximumRequestBytes,
                    usedStateFields: &usedStateFields)
                let responseField = SMLWorkflowOpenAPIImportSupport.uniqueStateField(
                    "response_body", original: "response:\(operationID)", used: &usedStateFields)
                let timeout = try boundedDouble(
                    operation["x-kist-timeout-seconds"],
                    path: "\(operationPath).x-kist-timeout-seconds",
                    defaultValue: 30, allowed: 0.1...60)
                let responseLimit = try boundedInteger(
                    operation["x-kist-maximum-response-bytes"],
                    path: "\(operationPath).x-kist-maximum-response-bytes",
                    defaultValue: SMLHTTPEndpointValidation.maximumResponseBytes,
                    allowed: 1...SMLHTTPEndpointValidation.maximumResponseBytes)
                let authValue = operation["security"] ?? root["security"]
                let authentication = try authenticationRequirements(
                    authValue, apiID: apiID, root: root, path: "\(operationPath).security")

                let endpoint = SMLHTTPEndpointSpec(
                    capability: operationID,
                    method: method,
                    pathTemplate: pathTemplate,
                    servers: servers,
                    parameters: endpointParameters,
                    requestBody: requestBody,
                    authentication: authentication,
                    responseStateField: responseField,
                    timeoutSeconds: timeout,
                    maximumResponseBytes: responseLimit)
                let singleBundle = SMLHTTPEndpointBundle(
                    apiID: apiID, sourceDigest: sourceDigest, endpoints: [endpoint])
                try SMLHTTPEndpointValidation.validate(singleBundle)
                endpoints.append(endpoint)
                workflows.append(try wrapperWorkflow(
                    endpoint: endpoint,
                    apiID: apiID,
                    apiTitle: title,
                    sourceReference: sourceReference,
                    sourceDigest: sourceDigest))
            }
        }

        guard !endpoints.isEmpty else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: "$.paths", reason: "no supported operations were found")
        }
        let bundle = SMLHTTPEndpointBundle(
            apiID: apiID, sourceDigest: sourceDigest, endpoints: endpoints)
        try SMLHTTPEndpointValidation.validate(bundle)
        return SMLWorkflowOpenAPIImportResult(
            endpointBundle: bundle,
            proposedCatalog: SMLHTTPProposedCatalogFragment(
                apiID: apiID,
                sourceDigest: sourceDigest,
                toolCapabilities: endpoints.map(\.capability)),
            wrapperWorkflows: workflows.sorted { $0.id < $1.id })
    }

    private static func parameters(
        _ value: SMLValue?,
        root: SMLObject,
        path: String
    ) throws -> [ParsedParameter] {
        guard let value else { return [] }
        let entries = try SMLWorkflowOpenAPIImportSupport.array(value, path: path)
        guard entries.count <= 128 else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "too many parameters")
        }
        var result: [ParsedParameter] = []
        var seen = Set<String>()
        for (index, value) in entries.enumerated() {
            let itemPath = "\(path)[\(index)]"
            let object = try SMLWorkflowOpenAPIImportSupport.resolvedObject(
                value, root: root, path: itemPath)
            try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
                object,
                path: itemPath,
                allowed: ["name", "in", "description", "required", "deprecated",
                          "allowEmptyValue", "style", "explode", "allowReserved", "schema",
                          "example", "examples", "content"])
            guard object["content"] == nil else {
                throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                    path: itemPath, reason: "content-based parameters are not supported")
            }
            let name = try SMLWorkflowOpenAPIImportSupport.string(
                object["name"], path: "\(itemPath).name")
            let locationName = try SMLWorkflowOpenAPIImportSupport.string(
                object["in"], path: "\(itemPath).in")
            guard let location = SMLHTTPParameterLocation(rawValue: locationName) else {
                throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                    path: "\(itemPath).in",
                    reason: "only path, query, and non-secret header parameters are supported")
            }
            let declaredRequired = try SMLWorkflowOpenAPIImportSupport.optionalBool(
                object["required"], path: "\(itemPath).required") ?? false
            guard location != .path || declaredRequired else {
                throw SMLWorkflowOpenAPIImportError.invalidDocument(
                    path: "\(itemPath).required", reason: "path parameters must be required")
            }
            if location == .header {
                guard SMLHTTPEndpointValidation.validHeaderName(name),
                      !SMLHTTPEndpointValidation.reservedHeader(name) else {
                    throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                        path: "\(itemPath).name", reason: "reserved or invalid header name")
                }
            }
            if try SMLWorkflowOpenAPIImportSupport.optionalBool(
                object["allowReserved"], path: "\(itemPath).allowReserved") == true {
                throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                    path: itemPath, reason: "allowReserved query values are refused")
            }
            let valueType = try SMLWorkflowOpenAPIImportSupport.schemaStateType(
                object["schema"], root: root, path: "\(itemPath).schema")
            guard location == .query || valueType != .array,
                  valueType != .object else {
                throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                    path: itemPath,
                    reason: "objects and non-query arrays are not supported as parameters")
            }
            let style = try optionalString(object["style"], path: "\(itemPath).style")
                ?? (location == .query ? "form" : "simple")
            guard (location == .query && style == "form")
                    || (location != .query && style == "simple") else {
                throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                    path: itemPath, reason: "unsupported parameter serialization style '\(style)'")
            }
            let explode = try SMLWorkflowOpenAPIImportSupport.optionalBool(
                object["explode"], path: "\(itemPath).explode") ?? (location == .query)
            let parameter = ParsedParameter(
                name: name,
                location: location,
                required: location == .path || declaredRequired,
                valueType: valueType,
                explode: explode)
            guard seen.insert(parameter.identity).inserted else {
                throw SMLWorkflowOpenAPIImportError.invalidDocument(
                    path: itemPath, reason: "duplicate parameter '\(parameter.identity)'")
            }
            result.append(parameter)
        }
        return result
    }

    private static func requestBody(
        _ value: SMLValue?,
        root: SMLObject,
        path: String,
        maximumBytes: Int,
        usedStateFields: inout Set<String>
    ) throws -> SMLHTTPRequestBodySpec? {
        guard let value else { return nil }
        let object = try SMLWorkflowOpenAPIImportSupport.resolvedObject(
            value, root: root, path: path)
        try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
            object, path: path, allowed: ["description", "content", "required"])
        let content = try SMLWorkflowOpenAPIImportSupport.object(
            object["content"], path: "\(path).content")
        guard !content.isEmpty, content.count <= 32 else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: "\(path).content", reason: "content must contain 1...32 media types")
        }
        let jsonMediaType = content.keys.sorted().first {
            let lower = $0.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            return lower == "application/json" || lower.hasSuffix("+json")
        }
        guard let jsonMediaType else {
            throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                path: "\(path).content", reason: "request bodies must offer a JSON media type")
        }
        let media = try SMLWorkflowOpenAPIImportSupport.object(
            content[jsonMediaType], path: "\(path).content.\(jsonMediaType)")
        try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
            media,
            path: "\(path).content.\(jsonMediaType)",
            allowed: ["schema", "example", "examples", "encoding"])
        let type = try SMLWorkflowOpenAPIImportSupport.schemaStateType(
            media["schema"], root: root, path: "\(path).content.\(jsonMediaType).schema",
            default: .object)
        let stateField = SMLWorkflowOpenAPIImportSupport.uniqueStateField(
            "request_body", original: path, used: &usedStateFields)
        return SMLHTTPRequestBodySpec(
            required: try SMLWorkflowOpenAPIImportSupport.optionalBool(
                object["required"], path: "\(path).required") ?? false,
            stateField: stateField,
            valueType: type,
            maximumBytes: maximumBytes)
    }

    private static func authenticationRequirements(
        _ value: SMLValue?,
        apiID: String,
        root: SMLObject,
        path: String
    ) throws -> [SMLHTTPAuthenticationRequirement] {
        guard let value else { return [] }
        let alternatives = try SMLWorkflowOpenAPIImportSupport.array(value, path: path)
        guard alternatives.count <= 16 else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "too many security alternatives")
        }
        let components = try optionalObject(root["components"], path: "$.components") ?? [:]
        let definitions = try optionalObject(
            components["securitySchemes"], path: "$.components.securitySchemes") ?? [:]
        var result: [SMLHTTPAuthenticationRequirement] = []
        for (index, alternativeValue) in alternatives.enumerated() {
            let itemPath = "\(path)[\(index)]"
            let alternative = try SMLWorkflowOpenAPIImportSupport.object(
                alternativeValue, path: itemPath)
            var schemes: [SMLHTTPAuthenticationSchemeSpec] = []
            for schemeName in alternative.keys.sorted() {
                guard SMLValidationSupport.identifierIsValid(schemeName, maximumLength: 96) else {
                    throw SMLWorkflowOpenAPIImportError.invalidDocument(
                        path: "\(itemPath).\(schemeName)", reason: "invalid security scheme name")
                }
                guard let definitionValue = definitions[schemeName] else {
                    throw SMLWorkflowOpenAPIImportError.unresolvedReference(
                        path: "\(itemPath).\(schemeName)",
                        reference: "#/components/securitySchemes/\(schemeName)")
                }
                let definition = try SMLWorkflowOpenAPIImportSupport.resolvedObject(
                    definitionValue, root: root,
                    path: "$.components.securitySchemes.\(schemeName)")
                let type = try SMLWorkflowOpenAPIImportSupport.string(
                    definition["type"], path: "$.components.securitySchemes.\(schemeName).type")
                let credentialID = "\(apiID).\(schemeName)"
                guard SMLValidationSupport.identifierIsValid(credentialID) else {
                    throw SMLWorkflowOpenAPIImportError.invalidDocument(
                        path: "\(itemPath).\(schemeName)", reason: "credential id exceeds SML limits")
                }
                let scopes = try stringArray(
                    alternative[schemeName], path: "\(itemPath).\(schemeName)")
                let scheme: SMLHTTPAuthenticationSchemeSpec
                switch type {
                case "apiKey":
                    try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
                        definition,
                        path: "$.components.securitySchemes.\(schemeName)",
                        allowed: ["type", "description", "name", "in"])
                    let location = try SMLWorkflowOpenAPIImportSupport.string(
                        definition["in"], path: "$.components.securitySchemes.\(schemeName).in")
                    guard location == "header" else {
                        throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                            path: "\(itemPath).\(schemeName)",
                            reason: "API keys in query strings or cookies are refused")
                    }
                    let header = try SMLWorkflowOpenAPIImportSupport.string(
                        definition["name"], path: "$.components.securitySchemes.\(schemeName).name")
                    guard SMLHTTPEndpointValidation.validHeaderName(header),
                          !SMLHTTPEndpointValidation.reservedHeader(header), scopes.isEmpty else {
                        throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                            path: "\(itemPath).\(schemeName)", reason: "invalid API-key scheme")
                    }
                    scheme = .init(
                        credentialID: credentialID, kind: .apiKeyHeader, headerName: header)
                case "http":
                    try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
                        definition,
                        path: "$.components.securitySchemes.\(schemeName)",
                        allowed: ["type", "description", "scheme", "bearerFormat"])
                    let httpScheme = try SMLWorkflowOpenAPIImportSupport.string(
                        definition["scheme"], path: "$.components.securitySchemes.\(schemeName).scheme")
                        .lowercased()
                    guard scopes.isEmpty, httpScheme == "bearer" || httpScheme == "basic" else {
                        throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                            path: "\(itemPath).\(schemeName)",
                            reason: "only HTTP bearer and basic authentication are supported")
                    }
                    scheme = .init(
                        credentialID: credentialID,
                        kind: httpScheme == "bearer" ? .bearer : .basic)
                case "oauth2":
                    try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
                        definition,
                        path: "$.components.securitySchemes.\(schemeName)",
                        allowed: ["type", "description", "flows"])
                    let declaredScopes = try oauth2Scopes(
                        definition["flows"],
                        path: "$.components.securitySchemes.\(schemeName).flows")
                    guard declaredScopes.isSuperset(of: scopes) else {
                        throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                            path: "\(itemPath).\(schemeName)",
                            reason: "security requirement asks for an undeclared OAuth scope")
                    }
                    scheme = .init(
                        credentialID: credentialID,
                        kind: .oauth2Bearer,
                        requiredScopes: scopes)
                case "openIdConnect":
                    try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
                        definition,
                        path: "$.components.securitySchemes.\(schemeName)",
                        allowed: ["type", "description", "openIdConnectUrl"])
                    let discoveryURL = try SMLWorkflowOpenAPIImportSupport.string(
                        definition["openIdConnectUrl"],
                        path: "$.components.securitySchemes.\(schemeName).openIdConnectUrl")
                    guard discoveryURL.utf8.count <= 2_048 else {
                        throw SMLWorkflowOpenAPIImportError.invalidDocument(
                            path: "$.components.securitySchemes.\(schemeName).openIdConnectUrl",
                            reason: "URL exceeds 2048 bytes")
                    }
                    scheme = .init(
                        credentialID: credentialID,
                        kind: .openIDBearer,
                        requiredScopes: scopes)
                default:
                    throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                        path: "\(itemPath).\(schemeName)",
                        reason: "security scheme type '\(type)' is not supported")
                }
                schemes.append(scheme)
            }
            result.append(SMLHTTPAuthenticationRequirement(schemes: schemes))
        }
        return result
    }

    private static func oauth2Scopes(
        _ value: SMLValue?,
        path: String
    ) throws -> Set<String> {
        let flows = try SMLWorkflowOpenAPIImportSupport.object(value, path: path)
        let flowNames: Set<String> = [
            "implicit", "password", "clientCredentials", "authorizationCode",
        ]
        try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
            flows, path: path, allowed: flowNames)
        guard !flows.isEmpty else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "OAuth flows must not be empty")
        }
        var declared = Set<String>()
        for name in flows.keys.sorted() {
            let flowPath = "\(path).\(name)"
            let flow = try SMLWorkflowOpenAPIImportSupport.object(
                flows[name], path: flowPath)
            let requiredURLs: Set<String>
            switch name {
            case "implicit": requiredURLs = ["authorizationUrl"]
            case "password", "clientCredentials": requiredURLs = ["tokenUrl"]
            case "authorizationCode": requiredURLs = ["authorizationUrl", "tokenUrl"]
            default: requiredURLs = []
            }
            try SMLWorkflowOpenAPIImportSupport.requireKnownKeys(
                flow,
                path: flowPath,
                allowed: requiredURLs.union(["refreshUrl", "scopes"]))
            for key in requiredURLs {
                let url = try SMLWorkflowOpenAPIImportSupport.string(
                    flow[key], path: "\(flowPath).\(key)")
                guard url.utf8.count <= 2_048 else {
                    throw SMLWorkflowOpenAPIImportError.invalidDocument(
                        path: "\(flowPath).\(key)", reason: "URL exceeds 2048 bytes")
                }
            }
            let scopes = try SMLWorkflowOpenAPIImportSupport.object(
                flow["scopes"], path: "\(flowPath).scopes")
            guard scopes.count <= 1_024 else {
                throw SMLWorkflowOpenAPIImportError.invalidDocument(
                    path: "\(flowPath).scopes", reason: "too many OAuth scopes")
            }
            for scope in scopes.keys.sorted() {
                guard !scope.isEmpty, scope.utf8.count <= 256,
                      case .string? = scopes[scope] else {
                    throw SMLWorkflowOpenAPIImportError.invalidDocument(
                        path: "\(flowPath).scopes", reason: "invalid OAuth scope map")
                }
                declared.insert(scope)
            }
        }
        return declared
    }

    private static func wrapperWorkflow(
        endpoint: SMLHTTPEndpointSpec,
        apiID: String,
        apiTitle: String,
        sourceReference: String,
        sourceDigest: String
    ) throws -> SMLWorkflow {
        var fields = endpoint.parameters.map {
            SMLStateField(
                name: $0.stateField,
                type: $0.valueType,
                required: $0.required,
                description: "OpenAPI \($0.location.rawValue) parameter '\($0.name)'")
        }
        var inputs = endpoint.parameters.map(\.stateField)
        if let body = endpoint.requestBody {
            fields.append(.init(
                name: body.stateField,
                type: body.valueType,
                required: body.required,
                description: "OpenAPI JSON request body"))
            inputs.append(body.stateField)
        }
        fields.append(.init(
            name: endpoint.responseStateField,
            type: .string,
            required: false,
            description: "Bounded HTTP response body"))
        let rawID = "openapi.\(apiID).\(endpoint.capability)"
        let workflowID: String
        if rawID.count <= 128 {
            workflowID = rawID
        } else {
            workflowID = String(rawID.prefix(119)) + "."
                + SMLWorkflowOpenAPIImportSupport.digestHex(Data(rawID.utf8)).prefix(8)
        }
        let workflow = SMLWorkflow(
            id: workflowID,
            version: "1.0.0+openapi.\(sourceDigest.prefix(8))",
            name: "\(apiTitle) — \(endpoint.capability)",
            source: SMLWorkflowSource(
                kind: .openAPI, reference: sourceReference, digest: sourceDigest),
            trigger: SMLTrigger(kind: .manual),
            stateSchema: fields,
            interface: SMLWorkflowInterface(
                inputFields: inputs,
                outputFields: [endpoint.responseStateField]),
            entrypoint: "request",
            instructions: [
                SMLInstruction(
                    id: "request",
                    op: .callTool,
                    capability: endpoint.capability,
                    arguments: [
                        SMLCapabilityDriverSupport.outputFieldArgument:
                            .string(endpoint.responseStateField),
                    ],
                    next: "receipt"),
                SMLInstruction(
                    id: "receipt",
                    op: .emitReceipt,
                    receiptFields: [endpoint.responseStateField]),
            ])
        return try SMLWorkflowValidator.requireValidForImport(workflow).workflow
    }

    private static func boundedInteger(
        _ value: SMLValue?,
        path: String,
        defaultValue: Int,
        allowed: ClosedRange<Int>
    ) throws -> Int {
        let result = try SMLWorkflowOpenAPIImportSupport.optionalInt(value, path: path)
            ?? defaultValue
        guard allowed.contains(result) else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "value must be in \(allowed)")
        }
        return result
    }

    private static func supportedOpenAPIVersion(_ version: String) -> Bool {
        guard version.utf8.count <= 32 else { return false }
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0] == "3",
              fields[1] == "0" || fields[1] == "1",
              !fields[2].isEmpty,
              fields[2].unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            return false
        }
        return true
    }

    private static func boundedDouble(
        _ value: SMLValue?,
        path: String,
        defaultValue: Double,
        allowed: ClosedRange<Double>
    ) throws -> Double {
        let result = try SMLWorkflowOpenAPIImportSupport.optionalDouble(value, path: path)
            ?? defaultValue
        guard allowed.contains(result) else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "value must be in \(allowed)")
        }
        return result
    }

    private static func optionalString(_ value: SMLValue?, path: String) throws -> String? {
        guard let value else { return nil }
        return try SMLWorkflowOpenAPIImportSupport.string(value, path: path)
    }

    private static func optionalObject(_ value: SMLValue?, path: String) throws -> SMLObject? {
        guard let value else { return nil }
        return try SMLWorkflowOpenAPIImportSupport.object(value, path: path)
    }

    private static func stringArray(_ value: SMLValue?, path: String) throws -> [String] {
        let values = try SMLWorkflowOpenAPIImportSupport.array(value, path: path)
        guard values.count <= 128 else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "array exceeds 128 entries")
        }
        let strings = try values.enumerated().map {
            try SMLWorkflowOpenAPIImportSupport.string(
                $0.element, path: "\(path)[\($0.offset)]")
        }
        guard Set(strings).count == strings.count else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "array contains duplicates")
        }
        return strings.sorted()
    }
}
