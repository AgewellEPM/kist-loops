import Crypto
import Foundation

/// Shared plumbing for production capability drivers: the SMLValue↔Foundation bridge (drivers talk
/// to `AgentTool.execute(arguments: [String: Any], ...)`), canonical evidence digests, and the one
/// state-output convention. Kept separate so each driver file owns exactly one capability seam.
public enum SMLCapabilityDriverSupport {
    /// The argument key naming the declared state field a driver writes its result into.
    /// Optional: absent means the step produces evidence only, no state patch. The runtime
    /// validates every patch against the workflow's state schema, so a typo'd field name fails
    /// the completion loudly instead of writing untyped state.
    public static let outputFieldArgument = "output_field"

    public static func foundationValue(_ value: SMLValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let bool): return bool
        case .number(let number): return NSDecimalNumber(decimal: number)
        case .string(let string): return string
        case .array(let array): return array.map(foundationValue)
        case .object(let object): return object.mapValues(foundationValue)
        }
    }

    public static func foundationArguments(_ object: SMLObject) -> [String: Any] {
        object.mapValues(foundationValue)
    }

    /// Canonical SHA-256 over sorted-key JSON so identical results digest identically across
    /// processes; evidence digests bind the outcome to what the driver actually observed.
    public static func evidenceDigest(_ object: SMLObject) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(object)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The declared output field for a request, if any. Fails loudly on a non-string value —
    /// a malformed convention must never silently drop a result.
    public static func outputField(of request: SMLCapabilityRequest) throws -> String? {
        guard let value = request.arguments[outputFieldArgument] else { return nil }
        guard case .string(let field) = value, !field.isEmpty else {
            throw SMLCapabilityDriverConfigurationError.invalidOutputField(
                instructionID: request.instructionID
            )
        }
        return field
    }

    /// Builds the passed/failed outcome envelope every driver returns, binding dispatch identity
    /// and the pre-execution state digest exactly as the router requires.
    public static func outcome(
        for invocation: SMLCapabilityInvocation,
        driverID: String,
        status: SMLCapabilityOutcomeStatus,
        statePatch: SMLObject,
        evidencePayload: SMLObject,
        receiptID: String,
        observedAtEpoch: Double
    ) -> SMLCapabilityOutcome {
        SMLCapabilityOutcome(
            dispatchID: invocation.dispatchID,
            instructionID: invocation.request.instructionID,
            requestStateDigest: invocation.request.stateDigest,
            status: status,
            statePatch: statePatch,
            evidence: SMLCapabilityEvidence(
                receiptID: receiptID,
                source: driverID,
                digest: evidenceDigest(evidencePayload),
                observedAtEpoch: observedAtEpoch
            )
        )
    }
}

extension SMLCapabilityRouter {
    /// A synthetic request for LAUNCH-TIME route probing only: hosts verify every admitted
    /// catalog reference resolves to at most one driver before any task can run. The request
    /// never reaches a driver's execute path — `driverID(for:)` is pure route selection.
    public static func probeRequest(
        operation: SMLInstructionOperation,
        reference: String
    ) -> SMLCapabilityRequest {
        SMLCapabilityRequest(
            taskID: "PROBE",
            role: "probe-role",
            workflowID: "probe.workflow",
            workflowVersion: "0.0.0",
            taskRevision: 0,
            instructionID: "probe",
            operation: operation,
            reference: reference,
            arguments: [:],
            scope: [:],
            expectedState: [:],
            state: [:],
            stateDigest: String(repeating: "0", count: 64)
        )
    }
}

public enum SMLCapabilityDriverConfigurationError: Error, Equatable, CustomStringConvertible {
    case invalidOutputField(instructionID: String)
    case unknownTool(capability: String)
    case toolNotReadOnly(capability: String)
    case unknownRetrievalSource(String)
    case unknownModelPurpose(String)

    public var description: String {
        switch self {
        case .invalidOutputField(let instructionID):
            return "instruction '\(instructionID)' declares a non-string or empty "
                + "'\(SMLCapabilityDriverSupport.outputFieldArgument)' argument"
        case .unknownTool(let capability):
            return "capability '\(capability)' does not resolve to a registered kist tool"
        case .toolNotReadOnly(let capability):
            return "observation source '\(capability)' resolves to a tool that is not "
                + "host-reviewed read-only — OBSERVE never runs mutating tools"
        case .unknownRetrievalSource(let source):
            return "retrieval source '\(source)' is not configured in .kist/sml/retrieval.json"
        case .unknownModelPurpose(let purpose):
            return "model purpose '\(purpose)' is not configured in .kist/sml/models.json"
        }
    }
}
