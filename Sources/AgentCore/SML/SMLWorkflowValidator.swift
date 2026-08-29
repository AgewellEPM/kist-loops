import Foundation

public struct SMLWorkflowValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    public let report: SMLValidationReport

    public init(report: SMLValidationReport) {
        self.report = report
    }

    public var description: String {
        report.errors.map(\.description).joined(separator: "\n")
    }
}

/// Structurally validated import output. This is deliberately not execution admission: runtime
/// code must still obtain host policy, plugin, tool, and approval attestations.
public struct SMLWorkflowCandidate: Sendable {
    let workflow: SMLWorkflow

    init(workflow: SMLWorkflow) {
        self.workflow = workflow
    }

    public var id: String { workflow.id }
    public var version: String { workflow.version }
    public var source: SMLWorkflowSource { workflow.source }
}

/// Structural and authority-shape validation for the common SML IR.
///
/// This validator does not execute imported code or grant a capability. It proves only that the
/// workflow is bounded, internally connected, and explicit enough for later policy admission.
public enum SMLWorkflowValidator {
    public static let maximumInstructions = 4_096
    public static let maximumStateFields = 512
    public static let maximumDiagnostics = 256

    public static func validate(_ workflow: SMLWorkflow) -> SMLValidationReport {
        var diagnostics: [SMLDiagnostic] = []
        func record(_ diagnostic: SMLDiagnostic) {
            if diagnostics.count < maximumDiagnostics {
                diagnostics.append(diagnostic)
                return
            }

            // A flood of advisory warnings must never hide the first later error and turn an
            // invalid workflow into an import candidate. Once the bounded report is full, errors
            // displace warnings; if it already contains only errors, validity is already closed.
            guard diagnostic.severity == .error,
                  let warningIndex = diagnostics.lastIndex(where: { $0.severity == .warning }) else {
                return
            }
            diagnostics[warningIndex] = diagnostic
        }
        func error(_ code: String, _ path: String, _ message: String) {
            record(SMLValidationSupport.error(code, path, message))
        }
        func warning(_ code: String, _ path: String, _ message: String) {
            record(SMLDiagnostic(
                severity: .warning, code: code, path: path, message: message
            ))
        }
        func append(_ additions: [SMLDiagnostic]) {
            for diagnostic in additions {
                record(diagnostic)
            }
        }
        func present(_ value: String?) -> Bool {
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if workflow.irVersion != SMLWorkflow.currentIRVersion {
            error("unsupported_ir", "ir_version",
                  "expected IR version \(SMLWorkflow.currentIRVersion)")
        }
        if !SMLValidationSupport.identifierIsValid(workflow.id) {
            error("invalid_workflow_id", "id", "workflow id is not a valid SML identifier")
        }
        if !semanticVersionIsValid(workflow.version) {
            error("invalid_version", "version", "workflow version must be semantic version syntax")
        }
        if workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || workflow.name.utf8.count > 512 {
            error("invalid_name", "name", "workflow name must contain 1...512 UTF-8 bytes")
        }
        if workflow.source.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("missing_source", "source.reference", "workflow source reference is required")
        } else if workflow.source.reference.utf8.count > 4_096 {
            error("source_too_large", "source.reference", "workflow source reference exceeds 4096 bytes")
        }
        if let digest = workflow.source.digest,
           !(digest.count == 64 && digest == digest.lowercased()
             && digest.unicodeScalars.allSatisfy({
                 (48...57).contains($0.value) || (97...102).contains($0.value)
             })) {
            error("invalid_source_digest", "source.digest", "source digest must be lowercase SHA-256 hex")
        }
        if workflow.trigger.kind != .manual && !present(workflow.trigger.value) {
            error("missing_trigger_value", "trigger.value", "event and schedule triggers require a value")
        }
        if let value = workflow.trigger.value, value.utf8.count > 4_096 {
            error("trigger_too_large", "trigger.value", "trigger value exceeds 4096 bytes")
        }

        let stateSchemaIsOversized = workflow.stateSchema.count > maximumStateFields
        let instructionListIsOversized = workflow.instructions.count > maximumInstructions
        if stateSchemaIsOversized {
            error("state_schema_too_large", "state_schema",
                  "state schema exceeds \(maximumStateFields) fields")
        }
        if instructionListIsOversized {
            error("workflow_too_large", "instructions",
                  "workflow exceeds \(maximumInstructions) instructions")
        }
        // Hard stop: limits are admission bounds, not advisory diagnostics. This also keeps graph
        // analysis and value inspection bounded for in-memory callers that bypass the wire codec.
        if stateSchemaIsOversized || instructionListIsOversized {
            return SMLValidationReport(diagnostics: diagnostics)
        }
        var stateNames = Set<String>()
        var stateFields: [String: SMLStateField] = [:]
        for (index, field) in workflow.stateSchema.enumerated() {
            let path = "state_schema[\(index)]"
            if !SMLValidationSupport.identifierIsValid(field.name, allowDot: false) {
                error("invalid_state_field", "\(path).name", "state field is not a valid identifier")
            }
            if !stateNames.insert(field.name).inserted {
                error("duplicate_state_field", "\(path).name", "state field '\(field.name)' is duplicated")
            }
            stateFields[field.name] = field
            if let description = field.description,
               description.utf8.count > SMLValidationSupport.maximumStringBytes {
                error("description_too_large", "\(path).description", "description is too large")
            }
        }

        if workflow.instructions.isEmpty {
            error("empty_workflow", "instructions", "workflow requires at least one instruction")
        }
        var instructionByID: [String: SMLInstruction] = [:]
        var valueNodes = 0
        for (index, instruction) in workflow.instructions.enumerated() {
            let path = "instructions[\(index)]"
            if !SMLValidationSupport.identifierIsValid(instruction.id) {
                error("invalid_instruction_id", "\(path).id", "instruction id is not valid")
            }
            if instructionByID.updateValue(instruction, forKey: instruction.id) != nil {
                error("duplicate_instruction", "\(path).id",
                      "instruction '\(instruction.id)' is duplicated")
            }
            append(SMLValidationSupport.inspectObject(
                instruction.arguments, path: "\(path).arguments", nodes: &valueNodes
            ))
            append(SMLValidationSupport.inspectObject(
                instruction.scope, path: "\(path).scope", nodes: &valueNodes
            ))
            append(SMLValidationSupport.inspectObject(
                instruction.expectedState, path: "\(path).expected_state", nodes: &valueNodes
            ))
            validateExpectedState(
                instruction.expectedState, stateFields: stateFields,
                path: "\(path).expected_state", error: error
            )
            validateCondition(
                instruction.condition, stateNames: stateNames, stateFields: stateFields,
                path: "\(path).condition", valueNodes: &valueNodes,
                append: append, error: error
            )
            validateInstruction(
                instruction, path: path, present: present, error: error, warning: warning
            )
        }

        if !SMLValidationSupport.identifierIsValid(workflow.entrypoint) {
            error("invalid_entrypoint", "entrypoint", "entrypoint is not a valid instruction id")
        } else if instructionByID[workflow.entrypoint] == nil {
            error("missing_entrypoint", "entrypoint", "entrypoint does not name an instruction")
        }

        for (index, instruction) in workflow.instructions.enumerated() {
            for target in successors(of: instruction) where instructionByID[target] == nil {
                error("unknown_transition", "instructions[\(index)]",
                      "transition names missing instruction '\(target)'")
            }
        }

        if instructionByID[workflow.entrypoint] != nil {
            let reachable = reachableIDs(from: workflow.entrypoint, instructions: instructionByID)
            for (index, instruction) in workflow.instructions.enumerated()
                where !reachable.contains(instruction.id) {
                error("unreachable_instruction", "instructions[\(index)].id",
                      "instruction '\(instruction.id)' is unreachable from the entrypoint")
            }

            let terminalReachable = IDsThatCanReachTerminal(
                reachable: reachable, instructions: instructionByID
            )
            for id in reachable.sorted() where !terminalReachable.contains(id) {
                error("no_terminal_path", "instructions.\(id)",
                      "instruction cannot reach COMPLETE, ESCALATE, or EMIT_RECEIPT")
            }

            let unboundedCycleMembers = cycleMembersAfterRemovingRetries(
                reachable: reachable, instructions: instructionByID
            )
            if !unboundedCycleMembers.isEmpty {
                let preview = unboundedCycleMembers.sorted().prefix(32).joined(separator: ", ")
                error("unbounded_cycle", "instructions",
                      "cycle [\(preview)] can repeat without consuming a RETRY budget")
            }
        }

        return SMLValidationReport(diagnostics: diagnostics)
    }

