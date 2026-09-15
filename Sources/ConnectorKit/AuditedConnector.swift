import Foundation

/// Persist an invocation intent before calling the connector, and acknowledge success only
/// after its result is recorded. An unresolved intent remains visible after interruption.
public struct AuditedConnector: Connector {
    private let connector: any Connector
    private let audit: ConnectorAudit
    public var name: String { connector.name }

    public init(_ connector: any Connector, audit: ConnectorAudit) {
        self.connector = connector
        self.audit = audit
    }

    public func actions() -> [ConnectorAction] { connector.actions() }

    public func invoke(action: String, input: [String: String]) async throws -> ConnectorResult {
        let invocationID = UUID().uuidString.lowercased()
        try audit.record(connector: name, action: action, input: input,
                         statusCode: 0, ok: false, atEpoch: Date().timeIntervalSince1970,
                         phase: "started", invocationID: invocationID)
        let result = try await connector.invoke(action: action, input: input)
        do {
            try audit.record(connector: name, action: action, input: input,
                             statusCode: result.statusCode, ok: result.ok,
                             atEpoch: Date().timeIntervalSince1970, phase: "completed", invocationID: invocationID)
        } catch {
            throw ConnectorError.transport("operation \(invocationID) returned HTTP \(result.statusCode), but its audit result could not be saved; inspect the recorded intent before retrying")
        }
        return result
    }
}
