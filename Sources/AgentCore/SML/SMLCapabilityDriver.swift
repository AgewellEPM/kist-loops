import Foundation

/// Host-minted execution authority for one exact RUN_PLUGIN instruction.
///
/// The initializer is intentionally module-internal: drivers may inspect the immutable isolation
/// decision and exact binding, but cannot attach a different attestation to a runtime request. The
/// digest is also folded into the capability state digest persisted by the durable claim.
public struct SMLPluginExecutionAttestation: Sendable, Equatable {
    public let pluginID: String
    public let workflowID: String
    public let workflowVersion: String
    public let instructionID: String
    public let trustLevel: SMLPluginTrustLevel
    public let isolation: SMLPluginIsolation
    public let attestedBy: String
    public let bindingDigest: String

    let contract: SMLPluginContract

    init(
        attestation: SMLPluginAttestation,
        workflowID: String,
        workflowVersion: String,
        instructionID: String
    ) throws {
        struct Binding: Encodable {
            let pluginID: String
            let workflowID: String
            let workflowVersion: String
            let instructionID: String
            let contract: SMLPluginContract
            let trustLevel: String
            let isolation: String
            let attestedBy: String
        }

        let trustLevel: String
        switch attestation.trustLevel {
        case .contracted: trustLevel = "contracted"
        case .verified: trustLevel = "verified"
        }
        let isolation: String
        switch attestation.isolation {
        case .sandboxed: isolation = "sandboxed"
        case .trustedProcess: isolation = "trusted_process"
        }
        let binding = Binding(
            pluginID: attestation.contract.id,
            workflowID: workflowID,
            workflowVersion: workflowVersion,
            instructionID: instructionID,
            contract: attestation.contract,
            trustLevel: trustLevel,
            isolation: isolation,
            attestedBy: attestation.attestedBy
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        pluginID = attestation.contract.id
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.instructionID = instructionID
        self.trustLevel = attestation.trustLevel
        self.isolation = attestation.isolation
        self.attestedBy = attestation.attestedBy
        contract = attestation.contract
        bindingDigest = MythosCrypto.sha256(try encoder.encode(binding))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func isBound(
        to contract: SMLPluginContract,
        workflowID: String,
        workflowVersion: String,
        instructionID: String
    ) -> Bool {
        self.contract == contract
            && pluginID == contract.id
            && self.workflowID == workflowID
            && self.workflowVersion == workflowVersion
            && self.instructionID == instructionID
    }
}

/// Immutable runtime projection of one external instruction. Construction stays inside AgentCore so
/// wire input cannot invent a driver request; callers may inspect it before resolving authority.
public struct SMLCapabilityRequest: Sendable, Equatable {
    public let taskID: String
    public let role: String
    public let workflowID: String
    public let workflowVersion: String
    public let taskRevision: Int
    public let instructionID: String
    public let operation: SMLInstructionOperation
    public let reference: String
    public let outputSchema: String?
    public let verifier: String?
    public let plugin: SMLPluginContract?
    public let pluginExecutionAttestation: SMLPluginExecutionAttestation?
    public let arguments: SMLObject
    public let scope: SMLObject
    public let expectedState: SMLObject
    public let state: SMLObject
    public let stateDigest: String

    init(
        taskID: String,
        role: String,
        workflowID: String,
        workflowVersion: String,
        taskRevision: Int,
        instructionID: String,
        operation: SMLInstructionOperation,
        reference: String,
        outputSchema: String? = nil,
        verifier: String? = nil,
        plugin: SMLPluginContract? = nil,
        pluginExecutionAttestation: SMLPluginExecutionAttestation? = nil,
        arguments: SMLObject,
        scope: SMLObject,
        expectedState: SMLObject,
        state: SMLObject,
        stateDigest: String
    ) {
        self.taskID = taskID
        self.role = role
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.taskRevision = taskRevision
        self.instructionID = instructionID
        self.operation = operation
        self.reference = reference
        self.outputSchema = outputSchema
        self.verifier = verifier
        self.plugin = plugin
        self.pluginExecutionAttestation = pluginExecutionAttestation
        self.arguments = arguments
        self.scope = scope
        self.expectedState = expectedState
        self.state = state
        self.stateDigest = stateDigest
    }
}

/// Capability drivers can report observations, but they cannot promote their own output into host
/// acceptance. VERIFY and COMMIT remain fail-closed until a separate host-owned verifier mints an
/// opaque accepted receipt.
public enum SMLCapabilityEvidenceAuthority: String, Sendable, Codable, Equatable {
    case observed
}

public enum SMLCapabilityOutcomeStatus: String, Sendable, Codable, Equatable {
    case passed
    case failed
}

public struct SMLCapabilityEvidence: Sendable, Equatable {
    public let receiptID: String
    public let source: String
    public let digest: String
    public let authority: SMLCapabilityEvidenceAuthority
    public let observedAtEpoch: Double

    public init(
        receiptID: String,
        source: String,
        digest: String,
        observedAtEpoch: Double
    ) {
        self.receiptID = receiptID
        self.source = source
        self.digest = digest
        self.authority = .observed
        self.observedAtEpoch = observedAtEpoch
    }
}

/// A driver must bind its result to both the durable dispatch and the exact pre-execution state.
public struct SMLCapabilityOutcome: Sendable, Equatable {
    public let dispatchID: String
    public let instructionID: String
    public let requestStateDigest: String
    public let status: SMLCapabilityOutcomeStatus
    public let statePatch: SMLObject
    public let evidence: SMLCapabilityEvidence

    public init(
        dispatchID: String,
        instructionID: String,
        requestStateDigest: String,
        status: SMLCapabilityOutcomeStatus,
        statePatch: SMLObject = [:],
        evidence: SMLCapabilityEvidence
    ) {
        self.dispatchID = dispatchID
        self.instructionID = instructionID
        self.requestStateDigest = requestStateDigest
        self.status = status
        self.statePatch = statePatch
        self.evidence = evidence
    }
}

/// Opaque proof that command admission and the runtime's durable single-flight transition happened
/// before a driver was called. The dispatch ID is the driver's external idempotency key.
public struct SMLClaimedCapability: Sendable {
    public let request: SMLCapabilityRequest
    public let dispatchID: String
    public let driverID: String
    let record: SMLCapabilityClaimRecord

    init(request: SMLCapabilityRequest, record: SMLCapabilityClaimRecord) {
        self.request = request
        dispatchID = record.dispatchID
        driverID = record.driverID
        self.record = record
    }
}

public struct SMLCapabilityInvocation: Sendable {
    public let request: SMLCapabilityRequest
    public let dispatchID: String
    public let driverID: String

    init(claimed: SMLClaimedCapability) {
        request = claimed.request
        dispatchID = claimed.dispatchID
        driverID = claimed.driverID
    }
}

/// Opaque router validation result. A raw driver outcome cannot reach runtime completion directly.
public struct SMLRoutedCapabilityOutcome: Sendable {
    public let outcome: SMLCapabilityOutcome
    public let dispatchID: String
    public let driverID: String
    let claimRecord: SMLCapabilityClaimRecord

    init(outcome: SMLCapabilityOutcome, claimed: SMLClaimedCapability) {
        self.outcome = outcome
        dispatchID = claimed.dispatchID
        driverID = claimed.driverID
        claimRecord = claimed.record
    }
}

public protocol SMLInstructionDriver: Sendable {
    var id: String { get }
    func supports(_ request: SMLCapabilityRequest) -> Bool
    func execute(_ invocation: SMLCapabilityInvocation) async throws -> SMLCapabilityOutcome
}

public enum SMLCapabilityRouterError: Error, Sendable, Equatable, CustomStringConvertible {
    case noDriver(operation: String, reference: String)
    case ambiguousDrivers([String])
    case invalidDriverID(String)
    case mismatchedDispatch
    case mismatchedInstruction
    case staleRequestDigest
    case evidenceSourceMismatch(expected: String, actual: String)
    case insufficientEvidence(operation: String)
    case invalidEvidence(String)

    public var description: String {
        switch self {
        case .noDriver(let operation, let reference):
            return "no capability driver for \(operation) \(reference)"
        case .ambiguousDrivers(let ids):
            return "multiple capability drivers matched: \(ids.joined(separator: ", "))"
        case .invalidDriverID(let id): return "invalid capability driver id: \(id)"
        case .mismatchedDispatch: return "capability outcome names a different dispatch"
        case .mismatchedInstruction: return "capability outcome names a different instruction"
        case .staleRequestDigest:
            return "capability outcome is not bound to the claimed state digest"
        case .evidenceSourceMismatch(let expected, let actual):
            return "capability evidence source \(actual) does not match driver \(expected)"
        case .insufficientEvidence(let operation):
            return "\(operation) requires a host-accepted receipt; driver observations are insufficient"
        case .invalidEvidence(let reason): return "capability evidence is invalid: \(reason)"
        }
    }
}

public struct SMLCapabilityRouter: Sendable {
    private let drivers: [any SMLInstructionDriver]

    public init(drivers: [any SMLInstructionDriver]) {
        self.drivers = drivers
    }

    /// Pure route selection used before acquiring the dispatch claim. It never calls a driver.
    public func driverID(for request: SMLCapabilityRequest) throws -> String {
        let matching = drivers.filter { $0.supports(request) }
        guard !matching.isEmpty else {
            throw SMLCapabilityRouterError.noDriver(
                operation: request.operation.rawValue, reference: request.reference
            )
        }
        guard matching.count == 1, let driver = matching.first else {
            throw SMLCapabilityRouterError.ambiguousDrivers(matching.map(\.id).sorted())
        }
        guard SMLValidationSupport.identifierIsValid(driver.id) else {
            throw SMLCapabilityRouterError.invalidDriverID(driver.id)
        }
        return driver.id
    }

    public func execute(
        _ claimed: SMLClaimedCapability
    ) async throws -> SMLRoutedCapabilityOutcome {
        let matching = drivers.filter {
            $0.id == claimed.driverID && $0.supports(claimed.request)
        }
        guard matching.count == 1, let driver = matching.first else {
            if matching.isEmpty {
                throw SMLCapabilityRouterError.noDriver(
                    operation: claimed.request.operation.rawValue,
                    reference: claimed.request.reference
                )
            }
            throw SMLCapabilityRouterError.ambiguousDrivers(matching.map(\.id).sorted())
        }
        let outcome = try await driver.execute(SMLCapabilityInvocation(claimed: claimed))
        guard outcome.dispatchID == claimed.dispatchID else {
            throw SMLCapabilityRouterError.mismatchedDispatch
        }
        guard outcome.instructionID == claimed.request.instructionID else {
            throw SMLCapabilityRouterError.mismatchedInstruction
        }
        guard outcome.requestStateDigest == claimed.request.stateDigest else {
            throw SMLCapabilityRouterError.staleRequestDigest
        }
        guard outcome.evidence.source == driver.id else {
            throw SMLCapabilityRouterError.evidenceSourceMismatch(
                expected: driver.id, actual: outcome.evidence.source
            )
        }
        try Self.validate(outcome.evidence)
        if [.verify, .commit].contains(claimed.request.operation) {
            throw SMLCapabilityRouterError.insufficientEvidence(
                operation: claimed.request.operation.rawValue
            )
        }
        return SMLRoutedCapabilityOutcome(outcome: outcome, claimed: claimed)
    }

    static func validate(_ evidence: SMLCapabilityEvidence) throws {
        guard SMLValidationSupport.identifierIsValid(evidence.receiptID),
              SMLValidationSupport.identifierIsValid(evidence.source) else {
            throw SMLCapabilityRouterError.invalidEvidence(
                "receipt id and source must be identifiers"
            )
        }
        guard evidence.digest.count == 64,
              evidence.digest == evidence.digest.lowercased(),
              evidence.digest.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            throw SMLCapabilityRouterError.invalidEvidence(
                "digest must be lowercase SHA-256 hex"
            )
        }
        guard evidence.observedAtEpoch.isFinite, evidence.observedAtEpoch >= 0 else {
            throw SMLCapabilityRouterError.invalidEvidence(
                "observation time must be finite and non-negative"
            )
        }
    }
}

public struct SMLCapabilityClaimCompiler: Sendable {
    private let actor: String
    private let commandID: @Sendable () -> String
    private let dispatchID: @Sendable () -> String