    public static func requireValidForImport(_ workflow: SMLWorkflow) throws -> SMLWorkflowCandidate {
        let report = validate(workflow)
        guard report.isValid else { throw SMLWorkflowValidationError(report: report) }
        return SMLWorkflowCandidate(workflow: workflow)
    }

    private static func semanticVersionIsValid(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func validateCondition(
        _ condition: SMLCondition?,
        stateNames: Set<String>,
        stateFields: [String: SMLStateField],
        path: String,
        valueNodes: inout Int,
        append: ([SMLDiagnostic]) -> Void,
        error: (_ code: String, _ path: String, _ message: String) -> Void
    ) {
        guard let condition else { return }
        if condition.clauses.isEmpty {
            error("empty_condition", path, "condition requires at least one clause")
        }
        if condition.clauses.count > 32 {
            error("condition_too_large", path, "condition exceeds 32 clauses")
            return
        }
        for (index, clause) in condition.clauses.enumerated() {
            let clausePath = "\(path).clauses[\(index)]"
            if !SMLValidationSupport.identifierIsValid(clause.field, allowDot: false)
                || !stateNames.contains(clause.field) {
                error("unknown_condition_field", "\(clausePath).field",
                      "condition field '\(clause.field)' is not declared in state_schema")
            }
            if let value = clause.value {
                append(SMLValidationSupport.inspectValue(
                    value, path: "\(clausePath).value", nodes: &valueNodes
                ))
            }
            let valueless = clause.op == .exists || clause.op == .isNull
            if valueless && clause.value != nil {
                error("unexpected_condition_value", "\(clausePath).value",
                      "\(clause.op.rawValue) does not accept a value")
            } else if !valueless && clause.value == nil {
                error("missing_condition_value", "\(clausePath).value",
                      "\(clause.op.rawValue) requires a value")
            }
            guard let field = stateFields[clause.field] else { continue }
            if [.lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual].contains(clause.op),
               field.type != .number && field.type != .integer {
                error("non_numeric_comparison", clausePath,
                      "numeric comparison requires a number or integer state field")
            }
            if [.lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual].contains(clause.op),
                let value = clause.value {
                switch value {
                case .number: break
                default:
                    error("non_numeric_condition_value", "\(clausePath).value",
                          "numeric comparison requires a numeric value")
                }
            }
            if clause.op == .contains, field.type != .string && field.type != .array {
                error("invalid_contains_field", clausePath,
                      "contains requires a string or array state field")
            }
            if clause.op == .contains, field.type == .string,
               let value = clause.value, !valueMatchesStateType(value, type: .string, nullable: false) {
                error("invalid_contains_value", "\(clausePath).value",
                      "string containment requires a string value")
            }
            if [.equals, .notEquals].contains(clause.op), let value = clause.value,
               !valueMatchesStateType(value, type: field.type, nullable: field.nullable) {
                error("condition_type_mismatch", "\(clausePath).value",
                      "condition value does not match state field type \(field.type.rawValue)")
            }
        }
    }

    private static func validateExpectedState(
        _ expectedState: SMLObject,
        stateFields: [String: SMLStateField],
        path: String,
        error: (_ code: String, _ path: String, _ message: String) -> Void
    ) {
        for (key, value) in expectedState {
            guard let field = stateFields[key] else {
                error("unknown_expected_state_field", "\(path).\(key)",
                      "expected state field is not declared in state_schema")
                continue
            }
            if !valueMatchesStateType(value, type: field.type, nullable: field.nullable) {
                error("expected_state_type_mismatch", "\(path).\(key)",
                      "expected value does not match state field type \(field.type.rawValue)")
            }
        }
    }

    private static func valueMatchesStateType(
        _ value: SMLValue, type: SMLStateType, nullable: Bool
    ) -> Bool {
        if case .null = value { return nullable }
        switch (type, value) {
        case (.string, .string), (.number, .number), (.boolean, .bool),
             (.object, .object), (.array, .array):
            return true
        case (.integer, .number(let number)):
            var input = number
            var rounded = Decimal()
            NSDecimalRound(&rounded, &input, 0, .plain)
            return rounded == number
        default:
            return false
        }
    }

    private static func validateInstruction(
        _ instruction: SMLInstruction,
        path: String,
        present: (String?) -> Bool,
        error: (_ code: String, _ path: String, _ message: String) -> Void,
        warning: (_ code: String, _ path: String, _ message: String) -> Void
    ) {
        validateClosedInstructionFields(instruction, path: path, error: error)
        validateInstructionStrings(instruction, path: path, error: error)

        func require(_ value: String?, _ field: String) {
            if !present(value) {
                error("missing_\(field)", "\(path).\(field)",
                      "\(instruction.op.rawValue) requires \(field)")
            }
        }
        func rejectStandardAlternatives() {
            if instruction.onPass != nil || instruction.onFailure != nil
                || instruction.trueTarget != nil || instruction.falseTarget != nil
                || instruction.retryPolicy != nil {
                error("ambiguous_transition", path,
                      "\(instruction.op.rawValue) uses only the next transition")
            }
        }
        func requireNext() {
            require(instruction.next, "next")
            rejectStandardAlternatives()
        }

        switch instruction.op {
        case .observe:
            require(instruction.source, "source")
            requireNext()
        case .retrieve:
            require(instruction.source, "source")
            requireNext()
        case .callTool:
            require(instruction.capability, "capability")
            requireNext()
        case .callModel:
            require(instruction.purpose, "purpose")
            require(instruction.outputSchema, "output_schema")
            requireNext()
        case .invokeVCard:
            require(instruction.capability, "capability")
            require(instruction.verifier, "verifier")
            if instruction.expectedState.isEmpty {
                error("missing_expected_state", "\(path).expected_state",
                      "INVOKE_VCARD requires an expected state transition")
            }
            requireNext()
        case .runPlugin:
            guard let plugin = instruction.plugin else {
                error("missing_plugin", "\(path).plugin", "RUN_PLUGIN requires a plugin contract")
                requireNext()
                return
            }
            validatePlugin(plugin, path: "\(path).plugin", present: present,
                           error: error, warning: warning)
            requireNext()
        case .runWorkflow:
            require(instruction.workflow, "workflow")
            requireNext()
        case .branch:
            if instruction.condition == nil {
                error("missing_condition", "\(path).condition", "BRANCH requires a condition")
            }
            require(instruction.trueTarget, "true")
            require(instruction.falseTarget, "false")
            if instruction.trueTarget == instruction.falseTarget {
                error("degenerate_branch", path, "BRANCH true and false targets must differ")
            }
            if instruction.next != nil || instruction.onPass != nil || instruction.onFailure != nil
                || instruction.retryPolicy != nil {
                error("ambiguous_transition", path, "BRANCH uses only true and false transitions")
            }
        case .assert:
            if instruction.condition == nil {
                error("missing_condition", "\(path).condition", "ASSERT requires a condition")
            }
            require(instruction.onPass, "on_pass")
            require(instruction.onFailure, "on_failure")
            rejectOutcomeAlternatives(instruction, path: path, error: error)
        case .verify:
            require(instruction.verifier, "verifier")
            require(instruction.onPass, "on_pass")
            require(instruction.onFailure, "on_failure")
            rejectOutcomeAlternatives(instruction, path: path, error: error)
        case .checkpoint:
            requireNext()
        case .waitApproval:
            require(instruction.reason, "reason")
            require(instruction.owner, "owner")
            require(instruction.next, "next")
            require(instruction.onFailure, "on_failure")
            if instruction.onPass != nil || instruction.trueTarget != nil
                || instruction.falseTarget != nil || instruction.retryPolicy != nil {
                error("ambiguous_transition", path,
                      "WAIT_APPROVAL uses next for approval and on_failure for refusal")
            }
        case .retry:
            guard let retry = instruction.retryPolicy else {
                error("missing_retry_policy", "\(path).retry_policy", "RETRY requires a policy")
                break
            }
            if !SMLValidationSupport.identifierIsValid(retry.target) {
                error("invalid_retry_target", "\(path).retry_policy.target",
                      "retry target is not a valid instruction id")
            }
            if !(1...100).contains(retry.maximumAttempts) {
                error("invalid_retry_budget", "\(path).retry_policy.maximum_attempts",
                      "maximum attempts must be in 1...100")
            }
            if !retry.backoffSeconds.isFinite || retry.backoffSeconds < 0
                || retry.backoffSeconds > 86_400 {
                error("invalid_retry_backoff", "\(path).retry_policy.backoff_seconds",
                      "backoff must be finite and between 0 and 86400 seconds")
            }
            require(instruction.onFailure, "on_failure")
            if instruction.next != nil || instruction.onPass != nil
                || instruction.trueTarget != nil || instruction.falseTarget != nil {
                error("ambiguous_transition", path,
                      "RETRY uses retry_policy.target and on_failure only")
            }
        case .rollback:
            require(instruction.reason, "reason")
            requireNext()
        case .escalate:
            require(instruction.reason, "reason")
            require(instruction.owner, "owner")
            rejectTerminalTransitions(instruction, path: path, error: error)
        case .commit:
            require(instruction.verifier, "verifier")
            requireNext()
        case .emitReceipt:
            if instruction.receiptFields.isEmpty {
                error("missing_receipt_fields", "\(path).receipt_fields",
                      "EMIT_RECEIPT must name the evidence fields it emits")
            }
            if Set(instruction.receiptFields).count != instruction.receiptFields.count
                || instruction.receiptFields.contains(where: {
                    !SMLValidationSupport.identifierIsValid($0)
                }) {
                error("invalid_receipt_fields", "\(path).receipt_fields",
                      "receipt fields must be unique valid identifiers")
            }
            if instruction.receiptFields.count > 128 {
                error("receipt_fields_too_large", "\(path).receipt_fields",
                      "receipt field list exceeds 128 entries")
            }
            rejectTerminalTransitions(instruction, path: path, error: error)
        case .complete:
            rejectTerminalTransitions(instruction, path: path, error: error)
        }
    }

    private static func validateClosedInstructionFields(
        _ instruction: SMLInstruction,
        path: String,
        error: (_ code: String, _ path: String, _ message: String) -> Void
    ) {
        let op = instruction.op
        let fields: [(String, Bool, Set<SMLInstructionOperation>)] = [
            ("source", instruction.source != nil, [.observe, .retrieve]),
            ("purpose", instruction.purpose != nil, [.callModel]),
            ("capability", instruction.capability != nil, [.callTool, .invokeVCard]),
            ("workflow", instruction.workflow != nil, [.runWorkflow]),
            ("verifier", instruction.verifier != nil, [.invokeVCard, .verify, .commit]),
            ("output_schema", instruction.outputSchema != nil, [.callModel]),
            ("reason", instruction.reason != nil, [.waitApproval, .rollback, .escalate]),
            ("owner", instruction.owner != nil, [.waitApproval, .escalate]),
            ("condition", instruction.condition != nil, [.branch, .assert]),
            ("plugin", instruction.plugin != nil, [.runPlugin]),
            ("retry_policy", instruction.retryPolicy != nil, [.retry]),
            ("receipt_fields", !instruction.receiptFields.isEmpty, [.emitReceipt]),
            ("arguments", !instruction.arguments.isEmpty,
             [.observe, .retrieve, .callTool, .callModel, .invokeVCard, .runPlugin,
              .runWorkflow, .verify]),
            ("scope", !instruction.scope.isEmpty,
             [.retrieve, .callTool, .callModel, .invokeVCard, .runPlugin, .runWorkflow]),
            ("expected_state", !instruction.expectedState.isEmpty,
             [.callTool, .invokeVCard, .runPlugin, .runWorkflow, .commit]),
        ]
        for (field, isPresent, allowed) in fields where isPresent && !allowed.contains(op) {
            error("unexpected_field", "\(path).\(field)",
                  "\(field) is not valid for \(op.rawValue)")
        }
    }

    private static func validateInstructionStrings(
        _ instruction: SMLInstruction,
        path: String,
        error: (_ code: String, _ path: String, _ message: String) -> Void
    ) {
        let bounded: [(String, String?)] = [
            ("source", instruction.source),
            ("purpose", instruction.purpose),
            ("capability", instruction.capability),
            ("workflow", instruction.workflow),
            ("verifier", instruction.verifier),
            ("output_schema", instruction.outputSchema),
            ("reason", instruction.reason),
            ("owner", instruction.owner),
        ]
        for (field, value) in bounded {
            guard let value else { continue }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || value.utf8.count > 4_096 {
                error("invalid_instruction_field", "\(path).\(field)",
                      "field must contain 1...4096 UTF-8 bytes")
            }
        }
        let identifiers: [(String, String?)] = [
            ("capability", instruction.capability),
            ("workflow", instruction.workflow),
            ("verifier", instruction.verifier),
            ("output_schema", instruction.outputSchema),
            ("owner", instruction.owner),
        ]
        for (field, value) in identifiers {
            guard let value, !SMLValidationSupport.identifierIsValid(value, maximumLength: 160) else {
                continue
            }
            error("invalid_instruction_identifier", "\(path).\(field)",
                  "field is not a valid SML identifier")
        }
    }

    private static func validatePlugin(
        _ plugin: SMLPluginContract,
        path: String,
        present: (String?) -> Bool,
        error: (_ code: String, _ path: String, _ message: String) -> Void,
        warning: (_ code: String, _ path: String, _ message: String) -> Void
    ) {
        if !SMLValidationSupport.identifierIsValid(plugin.id) {
            error("invalid_plugin_id", "\(path).id", "plugin id is not a valid identifier")
        }
        let collections: [(String, [String])] = [
            ("reads", plugin.reads),
            ("writes", plugin.writes),
            ("preconditions", plugin.preconditions),
            ("postconditions", plugin.postconditions),
        ]
        for (field, values) in collections {
            if values.count > 256 {
                error("plugin_contract_too_large", "\(path).\(field)",
                      "plugin contract list exceeds 256 entries")
            }
            if values.contains(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.utf8.count > 4_096
            }) {
                error("invalid_plugin_contract_value", "\(path).\(field)",
                      "plugin contract entries must contain 1...4096 UTF-8 bytes")
            }
            if Set(values).count != values.count {
                error("duplicate_plugin_contract_value", "\(path).\(field)",
                      "plugin contract entries must be unique")
            }
        }
        for (field, value) in [("rollback", plugin.rollback), ("verifier", plugin.verifier)] {
            if let value, (!SMLValidationSupport.identifierIsValid(value, maximumLength: 160)) {
                error("invalid_plugin_identifier", "\(path).\(field)",
                      "plugin \(field) must be a valid SML identifier")
            }
        }
        if plugin.sideEffectLevel == .unknown {
            warning("plugin_unclassified", path,
                    "plugin is importable but not executable until a host attestation classifies it")
        } else {
            if !plugin.writes.isEmpty
                && (plugin.preconditions.isEmpty || plugin.postconditions.isEmpty) {
                error("incomplete_plugin_contract", path,
                      "plugins that write require preconditions and postconditions")
            }
        }
        if plugin.sideEffectLevel == .readOnly && !plugin.writes.isEmpty {
            error("read_only_plugin_writes", "\(path).writes",
                  "a read-only plugin cannot declare writes")
        }
        if !plugin.writes.isEmpty && plugin.sideEffectLevel != .unknown
            && !present(plugin.verifier) {
            error("missing_plugin_verifier", "\(path).verifier",
                  "a plugin that writes requires a verifier")
        }
        if !plugin.writes.isEmpty,
           (plugin.sideEffectLevel == .reversibleInternal
            || plugin.sideEffectLevel == .reversibleExternal),
           !present(plugin.rollback) {
            error("missing_plugin_rollback", "\(path).rollback",
                  "reversible plugin writes require a rollback procedure")
        }
    }

