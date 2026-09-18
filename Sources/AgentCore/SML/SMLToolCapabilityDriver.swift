import Foundation

/// Production `CALL_TOOL` driver: routes an admitted tool capability to kist's real
/// `AgentTool` registry and executes it under the host `ToolContext` — project-root confinement,
/// `ShellPolicy`, `SandboxPolicy`, and the audit log all apply automatically at the tool protocol
/// layer, not as driver-side promises.
///
/// `supports` requires both `CALL_TOOL` and a reference in the host catalog's
/// `tool_capabilities` (checked at admission AND here). The implementation is resolved again at
/// execution; a capability the catalog admits but the registry lacks fails with a named error.
public struct SMLToolCapabilityDriver: SMLInstructionDriver {
    public let id = "kist-tool-driver"

    private let allowedCapabilities: Set<String>
    private let registry: ToolRegistry
    private let context: ToolContext
    private let clock: @Sendable () -> Double

    public init(
        allowedCapabilities: Set<String>,
        registry: ToolRegistry,
        context: ToolContext,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.allowedCapabilities = allowedCapabilities
        self.registry = registry
        self.context = context
        self.clock = clock
    }

    public func supports(_ request: SMLCapabilityRequest) -> Bool {
        // Admission names a permitted capability, not an installed implementation. Resolve before
        // the coordinator claims dispatch; an absent tool must remain parked and restartable.
        request.operation == .callTool && allowedCapabilities.contains(request.reference)
            && registry.tool(named: request.reference) != nil
    }

    public func execute(
        _ invocation: SMLCapabilityInvocation
    ) async throws -> SMLCapabilityOutcome {
        let request = invocation.request
        guard registry.tool(named: request.reference) != nil else {
            throw SMLCapabilityDriverConfigurationError.unknownTool(capability: request.reference)
        }
        let outputField = try SMLCapabilityDriverSupport.outputField(of: request)

        var arguments = request.arguments
        arguments.removeValue(forKey: SMLCapabilityDriverSupport.outputFieldArgument)
        // Never call AgentTool.execute directly. ToolRegistry.execute is the shared security
        // choke point for ToolGate authorization, schema validation, audit, tracing, and thrown
        // error normalization; bypassing it would make serve mode less constrained than Kist.
        let result = await registry.execute(
            name: request.reference,
            arguments: SMLCapabilityDriverSupport.foundationArguments(arguments),
            context: context.withCorrelationID(invocation.dispatchID)
        )

        var statePatch: SMLObject = [:]
        if result.success, let outputField {
            statePatch[outputField] = .string(result.output)
        }
        let evidencePayload: SMLObject = [
            "capability": .string(request.reference),
            "success": .bool(result.success),
            "output": .string(result.output),
            "error": result.error.map { .string($0) } ?? .null,
        ]
        return SMLCapabilityDriverSupport.outcome(
            for: invocation,
            driverID: id,
            status: result.success ? .passed : .failed,
            statePatch: statePatch,
            evidencePayload: evidencePayload,
            receiptID: "tool.\(request.reference).\(result.success ? "passed" : "failed")",
            observedAtEpoch: clock()
        )
    }
}