    public init(
        actor: String,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        dispatchID: @escaping @Sendable () -> String = {
            "dispatch-" + UUID().uuidString.lowercased()
        }
    ) {
        self.actor = actor
        self.commandID = commandID
        self.dispatchID = dispatchID
    }

    public func compile(
        request: SMLCapabilityRequest,
        driverID: String,
        issuedAtEpoch: Double
    ) throws -> SMLCommandEnvelope {
        guard SMLValidationSupport.identifierIsValid(driverID) else {
            throw SMLCapabilityRouterError.invalidDriverID(driverID)
        }
        var expected = request.state
        expected["instruction_id"] = .string(request.instructionID)
        expected["workflow_version"] = .string(request.workflowVersion)
        expected["task_status"] = .string(SMLTaskStatus.waitingCapability.rawValue)
        expected["task_revision"] = .number(Decimal(request.taskRevision))
        expected["capability_state_digest"] = .string(request.stateDigest)
        let envelope = SMLCommandEnvelope(
            commandID: commandID(),
            actor: actor,
            role: request.role,
            task: request.taskID,
            op: SMLRuntimeCommandOperation.taskClaimCapability,
            arguments: [
                "workflow_id": .string(request.workflowID),
                "workflow_version": .string(request.workflowVersion),
                "instruction_id": .string(request.instructionID),
                "capability_operation": .string(request.operation.rawValue),
                "reference": .string(request.reference),
                "driver_id": .string(driverID),
                "dispatch_id": .string(dispatchID()),
                "request_state_digest": .string(request.stateDigest),
            ],
            scope: request.scope,
            expectedState: expected,
            issuedAtEpoch: issuedAtEpoch
        )
        try Self.requireValid(envelope)
        return envelope
    }

