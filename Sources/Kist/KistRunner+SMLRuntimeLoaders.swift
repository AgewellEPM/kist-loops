import Foundation
import AgentCore

extension KistRunner {
    static func withSMLRuntimeHostLaunch<T>(
        sourcePath: String?,
        projectRoot: String,
        mode: SMLRuntimeHostMode = .ephemeralExport,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil,
        _ body: (SMLRuntimeHostLaunch) async throws -> T
    ) async throws -> T {
        guard let sourcePath,
              !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingSourcePath
        }
        let requestedSourceURL = smlRuntimeSourceURL(sourcePath, projectRoot: projectRoot)
        let sourceURL = smlRuntimeReadableSourceURL(requestedSourceURL)
        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: sourceURL)
        } catch {
            throw SMLRuntimeHostExportError.readFailed(
                path: sourceURL.path,
                reason: String(describing: error)
            )
        }

        var loaded = try loadSMLRuntimeSource(data: sourceData, path: sourceURL.path)
        // Durable (live) hosts run every workflow through approval gating BEFORE validation and
        // admission, so the DAG proofs hold for the gated graph and no externally advanced step
        // can execute without a human gate. Ephemeral export stays byte-stable and ungated —
        // it proves installability, not execution authority.
        if case .durable = mode {
            let policy = try SMLApprovalPolicy.load(projectRoot: projectRoot)
            loaded = try loaded.approvalGated(policy: policy)
        }
        let actor = actor ?? "sml-runtime-exporter"
        let title = title ?? "SML Workflow Runtime API"
        let version = version ?? "1.0.0"
        let modelRounds = modelMaximumCommandRoundsOverride.map { min(max(1, $0), 8) }
        let apiWorkflowPathOverrides = try normalizedSMLRuntimeAPIWorkflowPathOverrides(
            apiWorkflowPathOverrides,
            workflows: loaded.workflows
        )
        // The derived catalog rubber-stamps the workflow's own references — offline install proof
        // only. A durable (live) host admits against the human-reviewed catalog file, never the
        // workflow's self-description.
        let admissionCatalog: SMLExecutionAdmissionCatalog
        switch mode {
        case .ephemeralExport:
            admissionCatalog = derivedSMLAdmissionCatalog(for: loaded.workflows)
        case .durable:
            admissionCatalog = try SMLRuntimeHostCatalogFile.load(projectRoot: projectRoot)
        }
        // Ephemeral exports keep deterministic IDs (goldens depend on them; the store dies with
        // the process). Durable sessions MUST salt their IDs: the persistent store keeps replay
        // claims across launches, so a restarted sequential source would collide with its own
        // prior session's claims and every command would die "already claimed".
        let commandIDSource: SMLRuntimeSequentialIDSource
        let taskIDSource: SMLRuntimeSequentialIDSource
        switch mode {
        case .ephemeralExport:
            commandIDSource = SMLRuntimeSequentialIDSource(prefix: "sml-runtime-export-command")
            taskIDSource = SMLRuntimeSequentialIDSource(prefix: "TASK-SML-RUNTIME-EXPORT")
        case .durable:
            let nonce = UUID().uuidString.lowercased().prefix(8)
            commandIDSource = SMLRuntimeSequentialIDSource(prefix: "sml-cmd-\(nonce)")
            taskIDSource = SMLRuntimeSequentialIDSource(prefix: "TASK-SML-\(String(nonce).uppercased())")
        }
        let registry: SMLWorkflowRuntimeRegistry
        if let package = loaded.package {
            registry = try SMLWorkflowRuntimeRegistry.compile(
                package: package,
                admissionCatalog: admissionCatalog,
                actor: actor,
                roleOverride: roleOverride,
                apiBasePathOverride: apiBasePathOverride,
                apiWorkflowPathOverrides: apiWorkflowPathOverrides,
                modelMaximumCommandRoundsOverride: modelRounds,
                commandID: { commandIDSource.nextID() },
                taskID: { taskIDSource.nextID() }
            )
        } else if !loaded.sourceSetMounts.isEmpty {
            registry = try SMLWorkflowRuntimeRegistry.compile(
                candidateMounts: loaded.sourceSetMounts.map { mount in
                    SMLWorkflowRuntimeCandidateMount(
                        workflow: mount.workflow,
                        admissionCatalog: admissionCatalog,
                        role: roleOverride ?? mount.role ?? "workflow-agent",
                        actor: actor,
                        apiBasePath: apiBasePathOverride ?? mount.apiBasePath ?? "/sml",
                        apiWorkflowPath: apiWorkflowPathOverrides[mount.workflow.id] ?? mount.apiWorkflowPath,
                        modelMaximumCommandRounds: modelRounds
                            ?? mount.modelMaximumCommandRounds
                            ?? 4
                    )
                },
                commandID: { commandIDSource.nextID() },
                taskID: { taskIDSource.nextID() }
            )
        } else {
            registry = try SMLWorkflowRuntimeRegistry.compile(
                candidateMounts: loaded.workflows.map { workflow in
                    SMLWorkflowRuntimeCandidateMount(
                        workflow: workflow,
                        admissionCatalog: admissionCatalog,
                        role: roleOverride ?? "workflow-agent",
                        actor: actor,
                        apiBasePath: apiBasePathOverride ?? "/sml",
                        apiWorkflowPath: apiWorkflowPathOverrides[workflow.id],
                        modelMaximumCommandRounds: modelRounds ?? 4
                    )
                },
                commandID: { commandIDSource.nextID() },
                taskID: { taskIDSource.nextID() }
            )
        }

        let runtimePackage = try SMLWorkflowRuntimeSourcePackage(
            normalizedWorkflows: loaded.workflows,
            runtime: registry.export(title: title, version: version)
        )
        switch mode {
        case .ephemeralExport:
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
            let host = SMLRuntimeHostLaunch(
                sourcePath: sourceURL.standardizedFileURL.path,
                sourceFormat: loaded.format,
                runtimePackage: runtimePackage,
                launch: launch,
                durableEnvironment: nil
            )
            return try await body(host)
        case .durable:
            let environment = try await SMLRuntimeDurableHostEnvironment.acquire(projectRoot: projectRoot)
            defer { environment.lock.release() }
            let runtime = SMLRuntime(store: environment.store, clock: environment.clock)
            let launch = try await SMLWorkflowRuntimeApp.launch(
                registry: registry,
                runtime: runtime,
                replayGuard: environment.store,
                authorityResolver: environment.authorityResolver,
                sourcePackage: runtimePackage,
                clock: environment.clock
            )
            let host = SMLRuntimeHostLaunch(
                sourcePath: sourceURL.standardizedFileURL.path,
                sourceFormat: loaded.format,
                runtimePackage: runtimePackage,
                launch: launch,
                durableEnvironment: environment,
                durableRuntime: runtime
            )
            return try await body(host)
        }
    }

    private static func normalizedSMLRuntimeAPIWorkflowPathOverrides(
        _ overrides: [String: String],
        workflows: [SMLWorkflow]
    ) throws -> [String: String] {
        guard !overrides.isEmpty else { return [:] }
        let workflowIDs = Set(workflows.map(\.id))
        let available = workflows.map(\.id).sorted()
        var normalized: [String: String] = [:]
        for (workflowID, path) in overrides.sorted(by: { $0.key < $1.key }) {
            let workflowID = workflowID.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !workflowID.isEmpty,
                  !path.isEmpty,
                  smlRuntimeSourceSetAPIWorkflowPathIsValid(path) else {
                throw SMLRuntimeHostExportError.invalidAPIWorkflowPathOverride(
                    workflowID: workflowID,
                    path: path
                )
            }
            guard normalized[workflowID] == nil else {
                throw SMLRuntimeHostExportError.duplicateAPIWorkflowPathOverride(workflowID)
            }
            guard workflowIDs.contains(workflowID) else {
                throw SMLRuntimeHostExportError.unknownAPIWorkflowPathOverride(
                    requested: workflowID,
                    available: available
                )
            }
            normalized[workflowID] = path
        }
        return normalized
    }

    static func selectSMLRuntimeREPLWorkflowID(
        _ workflowID: String?,
        availableWorkflowIDs: [String]
    ) throws -> String {
        guard !availableWorkflowIDs.isEmpty else {
            throw SMLRuntimeHostExportError.noREPLWorkflows
        }
        if let workflowID,
           !workflowID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard availableWorkflowIDs.contains(workflowID) else {
                throw SMLRuntimeHostExportError.unknownREPLWorkflow(
                    requested: workflowID,
                    available: availableWorkflowIDs
                )
            }
            return workflowID
        }
        guard availableWorkflowIDs.count == 1, let only = availableWorkflowIDs.first else {
            throw SMLRuntimeHostExportError.ambiguousREPLWorkflow(availableWorkflowIDs)
        }
        return only
    }

    static func selectSMLRuntimeOptionalWorkflowID(
        _ workflowID: String?,
        availableWorkflowIDs: [String]
    ) throws -> String? {
        guard let workflowID,
              !workflowID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard availableWorkflowIDs.contains(workflowID) else {
            throw SMLRuntimeHostExportError.unknownREPLWorkflow(
                requested: workflowID,
                available: availableWorkflowIDs
            )
        }
        return workflowID
    }

    static func decodeSMLRuntimeOpenObject(
        _ json: String?,
        flag: String
    ) throws -> SMLObject {
        guard let json,
              !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        guard let data = json.data(using: .utf8) else {
            throw SMLRuntimeHostExportError.invalidJSONObject(
                flag: flag,
                reason: "input is not UTF-8"
            )
        }
        do {
            return try SMLWireCodec.decodeOpenObject(
                from: data,
                limits: .init(maximumBytes: 256 * 1_024, maximumDepth: 16, maximumNodes: 8_192)
            )
        } catch {
            throw SMLRuntimeHostExportError.invalidJSONObject(
                flag: flag,
                reason: String(describing: error)
            )
        }
    }

    static func loadSMLRuntimeREPLScript(
        scriptPath: String?,
        projectRoot: String
    ) throws -> (path: String, lines: [String]) {
        guard let scriptPath,
              !scriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingREPLScriptPath
        }
        let scriptURL = smlRuntimeSourceURL(scriptPath, projectRoot: projectRoot)
            .standardizedFileURL
        let scriptText: String
        do {
            scriptText = try String(contentsOf: scriptURL, encoding: .utf8)
        } catch {
            throw SMLRuntimeHostExportError.readREPLScriptFailed(
                path: scriptURL.path,
                reason: String(describing: error)
            )
        }
        let lines = scriptText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else {
            throw SMLRuntimeHostExportError.emptyREPLScript(path: scriptURL.path)
        }
        return (scriptURL.path, lines)
    }

    static func loadSMLRuntimeAPIScript(
        scriptPath: String?,
        projectRoot: String
    ) throws -> (path: String, requests: [SMLRuntimeHostAPIRequestSpec]) {
        guard let scriptPath,
              !scriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingAPIScriptPath
        }
        let scriptURL = smlRuntimeSourceURL(scriptPath, projectRoot: projectRoot)
            .standardizedFileURL
        let data: Data
        do {
            data = try Data(contentsOf: scriptURL)
        } catch {
            throw SMLRuntimeHostExportError.readAPIScriptFailed(
                path: scriptURL.path,
                reason: String(describing: error)
            )
        }
        let requests: [SMLRuntimeHostAPIRequestSpec]
        do {
            requests = try JSONDecoder().decode([SMLRuntimeHostAPIRequestSpec].self, from: data)
        } catch {
            throw SMLRuntimeHostExportError.invalidAPIScript(
                path: scriptURL.path,
                reason: String(describing: error)
            )
        }
        guard !requests.isEmpty else {
            throw SMLRuntimeHostExportError.emptyAPIScript(path: scriptURL.path)
        }
        for request in requests where request.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SMLRuntimeHostExportError.invalidAPIScript(
                path: scriptURL.path,
                reason: "request path must be nonempty"
            )
        }
        return (scriptURL.path, requests)
    }

    static func loadSMLRuntimeModelScript(
        scriptPath: String?,
        projectRoot: String
    ) throws -> (path: String, prompts: [String]) {
        guard let scriptPath,
              !scriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingModelScriptPath
        }
        let scriptURL = smlRuntimeSourceURL(scriptPath, projectRoot: projectRoot)
            .standardizedFileURL
        let scriptText: String
        do {
            scriptText = try String(contentsOf: scriptURL, encoding: .utf8)
        } catch {
            throw SMLRuntimeHostExportError.readModelScriptFailed(
                path: scriptURL.path,
                reason: String(describing: error)
            )
        }
        let prompts = scriptText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !prompts.isEmpty else {
            throw SMLRuntimeHostExportError.emptyModelScript(path: scriptURL.path)
        }
        return (scriptURL.path, prompts)
    }

    private struct LoadedSMLRuntimeSourceMount {
        let workflow: SMLWorkflow
        let role: String?
        let apiBasePath: String?
        let apiWorkflowPath: String?
        let modelMaximumCommandRounds: Int?
    }

    private struct LoadedSMLRuntimeSource {
        let format: SMLRuntimeHostExportSourceFormat
        let package: SMLWorkflowRuntimeSourcePackage?
        let workflows: [SMLWorkflow]
        let sourceSetMounts: [LoadedSMLRuntimeSourceMount]

        init(
            format: SMLRuntimeHostExportSourceFormat,
            package: SMLWorkflowRuntimeSourcePackage?,
            workflows: [SMLWorkflow],
            sourceSetMounts: [LoadedSMLRuntimeSourceMount] = []
        ) {
            self.format = format
            self.package = package
            self.workflows = workflows
            self.sourceSetMounts = sourceSetMounts
        }

        /// The durable-host view of this source: every workflow (top-level and per-mount) gated
        /// through approval injection. The pre-compiled runtime package is dropped on purpose —
        /// it embeds the UNGATED graphs, so a durable registry always recompiles from the gated
        /// candidate workflows (mount roles/paths are preserved via sourceSetMounts).
        func approvalGated(policy: SMLApprovalPolicy) throws -> LoadedSMLRuntimeSource {
            LoadedSMLRuntimeSource(
                format: format,
                package: nil,
                workflows: try workflows.map {
                    try SMLWorkflowApprovalGating.gate($0, policy: policy)
                },
                sourceSetMounts: try sourceSetMounts.map { mount in
                    LoadedSMLRuntimeSourceMount(
                        workflow: try SMLWorkflowApprovalGating.gate(mount.workflow, policy: policy),
                        role: mount.role,
                        apiBasePath: mount.apiBasePath,
                        apiWorkflowPath: mount.apiWorkflowPath,
                        modelMaximumCommandRounds: mount.modelMaximumCommandRounds
                    )
                }
            )
        }
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

    private static func smlRuntimeReadableSourceURL(_ sourceURL: URL) -> URL {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: sourceURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return sourceURL
        }
        return sourceURL.appendingPathComponent("scaffold.json", isDirectory: false)
    }

    private static func loadSMLRuntimeSource(
        data: Data,
        path: String,
        allowSourceSet: Bool = true
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
            let scaffold = try JSONDecoder().decode(SMLRuntimeHostScaffold.self, from: data)
            let package = try loadSMLRuntimePackage(from: scaffold, indexPath: path)
            return LoadedSMLRuntimeSource(
                format: .runtimeScaffold,
                package: package,
                workflows: package.normalizedWorkflows
            )
        } catch {
            diagnostics.append("runtime scaffold: \(error)")
        }
        if allowSourceSet {
            do {
                let sourceSet = try JSONDecoder().decode(SMLRuntimeHostSourceSet.self, from: data)
                let mounts = try loadSMLRuntimeSourceSet(sourceSet, indexPath: path)
                return LoadedSMLRuntimeSource(
                    format: .runtimeSourceSet,
                    package: nil,
                    workflows: mounts.map(\.workflow),
                    sourceSetMounts: mounts
                )
            } catch {
                diagnostics.append("runtime source set: \(error)")
            }
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

    private static func loadSMLRuntimeSourceSet(
        _ sourceSet: SMLRuntimeHostSourceSet,
        indexPath: String
    ) throws -> [LoadedSMLRuntimeSourceMount] {
        guard sourceSet.schemaVersion == SMLRuntimeHostSourceSet.currentSchemaVersion else {
            throw SMLRuntimeHostExportError.invalidSourceSet(
                path: indexPath,
                reason: "unsupported schemaVersion \(sourceSet.schemaVersion)"
            )
        }
        guard sourceSet.kind == SMLRuntimeHostSourceSet.kind else {
            throw SMLRuntimeHostExportError.invalidSourceSet(
                path: indexPath,
                reason: "kind must be '\(SMLRuntimeHostSourceSet.kind)'"
            )
        }
        guard !sourceSet.sources.isEmpty else {
            throw SMLRuntimeHostExportError.invalidSourceSet(
                path: indexPath,
                reason: "sources must contain at least one workflow source"
            )
        }

        let indexURL = URL(fileURLWithPath: indexPath).standardizedFileURL
        let baseURL = indexURL.deletingLastPathComponent()
        var mounts: [LoadedSMLRuntimeSourceMount] = []
        var seenWorkflowIDs = Set<String>()
        for (offset, entry) in sourceSet.sources.enumerated() {
            let entryPath = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entryPath.isEmpty else {
                throw SMLRuntimeHostExportError.invalidSourceSet(
                    path: indexPath,
                    reason: "sources[\(offset)].path must be nonempty"
                )
            }
            let entryURL = (entryPath.hasPrefix("/")
                ? URL(fileURLWithPath: entryPath)
                : baseURL.appendingPathComponent(entryPath))
                .standardizedFileURL
            let entryData: Data
            do {
                entryData = try Data(contentsOf: entryURL)
            } catch {
                throw SMLRuntimeHostExportError.invalidSourceSet(
                    path: indexPath,
                    reason: "could not read sources[\(offset)] '\(entryPath)': \(error)"
                )
            }
            let loaded = try loadSMLRuntimeSource(
                data: entryData,
                path: entryURL.path,
                allowSourceSet: false
            )
            guard loaded.package == nil,
                  loaded.workflows.count == 1,
                  loaded.format == .langGraphManifest || loaded.format == .smlWorkflowJSON else {
                throw SMLRuntimeHostExportError.invalidSourceSet(
                    path: indexPath,
                    reason: "sources[\(offset)] '\(entryPath)' must be a single LangGraph manifest or SML workflow JSON"
                )
            }
            let workflow = loaded.workflows[0]
            guard seenWorkflowIDs.insert(workflow.id).inserted else {
                throw SMLRuntimeHostExportError.invalidSourceSet(
                    path: indexPath,
                    reason: "duplicate workflow id '\(workflow.id)'"
                )
            }
            let role = try normalizedSMLRuntimeSourceSetString(
                entry.role,
                field: "sources[\(offset)].role",
                indexPath: indexPath
            )
            let apiBasePath = try normalizedSMLRuntimeSourceSetString(
                entry.apiBasePath,
                field: "sources[\(offset)].apiBasePath",
                indexPath: indexPath
            )
            if let apiBasePath,
               !smlRuntimeSourceSetAPIBasePathIsValid(apiBasePath) {
                throw SMLRuntimeHostExportError.invalidSourceSet(
                    path: indexPath,
                    reason: "sources[\(offset)].apiBasePath must be an absolute literal path"
                )
            }
            let apiWorkflowPath = try normalizedSMLRuntimeSourceSetString(
                entry.apiWorkflowPath,
                field: "sources[\(offset)].apiWorkflowPath",
                indexPath: indexPath
            )
            if let apiWorkflowPath,
               !smlRuntimeSourceSetAPIWorkflowPathIsValid(apiWorkflowPath) {
                throw SMLRuntimeHostExportError.invalidSourceSet(
                    path: indexPath,
                    reason: "sources[\(offset)].apiWorkflowPath must be an absolute literal path"
                )
            }
            if let modelMaximumCommandRounds = entry.modelMaximumCommandRounds,
               !(1...8).contains(modelMaximumCommandRounds) {
                throw SMLRuntimeHostExportError.invalidSourceSet(
                    path: indexPath,
                    reason: "sources[\(offset)].modelMaximumCommandRounds must be between 1 and 8"
                )
            }
            mounts.append(LoadedSMLRuntimeSourceMount(
                workflow: workflow,
                role: role,
                apiBasePath: apiBasePath,
                apiWorkflowPath: apiWorkflowPath,
                modelMaximumCommandRounds: entry.modelMaximumCommandRounds
            ))
        }
        return mounts
    }

    private static func normalizedSMLRuntimeSourceSetString(
        _ value: String?,
        field: String,
        indexPath: String
    ) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SMLRuntimeHostExportError.invalidSourceSet(
                path: indexPath,
                reason: "\(field) must be nonempty when provided"
            )
        }
        return trimmed
    }

    private static func smlRuntimeSourceSetAPIBasePathIsValid(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              !path.contains("?"),
              !path.contains("#"),
              !path.contains("//"),
              !path.contains("%") else {
            return false
        }
        return path.split(separator: "/").allSatisfy { segment in
            let value = String(segment)
            guard !value.isEmpty, value.count <= 128 else { return false }
            return value.unicodeScalars.allSatisfy { scalar in
                let number = (48...57).contains(scalar.value)
                let upper = (65...90).contains(scalar.value)
                let lower = (97...122).contains(scalar.value)
                return number || upper || lower || scalar == "_" || scalar == "-"
            }
        }
    }

    private static func smlRuntimeSourceSetAPIWorkflowPathIsValid(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              !path.contains("?"),
              !path.contains("#"),
              !path.contains("//"),
              !path.contains("%") else {
            return false
        }
        return path.split(separator: "/").allSatisfy { segment in
            let value = String(segment)
            guard !value.isEmpty, value.count <= 128 else { return false }
            return value.unicodeScalars.allSatisfy { scalar in
                let number = (48...57).contains(scalar.value)
                let upper = (65...90).contains(scalar.value)
                let lower = (97...122).contains(scalar.value)
                return number || upper || lower || scalar == "_" || scalar == "-" || scalar == "."
            }
        }
    }

    private static func loadSMLRuntimePackage(
        from scaffold: SMLRuntimeHostScaffold,
        indexPath: String
    ) throws -> SMLWorkflowRuntimeSourcePackage {
        let files = try validatedSMLRuntimeScaffoldFiles(scaffold, indexPath: indexPath)
        guard let packageData = files["runtime-source-package.json"] else {
            throw SMLRuntimeHostExportError.invalidScaffold(
                path: indexPath,
                reason: "missing runtime-source-package.json file record"
            )
        }
        return try JSONDecoder().decode(SMLWorkflowRuntimeSourcePackage.self, from: packageData)
    }

    private static func validatedSMLRuntimeScaffoldFiles(
        _ scaffold: SMLRuntimeHostScaffold,
        indexPath: String
    ) throws -> [String: Data] {
        guard (1...SMLRuntimeHostScaffold.currentSchemaVersion).contains(scaffold.schemaVersion) else {
            throw SMLRuntimeHostExportError.invalidScaffold(
                path: indexPath,
                reason: "unsupported schemaVersion \(scaffold.schemaVersion)"
            )
        }
        guard !scaffold.files.isEmpty else {
            throw SMLRuntimeHostExportError.invalidScaffold(
                path: indexPath,
                reason: "files must contain at least runtime-source-package.json"
            )
        }

        let indexURL = URL(fileURLWithPath: indexPath).standardizedFileURL
        let baseURL = indexURL.deletingLastPathComponent().standardizedFileURL
        var seen = Set<String>()
        var files: [String: Data] = [:]
        for file in scaffold.files {
            let relativePath = try validatedSMLRuntimeScaffoldRelativePath(
                file.relativePath,
                indexPath: indexPath
            )
            guard seen.insert(relativePath).inserted else {
                throw SMLRuntimeHostExportError.invalidScaffold(
                    path: indexPath,
                    reason: "duplicate file record '\(relativePath)'"
                )
            }
            let fileURL = baseURL
                .appendingPathComponent(relativePath, isDirectory: false)
                .standardizedFileURL
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw SMLRuntimeHostExportError.readFailed(
                    path: fileURL.path,
                    reason: String(describing: error)
                )
            }
            guard data.count == file.byteCount else {
                throw SMLRuntimeHostExportError.invalidScaffold(
                    path: indexPath,
                    reason: "\(relativePath) byte count changed"
                )
            }
            let text = String(decoding: data, as: UTF8.self)
            guard BuilderEvidenceDigest.sha256(text) == file.sha256 else {
                throw SMLRuntimeHostExportError.invalidScaffold(
                    path: indexPath,
                    reason: "\(relativePath) digest changed"
                )
            }
            files[relativePath] = data
        }
        if scaffold.schemaVersion >= 2 {
            let missingRequiredPaths = requiredSMLRuntimeScaffoldFilePaths(for: scaffold)
                .subtracting(Set(files.keys))
                .sorted()
            guard missingRequiredPaths.isEmpty else {
                throw SMLRuntimeHostExportError.invalidScaffold(
                    path: indexPath,
                    reason: "missing required file record '\(missingRequiredPaths[0])'"
                )
            }
        }
        if scaffold.schemaVersion >= 6 {
            try validateSMLRuntimeScaffoldWorkflowPathMaps(
                scaffold,
                indexPath: indexPath
            )
        }
        if scaffold.schemaVersion >= 7 {
            try validateSMLRuntimeScaffoldWorkflowBindings(
                scaffold,
                files: files,
                indexPath: indexPath
            )
        }
        guard files["runtime-source-package.json"] != nil else {
            throw SMLRuntimeHostExportError.invalidScaffold(
                path: indexPath,
                reason: "missing runtime-source-package.json file record"
            )
        }
        return files
    }

    private static func validatedSMLRuntimeScaffoldRelativePath(
        _ path: String,
        indexPath: String
    ) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty,
              trimmed == path,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              components.allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
              }) else {
            throw SMLRuntimeHostExportError.invalidScaffold(
                path: indexPath,
                reason: "invalid relative file path '\(path)'"
            )
        }
        return trimmed
    }

    private static func requiredSMLRuntimeScaffoldFilePaths(
        for scaffold: SMLRuntimeHostScaffold
    ) -> Set<String> {
        var paths = Set([
            "README.md",
            "agent-guide.json",
            "attachments.json",
            "catalog.json",
            "host-guide.json",
            "host-wiring.json",
            "launch.json",
            "model-router.json",
            "model-tools.json",
            "mount.json",
            "onyx-drivers.json",
            "openapi.json",
            "planning.json",
            "runbook.json",
            "runtime-export.json",
            "runtime-source-package.json",
        ])
        for attachment in scaffold.launchDescriptor.hostWiring.attachmentManifests {
            let fileStem = smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
            paths.formUnion([
                "api-scripts/\(fileStem).json",
                "api-mounts/\(fileStem).json",
                "attachments/\(fileStem).json",
                "model-scripts/\(fileStem).prompts",
                "model-tools/\(fileStem).json",
                "onyx-drivers/\(fileStem).json",
                "planning/\(fileStem).json",
                "repl-mounts/\(fileStem).json",
                "repl-scripts/\(fileStem).repl",
                "skill-trees/\(fileStem).json",
                "tool-bindings/\(fileStem).json",
                "workflow-runbooks/\(fileStem).json",
            ])
            if scaffold.schemaVersion >= 7 {
                paths.insert("workflow-bindings/\(fileStem).json")
            }
        }
        return paths
    }

    private static func validateSMLRuntimeScaffoldWorkflowPathMaps(
        _ scaffold: SMLRuntimeHostScaffold,
        indexPath: String
    ) throws {
        let attachments = scaffold.launchDescriptor.hostWiring.attachmentManifests.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }

        func expectedMap(
            directory: String,
            extension fileExtension: String
        ) -> [String: String] {
            Dictionary(uniqueKeysWithValues: attachments.map { attachment in
                let fileStem = smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
                return (attachment.workflowID, "\(directory)/\(fileStem).\(fileExtension)")
            })
        }

        func validate(
            _ name: String,
            actual: [String: String],
            expected: [String: String]
        ) throws {
            guard actual == expected else {
                throw SMLRuntimeHostExportError.invalidScaffold(
                    path: indexPath,
                    reason: "\(name) disagrees with generated workflow artifacts"
                )
            }
        }

        try validate(
            "workflowAPIMountPathsByWorkflowID",
            actual: scaffold.workflowAPIMountPathsByWorkflowID,
            expected: expectedMap(directory: "api-mounts", extension: "json")
        )
        try validate(
            "workflowREPLMountPathsByWorkflowID",
            actual: scaffold.workflowREPLMountPathsByWorkflowID,
            expected: expectedMap(directory: "repl-mounts", extension: "json")
        )
        try validate(
            "workflowModelToolPathsByWorkflowID",
            actual: scaffold.workflowModelToolPathsByWorkflowID,
            expected: expectedMap(directory: "model-tools", extension: "json")
        )
        try validate(
            "workflowOnyxDriverPathsByWorkflowID",
            actual: scaffold.workflowOnyxDriverPathsByWorkflowID,
            expected: expectedMap(directory: "onyx-drivers", extension: "json")
        )
        try validate(
            "workflowSkillTreePathsByWorkflowID",
            actual: scaffold.workflowSkillTreePathsByWorkflowID,
            expected: expectedMap(directory: "skill-trees", extension: "json")
        )
        try validate(
            "workflowToolBindingPathsByWorkflowID",
            actual: scaffold.workflowToolBindingPathsByWorkflowID,
            expected: expectedMap(directory: "tool-bindings", extension: "json")
        )
        try validate(
            "workflowPlanningBundlePathsByWorkflowID",
            actual: scaffold.workflowPlanningBundlePathsByWorkflowID,
            expected: expectedMap(directory: "planning", extension: "json")
        )
        try validate(
            "workflowRunbookPathsByWorkflowID",
            actual: scaffold.workflowRunbookPathsByWorkflowID,
            expected: expectedMap(directory: "workflow-runbooks", extension: "json")
        )
        if scaffold.schemaVersion >= 7 {
            try validate(
                "workflowBindingPathsByWorkflowID",
                actual: scaffold.workflowBindingPathsByWorkflowID,
                expected: expectedMap(directory: "workflow-bindings", extension: "json")
            )
        }

        let expectedMetadataByWorkflowID = Dictionary(uniqueKeysWithValues: attachments.map {
            ($0.workflowID, smlRuntimeWorkflowMetadataLinks(for: $0))
        })
        guard scaffold.runtimeWorkflowMetadataByWorkflowID == expectedMetadataByWorkflowID else {
            throw SMLRuntimeHostExportError.invalidScaffold(
                path: indexPath,
                reason: "runtimeWorkflowMetadataByWorkflowID disagrees with generated workflow metadata"
            )
        }
    }

    private static func validateSMLRuntimeScaffoldWorkflowBindings(
        _ scaffold: SMLRuntimeHostScaffold,
        files: [String: Data],
        indexPath: String
    ) throws {
        let attachments = scaffold.launchDescriptor.hostWiring.attachmentManifests.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }
        for attachment in attachments {
            let fileStem = smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
            let relativePath = scaffold.workflowBindingPathsByWorkflowID[attachment.workflowID]
                ?? "workflow-bindings/\(fileStem).json"
            guard let data = files[relativePath] else {
                throw SMLRuntimeHostExportError.invalidScaffold(
                    path: indexPath,
                    reason: "missing workflow binding file '\(relativePath)'"
                )
            }
            let workflowRunbook = SMLRuntimeHostScaffoldWorkflowRunbook(
                attachment: attachment,
                outputDirectory: scaffold.outputDirectory
            )
            let expectedBinding = SMLRuntimeHostScaffoldWorkflowBinding(
                workflowRunbook: workflowRunbook
            )
            let decodedBinding: SMLRuntimeHostScaffoldWorkflowBinding
            do {
                decodedBinding = try JSONDecoder().decode(
                    SMLRuntimeHostScaffoldWorkflowBinding.self,
                    from: data
                )
            } catch {
                throw SMLRuntimeHostExportError.invalidScaffold(
                    path: indexPath,
                    reason: "\(relativePath) is not a valid workflow binding manifest: \(String(describing: error))"
                )
            }
            guard decodedBinding == expectedBinding else {
                throw SMLRuntimeHostExportError.invalidScaffold(
                    path: indexPath,
                    reason: "\(relativePath) disagrees with generated workflow binding"
                )
            }
        }
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
