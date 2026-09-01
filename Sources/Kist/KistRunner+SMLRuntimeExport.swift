import Foundation
import AgentCore

extension KistRunner {
    enum SMLRuntimeHostExportSourceFormat: String, Sendable, Codable, Equatable {
        case runtimeSourcePackage = "runtime_source_package"
        case runtimeScaffold = "runtime_scaffold"
        case runtimeSourceSet = "runtime_source_set"
        case langGraphManifest = "langgraph_manifest"
        case smlWorkflowJSON = "sml_workflow_json"
    }

    struct SMLRuntimeHostSourceSetEntry: Sendable, Codable, Equatable {
        let path: String
        let role: String?
        let apiBasePath: String?
        let apiWorkflowPath: String?
        let modelMaximumCommandRounds: Int?

        init(
            path: String,
            role: String? = nil,
            apiBasePath: String? = nil,
            apiWorkflowPath: String? = nil,
            modelMaximumCommandRounds: Int? = nil
        ) {
            self.path = path
            self.role = role
            self.apiBasePath = apiBasePath
            self.apiWorkflowPath = apiWorkflowPath
            self.modelMaximumCommandRounds = modelMaximumCommandRounds
        }
    }

    struct SMLRuntimeHostSourceSet: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1
        static let kind = "sml_runtime_source_set"

        let schemaVersion: Int
        let kind: String
        let sources: [SMLRuntimeHostSourceSetEntry]

