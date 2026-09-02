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

    private struct FileFormat: Decodable {
        let schemaVersion: Int
        let observationSources: [String]?
        let retrievalSources: [String]?
        let toolCapabilities: [String]?
        let modelPurposes: [String]?
        let modelOutputSchemas: [String]?
        let vCards: [String]?
        let workflows: [String]?
        let verifiers: [String]?
        let rollbackProcedures: [String]?
        let approvalAuthorities: [String]?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case observationSources = "observation_sources"
            case retrievalSources = "retrieval_sources"
            case toolCapabilities = "tool_capabilities"
            case modelPurposes = "model_purposes"
            case modelOutputSchemas = "model_output_schemas"
            case vCards = "v_cards"
            case workflows
            case verifiers
            case rollbackProcedures = "rollback_procedures"
            case approvalAuthorities = "approval_authorities"
        }
    }

    public static func defaultURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
    }

    public static func load(projectRoot: String) throws -> SMLExecutionAdmissionCatalog {
        try load(fileURL: defaultURL(projectRoot: projectRoot))
    }

    public static func load(fileURL: URL) throws -> SMLExecutionAdmissionCatalog {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw LoadError.missing(path: path)
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
        return SMLExecutionAdmissionCatalog(
            observationSources: try entrySet("observation_sources", decoded.observationSources),
            retrievalSources: try entrySet("retrieval_sources", decoded.retrievalSources),
            toolCapabilities: try entrySet("tool_capabilities", decoded.toolCapabilities),
            modelPurposes: try entrySet("model_purposes", decoded.modelPurposes),
            modelOutputSchemas: try entrySet("model_output_schemas", decoded.modelOutputSchemas),
            vCards: try entrySet("v_cards", decoded.vCards),
            workflows: try entrySet("workflows", decoded.workflows),
            verifiers: try entrySet("verifiers", decoded.verifiers),
            rollbackProcedures: try entrySet("rollback_procedures", decoded.rollbackProcedures),
            approvalAuthorities: try entrySet("approval_authorities", decoded.approvalAuthorities)
        )
    }

    private static func entrySet(_ field: String, _ values: [String]?) throws -> Set<String> {
        var out: Set<String> = []
        for value in values ?? [] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LoadError.invalidEntry(field: field, value: value)
            }
            out.insert(value)
        }
        return out
    }
}