    private static func rejectOutcomeAlternatives(
        _ instruction: SMLInstruction,
        path: String,
        error: (_ code: String, _ path: String, _ message: String) -> Void
    ) {
        if instruction.next != nil || instruction.trueTarget != nil
            || instruction.falseTarget != nil || instruction.retryPolicy != nil {
            error("ambiguous_transition", path,
                  "\(instruction.op.rawValue) uses only on_pass and on_failure transitions")
        }
    }

    private static func rejectTerminalTransitions(
        _ instruction: SMLInstruction,
        path: String,
        error: (_ code: String, _ path: String, _ message: String) -> Void
    ) {
        if instruction.next != nil || instruction.onPass != nil || instruction.onFailure != nil
            || instruction.trueTarget != nil || instruction.falseTarget != nil
            || instruction.retryPolicy != nil {
            error("terminal_has_transition", path,
                  "\(instruction.op.rawValue) is terminal and cannot have transitions")
        }
    }

    private static func successors(of instruction: SMLInstruction) -> [String] {
        let values: [String?]
        switch instruction.op {
        case .branch:
            values = [instruction.trueTarget, instruction.falseTarget]
        case .assert, .verify:
            values = [instruction.onPass, instruction.onFailure]
        case .waitApproval:
            values = [instruction.next, instruction.onFailure]
        case .retry:
            values = [instruction.retryPolicy?.target, instruction.onFailure]
        case .escalate, .emitReceipt, .complete:
            values = []
        default:
            values = [instruction.next]
        }
        return Array(Set(values.compactMap { $0 })).sorted()
    }

