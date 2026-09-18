import Foundation

/// Human-reviewed execution admission catalog for durable SML runtime hosts, loaded from
/// `<projectRoot>/.kist/sml/catalog.json`.
///
/// Live hosts must NEVER derive their catalog from the workflow's own references — that derivation
/// (see `derivedSMLAdmissionCatalog`) trusts whatever the workflow asks for and exists only so the
/// offline export path can prove installability. This file is the host owner's explicit statement
/// of which observation sources, tools, model purposes, verifiers, and approval owners are real on
/// THIS host. Importers may write PROPOSED fragments next to it; nothing merges into this file
/// except a human.
///
/// Plugins are deliberately absent from schema v1: `RUN_PLUGIN` has no production driver, and a
/// plugin attestation is a signed contract, not a string — admitting one takes more than a list
/// entry. Workflows referencing plugins fail admission on a durable host until that story exists.
public enum SMLRuntimeHostCatalogFile {
    public static let schemaVersion = 1
    public static let relativePath = ".kist/sml/catalog.json"

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case missing(path: String)
        case unreadable(path: String, reason: String)
        case malformed(path: String, reason: String)
        case unsupportedSchemaVersion(Int)
        case invalidEntry(field: String, value: String)

        public var description: String {
            switch self {
            case .missing(let path):
                return "SML host catalog is missing: \(path) — a durable host needs the "
                    + "human-reviewed admission catalog (observation_sources, tool_capabilities, "
                    + "model_purposes, approval_authorities, ...); it is never derived from the workflow"
            case .unreadable(let path, let reason):
                return "SML host catalog is unreadable: \(path) (\(reason))"
            case .malformed(let path, let reason):
                return "SML host catalog is malformed: \(path) (\(reason))"
            case .unsupportedSchemaVersion(let version):
                return "SML host catalog schema_version \(version) is unsupported (expected \(schemaVersion))"
            case .invalidEntry(let field, let value):
                return "SML host catalog \(field) entry is empty or whitespace: '\(value)'"
            }
        }
    }

    public static func defaultURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
    }

    public static func load(projectRoot: String) throws -> SMLExecutionAdmissionCatalog {
        let path = defaultURL(projectRoot: projectRoot).path
        return try load(path: path) {
            try SMLHostConfigurationFile.read(
                projectRoot: projectRoot,
                relativePath: relativePath
            )
        }
    }

    public static func load(fileURL: URL) throws -> SMLExecutionAdmissionCatalog {
        let path = fileURL.path
        return try load(path: path) { try SMLHostConfigurationFile.read(fileURL: fileURL) }
    }

    private static func load(
        path: String,
        read: () throws -> Data
    ) throws -> SMLExecutionAdmissionCatalog {
        let data: Data
        do {
            data = try read()
        } catch SMLHostConfigurationFile.ReadError.missing {
            throw LoadError.missing(path: path)
        } catch {
            throw LoadError.unreadable(path: path, reason: String(describing: error))
        }

        do {
            let root = try SMLHostConfigurationFile.decodeRoot(from: data)
            let fields: Set<String> = [
                "schema_version", "observation_sources", "retrieval_sources",
                "tool_capabilities", "model_purposes", "model_output_schemas", "v_cards",
                "workflows", "verifiers", "rollback_procedures", "approval_authorities",
            ]
            try SMLHostConfigurationFile.requireOnlyKeys(root, allowed: fields, path: "catalog")
            let version = try SMLHostConfigurationFile.requiredInteger(
                root["schema_version"], path: "catalog.schema_version")
            guard version == schemaVersion else {
                throw LoadError.unsupportedSchemaVersion(version)
            }

            var totalEntries = 0
            func entries(_ field: String) throws -> Set<String> {
                guard let value = root[field] else { return [] }
                let values = try entrySet(field, value)
                totalEntries += values.count
                guard totalEntries <= 4_096 else {
                    throw SMLHostConfigurationFile.SchemaError(
                        reason: "catalog exceeds 4096 total admission entries")
                }
                return values
            }

            return SMLExecutionAdmissionCatalog(
                observationSources: try entries("observation_sources"),
                retrievalSources: try entries("retrieval_sources"),
                toolCapabilities: try entries("tool_capabilities"),
                modelPurposes: try entries("model_purposes"),
                modelOutputSchemas: try entries("model_output_schemas"),
                vCards: try entries("v_cards"),
                workflows: try entries("workflows"),
                verifiers: try entries("verifiers"),
                rollbackProcedures: try entries("rollback_procedures"),
                approvalAuthorities: try entries("approval_authorities")
            )
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.malformed(path: path, reason: String(describing: error))
        }
    }

    private static func entrySet(_ field: String, _ value: SMLValue) throws -> Set<String> {
        let values = try SMLHostConfigurationFile.stringArray(
            value,
            path: "catalog.\(field)"
        ) { entry, path in
            do {
                _ = try SMLHostConfigurationFile.reference(entry, path: path)
            } catch {
                if entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw LoadError.invalidEntry(field: field, value: entry)
                }
                throw error
            }
        }
        return Set(values)
    }
}
