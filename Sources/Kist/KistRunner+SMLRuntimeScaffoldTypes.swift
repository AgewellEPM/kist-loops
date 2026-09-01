import Foundation
import AgentCore

extension KistRunner {
    struct SMLRuntimeHostScaffoldFile: Sendable, Codable, Equatable {
        let relativePath: String
        let path: String
        let resource: SMLWorkflowRuntimeMetadataResource?
        let byteCount: Int
        let sha256: String
        let summary: String

        init(
            relativePath: String,
            path: String,
            resource: SMLWorkflowRuntimeMetadataResource? = nil,
            byteCount: Int,
            sha256: String,
            summary: String
        ) {
            self.relativePath = relativePath
            self.path = path
            self.resource = resource
            self.byteCount = byteCount
            self.sha256 = sha256
            self.summary = summary
        }
    }

    struct SMLRuntimeHostScaffold: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 7

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let outputDirectory: String
        let indexPath: String
        let runbookPath: String
        let workflowIDs: [String]
        let apiBasePaths: [String]
        let workflowAPIMountPathsByWorkflowID: [String: String]
        let workflowREPLMountPathsByWorkflowID: [String: String]
        let workflowModelToolPathsByWorkflowID: [String: String]
        let workflowOnyxDriverPathsByWorkflowID: [String: String]
        let workflowSkillTreePathsByWorkflowID: [String: String]
        let workflowToolBindingPathsByWorkflowID: [String: String]
        let workflowPlanningBundlePathsByWorkflowID: [String: String]
        let workflowRunbookPathsByWorkflowID: [String: String]
        let workflowBindingPathsByWorkflowID: [String: String]
        let runtimeWorkflowMetadataByWorkflowID: [String: SMLWorkflowRuntimeWorkflowMetadataLinks]
        let files: [SMLRuntimeHostScaffoldFile]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostScaffold.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            outputDirectory: String,
            indexPath: String = "scaffold.json",
            runbookPath: String = "runbook.json",
            workflowIDs: [String],
            apiBasePaths: [String],
            workflowAPIMountPathsByWorkflowID: [String: String]? = nil,
            workflowREPLMountPathsByWorkflowID: [String: String]? = nil,
            workflowModelToolPathsByWorkflowID: [String: String]? = nil,
            workflowOnyxDriverPathsByWorkflowID: [String: String]? = nil,
            workflowSkillTreePathsByWorkflowID: [String: String]? = nil,
            workflowToolBindingPathsByWorkflowID: [String: String]? = nil,
            workflowPlanningBundlePathsByWorkflowID: [String: String]? = nil,
            workflowRunbookPathsByWorkflowID: [String: String]? = nil,
            workflowBindingPathsByWorkflowID: [String: String]? = nil,
            runtimeWorkflowMetadataByWorkflowID: [String: SMLWorkflowRuntimeWorkflowMetadataLinks]? = nil,
            files: [SMLRuntimeHostScaffoldFile],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.outputDirectory = outputDirectory
            self.indexPath = indexPath
            self.runbookPath = runbookPath
            self.workflowIDs = workflowIDs.sorted()
            self.apiBasePaths = apiBasePaths.sorted()
            let attachments = launchDescriptor.hostWiring.attachmentManifests.sorted {
                if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
                return $0.workflowVersion < $1.workflowVersion
            }
            self.workflowAPIMountPathsByWorkflowID = workflowAPIMountPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: attachments.map { attachment in
                    let fileStem = KistRunner.smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
                    return (attachment.workflowID, "api-mounts/\(fileStem).json")
                })
            self.workflowREPLMountPathsByWorkflowID = workflowREPLMountPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: attachments.map { attachment in
                    let fileStem = KistRunner.smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
                    return (attachment.workflowID, "repl-mounts/\(fileStem).json")
                })
            self.workflowModelToolPathsByWorkflowID = workflowModelToolPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: attachments.map { attachment in
                    let fileStem = KistRunner.smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
                    return (attachment.workflowID, "model-tools/\(fileStem).json")
                })
            self.workflowOnyxDriverPathsByWorkflowID = workflowOnyxDriverPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: attachments.map { attachment in
                    let fileStem = KistRunner.smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
                    return (attachment.workflowID, "onyx-drivers/\(fileStem).json")
                })
            self.workflowSkillTreePathsByWorkflowID = workflowSkillTreePathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: attachments.map { attachment in
                    let fileStem = KistRunner.smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
                    return (attachment.workflowID, "skill-trees/\(fileStem).json")
                })
            self.workflowToolBindingPathsByWorkflowID = workflowToolBindingPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: attachments.map { attachment in
                    let fileStem = KistRunner.smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
                    return (attachment.workflowID, "tool-bindings/\(fileStem).json")
                })
            self.workflowPlanningBundlePathsByWorkflowID = workflowPlanningBundlePathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: attachments.map { attachment in
                    let fileStem = KistRunner.smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
                    return (attachment.workflowID, "planning/\(fileStem).json")
                })
            self.workflowRunbookPathsByWorkflowID = workflowRunbookPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: attachments.map { attachment in
                    let fileStem = KistRunner.smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
                    return (attachment.workflowID, "workflow-runbooks/\(fileStem).json")
                })
            self.workflowBindingPathsByWorkflowID = workflowBindingPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: attachments.map { attachment in
                    let fileStem = KistRunner.smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
                    return (attachment.workflowID, "workflow-bindings/\(fileStem).json")
                })
            self.runtimeWorkflowMetadataByWorkflowID = runtimeWorkflowMetadataByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: attachments.map {
                    ($0.workflowID, KistRunner.smlRuntimeWorkflowMetadataLinks(for: $0))
                })
            self.files = files.sorted {
                if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
                return $0.sha256 < $1.sha256
            }
            self.launchDescriptor = launchDescriptor
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case sourcePath
            case sourceFormat
            case outputDirectory
            case indexPath
            case runbookPath
            case workflowIDs
            case apiBasePaths
            case workflowAPIMountPathsByWorkflowID
            case workflowREPLMountPathsByWorkflowID
            case workflowModelToolPathsByWorkflowID
            case workflowOnyxDriverPathsByWorkflowID
            case workflowSkillTreePathsByWorkflowID
            case workflowToolBindingPathsByWorkflowID
            case workflowPlanningBundlePathsByWorkflowID
            case workflowRunbookPathsByWorkflowID
            case workflowBindingPathsByWorkflowID
            case runtimeWorkflowMetadataByWorkflowID
            case files
            case launchDescriptor
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            let sourcePath = try container.decode(String.self, forKey: .sourcePath)
            let sourceFormat = try container.decode(
                SMLRuntimeHostExportSourceFormat.self,
                forKey: .sourceFormat
            )
            let outputDirectory = try container.decode(String.self, forKey: .outputDirectory)
            let indexPath = try container.decodeIfPresent(String.self, forKey: .indexPath)
                ?? "scaffold.json"
            let runbookPath = try container.decodeIfPresent(String.self, forKey: .runbookPath)
                ?? "runbook.json"
            let workflowIDs = try container.decode([String].self, forKey: .workflowIDs)
            let apiBasePaths = try container.decode([String].self, forKey: .apiBasePaths)
            let workflowAPIMountPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowAPIMountPathsByWorkflowID
            )
            let workflowREPLMountPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowREPLMountPathsByWorkflowID
            )
            let workflowModelToolPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowModelToolPathsByWorkflowID
            )
            let workflowOnyxDriverPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowOnyxDriverPathsByWorkflowID
            )
            let workflowSkillTreePathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowSkillTreePathsByWorkflowID
            )
            let workflowToolBindingPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowToolBindingPathsByWorkflowID
            )
            let workflowPlanningBundlePathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowPlanningBundlePathsByWorkflowID
            )
            let workflowRunbookPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowRunbookPathsByWorkflowID
            )
            let workflowBindingPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowBindingPathsByWorkflowID
            )
            let runtimeWorkflowMetadataByWorkflowID = try container.decodeIfPresent(
                [String: SMLWorkflowRuntimeWorkflowMetadataLinks].self,
                forKey: .runtimeWorkflowMetadataByWorkflowID
            )
            let files = try container.decode([SMLRuntimeHostScaffoldFile].self, forKey: .files)
            let launchDescriptor = try container.decode(
                SMLWorkflowRuntimeLaunchDescriptor.self,
                forKey: .launchDescriptor
            )
            self.init(
                schemaVersion: schemaVersion,
                sourcePath: sourcePath,
                sourceFormat: sourceFormat,
                outputDirectory: outputDirectory,
                indexPath: indexPath,
                runbookPath: runbookPath,
                workflowIDs: workflowIDs,
                apiBasePaths: apiBasePaths,
                workflowAPIMountPathsByWorkflowID: workflowAPIMountPathsByWorkflowID,
                workflowREPLMountPathsByWorkflowID: workflowREPLMountPathsByWorkflowID,
                workflowModelToolPathsByWorkflowID: workflowModelToolPathsByWorkflowID,
                workflowOnyxDriverPathsByWorkflowID: workflowOnyxDriverPathsByWorkflowID,
                workflowSkillTreePathsByWorkflowID: workflowSkillTreePathsByWorkflowID,
                workflowToolBindingPathsByWorkflowID: workflowToolBindingPathsByWorkflowID,
                workflowPlanningBundlePathsByWorkflowID: workflowPlanningBundlePathsByWorkflowID,
                workflowRunbookPathsByWorkflowID: workflowRunbookPathsByWorkflowID,
                workflowBindingPathsByWorkflowID: workflowBindingPathsByWorkflowID,
                runtimeWorkflowMetadataByWorkflowID: runtimeWorkflowMetadataByWorkflowID,
                files: files,
                launchDescriptor: launchDescriptor
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(sourcePath, forKey: .sourcePath)
            try container.encode(sourceFormat, forKey: .sourceFormat)
            try container.encode(outputDirectory, forKey: .outputDirectory)
            try container.encode(indexPath, forKey: .indexPath)
            try container.encode(runbookPath, forKey: .runbookPath)
            try container.encode(workflowIDs, forKey: .workflowIDs)
            try container.encode(apiBasePaths, forKey: .apiBasePaths)
            try container.encode(workflowAPIMountPathsByWorkflowID, forKey: .workflowAPIMountPathsByWorkflowID)
            try container.encode(workflowREPLMountPathsByWorkflowID, forKey: .workflowREPLMountPathsByWorkflowID)
            try container.encode(workflowModelToolPathsByWorkflowID, forKey: .workflowModelToolPathsByWorkflowID)
            try container.encode(workflowOnyxDriverPathsByWorkflowID, forKey: .workflowOnyxDriverPathsByWorkflowID)
            try container.encode(workflowSkillTreePathsByWorkflowID, forKey: .workflowSkillTreePathsByWorkflowID)
            try container.encode(workflowToolBindingPathsByWorkflowID, forKey: .workflowToolBindingPathsByWorkflowID)
            try container.encode(workflowPlanningBundlePathsByWorkflowID, forKey: .workflowPlanningBundlePathsByWorkflowID)
            try container.encode(workflowRunbookPathsByWorkflowID, forKey: .workflowRunbookPathsByWorkflowID)
            try container.encode(workflowBindingPathsByWorkflowID, forKey: .workflowBindingPathsByWorkflowID)
            try container.encode(runtimeWorkflowMetadataByWorkflowID, forKey: .runtimeWorkflowMetadataByWorkflowID)
            try container.encode(files, forKey: .files)
            try container.encode(launchDescriptor, forKey: .launchDescriptor)
        }
    }

    struct SMLRuntimeHostScaffoldRunbookArtifacts: Sendable, Codable, Equatable {
        let scaffoldIndexPath: String
        let readmePath: String
        let runtimeSourcePackagePath: String
        let runtimeExportPath: String
        let catalogPath: String
        let mountPath: String
        let launchPath: String
        let openAPIPath: String
        let modelToolsPath: String
        let modelRouterPath: String
        let onyxDriversPath: String
        let planningPath: String
        let workflowAPIMountsPath: String
        let workflowREPLMountsPath: String
        let workflowModelToolsPath: String
        let workflowOnyxDriversPath: String
        let workflowSkillTreesPath: String
        let workflowToolBindingsPath: String
        let workflowPlanningPath: String
        let workflowRunbooksPath: String
        let workflowBindingsPath: String
        let agentGuidePath: String
        let hostGuidePath: String
        let hostWiringPath: String
        let attachmentsPath: String

        init(
            scaffoldIndexPath: String = "scaffold.json",
            readmePath: String = "README.md",
            runtimeSourcePackagePath: String = "runtime-source-package.json",
            runtimeExportPath: String = "runtime-export.json",
            catalogPath: String = "catalog.json",
            mountPath: String = "mount.json",
            launchPath: String = "launch.json",
            openAPIPath: String = "openapi.json",
            modelToolsPath: String = "model-tools.json",
            modelRouterPath: String = "model-router.json",
            onyxDriversPath: String = "onyx-drivers.json",
            planningPath: String = "planning.json",
            workflowAPIMountsPath: String = "api-mounts",
            workflowREPLMountsPath: String = "repl-mounts",
            workflowModelToolsPath: String = "model-tools",
            workflowOnyxDriversPath: String = "onyx-drivers",
            workflowSkillTreesPath: String = "skill-trees",
            workflowToolBindingsPath: String = "tool-bindings",
            workflowPlanningPath: String = "planning",
            workflowRunbooksPath: String = "workflow-runbooks",
            workflowBindingsPath: String = "workflow-bindings",
            agentGuidePath: String = "agent-guide.json",
            hostGuidePath: String = "host-guide.json",
            hostWiringPath: String = "host-wiring.json",
            attachmentsPath: String = "attachments.json"
        ) {
            self.scaffoldIndexPath = scaffoldIndexPath
            self.readmePath = readmePath
            self.runtimeSourcePackagePath = runtimeSourcePackagePath
            self.runtimeExportPath = runtimeExportPath
            self.catalogPath = catalogPath
            self.mountPath = mountPath
            self.launchPath = launchPath
            self.openAPIPath = openAPIPath
            self.modelToolsPath = modelToolsPath
            self.modelRouterPath = modelRouterPath
            self.onyxDriversPath = onyxDriversPath
            self.planningPath = planningPath
            self.workflowAPIMountsPath = workflowAPIMountsPath
            self.workflowREPLMountsPath = workflowREPLMountsPath
            self.workflowModelToolsPath = workflowModelToolsPath
            self.workflowOnyxDriversPath = workflowOnyxDriversPath
            self.workflowSkillTreesPath = workflowSkillTreesPath
            self.workflowToolBindingsPath = workflowToolBindingsPath
            self.workflowPlanningPath = workflowPlanningPath
            self.workflowRunbooksPath = workflowRunbooksPath
            self.workflowBindingsPath = workflowBindingsPath
            self.agentGuidePath = agentGuidePath
            self.hostGuidePath = hostGuidePath
            self.hostWiringPath = hostWiringPath
            self.attachmentsPath = attachmentsPath
        }

        private enum CodingKeys: String, CodingKey {
            case scaffoldIndexPath
            case readmePath
            case runtimeSourcePackagePath
            case runtimeExportPath
            case catalogPath
            case mountPath
            case launchPath
            case openAPIPath
            case modelToolsPath
            case modelRouterPath
            case onyxDriversPath
            case planningPath
            case workflowAPIMountsPath
            case workflowREPLMountsPath
            case workflowModelToolsPath
            case workflowOnyxDriversPath
            case workflowSkillTreesPath
            case workflowToolBindingsPath
            case workflowPlanningPath
            case workflowRunbooksPath
            case workflowBindingsPath
            case agentGuidePath
            case hostGuidePath
            case hostWiringPath
            case attachmentsPath
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                scaffoldIndexPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .scaffoldIndexPath
                ) ?? "scaffold.json",
                readmePath: try container.decodeIfPresent(
                    String.self,
                    forKey: .readmePath
                ) ?? "README.md",
                runtimeSourcePackagePath: try container.decodeIfPresent(
                    String.self,
                    forKey: .runtimeSourcePackagePath
                ) ?? "runtime-source-package.json",
                runtimeExportPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .runtimeExportPath
                ) ?? "runtime-export.json",
                catalogPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .catalogPath
                ) ?? "catalog.json",
                mountPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .mountPath
                ) ?? "mount.json",
                launchPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .launchPath
                ) ?? "launch.json",
                openAPIPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .openAPIPath
                ) ?? "openapi.json",
                modelToolsPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .modelToolsPath
                ) ?? "model-tools.json",
                modelRouterPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .modelRouterPath
                ) ?? "model-router.json",
                onyxDriversPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .onyxDriversPath
                ) ?? "onyx-drivers.json",
                planningPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .planningPath
                ) ?? "planning.json",
                workflowAPIMountsPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .workflowAPIMountsPath
                ) ?? "api-mounts",
                workflowREPLMountsPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .workflowREPLMountsPath
                ) ?? "repl-mounts",
                workflowModelToolsPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .workflowModelToolsPath
                ) ?? "model-tools",
                workflowOnyxDriversPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .workflowOnyxDriversPath
                ) ?? "onyx-drivers",
                workflowSkillTreesPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .workflowSkillTreesPath
                ) ?? "skill-trees",
                workflowToolBindingsPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .workflowToolBindingsPath
                ) ?? "tool-bindings",
                workflowPlanningPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .workflowPlanningPath
                ) ?? "planning",
                workflowRunbooksPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .workflowRunbooksPath
                ) ?? "workflow-runbooks",
                workflowBindingsPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .workflowBindingsPath
                ) ?? "workflow-bindings",
                agentGuidePath: try container.decodeIfPresent(
                    String.self,
                    forKey: .agentGuidePath
                ) ?? "agent-guide.json",
                hostGuidePath: try container.decodeIfPresent(
                    String.self,
                    forKey: .hostGuidePath
                ) ?? "host-guide.json",
                hostWiringPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .hostWiringPath
                ) ?? "host-wiring.json",
                attachmentsPath: try container.decodeIfPresent(
                    String.self,
                    forKey: .attachmentsPath
                ) ?? "attachments.json"
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(scaffoldIndexPath, forKey: .scaffoldIndexPath)
            try container.encode(readmePath, forKey: .readmePath)
            try container.encode(runtimeSourcePackagePath, forKey: .runtimeSourcePackagePath)
            try container.encode(runtimeExportPath, forKey: .runtimeExportPath)
            try container.encode(catalogPath, forKey: .catalogPath)
            try container.encode(mountPath, forKey: .mountPath)
            try container.encode(launchPath, forKey: .launchPath)
            try container.encode(openAPIPath, forKey: .openAPIPath)
            try container.encode(modelToolsPath, forKey: .modelToolsPath)
            try container.encode(modelRouterPath, forKey: .modelRouterPath)
            try container.encode(onyxDriversPath, forKey: .onyxDriversPath)
            try container.encode(planningPath, forKey: .planningPath)
            try container.encode(workflowAPIMountsPath, forKey: .workflowAPIMountsPath)
            try container.encode(workflowREPLMountsPath, forKey: .workflowREPLMountsPath)
            try container.encode(workflowModelToolsPath, forKey: .workflowModelToolsPath)
            try container.encode(workflowOnyxDriversPath, forKey: .workflowOnyxDriversPath)
            try container.encode(workflowSkillTreesPath, forKey: .workflowSkillTreesPath)
            try container.encode(workflowToolBindingsPath, forKey: .workflowToolBindingsPath)
            try container.encode(workflowPlanningPath, forKey: .workflowPlanningPath)
            try container.encode(workflowRunbooksPath, forKey: .workflowRunbooksPath)
            try container.encode(workflowBindingsPath, forKey: .workflowBindingsPath)
            try container.encode(agentGuidePath, forKey: .agentGuidePath)
            try container.encode(hostGuidePath, forKey: .hostGuidePath)
            try container.encode(hostWiringPath, forKey: .hostWiringPath)
            try container.encode(attachmentsPath, forKey: .attachmentsPath)
        }
    }

    struct SMLRuntimeHostScaffoldWorkflowPlanningBundle: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let workflowID: String
        let workflowVersion: String
        let workflowName: String
        let role: String
        let apiBasePath: String
        let apiWorkflowPath: String
        let planningWorkflowID: String?
        let plannerEntrypoint: String?
        let plan: SMLOnyxPlan?
        let skillIndex: [SMLWorkflowRuntimePlanningSkillIndexEntry]
        let toolReferences: [String]
        let toolBindings: [SMLOnyxToolBinding]
        let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
        let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]
        let commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]

        init(
            schemaVersion: Int = SMLRuntimeHostScaffoldWorkflowPlanningBundle.currentSchemaVersion,
            attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest
        ) {
            self.schemaVersion = schemaVersion
            workflowID = attachment.workflowID
            workflowVersion = attachment.workflowVersion
            workflowName = attachment.workflowName
            role = attachment.role
            apiBasePath = attachment.apiBasePath
            apiWorkflowPath = attachment.apiWorkflowPath
            planningWorkflowID = attachment.planningWorkflowID
            plannerEntrypoint = attachment.plannerEntrypoint
            plan = attachment.plan
            skillIndex = attachment.skillIndex
            toolReferences = attachment.toolReferences
            toolBindings = attachment.toolBindings
            decomposableUnits = attachment.decomposableUnits
            approvalGates = attachment.approvalGates
            commandBindings = attachment.commandBindings
        }
    }

    struct SMLRuntimeHostScaffoldWorkflowBinding: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let workflowID: String
        let workflowVersion: String
        let workflowName: String
        let role: String
        let apiBasePath: String
        let apiWorkflowPath: String
        let apiTaskPath: String
        let hostBindingChannels: [SMLWorkflowRuntimeHostBindingChannel]
        let localArtifactPathsByChannel: [String: String]
        let runtimeMetadataPathsByChannel: [String: String]
        let attachmentPath: String
        let workflowRunbookPath: String
        let replScriptPath: String
        let replMountPath: String
        let apiScriptPath: String
        let apiMountPath: String
        let modelScriptPath: String
        let modelToolPath: String
        let onyxDriverPath: String
        let skillTreePath: String
        let toolBindingsPath: String
        let planningBundlePath: String
        let runtimeWorkflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks
        let runtimeWorkflowAttachmentPath: String
        let runtimeWorkflowREPLMountPath: String
        let runtimeWorkflowAPIMountPath: String
        let runtimeWorkflowModelToolPath: String
        let runtimeWorkflowOnyxDriverPath: String
        let runtimeWorkflowSkillTreePath: String
        let runtimeWorkflowToolBindingsPath: String
        let runtimeWorkflowPlanningPath: String
        let modelToolName: String
        let modelRouterToolName: String
        let onyxDriverID: String
        let planningWorkflowID: String?
        let plannerEntrypoint: String?
        let skillIDs: [String]
        let toolReferences: [String]
        let decomposableUnitIDs: [String]
        let approvalGateIDs: [String]
        let commandActions: [String]
        let replTranscriptCommand: SMLRuntimeHostScaffoldCommandTemplate
        let apiTranscriptCommand: SMLRuntimeHostScaffoldCommandTemplate
        let modelTranscriptCommand: SMLRuntimeHostScaffoldCommandTemplate

        init(
            schemaVersion: Int = SMLRuntimeHostScaffoldWorkflowBinding.currentSchemaVersion,
            workflowRunbook: SMLRuntimeHostScaffoldWorkflowRunbook
        ) {
            self.schemaVersion = schemaVersion
            workflowID = workflowRunbook.workflowID
            workflowVersion = workflowRunbook.workflowVersion
            workflowName = workflowRunbook.workflowName
            role = workflowRunbook.role
            apiBasePath = workflowRunbook.apiBasePath
            apiWorkflowPath = workflowRunbook.apiWorkflowPath
            apiTaskPath = workflowRunbook.apiEndpoints.first { $0.action == .start }?.pathTemplate
                ?? "\(workflowRunbook.apiBasePath)\(workflowRunbook.apiWorkflowPath)/tasks"
            hostBindingChannels = workflowRunbook.hostBindingChannels

            let localPathsByChannel = [
                SMLWorkflowRuntimeHostBindingChannel.agentGuide.rawValue: "agent-guide.json",
                SMLWorkflowRuntimeHostBindingChannel.customAPI.rawValue: workflowRunbook.apiMountPath,
                SMLWorkflowRuntimeHostBindingChannel.customREPL.rawValue: workflowRunbook.replMountPath,
                SMLWorkflowRuntimeHostBindingChannel.modelRouter.rawValue: "model-router.json",
                SMLWorkflowRuntimeHostBindingChannel.modelTool.rawValue: workflowRunbook.modelToolPath,
                SMLWorkflowRuntimeHostBindingChannel.onyxDriver.rawValue: workflowRunbook.onyxDriverPath,
                SMLWorkflowRuntimeHostBindingChannel.planningWorkflow.rawValue: workflowRunbook.planningBundlePath,
                SMLWorkflowRuntimeHostBindingChannel.skillTree.rawValue: workflowRunbook.skillTreePath,
                SMLWorkflowRuntimeHostBindingChannel.toolBindings.rawValue: workflowRunbook.toolBindingsPath,
            ]
            localArtifactPathsByChannel = Dictionary(uniqueKeysWithValues: hostBindingChannels.compactMap { channel in
                localPathsByChannel[channel.rawValue].map { (channel.rawValue, $0) }
            })

            let metadataPathsByChannel = [
                SMLWorkflowRuntimeHostBindingChannel.agentGuide.rawValue: "\(workflowRunbook.apiBasePath)/runtime/agent-guide",
                SMLWorkflowRuntimeHostBindingChannel.customAPI.rawValue: workflowRunbook.runtimeWorkflowAPIMountPath,
                SMLWorkflowRuntimeHostBindingChannel.customREPL.rawValue: workflowRunbook.runtimeWorkflowREPLMountPath,
                SMLWorkflowRuntimeHostBindingChannel.modelRouter.rawValue: "\(workflowRunbook.apiBasePath)/runtime/model-router",
                SMLWorkflowRuntimeHostBindingChannel.modelTool.rawValue: workflowRunbook.runtimeWorkflowModelToolPath,
                SMLWorkflowRuntimeHostBindingChannel.onyxDriver.rawValue: workflowRunbook.runtimeWorkflowOnyxDriverPath,
                SMLWorkflowRuntimeHostBindingChannel.planningWorkflow.rawValue: workflowRunbook.runtimeWorkflowPlanningPath,
                SMLWorkflowRuntimeHostBindingChannel.skillTree.rawValue: workflowRunbook.runtimeWorkflowSkillTreePath,
                SMLWorkflowRuntimeHostBindingChannel.toolBindings.rawValue: workflowRunbook.runtimeWorkflowToolBindingsPath,
            ]
            runtimeMetadataPathsByChannel = Dictionary(uniqueKeysWithValues: hostBindingChannels.compactMap { channel in
                metadataPathsByChannel[channel.rawValue].map { (channel.rawValue, $0) }
            })

            attachmentPath = workflowRunbook.attachmentPath
            workflowRunbookPath = workflowRunbook.workflowRunbookPath
            replScriptPath = workflowRunbook.replScriptPath
            replMountPath = workflowRunbook.replMountPath
            apiScriptPath = workflowRunbook.apiScriptPath
            apiMountPath = workflowRunbook.apiMountPath
            modelScriptPath = workflowRunbook.modelScriptPath
            modelToolPath = workflowRunbook.modelToolPath
            onyxDriverPath = workflowRunbook.onyxDriverPath
            skillTreePath = workflowRunbook.skillTreePath
            toolBindingsPath = workflowRunbook.toolBindingsPath
            planningBundlePath = workflowRunbook.planningBundlePath
            runtimeWorkflowMetadata = workflowRunbook.runtimeWorkflowMetadata
            runtimeWorkflowAttachmentPath = workflowRunbook.runtimeWorkflowAttachmentPath
            runtimeWorkflowREPLMountPath = workflowRunbook.runtimeWorkflowREPLMountPath
            runtimeWorkflowAPIMountPath = workflowRunbook.runtimeWorkflowAPIMountPath
            runtimeWorkflowModelToolPath = workflowRunbook.runtimeWorkflowModelToolPath
            runtimeWorkflowOnyxDriverPath = workflowRunbook.runtimeWorkflowOnyxDriverPath
            runtimeWorkflowSkillTreePath = workflowRunbook.runtimeWorkflowSkillTreePath
            runtimeWorkflowToolBindingsPath = workflowRunbook.runtimeWorkflowToolBindingsPath
            runtimeWorkflowPlanningPath = workflowRunbook.runtimeWorkflowPlanningPath
            modelToolName = workflowRunbook.modelToolName
            modelRouterToolName = workflowRunbook.modelRouterToolName
            onyxDriverID = workflowRunbook.onyxDriverID
            planningWorkflowID = workflowRunbook.planningWorkflowID
            plannerEntrypoint = workflowRunbook.plannerEntrypoint
            skillIDs = workflowRunbook.skillIDs
            toolReferences = workflowRunbook.toolReferences
            decomposableUnitIDs = workflowRunbook.decomposableUnitIDs
            approvalGateIDs = workflowRunbook.approvalGateIDs
            commandActions = workflowRunbook.commandActions
            replTranscriptCommand = workflowRunbook.replTranscriptCommand
            apiTranscriptCommand = workflowRunbook.apiTranscriptCommand
            modelTranscriptCommand = workflowRunbook.modelTranscriptCommand
        }
    }

    struct SMLRuntimeHostScaffoldCommandTemplate: Sendable, Codable, Equatable {
        let executable: String
        let workingDirectory: String
        let arguments: [String]
        let requiresProviderBinding: Bool
        let summary: String

        init(
            executable: String = "kist",
            workingDirectory: String,
            arguments: [String],
            requiresProviderBinding: Bool = false,
            summary: String
        ) {
            self.executable = executable
            self.workingDirectory = workingDirectory
            self.arguments = arguments
            self.requiresProviderBinding = requiresProviderBinding
            self.summary = summary
        }
    }

    struct SMLRuntimeHostScaffoldEndpointReference: Sendable, Codable, Equatable {
        let method: SMLWorkflowAPIMethod
        let pathTemplate: String
        let operationID: String
        let action: SMLWorkflowControlAction?

        init(route: SMLWorkflowRuntimeAPIMount) {
            method = route.method
            pathTemplate = route.pathTemplate
            operationID = route.operationID
            action = route.action
        }
    }

}
