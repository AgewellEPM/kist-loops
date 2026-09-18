import Foundation

enum SMLWorkflowRuntimeOpenAPIGenerator {
    static func document(
        catalog: SMLWorkflowRuntimeCatalog,
        title: String,
        version: String
    ) -> SMLObject {
        var paths: SMLObject = [:]
        var schemas: SMLObject = [
            "SMLCommandResult": .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
                "description": .string("Runtime command result envelope returned after host admission."),
            ]),
            "SMLExpectedState": .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
                "required": .array([.string("task_revision")]),
                "properties": .object([
                    "task_revision": .object([
                        "type": .string("integer"),
                        "minimum": .number(0),
                    ]),
                ]),
            ]),
            "SMLReconciliation": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("task_revision"), .string("dispatch_id"), .string("note")]),
                "properties": .object([
                    "task_revision": .object(["type": .string("integer"), "minimum": .number(0)]),
                    "dispatch_id": .object(["type": .string("string"), "minLength": .number(1)]),
                    "note": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(4096)]),
                ]),
            ]),
            "SMLRuntimeMetadata": .object([
                "type": .array([.string("object"), .string("array")]),
                "additionalProperties": .bool(true),
                "description": .string("Authority-neutral runtime descriptor payload."),
            ]),
        ]

        for endpoint in catalog.metadataEndpoints {
            var methods = pathObject(paths[endpoint.pathTemplate])
            methods[endpoint.method.rawValue.lowercased()] = .object(
                metadataOperation(endpoint)
            )
            paths[endpoint.pathTemplate] = .object(methods)
        }

        for workflow in catalog.workflows {
            let commandBindingsByAction = Dictionary(
                uniqueKeysWithValues: catalog.planningManifest.commandBindings
                    .filter {
                        $0.workflowID == workflow.workflowID
                            && $0.workflowVersion == workflow.workflowVersion
                    }
                    .map { ($0.action, $0) }
            )
            schemas[inputSchemaName(workflow)] = .object(inputSchema(workflow))
            schemas[startBodySchemaName(workflow)] = .object(startBodySchema(workflow))
            for endpoint in workflow.api.endpoints {
                var methods = pathObject(paths[endpoint.pathTemplate])
                methods[endpoint.method.rawValue.lowercased()] = .object(
                    operation(
                        endpoint,
                        workflow: workflow,
                        commandBinding: commandBindingsByAction[endpoint.action]
                    )
                )
                paths[endpoint.pathTemplate] = .object(methods)
            }
        }

        let agentGuide = catalog.agentGuide
        let hostGuide = catalog.hostGuide
        let hostWiring = catalog.hostWiring
        return [
            "openapi": .string("3.1.0"),
            "info": .object([
                "title": .string(title),
                "version": .string(version),
            ]),
            "paths": .object(paths),
            "components": .object([
                "schemas": .object(schemas),
            ]),
            "x-sml-runtime": .object([
                "schemaVersion": .number(Decimal(catalog.schemaVersion)),
                "workflowIDs": .array(catalog.workflowIDs.map { .string($0) }),
                "mountContractSchemaVersion": .number(
                    Decimal(catalog.mountContract.schemaVersion)
                ),
                "mountAPIRouteCount": .number(Decimal(catalog.mountContract.apiRoutes.count)),
                "mountREPLCount": .number(Decimal(catalog.mountContract.replMounts.count)),
                "mountREPLCommandBindingCount": .number(Decimal(
                    catalog.mountContract.replMounts.reduce(0) { $0 + $1.commandBindings.count }
                )),
                "mountWorkflowCommandBindingCount": .number(Decimal(
                    catalog.mountContract.workflowMounts.reduce(0) {
                        $0 + $1.commandBindings.count
                    }
                )),
                "onyxDriverIDs": .array(catalog.onyxDrivers.map { .string($0.driverID) }),
                "modelToolNames": .array(catalog.modelTools.map { .string($0.tool.name) }),
                "modelRouterToolName": .string(catalog.modelRouter.tool.name),
                "modelRouterTool": .object(modelTool(catalog.modelRouter.tool)),
                "modelRouterExamples": .array(
                    catalog.modelRouter.examples.map(modelToolCallExample)
                ),
                "modelRouterWorkflowMetadata": .array(
                    catalog.modelRouter.workflowMetadata.map(workflowMetadataLink)
                ),
                "modelRouterMaximumCommandRounds": .number(
                    Decimal(catalog.modelRouter.maximumCommandRounds)
                ),
                "metadataEndpoints": .array(
                    catalog.metadataEndpoints.map(metadataEndpoint)
                ),
                "agentGuideSchemaVersion": .number(Decimal(agentGuide.schemaVersion)),
                "agentGuideWorkflowCount": .number(
                    Decimal(agentGuide.workflowGuides.count)
                ),
                "agentGuideModelRouterToolName": .string(agentGuide.modelRouterTool.name),
                "agentGuideCommandBindingCount": .number(Decimal(
                    agentGuide.workflowGuides.reduce(0) { $0 + $1.commandBindings.count }
                )),
                "agentGuideModelDescriptorCount": .number(Decimal(
                    agentGuide.workflowGuides.reduce(0) { $0 + ($1.model == nil ? 0 : 1) }
                )),
                "agentGuideSkillIndexCount": .number(Decimal(
                    agentGuide.workflowGuides.reduce(0) { $0 + $1.skillIndex.count }
                )),
                "hostGuideSchemaVersion": .number(Decimal(hostGuide.schemaVersion)),
                "hostGuideWorkflowCount": .number(
                    Decimal(hostGuide.workflowBindings.count)
                ),
                "hostGuideBindingCount": .number(Decimal(hostGuide.hostBindingCount)),
                "hostGuideCommandBindingCount": .number(Decimal(
                    hostGuide.workflowBindings.reduce(0) { $0 + $1.commandBindings.count }
                )),
                "hostGuideModelDescriptorCount": .number(Decimal(
                    hostGuide.workflowBindings.reduce(0) { $0 + ($1.model == nil ? 0 : 1) }
                )),
                "hostGuideSkillIndexCount": .number(Decimal(
                    hostGuide.workflowBindings.reduce(0) { $0 + $1.skillIndex.count }
                )),
                "hostWiringSchemaVersion": .number(Decimal(hostWiring.schemaVersion)),
                "hostWiringWorkflowCount": .number(Decimal(hostWiring.workflows.count)),
                "hostWiringBindingCount": .number(Decimal(hostWiring.hostBindingCount)),
                "hostWiringModelDescriptorCount": .number(Decimal(
                    hostWiring.workflows.reduce(0) { $0 + ($1.model == nil ? 0 : 1) }
                )),
                "hostWiringSkillIndexCount": .number(Decimal(
                    hostWiring.workflows.reduce(0) { $0 + $1.skillIndex.count }
                )),
                "attachmentManifestCount": .number(
                    Decimal(hostWiring.attachmentManifests.count)
                ),
                "attachmentWorkflowIDs": .array(
                    hostWiring.attachmentManifests.map { .string($0.workflowID) }
                ),
                "attachmentModelDescriptorCount": .number(Decimal(
                    hostWiring.attachmentManifests.reduce(0) { $0 + ($1.model == nil ? 0 : 1) }
                )),
                "attachmentSkillTreeNodeCount": .number(Decimal(
                    hostWiring.attachmentManifests.reduce(0) { $0 + $1.skillTree.count }
                )),
                "attachmentSkillIndexCount": .number(Decimal(
                    hostWiring.attachmentManifests.reduce(0) { $0 + $1.skillIndex.count }
                )),
                "attachmentToolBindingCount": .number(Decimal(
                    hostWiring.attachmentManifests.reduce(0) { $0 + $1.toolBindings.count }
                )),
                "attachmentCommandBindingCount": .number(Decimal(
                    hostWiring.attachmentManifests.reduce(0) { $0 + $1.commandBindings.count }
                )),
                "attachmentPlanCount": .number(Decimal(
                    hostWiring.attachmentManifests.reduce(0) { $0 + ($1.plan == nil ? 0 : 1) }
                )),
                "planningManifestSchemaVersion": .number(
                    Decimal(catalog.planningManifest.schemaVersion)
                ),
                "planningWorkflowIDs": .array(
                    catalog.planningManifest.workflowIDs.map { .string($0) }
                ),
                "planningSkillIndexCount": .number(
                    Decimal(catalog.planningManifest.skillIndex.count)
                ),
                "planningSkillIndex": .array(
                    catalog.planningManifest.skillIndex.map(planningSkill)
                ),
                "planningToolIndex": .array(
                    catalog.planningManifest.toolIndex.map(planningTool)
                ),
                "planningDecomposableUnits": .array(
                    catalog.planningManifest.decomposableUnits.map(decomposableUnit)
                ),
                "planningApprovalGates": .array(
                    catalog.planningManifest.approvalGates.map(approvalGate)
                ),
                "planningCommandBindings": .array(
                    catalog.planningManifest.commandBindings.map(planningCommandBinding)
                ),
            ]),
        ]
    }

    private static func metadataOperation(
        _ endpoint: SMLWorkflowRuntimeMetadataEndpoint
    ) -> SMLObject {
        var object: SMLObject = [
            "operationId": .string(endpoint.operationID),
            "summary": .string(endpoint.summary),
            "tags": .array([.string("sml-runtime")]),
            "responses": .object([
                "200": .object([
                    "description": .string("Authority-neutral SML runtime metadata."),
                    "content": .object([
                        "application/json": .object([
                            "schema": .object(reference("SMLRuntimeMetadata")),
                        ]),
                    ]),
                ]),
            ]),
            "x-sml-runtime-resource": .string(endpoint.resource.rawValue),
            "x-sml-read-only": .bool(true),
            "x-sml-authority": .string("descriptor-only"),
        ]
        if endpoint.pathTemplate.contains("{workflow_id}") {
            object["parameters"] = .array([
                .object([
                    "name": .string("workflow_id"),
                    "in": .string("path"),
                    "required": .bool(true),
                    "schema": .object([
                        "type": .string("string"),
                    ]),
                ]),
            ])
        }
        return object
    }

    private static func operation(
        _ endpoint: SMLWorkflowAPIEndpoint,
        workflow: SMLWorkflowRuntimeDescriptor,
        commandBinding: SMLWorkflowRuntimePlanningCommandBinding?
    ) -> SMLObject {
        let statusCode = endpoint.action == .start ? "201" : "200"
        var object: SMLObject = [
            "operationId": .string(operationID(endpoint, workflow: workflow)),
            "summary": .string(endpoint.summary),
            "tags": .array([.string(workflow.workflowID)]),
            "responses": .object([
                statusCode: .object([
                    "description": .string("Admitted SML runtime result."),
                    "content": .object([
                        "application/json": .object([
                            "schema": .object(reference("SMLCommandResult")),
                        ]),
                    ]),
                ]),
            ]),
            "x-sml-action": .string(endpoint.action.rawValue),
            "x-sml-workflow-id": .string(workflow.workflowID),
            "x-sml-workflow-version": .string(workflow.workflowVersion),
            "x-sml-role": .string(workflow.role),
            "x-sml-model-tool": .string(workflow.model.tool.name),
            "x-sml-model-router-tool": .string(SMLWorkflowRuntimeModelAdapter.toolName),
            "x-sml-onyx-driver-id": .string(workflow.onyx.driverID),
            "x-sml-workflow-runtime-metadata": .object(workflowRuntimeMetadata(workflow)),
            "x-sml-request-examples": .array(endpoint.examples.map(apiExample)),
        ]

        if let commandBinding {
            object["x-sml-command-binding"] = planningCommandBinding(commandBinding)
        }

        if endpoint.pathTemplate.contains("{task_id}") {
            object["parameters"] = .array([
                .object([
                    "name": .string("task_id"),
                    "in": .string("path"),
                    "required": .bool(true),
                    "schema": .object([
                        "type": .string("string"),
                    ]),
                ]),
            ])
        }

        switch endpoint.bodyKind {
        case .none:
            break
        case .startTask:
            var jsonContent: SMLObject = [
                "schema": .object(reference(startBodySchemaName(workflow))),
            ]
            if let examples = requestBodyExamples(endpoint) {
                jsonContent["examples"] = .object(examples)
            }
            object["requestBody"] = .object([
                "required": .bool(true),
                "content": .object([
                    "application/json": .object(jsonContent),
                ]),
            ])
        case .expectedState:
            var jsonContent: SMLObject = [
                "schema": .object(reference(endpoint.action == .reconcile ? "SMLReconciliation" : "SMLExpectedState")),
            ]
            if let examples = requestBodyExamples(endpoint) {
                jsonContent["examples"] = .object(examples)
            }
            object["requestBody"] = .object([
                "required": .bool(true),
                "content": .object([
                    "application/json": .object(jsonContent),
                ]),
            ])
        }
        return object
    }

    private static func apiExample(_ example: SMLWorkflowAPIRequestExample) -> SMLValue {
        .object([
            "method": .string(example.method.rawValue),
            "path": .string(example.path),
            "summary": .string(example.summary),
            "body": .object(example.body),
        ])
    }

    private static func requestBodyExamples(
        _ endpoint: SMLWorkflowAPIEndpoint
    ) -> SMLObject? {
        let examples = endpoint.examples.filter { !$0.body.isEmpty }
        guard !examples.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: examples.enumerated().map { index, example in
            (
                "example\(index + 1)",
                .object([
                    "summary": .string(example.summary),
                    "value": .object(example.body),
                ])
            )
        })
    }

    private static func workflowRuntimeMetadata(
        _ workflow: SMLWorkflowRuntimeDescriptor
    ) -> SMLObject {
        [
            "attachment": .string(runtimeWorkflowPath(
                workflow,
                resourcePath: "attachments"
            )),
            "replMount": .string(runtimeWorkflowPath(
                workflow,
                resourcePath: "repl-mounts"
            )),
            "apiMount": .string(runtimeWorkflowPath(
                workflow,
                resourcePath: "api-mounts"
            )),
            "modelTool": .string(runtimeWorkflowPath(
                workflow,
                resourcePath: "model-tools"
            )),
            "onyxDriver": .string(runtimeWorkflowPath(
                workflow,
                resourcePath: "onyx-drivers"
            )),
            "skillTree": .string(runtimeWorkflowPath(
                workflow,
                resourcePath: "skill-trees"
            )),
            "toolBindings": .string(runtimeWorkflowPath(
                workflow,
                resourcePath: "tool-bindings"
            )),
            "planningBundle": .string(runtimeWorkflowPath(
                workflow,
                resourcePath: "planning"
            )),
        ]
    }

    private static func runtimeWorkflowPath(
        _ workflow: SMLWorkflowRuntimeDescriptor,
        resourcePath: String
    ) -> String {
        "\(workflow.api.basePath)/runtime/\(resourcePath)/\(workflow.workflowID)"
    }

    private static func startBodySchema(_ workflow: SMLWorkflowRuntimeDescriptor) -> SMLObject {
        var required: [SMLValue] = [.string("task_id")]
        if workflow.inputs.contains(where: \.required) {
            required.append(.string("input"))
        }
        return [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array(required),
            "properties": .object([
                "task_id": .object([
                    "type": .string("string"),
                ]),
                "input": .object(reference(inputSchemaName(workflow))),
            ]),
        ]
    }

    private static func inputSchema(_ workflow: SMLWorkflowRuntimeDescriptor) -> SMLObject {
        var properties: SMLObject = [:]
        for field in workflow.inputs {
            properties[field.name] = .object(schema(for: field))
        }
        return [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array(workflow.inputs.filter(\.required).map { .string($0.name) }),
            "properties": .object(properties),
        ]
    }

    private static func schema(for field: SMLWorkflowFieldDescriptor) -> SMLObject {
        var schema: SMLObject = [
            "type": .array(schemaTypes(for: field)),
        ]
        if let description = field.description {
            schema["description"] = .string(description)
        }
        return schema
    }

    private static func schemaTypes(for field: SMLWorkflowFieldDescriptor) -> [SMLValue] {
        var values: [SMLValue]
        switch field.type {
        case .string:
            values = [.string("string")]
        case .number:
            values = [.string("number")]
        case .integer:
            values = [.string("integer")]
        case .boolean:
            values = [.string("boolean")]
        case .object:
            values = [.string("object")]
        case .array:
            values = [.string("array")]
        }
        if field.nullable {
            values.append(.string("null"))
        }
        return values
    }

    private static func pathObject(_ value: SMLValue?) -> SMLObject {
        guard case .object(let object)? = value else { return [:] }
        return object
    }

    private static func modelTool(_ descriptor: SMLWorkflowModelToolDescriptor) -> SMLObject {
        [
            "name": .string(descriptor.name),
            "description": .string(descriptor.description),
            "parameters": .array(descriptor.parameters.map { parameter in
                .object([
                    "name": .string(parameter.name),
                    "type": .string(parameter.type),
                    "description": .string(parameter.description),
                    "required": .bool(parameter.required),
                ])
            }),
        ]
    }

    private static func modelToolCallExample(
        _ example: SMLWorkflowRuntimeModelToolCallExample
    ) -> SMLValue {
        var object: SMLObject = [
            "toolName": .string(example.toolName),
            "line": .string(example.line),
            "arguments": .object(example.arguments),
            "summary": .string(example.summary),
        ]
        if let workflowID = example.workflowID {
            object["workflowID"] = .string(workflowID)
        }
        return .object(object)
    }

    private static func metadataEndpoint(
        _ endpoint: SMLWorkflowRuntimeMetadataEndpoint
    ) -> SMLValue {
        .object([
            "method": .string(endpoint.method.rawValue),
            "pathTemplate": .string(endpoint.pathTemplate),
            "operationID": .string(endpoint.operationID),
            "resource": .string(endpoint.resource.rawValue),
            "summary": .string(endpoint.summary),
        ])
    }

    private static func workflowMetadataLink(
        _ metadata: SMLWorkflowRuntimeWorkflowMetadataLinks
    ) -> SMLValue {
        .object([
            "workflowID": .string(metadata.workflowID),
            "workflowVersion": .string(metadata.workflowVersion),
            "attachmentPath": .string(metadata.attachmentPath),
            "replMountPath": .string(metadata.replMountPath),
            "apiMountPath": .string(metadata.apiMountPath),
            "modelToolPath": .string(metadata.modelToolPath),
            "onyxDriverPath": .string(metadata.onyxDriverPath),
            "skillTreePath": .string(metadata.skillTreePath),
            "toolBindingsPath": .string(metadata.toolBindingsPath),
            "planningBundlePath": .string(metadata.planningBundlePath),
        ])
    }

    private static func planningSkill(
        _ entry: SMLWorkflowRuntimePlanningSkillIndexEntry
    ) -> SMLValue {
        var object: SMLObject = [
            "workflowID": .string(entry.workflowID),
            "workflowVersion": .string(entry.workflowVersion),
            "instructionID": .string(entry.instructionID),
            "kind": .string(entry.kind.rawValue),
            "operation": .string(entry.operation.rawValue),
            "prerequisites": .array(entry.prerequisites.map { .string($0) }),
            "successors": .array(entry.successors.map { .string($0) }),
            "statePreconditions": .array(entry.statePreconditions.map { .string($0) }),
            "expectedState": .object(entry.expectedState),
            "declaredOutputs": .array(entry.declaredOutputs.map { .string($0) }),
            "receiptFields": .array(entry.receiptFields.map { .string($0) }),
            "canDecomposeFurther": .bool(entry.canDecomposeFurther),
            "requiresApproval": .bool(entry.requiresApproval),
            "terminal": .bool(entry.terminal),
        ]
        if let reference = entry.reference {
            object["reference"] = .string(reference)
        }
        if let unitKind = entry.unitKind {
            object["unitKind"] = .string(unitKind.rawValue)
        }
        if let outputSchema = entry.outputSchema {
            object["outputSchema"] = .string(outputSchema)
        }
        return .object(object)
    }

    private static func planningTool(
        _ entry: SMLWorkflowRuntimePlanningToolIndexEntry
    ) -> SMLValue {
        var object: SMLObject = [
            "workflowID": .string(entry.workflowID),
            "instructionID": .string(entry.instructionID),
            "operation": .string(entry.operation.rawValue),
            "reference": .string(entry.reference),
            "statePreconditions": .array(entry.statePreconditions.map { .string($0) }),
            "declaredOutputs": .array(entry.declaredOutputs.map { .string($0) }),
        ]
        if let unitKind = entry.unitKind {
            object["unitKind"] = .string(unitKind.rawValue)
        }
        if let verifier = entry.verifier {
            object["verifier"] = .string(verifier)
        }
        if let sideEffectLevel = entry.sideEffectLevel {
            object["sideEffectLevel"] = .string(sideEffectLevel.rawValue)
        }
        return .object(object)
    }

    private static func decomposableUnit(
        _ unit: SMLWorkflowRuntimePlanningDecompositionUnit
    ) -> SMLValue {
        var object: SMLObject = [
            "workflowID": .string(unit.workflowID),
            "instructionID": .string(unit.instructionID),
            "unitKind": .string(unit.unitKind.rawValue),
            "successors": .array(unit.successors.map { .string($0) }),
        ]
        if let reference = unit.reference {
            object["reference"] = .string(reference)
        }
        return .object(object)
    }

    private static func approvalGate(
        _ gate: SMLWorkflowRuntimePlanningApprovalGate
    ) -> SMLValue {
        var object: SMLObject = [
            "workflowID": .string(gate.workflowID),
            "instructionID": .string(gate.instructionID),
            "statePreconditions": .array(gate.statePreconditions.map { .string($0) }),
            "successors": .array(gate.successors.map { .string($0) }),
        ]
        if let reference = gate.reference {
            object["reference"] = .string(reference)
        }
        return .object(object)
    }

    private static func planningCommandBinding(
        _ binding: SMLWorkflowRuntimePlanningCommandBinding
    ) -> SMLValue {
        var object: SMLObject = [
            "workflowID": .string(binding.workflowID),
            "workflowVersion": .string(binding.workflowVersion),
            "action": .string(binding.action.rawValue),
            "replVerb": .string(binding.replVerb),
            "replAliases": .array(binding.replAliases.map { .string($0) }),
            "replLineTemplate": .string(binding.replLineTemplate),
            "replJSONBodyKind": .string(binding.replJSONBodyKind.rawValue),
            "replJSONFields": .array(binding.replJSONFields.map(fieldDescriptor)),
            "apiMethod": .string(binding.apiMethod.rawValue),
            "apiPathTemplate": .string(binding.apiPathTemplate),
            "apiOperationID": .string(binding.apiOperationID),
            "apiBodyKind": .string(binding.apiBodyKind.rawValue),
            "apiBodyFields": .array(binding.apiBodyFields.map(fieldDescriptor)),
            "readOnly": .bool(binding.readOnly),
            "requiresTask": .bool(binding.requiresTask),
            "changesTaskState": .bool(binding.changesTaskState),
            "modelEligible": .bool(binding.modelEligible),
            "modelToolName": .string(binding.modelToolName),
            "modelRouterToolName": .string(binding.modelRouterToolName),
            "modelRouterArgumentsTemplate": .object(binding.modelRouterArgumentsTemplate),
        ]
        if let line = binding.exampleReplLine {
            object["exampleReplLine"] = .string(line)
        }
        if let path = binding.exampleAPIPath {
            object["exampleAPIPath"] = .string(path)
        }
        if let body = binding.exampleAPIBody {
            object["exampleAPIBody"] = .object(body)
        }
        if let arguments = binding.exampleModelRouterArguments {
            object["exampleModelRouterArguments"] = .object(arguments)
        }
        return .object(object)
    }

    private static func fieldDescriptor(_ field: SMLWorkflowFieldDescriptor) -> SMLValue {
        var object: SMLObject = [
            "name": .string(field.name),
            "type": .string(field.type.rawValue),
            "required": .bool(field.required),
            "nullable": .bool(field.nullable),
        ]
        if let description = field.description {
            object["description"] = .string(description)
        }
        return .object(object)
    }

    private static func reference(_ name: String) -> SMLObject {
        ["$ref": .string("#/components/schemas/\(name)")]
    }

    private static func inputSchemaName(_ workflow: SMLWorkflowRuntimeDescriptor) -> String {
        "WorkflowInput_\(componentSuffix(workflow))"
    }

    private static func startBodySchemaName(_ workflow: SMLWorkflowRuntimeDescriptor) -> String {
        "WorkflowStart_\(componentSuffix(workflow))"
    }

    private static func operationID(
        _ endpoint: SMLWorkflowAPIEndpoint,
        workflow: SMLWorkflowRuntimeDescriptor
    ) -> String {
        "\(endpoint.operationID)_\(componentSuffix(workflow))"
    }

    private static func componentSuffix(_ workflow: SMLWorkflowRuntimeDescriptor) -> String {
        workflow.workflowID
            .split(separator: ".")
            .map { segment in
                segment
                    .split(separator: "-")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined()
            }
            .joined()
    }
}

