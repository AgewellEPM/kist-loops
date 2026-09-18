import Foundation

/// Host-only credentials for imported HTTP endpoints. Values never appear in endpoint bundles,
/// workflow IR, evidence payloads, errors, or catalog proposals.
public struct SMLHTTPAuthenticationStore: Sendable {
    public static let schemaVersion = 1
    public static let relativePath = ".kist/sml/http-auth.json"
    private static let maximumBytes = 1 * 1_024 * 1_024

    struct Credential: Sendable {
        let value: String?
        let username: String?
        let password: String?
        let scopes: Set<String>
    }

    private let credentials: [String: Credential]

    public init() {
        credentials = [:]
    }

    init(credentials: [String: Credential]) {
        self.credentials = credentials
    }

    public enum LoadError: Error, Sendable, Equatable, CustomStringConvertible {
        case unsafeFile(String)
        case malformed(String)
        case unsupportedSchemaVersion(Int)

        public var description: String {
            switch self {
            case .unsafeFile(let path):
                return "SML HTTP authentication file is unsafe or unreadable: \(path); "
                    + "it must be one owner-only 0600 regular file"
            case .malformed(let reason):
                return "SML HTTP authentication file is malformed: \(reason)"
            case .unsupportedSchemaVersion(let version):
                return "SML HTTP authentication schema_version \(version) is unsupported "
                    + "(expected \(schemaVersion))"
            }
        }
    }

    public static func load(projectRoot: String) throws -> SMLHTTPAuthenticationStore {
        let path = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .appendingPathComponent(relativePath).path
        let data: Data
        do {
            let root = try ConfinedRoot(root: projectRoot, readOnly: true)
            data = try root.readStableOwnerOnlyData(
                relativePath, maxBytes: maximumBytes, permissions: 0o600)
        } catch ToolError.notFound {
            return SMLHTTPAuthenticationStore()
        } catch {
            throw LoadError.unsafeFile(path)
        }
        let root: SMLObject
        do { root = try SMLWireCodec.decodeArbitraryJSONObject(from: data) }
        catch { throw LoadError.malformed(String(describing: error)) }
        let allowedRoot: Set<String> = ["schema_version", "credentials"]
        guard root.keys.allSatisfy(allowedRoot.contains),
              case .number(let versionValue)? = root["schema_version"],
              let version = exactInt(versionValue) else {
            throw LoadError.malformed("expected schema_version and credentials only")
        }
        guard version == schemaVersion else { throw LoadError.unsupportedSchemaVersion(version) }
        guard case .object(let rawCredentials)? = root["credentials"],
              rawCredentials.count <= 256 else {
            throw LoadError.malformed("credentials must be an object with at most 256 entries")
        }
        var decoded: [String: Credential] = [:]
        for id in rawCredentials.keys.sorted() {
            guard SMLValidationSupport.identifierIsValid(id),
                  case .object(let entry)? = rawCredentials[id],
                  entry.keys.allSatisfy({
                    ["value", "username", "password", "scopes"].contains($0)
                  }) else {
                throw LoadError.malformed("credential ids and fields must use the documented schema")
            }
            let value = try optionalSecret(
                entry["value"], label: "value", visibleASCIIOnly: true)
            let username = try optionalSecret(entry["username"], label: "username")
            let password = try optionalSecret(entry["password"], label: "password")
            let hasValue = value != nil && username == nil && password == nil
            let hasBasic = value == nil && username != nil && password != nil
            guard hasValue || hasBasic, username?.contains(":") != true else {
                throw LoadError.malformed(
                    "credential '\(id)' must contain either value or username+password")
            }
            var scopes = Set<String>()
            if let scopeValue = entry["scopes"] {
                guard case .array(let values) = scopeValue, values.count <= 128 else {
                    throw LoadError.malformed("credential '\(id)' scopes must be a bounded array")
                }
                for value in values {
                    guard case .string(let scope) = value,
                          !scope.isEmpty, scope.utf8.count <= 256,
                          !scope.unicodeScalars.contains(where: {
                              $0.value < 0x20 || $0.value == 0x7f
                                  || ($0.value >= 0x80 && $0.value <= 0x9f)
                          }),
                          scopes.insert(scope).inserted else {
                        throw LoadError.malformed("credential '\(id)' contains invalid scopes")
                    }
                }
            }
            decoded[id] = Credential(
                value: value, username: username, password: password, scopes: scopes)
        }
        return SMLHTTPAuthenticationStore(credentials: decoded)
    }

    /// Resolve one OpenAPI OR-alternative at launch time. No operation is routed if its required
    /// credential set is incomplete, kind-mismatched, or lacks a declared OAuth scope.
    func headers(
        for endpoint: SMLHTTPEndpointSpec
    ) throws -> [String: String] {
        guard !endpoint.authentication.isEmpty else { return [:] }
        for requirement in endpoint.authentication {
            if requirement.schemes.isEmpty { return [:] }
            var candidate: [String: String] = [:]
            var lowerNames = Set<String>()
            var complete = true
            for scheme in requirement.schemes {
                guard let credential = credentials[scheme.credentialID],
                      credential.scopes.isSuperset(of: scheme.requiredScopes) else {
                    complete = false
                    break
                }
                let header: (String, String)?
                switch scheme.kind {
                case .apiKeyHeader:
                    guard let name = scheme.headerName, let value = credential.value else {
                        complete = false; header = nil; break
                    }
                    header = (name, value)
                case .bearer, .oauth2Bearer, .openIDBearer:
                    guard let value = credential.value else {
                        complete = false; header = nil; break
                    }
                    header = ("Authorization", "Bearer \(value)")
                case .basic:
                    guard let username = credential.username, let password = credential.password else {
                        complete = false; header = nil; break
                    }
                    let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
                    header = ("Authorization", "Basic \(encoded)")
                }
                guard complete, let header,
                      lowerNames.insert(header.0.lowercased()).inserted else {
                    complete = false
                    break
                }
                candidate[header.0] = header.1
            }
            if complete { return candidate }
        }
        throw SMLHTTPExecutionError.missingCredentials(endpoint.capability)
    }

    private static func optionalSecret(
        _ value: SMLValue?,
        label: String,
        visibleASCIIOnly: Bool = false
    ) throws -> String? {
        guard let value else { return nil }
        guard case .string(let secret) = value,
              !secret.isEmpty, secret.utf8.count <= 16_384,
              secret.unicodeScalars.allSatisfy({ scalar in
                scalar.value >= 0x20 && scalar.value != 0x7f
                    && !(scalar.value >= 0x80 && scalar.value <= 0x9f)
                    && (!visibleASCIIOnly || scalar.value <= 0x7e)
              }) else {
            throw LoadError.malformed(
                "credential \(label) is empty, oversized, or contains unsupported characters")
        }
        return secret
    }

    private static func exactInt(_ decimal: Decimal) -> Int? {
        guard decimal.isFinite,
              decimal >= Decimal(Int.min), decimal <= Decimal(Int.max) else { return nil }
        var input = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard input == rounded else { return nil }
        return NSDecimalNumber(decimal: input).intValue
    }

}
