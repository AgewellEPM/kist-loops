import Foundation

/// The sole authority-neutral message accepted by the SML command bus.
///
/// Natural language, UI actions, schedulers, APIs, and model workers must all compile to this
/// envelope. It describes a request; it never proves that the actor is authorized or that the
/// requested state transition completed.
public struct SMLCommandEnvelope: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let commandID: String
    public let actor: String
    public let role: String
    public let task: String
    public let op: String
    public let arguments: SMLObject
    public let scope: SMLObject
    public let expectedState: SMLObject
    public let issuedAtEpoch: Double

    public init(
        schemaVersion: Int = SMLCommandEnvelope.currentSchemaVersion,
        commandID: String = UUID().uuidString.lowercased(),
        actor: String,
        role: String,
        task: String,
        op: String,
        arguments: SMLObject = [:],
        scope: SMLObject = [:],
        expectedState: SMLObject = [:],
        issuedAtEpoch: Double = Date().timeIntervalSince1970
    ) {
        self.schemaVersion = schemaVersion
        self.commandID = commandID
        self.actor = actor
        self.role = role
        self.task = task
        self.op = op
        self.arguments = arguments
        self.scope = scope
        self.expectedState = expectedState
        self.issuedAtEpoch = issuedAtEpoch
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case commandID = "command_id"
        case actor, role, task, op, arguments, scope
        case expectedState = "expected_state"
        case issuedAtEpoch = "issued_at_epoch"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        commandID = try container.decode(String.self, forKey: .commandID)
        actor = try container.decode(String.self, forKey: .actor)
        role = try container.decode(String.self, forKey: .role)
        task = try container.decode(String.self, forKey: .task)
        op = try container.decode(String.self, forKey: .op)
        arguments = try container.decodeIfPresent(SMLObject.self, forKey: .arguments) ?? [:]
        scope = try container.decodeIfPresent(SMLObject.self, forKey: .scope) ?? [:]
        expectedState = try container.decodeIfPresent(SMLObject.self, forKey: .expectedState) ?? [:]
        issuedAtEpoch = try container.decode(Double.self, forKey: .issuedAtEpoch)
    }

    public func validate() -> SMLValidationReport {
        var diagnostics: [SMLDiagnostic] = []

        if schemaVersion != Self.currentSchemaVersion {
            diagnostics.append(SMLValidationSupport.error(
                "unsupported_schema", "schema_version",
                "expected schema version \(Self.currentSchemaVersion)"
            ))
        }
        for (path, value, maximumLength) in [
            ("command_id", commandID, 128),
            ("actor", actor, 128),
            ("role", role, 128),
            ("task", task, 128),
            ("op", op, 160),
        ] {
            if !SMLValidationSupport.identifierIsValid(value, maximumLength: maximumLength) {
                diagnostics.append(SMLValidationSupport.error(
                    "invalid_identifier", path,
                    "must use 1...\(maximumLength) letters, numbers, '.', '_', or '-'"
                ))
            }
        }
        if !issuedAtEpoch.isFinite || issuedAtEpoch < 0 {
            diagnostics.append(SMLValidationSupport.error(
                "invalid_timestamp", "issued_at_epoch",
                "must be a finite non-negative epoch timestamp"
            ))
        }
        var valueNodes = 0
        diagnostics += SMLValidationSupport.inspectObject(
            arguments, path: "arguments", nodes: &valueNodes
        )
        diagnostics += SMLValidationSupport.inspectObject(
            scope, path: "scope", nodes: &valueNodes
        )
        diagnostics += SMLValidationSupport.inspectObject(
            expectedState, path: "expected_state", nodes: &valueNodes
        )

        return SMLValidationReport(diagnostics: diagnostics)
    }
}
