import Foundation

public enum SMLWorkflowSourceImportError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownKey(path: String, key: String)
    case missingField(String)
    case invalidField(path: String, reason: String)
    case unsupportedManifestVersion(Int)
    case unsupportedSource(String)
    case structuralValidationFailed(SMLValidationReport)

    public var description: String {
        switch self {
        case .unknownKey(let path, let key):
            return "unknown workflow source import key '\(key)' at \(path)"
        case .missingField(let path):
            return "missing workflow source import field at \(path)"
        case .invalidField(let path, let reason):
            return "invalid workflow source import field at \(path): \(reason)"
        case .unsupportedManifestVersion(let version):
            return "unsupported workflow source import manifest version \(version)"
        case .unsupportedSource(let reason):
            return "unsupported workflow source import: \(reason)"
        case .structuralValidationFailed(let report):
            return report.errors.map(\.description).joined(separator: "\n")
        }
    }
}

public enum SMLWorkflowSourceDocument: Sendable, Equatable {
    case smlWorkflowJSON(Data)
    case langGraphManifest(Data)
    case langGraphPython(reference: String, source: Data)
}

public struct SMLWorkflowRuntimeSourceMount: Sendable {
    public let document: SMLWorkflowSourceDocument
    public let admissionCatalog: SMLExecutionAdmissionCatalog
    public let role: String
    public let actor: String
    public let replActions: Set<SMLWorkflowControlAction>?
    public let modelActions: Set<SMLWorkflowControlAction>
    public let apiBasePath: String
    public let modelMaximumCommandRounds: Int

    public init(
        document: SMLWorkflowSourceDocument,
        admissionCatalog: SMLExecutionAdmissionCatalog,
        role: String,
        actor: String,
        replActions: Set<SMLWorkflowControlAction>? = nil,
        modelActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions,
        apiBasePath: String = "/v1",
        modelMaximumCommandRounds: Int = 4
    ) {
        self.document = document
        self.admissionCatalog = admissionCatalog
        self.role = role
        self.actor = actor
        self.replActions = replActions
        self.modelActions = modelActions
        self.apiBasePath = apiBasePath
        self.modelMaximumCommandRounds = modelMaximumCommandRounds
    }

    public func candidateMount(
        limits: SMLWireCodec.Limits = .standard
    ) throws -> SMLWorkflowRuntimeCandidateMount {
        SMLWorkflowRuntimeCandidateMount(
            workflow: try SMLWorkflowSourceImporter.workflow(from: document, limits: limits),
            admissionCatalog: admissionCatalog,
            role: role,
            actor: actor,
            replActions: replActions,
            modelActions: modelActions,
            apiBasePath: apiBasePath,
            modelMaximumCommandRounds: modelMaximumCommandRounds
        )
    }
}

public enum SMLWorkflowSourceImporter {
    public static func workflow(
        from document: SMLWorkflowSourceDocument,
        limits: SMLWireCodec.Limits = .standard
    ) throws -> SMLWorkflow {
        switch document {
        case .smlWorkflowJSON(let data):
            return try SMLWireCodec.decodeWorkflowImportCandidate(
                from: data,
                limits: limits
            ).workflow
        case .langGraphManifest(let data):
            return try langGraphWorkflow(from: data, limits: limits)
        case .langGraphPython:
            throw SMLWorkflowSourceImportError.unsupportedSource(
                "raw LangGraph Python import requires an explicit langgraph_manifest; code is referenced and digested, not executed"
            )
        }
    }

