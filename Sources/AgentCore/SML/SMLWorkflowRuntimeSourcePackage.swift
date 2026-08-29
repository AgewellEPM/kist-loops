import Foundation

public enum SMLWorkflowRuntimeSourcePackageError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case emptyPackage
    case duplicateWorkflowID(String)
    case invalidWorkflow(workflowID: String, report: SMLValidationReport)
    case runtimeWorkflowMismatch(workflowID: String, field: String, expected: String, actual: String)
    case runtimeExportMismatch(field: String, expected: [String], actual: [String])
    case runtimeDerivedPayloadMismatch(field: String)

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "unsupported SML workflow runtime source package schema version \(version)"
        case .emptyPackage:
            return "SML workflow runtime source package requires at least one workflow"
        case .duplicateWorkflowID(let workflowID):
            return "SML workflow runtime source package contains duplicate workflow id: \(workflowID)"
        case .invalidWorkflow(let workflowID, let report):
            let details = report.errors.map(\.description).joined(separator: "\n")
            return "SML workflow runtime source package contains invalid workflow \(workflowID): \(details)"
        case .runtimeWorkflowMismatch(let workflowID, let field, let expected, let actual):
            return "SML workflow runtime source package workflow \(workflowID) \(field) mismatch: expected \(expected), got \(actual)"
        case .runtimeExportMismatch(let field, let expected, let actual):
            return "SML workflow runtime source package \(field) mismatch: expected \(expected), got \(actual)"
        case .runtimeDerivedPayloadMismatch(let field):
            return "SML workflow runtime source package \(field) does not match the catalog-derived payload"
        }
    }
}

public struct SMLWorkflowRuntimeSourceSummary: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let sourceKind: SMLWorkflowSourceKind
    public let sourceReference: String
    public let sourceDigest: String?
    public let apiBasePath: String
    public let replGrammar: String
    public let modelToolName: String
    public let modelRouterToolName: String
    public let onyxDriverID: String
    public let planningWorkflowID: String?

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        sourceKind: SMLWorkflowSourceKind,
        sourceReference: String,
        sourceDigest: String?,
        apiBasePath: String,
        replGrammar: String,
        modelToolName: String,
        modelRouterToolName: String,
        onyxDriverID: String,
        planningWorkflowID: String?
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.sourceKind = sourceKind
        self.sourceReference = sourceReference
        self.sourceDigest = sourceDigest
        self.apiBasePath = apiBasePath
        self.replGrammar = replGrammar
        self.modelToolName = modelToolName
        self.modelRouterToolName = modelRouterToolName
        self.onyxDriverID = onyxDriverID
        self.planningWorkflowID = planningWorkflowID
    }
}