    private static func isTerminal(_ instruction: SMLInstruction) -> Bool {
        instruction.op == .escalate || instruction.op == .emitReceipt || instruction.op == .complete
    }

    private static func reachableIDs(
        from entrypoint: String,
        instructions: [String: SMLInstruction]
    ) -> Set<String> {
        var reachable = Set<String>()
        var pending = [entrypoint]
        while let id = pending.popLast() {
            guard reachable.insert(id).inserted, let instruction = instructions[id] else {
                continue
            }
            pending.append(contentsOf: successors(of: instruction).filter { instructions[$0] != nil })
        }
        return reachable
    }

    private static func IDsThatCanReachTerminal(
        reachable: Set<String>,
        instructions: [String: SMLInstruction]
    ) -> Set<String> {
        var reverse: [String: Set<String>] = [:]
        for id in reachable {
            guard let instruction = instructions[id] else { continue }
            for successor in successors(of: instruction) where reachable.contains(successor) {
                reverse[successor, default: []].insert(id)
            }
        }
        var result = Set(reachable.filter { instructions[$0].map(isTerminal) == true })
        var pending = Array(result)
        while let id = pending.popLast() {
            for predecessor in reverse[id] ?? [] where result.insert(predecessor).inserted {
                pending.append(predecessor)
            }
        }
        return result
    }

    /// Every executable cycle must cross a RETRY instruction, whose durable attempt budget is
    /// decremented by the runtime. Removing RETRY vertices must therefore leave a DAG. Kahn's
    /// algorithm keeps this proof iterative and stack-safe at the maximum workflow size.
    private static func cycleMembersAfterRemovingRetries(
        reachable: Set<String>,
        instructions: [String: SMLInstruction]
    ) -> Set<String> {
        let residual = Set(reachable.filter { instructions[$0]?.op != .retry })
        var indegree = Dictionary(uniqueKeysWithValues: residual.map { ($0, 0) })
        for id in residual {
            guard let instruction = instructions[id] else { continue }
            for successor in successors(of: instruction) where residual.contains(successor) {
                indegree[successor, default: 0] += 1
            }
        }
        var queue = indegree.compactMap { $0.value == 0 ? $0.key : nil }
        var cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]
            cursor += 1
            guard let instruction = instructions[id] else { continue }
            for successor in successors(of: instruction) where residual.contains(successor) {
                guard let current = indegree[successor] else { continue }
                indegree[successor] = current - 1
                if current == 1 { queue.append(successor) }
            }
        }
        return Set(indegree.compactMap { $0.value > 0 ? $0.key : nil })
    }
}