    public static func langGraphWorkflow(
        from data: Data,
        limits: SMLWireCodec.Limits = .standard
    ) throws -> SMLWorkflow {
        let object = try SMLWireCodec.decodeOpenObject(from: data, limits: limits)
        try requireKnownKeys(
            object,
            path: "$",
            allowed: [
                "manifest_version", "id", "version", "name", "source_reference",
                "source_digest", "trigger", "state_schema", "input_fields",
                "output_fields", "entrypoint", "nodes",
            ]
        )
        let manifestVersion = try int(object, "manifest_version", path: "$.manifest_version")
        guard manifestVersion == 1 else {
            throw SMLWorkflowSourceImportError.unsupportedManifestVersion(manifestVersion)
        }
        let workflow = SMLWorkflow(
            id: try string(object, "id", path: "$.id"),
            version: try string(object, "version", path: "$.version"),
            name: try string(object, "name", path: "$.name"),
            source: SMLWorkflowSource(
                kind: .langGraph,
                reference: try string(
                    object,
                    "source_reference",
                    path: "$.source_reference"
                ),
                digest: try optionalString(
                    object,
                    "source_digest",
                    path: "$.source_digest"
                )
            ),
            trigger: try trigger(
                object["trigger"],
                path: "$.trigger"
            ) ?? SMLTrigger(kind: .manual),
            stateSchema: try stateSchema(object, path: "$.state_schema"),
            interface: SMLWorkflowInterface(
                inputFields: try stringArray(
                    object,
                    "input_fields",
                    path: "$.input_fields"
                ),
                outputFields: try stringArray(
                    object,
                    "output_fields",
                    path: "$.output_fields"
                )
            ),
            entrypoint: try string(object, "entrypoint", path: "$.entrypoint"),
            instructions: try instructions(object, path: "$.nodes")
        )
        do {
            _ = try SMLWorkflowValidator.requireValidForImport(workflow)
            return workflow
        } catch let error as SMLWorkflowValidationError {
            throw SMLWorkflowSourceImportError.structuralValidationFailed(error.report)
        }
    }

    public static func candidateMount(
        from document: SMLWorkflowSourceDocument,
        admissionCatalog: SMLExecutionAdmissionCatalog,
        role: String,
        actor: String,
        replActions: Set<SMLWorkflowControlAction>? = nil,
        modelActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions,
        apiBasePath: String = "/v1",
        modelMaximumCommandRounds: Int = 4,
        limits: SMLWireCodec.Limits = .standard
    ) throws -> SMLWorkflowRuntimeCandidateMount {
        try SMLWorkflowRuntimeSourceMount(
            document: document,
            admissionCatalog: admissionCatalog,
            role: role,
            actor: actor,
            replActions: replActions,
            modelActions: modelActions,
            apiBasePath: apiBasePath,
            modelMaximumCommandRounds: modelMaximumCommandRounds
        ).candidateMount(limits: limits)
    }

    private static func stateSchema(_ object: SMLObject, path: String) throws -> [SMLStateField] {
        let values = try array(object, "state_schema", path: path)
        return try values.enumerated().map { index, value in
            let itemPath = "\(path)[\(index)]"
            guard case .object(let field) = value else {
                throw SMLWorkflowSourceImportError.invalidField(
                    path: itemPath,
                    reason: "expected object"
                )
            }
            try requireKnownKeys(
                field,
                path: itemPath,
                allowed: ["name", "type", "required", "nullable", "description"]
            )
            let typeName = try string(field, "type", path: "\(itemPath).type")
            guard let type = SMLStateType(rawValue: typeName) else {
                throw SMLWorkflowSourceImportError.invalidField(
                    path: "\(itemPath).type",
                    reason: "unknown state type \(typeName)"
                )
            }
            return SMLStateField(
                name: try string(field, "name", path: "\(itemPath).name"),
                type: type,
                required: try optionalBool(
                    field,
                    "required",
                    path: "\(itemPath).required"
                ) ?? true,
                nullable: try optionalBool(
                    field,
                    "nullable",
                    path: "\(itemPath).nullable"
                ) ?? false,
                description: try optionalString(
                    field,
                    "description",
                    path: "\(itemPath).description"
                )
            )
        }
    }

    private static func instructions(_ object: SMLObject, path: String) throws -> [SMLInstruction] {
        let values = try array(object, "nodes", path: path)
        return try values.enumerated().map { index, value in
            try instruction(value, path: "\(path)[\(index)]")
        }
    }

