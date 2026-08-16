import Foundation

/// Host-owned tools may normalize an invocation before any authorization or evidence boundary.
/// Provider/model output never chooses a canonicalizer: only the concrete registered tool can
/// implement this protocol. The returned arguments become the single input to schema validation,
/// authorization, audit, trusted invocation scope, execution, and telemetry.
public protocol ToolArgumentCanonicalizing {
    func canonicalizeToolArguments(_ arguments: [String: Any]) -> [String: Any]
}
