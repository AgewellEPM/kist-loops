import Foundation
import AgentCore

extension KistRunner {
    static func writeSMLRuntimeHostScaffold(
        sourcePath: String?,
        outputDirectory: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostScaffold {
        let outputURL = try smlRuntimeScaffoldOutputURL(
            outputDirectory,
            projectRoot: projectRoot
        )
        try validateSMLRuntimeScaffoldOutputDirectory(
            outputURL,
            projectRoot: projectRoot
        )
        return try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            try prepareSMLRuntimeScaffoldOutputDirectory(
                outputURL,
                projectRoot: projectRoot
            )
            let runtime = host.runtimePackage.runtime
            let launchDescriptor = host.launch.launchDescriptor
            var files: [SMLRuntimeHostScaffoldFile] = []
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "catalog.json",
                outputDirectory: outputURL,
                resource: .catalog,
                summary: "Mounted workflow runtime catalog.",
                payload: runtime.catalog
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "mount.json",
                outputDirectory: outputURL,
                resource: .mount,
                summary: "Host mount contract for generated REPL/API/model/Onyx/planning surfaces.",
                payload: runtime.mountContract
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "launch.json",
                outputDirectory: outputURL,
                resource: .launch,
                summary: "Launch descriptor proving the wrapped source mounted cleanly.",
                payload: launchDescriptor
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "runtime-export.json",
                outputDirectory: outputURL,
                resource: .export,
                summary: "Complete descriptor-only runtime export.",
                payload: runtime
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "runtime-source-package.json",
                outputDirectory: outputURL,
                summary: "Portable source package plus generated runtime export.",
                payload: host.runtimePackage
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "openapi.json",
                outputDirectory: outputURL,
                resource: .openAPI,
                summary: "Generated OpenAPI document for custom runtime API endpoints.",
                payload: runtime.openAPI
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "model-tools.json",
                outputDirectory: outputURL,
                summary: "Per-workflow model tool descriptors.",
                payload: runtime.modelTools
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "model-router.json",
                outputDirectory: outputURL,
                resource: .modelRouter,
                summary: "Native model-router tool descriptor for selecting and driving mounted workflows.",
                payload: runtime.modelRouter
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "onyx-drivers.json",
                outputDirectory: outputURL,
                resource: .onyxDrivers,
                summary: "Generated Onyx driver manifests with skill trees, tools, and plans.",
                payload: runtime.onyxDrivers
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "planning.json",
                outputDirectory: outputURL,
                resource: .planning,
                summary: "Aggregate planning manifest with skill index, tool index, graph units, and gates.",
                payload: runtime.planning
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "agent-guide.json",
                outputDirectory: outputURL,
                resource: .agentGuide,
                summary: "Canonical model/agent operating guide.",
                payload: runtime.agentGuide
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "host-guide.json",
                outputDirectory: outputURL,
                resource: .hostGuide,
                summary: "Canonical host integration checklist.",
                payload: runtime.hostGuide
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "host-wiring.json",
                outputDirectory: outputURL,
                resource: .hostWiring,
                summary: "Compact host wiring map for dashboards, CLIs, HTTP routers, model hosts, and Onyx bridges.",
                payload: runtime.hostWiring
            ))
            let attachments = runtime.hostWiring.attachmentManifests
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "attachments.json",
                outputDirectory: outputURL,
                resource: .attachments,
                summary: "All per-workflow attachment manifests.",
                payload: attachments
            ))
            let onyxDriversByWorkflowID = Dictionary(grouping: runtime.onyxDrivers, by: \.workflowID)
            for attachment in attachments {
                let fileStem = smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
                let workflowRunbook = SMLRuntimeHostScaffoldWorkflowRunbook(
                    attachment: attachment,
                    outputDirectory: outputURL.standardizedFileURL.path
                )
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "workflow-runbooks/\(fileStem).json",
                    outputDirectory: outputURL,
                    summary: "Per-workflow runbook card with artifact paths, commands, REPL mount, routes, model, Onyx, skill, tool, and planning IDs for \(attachment.workflowID).",
                    payload: workflowRunbook
                ))
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "workflow-bindings/\(fileStem).json",
                    outputDirectory: outputURL,
                    summary: "Per-workflow binding manifest tying REPL, API, model-router, Onyx, skill, tool, and planning channels to local artifacts and runtime metadata APIs for \(attachment.workflowID).",
                    payload: SMLRuntimeHostScaffoldWorkflowBinding(workflowRunbook: workflowRunbook)
                ))
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "repl-mounts/\(fileStem).json",
                    outputDirectory: outputURL,
                    summary: "Per-workflow custom REPL mount descriptor for \(attachment.workflowID).",
                    payload: attachment.replMount
                ))
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "api-mounts/\(fileStem).json",
                    outputDirectory: outputURL,
                    summary: "Per-workflow custom API mount descriptors for \(attachment.workflowID).",
                    payload: attachment.apiRoutes
                ))
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "model-tools/\(fileStem).json",
                    outputDirectory: outputURL,
                    summary: "Per-workflow native model tool descriptor for \(attachment.workflowID).",
                    payload: smlRuntimeModelToolExport(for: attachment)
                ))
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "attachments/\(fileStem).json",
                    outputDirectory: outputURL,
                    resource: .workflowAttachment,
                    summary: "Attachment manifest for \(attachment.workflowID).",
                    payload: attachment
                ))
                guard let onyxDriver = onyxDriversByWorkflowID[attachment.workflowID]?.first(where: {
                    $0.driverID == attachment.onyxDriverID
                }) else {
                    throw SMLRuntimeHostExportError.writeFailed(
                        path: outputURL
                            .appendingPathComponent("onyx-drivers/\(fileStem).json")
                            .standardizedFileURL
                            .path,
                        reason: "missing generated Onyx driver '\(attachment.onyxDriverID)' for \(attachment.workflowID)"
                    )
                }
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "onyx-drivers/\(fileStem).json",
                    outputDirectory: outputURL,
                    summary: "Per-workflow Onyx driver manifest for \(attachment.workflowID).",
                    payload: onyxDriver
                ))
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "skill-trees/\(fileStem).json",
                    outputDirectory: outputURL,
                    summary: "Per-workflow skill tree for \(attachment.workflowID).",
                    payload: attachment.skillTree
                ))
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "tool-bindings/\(fileStem).json",
                    outputDirectory: outputURL,
                    summary: "Per-workflow tool bindings for \(attachment.workflowID).",
                    payload: attachment.toolBindings
                ))
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "planning/\(fileStem).json",
                    outputDirectory: outputURL,
                    summary: "Per-workflow planning bundle for \(attachment.workflowID).",
                    payload: SMLRuntimeHostScaffoldWorkflowPlanningBundle(attachment: attachment)
                ))
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "api-scripts/\(fileStem).json",
                    outputDirectory: outputURL,
                    summary: "Runnable generated API request script template for \(attachment.workflowID).",
                    payload: smlRuntimeScaffoldAPIScript(for: attachment)
                ))
                files.append(try writeSMLRuntimeScaffoldTextFile(
                    relativePath: "repl-scripts/\(fileStem).repl",
                    outputDirectory: outputURL,
                    summary: "Runnable generated REPL script template for \(attachment.workflowID).",
                    text: smlRuntimeScaffoldREPLScript(for: attachment)
                ))
                files.append(try writeSMLRuntimeScaffoldTextFile(
                    relativePath: "model-scripts/\(fileStem).prompts",
                    outputDirectory: outputURL,
                    summary: "Runnable generated model-router prompt script template for \(attachment.workflowID).",
                    text: smlRuntimeScaffoldModelScript(for: attachment)
                ))
            }
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "runbook.json",
                outputDirectory: outputURL,
                summary: "Machine-readable host integration runbook tying artifacts, REPL mounts, inline scripts, commands, API endpoints, model-router, Onyx, and planning IDs together.",
                payload: smlRuntimeScaffoldRunbook(
                    sourcePath: host.sourcePath,
                    sourceFormat: host.sourceFormat,
                    outputDirectory: outputURL.standardizedFileURL.path,
                    artifactsMaterialized: true,
                    launchDescriptor: launchDescriptor,
                    attachments: attachments
                )
            ))
            files.append(try writeSMLRuntimeScaffoldTextFile(
                relativePath: "README.md",
                outputDirectory: outputURL,
                summary: "Human-readable scaffold usage guide.",
                text: smlRuntimeScaffoldReadme(
                    sourcePath: host.sourcePath,
                    sourceFormat: host.sourceFormat,
                    outputDirectory: outputURL.standardizedFileURL.path,
                    launchDescriptor: launchDescriptor,
                    files: files
                )
            ))
            let scaffold = SMLRuntimeHostScaffold(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                outputDirectory: outputURL.standardizedFileURL.path,
                workflowIDs: launchDescriptor.workflowIDs,
                apiBasePaths: launchDescriptor.apiBasePaths,
                files: files,
                launchDescriptor: launchDescriptor
            )
            try writeSMLRuntimeScaffoldJSONData(
                relativePath: scaffold.indexPath,
                outputDirectory: outputURL,
                payload: scaffold
            )
            return scaffold
        }
    }

    private static func smlRuntimeScaffoldOutputURL(
        _ outputDirectory: String?,
        projectRoot: String
    ) throws -> URL {
        guard let outputDirectory else {
            throw SMLRuntimeHostExportError.missingOutputDirectory
        }
        let trimmed = outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SMLRuntimeHostExportError.missingOutputDirectory
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: projectRoot, isDirectory: true)
            .appendingPathComponent(trimmed, isDirectory: true)
            .standardizedFileURL
    }

    private static func validateSMLRuntimeScaffoldOutputDirectory(
        _ outputURL: URL,
        projectRoot: String
    ) throws {
        let manager = FileManager.default
        let path = normalizedDirectoryPath(outputURL)
        let projectPath = normalizedDirectoryPath(
            URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL
        )
        let homePath = normalizedDirectoryPath(manager.homeDirectoryForCurrentUser.standardizedFileURL)
        guard path != "/", path != projectPath, path != homePath else {
            throw SMLRuntimeHostExportError.outputDirectoryNotAllowed(path)
        }
        if (try? manager.destinationOfSymbolicLink(atPath: path)) != nil {
            throw SMLRuntimeHostExportError.outputDirectoryNotAllowed(path)
        }
        var isDirectory = ObjCBool(false)
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue else {
            throw SMLRuntimeHostExportError.outputDirectoryIsFile(path)
        }
        do {
            if try !manager.contentsOfDirectory(atPath: path).isEmpty {
                throw SMLRuntimeHostExportError.outputDirectoryNotEmpty(path)
            }
        } catch let error as SMLRuntimeHostExportError {
            throw error
        } catch {
            throw SMLRuntimeHostExportError.writeFailed(
                path: path,
                reason: String(describing: error)
            )
        }
    }

    private static func prepareSMLRuntimeScaffoldOutputDirectory(
        _ outputURL: URL,
        projectRoot: String
    ) throws {
        try validateSMLRuntimeScaffoldOutputDirectory(
            outputURL,
            projectRoot: projectRoot
        )
        do {
            try FileManager.default.createDirectory(
                at: outputURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw SMLRuntimeHostExportError.writeFailed(
                path: outputURL.standardizedFileURL.path,
                reason: String(describing: error)
            )
        }
    }

    private static func normalizedDirectoryPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    @discardableResult
    private static func writeSMLRuntimeScaffoldJSONData<T: Encodable>(
        relativePath: String,
        outputDirectory: URL,
        payload: T
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try writeSMLRuntimeScaffoldData(
            data,
            relativePath: relativePath,
            outputDirectory: outputDirectory
        )
        return data
    }

    private static func writeSMLRuntimeScaffoldJSONFile<T: Encodable>(
        relativePath: String,
        outputDirectory: URL,
        resource: SMLWorkflowRuntimeMetadataResource? = nil,
        summary: String,
        payload: T
    ) throws -> SMLRuntimeHostScaffoldFile {
        let data = try writeSMLRuntimeScaffoldJSONData(
            relativePath: relativePath,
            outputDirectory: outputDirectory,
            payload: payload
        )
        return smlRuntimeScaffoldFileRecord(
            relativePath: relativePath,
            outputDirectory: outputDirectory,
            resource: resource,
            summary: summary,
            data: data
        )
    }

    private static func writeSMLRuntimeScaffoldTextFile(
        relativePath: String,
        outputDirectory: URL,
        summary: String,
        text: String
    ) throws -> SMLRuntimeHostScaffoldFile {
        let data = Data(text.utf8)
        try writeSMLRuntimeScaffoldData(
            data,
            relativePath: relativePath,
            outputDirectory: outputDirectory
        )
        return smlRuntimeScaffoldFileRecord(
            relativePath: relativePath,
            outputDirectory: outputDirectory,
            summary: summary,
            data: data
        )
    }

    private static func writeSMLRuntimeScaffoldData(
        _ data: Data,
        relativePath: String,
        outputDirectory: URL
    ) throws {
        let targetURL = outputDirectory.appendingPathComponent(relativePath, isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard !FileManager.default.fileExists(atPath: targetURL.path) else {
                throw SMLRuntimeHostExportError.writeFailed(
                    path: targetURL.path,
                    reason: "target already exists"
                )
            }
            try data.write(to: targetURL, options: [.atomic])
        } catch let error as SMLRuntimeHostExportError {
            throw error
        } catch {
            throw SMLRuntimeHostExportError.writeFailed(
                path: targetURL.path,
                reason: String(describing: error)
            )
        }
    }

    private static func smlRuntimeScaffoldFileRecord(
        relativePath: String,
        outputDirectory: URL,
        resource: SMLWorkflowRuntimeMetadataResource? = nil,
        summary: String,
        data: Data
    ) -> SMLRuntimeHostScaffoldFile {
        SMLRuntimeHostScaffoldFile(
            relativePath: relativePath,
            path: outputDirectory
                .appendingPathComponent(relativePath, isDirectory: false)
                .standardizedFileURL
                .path,
            resource: resource,
            byteCount: data.count,
            sha256: BuilderEvidenceDigest.sha256(String(decoding: data, as: UTF8.self)),
            summary: summary
        )
    }

    static func smlRuntimeScaffoldSafeFileStem(_ workflowID: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let stem = String(workflowID.map { allowed.contains($0) ? $0 : "_" })
        return stem.isEmpty ? "workflow" : stem
    }

    static func smlRuntimeWorkflowMetadataLinks(
        for attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest
    ) -> SMLWorkflowRuntimeWorkflowMetadataLinks {
        SMLWorkflowRuntimeWorkflowMetadataLinks(
            workflowID: attachment.workflowID,
            workflowVersion: attachment.workflowVersion,
            apiBasePath: attachment.apiBasePath,
            attachmentPath: attachment.runtimeWorkflowAttachmentPath,
            onyxDriverPath: attachment.runtimeWorkflowOnyxDriverPath,
            skillTreePath: attachment.runtimeWorkflowSkillTreePath,
            toolBindingsPath: attachment.runtimeWorkflowToolBindingsPath,
            planningBundlePath: attachment.runtimeWorkflowPlanningPath
        )
    }

    static func smlRuntimeModelToolExport(
        for attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest
    ) -> SMLWorkflowRuntimeModelToolExport {
        if let model = attachment.model {
            return SMLWorkflowRuntimeModelToolExport(
                workflowID: attachment.workflowID,
                workflowVersion: attachment.workflowVersion,
                tool: model.tool,
                allowedActions: model.allowedActions,
                maximumCommandRounds: model.maximumCommandRounds,
                workflowMetadata: smlRuntimeWorkflowMetadataLinks(for: attachment)
            )
        }
        let allowedActions = Array(
            Set(attachment.commandBindings.compactMap { binding in
                binding.modelEligible ? binding.action : nil
            })
        ).sorted { $0.rawValue < $1.rawValue }
        return SMLWorkflowRuntimeModelToolExport(
            workflowID: attachment.workflowID,
            workflowVersion: attachment.workflowVersion,
            tool: SMLWorkflowModelToolDescriptor(
                name: attachment.modelToolName,
                description: "Generated model command tool for \(attachment.workflowID).",
                parameters: []
            ),
            allowedActions: allowedActions,
            maximumCommandRounds: 1,
            workflowMetadata: smlRuntimeWorkflowMetadataLinks(for: attachment)
        )
    }

    static func smlRuntimeScaffoldRunbook(
        sourcePath: String,
        sourceFormat: SMLRuntimeHostExportSourceFormat,
        outputDirectory: String,
        artifactsMaterialized: Bool,
        launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor,
        attachments: [SMLWorkflowRuntimeWorkflowAttachmentManifest]
    ) -> SMLRuntimeHostScaffoldRunbook {
        SMLRuntimeHostScaffoldRunbook(
            sourcePath: sourcePath,
            sourceFormat: sourceFormat,
            outputDirectory: outputDirectory,
            workflowIDs: attachments.map(\.workflowID),
            apiBasePaths: attachments.map(\.apiBasePath),
            artifactsMaterialized: artifactsMaterialized,
            workflows: attachments.map {
                SMLRuntimeHostScaffoldWorkflowRunbook(
                    attachment: $0,
                    outputDirectory: outputDirectory
                )
            },
            launchDescriptor: launchDescriptor
        )
    }

    static func smlRuntimeRunbookOutputDirectory(
        for host: SMLRuntimeHostLaunch,
        projectRoot: String
    ) -> String {
        if host.sourceFormat == .runtimeScaffold {
            return URL(fileURLWithPath: host.sourcePath)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
        }
        return URL(fileURLWithPath: projectRoot, isDirectory: true)
            .standardizedFileURL
            .path
    }

    private static func smlRuntimeScaffoldReadme(
        sourcePath: String,
        sourceFormat: SMLRuntimeHostExportSourceFormat,
        outputDirectory: String,
        launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor,
        files: [SMLRuntimeHostScaffoldFile]
    ) -> String {
        let workflowList = launchDescriptor.workflowIDs.map { "- \($0)" }.joined(separator: "\n")
        let apiBaseList = launchDescriptor.apiBasePaths.map { "- \($0)" }.joined(separator: "\n")
        let apiWorkflowList = launchDescriptor.sourceSummaries.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }.map {
            let taskEndpoint = $0.apiRoutePaths.first { $0.hasSuffix("/tasks") }
                ?? "\($0.apiBasePath)\($0.apiWorkflowPath)/tasks"
            return "- \($0.workflowID): `\($0.apiWorkflowPath)` mounted at `\(taskEndpoint)`"
        }.joined(separator: "\n")
        let workflowCards = launchDescriptor.hostWiring.attachmentManifests.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }.map { attachment in
            let fileStem = smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
            let taskEndpoint = attachment.apiRoutes.first { $0.action == .start }?.pathTemplate
                ?? "\(attachment.apiBasePath)\(attachment.apiWorkflowPath)/tasks"
            let skillIDs = Array(Set(attachment.skillTree.map(\.id))).sorted()
            let skillList = skillIDs.isEmpty
                ? "none"
                : skillIDs.map { "`\($0)`" }.joined(separator: ", ")
            let toolList = attachment.toolReferences.isEmpty
                ? "none"
                : attachment.toolReferences.map { "`\($0)`" }.joined(separator: ", ")
            let planningID = attachment.planningWorkflowID ?? "none"
            let plannerEntrypoint = attachment.plannerEntrypoint ?? "none"
            let runtimeMetadata = smlRuntimeWorkflowMetadataLinks(for: attachment)
            return """
            ### \(attachment.workflowID)

            - Task endpoint: `\(taskEndpoint)`
            - REPL replay: `kist --sml-runtime-repl-script . --sml-script repl-scripts/\(fileStem).repl --sml-workflow \(attachment.workflowID)`
            - REPL mount: `repl-mounts/\(fileStem).json`
            - API replay: `kist --sml-runtime-api-script . --sml-api-script api-scripts/\(fileStem).json`
            - API mount: `api-mounts/\(fileStem).json`
            - Model-router replay: `kist --sml-runtime-model-script . --sml-model-script model-scripts/\(fileStem).prompts --provider <provider> --model <model>`
            - Model router tool: `\(attachment.modelRouterToolName)`; workflow model tool: `\(attachment.modelToolName)`
            - Model tool descriptor: `model-tools/\(fileStem).json`
            - Workflow runbook: `workflow-runbooks/\(fileStem).json`
            - Workflow binding manifest: `workflow-bindings/\(fileStem).json`
            - Onyx driver: `onyx-drivers/\(fileStem).json` (`\(attachment.onyxDriverID)`)
            - Skill tree: `skill-trees/\(fileStem).json` (\(skillList))
            - Tool bindings: `tool-bindings/\(fileStem).json` (\(toolList))
            - Planning bundle: `planning/\(fileStem).json` (planning workflow `\(planningID)`, entrypoint `\(plannerEntrypoint)`)
            - Attachment manifest: `attachments/\(fileStem).json`
            - Runtime metadata APIs: attachment `GET \(runtimeMetadata.attachmentPath)`; REPL mount `GET \(runtimeMetadata.replMountPath)`; API mount `GET \(runtimeMetadata.apiMountPath)`; model tool `GET \(runtimeMetadata.modelToolPath)`; Onyx driver `GET \(runtimeMetadata.onyxDriverPath)`; skill tree `GET \(runtimeMetadata.skillTreePath)`; tool bindings `GET \(runtimeMetadata.toolBindingsPath)`; planning bundle `GET \(runtimeMetadata.planningBundlePath)`
            """
        }.joined(separator: "\n\n")
        let fileList = files.sorted {
            if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
            return $0.sha256 < $1.sha256
        }.map {
            "- `\($0.relativePath)` — \($0.summary) SHA-256: `\($0.sha256)`"
        }.joined(separator: "\n")
        return """
        # SML runtime scaffold

        Source: `\(sourcePath)`
        Source format: `\(sourceFormat.rawValue)`
        Output directory: `\(outputDirectory)`
        Launch complete: `\(launchDescriptor.launchComplete)`

        ## Mounted workflows

        \(workflowList.isEmpty ? "- none" : workflowList)

        ## API base paths

        \(apiBaseList.isEmpty ? "- none" : apiBaseList)

        ## Workflow API paths

        \(apiWorkflowList.isEmpty ? "- none" : apiWorkflowList)

        ## Per-workflow wiring cards

        \(workflowCards.isEmpty ? "- none" : workflowCards)

        ## Files

        \(fileList)

        ## Host wiring order

        1. Decode `runbook.json` for exact scaffold artifact paths, inline REPL/API/model scripts, command templates, API endpoints, model-router IDs, Onyx driver IDs, planning IDs, workflow binding manifests, and runtime metadata API paths.
        2. Decode `runtime-source-package.json` or inspect `runtime-export.json`.
        3. Mount routes from `mount.json` and `openapi.json`.
        4. Attach `model-router.json` plus `model-tools.json` or `model-tools/*.json` as the native tools exposed to the selected model.
        5. Load `onyx-drivers.json` or `onyx-drivers/*.json` for Onyx driver manifests.
        6. Use `planning.json`, `planning/*.json`, `skill-trees/*.json`, `tool-bindings/*.json`, `agent-guide.json`, and `host-guide.json` as the agent/host operating contract.
        7. Use `workflow-bindings/*.json` first when a dashboard, CLI adapter, custom REPL/API/model host, or Onyx bridge needs one workflow-specific map; fall back to `workflow-runbooks/*.json`, `repl-mounts/*.json`, `api-mounts/*.json`, `model-tools/*.json`, `host-wiring.json`, or `attachments/*.json` for fuller payloads.
        8. Run `repl-scripts/*.repl` with `kist --sml-runtime-repl-script <this directory> --sml-script <script>` to produce a multi-turn workflow REPL transcript.
        9. Run `api-scripts/*.json` with `kist --sml-runtime-api-script <this directory> --sml-api-script <script>` to produce a multi-request generated API transcript.
        10. Run `model-scripts/*.prompts` with `kist --sml-runtime-model-script <this directory> --sml-model-script <script>` plus a native-tool provider/model to produce a multi-turn model-router transcript.

        Descriptor files do not carry actor identity, leases, credentials, provider registries, runtime handles, or completion authority. State changes still have to cross the generated host command gateway and replay/admission checks.
        """
    }

    static func smlRuntimeScaffoldAPIScript(
        for attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest
    ) -> [SMLRuntimeHostAPIRequestSpec] {
        let workflowRequests: [SMLRuntimeHostAPIRequestSpec] = [
            SMLWorkflowControlAction.describe, .start, .watch, .receipts,
        ].compactMap { action in
            let matchingEndpoints = attachment.apiRoutes.filter {
                $0.action == action
            }.sorted {
                if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
                return $0.method.rawValue < $1.method.rawValue
            }
            guard let endpoint = matchingEndpoints.first,
                  let example = endpoint.examples.first else {
                return nil
            }
            return SMLRuntimeHostAPIRequestSpec(
                method: example.method,
                path: example.path.replacingOccurrences(of: "TASK-ID", with: "TASK-SCAFFOLD"),
                body: smlRuntimeReplaceTaskID(in: example.body)
            )
        }
        let metadata = attachment.workflowMetadata
        let metadataRequests = [
            metadata.attachmentPath,
            metadata.replMountPath,
            metadata.apiMountPath,
            metadata.modelToolPath,
            metadata.onyxDriverPath,
            metadata.skillTreePath,
            metadata.toolBindingsPath,
            metadata.planningBundlePath,
        ].map { path in
            SMLRuntimeHostAPIRequestSpec(method: .get, path: path)
        }
        return workflowRequests + metadataRequests
    }

    static func smlRuntimeScaffoldREPLScript(
        for attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest
    ) -> String {
        let examplesByVerb = Dictionary(
            grouping: attachment.replExamples,
            by: \.verb
        ).mapValues { examples in
            examples.sorted { $0.line < $1.line }.first?.line ?? ""
        }
        let startLine = examplesByVerb["start"]?
            .replacingOccurrences(of: "TASK-ID", with: "TASK-SCAFFOLD")
        let watchLine = examplesByVerb["watch"]?
            .replacingOccurrences(of: "TASK-ID", with: "TASK-SCAFFOLD")
        let runtimeLines = [startLine, watchLine].compactMap { $0 }
        return ([
            "# Generated SML workflow REPL script for \(attachment.workflowID)",
            "# Run from the scaffold directory with:",
            "# kist --sml-runtime-repl-script . --sml-script repl-scripts/\(smlRuntimeScaffoldSafeFileStem(attachment.workflowID)).repl --sml-workflow \(attachment.workflowID)",
            "help",
            "schema",
            "api",
            "model",
            "onyx",
            "skill-tree",
            "tool-bindings",
            "planning",
            "attachment",
            "repl-mount",
            "api-mount",
            "model-tool",
            "onyx-driver",
            "skill-tree-json",
            "tool-bindings-json",
            "planning-bundle",
        ] + runtimeLines + [
            "# Approval/refusal/rollback commands require the latest task_revision returned by watch.",
            "exit",
            "",
        ]).joined(separator: "\n")
    }

    static func smlRuntimeScaffoldModelScript(
        for attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest
    ) -> String {
        let fileStem = smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
        let metadata = attachment.workflowMetadata
        let metadataContract = [
            "attachment GET \(metadata.attachmentPath)",
            "REPL mount GET \(metadata.replMountPath)",
            "API mount GET \(metadata.apiMountPath)",
            "model tool GET \(metadata.modelToolPath)",
            "Onyx driver GET \(metadata.onyxDriverPath)",
            "skill tree GET \(metadata.skillTreePath)",
            "tool bindings GET \(metadata.toolBindingsPath)",
            "planning bundle GET \(metadata.planningBundlePath)",
        ].joined(separator: "; ")
        let artifactContract = [
            "attachments/\(fileStem).json",
            "repl-mounts/\(fileStem).json",
            "api-mounts/\(fileStem).json",
            "model-tools/\(fileStem).json",
            "onyx-drivers/\(fileStem).json",
            "skill-trees/\(fileStem).json",
            "tool-bindings/\(fileStem).json",
            "planning/\(fileStem).json",
            "workflow-bindings/\(fileStem).json",
        ].joined(separator: "; ")
        return ([
            "# Generated SML workflow model-router prompt script for \(attachment.workflowID)",
            "# Run from the scaffold directory with a native-tool provider/model:",
            "# kist --sml-runtime-model-script . --sml-model-script model-scripts/\(fileStem).prompts --provider <provider> --model <model>",
            "# Runtime metadata APIs: \(metadataContract)",
            "# Local scaffold artifacts: \(artifactContract)",
            "Start \(attachment.workflowID) as task TASK-SCAFFOLD with the declared sample input after consulting the workflow metadata APIs (\(metadataContract)) and local scaffold artifacts (\(artifactContract)); use the planning bundle, skill tree, tool bindings, model tool, and Onyx driver as the operating contract, and propose the smallest admitted command.",
            "Watch the current \(attachment.workflowID) task using the remembered task id and the same planning/skill/tool/Onyx contract; summarize only the current waiting instruction and next bounded step.",
            "List receipts for \(attachment.workflowID) using the workflow metadata contract; treat only accepted or sealed receipts as proof and keep advisory prose separate from verified completion.",
            "",
        ]).joined(separator: "\n")
    }

    private static func smlRuntimeReplaceTaskID(in object: SMLObject) -> SMLObject {
        object.mapValues(smlRuntimeReplaceTaskID(in:))
    }

    private static func smlRuntimeReplaceTaskID(in value: SMLValue) -> SMLValue {
        switch value {
        case .null, .bool, .number:
            return value
        case .string(let string):
            return .string(string.replacingOccurrences(of: "TASK-ID", with: "TASK-SCAFFOLD"))
        case .array(let array):
            return .array(array.map(smlRuntimeReplaceTaskID(in:)))
        case .object(let object):
            return .object(smlRuntimeReplaceTaskID(in: object))
        }
    }

}
