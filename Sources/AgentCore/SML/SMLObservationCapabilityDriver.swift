import Foundation

/// Production `OBSERVE` driver: reads through host-reviewed READ-ONLY tools exclusively.
///
/// The read-only guarantee is a TYPE, not a name: the resolved tool must conform to
/// `ReadOnlyAgentTool`, the marker protocol host code applies to intrinsically observational
/// tools. A mutating tool listed as an observation source — by catalog typo or a tool that merely
/// calls itself `read_something` — fails dispatch with `toolNotReadOnly` before any execution.
public struct SMLObservationCapabilityDriver: SMLInstructionDriver {
    public let id = "kist-observation-driver"

    private let allowedSources: Set<String>
    private let registry: ToolRegistry
    private let context: ToolContext
    private let clock: @Sendable () -> Double

    public init(
        allowedSources: Set<String>,
        registry: ToolRegistry,
        context: ToolContext,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.allowedSources = allowedSources
        self.registry = registry
        self.context = context
        self.clock = clock
    }

    public func supports(_ request: SMLCapabilityRequest) -> Bool {
        // Missing or non-observational implementations cannot acquire a dispatch claim. Keep the
        // execute-time type check too, for callers outside the router.
        request.operation == .observe && allowedSources.contains(request.reference)
            && registry.tool(named: request.reference) is ReadOnlyAgentTool
    }

    public func execute(
        _ invocation: SMLCapabilityInvocation
    ) async throws -> SMLCapabilityOutcome {
        let request = invocation.request
        guard let tool = registry.tool(named: request.reference) else {
            throw SMLCapabilityDriverConfigurationError.unknownTool(capability: request.reference)
        }
        guard tool is ReadOnlyAgentTool else {
            throw SMLCapabilityDriverConfigurationError.toolNotReadOnly(
                capability: request.reference
            )
        }
        let outputField = try SMLCapabilityDriverSupport.outputField(of: request)

        var arguments = request.arguments
        arguments.removeValue(forKey: SMLCapabilityDriverSupport.outputFieldArgument)
        // Type-check the resolved implementation above, but execute through the registry so the
        // same ToolGate, argument validation, audit, and tracing boundary applies to observations.
        let result = await registry.execute(
            name: request.reference,
            arguments: SMLCapabilityDriverSupport.foundationArguments(arguments),
            context: context.withCorrelationID(invocation.dispatchID)
        )

        var statePatch: SMLObject = [:]
        if result.success, let outputField {
            statePatch[outputField] = .string(result.output)
        }
        return SMLCapabilityDriverSupport.outcome(
            for: invocation,
            driverID: id,
            status: result.success ? .passed : .failed,
            statePatch: statePatch,
            evidencePayload: [
                "source": .string(request.reference),
                "success": .bool(result.success),
                "output": .string(result.output),
            ],
            receiptID: "observe.\(request.reference).\(result.success ? "passed" : "failed")",
            observedAtEpoch: clock()
        )
    }
}
