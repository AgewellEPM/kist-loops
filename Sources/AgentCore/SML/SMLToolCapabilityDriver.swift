import Foundation

/// Production `CALL_TOOL` driver: routes an admitted tool capability to kist's real
/// `AgentTool` registry and executes it under the host `ToolContext` — project-root confinement,
/// `ShellPolicy`, `SandboxPolicy`, and the audit log all apply automatically at the tool protocol
/// layer, not as driver-side promises.
///
/// `supports` is the intersection of three authorities: the instruction must be `CALL_TOOL`, the
/// reference must be in the host catalog's `tool_capabilities` (checked at admission AND here),
/// and a tool of that name must actually be registered. A capability the catalog admits but the
/// registry lacks fails at dispatch with a named error, never silently.
public struct SMLToolCapabilityDriver: SMLInstructionDriver {
    public let id = "kist-tool-driver"

    private let allowedCapabilities: Set<String>
    private let tool: @Sendable (String) -> (any AgentTool)?
    private let context: ToolContext
    private let clock: @Sendable () -> Double

    public init(
        allowedCapabilities: Set<String>,
        toolLookup: @escaping @Sendable (String) -> (any AgentTool)?,
        context: ToolContext,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.allowedCapabilities = allowedCapabilities
        self.tool = toolLookup
        self.context = context
        self.clock = clock
    }

    public func supports(_ request: SMLCapabilityRequest) -> Bool {
        request.operation == .callTool && allowedCapabilities.contains(request.reference)
    }

    public func execute(
        _ invocation: SMLCapabilityInvocation
    ) async throws -> SMLCapabilityOutcome {
        let request = invocation.request
        guard let tool = tool(request.reference) else {
            throw SMLCapabilityDriverConfigurationError.unknownTool(capability: request.reference)
        }
        let outputField = try SMLCapabilityDriverSupport.outputField(of: request)

        var arguments = request.arguments
        arguments.removeValue(forKey: SMLCapabilityDriverSupport.outputFieldArgument)
        let result: ToolResult
        do {
            result = try await tool.execute(
                arguments: SMLCapabilityDriverSupport.foundationArguments(arguments),
                context: context
            )
        } catch {
            // A throwing tool (confinement refusal, shell policy, bad arguments) is a FAILED
            // outcome with the refusal preserved as evidence — not a driver crash. The task
            // parks visibly instead of the pump dying.
            return SMLCapabilityDriverSupport.outcome(
                for: invocation,
                driverID: id,
                status: .failed,
                statePatch: [:],
                evidencePayload: [
                    "capability": .string(request.reference),
                    "error": .string(String(describing: error)),
                ],
                receiptID: "tool.\(request.reference).threw",
                observedAtEpoch: clock()
            )
        }

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
