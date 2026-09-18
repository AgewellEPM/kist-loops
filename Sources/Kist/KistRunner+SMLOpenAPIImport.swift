import Foundation
import AgentCore

extension KistRunner {
    struct SMLOpenAPIImportFile: Sendable, Codable, Equatable {
        let relativePath: String
        let byteCount: Int
        let sha256: String
        let created: Bool

        enum CodingKeys: String, CodingKey {
            case created, sha256
            case relativePath = "relative_path"
            case byteCount = "byte_count"
        }
    }

    struct SMLOpenAPIImportManifest: Sendable, Codable, Equatable {
        static let schemaVersion = 1

        let schemaVersion: Int
        let kind: String
        let apiID: String
        let sourceReference: String
        let sourceDigest: String
        let outputRoot: String
        let capabilities: [String]
        let requiredCredentialIDs: [String]
        let credentialFile: String
        let endpointBundle: String
        let catalogProposal: String
        let workflowSourceSet: String
        let files: [SMLOpenAPIImportFile]
        let reviewRequired: Bool
        let catalogModified: Bool
        let durableApprovalGating: Bool

        init(
            apiID: String,
            sourceReference: String,
            sourceDigest: String,
            outputRoot: String,
            capabilities: [String],
            requiredCredentialIDs: [String],
            endpointBundle: String,
            catalogProposal: String,
            workflowSourceSet: String,
            files: [SMLOpenAPIImportFile]
        ) {
            schemaVersion = Self.schemaVersion
            kind = "sml_openapi_import"
            self.apiID = apiID
            self.sourceReference = sourceReference
            self.sourceDigest = sourceDigest
            self.outputRoot = outputRoot
            self.capabilities = capabilities.sorted()
            self.requiredCredentialIDs = requiredCredentialIDs.sorted()
            credentialFile = SMLHTTPAuthenticationStore.relativePath
            self.endpointBundle = endpointBundle
            self.catalogProposal = catalogProposal
            self.workflowSourceSet = workflowSourceSet
            self.files = files
            reviewRequired = true
            catalogModified = false
            durableApprovalGating = true
        }

        enum CodingKeys: String, CodingKey {
            case kind, capabilities, files
            case schemaVersion = "schema_version"
            case apiID = "api_id"
            case sourceReference = "source_reference"
            case sourceDigest = "source_digest"
            case outputRoot = "output_root"
            case requiredCredentialIDs = "required_credential_ids"
            case credentialFile = "credential_file"
            case endpointBundle = "endpoint_bundle"
            case catalogProposal = "catalog_proposal"
            case workflowSourceSet = "workflow_source_set"
            case reviewRequired = "review_required"
            case catalogModified = "catalog_modified"
            case durableApprovalGating = "durable_approval_gating"
        }
    }

    static func runSMLOpenAPIImport(_ opts: KistOptions) -> Int32 {
        do {
            let manifest = try importSMLOpenAPI(
                sourcePath: opts.smlOpenAPIImport,
                apiIDOverride: opts.smlOpenAPIID,
                outputDirectory: opts.smlRuntimeOutputDirectory,
                projectRoot: opts.project
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(manifest), as: UTF8.self))
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func importSMLOpenAPI(
        sourcePath: String?,
        apiIDOverride: String? = nil,
        outputDirectory: String? = nil,
        projectRoot: String
    ) throws -> SMLOpenAPIImportManifest {
        guard let sourcePath,
              !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLOpenAPIImportCLIError.missingSource
        }
        let root = try ConfinedRoot(root: projectRoot)
        let sourceData: Data
        do {
            sourceData = try root.readStableData(
                sourcePath, maxBytes: SMLHTTPEndpointRegistry.maximumBundleBytes)
        } catch {
            throw SMLOpenAPIImportCLIError.unreadableSource(String(describing: error))
        }
        let sourceReference = try projectRelativePath(
            sourcePath, canonicalProjectRoot: root.rootPath)
        let apiID = try normalizedSMLOpenAPIID(
            apiIDOverride ?? derivedSMLOpenAPIID(from: sourcePath))
        let outputPrefix = try normalizedSMLOutputPrefix(
            outputDirectory, canonicalProjectRoot: root.rootPath)

        let imported = try SMLWorkflowOpenAPIImporter.importDocument(
            sourceData,
            apiID: apiID,
            sourceReference: sourceReference
        )
        let workflowNames = imported.wrapperWorkflows.map {
            "\(apiID).\($0.instructions.first?.capability ?? $0.id).workflow.json"
        }
        guard Set(workflowNames.map { $0.lowercased() }).count == workflowNames.count else {
            throw SMLOpenAPIImportCLIError.filenameCollision
        }

        let endpointRelative = "\(SMLHTTPEndpointRegistry.relativeDirectory)/\(apiID).json"
        let proposalRelative = ".kist/sml/proposals/\(apiID).catalog.proposed.json"
        let workflowDirectory = ".kist/sml/http-workflows"
        let sourceSetRelative = "\(workflowDirectory)/\(apiID).sources.json"
        let sourceSet = SMLRuntimeHostSourceSet(sources: workflowNames.map {
            SMLRuntimeHostSourceSetEntry(path: $0)
        })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var artifacts: [(relativePath: String, data: Data)] = [
            (endpointRelative, try encoder.encode(imported.endpointBundle)),
            (proposalRelative, try encoder.encode(imported.proposedCatalog)),
        ]
        for (name, workflow) in zip(workflowNames, imported.wrapperWorkflows) {
            artifacts.append(("\(workflowDirectory)/\(name)", try encoder.encode(workflow)))
        }
        // Publish the source-set index last. A concurrent failure can leave only inert endpoint or
        // workflow files; it can never publish a runnable index that references missing wrappers.
        artifacts.append((sourceSetRelative, try encoder.encode(sourceSet)))

        var files: [SMLOpenAPIImportFile] = []
        for artifact in artifacts {
            let projectRelative = joinedSMLOutputPath(outputPrefix, artifact.relativePath)
            let created: Bool
            do {
                created = try root.createDataIfMissing(
                    projectRelative, artifact.data, createParents: true)
            } catch {
                throw SMLOpenAPIImportCLIError.writeFailed(
                    path: projectRelative, reason: String(describing: error))
            }
            files.append(SMLOpenAPIImportFile(
                relativePath: artifact.relativePath,
                byteCount: artifact.data.count,
                sha256: BuilderEvidenceDigest.sha256(
                    String(decoding: artifact.data, as: UTF8.self)),
                created: created
            ))
        }

        let credentialIDs = Set(imported.endpointBundle.endpoints.flatMap { endpoint in
            endpoint.authentication.flatMap { requirement in
                requirement.schemes.map(\.credentialID)
            }
        })
        return SMLOpenAPIImportManifest(
            apiID: apiID,
            sourceReference: sourceReference,
            sourceDigest: imported.endpointBundle.sourceDigest,
            outputRoot: outputPrefix.isEmpty ? "." : outputPrefix,
            capabilities: imported.endpointBundle.endpoints.map(\.capability),
            requiredCredentialIDs: Array(credentialIDs),
            endpointBundle: endpointRelative,
            catalogProposal: proposalRelative,
            workflowSourceSet: sourceSetRelative,
            files: files
        )
    }