    static func requireValid(_ envelope: SMLCommandEnvelope) throws {
        let report = envelope.validate()
        guard report.isValid else {
            throw SMLWorkflowSurfaceError.invalidEnvelope(
                report.errors.map(\.description)
            )
        }
    }
}

public struct SMLCapabilityCompletionCompiler: Sendable {
    private let actor: String
    private let commandID: @Sendable () -> String

    public init(
        actor: String,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.actor = actor
        self.commandID = commandID
    }

    /// Authority-only preview resolved before any driver call. Runtime never accepts this shape as
    /// completion; the final exact envelope is still admitted after a routed outcome exists.
    public func preflight(
        request: SMLCapabilityRequest,
        driverID: String,
        dispatchID: String,
        issuedAtEpoch: Double
    ) throws -> SMLCommandEnvelope {
        let envelope = SMLCommandEnvelope(
            commandID: commandID(),
            actor: actor,
            role: request.role,
            task: request.taskID,
            op: SMLRuntimeCommandOperation.taskRecordStep,
            arguments: [
                "workflow_id": .string(request.workflowID),
                "workflow_version": .string(request.workflowVersion),
                "dispatch_id": .string(dispatchID),
                "driver_id": .string(driverID),
                "phase": .string("authority_preflight"),
            ],
            scope: request.scope,
            issuedAtEpoch: issuedAtEpoch
        )
        try SMLCapabilityClaimCompiler.requireValid(envelope)
        return envelope
    }

