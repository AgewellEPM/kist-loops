import Foundation
import AgentCore

extension KistRunner {
    struct SMLRuntimeHostScaffoldWorkflowRunbook: Sendable, Codable, Equatable {
        let workflowID: String
        let workflowVersion: String
        let workflowName: String
        let role: String
        let apiBasePath: String
        let apiWorkflowPath: String
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
        let workflowBindingPath: String
        let hostBindingChannels: [SMLWorkflowRuntimeHostBindingChannel]
        let runtimeWorkflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks
        let runtimeWorkflowAttachmentPath: String
        let runtimeWorkflowREPLMountPath: String
        let runtimeWorkflowAPIMountPath: String
        let runtimeWorkflowModelToolPath: String
        let runtimeWorkflowOnyxDriverPath: String
        let runtimeWorkflowSkillTreePath: String
        let runtimeWorkflowToolBindingsPath: String
        let runtimeWorkflowPlanningPath: String
        let replMount: SMLWorkflowRuntimeREPLMount
        let replGrammar: String
        let replCommands: [SMLWorkflowREPLCommandDescriptor]
        let replExamples: [SMLWorkflowREPLExample]
        let apiMounts: [SMLWorkflowRuntimeAPIMount]
        let modelTool: SMLWorkflowRuntimeModelToolExport
        let replScript: String
        let apiScript: [SMLRuntimeHostAPIRequestSpec]
        let modelScript: String
        let replTranscriptCommand: SMLRuntimeHostScaffoldCommandTemplate
        let apiTranscriptCommand: SMLRuntimeHostScaffoldCommandTemplate
        let modelTranscriptCommand: SMLRuntimeHostScaffoldCommandTemplate
        let apiEndpoints: [SMLRuntimeHostScaffoldEndpointReference]
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

        init(
            attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest,
            outputDirectory: String
        ) {
            let fileStem = KistRunner.smlRuntimeScaffoldSafeFileStem(attachment.workflowID)
            workflowID = attachment.workflowID
            workflowVersion = attachment.workflowVersion
            workflowName = attachment.workflowName
            role = attachment.role
            apiBasePath = attachment.apiBasePath
            apiWorkflowPath = attachment.apiWorkflowPath
            attachmentPath = "attachments/\(fileStem).json"
            workflowRunbookPath = "workflow-runbooks/\(fileStem).json"
            replScriptPath = "repl-scripts/\(fileStem).repl"
            replMountPath = "repl-mounts/\(fileStem).json"
            apiScriptPath = "api-scripts/\(fileStem).json"
            apiMountPath = "api-mounts/\(fileStem).json"
            modelScriptPath = "model-scripts/\(fileStem).prompts"
            modelToolPath = "model-tools/\(fileStem).json"
            onyxDriverPath = "onyx-drivers/\(fileStem).json"
            skillTreePath = "skill-trees/\(fileStem).json"
            toolBindingsPath = "tool-bindings/\(fileStem).json"
            planningBundlePath = "planning/\(fileStem).json"
            workflowBindingPath = "workflow-bindings/\(fileStem).json"
            hostBindingChannels = attachment.channels
            let metadata = KistRunner.smlRuntimeWorkflowMetadataLinks(for: attachment)
            runtimeWorkflowMetadata = metadata
            runtimeWorkflowAttachmentPath = metadata.attachmentPath
            runtimeWorkflowREPLMountPath = metadata.replMountPath
            runtimeWorkflowAPIMountPath = metadata.apiMountPath
            runtimeWorkflowModelToolPath = metadata.modelToolPath
            runtimeWorkflowOnyxDriverPath = metadata.onyxDriverPath
            runtimeWorkflowSkillTreePath = metadata.skillTreePath
            runtimeWorkflowToolBindingsPath = metadata.toolBindingsPath
            runtimeWorkflowPlanningPath = metadata.planningBundlePath
            replMount = attachment.replMount
            replGrammar = attachment.replMount.grammar
            replCommands = attachment.replMount.commands
            replExamples = attachment.replMount.examples
            apiMounts = attachment.apiRoutes
            modelTool = KistRunner.smlRuntimeModelToolExport(for: attachment)
            replScript = KistRunner.smlRuntimeScaffoldREPLScript(for: attachment)
            apiScript = KistRunner.smlRuntimeScaffoldAPIScript(for: attachment)
            modelScript = KistRunner.smlRuntimeScaffoldModelScript(for: attachment)
            replTranscriptCommand = SMLRuntimeHostScaffoldCommandTemplate(
                workingDirectory: outputDirectory,
                arguments: [
                    "--sml-runtime-repl-script", ".",
                    "--sml-script", "repl-scripts/\(fileStem).repl",
                    "--sml-workflow", attachment.workflowID,
                ],
                summary: "Replay the generated REPL script and emit a workflow REPL transcript."
            )
            apiTranscriptCommand = SMLRuntimeHostScaffoldCommandTemplate(
                workingDirectory: outputDirectory,
                arguments: [
                    "--sml-runtime-api-script", ".",
                    "--sml-api-script", "api-scripts/\(fileStem).json",
                ],
                summary: "Replay the generated API request script and emit a generated API transcript."
            )
            modelTranscriptCommand = SMLRuntimeHostScaffoldCommandTemplate(
                workingDirectory: outputDirectory,
                arguments: [
                    "--sml-runtime-model-script", ".",
                    "--sml-model-script", "model-scripts/\(fileStem).prompts",
                    "--provider", "<provider>",
                    "--model", "<model>",
                ],
                requiresProviderBinding: true,
                summary: "Replay the generated model prompt script through the native model-router tool."
            )
            apiEndpoints = attachment.apiRoutes.map(SMLRuntimeHostScaffoldEndpointReference.init).sorted {
                if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
                if $0.method.rawValue != $1.method.rawValue {
                    return $0.method.rawValue < $1.method.rawValue
                }
                return $0.operationID < $1.operationID
            }
            modelToolName = attachment.modelToolName
            modelRouterToolName = attachment.modelRouterToolName
            onyxDriverID = attachment.onyxDriverID
            planningWorkflowID = attachment.planningWorkflowID
            plannerEntrypoint = attachment.plannerEntrypoint
            skillIDs = Array(Set(attachment.skillTree.map(\.id))).sorted()
            toolReferences = attachment.toolReferences
            decomposableUnitIDs = Array(Set(attachment.decomposableUnits.map(\.instructionID))).sorted()
            approvalGateIDs = Array(Set(attachment.approvalGates.map(\.instructionID))).sorted()
            commandActions = Array(Set(attachment.commandBindings.map { $0.action.rawValue })).sorted()
        }

