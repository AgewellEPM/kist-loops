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
                "output_fields", "entrypoint", "nodes", "edges", "conditional_edges",
            ]
        )
        let manifestVersion = try int(object, "manifest_version", path: "$.manifest_version")
        guard manifestVersion == 1 else {
            throw SMLWorkflowSourceImportError.unsupportedManifestVersion(manifestVersion)
        }
        let workflowID = try string(object, "id", path: "$.id")
        let workflowVersion = try string(object, "version", path: "$.version")
        let workflowName = try string(object, "name", path: "$.name")
        let sourceReference = try string(
            object,
            "source_reference",
            path: "$.source_reference"
        )
        let sourceDigest = try optionalString(
            object,
            "source_digest",
            path: "$.source_digest"
        )
        let inputFields = try stringArray(
            object,
            "input_fields",
            path: "$.input_fields"
        )
        let outputFields = try stringArray(
            object,
            "output_fields",
            path: "$.output_fields"
        )
        let entrypoint = try string(object, "entrypoint", path: "$.entrypoint")
        let workflow = SMLWorkflow(
            id: workflowID,
            version: workflowVersion,
            name: workflowName,
            source: SMLWorkflowSource(
                kind: .langGraph,
                reference: sourceReference,
                digest: sourceDigest
            ),
            trigger: try trigger(
                object["trigger"],
                path: "$.trigger"
            ) ?? SMLTrigger(kind: .manual),
            stateSchema: try stateSchema(object, path: "$.state_schema"),
            interface: SMLWorkflowInterface(
                inputFields: inputFields,
                outputFields: outputFields
            ),
            entrypoint: entrypoint,
            instructions: try instructions(
                object,
                path: "$.nodes",
                entrypoint: entrypoint,
                outputFields: outputFields
            )
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

    private struct LangGraphEdge {
        let from: String
        let to: String
        let label: String?
        let path: String
        let fromPath: String
        let toPath: String
        let labelPath: String?
    }

    private enum LangGraphEdgeSlot {
        case next
        case onPass
        case onFailure
        case trueTarget
        case falseTarget
    }

    private static func instructions(
        _ object: SMLObject,
        path: String,
        entrypoint: String,
        outputFields: [String]
    ) throws -> [SMLInstruction] {
        let values = try array(object, "nodes", path: path)
        var parsed = try values.enumerated().map { index, value in
            try instruction(value, path: "\(path)[\(index)]")
        }
        let edges = try edgeList(object)
        guard !edges.isEmpty else { return parsed }

        let knownNodeIDs = Set(parsed.map(\.id))
        let generatedEndID = generatedEndID(avoiding: knownNodeIDs)
        var outgoing: [String: [LangGraphEdge]] = [:]
        var needsGeneratedEnd = false

        for edge in edges {
            if isLangGraphStart(edge.from) {
                guard edge.to == entrypoint else {
                    throw SMLWorkflowSourceImportError.invalidField(
                        path: edge.toPath,
                        reason: "START edge must point to declared entrypoint \(entrypoint)"
                    )
                }
                continue
            }
            guard knownNodeIDs.contains(edge.from) else {
                throw SMLWorkflowSourceImportError.invalidField(
                    path: edge.fromPath,
                    reason: "unknown edge source \(edge.from)"
                )
            }
            if isLangGraphStart(edge.to) {
                throw SMLWorkflowSourceImportError.invalidField(
                    path: edge.toPath,
                    reason: "edge target cannot be START"
                )
            }
            if !isLangGraphEnd(edge.to) && !knownNodeIDs.contains(edge.to) {
                throw SMLWorkflowSourceImportError.invalidField(
                    path: edge.toPath,
                    reason: "unknown edge target \(edge.to)"
                )
            }
            outgoing[edge.from, default: []].append(edge)
        }

        parsed = try parsed.map { instruction in
            try applying(
                outgoing[instruction.id] ?? [],
                to: instruction,
                outputFields: outputFields,
                generatedEndID: generatedEndID,
                needsGeneratedEnd: &needsGeneratedEnd
            )
        }
        if needsGeneratedEnd {
            parsed.append(SMLInstruction(id: generatedEndID, op: .complete))
        }
        return parsed
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

    private static func edgeList(_ object: SMLObject) throws -> [LangGraphEdge] {
        var edges = try directEdges(object)
        edges.append(contentsOf: try conditionalEdges(object))
        return edges
    }

    private static func directEdges(_ object: SMLObject) throws -> [LangGraphEdge] {
        guard let values = try optionalArray(object, "edges", path: "$.edges") else {
            return []
        }
        return try values.enumerated().map { index, value in
            let itemPath = "$.edges[\(index)]"
            guard case .object(let edge) = value else {
                throw SMLWorkflowSourceImportError.invalidField(
                    path: itemPath,
                    reason: "expected object"
                )
            }
            try requireKnownKeys(edge, path: itemPath, allowed: ["from", "to", "label"])
            return LangGraphEdge(
                from: try string(edge, "from", path: "\(itemPath).from"),
                to: try string(edge, "to", path: "\(itemPath).to"),
                label: try optionalString(edge, "label", path: "\(itemPath).label"),
                path: itemPath,
                fromPath: "\(itemPath).from",
                toPath: "\(itemPath).to",
                labelPath: edge["label"] == nil ? nil : "\(itemPath).label"
            )
        }
    }

    private static func conditionalEdges(_ object: SMLObject) throws -> [LangGraphEdge] {
        guard let values = try optionalArray(
            object,
            "conditional_edges",
            path: "$.conditional_edges"
        ) else {
            return []
        }
        let labels = [
            "true", "false", "pass", "failure", "on_pass", "on_failure",
            "approved", "refused",
        ]
        var edges: [LangGraphEdge] = []
        for (index, value) in values.enumerated() {
            let itemPath = "$.conditional_edges[\(index)]"
            guard case .object(let edge) = value else {
                throw SMLWorkflowSourceImportError.invalidField(
                    path: itemPath,
                    reason: "expected object"
                )
            }
            try requireKnownKeys(edge, path: itemPath, allowed: Set(["from"] + labels))
            let from = try string(edge, "from", path: "\(itemPath).from")
            var added = 0
            for label in labels {
                if let target = try optionalString(edge, label, path: "\(itemPath).\(label)") {
                    edges.append(LangGraphEdge(
                        from: from,
                        to: target,
                        label: label,
                        path: itemPath,
                        fromPath: "\(itemPath).from",
                        toPath: "\(itemPath).\(label)",
                        labelPath: "\(itemPath).\(label)"
                    ))
                    added += 1
                }
            }
            guard added > 0 else {
                throw SMLWorkflowSourceImportError.invalidField(
                    path: itemPath,
                    reason: "expected at least one labeled target"
                )
            }
        }
        return edges
    }

    private static func applying(
        _ edges: [LangGraphEdge],
        to instruction: SMLInstruction,
        outputFields: [String],
        generatedEndID: String,
        needsGeneratedEnd: inout Bool
    ) throws -> SMLInstruction {
        guard !edges.isEmpty else { return instruction }

        var next = instruction.next
        var onPass = instruction.onPass
        var onFailure = instruction.onFailure
        var trueTarget = instruction.trueTarget
        var falseTarget = instruction.falseTarget

        for edge in edges {
            guard let target = try normalizedTarget(
                edge,
                from: instruction,
                outputFields: outputFields,
                generatedEndID: generatedEndID,
                needsGeneratedEnd: &needsGeneratedEnd
            ) else {
                continue
            }
            let slot = try transitionSlot(
                edge.label,
                for: instruction.op,
                path: edge.labelPath ?? edge.path
            )
            switch slot {
            case .next:
                try mergeTransition(&next, target: target, edge: edge, field: "next")
            case .onPass:
                try mergeTransition(&onPass, target: target, edge: edge, field: "on_pass")
            case .onFailure:
                try mergeTransition(&onFailure, target: target, edge: edge, field: "on_failure")
            case .trueTarget:
                try mergeTransition(&trueTarget, target: target, edge: edge, field: "true")
            case .falseTarget:
                try mergeTransition(&falseTarget, target: target, edge: edge, field: "false")
            }
        }

        return SMLInstruction(
            id: instruction.id,
            op: instruction.op,
            source: instruction.source,
            purpose: instruction.purpose,
            capability: instruction.capability,
            workflow: instruction.workflow,
            verifier: instruction.verifier,
            outputSchema: instruction.outputSchema,
            reason: instruction.reason,
            owner: instruction.owner,
            arguments: instruction.arguments,
            scope: instruction.scope,
            expectedState: instruction.expectedState,
            condition: instruction.condition,
            plugin: instruction.plugin,
            retryPolicy: instruction.retryPolicy,
            receiptFields: instruction.receiptFields,
            next: next,
            onPass: onPass,
            onFailure: onFailure,
            trueTarget: trueTarget,
            falseTarget: falseTarget
        )
    }

    private static func normalizedTarget(
        _ edge: LangGraphEdge,
        from instruction: SMLInstruction,
        outputFields: [String],
        generatedEndID: String,
        needsGeneratedEnd: inout Bool
    ) throws -> String? {
        guard isLangGraphEnd(edge.to) else { return edge.to }
        switch instruction.op {
        case .complete, .emitReceipt, .escalate:
            return nil
        default:
            guard outputFields.isEmpty else {
                throw SMLWorkflowSourceImportError.invalidField(
                    path: edge.toPath,
                    reason: "END edge from non-terminal node requires an explicit receipt node when output_fields are declared"
                )
            }
            needsGeneratedEnd = true
            return generatedEndID
        }
    }

    private static func transitionSlot(
        _ label: String?,
        for operation: SMLInstructionOperation,
        path: String
    ) throws -> LangGraphEdgeSlot {
        let normalized = label?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch operation {
        case .branch:
            switch normalized {
            case "true": return .trueTarget
            case "false": return .falseTarget
            default:
                throw SMLWorkflowSourceImportError.invalidField(
                    path: path,
                    reason: "BRANCH edges require true/false labels"
                )
            }
        case .assert, .verify:
            switch normalized {
            case "pass", "passed", "success", "on_pass", "true":
                return .onPass
            case "failure", "failed", "error", "on_failure", "false":
                return .onFailure
            default:
                throw SMLWorkflowSourceImportError.invalidField(
                    path: path,
                    reason: "\(operation.rawValue) edges require pass/failure labels"
                )
            }
        case .waitApproval:
            switch normalized {
            case nil, "", "next", "approved", "approve", "pass", "on_pass", "true":
                return .next
            case "refused", "refuse", "failure", "failed", "on_failure", "false":
                return .onFailure
            default:
                throw SMLWorkflowSourceImportError.invalidField(
                    path: path,
                    reason: "WAIT_APPROVAL edges require approved/refused labels"
                )
            }
        case .retry:
            switch normalized {
            case "failure", "failed", "exhausted", "on_failure", "false":
                return .onFailure
            default:
                throw SMLWorkflowSourceImportError.invalidField(
                    path: path,
                    reason: "RETRY edge lists only define the exhausted/failure transition; retry target stays in retry_policy"
                )
            }
        case .complete, .emitReceipt, .escalate:
            throw SMLWorkflowSourceImportError.invalidField(
                path: path,
                reason: "\(operation.rawValue) is terminal and cannot have outgoing edges"
            )
        default:
            switch normalized {
            case nil, "", "next", "then":
                return .next
            default:
                throw SMLWorkflowSourceImportError.invalidField(
                    path: path,
                    reason: "\(operation.rawValue) edges require an unlabeled or next label"
                )
            }
        }
    }

    private static func mergeTransition(
        _ current: inout String?,
        target: String,
        edge: LangGraphEdge,
        field: String
    ) throws {
        if let current, current != target {
            throw SMLWorkflowSourceImportError.invalidField(
                path: edge.toPath,
                reason: "edge conflicts with existing \(field) transition \(current)"
            )
        }
        current = target
    }

    private static func generatedEndID(avoiding knownNodeIDs: Set<String>) -> String {
        var candidate = "__sml_end"
        var index = 2
        while knownNodeIDs.contains(candidate) {
            candidate = "__sml_end_\(index)"
            index += 1
        }
        return candidate
    }

    private static func isLangGraphStart(_ id: String) -> Bool {
        id == "START" || id == "__start__"
    }

    private static func isLangGraphEnd(_ id: String) -> Bool {
        id == "END" || id == "__end__"
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

    private static func optionalArray(
        _ object: SMLObject,
        _ key: String,
        path: String
    ) throws -> [SMLValue]? {
        guard object[key] != nil else { return nil }
        return try array(object, key, path: path)
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