    public func compile(
        claimed: SMLClaimedCapability,
        routed: SMLRoutedCapabilityOutcome,
        issuedAtEpoch: Double
    ) throws -> SMLCommandEnvelope {
        guard routed.claimRecord == claimed.record,
              routed.dispatchID == claimed.dispatchID,
              routed.driverID == claimed.driverID else {
            throw SMLRuntimeError.capabilityClaimMismatch
        }
        let outcome = routed.outcome
        try SMLCapabilityRouter.validate(outcome.evidence)
        var expected = claimed.request.state
        expected["instruction_id"] = .string(claimed.request.instructionID)
        expected["workflow_version"] = .string(claimed.request.workflowVersion)
        expected["task_status"] = .string(SMLTaskStatus.waitingCapability.rawValue)
        expected["task_revision"] = .number(Decimal(claimed.request.taskRevision))
        expected["capability_state_digest"] = .string(claimed.request.stateDigest)
        let evidence: SMLObject = [
            "receipt_id": .string(outcome.evidence.receiptID),
            "source": .string(outcome.evidence.source),
            "digest": .string(outcome.evidence.digest),
            "authority": .string(outcome.evidence.authority.rawValue),
            "observed_at_epoch": .number(Decimal(outcome.evidence.observedAtEpoch)),
            "request_state_digest": .string(outcome.requestStateDigest),
        ]
        let envelope = SMLCommandEnvelope(
            commandID: commandID(),
            actor: actor,
            role: claimed.request.role,
            task: claimed.request.taskID,
            op: SMLRuntimeCommandOperation.taskRecordStep,
            arguments: [
                "workflow_id": .string(claimed.request.workflowID),
                "workflow_version": .string(claimed.request.workflowVersion),
                "dispatch_id": .string(claimed.dispatchID),
                "driver_id": .string(claimed.driverID),
                "outcome": .string(outcome.status.rawValue),
                "state_patch": .object(outcome.statePatch),
                "evidence": .object(evidence),
            ],
            scope: claimed.request.scope,
            expectedState: expected,
            issuedAtEpoch: issuedAtEpoch
        )
        try SMLCapabilityClaimCompiler.requireValid(envelope)
        return envelope
    }
}

/// Executes one bounded capability step. A durable, authority-admitted dispatch is acquired before
/// the host driver sees the request; a crash leaves that dispatch claimed and never auto-reexecutes it.
public struct SMLCapabilityCoordinator: Sendable {
    public typealias AuthorityResolver = @Sendable (
        _ command: SMLCommandEnvelope
    ) async throws -> SMLCommandAuthority