/// Portable, authority-neutral artifact for a source-wrapped workflow runtime.
///
/// It binds the normalized source workflows to the generated runtime export so a host can persist,
/// diff, sign, or serve one package containing the custom REPL contract, API/OpenAPI surface, native
/// model-router tool, Onyx driver manifests, and planning graph. It deliberately carries no actor,
/// lease, provider credentials, replay guard, runtime handle, or host admission catalog.
public struct SMLWorkflowRuntimeSourcePackage: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let normalizedWorkflows: [SMLWorkflow]
    public let runtime: SMLWorkflowRuntimeExport

    public init(
        schemaVersion: Int = SMLWorkflowRuntimeSourcePackage.currentSchemaVersion,
        normalizedWorkflows: [SMLWorkflow],
        runtime: SMLWorkflowRuntimeExport
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SMLWorkflowRuntimeSourcePackageError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !normalizedWorkflows.isEmpty else {
            throw SMLWorkflowRuntimeSourcePackageError.emptyPackage
        }

        let orderedWorkflows = normalizedWorkflows.sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.version < $1.version
        }
        var seenWorkflowIDs = Set<String>()
        for workflow in orderedWorkflows {
            guard seenWorkflowIDs.insert(workflow.id).inserted else {
                throw SMLWorkflowRuntimeSourcePackageError.duplicateWorkflowID(workflow.id)
            }
            do {
                _ = try SMLWorkflowValidator.requireValidForImport(workflow)
            } catch let error as SMLWorkflowValidationError {
                throw SMLWorkflowRuntimeSourcePackageError.invalidWorkflow(
                    workflowID: workflow.id,
                    report: error.report
                )
            }
        }

        let expectedWorkflowIDs = orderedWorkflows.map(\.id)
        try Self.requireWorkflowIDs(
            runtime.catalog.workflowIDs,
            equal: expectedWorkflowIDs,
            field: "runtime.catalog.workflowIDs"
        )
        try Self.requireWorkflowIDs(
            runtime.mountContract.workflowIDs,
            equal: expectedWorkflowIDs,
            field: "runtime.mountContract.workflowIDs"
        )
        try Self.requireWorkflowIDs(
            runtime.mountContract.replMounts.map(\.workflowID),
            equal: expectedWorkflowIDs,
            field: "runtime.mountContract.replMounts"
        )
        try Self.requireWorkflowIDs(
            runtime.mountContract.workflowMounts.map(\.workflowID),
            equal: expectedWorkflowIDs,
            field: "runtime.mountContract.workflowMounts"
        )
        try Self.requireWorkflowIDs(
            runtime.mountContract.modelRouter.workflowIDs,
            equal: expectedWorkflowIDs,
            field: "runtime.mountContract.modelRouter.workflowIDs"
        )
        try Self.requireWorkflowIDs(
            runtime.modelTools.map(\.workflowID),
            equal: expectedWorkflowIDs,
            field: "runtime.modelTools"
        )
        try Self.requireWorkflowIDs(
            runtime.modelRouter.workflowIDs,
            equal: expectedWorkflowIDs,
            field: "runtime.modelRouter.workflowIDs"
        )
        try Self.requireWorkflowIDs(
            runtime.onyxDrivers.map(\.workflowID),
            equal: expectedWorkflowIDs,
            field: "runtime.onyxDrivers"
        )
        try Self.requireWorkflowIDs(
            runtime.planning.workflowIDs,
            equal: expectedWorkflowIDs,
            field: "runtime.planning.workflowIDs"
        )
        try Self.requireWorkflowIDs(
            runtime.planning.workflows.map(\.workflowID),
            equal: expectedWorkflowIDs,
            field: "runtime.planning.workflows"
        )
        try Self.requireWorkflowIDs(
            runtime.hostWiring.workflows.map(\.workflowID),
            equal: expectedWorkflowIDs,
            field: "runtime.hostWiring.workflows"
        )
        try Self.requireDerivedRuntimePayloadsMatch(runtime)
        try Self.requireRuntimeWorkflowFields(
            workflows: orderedWorkflows,
            runtime: runtime
        )

        self.schemaVersion = schemaVersion
        self.normalizedWorkflows = orderedWorkflows
        self.runtime = runtime
    }

    public var workflowIDs: [String] {
        normalizedWorkflows.map(\.id)
    }

    public var sourceSummaries: [SMLWorkflowRuntimeSourceSummary] {
        let mountsByWorkflowID = Dictionary(
            uniqueKeysWithValues: runtime.mountContract.workflowMounts.map { ($0.workflowID, $0) }
        )
        return normalizedWorkflows.map { workflow in
            let mount = mountsByWorkflowID[workflow.id]
            return SMLWorkflowRuntimeSourceSummary(
                workflowID: workflow.id,
                workflowVersion: workflow.version,
                workflowName: workflow.name,
                sourceKind: workflow.source.kind,
                sourceReference: workflow.source.reference,
                sourceDigest: workflow.source.digest,
                apiBasePath: mount?.apiBasePath ?? "",
                replGrammar: mount?.repl.grammar ?? "",
                modelToolName: mount?.modelToolName ?? "",
                modelRouterToolName: mount?.modelRouterToolName ?? runtime.modelRouter.tool.name,
                onyxDriverID: mount?.onyxDriverID ?? "",
                planningWorkflowID: mount?.planningWorkflowID
            )
        }
    }

    public func candidateMounts(
        admissionCatalog: SMLExecutionAdmissionCatalog,
        actor: String,
        roleOverride: String? = nil,
        replActionsOverride: Set<SMLWorkflowControlAction>? = nil,
        modelActionsOverride: Set<SMLWorkflowControlAction>? = nil,
        apiBasePathOverride: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) throws -> [SMLWorkflowRuntimeCandidateMount] {
        let descriptorsByWorkflowID = Dictionary(
            uniqueKeysWithValues: runtime.catalog.workflows.map { ($0.workflowID, $0) }
        )
        return try normalizedWorkflows.map { workflow in
            guard let descriptor = descriptorsByWorkflowID[workflow.id] else {
                throw SMLWorkflowRuntimeSourcePackageError.runtimeExportMismatch(
                    field: "runtime.catalog.workflowIDs",
                    expected: workflowIDs,
                    actual: runtime.catalog.workflowIDs
                )
            }
            return SMLWorkflowRuntimeCandidateMount(
                workflow: workflow,
                admissionCatalog: admissionCatalog,
                role: roleOverride ?? descriptor.role,
                actor: actor,
                replActions: replActionsOverride ?? Set(descriptor.repl.allowedActions),
                modelActions: modelActionsOverride ?? Set(descriptor.model.allowedActions),
                apiBasePath: apiBasePathOverride ?? descriptor.api.basePath,
                modelMaximumCommandRounds: modelMaximumCommandRoundsOverride
                    ?? descriptor.model.maximumCommandRounds
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, normalizedWorkflows, runtime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            normalizedWorkflows: try container.decode(
                [SMLWorkflow].self,
                forKey: .normalizedWorkflows
            ),
            runtime: try container.decode(SMLWorkflowRuntimeExport.self, forKey: .runtime)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(normalizedWorkflows, forKey: .normalizedWorkflows)
        try container.encode(runtime, forKey: .runtime)
    }

    private static func requireWorkflowIDs(
        _ actual: [String],
        equal expected: [String],
        field: String
    ) throws {
        let actual = actual.sorted()
        guard actual == expected else {
            throw SMLWorkflowRuntimeSourcePackageError.runtimeExportMismatch(
                field: field,
                expected: expected,
                actual: actual
            )
        }
    }

    private static func requireRuntimeWorkflowFields(
        workflows: [SMLWorkflow],
        runtime: SMLWorkflowRuntimeExport
    ) throws {
        let descriptorsByWorkflowID = Dictionary(
            uniqueKeysWithValues: runtime.catalog.workflows.map { ($0.workflowID, $0) }
        )
        let onyxByWorkflowID = Dictionary(
            uniqueKeysWithValues: runtime.onyxDrivers.map { ($0.workflowID, $0) }
        )
        let planningByWorkflowID = Dictionary(
            uniqueKeysWithValues: runtime.planning.workflows.map { ($0.workflowID, $0) }
        )
        for workflow in workflows {
            guard let descriptor = descriptorsByWorkflowID[workflow.id],
                  let onyx = onyxByWorkflowID[workflow.id],
                  let planning = planningByWorkflowID[workflow.id] else {
                throw SMLWorkflowRuntimeSourcePackageError.runtimeExportMismatch(
                    field: "runtime.workflowIDs",
                    expected: workflows.map(\.id),
                    actual: runtime.catalog.workflowIDs
                )
            }
            try require(
                descriptor.workflowVersion,
                equals: workflow.version,
                workflowID: workflow.id,
                field: "runtime.catalog.workflowVersion"
            )
            try require(
                descriptor.workflowName,
                equals: workflow.name,
                workflowID: workflow.id,
                field: "runtime.catalog.workflowName"
            )
            try require(
                descriptor.sourceKind.rawValue,
                equals: workflow.source.kind.rawValue,
                workflowID: workflow.id,
                field: "runtime.catalog.sourceKind"
            )
            try require(
                descriptor.sourceReference,
                equals: workflow.source.reference,
                workflowID: workflow.id,
                field: "runtime.catalog.sourceReference"
            )
            try require(
                descriptor.sourceDigest ?? "",
                equals: workflow.source.digest ?? "",
                workflowID: workflow.id,
                field: "runtime.catalog.sourceDigest"
            )
            try require(
                onyx.workflowVersion,
                equals: workflow.version,
                workflowID: workflow.id,
                field: "runtime.onyxDrivers.workflowVersion"
            )
            try require(
                onyx.plan.entrypoint,
                equals: workflow.entrypoint,
                workflowID: workflow.id,
                field: "runtime.onyxDrivers.plan.entrypoint"
            )
            try require(
                planning.workflowVersion,
                equals: workflow.version,
                workflowID: workflow.id,
                field: "runtime.planning.workflowVersion"
            )
            try require(
                planning.entrypoint,
                equals: workflow.entrypoint,
                workflowID: workflow.id,
                field: "runtime.planning.entrypoint"
            )
        }
    }

    private static func requireDerivedRuntimePayloadsMatch(
        _ runtime: SMLWorkflowRuntimeExport
    ) throws {
        guard runtime.agentGuide == runtime.catalog.agentGuide else {
            throw SMLWorkflowRuntimeSourcePackageError.runtimeDerivedPayloadMismatch(
                field: "runtime.agentGuide"
            )
        }
        guard runtime.hostGuide == runtime.catalog.hostGuide else {
            throw SMLWorkflowRuntimeSourcePackageError.runtimeDerivedPayloadMismatch(
                field: "runtime.hostGuide"
            )
        }
        guard runtime.hostWiring == runtime.catalog.hostWiring else {
            throw SMLWorkflowRuntimeSourcePackageError.runtimeDerivedPayloadMismatch(
                field: "runtime.hostWiring"
            )
        }
    }

    private static func require(
        _ actual: String,
        equals expected: String,
        workflowID: String,
        field: String
    ) throws {
        guard actual == expected else {
            throw SMLWorkflowRuntimeSourcePackageError.runtimeWorkflowMismatch(
                workflowID: workflowID,
                field: field,
                expected: expected,
                actual: actual
            )
        }
    }
}

public extension SMLWorkflowSourceImporter {
    static func runtimePackage(
        from sourceMounts: [SMLWorkflowRuntimeSourceMount],
        limits: SMLWireCodec.Limits = .standard,
        title: String = "SML Workflow Runtime API",
        version: String = "1.0.0",
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) throws -> SMLWorkflowRuntimeSourcePackage {
        let candidateMounts = try sourceMounts.map { try $0.candidateMount(limits: limits) }
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            candidateMounts: candidateMounts,
            commandID: commandID,
            taskID: taskID
        )
        return try SMLWorkflowRuntimeSourcePackage(
            normalizedWorkflows: candidateMounts.map(\.workflow),
            runtime: registry.export(title: title, version: version)
        )
    }
}

