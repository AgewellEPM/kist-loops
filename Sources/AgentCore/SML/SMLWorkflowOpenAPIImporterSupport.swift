import Foundation

public enum SMLWorkflowOpenAPIImportError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case invalidDocument(path: String, reason: String)
    case unsupportedVersion(String)
    case unresolvedReference(path: String, reference: String)
    case unsupportedReference(path: String, reference: String)
    case duplicateOperationID(String)
    case unsupportedOperation(path: String, reason: String)

    public var description: String {
        switch self {
        case .invalidDocument(let path, let reason):
            return "invalid OpenAPI document at \(path): \(reason)"
        case .unsupportedVersion(let version):
            return "unsupported OpenAPI version '\(version)' (expected 3.0.x or 3.1.x)"
        case .unresolvedReference(let path, let reference):
            return "unresolved OpenAPI reference '\(reference)' at \(path)"
        case .unsupportedReference(let path, let reference):
            return "unsupported OpenAPI reference '\(reference)' at \(path); only local #/ references are accepted"
        case .duplicateOperationID(let id):
            return "OpenAPI operationId '\(id)' is duplicated"
        case .unsupportedOperation(let path, let reason):
            return "unsupported OpenAPI operation at \(path): \(reason)"
        }
    }
}

enum SMLWorkflowOpenAPIImportSupport {
    static func object(_ value: SMLValue?, path: String) throws -> SMLObject {
        guard case .object(let object)? = value else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "expected object")
        }
        return object
    }

    static func array(_ value: SMLValue?, path: String) throws -> [SMLValue] {
        guard case .array(let values)? = value else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "expected array")
        }
        return values
    }

    static func string(_ value: SMLValue?, path: String) throws -> String {
        guard case .string(let string)? = value,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "expected nonempty string")
        }
        return string
    }

    static func optionalBool(_ value: SMLValue?, path: String) throws -> Bool? {
        guard let value else { return nil }
        guard case .bool(let bool) = value else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "expected boolean")
        }
        return bool
    }

    static func optionalInt(_ value: SMLValue?, path: String) throws -> Int? {
        guard let value else { return nil }
        guard case .number(let number) = value,
              number.isFinite,
              number >= Decimal(Int.min), number <= Decimal(Int.max) else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "expected integer")
        }
        var input = number
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard rounded == number else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "expected integer")
        }
        return NSDecimalNumber(decimal: number).intValue
    }

    static func optionalDouble(_ value: SMLValue?, path: String) throws -> Double? {
        guard let value else { return nil }
        guard case .number(let number) = value, number.isFinite else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "expected finite number")
        }
        return NSDecimalNumber(decimal: number).doubleValue
    }

    static func requireKnownKeys(
        _ object: SMLObject,
        path: String,
        allowed: Set<String>
    ) throws {
        if let unknown = object.keys.sorted().first(where: {
            !allowed.contains($0) && !$0.hasPrefix("x-")
        }) {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: "\(path).\(unknown)", reason: "unknown member")
        }
    }

    static func resolvedObject(
        _ value: SMLValue?,
        root: SMLObject,
        path: String
    ) throws -> SMLObject {
        let decodedObject = try object(value, path: path)
        guard let referenceValue = decodedObject["$ref"] else { return decodedObject }
        guard decodedObject.count == 1 else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "$ref objects may not carry ambiguous siblings")
        }
        let reference = try string(referenceValue, path: "\(path).$ref")
        return try object(resolve(reference, root: root, path: "\(path).$ref"), path: reference)
    }

    static func validateAllReferences(in root: SMLObject) throws {
        var visited = Set<String>()
        var active = Set<String>()
        var count = 0

        func walk(_ value: SMLValue, path: String) throws {
            switch value {
            case .object(let object):
                if let referenceValue = object["$ref"] {
                    let reference = try string(referenceValue, path: "\(path).$ref")
                    count += 1
                    guard count <= 4_096 else {
                        throw SMLWorkflowOpenAPIImportError.invalidDocument(
                            path: path, reason: "too many references")
                    }
                    let target = try resolve(reference, root: root, path: "\(path).$ref")
                    if !visited.contains(reference), !active.contains(reference) {
                        active.insert(reference)
                        try walk(target, path: reference)
                        active.remove(reference)
                        visited.insert(reference)
                    }
                }
                for key in object.keys.sorted() where key != "$ref" {
                    try walk(object[key]!, path: "\(path).\(key)")
                }
            case .array(let values):
                for (index, value) in values.enumerated() {
                    try walk(value, path: "\(path)[\(index)]")
                }
            case .null, .bool, .number, .string:
                break
            }
        }

        try walk(.object(root), path: "$")
    }

    static func resolve(_ reference: String, root: SMLObject, path: String) throws -> SMLValue {
        guard reference.hasPrefix("#/") else {
            throw SMLWorkflowOpenAPIImportError.unsupportedReference(
                path: path, reference: reference)
        }
        guard let decoded = reference.removingPercentEncoding, decoded.hasPrefix("#/") else {
            throw SMLWorkflowOpenAPIImportError.unresolvedReference(
                path: path, reference: reference)
        }
        var current: SMLValue = .object(root)
        for raw in decoded.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let token = try decodeJSONPointerToken(String(raw), path: path)
            switch current {
            case .object(let object):
                guard let next = object[token] else {
                    throw SMLWorkflowOpenAPIImportError.unresolvedReference(
                        path: path, reference: reference)
                }
                current = next
            case .array(let values):
                guard let index = Int(token), values.indices.contains(index) else {
                    throw SMLWorkflowOpenAPIImportError.unresolvedReference(
                        path: path, reference: reference)
                }
                current = values[index]
            default:
                throw SMLWorkflowOpenAPIImportError.unresolvedReference(
                    path: path, reference: reference)
            }
        }
        return current
    }

    private static func decodeJSONPointerToken(_ raw: String, path: String) throws -> String {
        var output = ""
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            if raw[cursor] != "~" {
                output.append(raw[cursor])
                cursor = raw.index(after: cursor)
                continue
            }
            let next = raw.index(after: cursor)
            guard next < raw.endIndex else {
                throw SMLWorkflowOpenAPIImportError.invalidDocument(
                    path: path, reason: "invalid JSON Pointer escape")
            }
            if raw[next] == "0" { output.append("~") }
            else if raw[next] == "1" { output.append("/") }
            else {
                throw SMLWorkflowOpenAPIImportError.invalidDocument(
                    path: path, reason: "invalid JSON Pointer escape")
            }
            cursor = raw.index(after: next)
        }
        return output
    }

    static func servers(
        _ value: SMLValue?,
        root: SMLObject,
        path: String
    ) throws -> [SMLHTTPServerSpec] {
        guard let value else { return [] }
        let entries = try array(value, path: path)
        guard !entries.isEmpty, entries.count <= 16 else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "servers must contain 1...16 entries")
        }
        var seen = Set<String>()
        var result: [SMLHTTPServerSpec] = []
        for (index, value) in entries.enumerated() {
            let itemPath = "\(path)[\(index)]"
            let object = try resolvedObject(value, root: root, path: itemPath)
            try requireKnownKeys(object, path: itemPath,
                                 allowed: ["url", "description", "variables"])
            var url = try string(object["url"], path: "\(itemPath).url")
            let variables = try serverVariables(object["variables"], path: "\(itemPath).variables")
            for name in placeholders(in: url) {
                guard let replacement = variables[name] else {
                    throw SMLWorkflowOpenAPIImportError.invalidDocument(
                        path: "\(itemPath).url", reason: "server variable '\(name)' has no default")
                }
                url = url.replacingOccurrences(of: "{\(name)}", with: replacement)
            }
            guard !url.contains("{"), !url.contains("}") else {
                throw SMLWorkflowOpenAPIImportError.invalidDocument(
                    path: "\(itemPath).url", reason: "malformed server variable")
            }
            let server = try normalizedServer(url, path: "\(itemPath).url")
            let key = "\(server.origin)\(server.basePath)"
            if seen.insert(key).inserted { result.append(server) }
        }
        return result
    }

    private static func serverVariables(
        _ value: SMLValue?, path: String
    ) throws -> [String: String] {
        guard let value else { return [:] }
        let values = try object(value, path: path)
        guard values.count <= 32 else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "too many server variables")
        }
        var output: [String: String] = [:]
        for name in values.keys.sorted() {
            guard SMLValidationSupport.identifierIsValid(name, maximumLength: 64, allowDot: false) else {
                throw SMLWorkflowOpenAPIImportError.invalidDocument(
                    path: "\(path).\(name)", reason: "invalid server variable name")
            }
            let entry = try object(values[name], path: "\(path).\(name)")
            try requireKnownKeys(entry, path: "\(path).\(name)",
                                 allowed: ["default", "enum", "description"])
            let value = try string(entry["default"], path: "\(path).\(name).default")
            guard value.utf8.count <= 512 else {
                throw SMLWorkflowOpenAPIImportError.invalidDocument(
                    path: "\(path).\(name).default", reason: "value is too large")
            }
            if let enumValue = entry["enum"] {
                let candidates = try array(enumValue, path: "\(path).\(name).enum")
                guard !candidates.isEmpty, candidates.count <= 128 else {
                    throw SMLWorkflowOpenAPIImportError.invalidDocument(
                        path: "\(path).\(name).enum", reason: "enum must contain 1...128 values")
                }
                let allowed = try Set(candidates.enumerated().map {
                    try string($0.element, path: "\(path).\(name).enum[\($0.offset)]")
                })
                guard allowed.contains(value) else {
                    throw SMLWorkflowOpenAPIImportError.invalidDocument(
                        path: "\(path).\(name).default", reason: "default is not in enum")
                }
            }
            output[name] = value
        }
        return output
    }

    private static func normalizedServer(_ raw: String, path: String) throws -> SMLHTTPServerSpec {
        guard raw.utf8.count <= 2_048,
              let components = URLComponents(string: raw),
              let rawScheme = components.scheme,
              let rawHost = components.host,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "server URL must be an absolute origin with no credentials, query, or fragment")
        }
        let scheme = rawScheme.lowercased()
        let host = rawHost.lowercased()
        let loopback = host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "remote HTTP is refused; use HTTPS (plain HTTP is loopback-only)")
        }
        guard !components.percentEncodedPath.contains("%") else {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "percent-encoded server base paths are refused")
        }
        var basePath = components.path
        while basePath.count > 1 && basePath.hasSuffix("/") { basePath.removeLast() }
        if basePath == "/" { basePath = "" }
        var port = components.port
        if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
            port = nil
        }
        let server = SMLHTTPServerSpec(scheme: scheme, host: host, port: port, basePath: basePath)
        do {
            try SMLHTTPEndpointValidation.validate(
                SMLHTTPEndpointBundle(
                    apiID: "server.probe",
                    sourceDigest: String(repeating: "0", count: 64),
                    endpoints: [SMLHTTPEndpointSpec(
                        capability: "server.probe", method: .get, pathTemplate: "/probe",
                        servers: [server], timeoutSeconds: 1, maximumResponseBytes: 1)]))
        } catch {
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: path, reason: "server URL is not a valid pinned origin")
        }
        return server
    }

    static func schemaStateType(
        _ value: SMLValue?,
        root: SMLObject,
        path: String,
        default defaultType: SMLStateType = .string
    ) throws -> SMLStateType {
        guard let value else { return defaultType }
        let schema = try resolvedObject(value, root: root, path: path)
        guard let typeValue = schema["type"] else { return defaultType }
        let typeName: String
        switch typeValue {
        case .string(let string): typeName = string
        case .array(let values):
            let names = try values.map { try string($0, path: "\(path).type[]") }
                .filter { $0 != "null" }
            guard names.count == 1 else {
                throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                    path: path, reason: "union parameter/body schemas are not supported")
            }
            typeName = names[0]
        default:
            throw SMLWorkflowOpenAPIImportError.invalidDocument(
                path: "\(path).type", reason: "expected schema type string")
        }
        guard let type = SMLStateType(rawValue: typeName) else {
            throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                path: path, reason: "schema type '\(typeName)' is not supported")
        }
        if type == .array {
            let itemType = try schemaStateType(
                schema["items"], root: root, path: "\(path).items")
            guard itemType != .array && itemType != .object else {
                throw SMLWorkflowOpenAPIImportError.unsupportedOperation(
                    path: path, reason: "only scalar arrays are supported for HTTP parameters")
            }
        }
        return type
    }

    static func stableStateField(
        location: SMLHTTPParameterLocation,
        name: String,
        used: inout Set<String>
    ) -> String {
        let normalized = normalizedIdentifier(name)
        let base = "\(location.rawValue)_\(normalized)"
        return uniqueStateField(base, original: "\(location.rawValue):\(name)", used: &used)
    }

    static func uniqueStateField(
        _ requested: String,
        original: String,
        used: inout Set<String>
    ) -> String {
        let limited = String(requested.prefix(112))
        if used.insert(limited).inserted { return limited }
        let suffix = digestHex(Data(original.utf8)).prefix(8)
        let candidate = String(limited.prefix(103)) + "_" + suffix
        used.insert(candidate)
        return candidate
    }

    static func normalizedIdentifier(_ value: String) -> String {
        var output = ""
        var previousUnderscore = false
        for scalar in value.unicodeScalars {
            let allowed = (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
                || scalar == "_" || scalar == "-"
            if allowed {
                output.unicodeScalars.append(scalar)
                previousUnderscore = false
            } else if !previousUnderscore {
                output.append("_")
                previousUnderscore = true
            }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "value" : trimmed
    }

    static func digestHex(_ data: Data) -> String {
        MythosCrypto.sha256(data).map { String(format: "%02x", $0) }.joined()
    }

    private static func placeholders(in value: String) -> [String] {
        var output: [String] = []
        var cursor = value.startIndex
        while let open = value[cursor...].firstIndex(of: "{") {
            guard let close = value[open...].firstIndex(of: "}") else { break }
            output.append(String(value[value.index(after: open)..<close]))
            cursor = value.index(after: close)
        }
        return output
    }
}
