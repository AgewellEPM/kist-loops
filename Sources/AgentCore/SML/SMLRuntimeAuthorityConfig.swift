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

    public static func defaultURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
    }

    public static func load(projectRoot: String) throws -> SMLRuntimeAuthorityConfig {
        let path = defaultURL(projectRoot: projectRoot).path
        return try load(path: path) {
            try SMLHostConfigurationFile.read(
                projectRoot: projectRoot,
                relativePath: relativePath
            )
        }
    }

    public static func load(fileURL: URL) throws -> SMLRuntimeAuthorityConfig {
        let path = fileURL.path
        return try load(path: path) { try SMLHostConfigurationFile.read(fileURL: fileURL) }
    }

    private static func load(
        path: String,
        read: () throws -> Data
    ) throws -> SMLRuntimeAuthorityConfig {
        let data: Data
        do {
            data = try read()
        } catch SMLHostConfigurationFile.ReadError.missing {
            throw LoadError.missing(path: path)
        } catch {
            throw classifiedReadError(path: path, reason: String(describing: error))
        }

        do {
            let root = try SMLHostConfigurationFile.decodeRoot(from: data)
            try SMLHostConfigurationFile.requireOnlyKeys(
                root,
                allowed: ["schema_version", "actors"],
                path: "authority"
            )
            let version = try SMLHostConfigurationFile.requiredInteger(
                root["schema_version"], path: "authority.schema_version")
            guard version == schemaVersion else {
                throw LoadError.unsupportedSchemaVersion(version)
            }
            let entries = try SMLHostConfigurationFile.requiredArray(
                root["actors"], path: "authority.actors")
            guard !entries.isEmpty else { throw LoadError.noActors(path: path) }
            guard entries.count <= SMLHostConfigurationFile.maximumBindings else {
                throw SMLHostConfigurationFile.SchemaError(
                    reason: "authority.actors exceeds "
                        + "\(SMLHostConfigurationFile.maximumBindings) entries")
            }

            var actors: [String: ActorGrant] = [:]
            for (index, value) in entries.enumerated() {
                let entryPath = "authority.actors[\(index)]"
                let entry = try SMLHostConfigurationFile.requiredObject(value, path: entryPath)
                try SMLHostConfigurationFile.requireOnlyKeys(
                    entry,
                    allowed: [
                        "id", "roles", "operations", "approval_authorities", "scope_template",
                    ],
                    path: entryPath
                )
                let id = try SMLHostConfigurationFile.requiredString(
                    entry["id"], path: "\(entryPath).id")
                guard SMLValidationSupport.identifierIsValid(id) else {
                    throw LoadError.invalidActorID(id)
                }
                guard actors[id] == nil else { throw LoadError.duplicateActorID(id) }

                let roles = try SMLHostConfigurationFile.stringArray(
                    entry["roles"], path: "\(entryPath).roles", maximumCount: 128
                ) { role, _ in
                    guard SMLValidationSupport.identifierIsValid(role) else {
                        throw LoadError.invalidRole(actor: id, role: role)
                    }
                }
                guard !roles.isEmpty else { throw LoadError.emptyRoles(actor: id) }

                let operations = try SMLHostConfigurationFile.stringArray(
                    entry["operations"], path: "\(entryPath).operations", maximumCount: 128
                ) { operation, _ in
                    guard SMLRuntimeCommandOperation.all.contains(operation) else {
                        throw LoadError.unknownOperation(actor: id, operation: operation)
                    }
                }

                var approvalAuthorities: [String] = []
                if let value = entry["approval_authorities"] {
                    approvalAuthorities = try SMLHostConfigurationFile.stringArray(
                        value,
                        path: "\(entryPath).approval_authorities",
                        maximumCount: 128
                    ) { authority, _ in
                        guard SMLValidationSupport.identifierIsValid(authority) else {
                            throw LoadError.invalidApprovalAuthority(
                                actor: id, authority: authority)
                        }
                    }
                }

                let scopeTemplate = try SMLHostConfigurationFile.optionalObject(
                    entry["scope_template"], path: "\(entryPath).scope_template") ?? [:]
                let scopeDiagnostics = SMLValidationSupport.inspectObject(
                    scopeTemplate, path: "\(entryPath).scope_template")
                guard scopeDiagnostics.isEmpty else {
                    throw SMLHostConfigurationFile.SchemaError(
                        reason: scopeDiagnostics.map(\.description).joined(separator: "; "))
                }

                actors[id] = ActorGrant(
                    id: id,
                    roles: Set(roles),
                    operations: Set(operations),
                    approvalAuthorities: Set(approvalAuthorities),
                    scopeTemplate: scopeTemplate
                )
            }
            return SMLRuntimeAuthorityConfig(actors: actors)
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.malformed(path: path, reason: String(describing: error))
        }
    }

    /// The descriptor-confined read decides acceptance. This pathname-only probe is diagnostics
    /// after refusal, never a security decision, and preserves the existing actionable errors.
    private static func classifiedReadError(path: String, reason: String) -> LoadError {
        var status = stat()
        if lstat(path, &status) == 0,
           (status.st_mode & S_IFMT) == S_IFREG {
            if status.st_uid != geteuid() {
                return .notOwnedByProcessUser(path: path)
            }
            if status.st_mode & 0o077 != 0 {
                return .insecurePermissions(
                    path: path,
                    mode: String(format: "%03o", status.st_mode & 0o777)
                )
            }
        }
        return .unreadable(path: path, reason: reason)
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
            scope: grant.scopeTemplate,
            taskLease: lease
        )
    }
}