public extension SMLWorkflowRuntimeRegistry {
    static func compile(
        package: SMLWorkflowRuntimeSourcePackage,
        admissionCatalog: SMLExecutionAdmissionCatalog,
        actor: String,
        roleOverride: String? = nil,
        replActionsOverride: Set<SMLWorkflowControlAction>? = nil,
        modelActionsOverride: Set<SMLWorkflowControlAction>? = nil,
        apiBasePathOverride: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) throws -> SMLWorkflowRuntimeRegistry {
        try compile(
            candidateMounts: package.candidateMounts(
                admissionCatalog: admissionCatalog,
                actor: actor,
                roleOverride: roleOverride,
                replActionsOverride: replActionsOverride,
                modelActionsOverride: modelActionsOverride,
                apiBasePathOverride: apiBasePathOverride,
                modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
            ),
            commandID: commandID,
            taskID: taskID
        )
    }

    static func sourcePackage(
        sourceMounts: [SMLWorkflowRuntimeSourceMount],
        limits: SMLWireCodec.Limits = .standard,
        title: String = "SML Workflow Runtime API",
        version: String = "1.0.0",
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) throws -> SMLWorkflowRuntimeSourcePackage {
        try SMLWorkflowSourceImporter.runtimePackage(
            from: sourceMounts,
            limits: limits,
            title: title,
            version: version,
            commandID: commandID,
            taskID: taskID
        )
    }
}

public extension SMLWorkflowRuntimeApp {
    static func launch(
        package: SMLWorkflowRuntimeSourcePackage,
        admissionCatalog: SMLExecutionAdmissionCatalog,
        actor: String,
        runtime: SMLRuntime,
        replayGuard: any SMLCommandReplayGuard,
        authorityResolver: @escaping AuthorityResolver,
        roleOverride: String? = nil,
        replActionsOverride: Set<SMLWorkflowControlAction>? = nil,
        modelActionsOverride: Set<SMLWorkflowControlAction>? = nil,
        apiBasePathOverride: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() },
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) async throws -> SMLWorkflowRuntimeLaunch {
        try await launch(
            registry: try SMLWorkflowRuntimeRegistry.compile(
                package: package,
                admissionCatalog: admissionCatalog,
                actor: actor,
                roleOverride: roleOverride,
                replActionsOverride: replActionsOverride,
                modelActionsOverride: modelActionsOverride,
                apiBasePathOverride: apiBasePathOverride,
                modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride,
                commandID: commandID,
                taskID: taskID
            ),
            runtime: runtime,
            replayGuard: replayGuard,
            authorityResolver: authorityResolver,
            sourcePackage: package,
            clock: clock
        )
    }
}