        private enum CodingKeys: String, CodingKey {
            case workflowID
            case workflowVersion
            case workflowName
            case role
            case apiBasePath
            case apiWorkflowPath
            case attachmentPath
            case workflowRunbookPath
            case replScriptPath
            case replMountPath
            case apiScriptPath
            case apiMountPath
            case modelScriptPath
            case modelToolPath
            case onyxDriverPath
            case skillTreePath
            case toolBindingsPath
            case planningBundlePath
            case workflowBindingPath
            case hostBindingChannels
            case runtimeWorkflowMetadata
            case runtimeWorkflowAttachmentPath
            case runtimeWorkflowREPLMountPath
            case runtimeWorkflowAPIMountPath
            case runtimeWorkflowModelToolPath
            case runtimeWorkflowOnyxDriverPath
            case runtimeWorkflowSkillTreePath
            case runtimeWorkflowToolBindingsPath
            case runtimeWorkflowPlanningPath
            case replMount
            case replGrammar
            case replCommands
            case replExamples
            case apiMounts
            case modelTool
            case replScript
            case apiScript
            case modelScript
            case replTranscriptCommand
            case apiTranscriptCommand
            case modelTranscriptCommand
            case apiEndpoints
            case modelToolName
            case modelRouterToolName
            case onyxDriverID
            case planningWorkflowID
            case plannerEntrypoint
            case skillIDs
            case toolReferences
            case decomposableUnitIDs
            case approvalGateIDs
            case commandActions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            workflowID = try container.decode(String.self, forKey: .workflowID)
            workflowVersion = try container.decode(String.self, forKey: .workflowVersion)
            workflowName = try container.decode(String.self, forKey: .workflowName)
            role = try container.decode(String.self, forKey: .role)
            apiBasePath = try container.decode(String.self, forKey: .apiBasePath)
            apiWorkflowPath = try container.decode(String.self, forKey: .apiWorkflowPath)
            attachmentPath = try container.decode(String.self, forKey: .attachmentPath)
            workflowRunbookPath = try container.decode(String.self, forKey: .workflowRunbookPath)
            replScriptPath = try container.decode(String.self, forKey: .replScriptPath)
            replMountPath = try container.decodeIfPresent(String.self, forKey: .replMountPath)
                ?? "repl-mounts/\(KistRunner.smlRuntimeScaffoldSafeFileStem(workflowID)).json"
            apiScriptPath = try container.decode(String.self, forKey: .apiScriptPath)
            apiMountPath = try container.decodeIfPresent(String.self, forKey: .apiMountPath)
                ?? "api-mounts/\(KistRunner.smlRuntimeScaffoldSafeFileStem(workflowID)).json"
            modelScriptPath = try container.decode(String.self, forKey: .modelScriptPath)
            modelToolPath = try container.decodeIfPresent(String.self, forKey: .modelToolPath)
                ?? "model-tools/\(KistRunner.smlRuntimeScaffoldSafeFileStem(workflowID)).json"
            onyxDriverPath = try container.decode(String.self, forKey: .onyxDriverPath)
            skillTreePath = try container.decode(String.self, forKey: .skillTreePath)
            toolBindingsPath = try container.decode(String.self, forKey: .toolBindingsPath)
            planningBundlePath = try container.decode(String.self, forKey: .planningBundlePath)
            workflowBindingPath = try container.decodeIfPresent(String.self, forKey: .workflowBindingPath)
                ?? "workflow-bindings/\(KistRunner.smlRuntimeScaffoldSafeFileStem(workflowID)).json"
            hostBindingChannels = Array(Set(try container.decodeIfPresent(
                [SMLWorkflowRuntimeHostBindingChannel].self,
                forKey: .hostBindingChannels
            ) ?? [])).sorted { $0.rawValue < $1.rawValue }
            let decodedModelToolName = try container.decode(String.self, forKey: .modelToolName)
            let decodedModelRouterToolName = try container.decode(String.self, forKey: .modelRouterToolName)
            let decodedOnyxDriverID = try container.decode(String.self, forKey: .onyxDriverID)
            let decodedRuntimeWorkflowAttachmentPath = try container.decodeIfPresent(
                String.self,
                forKey: .runtimeWorkflowAttachmentPath
            )
            let decodedRuntimeWorkflowREPLMountPath = try container.decodeIfPresent(
                String.self,
                forKey: .runtimeWorkflowREPLMountPath
            )
            let decodedRuntimeWorkflowAPIMountPath = try container.decodeIfPresent(
                String.self,
                forKey: .runtimeWorkflowAPIMountPath
            )
            let decodedRuntimeWorkflowModelToolPath = try container.decodeIfPresent(
                String.self,
                forKey: .runtimeWorkflowModelToolPath
            )
            let decodedRuntimeWorkflowOnyxDriverPath = try container.decodeIfPresent(
                String.self,
                forKey: .runtimeWorkflowOnyxDriverPath
            )
            let decodedRuntimeWorkflowSkillTreePath = try container.decodeIfPresent(
                String.self,
                forKey: .runtimeWorkflowSkillTreePath
            )
            let decodedRuntimeWorkflowToolBindingsPath = try container.decodeIfPresent(
                String.self,
                forKey: .runtimeWorkflowToolBindingsPath
            )
            let decodedRuntimeWorkflowPlanningPath = try container.decodeIfPresent(
                String.self,
                forKey: .runtimeWorkflowPlanningPath
            )
            let metadata = try container.decodeIfPresent(
                SMLWorkflowRuntimeWorkflowMetadataLinks.self,
                forKey: .runtimeWorkflowMetadata
            ) ?? SMLWorkflowRuntimeWorkflowMetadataLinks(
                workflowID: workflowID,
                workflowVersion: workflowVersion,
                apiBasePath: apiBasePath,
                attachmentPath: decodedRuntimeWorkflowAttachmentPath,
                replMountPath: decodedRuntimeWorkflowREPLMountPath,
                apiMountPath: decodedRuntimeWorkflowAPIMountPath,
                modelToolPath: decodedRuntimeWorkflowModelToolPath,
                onyxDriverPath: decodedRuntimeWorkflowOnyxDriverPath,
                skillTreePath: decodedRuntimeWorkflowSkillTreePath,
                toolBindingsPath: decodedRuntimeWorkflowToolBindingsPath,
                planningBundlePath: decodedRuntimeWorkflowPlanningPath
            )
            runtimeWorkflowMetadata = metadata
            runtimeWorkflowAttachmentPath = decodedRuntimeWorkflowAttachmentPath ?? metadata.attachmentPath
            runtimeWorkflowREPLMountPath = decodedRuntimeWorkflowREPLMountPath ?? metadata.replMountPath
            runtimeWorkflowAPIMountPath = decodedRuntimeWorkflowAPIMountPath ?? metadata.apiMountPath
            runtimeWorkflowModelToolPath = decodedRuntimeWorkflowModelToolPath ?? metadata.modelToolPath
            runtimeWorkflowOnyxDriverPath = decodedRuntimeWorkflowOnyxDriverPath ?? metadata.onyxDriverPath
            runtimeWorkflowSkillTreePath = decodedRuntimeWorkflowSkillTreePath ?? metadata.skillTreePath
            runtimeWorkflowToolBindingsPath = decodedRuntimeWorkflowToolBindingsPath ?? metadata.toolBindingsPath
            runtimeWorkflowPlanningPath = decodedRuntimeWorkflowPlanningPath ?? metadata.planningBundlePath
            let decodedReplGrammar = try container.decodeIfPresent(String.self, forKey: .replGrammar)
            let decodedReplCommands = try container.decodeIfPresent(
                [SMLWorkflowREPLCommandDescriptor].self,
                forKey: .replCommands
            )
            let decodedReplExamples = try container.decodeIfPresent(
                [SMLWorkflowREPLExample].self,
                forKey: .replExamples
            )
            let mount = try container.decodeIfPresent(
                SMLWorkflowRuntimeREPLMount.self,
                forKey: .replMount
            ) ?? SMLWorkflowRuntimeREPLMount(
                workflowID: workflowID,
                workflowVersion: workflowVersion,
                workflowName: workflowName,
                role: role,
                apiBasePath: apiBasePath,
                apiWorkflowPath: apiWorkflowPath,
                grammar: decodedReplGrammar ?? "",
                helpText: "",
                commands: decodedReplCommands ?? [],
                examples: decodedReplExamples ?? [],
                modelToolName: decodedModelToolName,
                modelRouterToolName: decodedModelRouterToolName,
                onyxDriverID: decodedOnyxDriverID,
                commandBindings: []
            )
            replMount = mount
            replGrammar = decodedReplGrammar ?? mount.grammar
            replCommands = decodedReplCommands ?? mount.commands
            replExamples = decodedReplExamples ?? mount.examples
            apiMounts = try container.decodeIfPresent(
                [SMLWorkflowRuntimeAPIMount].self,
                forKey: .apiMounts
            ) ?? []
            modelTool = try container.decodeIfPresent(
                SMLWorkflowRuntimeModelToolExport.self,
                forKey: .modelTool
            ) ?? SMLWorkflowRuntimeModelToolExport(
                workflowID: workflowID,
                workflowVersion: workflowVersion,
                tool: SMLWorkflowModelToolDescriptor(
                    name: decodedModelToolName,
                    description: "Generated model command tool for \(workflowID).",
                    parameters: []
                ),
                allowedActions: [],
                maximumCommandRounds: 1,
                workflowMetadata: metadata
            )
            replScript = try container.decode(String.self, forKey: .replScript)
            apiScript = try container.decode([SMLRuntimeHostAPIRequestSpec].self, forKey: .apiScript)
            modelScript = try container.decode(String.self, forKey: .modelScript)
            replTranscriptCommand = try container.decode(
                SMLRuntimeHostScaffoldCommandTemplate.self,
                forKey: .replTranscriptCommand
            )
            apiTranscriptCommand = try container.decode(
                SMLRuntimeHostScaffoldCommandTemplate.self,
                forKey: .apiTranscriptCommand
            )
            modelTranscriptCommand = try container.decode(
                SMLRuntimeHostScaffoldCommandTemplate.self,
                forKey: .modelTranscriptCommand
            )
            apiEndpoints = try container.decode(
                [SMLRuntimeHostScaffoldEndpointReference].self,
                forKey: .apiEndpoints
            )
            modelToolName = decodedModelToolName
            modelRouterToolName = decodedModelRouterToolName
            onyxDriverID = decodedOnyxDriverID
            planningWorkflowID = try container.decodeIfPresent(String.self, forKey: .planningWorkflowID)
            plannerEntrypoint = try container.decodeIfPresent(String.self, forKey: .plannerEntrypoint)
            skillIDs = try container.decode([String].self, forKey: .skillIDs)
            toolReferences = try container.decode([String].self, forKey: .toolReferences)
            decomposableUnitIDs = try container.decode([String].self, forKey: .decomposableUnitIDs)
            approvalGateIDs = try container.decode([String].self, forKey: .approvalGateIDs)
            commandActions = try container.decode([String].self, forKey: .commandActions)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(workflowID, forKey: .workflowID)
            try container.encode(workflowVersion, forKey: .workflowVersion)
            try container.encode(workflowName, forKey: .workflowName)
            try container.encode(role, forKey: .role)
            try container.encode(apiBasePath, forKey: .apiBasePath)
            try container.encode(apiWorkflowPath, forKey: .apiWorkflowPath)
            try container.encode(attachmentPath, forKey: .attachmentPath)
            try container.encode(workflowRunbookPath, forKey: .workflowRunbookPath)
            try container.encode(replScriptPath, forKey: .replScriptPath)
            try container.encode(replMountPath, forKey: .replMountPath)
            try container.encode(apiScriptPath, forKey: .apiScriptPath)
            try container.encode(apiMountPath, forKey: .apiMountPath)
            try container.encode(modelScriptPath, forKey: .modelScriptPath)
            try container.encode(modelToolPath, forKey: .modelToolPath)
            try container.encode(onyxDriverPath, forKey: .onyxDriverPath)
            try container.encode(skillTreePath, forKey: .skillTreePath)
            try container.encode(toolBindingsPath, forKey: .toolBindingsPath)
            try container.encode(planningBundlePath, forKey: .planningBundlePath)
            try container.encode(workflowBindingPath, forKey: .workflowBindingPath)
            try container.encode(hostBindingChannels, forKey: .hostBindingChannels)
            try container.encode(runtimeWorkflowMetadata, forKey: .runtimeWorkflowMetadata)
            try container.encode(runtimeWorkflowAttachmentPath, forKey: .runtimeWorkflowAttachmentPath)
            try container.encode(runtimeWorkflowREPLMountPath, forKey: .runtimeWorkflowREPLMountPath)
            try container.encode(runtimeWorkflowAPIMountPath, forKey: .runtimeWorkflowAPIMountPath)
            try container.encode(runtimeWorkflowModelToolPath, forKey: .runtimeWorkflowModelToolPath)
            try container.encode(runtimeWorkflowOnyxDriverPath, forKey: .runtimeWorkflowOnyxDriverPath)
            try container.encode(runtimeWorkflowSkillTreePath, forKey: .runtimeWorkflowSkillTreePath)
            try container.encode(runtimeWorkflowToolBindingsPath, forKey: .runtimeWorkflowToolBindingsPath)
            try container.encode(runtimeWorkflowPlanningPath, forKey: .runtimeWorkflowPlanningPath)
            try container.encode(replMount, forKey: .replMount)
            try container.encode(replGrammar, forKey: .replGrammar)
            try container.encode(replCommands, forKey: .replCommands)
            try container.encode(replExamples, forKey: .replExamples)
            try container.encode(apiMounts, forKey: .apiMounts)
            try container.encode(modelTool, forKey: .modelTool)
            try container.encode(replScript, forKey: .replScript)
            try container.encode(apiScript, forKey: .apiScript)
            try container.encode(modelScript, forKey: .modelScript)
            try container.encode(replTranscriptCommand, forKey: .replTranscriptCommand)
            try container.encode(apiTranscriptCommand, forKey: .apiTranscriptCommand)
            try container.encode(modelTranscriptCommand, forKey: .modelTranscriptCommand)
            try container.encode(apiEndpoints, forKey: .apiEndpoints)
            try container.encode(modelToolName, forKey: .modelToolName)
            try container.encode(modelRouterToolName, forKey: .modelRouterToolName)
            try container.encode(onyxDriverID, forKey: .onyxDriverID)
            try container.encodeIfPresent(planningWorkflowID, forKey: .planningWorkflowID)
            try container.encodeIfPresent(plannerEntrypoint, forKey: .plannerEntrypoint)
            try container.encode(skillIDs, forKey: .skillIDs)
            try container.encode(toolReferences, forKey: .toolReferences)
            try container.encode(decomposableUnitIDs, forKey: .decomposableUnitIDs)
            try container.encode(approvalGateIDs, forKey: .approvalGateIDs)
            try container.encode(commandActions, forKey: .commandActions)
        }
    }

