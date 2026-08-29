import Foundation
import AgentCore

extension KistRunner {
    enum SMLRuntimeHostExportSourceFormat: String, Sendable, Codable, Equatable {
        case runtimeSourcePackage = "runtime_source_package"
        case langGraphManifest = "langgraph_manifest"
        case smlWorkflowJSON = "sml_workflow_json"
    }

    struct SMLRuntimeHostExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let runtimePackage: SMLWorkflowRuntimeSourcePackage
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            runtimePackage: SMLWorkflowRuntimeSourcePackage,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.runtimePackage = runtimePackage
            self.launchDescriptor = launchDescriptor
        }
    }

    enum SMLRuntimeHostExportError: Error, CustomStringConvertible {
        case missingSourcePath
        case readFailed(path: String, reason: String)
        case unsupportedSource(path: String, diagnostics: [String])

        var description: String {
            switch self {
            case .missingSourcePath:
                return "--sml-runtime-export requires <source.json>"
            case .readFailed(let path, let reason):
                return "could not read SML runtime source '\(path)': \(reason)"
            case .unsupportedSource(let path, let diagnostics):
                return """
                unsupported SML runtime source '\(path)'. Expected a runtime source package, LangGraph manifest, or SML workflow JSON.
                \(diagnostics.map { "  - \($0)" }.joined(separator: "\n"))
                """
            }
        }
    }

    static func runSMLRuntimeExport(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostExport(
                sourcePath: opts.smlRuntimeExport,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func renderSMLRuntimeHostExport(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let export = try await makeSMLRuntimeHostExport(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(export), as: UTF8.self)
    }

    static func makeSMLRuntimeHostExport(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostExport {
        guard let sourcePath,
              !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingSourcePath
        }
        let sourceURL = smlRuntimeSourceURL(sourcePath, projectRoot: projectRoot)
        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: sourceURL)
        } catch {
            throw SMLRuntimeHostExportError.readFailed(
                path: sourceURL.path,
                reason: String(describing: error)
            )
        }

        let loaded = try loadSMLRuntimeSource(data: sourceData, path: sourceURL.path)
        let role = roleOverride ?? (loaded.package == nil ? "workflow-agent" : nil)
        let actor = actor ?? "sml-runtime-exporter"
        let title = title ?? "SML Workflow Runtime API"
        let version = version ?? "1.0.0"
        let modelRounds = modelMaximumCommandRoundsOverride.map { min(max(1, $0), 8) }
        let admissionCatalog = derivedSMLAdmissionCatalog(for: loaded.workflows)
        let registry: SMLWorkflowRuntimeRegistry
        if let package = loaded.package {
            registry = try SMLWorkflowRuntimeRegistry.compile(
                package: package,
                admissionCatalog: admissionCatalog,
                actor: actor,
                roleOverride: role,
                apiBasePathOverride: apiBasePathOverride,
                modelMaximumCommandRoundsOverride: modelRounds,
                commandID: { "sml-runtime-export-command" },
                taskID: { "TASK-SML-RUNTIME-EXPORT" }
            )
        } else {
            registry = try SMLWorkflowRuntimeRegistry.compile(
                workflows: loaded.workflows,
                admissionCatalog: admissionCatalog,
                role: role ?? "workflow-agent",
                actor: actor,
                apiBasePath: apiBasePathOverride ?? "/sml",
                modelMaximumCommandRounds: modelRounds ?? 4,
                commandID: { "sml-runtime-export-command" },
                taskID: { "TASK-SML-RUNTIME-EXPORT" }
            )
        }

        let runtimePackage = try SMLWorkflowRuntimeSourcePackage(
            normalizedWorkflows: loaded.workflows,
            runtime: registry.export(title: title, version: version)
        )
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-sml-runtime-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let store = SMLRuntimeStore(
            fileURL: tempDirectory.appendingPathComponent("runtime.json"),
            clock: { 0 }
        )
        let runtime = SMLRuntime(store: store, clock: { 0 })
        let authority: @Sendable (SMLCommandEnvelope) async throws -> SMLCommandAuthority = {
            command in
            SMLCommandAuthority(
                authenticatedActor: actor,
                leaseID: "sml-runtime-export-lease",
                roles: [command.role],
                tasks: [command.task],
                operations: [command.op],
                scope: command.scope
            )
        }
        let launch = try await SMLWorkflowRuntimeApp.launch(
            registry: registry,
            runtime: runtime,
            replayGuard: store,
            authorityResolver: authority,
            sourcePackage: runtimePackage,
            clock: { 0 }
        )
        return SMLRuntimeHostExport(
            sourcePath: sourceURL.standardizedFileURL.path,
            sourceFormat: loaded.format,
            runtimePackage: runtimePackage,
            launchDescriptor: launch.launchDescriptor
        )
    }

    private struct LoadedSMLRuntimeSource {
        let format: SMLRuntimeHostExportSourceFormat
        let package: SMLWorkflowRuntimeSourcePackage?
        let workflows: [SMLWorkflow]
    }

    private static func smlRuntimeSourceURL(
        _ sourcePath: String,
        projectRoot: String
    ) -> URL {
        if sourcePath.hasPrefix("/") {
            return URL(fileURLWithPath: sourcePath)
        }
        return URL(fileURLWithPath: projectRoot, isDirectory: true)
            .appendingPathComponent(sourcePath)
    }

    private static func loadSMLRuntimeSource(
        data: Data,
        path: String
    ) throws -> LoadedSMLRuntimeSource {
        var diagnostics: [String] = []
        do {
            let package = try JSONDecoder().decode(SMLWorkflowRuntimeSourcePackage.self, from: data)
            return LoadedSMLRuntimeSource(
                format: .runtimeSourcePackage,
                package: package,
                workflows: package.normalizedWorkflows
            )
        } catch {
            diagnostics.append("runtime source package: \(error)")
        }
        do {
            let workflow = try SMLWorkflowSourceImporter.langGraphWorkflow(from: data)
            return LoadedSMLRuntimeSource(
                format: .langGraphManifest,
                package: nil,
                workflows: [workflow]
            )
        } catch {
            diagnostics.append("LangGraph manifest: \(error)")
        }
        do {
            let workflow = try SMLWorkflowSourceImporter.workflow(from: .smlWorkflowJSON(data))
            return LoadedSMLRuntimeSource(
                format: .smlWorkflowJSON,
                package: nil,
                workflows: [workflow]
            )
        } catch {
            diagnostics.append("SML workflow JSON: \(error)")
        }
        throw SMLRuntimeHostExportError.unsupportedSource(
            path: path,
            diagnostics: diagnostics
        )
    }

    /// Offline export needs an admission catalog only to prove the generated surfaces are structurally
    /// mountable. This catalog is derived from the already-imported workflow references and is not
    /// serialized; live execution still requires the host's fresh admission catalog and authority resolver.
    private static func derivedSMLAdmissionCatalog(
        for workflows: [SMLWorkflow]
    ) -> SMLExecutionAdmissionCatalog {
        var observationSources = Set<String>()
        var retrievalSources = Set<String>()
        var toolCapabilities = Set<String>()
        var modelPurposes = Set<String>()
        var modelOutputSchemas = Set<String>()
        var vCards = Set<String>()
        var workflowIDs = Set(workflows.map(\.id))
        var verifiers = Set<String>()
        var rollbackProcedures = Set<String>()
        var approvalAuthorities = Set<String>()

        for workflow in workflows {
            for instruction in workflow.instructions {
                switch instruction.op {
                case .observe:
                    insert(instruction.source, into: &observationSources)
                case .retrieve:
                    insert(instruction.source, into: &retrievalSources)
                case .callTool:
                    insert(instruction.capability, into: &toolCapabilities)
                case .callModel:
                    insert(instruction.purpose, into: &modelPurposes)
                    insert(instruction.outputSchema, into: &modelOutputSchemas)
                case .invokeVCard:
                    insert(instruction.capability, into: &vCards)
                    insert(instruction.verifier, into: &verifiers)
                case .runWorkflow:
                    insert(instruction.workflow, into: &workflowIDs)
                case .verify, .commit:
                    insert(instruction.verifier, into: &verifiers)
                case .waitApproval:
                    insert(instruction.owner, into: &approvalAuthorities)
                case .runPlugin:
                    insert(instruction.plugin?.verifier, into: &verifiers)
                    insert(instruction.plugin?.rollback, into: &rollbackProcedures)
                case .branch, .assert, .checkpoint, .retry, .rollback, .escalate,
                     .emitReceipt, .complete:
                    break
                }
            }
        }

        return SMLExecutionAdmissionCatalog(
            observationSources: observationSources,
            retrievalSources: retrievalSources,
            toolCapabilities: toolCapabilities,
            modelPurposes: modelPurposes,
            modelOutputSchemas: modelOutputSchemas,
            vCards: vCards,
            workflows: workflowIDs,
            verifiers: verifiers,
            rollbackProcedures: rollbackProcedures,
            approvalAuthorities: approvalAuthorities
        )
    }

    private static func insert(_ value: String?, into values: inout Set<String>) {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        values.insert(value)
    }
}