    private static func instruction(
        _ value: SMLValue,
        path: String
    ) throws -> SMLInstruction {
        guard case .object(let object) = value else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected object"
            )
        }
        try requireKnownKeys(
            object,
            path: path,
            allowed: [
                "id", "kind", "source", "purpose", "capability", "workflow",
                "verifier", "output_schema", "reason", "owner", "arguments", "scope",
                "expected_state", "condition", "plugin", "retry_policy", "receipt_fields",
                "next", "on_pass", "on_failure", "true", "false",
            ]
        )
        let kind = try string(object, "kind", path: "\(path).kind")
        return SMLInstruction(
            id: try string(object, "id", path: "\(path).id"),
            op: try operation(kind, path: "\(path).kind"),
            source: try optionalString(object, "source", path: "\(path).source"),
            purpose: try optionalString(object, "purpose", path: "\(path).purpose"),
            capability: try optionalString(object, "capability", path: "\(path).capability"),
            workflow: try optionalString(object, "workflow", path: "\(path).workflow"),
            verifier: try optionalString(object, "verifier", path: "\(path).verifier"),
            outputSchema: try optionalString(
                object,
                "output_schema",
                path: "\(path).output_schema"
            ),
            reason: try optionalString(object, "reason", path: "\(path).reason"),
            owner: try optionalString(object, "owner", path: "\(path).owner"),
            arguments: try optionalObject(object, "arguments", path: "\(path).arguments") ?? [:],
            scope: try optionalObject(object, "scope", path: "\(path).scope") ?? [:],
            expectedState: try optionalObject(
                object,
                "expected_state",
                path: "\(path).expected_state"
            ) ?? [:],
            condition: try condition(object["condition"], path: "\(path).condition"),
            plugin: try plugin(object["plugin"], path: "\(path).plugin"),
            retryPolicy: try retryPolicy(object["retry_policy"], path: "\(path).retry_policy"),
            receiptFields: try optionalStringArray(
                object,
                "receipt_fields",
                path: "\(path).receipt_fields"
            ) ?? [],
            next: try optionalString(object, "next", path: "\(path).next"),
            onPass: try optionalString(object, "on_pass", path: "\(path).on_pass"),
            onFailure: try optionalString(object, "on_failure", path: "\(path).on_failure"),
            trueTarget: try optionalString(object, "true", path: "\(path).true"),
            falseTarget: try optionalString(object, "false", path: "\(path).false")
        )
    }

    private static func operation(
        _ kind: String,
        path: String
    ) throws -> SMLInstructionOperation {
        switch kind {
        case "observe": return .observe
        case "retrieve": return .retrieve
        case "model", "llm": return .callModel
        case "tool": return .callTool
        case "vcard": return .invokeVCard
        case "plugin": return .runPlugin
        case "workflow", "subworkflow": return .runWorkflow
        case "branch": return .branch
        case "assert": return .assert
        case "verify": return .verify
        case "checkpoint": return .checkpoint
        case "approval": return .waitApproval
        case "retry": return .retry
        case "rollback": return .rollback
        case "escalate": return .escalate
        case "commit": return .commit
        case "receipt": return .emitReceipt
        case "complete": return .complete
        default:
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "unknown LangGraph node kind \(kind)"
            )
        }
    }

    private static func trigger(
        _ value: SMLValue?,
        path: String
    ) throws -> SMLTrigger? {
        guard let value else { return nil }
        guard case .object(let object) = value else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected object"
            )
        }
        try requireKnownKeys(object, path: path, allowed: ["kind", "value"])
        let kindName = try string(object, "kind", path: "\(path).kind")
        guard let kind = SMLTrigger.Kind(rawValue: kindName) else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: "\(path).kind",
                reason: "unknown trigger kind \(kindName)"
            )
        }
        return SMLTrigger(
            kind: kind,
            value: try optionalString(object, "value", path: "\(path).value")
        )
    }

    private static func condition(
        _ value: SMLValue?,
        path: String
    ) throws -> SMLCondition? {
        guard let value else { return nil }
        guard case .object(let object) = value else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected object"
            )
        }
        try requireKnownKeys(object, path: path, allowed: ["combination", "clauses"])
        let combination: SMLCondition.Combination
        if let name = try optionalString(
            object,
            "combination",
            path: "\(path).combination"
        ) {
            guard let parsed = SMLCondition.Combination(rawValue: name) else {
                throw SMLWorkflowSourceImportError.invalidField(
                    path: "\(path).combination",
                    reason: "unknown condition combination \(name)"
                )
            }
            combination = parsed
        } else {
            combination = .all
        }
        let clauseValues = try array(object, "clauses", path: "\(path).clauses")
        let clauses = try clauseValues.enumerated().map { index, value in
            try conditionClause(value, path: "\(path).clauses[\(index)]")
        }
        return SMLCondition(combination: combination, clauses: clauses)
    }

    private static func conditionClause(
        _ value: SMLValue,
        path: String
    ) throws -> SMLConditionClause {
        guard case .object(let object) = value else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected object"
            )
        }
        try requireKnownKeys(object, path: path, allowed: ["field", "op", "value"])
        let opName = try string(object, "op", path: "\(path).op")
        guard let op = SMLConditionOperator(rawValue: opName) else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: "\(path).op",
                reason: "unknown condition operator \(opName)"
            )
        }
        return SMLConditionClause(
            field: try string(object, "field", path: "\(path).field"),
            op: op,
            value: object["value"]
        )
    }

    private static func plugin(
        _ value: SMLValue?,
        path: String
    ) throws -> SMLPluginContract? {
        guard let value else { return nil }
        guard case .object(let object) = value else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected object"
            )
        }
        try requireKnownKeys(
            object,
            path: path,
            allowed: [
                "id", "reads", "writes", "side_effect_level", "preconditions",
                "postconditions", "rollback", "verifier",
            ]
        )
        let sideEffect: SMLSideEffectLevel
        if let sideEffectName = try optionalString(
            object,
            "side_effect_level",
            path: "\(path).side_effect_level"
        ) {
            guard let parsed = SMLSideEffectLevel(rawValue: sideEffectName) else {
                throw SMLWorkflowSourceImportError.invalidField(
                    path: "\(path).side_effect_level",
                    reason: "unknown side effect level \(sideEffectName)"
                )
            }
            sideEffect = parsed
        } else {
            sideEffect = .unknown
        }
        return SMLPluginContract(
            id: try string(object, "id", path: "\(path).id"),
            reads: try optionalStringArray(object, "reads", path: "\(path).reads") ?? [],
            writes: try optionalStringArray(object, "writes", path: "\(path).writes") ?? [],
            sideEffectLevel: sideEffect,
            preconditions: try optionalStringArray(
                object,
                "preconditions",
                path: "\(path).preconditions"
            ) ?? [],
            postconditions: try optionalStringArray(
                object,
                "postconditions",
                path: "\(path).postconditions"
            ) ?? [],
            rollback: try optionalString(object, "rollback", path: "\(path).rollback"),
            verifier: try optionalString(object, "verifier", path: "\(path).verifier")
        )
    }

    private static func retryPolicy(
        _ value: SMLValue?,
        path: String
    ) throws -> SMLRetryPolicy? {
        guard let value else { return nil }
        guard case .object(let object) = value else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected object"
            )
        }
        try requireKnownKeys(
            object,
            path: path,
            allowed: ["target", "maximum_attempts", "backoff_seconds"]
        )
        return SMLRetryPolicy(
            target: try string(object, "target", path: "\(path).target"),
            maximumAttempts: try int(
                object,
                "maximum_attempts",
                path: "\(path).maximum_attempts"
            ),
            backoffSeconds: try optionalDouble(
                object,
                "backoff_seconds",
                path: "\(path).backoff_seconds"
            ) ?? 0
        )
    }

    private static func requireKnownKeys(
        _ object: SMLObject,
        path: String,
        allowed: Set<String>
    ) throws {
        if let unknown = object.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw SMLWorkflowSourceImportError.unknownKey(path: path, key: unknown)
        }
    }

    private static func string(
        _ object: SMLObject,
        _ key: String,
        path: String
    ) throws -> String {
        guard let value = object[key] else {
            throw SMLWorkflowSourceImportError.missingField(path)
        }
        guard case .string(let string) = value else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected string"
            )
        }
        return string
    }

    private static func optionalString(
        _ object: SMLObject,
        _ key: String,
        path: String
    ) throws -> String? {
        guard let value = object[key] else { return nil }
        guard case .string(let string) = value else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected string"
            )
        }
        return string
    }

    private static func optionalBool(
        _ object: SMLObject,
        _ key: String,
        path: String
    ) throws -> Bool? {
        guard let value = object[key] else { return nil }
        guard case .bool(let bool) = value else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected boolean"
            )
        }
        return bool
    }

    private static func int(
        _ object: SMLObject,
        _ key: String,
        path: String
    ) throws -> Int {
        guard let value = object[key] else {
            throw SMLWorkflowSourceImportError.missingField(path)
        }
        return try int(value, path: path)
    }

    private static func int(_ value: SMLValue, path: String) throws -> Int {
        guard case .number(let decimal) = value,
              decimal >= Decimal(Int.min),
              decimal <= Decimal(Int.max) else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected integer"
            )
        }
        var input = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard rounded == decimal else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected integer"
            )
        }
        return NSDecimalNumber(decimal: decimal).intValue
    }

    private static func optionalDouble(
        _ object: SMLObject,
        _ key: String,
        path: String
    ) throws -> Double? {
        guard let value = object[key] else { return nil }
        guard case .number(let decimal) = value else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected number"
            )
        }
        let double = NSDecimalNumber(decimal: decimal).doubleValue
        guard double.isFinite else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected finite number"
            )
        }
        return double
    }

    private static func array(
        _ object: SMLObject,
        _ key: String,
        path: String
    ) throws -> [SMLValue] {
        guard let value = object[key] else {
            throw SMLWorkflowSourceImportError.missingField(path)
        }
        guard case .array(let values) = value else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected array"
            )
        }
        return values
    }

    private static func stringArray(
        _ object: SMLObject,
        _ key: String,
        path: String
    ) throws -> [String] {
        let values = try array(object, key, path: path)
        return try values.enumerated().map { index, value in
            guard case .string(let string) = value else {
                throw SMLWorkflowSourceImportError.invalidField(
                    path: "\(path)[\(index)]",
                    reason: "expected string"
                )
            }
            return string
        }
    }

    private static func optionalStringArray(
        _ object: SMLObject,
        _ key: String,
        path: String
    ) throws -> [String]? {
        guard object[key] != nil else { return nil }
        return try stringArray(object, key, path: path)
    }

    private static func optionalObject(
        _ object: SMLObject,
        _ key: String,
        path: String
    ) throws -> SMLObject? {
        guard let value = object[key] else { return nil }
        guard case .object(let object) = value else {
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "expected object"
            )
        }
        return object
    }
}

public extension SMLWorkflowRuntimeRegistry {
    static func compile(
        sourceMounts: [SMLWorkflowRuntimeSourceMount],
        limits: SMLWireCodec.Limits = .standard,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) throws -> SMLWorkflowRuntimeRegistry {
        try compile(
            candidateMounts: sourceMounts.map { try $0.candidateMount(limits: limits) },
            commandID: commandID,
            taskID: taskID
        )
    }
}

public extension SMLWorkflowRuntimeApp {
    static func launch(
        sourceMounts: [SMLWorkflowRuntimeSourceMount],
        limits: SMLWireCodec.Limits = .standard,
        runtime: SMLRuntime,
        replayGuard: any SMLCommandReplayGuard,
        authorityResolver: @escaping AuthorityResolver,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() },
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) async throws -> SMLWorkflowRuntimeLaunch {
        try await launch(
            candidateMounts: sourceMounts.map { try $0.candidateMount(limits: limits) },
            runtime: runtime,
            replayGuard: replayGuard,
            authorityResolver: authorityResolver,
            commandID: commandID,
            taskID: taskID,
            clock: clock
        )
    }
}
