import Foundation

/// Host-derived authority for one authenticated transport session and active worker lease.
/// It is not Codable, so none of these grants can arrive inside the command being checked.
public struct SMLCommandAuthority: Sendable {
    public let authenticatedActor: String
    public let leaseID: String
    public let roles: Set<String>
    public let tasks: Set<String>
    public let operations: Set<String>
    public let scope: SMLObject
    public let maximumCommandAgeSeconds: Double
    public let maximumFutureSkewSeconds: Double

    public init(
        authenticatedActor: String,
        leaseID: String,
        roles: Set<String>,
        tasks: Set<String>,
        operations: Set<String>,
        scope: SMLObject,
        maximumCommandAgeSeconds: Double = 300,
        maximumFutureSkewSeconds: Double = 30
    ) {
        self.authenticatedActor = authenticatedActor
        self.leaseID = leaseID
        self.roles = roles
        self.tasks = tasks
        self.operations = operations
        self.scope = scope
        self.maximumCommandAgeSeconds = maximumCommandAgeSeconds
        self.maximumFutureSkewSeconds = maximumFutureSkewSeconds
    }
}

/// Durable implementations atomically claim a command ID until its expiry. Returning false means
/// the command was already observed; throwing means replay state could not be established fail-closed.
public protocol SMLCommandReplayGuard: Sendable {
    func claim(commandID: String, expiresAtEpoch: Double) async throws -> Bool
}

public enum SMLCommandAdmissionError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidCandidate
    case invalidHostAuthority
    case actorMismatch
    case roleDenied
    case taskDenied
    case operationDenied
    case scopeDenied(path: String)
    case commandExpired
    case commandFromFuture
    case replayedCommand
    case replayGuardFailed(String)

    public var description: String {
        switch self {
        case .invalidCandidate: return "command candidate is not structurally valid"
        case .invalidHostAuthority: return "host command authority is invalid"
        case .actorMismatch: return "command actor does not match authenticated transport actor"
        case .roleDenied: return "command role is not granted by the active authority"
        case .taskDenied: return "command task is not bound to the active worker lease"
        case .operationDenied: return "command operation is not registered for this authority"
        case .scopeDenied(let path): return "command scope exceeds authority at \(path)"
        case .commandExpired: return "command is older than the accepted replay window"
        case .commandFromFuture: return "command timestamp exceeds accepted clock skew"
        case .replayedCommand: return "command ID was already claimed"
        case .replayGuardFailed(let reason): return "replay guard failed closed: \(reason)"
        }
    }
}

/// Opaque authority proof accepted by the future command bus. The original envelope remains internal.
public struct SMLAdmittedCommand: Sendable {
    let command: SMLCommandEnvelope
    let leaseID: String
    let admittedAtEpoch: Double

    public var commandID: String { command.commandID }
    public var op: String { command.op }
    public var task: String { command.task }
}

public enum SMLCommandAdmission {
    public static func admit(
        _ candidate: SMLCommandCandidate,
        authority: SMLCommandAuthority,
        nowEpoch: Double,
        replayGuard: any SMLCommandReplayGuard
    ) async throws -> SMLAdmittedCommand {
        let command = candidate.command
        guard candidate.validationReport.isValid else {
            throw SMLCommandAdmissionError.invalidCandidate
        }
        guard nowEpoch.isFinite, nowEpoch >= 0,
              authority.maximumCommandAgeSeconds.isFinite,
              (0...86_400).contains(authority.maximumCommandAgeSeconds),
              authority.maximumCommandAgeSeconds > 0,
              authority.maximumFutureSkewSeconds.isFinite,
              (0...300).contains(authority.maximumFutureSkewSeconds),
              SMLValidationSupport.identifierIsValid(authority.authenticatedActor),
              SMLValidationSupport.identifierIsValid(authority.leaseID) else {
            throw SMLCommandAdmissionError.invalidHostAuthority
        }
        guard command.actor == authority.authenticatedActor else {
            throw SMLCommandAdmissionError.actorMismatch
        }
        guard authority.roles.contains(command.role) else {
            throw SMLCommandAdmissionError.roleDenied
        }
        guard authority.tasks.contains(command.task) else {
            throw SMLCommandAdmissionError.taskDenied
        }
        guard authority.operations.contains(command.op) else {
            throw SMLCommandAdmissionError.operationDenied
        }
        if let deniedPath = firstScopeViolation(requested: command.scope, allowed: authority.scope) {
            throw SMLCommandAdmissionError.scopeDenied(path: deniedPath)
        }
        guard command.issuedAtEpoch <= nowEpoch + authority.maximumFutureSkewSeconds else {
            throw SMLCommandAdmissionError.commandFromFuture
        }
        guard command.issuedAtEpoch >= nowEpoch - authority.maximumCommandAgeSeconds else {
            throw SMLCommandAdmissionError.commandExpired
        }

        let expiresAt = command.issuedAtEpoch
            + authority.maximumCommandAgeSeconds
            + authority.maximumFutureSkewSeconds
        let claimed: Bool
        do {
            claimed = try await replayGuard.claim(
                commandID: command.commandID, expiresAtEpoch: expiresAt
            )
        } catch {
            throw SMLCommandAdmissionError.replayGuardFailed(String(describing: error))
        }
        guard claimed else { throw SMLCommandAdmissionError.replayedCommand }

        return SMLAdmittedCommand(
            command: command, leaseID: authority.leaseID, admittedAtEpoch: nowEpoch
        )
    }

    private static func firstScopeViolation(
        requested: SMLObject, allowed: SMLObject, path: String = "scope"
    ) -> String? {
        for key in requested.keys.sorted() {
            guard let requestedValue = requested[key], let allowedValue = allowed[key] else {
                return "\(path).\(key)"
            }
            switch (requestedValue, allowedValue) {
            case (.object(let requestedObject), .object(let allowedObject)):
                if let nested = firstScopeViolation(
                    requested: requestedObject, allowed: allowedObject,
                    path: "\(path).\(key)"
                ) {
                    return nested
                }
            default:
                if requestedValue != allowedValue { return "\(path).\(key)" }
            }
        }
        return nil
    }
}
