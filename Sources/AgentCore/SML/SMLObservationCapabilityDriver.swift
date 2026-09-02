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
    private let tool: @Sendable (String) -> (any AgentTool)?
    private let context: ToolContext
    private let clock: @Sendable () -> Double

    public init(
        allowedSources: Set<String>,
        toolLookup: @escaping @Sendable (String) -> (any AgentTool)?,
        context: ToolContext,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.allowedSources = allowedSources
        self.tool = toolLookup
        self.context = context
        self.clock = clock
    }

    public func supports(_ request: SMLCapabilityRequest) -> Bool {
        request.operation == .observe && allowedSources.contains(request.reference)
    }

    public func execute(
        _ invocation: SMLCapabilityInvocation
    ) async throws -> SMLCapabilityOutcome {
        let request = invocation.request
        guard let tool = tool(request.reference) else {
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
        let result: ToolResult
        do {
            result = try await tool.execute(
                arguments: SMLCapabilityDriverSupport.foundationArguments(arguments),
                context: context
            )
        } catch {
            return SMLCapabilityDriverSupport.outcome(
                for: invocation,
                driverID: id,
                status: .failed,
                statePatch: [:],
                evidencePayload: [
                    "source": .string(request.reference),
                    "error": .string(String(describing: error)),
                ],
                receiptID: "observe.\(request.reference).threw",
                observedAtEpoch: clock()
            )
        }

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