    struct SMLRuntimeHostScaffoldRunbook: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 11

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let outputDirectory: String
        let workflowIDs: [String]
        let apiBasePaths: [String]
        let apiWorkflowPathsByWorkflowID: [String: String]
        let apiTaskPathsByWorkflowID: [String: String]
        let workflowAttachmentPathsByWorkflowID: [String: String]
        let workflowRunbookPathsByWorkflowID: [String: String]
        let workflowREPLScriptPathsByWorkflowID: [String: String]
        let workflowREPLMountPathsByWorkflowID: [String: String]
        let workflowAPIScriptPathsByWorkflowID: [String: String]
        let workflowAPIMountPathsByWorkflowID: [String: String]
        let workflowModelScriptPathsByWorkflowID: [String: String]
        let workflowModelToolPathsByWorkflowID: [String: String]
        let workflowOnyxDriverPathsByWorkflowID: [String: String]
        let workflowSkillTreePathsByWorkflowID: [String: String]
        let workflowToolBindingPathsByWorkflowID: [String: String]
        let workflowPlanningBundlePathsByWorkflowID: [String: String]
        let workflowBindingPathsByWorkflowID: [String: String]
        let workflowHostBindingChannelsByWorkflowID: [String: [SMLWorkflowRuntimeHostBindingChannel]]
        let runtimeWorkflowMetadataByWorkflowID: [String: SMLWorkflowRuntimeWorkflowMetadataLinks]
        let descriptorOnly: Bool
        let artifactsMaterialized: Bool
        let omittedRuntimeState: [String]
        let artifacts: SMLRuntimeHostScaffoldRunbookArtifacts
        let workflows: [SMLRuntimeHostScaffoldWorkflowRunbook]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostScaffoldRunbook.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            outputDirectory: String,
            workflowIDs: [String],
            apiBasePaths: [String],
            apiWorkflowPathsByWorkflowID: [String: String]? = nil,
            apiTaskPathsByWorkflowID: [String: String]? = nil,
            workflowAttachmentPathsByWorkflowID: [String: String]? = nil,
            workflowRunbookPathsByWorkflowID: [String: String]? = nil,
            workflowREPLScriptPathsByWorkflowID: [String: String]? = nil,
            workflowREPLMountPathsByWorkflowID: [String: String]? = nil,
            workflowAPIScriptPathsByWorkflowID: [String: String]? = nil,
            workflowAPIMountPathsByWorkflowID: [String: String]? = nil,
            workflowModelScriptPathsByWorkflowID: [String: String]? = nil,
            workflowModelToolPathsByWorkflowID: [String: String]? = nil,
            workflowOnyxDriverPathsByWorkflowID: [String: String]? = nil,
            workflowSkillTreePathsByWorkflowID: [String: String]? = nil,
            workflowToolBindingPathsByWorkflowID: [String: String]? = nil,
            workflowPlanningBundlePathsByWorkflowID: [String: String]? = nil,
            workflowBindingPathsByWorkflowID: [String: String]? = nil,
            workflowHostBindingChannelsByWorkflowID: [String: [SMLWorkflowRuntimeHostBindingChannel]]? = nil,
            runtimeWorkflowMetadataByWorkflowID: [String: SMLWorkflowRuntimeWorkflowMetadataLinks]? = nil,
            descriptorOnly: Bool = true,
            artifactsMaterialized: Bool = false,
            omittedRuntimeState: [String] = [
                "actor_identity",
                "completion_authority",
                "credentials",
                "leases",
                "provider_registry",
                "runtime_handles",
            ],
            artifacts: SMLRuntimeHostScaffoldRunbookArtifacts = SMLRuntimeHostScaffoldRunbookArtifacts(),
            workflows: [SMLRuntimeHostScaffoldWorkflowRunbook],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.outputDirectory = outputDirectory
            self.workflowIDs = Array(Set(workflowIDs)).sorted()
            self.apiBasePaths = Array(Set(apiBasePaths)).sorted()
            let sortedWorkflows = workflows.sorted {
                if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
                return $0.workflowVersion < $1.workflowVersion
            }
            self.apiWorkflowPathsByWorkflowID = apiWorkflowPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.apiWorkflowPath)
                })
            self.apiTaskPathsByWorkflowID = apiTaskPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map { workflow in
                    let startPath = workflow.apiEndpoints.first { $0.action == .start }?.pathTemplate
                        ?? "\(workflow.apiBasePath)\(workflow.apiWorkflowPath)/tasks"
                    return (workflow.workflowID, startPath)
                })
            self.workflowAttachmentPathsByWorkflowID = workflowAttachmentPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.attachmentPath)
                })
            self.workflowRunbookPathsByWorkflowID = workflowRunbookPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.workflowRunbookPath)
                })
            self.workflowREPLScriptPathsByWorkflowID = workflowREPLScriptPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.replScriptPath)
                })
            self.workflowREPLMountPathsByWorkflowID = workflowREPLMountPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.replMountPath)
                })
            self.workflowAPIScriptPathsByWorkflowID = workflowAPIScriptPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.apiScriptPath)
                })
            self.workflowAPIMountPathsByWorkflowID = workflowAPIMountPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.apiMountPath)
                })
            self.workflowModelScriptPathsByWorkflowID = workflowModelScriptPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.modelScriptPath)
                })
            self.workflowModelToolPathsByWorkflowID = workflowModelToolPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.modelToolPath)
                })
            self.workflowOnyxDriverPathsByWorkflowID = workflowOnyxDriverPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.onyxDriverPath)
                })
            self.workflowSkillTreePathsByWorkflowID = workflowSkillTreePathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.skillTreePath)
                })
            self.workflowToolBindingPathsByWorkflowID = workflowToolBindingPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.toolBindingsPath)
                })
            self.workflowPlanningBundlePathsByWorkflowID = workflowPlanningBundlePathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.planningBundlePath)
                })
            self.workflowBindingPathsByWorkflowID = workflowBindingPathsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.workflowBindingPath)
                })
            self.workflowHostBindingChannelsByWorkflowID = workflowHostBindingChannelsByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.hostBindingChannels)
                })
            self.runtimeWorkflowMetadataByWorkflowID = runtimeWorkflowMetadataByWorkflowID
                ?? Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.runtimeWorkflowMetadata)
                })
            self.descriptorOnly = descriptorOnly
            self.artifactsMaterialized = artifactsMaterialized
            self.omittedRuntimeState = Array(Set(omittedRuntimeState)).sorted()
            self.artifacts = artifacts
            self.workflows = sortedWorkflows
            self.launchDescriptor = launchDescriptor
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case sourcePath
            case sourceFormat
            case outputDirectory
            case workflowIDs
            case apiBasePaths
            case apiWorkflowPathsByWorkflowID
            case apiTaskPathsByWorkflowID
            case workflowAttachmentPathsByWorkflowID
            case workflowRunbookPathsByWorkflowID
            case workflowREPLScriptPathsByWorkflowID
            case workflowREPLMountPathsByWorkflowID
            case workflowAPIScriptPathsByWorkflowID
            case workflowAPIMountPathsByWorkflowID
            case workflowModelScriptPathsByWorkflowID
            case workflowModelToolPathsByWorkflowID
            case workflowOnyxDriverPathsByWorkflowID
            case workflowSkillTreePathsByWorkflowID
            case workflowToolBindingPathsByWorkflowID
            case workflowPlanningBundlePathsByWorkflowID
            case workflowBindingPathsByWorkflowID
            case workflowHostBindingChannelsByWorkflowID
            case runtimeWorkflowMetadataByWorkflowID
            case descriptorOnly
            case artifactsMaterialized
            case omittedRuntimeState
            case artifacts
            case workflows
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
            let workflowIDs = try container.decode([String].self, forKey: .workflowIDs)
            let apiBasePaths = try container.decode([String].self, forKey: .apiBasePaths)
            let apiWorkflowPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .apiWorkflowPathsByWorkflowID
            )
            let apiTaskPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .apiTaskPathsByWorkflowID
            )
            let workflowAttachmentPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowAttachmentPathsByWorkflowID
            )
            let workflowRunbookPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowRunbookPathsByWorkflowID
            )
            let workflowREPLScriptPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowREPLScriptPathsByWorkflowID
            )
            let workflowREPLMountPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowREPLMountPathsByWorkflowID
            )
            let workflowAPIScriptPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowAPIScriptPathsByWorkflowID
            )
            let workflowAPIMountPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowAPIMountPathsByWorkflowID
            )
            let workflowModelScriptPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowModelScriptPathsByWorkflowID
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
            let workflowBindingPathsByWorkflowID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .workflowBindingPathsByWorkflowID
            )
            let workflowHostBindingChannelsByWorkflowID = try container.decodeIfPresent(
                [String: [SMLWorkflowRuntimeHostBindingChannel]].self,
                forKey: .workflowHostBindingChannelsByWorkflowID
            )?.mapValues { channels in
                Array(Set(channels)).sorted { $0.rawValue < $1.rawValue }
            }
            let runtimeWorkflowMetadataByWorkflowID = try container.decodeIfPresent(
                [String: SMLWorkflowRuntimeWorkflowMetadataLinks].self,
                forKey: .runtimeWorkflowMetadataByWorkflowID
            )
            let descriptorOnly = try container.decodeIfPresent(Bool.self, forKey: .descriptorOnly)
                ?? true
            let artifactsMaterialized = try container.decodeIfPresent(
                Bool.self,
                forKey: .artifactsMaterialized
            ) ?? false
            let omittedRuntimeState = try container.decodeIfPresent(
                [String].self,
                forKey: .omittedRuntimeState
            ) ?? [
                "actor_identity",
                "completion_authority",
                "credentials",
                "leases",
                "provider_registry",
                "runtime_handles",
            ]
            let artifacts = try container.decodeIfPresent(
                SMLRuntimeHostScaffoldRunbookArtifacts.self,
                forKey: .artifacts
            ) ?? SMLRuntimeHostScaffoldRunbookArtifacts()
            let workflows = try container.decode(
                [SMLRuntimeHostScaffoldWorkflowRunbook].self,
                forKey: .workflows
            )
            let launchDescriptor = try container.decode(
                SMLWorkflowRuntimeLaunchDescriptor.self,
                forKey: .launchDescriptor
            )
            let sortedWorkflows = workflows.sorted {
                if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
                return $0.workflowVersion < $1.workflowVersion
            }
            let expectedWorkflowIDs = Array(Set(sortedWorkflows.map(\.workflowID))).sorted()
            guard expectedWorkflowIDs.count == sortedWorkflows.count else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.workflows],
                    debugDescription: "workflows must not contain duplicate workflowID values"
                ))
            }
            guard Array(Set(workflowIDs)).sorted() == expectedWorkflowIDs,
                  Set(workflowIDs).count == workflowIDs.count else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.workflowIDs],
                    debugDescription: "workflowIDs disagrees with workflow runbook cards"
                ))
            }
            let expectedAPIBasePaths = Array(Set(sortedWorkflows.map(\.apiBasePath))).sorted()
            guard Array(Set(apiBasePaths)).sorted() == expectedAPIBasePaths,
                  Set(apiBasePaths).count == apiBasePaths.count else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.apiBasePaths],
                    debugDescription: "apiBasePaths disagrees with workflow runbook cards"
                ))
            }

            func workflowPathMap(
                _ keyPath: KeyPath<SMLRuntimeHostScaffoldWorkflowRunbook, String>
            ) -> [String: String] {
                Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0[keyPath: keyPath])
                })
            }

            func workflowAPITaskPathMap() -> [String: String] {
                Dictionary(uniqueKeysWithValues: sortedWorkflows.map { workflow in
                    let startPath = workflow.apiEndpoints.first { $0.action == .start }?.pathTemplate
                        ?? "\(workflow.apiBasePath)\(workflow.apiWorkflowPath)/tasks"
                    return (workflow.workflowID, startPath)
                })
            }

            func workflowMetadataMap() -> [String: SMLWorkflowRuntimeWorkflowMetadataLinks] {
                Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.runtimeWorkflowMetadata)
                })
            }

            func validateDecodedMap<Value: Equatable>(
                _ actual: [String: Value]?,
                expected: [String: Value],
                key: CodingKeys
            ) throws {
                guard let actual else { return }
                guard actual == expected else {
                    throw DecodingError.dataCorrupted(DecodingError.Context(
                        codingPath: container.codingPath + [key],
                        debugDescription: "\(key.stringValue) disagrees with workflow runbook cards"
                    ))
                }
            }

            try validateDecodedMap(
                apiWorkflowPathsByWorkflowID,
                expected: workflowPathMap(\.apiWorkflowPath),
                key: .apiWorkflowPathsByWorkflowID
            )
            try validateDecodedMap(
                apiTaskPathsByWorkflowID,
                expected: workflowAPITaskPathMap(),
                key: .apiTaskPathsByWorkflowID
            )
            try validateDecodedMap(
                workflowAttachmentPathsByWorkflowID,
                expected: workflowPathMap(\.attachmentPath),
                key: .workflowAttachmentPathsByWorkflowID
            )
            try validateDecodedMap(
                workflowRunbookPathsByWorkflowID,
                expected: workflowPathMap(\.workflowRunbookPath),
                key: .workflowRunbookPathsByWorkflowID
            )
            try validateDecodedMap(
                workflowREPLScriptPathsByWorkflowID,
                expected: workflowPathMap(\.replScriptPath),
                key: .workflowREPLScriptPathsByWorkflowID
            )
            try validateDecodedMap(
                workflowREPLMountPathsByWorkflowID,
                expected: workflowPathMap(\.replMountPath),
                key: .workflowREPLMountPathsByWorkflowID
            )
            try validateDecodedMap(
                workflowAPIScriptPathsByWorkflowID,
                expected: workflowPathMap(\.apiScriptPath),
                key: .workflowAPIScriptPathsByWorkflowID
            )
            try validateDecodedMap(
                workflowAPIMountPathsByWorkflowID,
                expected: workflowPathMap(\.apiMountPath),
                key: .workflowAPIMountPathsByWorkflowID
            )
            try validateDecodedMap(
                workflowModelScriptPathsByWorkflowID,
                expected: workflowPathMap(\.modelScriptPath),
                key: .workflowModelScriptPathsByWorkflowID
            )
            try validateDecodedMap(
                workflowModelToolPathsByWorkflowID,
                expected: workflowPathMap(\.modelToolPath),
                key: .workflowModelToolPathsByWorkflowID
            )
            try validateDecodedMap(
                workflowOnyxDriverPathsByWorkflowID,
                expected: workflowPathMap(\.onyxDriverPath),
                key: .workflowOnyxDriverPathsByWorkflowID
            )
            try validateDecodedMap(
                workflowSkillTreePathsByWorkflowID,
                expected: workflowPathMap(\.skillTreePath),
                key: .workflowSkillTreePathsByWorkflowID
            )
            try validateDecodedMap(
                workflowToolBindingPathsByWorkflowID,
                expected: workflowPathMap(\.toolBindingsPath),
                key: .workflowToolBindingPathsByWorkflowID
            )
            try validateDecodedMap(
                workflowPlanningBundlePathsByWorkflowID,
                expected: workflowPathMap(\.planningBundlePath),
                key: .workflowPlanningBundlePathsByWorkflowID
            )
            try validateDecodedMap(
                workflowBindingPathsByWorkflowID,
                expected: workflowPathMap(\.workflowBindingPath),
                key: .workflowBindingPathsByWorkflowID
            )
            try validateDecodedMap(
                workflowHostBindingChannelsByWorkflowID,
                expected: Dictionary(uniqueKeysWithValues: sortedWorkflows.map {
                    ($0.workflowID, $0.hostBindingChannels)
                }),
                key: .workflowHostBindingChannelsByWorkflowID
            )
            try validateDecodedMap(
                runtimeWorkflowMetadataByWorkflowID,
                expected: workflowMetadataMap(),
                key: .runtimeWorkflowMetadataByWorkflowID
            )

            if schemaVersion >= 10 {
                var launchAttachmentsByWorkflowID: [String: SMLWorkflowRuntimeWorkflowAttachmentManifest] = [:]
                for launchAttachment in launchDescriptor.hostWiring.attachmentManifests {
                    guard launchAttachmentsByWorkflowID[launchAttachment.workflowID] == nil else {
                        throw DecodingError.dataCorrupted(DecodingError.Context(
                            codingPath: container.codingPath + [CodingKeys.launchDescriptor],
                            debugDescription: "launchDescriptor host wiring contains duplicate workflowID values"
                        ))
                    }
                    launchAttachmentsByWorkflowID[launchAttachment.workflowID] = launchAttachment
                }
                for (workflowIndex, workflow) in sortedWorkflows.enumerated() {
                    guard let launchAttachment = launchAttachmentsByWorkflowID[workflow.workflowID] else {
                        throw DecodingError.dataCorrupted(DecodingError.Context(
                            codingPath: container.codingPath + [CodingKeys.workflows],
                            debugDescription: "workflows[\(workflowIndex)] has no matching launchDescriptor host wiring attachment"
                        ))
                    }
                    let expectedWorkflow = SMLRuntimeHostScaffoldWorkflowRunbook(
                        attachment: launchAttachment,
                        outputDirectory: outputDirectory
                    )
                    guard workflow == expectedWorkflow else {
                        throw DecodingError.dataCorrupted(DecodingError.Context(
                            codingPath: container.codingPath + [CodingKeys.workflows],
                            debugDescription: "workflows[\(workflowIndex)] disagrees with launchDescriptor host wiring attachment"
                        ))
                    }
                }
            }
            self.init(
                schemaVersion: schemaVersion,
                sourcePath: sourcePath,
                sourceFormat: sourceFormat,
                outputDirectory: outputDirectory,
                workflowIDs: workflowIDs,
                apiBasePaths: apiBasePaths,
                apiWorkflowPathsByWorkflowID: apiWorkflowPathsByWorkflowID,
                apiTaskPathsByWorkflowID: apiTaskPathsByWorkflowID,
                workflowAttachmentPathsByWorkflowID: workflowAttachmentPathsByWorkflowID,
                workflowRunbookPathsByWorkflowID: workflowRunbookPathsByWorkflowID,
                workflowREPLScriptPathsByWorkflowID: workflowREPLScriptPathsByWorkflowID,
                workflowREPLMountPathsByWorkflowID: workflowREPLMountPathsByWorkflowID,
                workflowAPIScriptPathsByWorkflowID: workflowAPIScriptPathsByWorkflowID,
                workflowAPIMountPathsByWorkflowID: workflowAPIMountPathsByWorkflowID,
                workflowModelScriptPathsByWorkflowID: workflowModelScriptPathsByWorkflowID,
                workflowModelToolPathsByWorkflowID: workflowModelToolPathsByWorkflowID,
                workflowOnyxDriverPathsByWorkflowID: workflowOnyxDriverPathsByWorkflowID,
                workflowSkillTreePathsByWorkflowID: workflowSkillTreePathsByWorkflowID,
                workflowToolBindingPathsByWorkflowID: workflowToolBindingPathsByWorkflowID,
                workflowPlanningBundlePathsByWorkflowID: workflowPlanningBundlePathsByWorkflowID,
                workflowBindingPathsByWorkflowID: workflowBindingPathsByWorkflowID,
                workflowHostBindingChannelsByWorkflowID: workflowHostBindingChannelsByWorkflowID,
                runtimeWorkflowMetadataByWorkflowID: runtimeWorkflowMetadataByWorkflowID,
                descriptorOnly: descriptorOnly,
                artifactsMaterialized: artifactsMaterialized,
                omittedRuntimeState: omittedRuntimeState,
                artifacts: artifacts,
                workflows: workflows,
                launchDescriptor: launchDescriptor
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(sourcePath, forKey: .sourcePath)
            try container.encode(sourceFormat, forKey: .sourceFormat)
            try container.encode(outputDirectory, forKey: .outputDirectory)
            try container.encode(workflowIDs, forKey: .workflowIDs)
            try container.encode(apiBasePaths, forKey: .apiBasePaths)
            try container.encode(apiWorkflowPathsByWorkflowID, forKey: .apiWorkflowPathsByWorkflowID)
            try container.encode(apiTaskPathsByWorkflowID, forKey: .apiTaskPathsByWorkflowID)
            try container.encode(workflowAttachmentPathsByWorkflowID, forKey: .workflowAttachmentPathsByWorkflowID)
            try container.encode(workflowRunbookPathsByWorkflowID, forKey: .workflowRunbookPathsByWorkflowID)
            try container.encode(workflowREPLScriptPathsByWorkflowID, forKey: .workflowREPLScriptPathsByWorkflowID)
            try container.encode(workflowREPLMountPathsByWorkflowID, forKey: .workflowREPLMountPathsByWorkflowID)
            try container.encode(workflowAPIScriptPathsByWorkflowID, forKey: .workflowAPIScriptPathsByWorkflowID)
            try container.encode(workflowAPIMountPathsByWorkflowID, forKey: .workflowAPIMountPathsByWorkflowID)
            try container.encode(workflowModelScriptPathsByWorkflowID, forKey: .workflowModelScriptPathsByWorkflowID)
            try container.encode(workflowModelToolPathsByWorkflowID, forKey: .workflowModelToolPathsByWorkflowID)
            try container.encode(workflowOnyxDriverPathsByWorkflowID, forKey: .workflowOnyxDriverPathsByWorkflowID)
            try container.encode(workflowSkillTreePathsByWorkflowID, forKey: .workflowSkillTreePathsByWorkflowID)
            try container.encode(workflowToolBindingPathsByWorkflowID, forKey: .workflowToolBindingPathsByWorkflowID)
            try container.encode(workflowPlanningBundlePathsByWorkflowID, forKey: .workflowPlanningBundlePathsByWorkflowID)
            try container.encode(workflowBindingPathsByWorkflowID, forKey: .workflowBindingPathsByWorkflowID)
            try container.encode(
                workflowHostBindingChannelsByWorkflowID,
                forKey: .workflowHostBindingChannelsByWorkflowID
            )
            try container.encode(runtimeWorkflowMetadataByWorkflowID, forKey: .runtimeWorkflowMetadataByWorkflowID)
            try container.encode(descriptorOnly, forKey: .descriptorOnly)
            try container.encode(artifactsMaterialized, forKey: .artifactsMaterialized)
            try container.encode(omittedRuntimeState, forKey: .omittedRuntimeState)
            try container.encode(artifacts, forKey: .artifacts)
            try container.encode(workflows, forKey: .workflows)
            try container.encode(launchDescriptor, forKey: .launchDescriptor)
        }
    }

}