    private static func derivedSMLOpenAPIID(from sourcePath: String) -> String {
        var name = URL(fileURLWithPath: sourcePath).lastPathComponent
        if name.lowercased().hasSuffix(".json") { name.removeLast(5) }
        if name.lowercased().hasSuffix(".openapi") { name.removeLast(8) }
        return name
    }

    private static func normalizedSMLOpenAPIID(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 96,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({ scalar in
                (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
                    || (97...122).contains(scalar.value) || scalar == "."
                    || scalar == "_" || scalar == "-"
              }) else {
            throw SMLOpenAPIImportCLIError.invalidAPIID
        }
        return value
    }

    private static func projectRelativePath(
        _ path: String,
        canonicalProjectRoot: String
    ) throws -> String {
        let relative: String
        if path.hasPrefix("/") {
            let prefix = canonicalProjectRoot == "/" ? "/" : canonicalProjectRoot + "/"
            guard path.hasPrefix(prefix), path.count > prefix.count else {
                throw SMLOpenAPIImportCLIError.sourceOutsideProject
            }
            relative = String(path.dropFirst(prefix.count))
        } else {
            relative = path
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != ".." }) else {
            throw SMLOpenAPIImportCLIError.sourceOutsideProject
        }
        let normalized = parts.filter { $0 != "." }.joined(separator: "/")
        guard !normalized.isEmpty else { throw SMLOpenAPIImportCLIError.sourceOutsideProject }
        return normalized
    }

    private static func normalizedSMLOutputPrefix(
        _ outputDirectory: String?,
        canonicalProjectRoot: String
    ) throws -> String {
        guard let outputDirectory else { return "" }
        let trimmed = outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SMLOpenAPIImportCLIError.invalidOutputDirectory }
        let absolute = (trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed, isDirectory: true)
            : URL(fileURLWithPath: canonicalProjectRoot, isDirectory: true)
                .appendingPathComponent(trimmed, isDirectory: true))
            .standardizedFileURL.path
        if absolute == canonicalProjectRoot { return "" }
        let prefix = canonicalProjectRoot == "/" ? "/" : canonicalProjectRoot + "/"
        guard absolute.hasPrefix(prefix) else {
            throw SMLOpenAPIImportCLIError.invalidOutputDirectory
        }
        return String(absolute.dropFirst(prefix.count))
    }

    private static func joinedSMLOutputPath(_ prefix: String, _ path: String) -> String {
        prefix.isEmpty ? path : "\(prefix)/\(path)"
    }
}

enum SMLOpenAPIImportCLIError: Error, CustomStringConvertible {
    case missingSource
    case unreadableSource(String)
    case sourceOutsideProject
    case invalidAPIID
    case invalidOutputDirectory
    case filenameCollision
    case writeFailed(path: String, reason: String)

    var description: String {
        switch self {
        case .missingSource:
            return "--sml-import-openapi requires a project-confined OpenAPI JSON document"
        case .unreadableSource(let reason):
            return "OpenAPI source is unsafe or unreadable (\(reason))"
        case .sourceOutsideProject:
            return "OpenAPI source must be a regular file inside --project"
        case .invalidAPIID:
            return "API id must be 1...96 ASCII letters, numbers, '.', '_', or '-'; "
                + "use --sml-api-id to set one explicitly"
        case .invalidOutputDirectory:
            return "--sml-out must resolve inside --project"
        case .filenameCollision:
            return "OpenAPI operation ids collide on a case-insensitive filesystem"
        case .writeFailed(let path, let reason):
            return "could not create OpenAPI import artifact '\(path)' (\(reason))"
        }
    }
}
