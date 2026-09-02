import Foundation

/// Host-side authority grants for durable SML runtime hosts, loaded from
/// `<projectRoot>/.kist/sml/authority.json`. This file is the ONLY source of live-host authority:
/// the offline export path's resolver echoes each command's own role/task/op back (a deliberate
/// rubber stamp for install proof — see `withSMLRuntimeHostLaunch`), which must never drive real
/// capability execution. Grants live in a host-owned file rather than on the wire, preserving the
/// `SMLCommandAuthority` invariant that authority cannot arrive inside the command being checked.
///
/// Deny-by-default, no wildcards: an actor absent from the file has no authority; an operation
/// string absent from `SMLRuntimeCommandOperation.all` fails the LOAD (typos surface at startup,
/// not as silent runtime denials); an omitted `scope_template` is the empty object, which admits
/// only commands carrying empty scope (the generated surface compilers' default).
public struct SMLRuntimeAuthorityConfig: Sendable {
    public struct ActorGrant: Sendable {
        public let id: String
        public let roles: Set<String>
        public let operations: Set<String>
        public let approvalAuthorities: Set<String>
        public let scopeTemplate: SMLObject
    }

    public static let schemaVersion = 1
    public static let relativePath = ".kist/sml/authority.json"

    public let actors: [String: ActorGrant]

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case missing(path: String)
        case unreadable(path: String, reason: String)
        case insecurePermissions(path: String, mode: String)
        case notOwnedByProcessUser(path: String)
        case malformed(path: String, reason: String)
        case unsupportedSchemaVersion(Int)
        case invalidActorID(String)
        case duplicateActorID(String)
        case emptyRoles(actor: String)
        case invalidRole(actor: String, role: String)
        case unknownOperation(actor: String, operation: String)
        case invalidApprovalAuthority(actor: String, authority: String)
        case noActors(path: String)