        init(
            schemaVersion: Int = SMLRuntimeHostSourceSet.currentSchemaVersion,
            kind: String = SMLRuntimeHostSourceSet.kind,
            sources: [SMLRuntimeHostSourceSetEntry]
        ) {
            self.schemaVersion = schemaVersion
            self.kind = kind
            self.sources = sources
        }
    }

    struct SMLRuntimeHostExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 11

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let runtimePackage: SMLWorkflowRuntimeSourcePackage
        let hostWiring: SMLWorkflowRuntimeHostWiring
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            runtimePackage: SMLWorkflowRuntimeSourcePackage,
            hostWiring: SMLWorkflowRuntimeHostWiring,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.runtimePackage = runtimePackage
            self.hostWiring = hostWiring
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostLaunchDescriptor: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let launchEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostLaunchDescriptor.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            launchEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.launchEndpoint = launchEndpoint
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostOpenAPIExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let openAPIEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let openAPI: SMLObject
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostOpenAPIExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            openAPIEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            openAPI: SMLObject,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.openAPIEndpoint = openAPIEndpoint
            self.openAPI = openAPI
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostModelRouterExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let modelRouterEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let modelRouter: SMLWorkflowRuntimeModelRouterDescriptor
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostModelRouterExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            modelRouterEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            modelRouter: SMLWorkflowRuntimeModelRouterDescriptor,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.modelRouterEndpoint = modelRouterEndpoint
            self.modelRouter = modelRouter
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostOnyxDrivers: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let workflowID: String?
        let availableWorkflowIDs: [String]
        let apiBasePaths: [String]
        let onyxDriversEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let onyxDrivers: [SMLOnyxDriverManifest]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostOnyxDrivers.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            workflowID: String?,
            availableWorkflowIDs: [String],
            apiBasePaths: [String],
            onyxDriversEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            onyxDrivers: [SMLOnyxDriverManifest],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.workflowID = workflowID
            self.availableWorkflowIDs = availableWorkflowIDs.sorted()
            self.apiBasePaths = apiBasePaths.sorted()
            self.onyxDriversEndpoint = onyxDriversEndpoint
            self.onyxDrivers = onyxDrivers.sorted {
                if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
                return $0.workflowVersion < $1.workflowVersion
            }
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostPlanningExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let planningEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let planning: SMLWorkflowRuntimePlanningManifest
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostPlanningExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            planningEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            planning: SMLWorkflowRuntimePlanningManifest,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.planningEndpoint = planningEndpoint
            self.planning = planning
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostCatalogExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let catalogEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let catalog: SMLWorkflowRuntimeCatalog
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostCatalogExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            catalogEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            catalog: SMLWorkflowRuntimeCatalog,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.catalogEndpoint = catalogEndpoint
            self.catalog = catalog
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostMountExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let mountEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let mountContract: SMLWorkflowRuntimeMountContract
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostMountExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            mountEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            mountContract: SMLWorkflowRuntimeMountContract,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.mountEndpoint = mountEndpoint
            self.mountContract = mountContract
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostAgentGuideExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let agentGuideEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let agentGuide: SMLWorkflowRuntimeAgentGuide
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostAgentGuideExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            agentGuideEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            agentGuide: SMLWorkflowRuntimeAgentGuide,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.agentGuideEndpoint = agentGuideEndpoint
            self.agentGuide = agentGuide
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostGuideExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let hostGuideEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let hostGuide: SMLWorkflowRuntimeHostGuide
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostGuideExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            hostGuideEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            hostGuide: SMLWorkflowRuntimeHostGuide,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.hostGuideEndpoint = hostGuideEndpoint
            self.hostGuide = hostGuide
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostWiringExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let hostWiringEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let hostWiring: SMLWorkflowRuntimeHostWiring
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostWiringExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            hostWiringEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            hostWiring: SMLWorkflowRuntimeHostWiring,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.hostWiringEndpoint = hostWiringEndpoint
            self.hostWiring = hostWiring
            self.launchDescriptor = launchDescriptor
        }
    }

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

    struct SMLRuntimeHostAttachments: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 5

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let workflowID: String?
        let availableWorkflowIDs: [String]
        let apiBasePaths: [String]
        let attachmentEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let attachments: [SMLWorkflowRuntimeWorkflowAttachmentManifest]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostAttachments.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            workflowID: String?,
            availableWorkflowIDs: [String],
            apiBasePaths: [String],
            attachmentEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            attachments: [SMLWorkflowRuntimeWorkflowAttachmentManifest],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.workflowID = workflowID
            self.availableWorkflowIDs = availableWorkflowIDs.sorted()
            self.apiBasePaths = apiBasePaths.sorted()
            self.attachmentEndpoint = attachmentEndpoint
            self.attachments = attachments.sorted {
                if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
                return $0.workflowVersion < $1.workflowVersion
            }
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostREPLCommand: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 2

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let workflowID: String
        let availableWorkflowIDs: [String]
        let line: String
        let output: String
        let shouldExit: Bool
        let command: SMLCommandEnvelope?
        let result: SMLCommandResult?
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostREPLCommand.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            workflowID: String,
            availableWorkflowIDs: [String],
            line: String,
            output: String,
            shouldExit: Bool,
            command: SMLCommandEnvelope?,
            result: SMLCommandResult?,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.workflowID = workflowID
            self.availableWorkflowIDs = availableWorkflowIDs
            self.line = line
            self.output = output
            self.shouldExit = shouldExit
            self.command = command
            self.result = result
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostREPLTranscriptTurn: Sendable, Codable, Equatable {
        let index: Int
        let line: String
        let output: String
        let shouldExit: Bool
        let command: SMLCommandEnvelope?
        let result: SMLCommandResult?

        init(
            index: Int,
            line: String,
            output: String,
            shouldExit: Bool,
            command: SMLCommandEnvelope?,
            result: SMLCommandResult?
        ) {
            self.index = index
            self.line = line
            self.output = output
            self.shouldExit = shouldExit
            self.command = command
            self.result = result
        }
    }

    struct SMLRuntimeHostREPLTranscript: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let workflowID: String
        let availableWorkflowIDs: [String]
        let scriptPath: String
        let requestedLineCount: Int
        let executedLineCount: Int
        let stoppedAtExit: Bool
        let turns: [SMLRuntimeHostREPLTranscriptTurn]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostREPLTranscript.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            workflowID: String,
            availableWorkflowIDs: [String],
            scriptPath: String,
            requestedLineCount: Int,
            stoppedAtExit: Bool,
            turns: [SMLRuntimeHostREPLTranscriptTurn],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.workflowID = workflowID
            self.availableWorkflowIDs = availableWorkflowIDs
            self.scriptPath = scriptPath
            self.requestedLineCount = requestedLineCount
            self.executedLineCount = turns.count
            self.stoppedAtExit = stoppedAtExit
            self.turns = turns
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostAPIExchange: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 2

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let method: SMLWorkflowAPIMethod
        let path: String
        let requestBody: SMLObject
        let statusCode: Int
        let kind: SMLWorkflowRuntimeAPIResponseKind
        let responseBody: SMLValue
        let route: SMLWorkflowRuntimeAPIMount?
        let pathParameters: [String: String]
        let metadataResource: SMLWorkflowRuntimeMetadataResource?
        let command: SMLCommandEnvelope?
        let result: SMLCommandResult?
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostAPIExchange.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            method: SMLWorkflowAPIMethod,
            path: String,
            requestBody: SMLObject,
            statusCode: Int,
            kind: SMLWorkflowRuntimeAPIResponseKind,
            responseBody: SMLValue,
            route: SMLWorkflowRuntimeAPIMount?,
            pathParameters: [String: String],
            metadataResource: SMLWorkflowRuntimeMetadataResource?,
            command: SMLCommandEnvelope?,
            result: SMLCommandResult?,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.method = method
            self.path = path
            self.requestBody = requestBody
            self.statusCode = statusCode
            self.kind = kind
            self.responseBody = responseBody
            self.route = route
            self.pathParameters = pathParameters
            self.metadataResource = metadataResource
            self.command = command
            self.result = result
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostAPIRequestSpec: Sendable, Codable, Equatable {
        let method: SMLWorkflowAPIMethod
        let path: String
        let body: SMLObject

        init(
            method: SMLWorkflowAPIMethod,
            path: String,
            body: SMLObject = [:]
        ) {
            self.method = method
            self.path = path
            self.body = body
        }

        enum CodingKeys: String, CodingKey {
            case method
            case path
            case body
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                method: try container.decode(SMLWorkflowAPIMethod.self, forKey: .method),
                path: try container.decode(String.self, forKey: .path),
                body: try container.decodeIfPresent(SMLObject.self, forKey: .body) ?? [:]
            )
        }
    }

    struct SMLRuntimeHostAPITranscriptExchange: Sendable, Codable, Equatable {
        let index: Int
        let method: SMLWorkflowAPIMethod
        let path: String
        let requestBody: SMLObject
        let statusCode: Int
        let kind: SMLWorkflowRuntimeAPIResponseKind
        let responseBody: SMLValue
        let route: SMLWorkflowRuntimeAPIMount?
        let pathParameters: [String: String]
        let metadataResource: SMLWorkflowRuntimeMetadataResource?
        let command: SMLCommandEnvelope?
        let result: SMLCommandResult?

        init(
            index: Int,
            method: SMLWorkflowAPIMethod,
            path: String,
            requestBody: SMLObject,
            statusCode: Int,
            kind: SMLWorkflowRuntimeAPIResponseKind,
            responseBody: SMLValue,
            route: SMLWorkflowRuntimeAPIMount?,
            pathParameters: [String: String],
            metadataResource: SMLWorkflowRuntimeMetadataResource?,
            command: SMLCommandEnvelope?,
            result: SMLCommandResult?
        ) {
            self.index = index
            self.method = method
            self.path = path
            self.requestBody = requestBody
            self.statusCode = statusCode
            self.kind = kind
            self.responseBody = responseBody
            self.route = route
            self.pathParameters = pathParameters
            self.metadataResource = metadataResource
            self.command = command
            self.result = result
        }
    }

    struct SMLRuntimeHostAPITranscript: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let scriptPath: String
        let requestedRequestCount: Int
        let executedRequestCount: Int
        let exchanges: [SMLRuntimeHostAPITranscriptExchange]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostAPITranscript.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            scriptPath: String,
            requestedRequestCount: Int,
            exchanges: [SMLRuntimeHostAPITranscriptExchange],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.scriptPath = scriptPath
            self.requestedRequestCount = requestedRequestCount
            self.executedRequestCount = exchanges.count
            self.exchanges = exchanges
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostModelStep: Sendable, Codable, Equatable {
        let disposition: SMLWorkflowModelStepDisposition
        let advisoryText: String
        let toolCallID: String?
        let command: SMLCommandEnvelope?
        let result: SMLCommandResult?

        init(_ step: SMLWorkflowModelStep) {
            disposition = step.disposition
            advisoryText = step.advisoryText
            toolCallID = step.toolCallID
            command = step.command
            result = step.result
        }
    }

    struct SMLRuntimeHostModelTurn: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let prompt: String
        let providerBinding: ProviderBinding
        let maximumCommandRounds: Int
        let providerRequestLimit: Int
        let providerRequestsConsumed: Int
        let advisoryText: String
        let steps: [SMLRuntimeHostModelStep]
        let taskIDsByWorkflowID: [String: String]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostModelTurn.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            prompt: String,
            providerBinding: ProviderBinding,
            maximumCommandRounds: Int,
            providerRequestLimit: Int,
            providerRequestsConsumed: Int,
            advisoryText: String,
            steps: [SMLRuntimeHostModelStep],
            taskIDsByWorkflowID: [String: String],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.prompt = prompt
            self.providerBinding = providerBinding
            self.maximumCommandRounds = maximumCommandRounds
            self.providerRequestLimit = providerRequestLimit
            self.providerRequestsConsumed = providerRequestsConsumed
            self.advisoryText = advisoryText
            self.steps = steps
            self.taskIDsByWorkflowID = taskIDsByWorkflowID
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostModelTranscriptTurn: Sendable, Codable, Equatable {
        let index: Int
        let prompt: String
        let providerRequestsBefore: Int
        let providerRequestsAfter: Int
        let providerRequestsConsumed: Int
        let advisoryText: String
        let steps: [SMLRuntimeHostModelStep]
        let taskIDsByWorkflowID: [String: String]

        init(
            index: Int,
            prompt: String,
            providerRequestsBefore: Int,
            providerRequestsAfter: Int,
            advisoryText: String,
            steps: [SMLRuntimeHostModelStep],
            taskIDsByWorkflowID: [String: String]
        ) {
            self.index = index
            self.prompt = prompt
            self.providerRequestsBefore = providerRequestsBefore
            self.providerRequestsAfter = providerRequestsAfter
            self.providerRequestsConsumed = providerRequestsAfter - providerRequestsBefore
            self.advisoryText = advisoryText
            self.steps = steps
            self.taskIDsByWorkflowID = taskIDsByWorkflowID
        }
    }

    struct SMLRuntimeHostModelTranscript: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let scriptPath: String
        let providerBinding: ProviderBinding
        let maximumCommandRounds: Int
        let promptCount: Int
        let providerRequestLimit: Int
        let providerRequestsConsumed: Int
        let turns: [SMLRuntimeHostModelTranscriptTurn]
        let taskIDsByWorkflowID: [String: String]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostModelTranscript.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            scriptPath: String,
            providerBinding: ProviderBinding,
            maximumCommandRounds: Int,
            promptCount: Int,
            providerRequestLimit: Int,
            providerRequestsConsumed: Int,
            turns: [SMLRuntimeHostModelTranscriptTurn],
            taskIDsByWorkflowID: [String: String],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.scriptPath = scriptPath
            self.providerBinding = providerBinding
            self.maximumCommandRounds = maximumCommandRounds
            self.promptCount = promptCount
            self.providerRequestLimit = providerRequestLimit
            self.providerRequestsConsumed = providerRequestsConsumed
            self.turns = turns
            self.taskIDsByWorkflowID = taskIDsByWorkflowID
            self.launchDescriptor = launchDescriptor
        }
    }

    enum SMLRuntimeHostExportError: Error, CustomStringConvertible {
        case missingSourcePath
        case missingOutputDirectory
        case missingREPLLine
        case missingREPLScriptPath
        case emptyREPLScript(path: String)
        case readREPLScriptFailed(path: String, reason: String)
        case missingAPIPath
        case missingAPIScriptPath
        case emptyAPIScript(path: String)
        case invalidAPIScript(path: String, reason: String)
        case readAPIScriptFailed(path: String, reason: String)
        case missingModelPrompt
        case missingModelScriptPath
        case emptyModelScript(path: String)
        case readModelScriptFailed(path: String, reason: String)
        case invalidJSONObject(flag: String, reason: String)
        case invalidSourceSet(path: String, reason: String)
        case invalidAPIWorkflowPathOverride(workflowID: String, path: String)
        case duplicateAPIWorkflowPathOverride(String)
        case unknownAPIWorkflowPathOverride(requested: String, available: [String])
        case invalidScaffold(path: String, reason: String)
        case readFailed(path: String, reason: String)
        case unsupportedSource(path: String, diagnostics: [String])
        case noREPLWorkflows
        case ambiguousREPLWorkflow([String])
        case unknownREPLWorkflow(requested: String, available: [String])
        case outputDirectoryNotAllowed(String)
        case outputDirectoryIsFile(String)
        case outputDirectoryNotEmpty(String)
        case writeFailed(path: String, reason: String)

        var description: String {
            switch self {
            case .missingSourcePath:
                return "--sml-runtime-export/--sml-runtime-launch/--sml-runtime-openapi/--sml-runtime-model-router/--sml-runtime-onyx/--sml-runtime-planning/--sml-runtime-catalog/--sml-runtime-mount/--sml-runtime-agent-guide/--sml-runtime-host-guide/--sml-runtime-host-wiring/--sml-runtime-runbook/--sml-runtime-scaffold/--sml-runtime-attachments/--sml-runtime-repl/--sml-runtime-repl-script/--sml-runtime-api/--sml-runtime-api-script/--sml-runtime-model/--sml-runtime-model-script requires <source.json>"
            case .missingOutputDirectory:
                return "--sml-runtime-scaffold requires --sml-out <dir>"
            case .missingREPLLine:
                return "--sml-runtime-repl requires --sml-line <line>"
            case .missingREPLScriptPath:
                return "--sml-runtime-repl-script requires --sml-script <path>"
            case .emptyREPLScript(let path):
                return "--sml-script contains no runnable REPL lines: \(path)"
            case .readREPLScriptFailed(let path, let reason):
                return "could not read SML runtime REPL script '\(path)': \(reason)"
            case .missingAPIPath:
                return "--sml-runtime-api requires --sml-path <path>"
            case .missingAPIScriptPath:
                return "--sml-runtime-api-script requires --sml-api-script <path>"
            case .emptyAPIScript(let path):
                return "--sml-api-script contains no API requests: \(path)"
            case .invalidAPIScript(let path, let reason):
                return "invalid SML runtime API script '\(path)': \(reason)"
            case .readAPIScriptFailed(let path, let reason):
                return "could not read SML runtime API script '\(path)': \(reason)"
            case .missingModelPrompt:
                return "--sml-runtime-model requires --sml-prompt <text> or a positional prompt"
            case .missingModelScriptPath:
                return "--sml-runtime-model-script requires --sml-model-script <path>"
            case .emptyModelScript(let path):
                return "--sml-model-script contains no runnable prompts: \(path)"
            case .readModelScriptFailed(let path, let reason):
                return "could not read SML runtime model script '\(path)': \(reason)"
            case .invalidJSONObject(let flag, let reason):
                return "\(flag) must be a valid SML JSON object: \(reason)"
            case .invalidSourceSet(let path, let reason):
                return "invalid SML runtime source set '\(path)': \(reason)"
            case .invalidAPIWorkflowPathOverride(let workflowID, let path):
                return "--sml-api-workflow-path for workflow '\(workflowID)' must be an absolute literal path, got '\(path)'"
            case .duplicateAPIWorkflowPathOverride(let workflowID):
                return "--sml-api-workflow-path repeats workflow id '\(workflowID)'"
            case .unknownAPIWorkflowPathOverride(let requested, let available):
                return "unknown --sml-api-workflow-path workflow id '\(requested)'. Available workflows: \(available.joined(separator: ", "))"
            case .invalidScaffold(let path, let reason):
                return "invalid SML runtime scaffold '\(path)': \(reason)"
            case .readFailed(let path, let reason):
                return "could not read SML runtime source '\(path)': \(reason)"
            case .unsupportedSource(let path, let diagnostics):
                return """
                unsupported SML runtime source '\(path)'. Expected a runtime source package, runtime scaffold, runtime source set, LangGraph manifest, or SML workflow JSON.
                \(diagnostics.map { "  - \($0)" }.joined(separator: "\n"))
                """
            case .noREPLWorkflows:
                return "SML runtime source contains no workflow REPL mounts"
            case .ambiguousREPLWorkflow(let workflows):
                return "--sml-workflow is required because the runtime source contains multiple workflows: \(workflows.joined(separator: ", "))"
            case .unknownREPLWorkflow(let requested, let available):
                return "unknown --sml-workflow '\(requested)'. Available workflows: \(available.joined(separator: ", "))"
            case .outputDirectoryNotAllowed(let path):
                return "--sml-out refuses broad output directory: \(path)"
            case .outputDirectoryIsFile(let path):
                return "--sml-out path exists and is not a directory: \(path)"
            case .outputDirectoryNotEmpty(let path):
                return "--sml-out refuses to overwrite non-empty directory: \(path)"
            case .writeFailed(let path, let reason):
                return "could not write SML runtime scaffold file '\(path)': \(reason)"
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
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeLaunch(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostLaunchDescriptor(
                sourcePath: opts.smlRuntimeLaunch,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeOpenAPI(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostOpenAPI(
                sourcePath: opts.smlRuntimeOpenAPI,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeModelRouter(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostModelRouter(
                sourcePath: opts.smlRuntimeModelRouter,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeOnyx(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostOnyxDrivers(
                sourcePath: opts.smlRuntimeOnyx,
                projectRoot: opts.project,
                workflowID: opts.smlRuntimeWorkflowID,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimePlanning(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostPlanning(
                sourcePath: opts.smlRuntimePlanning,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeCatalog(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostCatalog(
                sourcePath: opts.smlRuntimeCatalog,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeMount(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostMount(
                sourcePath: opts.smlRuntimeMount,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeAgentGuide(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostAgentGuide(
                sourcePath: opts.smlRuntimeAgentGuide,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeHostGuide(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostGuide(
                sourcePath: opts.smlRuntimeHostGuide,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeHostWiring(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostWiring(
                sourcePath: opts.smlRuntimeHostWiring,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeRunbook(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostRunbook(
                sourcePath: opts.smlRuntimeRunbook,
                projectRoot: opts.project,
                workflowID: opts.smlRuntimeWorkflowID,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeScaffold(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostScaffold(
                sourcePath: opts.smlRuntimeScaffold,
                outputDirectory: opts.smlRuntimeOutputDirectory,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeAttachments(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostAttachments(
                sourcePath: opts.smlRuntimeAttachments,
                projectRoot: opts.project,
                workflowID: opts.smlRuntimeWorkflowID,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeREPL(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostREPLCommand(
                sourcePath: opts.smlRuntimeREPL,
                projectRoot: opts.project,
                workflowID: opts.smlRuntimeWorkflowID,
                line: opts.smlRuntimeREPLLine,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeREPLScript(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostREPLTranscript(
                sourcePath: opts.smlRuntimeREPLScript,
                projectRoot: opts.project,
                workflowID: opts.smlRuntimeWorkflowID,
                scriptPath: opts.smlRuntimeREPLScriptPath,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeAPI(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostAPIExchange(
                sourcePath: opts.smlRuntimeAPI,
                projectRoot: opts.project,
                method: opts.smlRuntimeAPIMethod,
                path: opts.smlRuntimeAPIPath,
                bodyJSON: opts.smlRuntimeAPIBody,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeAPIScript(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostAPITranscript(
                sourcePath: opts.smlRuntimeAPIScript,
                projectRoot: opts.project,
                scriptPath: opts.smlRuntimeAPIScriptPath,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeModel(
        _ opts: KistOptions,
        registry: ProviderRegistry,
        providerId: String,
        model: String?,
        projectRoot: String
    ) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostModelTurn(
                sourcePath: opts.smlRuntimeModel,
                projectRoot: projectRoot,
                prompt: opts.smlRuntimeModelPrompt ?? opts.goal,
                binding: ProviderBinding(providerId: providerId, model: model),
                providers: registry,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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

    static func runSMLRuntimeModelScript(
        _ opts: KistOptions,
        registry: ProviderRegistry,
        providerId: String,
        model: String?,
        projectRoot: String
    ) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostModelTranscript(
                sourcePath: opts.smlRuntimeModelScript,
                projectRoot: projectRoot,
                scriptPath: opts.smlRuntimeModelScriptPath,
                binding: ProviderBinding(providerId: providerId, model: model),
                providers: registry,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(export), as: UTF8.self)
    }

    static func renderSMLRuntimeHostLaunchDescriptor(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let launch = try await makeSMLRuntimeHostLaunchDescriptor(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(launch), as: UTF8.self)
    }

    static func renderSMLRuntimeHostOpenAPI(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let openAPI = try await makeSMLRuntimeHostOpenAPI(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(openAPI), as: UTF8.self)
    }

    static func renderSMLRuntimeHostModelRouter(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let modelRouter = try await makeSMLRuntimeHostModelRouter(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(modelRouter), as: UTF8.self)
    }

    static func renderSMLRuntimeHostOnyxDrivers(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let onyxDrivers = try await makeSMLRuntimeHostOnyxDrivers(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            workflowID: workflowID,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(onyxDrivers), as: UTF8.self)
    }

    static func renderSMLRuntimeHostPlanning(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let planning = try await makeSMLRuntimeHostPlanning(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(planning), as: UTF8.self)
    }

    static func renderSMLRuntimeHostCatalog(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let catalog = try await makeSMLRuntimeHostCatalog(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(catalog), as: UTF8.self)
    }

    static func renderSMLRuntimeHostMount(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let mount = try await makeSMLRuntimeHostMount(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(mount), as: UTF8.self)
    }

    static func renderSMLRuntimeHostAgentGuide(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let guide = try await makeSMLRuntimeHostAgentGuide(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(guide), as: UTF8.self)
    }

    static func renderSMLRuntimeHostGuide(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let guide = try await makeSMLRuntimeHostGuide(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(guide), as: UTF8.self)
    }

    static func renderSMLRuntimeHostWiring(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let wiring = try await makeSMLRuntimeHostWiring(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(wiring), as: UTF8.self)
    }

    static func renderSMLRuntimeHostRunbook(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let runbook = try await makeSMLRuntimeHostRunbook(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            workflowID: workflowID,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(runbook), as: UTF8.self)
    }

    static func renderSMLRuntimeHostScaffold(
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
    ) async throws -> String {
        let scaffold = try await writeSMLRuntimeHostScaffold(
            sourcePath: sourcePath,
            outputDirectory: outputDirectory,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(scaffold), as: UTF8.self)
    }

    static func renderSMLRuntimeHostREPLCommand(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        line: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let command = try await makeSMLRuntimeHostREPLCommand(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            workflowID: workflowID,
            line: line,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(command), as: UTF8.self)
    }

    static func renderSMLRuntimeHostREPLTranscript(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        scriptPath: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let transcript = try await makeSMLRuntimeHostREPLTranscript(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            workflowID: workflowID,
            scriptPath: scriptPath,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(transcript), as: UTF8.self)
    }

    static func renderSMLRuntimeHostAttachments(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let attachments = try await makeSMLRuntimeHostAttachments(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            workflowID: workflowID,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(attachments), as: UTF8.self)
    }

    static func renderSMLRuntimeHostAPIExchange(
        sourcePath: String?,
        projectRoot: String,
        method: SMLWorkflowAPIMethod = .get,
        path: String?,
        bodyJSON: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let exchange = try await makeSMLRuntimeHostAPIExchange(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            method: method,
            path: path,
            bodyJSON: bodyJSON,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(exchange), as: UTF8.self)
    }

    static func renderSMLRuntimeHostAPITranscript(
        sourcePath: String?,
        projectRoot: String,
        scriptPath: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let transcript = try await makeSMLRuntimeHostAPITranscript(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            scriptPath: scriptPath,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(transcript), as: UTF8.self)
    }

    static func renderSMLRuntimeHostModelTurn(
        sourcePath: String?,
        projectRoot: String,
        prompt: String?,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let turn = try await makeSMLRuntimeHostModelTurn(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            prompt: prompt,
            binding: binding,
            providers: providers,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(turn), as: UTF8.self)
    }

    static func renderSMLRuntimeHostModelTranscript(
        sourcePath: String?,
        projectRoot: String,
        scriptPath: String?,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let transcript = try await makeSMLRuntimeHostModelTranscript(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            scriptPath: scriptPath,
            binding: binding,
            providers: providers,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(transcript), as: UTF8.self)
    }

    static func makeSMLRuntimeHostExport(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostExport {
        try await withSMLRuntimeHostLaunch(
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
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                runtimePackage: host.runtimePackage,
                hostWiring: host.runtimePackage.runtime.hostWiring,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostLaunchDescriptor(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostLaunchDescriptor {
        try await withSMLRuntimeHostLaunch(
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
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostLaunchDescriptor(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                launchEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .launch
                },
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostOpenAPI(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostOpenAPIExport {
        try await withSMLRuntimeHostLaunch(
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
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostOpenAPIExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                openAPIEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .openAPI
                },
                openAPI: host.runtimePackage.runtime.openAPI,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostModelRouter(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostModelRouterExport {
        try await withSMLRuntimeHostLaunch(
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
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostModelRouterExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                modelRouterEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .modelRouter
                },
                modelRouter: host.runtimePackage.runtime.modelRouter,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostOnyxDrivers(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostOnyxDrivers {
        try await withSMLRuntimeHostLaunch(
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
            let launchDescriptor = host.launch.launchDescriptor
            let selectedWorkflowID = try selectSMLRuntimeOptionalWorkflowID(
                workflowID,
                availableWorkflowIDs: launchDescriptor.workflowIDs
            )
            let drivers = host.runtimePackage.runtime.onyxDrivers.filter { driver in
                selectedWorkflowID.map { $0 == driver.workflowID } ?? true
            }
            return SMLRuntimeHostOnyxDrivers(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                workflowID: selectedWorkflowID,
                availableWorkflowIDs: launchDescriptor.workflowIDs,
                apiBasePaths: launchDescriptor.apiBasePaths,
                onyxDriversEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .onyxDrivers
                },
                onyxDrivers: drivers,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostPlanning(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostPlanningExport {
        try await withSMLRuntimeHostLaunch(
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
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostPlanningExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                planningEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .planning
                },
                planning: host.runtimePackage.runtime.planning,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostCatalog(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostCatalogExport {
        try await withSMLRuntimeHostLaunch(
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
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostCatalogExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                catalogEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .catalog
                },
                catalog: host.runtimePackage.runtime.catalog,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostMount(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostMountExport {
        try await withSMLRuntimeHostLaunch(
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
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostMountExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                mountEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .mount
                },
                mountContract: host.runtimePackage.runtime.mountContract,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostAgentGuide(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostAgentGuideExport {
        try await withSMLRuntimeHostLaunch(
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
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostAgentGuideExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                agentGuideEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .agentGuide
                },
                agentGuide: host.runtimePackage.runtime.agentGuide,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostGuide(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostGuideExport {
        try await withSMLRuntimeHostLaunch(
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
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostGuideExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                hostGuideEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .hostGuide
                },
                hostGuide: host.runtimePackage.runtime.hostGuide,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostWiring(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostWiringExport {
        try await withSMLRuntimeHostLaunch(
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
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostWiringExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                hostWiringEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .hostWiring
                },
                hostWiring: host.runtimePackage.runtime.hostWiring,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostRunbook(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostScaffoldRunbook {
        try await withSMLRuntimeHostLaunch(
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
            let launchDescriptor = host.launch.launchDescriptor
            let selectedWorkflowID = try selectSMLRuntimeOptionalWorkflowID(
                workflowID,
                availableWorkflowIDs: launchDescriptor.workflowIDs
            )
            let attachments = host.runtimePackage.runtime.hostWiring.attachmentManifests.filter { attachment in
                selectedWorkflowID.map { $0 == attachment.workflowID } ?? true
            }
            return smlRuntimeScaffoldRunbook(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                outputDirectory: smlRuntimeRunbookOutputDirectory(
                    for: host,
                    projectRoot: projectRoot
                ),
                artifactsMaterialized: host.sourceFormat == .runtimeScaffold,
                launchDescriptor: launchDescriptor,
                attachments: attachments
            )
        }
    }

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

    private static func smlRuntimeScaffoldSafeFileStem(_ workflowID: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let stem = String(workflowID.map { allowed.contains($0) ? $0 : "_" })
        return stem.isEmpty ? "workflow" : stem
    }

    private static func smlRuntimeWorkflowMetadataLinks(
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

    private static func smlRuntimeModelToolExport(
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

    private static func smlRuntimeScaffoldRunbook(
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

    private static func smlRuntimeRunbookOutputDirectory(
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

    private static func smlRuntimeScaffoldAPIScript(
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

    private static func smlRuntimeScaffoldREPLScript(
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

    private static func smlRuntimeScaffoldModelScript(
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

    static func makeSMLRuntimeHostAPIExchange(
        sourcePath: String?,
        projectRoot: String,
        method: SMLWorkflowAPIMethod = .get,
        path: String?,
        bodyJSON: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostAPIExchange {
        guard let path,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingAPIPath
        }
        let requestBody = try decodeSMLRuntimeOpenObject(
            bodyJSON,
            flag: "--sml-body"
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
            let request = SMLWorkflowAPIRequest(
                method: method,
                path: path,
                body: requestBody
            )
            let response = try await host.launch.app.handleRuntimeAPI(request)
            return SMLRuntimeHostAPIExchange(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                method: method,
                path: path,
                requestBody: requestBody,
                statusCode: response.statusCode,
                kind: response.kind,
                responseBody: response.body,
                route: response.route,
                pathParameters: response.pathParameters,
                metadataResource: response.metadataResource,
                command: response.command,
                result: response.result,
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostAPITranscript(
        sourcePath: String?,
        projectRoot: String,
        scriptPath: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostAPITranscript {
        let script = try loadSMLRuntimeAPIScript(
            scriptPath: scriptPath,
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
            var exchanges: [SMLRuntimeHostAPITranscriptExchange] = []
            for (offset, spec) in script.requests.enumerated() {
                let request = SMLWorkflowAPIRequest(
                    method: spec.method,
                    path: spec.path,
                    body: spec.body
                )
                let response = try await host.launch.app.handleRuntimeAPI(request)
                exchanges.append(SMLRuntimeHostAPITranscriptExchange(
                    index: offset + 1,
                    method: spec.method,
                    path: spec.path,
                    requestBody: spec.body,
                    statusCode: response.statusCode,
                    kind: response.kind,
                    responseBody: response.body,
                    route: response.route,
                    pathParameters: response.pathParameters,
                    metadataResource: response.metadataResource,
                    command: response.command,
                    result: response.result
                ))
            }
            return SMLRuntimeHostAPITranscript(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                scriptPath: script.path,
                requestedRequestCount: script.requests.count,
                exchanges: exchanges,
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostAttachments(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostAttachments {
        try await withSMLRuntimeHostLaunch(
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
            let hostWiring = host.runtimePackage.runtime.hostWiring
            let availableWorkflowIDs = host.runtimePackage.workflowIDs
            let selectedWorkflowID = try selectSMLRuntimeOptionalWorkflowID(
                workflowID,
                availableWorkflowIDs: availableWorkflowIDs
            )
            let attachmentManifests = selectedWorkflowID.map { selected in
                hostWiring.attachmentManifests.filter { $0.workflowID == selected }
            } ?? hostWiring.attachmentManifests
            return SMLRuntimeHostAttachments(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                workflowID: selectedWorkflowID,
                availableWorkflowIDs: availableWorkflowIDs,
                apiBasePaths: hostWiring.apiBasePaths,
                attachmentEndpoint: hostWiring.metadataEndpoints.first {
                    $0.resource == .attachments
                },
                attachments: attachmentManifests,
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostModelTurn(
        sourcePath: String?,
        projectRoot: String,
        prompt: String?,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostModelTurn {
        guard let prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingModelPrompt
        }
        let maximumCommandRounds = modelMaximumCommandRoundsOverride.map {
            min(max(1, $0), 8)
        } ?? 4
        let requestBudget = ProviderRequestBudget(limit: maximumCommandRounds)
        return try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: maximumCommandRounds
        ) { host in
            let session = host.launch.app.modelRouterSession(
                binding: binding,
                providers: providers,
                maximumCommandRounds: maximumCommandRounds
            )
            let turn = try await session.submit(
                prompt,
                requestBudget: requestBudget
            )
            let consumed = await requestBudget.consumedCount()
            return SMLRuntimeHostModelTurn(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                prompt: prompt,
                providerBinding: binding,
                maximumCommandRounds: maximumCommandRounds,
                providerRequestLimit: maximumCommandRounds,
                providerRequestsConsumed: consumed,
                advisoryText: turn.advisoryText,
                steps: turn.steps.map(SMLRuntimeHostModelStep.init),
                taskIDsByWorkflowID: turn.taskIDsByWorkflowID,
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostModelTranscript(
        sourcePath: String?,
        projectRoot: String,
        scriptPath: String?,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostModelTranscript {
        let script = try loadSMLRuntimeModelScript(
            scriptPath: scriptPath,
            projectRoot: projectRoot
        )
        let maximumCommandRounds = modelMaximumCommandRoundsOverride.map {
            min(max(1, $0), 8)
        } ?? 4
        let providerRequestLimit = maximumCommandRounds * script.prompts.count
        let requestBudget = ProviderRequestBudget(limit: providerRequestLimit)
        return try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: maximumCommandRounds
        ) { host in
            let session = host.launch.app.modelRouterSession(
                binding: binding,
                providers: providers,
                maximumCommandRounds: maximumCommandRounds
            )
            var turns: [SMLRuntimeHostModelTranscriptTurn] = []
            for (offset, prompt) in script.prompts.enumerated() {
                let before = await requestBudget.consumedCount()
                let turn = try await session.submit(
                    prompt,
                    requestBudget: requestBudget
                )
                let after = await requestBudget.consumedCount()
                turns.append(SMLRuntimeHostModelTranscriptTurn(
                    index: offset + 1,
                    prompt: prompt,
                    providerRequestsBefore: before,
                    providerRequestsAfter: after,
                    advisoryText: turn.advisoryText,
                    steps: turn.steps.map(SMLRuntimeHostModelStep.init),
                    taskIDsByWorkflowID: turn.taskIDsByWorkflowID
                ))
            }
            let consumed = await requestBudget.consumedCount()
            return SMLRuntimeHostModelTranscript(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                scriptPath: script.path,
                providerBinding: binding,
                maximumCommandRounds: maximumCommandRounds,
                promptCount: script.prompts.count,
                providerRequestLimit: providerRequestLimit,
                providerRequestsConsumed: consumed,
                turns: turns,
                taskIDsByWorkflowID: await session.taskIDs(),
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostREPLCommand(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        line: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostREPLCommand {
        guard let line,
              !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingREPLLine
        }
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
            let availableWorkflowIDs = host.runtimePackage.workflowIDs
            let selectedWorkflowID = try selectSMLRuntimeREPLWorkflowID(
                workflowID,
                availableWorkflowIDs: availableWorkflowIDs
            )
            let session = try host.launch.app.replSession(workflowID: selectedWorkflowID)
            let response = try await session.submit(line)
            return SMLRuntimeHostREPLCommand(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                workflowID: selectedWorkflowID,
                availableWorkflowIDs: availableWorkflowIDs,
                line: line,
                output: response.output,
                shouldExit: response.shouldExit,
                command: response.command,
                result: response.result,
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostREPLTranscript(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        scriptPath: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostREPLTranscript {
        let script = try loadSMLRuntimeREPLScript(
            scriptPath: scriptPath,
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
            let availableWorkflowIDs = host.runtimePackage.workflowIDs
            let selectedWorkflowID = try selectSMLRuntimeREPLWorkflowID(
                workflowID,
                availableWorkflowIDs: availableWorkflowIDs
            )
            let session = try host.launch.app.replSession(workflowID: selectedWorkflowID)
            var turns: [SMLRuntimeHostREPLTranscriptTurn] = []
            var stoppedAtExit = false
            for (offset, line) in script.lines.enumerated() {
                let response = try await session.submit(line)
                turns.append(SMLRuntimeHostREPLTranscriptTurn(
                    index: offset + 1,
                    line: line,
                    output: response.output,
                    shouldExit: response.shouldExit,
                    command: response.command,
                    result: response.result
                ))
                if response.shouldExit {
                    stoppedAtExit = true
                    break
                }
            }
            return SMLRuntimeHostREPLTranscript(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                workflowID: selectedWorkflowID,
                availableWorkflowIDs: availableWorkflowIDs,
                scriptPath: script.path,
                requestedLineCount: script.lines.count,
                stoppedAtExit: stoppedAtExit,
                turns: turns,
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    private struct SMLRuntimeHostLaunch {
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let runtimePackage: SMLWorkflowRuntimeSourcePackage
        let launch: SMLWorkflowRuntimeLaunch
    }

    private final class SMLRuntimeSequentialIDSource: @unchecked Sendable {
        private let lock = NSLock()
        private let prefix: String
        private var nextValue = 0

        init(prefix: String) {
            self.prefix = prefix
        }

        func nextID() -> String {
            lock.lock()
            defer { lock.unlock() }
            nextValue += 1
            return "\(prefix)-\(nextValue)"
        }
    }

    private static func withSMLRuntimeHostLaunch<T>(
        sourcePath: String?,
        projectRoot: String,
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

        let loaded = try loadSMLRuntimeSource(data: sourceData, path: sourceURL.path)
        let actor = actor ?? "sml-runtime-exporter"
        let title = title ?? "SML Workflow Runtime API"
        let version = version ?? "1.0.0"
        let modelRounds = modelMaximumCommandRoundsOverride.map { min(max(1, $0), 8) }
        let apiWorkflowPathOverrides = try normalizedSMLRuntimeAPIWorkflowPathOverrides(
            apiWorkflowPathOverrides,
            workflows: loaded.workflows
        )
        let admissionCatalog = derivedSMLAdmissionCatalog(for: loaded.workflows)
        let commandIDSource = SMLRuntimeSequentialIDSource(prefix: "sml-runtime-export-command")
        let taskIDSource = SMLRuntimeSequentialIDSource(prefix: "TASK-SML-RUNTIME-EXPORT")
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
            launch: launch
        )
        return try await body(host)
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

    private static func selectSMLRuntimeREPLWorkflowID(
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

    private static func selectSMLRuntimeOptionalWorkflowID(
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

    private static func decodeSMLRuntimeOpenObject(
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

    private static func loadSMLRuntimeREPLScript(
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

    private static func loadSMLRuntimeAPIScript(
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

    private static func loadSMLRuntimeModelScript(
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