    private let runtime: SMLRuntime
    private let router: SMLCapabilityRouter
    private let claimCompiler: SMLCapabilityClaimCompiler
    private let completionCompiler: SMLCapabilityCompletionCompiler
    private let gateway: SMLCommandGateway
    private let authorityResolver: AuthorityResolver
    private let clock: @Sendable () -> Double

    public init(
        runtime: SMLRuntime,
        router: SMLCapabilityRouter,
        claimCompiler: SMLCapabilityClaimCompiler,
        completionCompiler: SMLCapabilityCompletionCompiler,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping AuthorityResolver,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.runtime = runtime
        self.router = router
        self.claimCompiler = claimCompiler
        self.completionCompiler = completionCompiler
        self.gateway = gateway
        self.authorityResolver = authorityResolver
        self.clock = clock
    }

    public func executeNext(taskID: String) async throws -> SMLCommandResult {
        let request = try await runtime.pendingCapability(taskID: taskID)
        let driverID = try router.driverID(for: request)

        let claimTime = clock()
        let claimCommand = try claimCompiler.compile(
            request: request, driverID: driverID, issuedAtEpoch: claimTime
        )
        let claimAuthority = try await authorityResolver(claimCommand)
        guard case .string(let dispatchID)? = claimCommand.arguments["dispatch_id"] else {
            throw SMLRuntimeError.capabilityClaimMismatch
        }
        let completionPreflight = try completionCompiler.preflight(
            request: request,
            driverID: driverID,
            dispatchID: dispatchID,
            issuedAtEpoch: claimTime
        )
        let preflightAuthority = try await authorityResolver(completionPreflight)
        guard preflightAuthority.leaseID == claimAuthority.leaseID else {
            throw SMLRuntimeError.capabilityClaimMismatch
        }
        try SMLCommandAdmission.preflight(
            completionPreflight,
            authority: preflightAuthority,
            nowEpoch: claimTime
        )
        let claimed = try await gateway.claimCapability(
            claimCommand, authority: claimAuthority, nowEpoch: claimTime
        )

        let routed = try await router.execute(claimed)
        let completionTime = clock()
        let completionCommand = try completionCompiler.compile(
            claimed: claimed, routed: routed, issuedAtEpoch: completionTime
        )
        let completionAuthority = try await authorityResolver(completionCommand)
        return try await gateway.completeCapability(
            completionCommand,
            claimed: claimed,
            routed: routed,
            authority: completionAuthority,
            nowEpoch: completionTime
        )
    }
}

enum SMLCapabilityStateDigest {
    static func compute(
        task: SMLRuntimeTask,
        instruction: SMLInstruction,
        pluginAttestationBindingDigest: String? = nil
    ) throws -> String {
        struct BoundState: Encodable {
            let taskID: String
            let role: String
            let workflowID: String
            let workflowVersion: String
            let taskRevision: Int
            let status: SMLTaskStatus
            let createdAtEpoch: Double
            let updatedAtEpoch: Double
            let state: SMLObject
            let retryCounts: [String: Int]
            let receiptIDs: [String]
            let instruction: SMLInstruction
            let pluginAttestationBindingDigest: String?
        }
        let value = BoundState(
            taskID: task.taskID,
            role: task.role,
            workflowID: task.workflowID,
            workflowVersion: task.workflowVersion,
            taskRevision: task.revision,
            status: task.status,
            createdAtEpoch: task.createdAtEpoch,
            updatedAtEpoch: task.updatedAtEpoch,
            state: task.state,
            retryCounts: task.retryCounts,
            receiptIDs: task.receiptIDs,
            instruction: instruction,
            pluginAttestationBindingDigest: pluginAttestationBindingDigest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = MythosCrypto.sha256(try encoder.encode(value))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