        public var description: String {
            switch self {
            case .missing(let path):
                return "SML host authority file is missing: \(path) — create it with an actors "
                    + "array granting explicit roles/operations before running a durable host"
            case .unreadable(let path, let reason):
                return "SML host authority file is unreadable: \(path) (\(reason))"
            case .insecurePermissions(let path, let mode):
                return "SML host authority file must be owner-only (chmod 600): \(path) has mode \(mode)"
            case .notOwnedByProcessUser(let path):
                return "SML host authority file is not owned by the current user: \(path)"
            case .malformed(let path, let reason):
                return "SML host authority file is malformed: \(path) (\(reason))"
            case .unsupportedSchemaVersion(let version):
                return "SML host authority schema_version \(version) is unsupported (expected \(schemaVersion))"
            case .invalidActorID(let id):
                return "SML host authority actor id is not a valid identifier: '\(id)'"
            case .duplicateActorID(let id):
                return "SML host authority declares actor '\(id)' more than once"
            case .emptyRoles(let actor):
                return "SML host authority actor '\(actor)' grants no roles — deny-by-default "
                    + "means an empty grant is a configuration mistake, not a valid state"
            case .invalidRole(let actor, let role):
                return "SML host authority actor '\(actor)' role is not a valid identifier: '\(role)'"
            case .unknownOperation(let actor, let operation):
                return "SML host authority actor '\(actor)' grants unknown operation '\(operation)' "
                    + "— valid operations: \(SMLRuntimeCommandOperation.all.sorted().joined(separator: ", "))"
            case .invalidApprovalAuthority(let actor, let authority):
                return "SML host authority actor '\(actor)' approval authority is not a valid "
                    + "identifier: '\(authority)'"
            case .noActors(let path):
                return "SML host authority file declares no actors: \(path)"
            }
        }
    }

    public enum ResolutionError: Error, Equatable, CustomStringConvertible {
        case unknownActor(String)

        public var description: String {
            switch self {
            case .unknownActor(let actor):
                return "actor '\(actor)' holds no grants in \(SMLRuntimeAuthorityConfig.relativePath) "
                    + "— durable hosts deny unknown actors by default"
            }
        }
    }

    private struct FileFormat: Decodable {
        struct ActorEntry: Decodable {
            let id: String
            let roles: [String]
            let operations: [String]
            let approvalAuthorities: [String]?
            let scopeTemplate: SMLObject?

            enum CodingKeys: String, CodingKey {
                case id, roles, operations
                case approvalAuthorities = "approval_authorities"
                case scopeTemplate = "scope_template"
            }
        }

        let schemaVersion: Int
        let actors: [ActorEntry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case actors
        }
    }

    public static func defaultURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
    }

    public static func load(projectRoot: String) throws -> SMLRuntimeAuthorityConfig {
        try load(fileURL: defaultURL(projectRoot: projectRoot))
    }

    public static func load(fileURL: URL) throws -> SMLRuntimeAuthorityConfig {
        let path = fileURL.path
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw LoadError.missing(path: path)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw LoadError.unreadable(path: path, reason: "not a regular file")
        }
        guard status.st_uid == geteuid() else {
            throw LoadError.notOwnedByProcessUser(path: path)
        }
        let groupOtherBits = status.st_mode & 0o077
        guard groupOtherBits == 0 else {
            throw LoadError.insecurePermissions(
                path: path,
                mode: String(format: "%03o", status.st_mode & 0o777)
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw LoadError.unreadable(path: path, reason: String(describing: error))
        }
        let decoded: FileFormat
        do {
            decoded = try JSONDecoder().decode(FileFormat.self, from: data)
        } catch {
            throw LoadError.malformed(path: path, reason: String(describing: error))
        }
        guard decoded.schemaVersion == schemaVersion else {
            throw LoadError.unsupportedSchemaVersion(decoded.schemaVersion)
        }
        guard !decoded.actors.isEmpty else {
            throw LoadError.noActors(path: path)
        }

        var actors: [String: ActorGrant] = [:]
        for entry in decoded.actors {
            guard SMLValidationSupport.identifierIsValid(entry.id) else {
                throw LoadError.invalidActorID(entry.id)
            }
            guard actors[entry.id] == nil else {
                throw LoadError.duplicateActorID(entry.id)
            }
            guard !entry.roles.isEmpty else {
                throw LoadError.emptyRoles(actor: entry.id)
            }
            for role in entry.roles where !SMLValidationSupport.identifierIsValid(role) {
                throw LoadError.invalidRole(actor: entry.id, role: role)
            }
            for operation in entry.operations
            where !SMLRuntimeCommandOperation.all.contains(operation) {
                throw LoadError.unknownOperation(actor: entry.id, operation: operation)
            }
            for authority in entry.approvalAuthorities ?? []
            where !SMLValidationSupport.identifierIsValid(authority) {
                throw LoadError.invalidApprovalAuthority(actor: entry.id, authority: authority)
            }
            actors[entry.id] = ActorGrant(
                id: entry.id,
                roles: Set(entry.roles),
                operations: Set(entry.operations),
                approvalAuthorities: Set(entry.approvalAuthorities ?? []),
                scopeTemplate: entry.scopeTemplate ?? [:]
            )
        }
        return SMLRuntimeAuthorityConfig(actors: actors)
    }

    /// Resolves one command against the configured grants and the session lease. Task authority is
    /// dynamic: creating operations admit the command's own (new) task; every other operation is
    /// confined to tasks the lease already owns plus the synthetic "runtime" metadata task.
    public func resolveAuthority(
        for command: SMLCommandEnvelope,
        lease: SMLRuntimeLeaseRegistry.Session
    ) async throws -> SMLCommandAuthority {
        guard let grant = actors[command.actor] else {
            throw ResolutionError.unknownActor(command.actor)
        }
        let tasks = await lease.authorizedTasks(for: command)
        return SMLCommandAuthority(
            authenticatedActor: grant.id,
            leaseID: lease.leaseID,
            roles: grant.roles,
            tasks: tasks,
            operations: grant.operations,
            approvalAuthorities: grant.approvalAuthorities,
            scope: grant.scopeTemplate
        )
    }
}
