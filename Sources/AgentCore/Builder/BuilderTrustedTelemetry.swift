import Foundation

public struct BuilderTrustedTelemetryBinding: Sendable, Equatable {
    public let contractFingerprint: String
    public let nodeID: String
    public let attempt: Int
    public let stage: BuilderExecutionStage

    public init(contractFingerprint: String, nodeID: String, attempt: Int,
                stage: BuilderExecutionStage) throws {
        self.contractFingerprint = try BuilderExecutionValidation.digest(
            contractFingerprint, field: "telemetry contract fingerprint")
        self.nodeID = try BuilderExecutionValidation.identifier(nodeID, field: "telemetry node")
        guard attempt > 0 else {
            throw BuilderBudgetLedgerError.invalidObservation("telemetry attempt must be positive")
        }
        self.attempt = attempt
        self.stage = stage
    }
}

public enum BuilderTrustedTelemetryKind: String, Codable, Sendable, Equatable {
    case command, tool, provider, cliProviderInvocation
}

/// Sealed evidence minted only by `CLIChatProvider` after a concrete local CLI process returned a
/// successful response. The caller sees fingerprints, never the prompt, argv, or response bytes.
public struct BuilderTrustedCLIRouteReceipt: Codable, Sendable, Equatable {
    public let observationID: String
    public let contractFingerprint: String
    public let nodeID: String
    public let attempt: Int
    public let stage: BuilderExecutionStage
    public let providerID: String
    public let modelID: String
    public let route: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let usageReported: Bool
    public let wallTimeMilliseconds: Int
    public let requestFingerprint: String
    public let responseFingerprint: String
    public let bindingDigest: String
    public let seal: String

    private struct Payload: Codable {
        let observationID: String; let contractFingerprint: String
        let nodeID: String; let attempt: Int; let stage: BuilderExecutionStage
        let providerID: String; let modelID: String; let route: String
        let inputTokens: Int; let outputTokens: Int; let usageReported: Bool
        let wallTimeMilliseconds: Int
        let requestFingerprint: String; let responseFingerprint: String
    }

    private var payload: Payload {
        .init(observationID: observationID, contractFingerprint: contractFingerprint,
              nodeID: nodeID, attempt: attempt, stage: stage,
              providerID: providerID, modelID: modelID, route: route,
              inputTokens: inputTokens, outputTokens: outputTokens,
              usageReported: usageReported, wallTimeMilliseconds: wallTimeMilliseconds,
              requestFingerprint: requestFingerprint,
              responseFingerprint: responseFingerprint)
    }

    fileprivate init(
        binding: BuilderTrustedTelemetryBinding, observationID: String,
        providerID: String, modelID: String, route: String,
        inputTokens: Int, outputTokens: Int, usageReported: Bool,
        wallTimeMilliseconds: Int, requestFingerprint: String,
        responseFingerprint: String
    ) throws {
        guard ["text-protocol", "native-structured"].contains(route) else {
            throw BuilderBudgetLedgerError.invalidObservation("unknown CLI provider route")
        }
        guard usageReported || (inputTokens == 0 && outputTokens == 0) else {
            throw BuilderBudgetLedgerError.invalidObservation(
                "unreported CLI usage must remain exact zero")
        }
        let payload = Payload(
            observationID: try BuilderExecutionValidation.identifier(
                observationID, field: "CLI provider observation"),
            contractFingerprint: binding.contractFingerprint,
            nodeID: binding.nodeID, attempt: binding.attempt, stage: binding.stage,
            providerID: try BuilderExecutionValidation.text(
                providerID, field: "CLI provider"),
            modelID: try BuilderExecutionValidation.text(modelID, field: "CLI model"),
            route: route, inputTokens: max(0, inputTokens),
            outputTokens: max(0, outputTokens), usageReported: usageReported,
            wallTimeMilliseconds: max(1, wallTimeMilliseconds),
            requestFingerprint: try BuilderExecutionValidation.digest(
                requestFingerprint, field: "CLI request fingerprint"),
            responseFingerprint: try BuilderExecutionValidation.digest(
                responseFingerprint, field: "CLI response fingerprint"))
        let canonical = String(
            decoding: try BuilderDurableIO.canonicalData(payload), as: UTF8.self)
        let digest = BuilderEvidenceDigest.sha256(
            "kist.builder.cli-route.v1\u{0}" + canonical)
        let seal = ForgeSeal.sign(digest)
        guard !seal.isEmpty else { throw BuilderBudgetLedgerError.tampered }
        self.observationID = payload.observationID
        self.contractFingerprint = payload.contractFingerprint
        self.nodeID = payload.nodeID; self.attempt = payload.attempt; self.stage = payload.stage
        self.providerID = payload.providerID; self.modelID = payload.modelID
        self.route = payload.route; self.inputTokens = payload.inputTokens
        self.outputTokens = payload.outputTokens; self.usageReported = payload.usageReported
        self.wallTimeMilliseconds = payload.wallTimeMilliseconds
        self.requestFingerprint = payload.requestFingerprint
        self.responseFingerprint = payload.responseFingerprint
        self.bindingDigest = digest; self.seal = seal
    }

    public var isValid: Bool {
        guard ["text-protocol", "native-structured"].contains(route),
              usageReported || (inputTokens == 0 && outputTokens == 0),
              let canonicalData = try? BuilderDurableIO.canonicalData(payload) else {
            return false
        }
        let expected = BuilderEvidenceDigest.sha256(
            "kist.builder.cli-route.v1\u{0}"
                + String(decoding: canonicalData, as: UTF8.self))
        return expected == bindingDigest && ForgeSeal.verify(bindingDigest, seal: seal)
    }

}

public struct BuilderTrustedCommandReference: Codable, Sendable, Equatable {
    public let observationID: String
    public let invocationID: String
    public let gateArgumentsDigest: String
    public let requestedArgumentsDigest: String
    public let effectiveLauncherDigest: String
    public let effectiveEnvironmentDigest: String?
    public let sandboxProfileDigest: String?
    public let stdoutDigest: String
    public let stderrDigest: String
    public let stdoutByteCount: Int
    public let stderrByteCount: Int
    public let exitCode: Int
    public let timedOut: Bool
    public let wasSignalled: Bool
    public let wallTimeMilliseconds: Int
    public let bindingDigest: String
    public let seal: String

    private struct Payload: Codable {
        let observationID: String; let invocationID: String
        let gateArgumentsDigest: String; let requestedArgumentsDigest: String
        let effectiveLauncherDigest: String; let effectiveEnvironmentDigest: String?
        let sandboxProfileDigest: String?; let stdoutDigest: String; let stderrDigest: String
        let stdoutByteCount: Int; let stderrByteCount: Int; let exitCode: Int
        let timedOut: Bool; let wasSignalled: Bool; let wallTimeMilliseconds: Int
    }

    private var payload: Payload {
        .init(observationID: observationID, invocationID: invocationID,
              gateArgumentsDigest: gateArgumentsDigest,
              requestedArgumentsDigest: requestedArgumentsDigest,
              effectiveLauncherDigest: effectiveLauncherDigest,
              effectiveEnvironmentDigest: effectiveEnvironmentDigest,
              sandboxProfileDigest: sandboxProfileDigest,
              stdoutDigest: stdoutDigest, stderrDigest: stderrDigest,
              stdoutByteCount: stdoutByteCount, stderrByteCount: stderrByteCount,
              exitCode: exitCode, timedOut: timedOut, wasSignalled: wasSignalled,
              wallTimeMilliseconds: wallTimeMilliseconds)
    }

    init(observationID: String, invocationID: String, gateArgumentsDigest: String,
         requestedArgumentsDigest: String, effectiveLauncherDigest: String,
         effectiveEnvironmentDigest: String? = nil, sandboxProfileDigest: String? = nil,
         stdoutDigest: String, stderrDigest: String,
         stdoutByteCount: Int, stderrByteCount: Int, exitCode: Int,
         timedOut: Bool, wasSignalled: Bool, wallTimeMilliseconds: Int) throws {
        let payload = Payload(
            observationID: try BuilderExecutionValidation.identifier(
                observationID, field: "command observation"),
            invocationID: try BuilderExecutionValidation.identifier(
                invocationID, field: "command invocation"),
            gateArgumentsDigest: try BuilderExecutionValidation.digest(
                gateArgumentsDigest, field: "gated command arguments"),
            requestedArgumentsDigest: try BuilderExecutionValidation.digest(
                requestedArgumentsDigest, field: "requested command arguments"),
            effectiveLauncherDigest: try BuilderExecutionValidation.digest(
                effectiveLauncherDigest, field: "effective command launcher"),
            effectiveEnvironmentDigest: try effectiveEnvironmentDigest.map {
                try BuilderExecutionValidation.digest(
                    $0, field: "effective command environment")
            },
            sandboxProfileDigest: try sandboxProfileDigest.map {
                try BuilderExecutionValidation.digest($0, field: "sandbox profile")
            },
            stdoutDigest: try BuilderExecutionValidation.digest(
                stdoutDigest, field: "full stdout"),
            stderrDigest: try BuilderExecutionValidation.digest(
                stderrDigest, field: "full stderr"),
            stdoutByteCount: max(0, stdoutByteCount),
            stderrByteCount: max(0, stderrByteCount), exitCode: exitCode,
            timedOut: timedOut, wasSignalled: wasSignalled,
            wallTimeMilliseconds: max(1, wallTimeMilliseconds))
        let canonical = String(
            decoding: try BuilderDurableIO.canonicalData(payload), as: UTF8.self)
        let binding = BuilderEvidenceDigest.sha256(
            "kist.builder.command-launch.v1\u{0}" + canonical)
        let seal = ForgeSeal.sign(binding)
        guard !seal.isEmpty else { throw BuilderBudgetLedgerError.tampered }
        self.observationID = payload.observationID
        self.invocationID = payload.invocationID
        self.gateArgumentsDigest = payload.gateArgumentsDigest
        self.requestedArgumentsDigest = payload.requestedArgumentsDigest
        self.effectiveLauncherDigest = payload.effectiveLauncherDigest
        self.effectiveEnvironmentDigest = payload.effectiveEnvironmentDigest
        self.sandboxProfileDigest = payload.sandboxProfileDigest
        self.stdoutDigest = payload.stdoutDigest; self.stderrDigest = payload.stderrDigest
        self.stdoutByteCount = payload.stdoutByteCount
        self.stderrByteCount = payload.stderrByteCount
        self.exitCode = payload.exitCode; self.timedOut = payload.timedOut
        self.wasSignalled = payload.wasSignalled
        self.wallTimeMilliseconds = payload.wallTimeMilliseconds
        self.bindingDigest = binding; self.seal = seal
    }

    public var isValid: Bool {
        guard let canonicalData = try? BuilderDurableIO.canonicalData(payload) else { return false }
        let expected = BuilderEvidenceDigest.sha256(
            "kist.builder.command-launch.v1\u{0}"
                + String(decoding: canonicalData, as: UTF8.self))
        return expected == bindingDigest && ForgeSeal.verify(bindingDigest, seal: seal)
    }

    public var isBuilderOSSandboxed: Bool {
        guard isValid,
              let environment = effectiveEnvironmentDigest,
              let profile = sandboxProfileDigest else { return false }
        return environment.count == 64 && profile.count == 64
    }

    public var fullStreamDigest: String {
        BuilderEvidenceDigest.sha256([
            stdoutDigest, String(stdoutByteCount), stderrDigest, String(stderrByteCount),
        ].joined(separator: "\u{0}"))
    }
}

public struct BuilderTrustedTelemetryObservation: Codable, Sendable, Equatable {
    public let id: String
    public let kind: BuilderTrustedTelemetryKind
    public let contractFingerprint: String
    public let nodeID: String
    public let attempt: Int
    public let stage: BuilderExecutionStage
    public let name: String
    public let providerID: String?
    public let modelID: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let wallTimeMilliseconds: Int
    public let exitCode: Int?
    public let success: Bool
    public let warningCount: Int
    public let subjectDigest: String
    public let evidenceBindingDigest: String?
    public let commandReference: BuilderTrustedCommandReference?
    public let cliRouteReceipt: BuilderTrustedCLIRouteReceipt?
    public let workspaceRootIdentity: BuilderWorkspaceRootIdentity?
    public let seal: String

    fileprivate struct Payload: Codable {
        let id: String; let kind: BuilderTrustedTelemetryKind
        let contractFingerprint: String; let nodeID: String; let attempt: Int
        let stage: BuilderExecutionStage; let name: String
        let providerID: String?; let modelID: String?
        let inputTokens: Int; let outputTokens: Int; let wallTimeMilliseconds: Int
        let exitCode: Int?; let success: Bool; let warningCount: Int
        let subjectDigest: String; let evidenceBindingDigest: String?
        let commandReference: BuilderTrustedCommandReference?
        let cliRouteReceipt: BuilderTrustedCLIRouteReceipt?
        let workspaceRootIdentity: BuilderWorkspaceRootIdentity?
    }

    fileprivate var payload: Payload {
        .init(id: id, kind: kind, contractFingerprint: contractFingerprint,
              nodeID: nodeID, attempt: attempt, stage: stage, name: name,
              providerID: providerID, modelID: modelID,
              inputTokens: inputTokens, outputTokens: outputTokens,
              wallTimeMilliseconds: wallTimeMilliseconds, exitCode: exitCode,
              success: success, warningCount: warningCount,
              subjectDigest: subjectDigest,
              evidenceBindingDigest: evidenceBindingDigest,
              commandReference: commandReference,
              cliRouteReceipt: cliRouteReceipt,
              workspaceRootIdentity: workspaceRootIdentity)
    }

    fileprivate init(binding: BuilderTrustedTelemetryBinding,
                     kind: BuilderTrustedTelemetryKind, name: String,
                     providerID: String? = nil, modelID: String? = nil,
                     inputTokens: Int = 0, outputTokens: Int = 0,
                     wallTimeMilliseconds: Int, exitCode: Int? = nil,
                     success: Bool, warningCount: Int = 0,
                     subjectDigest: String,
                     evidenceBindingDigest: String? = nil,
                     commandReference: BuilderTrustedCommandReference? = nil,
                     cliRouteReceipt: BuilderTrustedCLIRouteReceipt? = nil,
                     workspaceRootIdentity: BuilderWorkspaceRootIdentity? = nil,
                     observationID: String? = nil) throws {
        let id = observationID ?? "obs-\(UUID().uuidString.lowercased())"
        let payload = Payload(
            id: id, kind: kind,
            contractFingerprint: binding.contractFingerprint,
            nodeID: binding.nodeID, attempt: binding.attempt, stage: binding.stage,
            name: try BuilderExecutionValidation.identifier(name, field: "telemetry route"),
            providerID: providerID, modelID: modelID,
            inputTokens: max(0, inputTokens), outputTokens: max(0, outputTokens),
            wallTimeMilliseconds: max(1, wallTimeMilliseconds), exitCode: exitCode,
            success: success, warningCount: max(0, warningCount),
            subjectDigest: try BuilderExecutionValidation.digest(
                subjectDigest, field: "telemetry subject digest"),
            evidenceBindingDigest: try evidenceBindingDigest.map {
                try BuilderExecutionValidation.digest(
                    $0, field: "telemetry evidence-binding digest")
            }, commandReference: commandReference, cliRouteReceipt: cliRouteReceipt,
            workspaceRootIdentity: workspaceRootIdentity)
        guard kind == .tool || workspaceRootIdentity == nil else {
            throw BuilderBudgetLedgerError.invalidObservation(
                "workspace root identity is valid only for tool telemetry")
        }
        if let commandReference {
            guard kind == .command, commandReference.observationID == id,
                  commandReference.bindingDigest == payload.evidenceBindingDigest,
                  commandReference.isValid else { throw BuilderBudgetLedgerError.tampered }
        }
        if let cliRouteReceipt {
            guard kind == .cliProviderInvocation, cliRouteReceipt.observationID == id,
                  cliRouteReceipt.contractFingerprint == binding.contractFingerprint,
                  cliRouteReceipt.nodeID == binding.nodeID,
                  cliRouteReceipt.attempt == binding.attempt,
                  cliRouteReceipt.stage == binding.stage,
                  cliRouteReceipt.providerID == providerID,
                  cliRouteReceipt.modelID == modelID,
                  cliRouteReceipt.inputTokens == payload.inputTokens,
                  cliRouteReceipt.outputTokens == payload.outputTokens,
                  cliRouteReceipt.wallTimeMilliseconds == payload.wallTimeMilliseconds,
                  cliRouteReceipt.responseFingerprint == payload.subjectDigest,
                  cliRouteReceipt.isValid else { throw BuilderBudgetLedgerError.tampered }
        }
        let canonical = String(
            decoding: try BuilderDurableIO.canonicalData(payload), as: UTF8.self)
        let seal = ForgeSeal.sign(canonical)
        guard !seal.isEmpty else { throw BuilderBudgetLedgerError.tampered }
        self.id = payload.id; self.kind = payload.kind
        self.contractFingerprint = payload.contractFingerprint
        self.nodeID = payload.nodeID; self.attempt = payload.attempt; self.stage = payload.stage
        self.name = payload.name; self.providerID = payload.providerID; self.modelID = payload.modelID
        self.inputTokens = payload.inputTokens; self.outputTokens = payload.outputTokens
        self.wallTimeMilliseconds = payload.wallTimeMilliseconds
        self.exitCode = payload.exitCode; self.success = payload.success
        self.warningCount = payload.warningCount; self.subjectDigest = payload.subjectDigest
        self.evidenceBindingDigest = payload.evidenceBindingDigest
        self.commandReference = payload.commandReference
        self.cliRouteReceipt = payload.cliRouteReceipt
        self.workspaceRootIdentity = payload.workspaceRootIdentity
        self.seal = seal
    }

    public func validate(binding: BuilderTrustedTelemetryBinding) throws {
        let canonical = String(
            decoding: try BuilderDurableIO.canonicalData(payload), as: UTF8.self)
        guard contractFingerprint == binding.contractFingerprint,
              nodeID == binding.nodeID, attempt == binding.attempt, stage == binding.stage,
              ForgeSeal.verify(canonical, seal: seal) else {
            throw BuilderBudgetLedgerError.tampered
        }
        if kind == .provider {
            guard let providerID, let modelID,
                  !providerID.isEmpty, !modelID.isEmpty,
                  inputTokens + outputTokens > 0 else {
                throw BuilderBudgetLedgerError.invalidObservation(
                    "provider telemetry requires a concrete route and measured nonzero usage")
            }
        }
        if kind == .cliProviderInvocation {
            guard let receipt = cliRouteReceipt, receipt.isValid,
                  receipt.observationID == id, receipt.contractFingerprint == contractFingerprint,
                  receipt.nodeID == nodeID, receipt.attempt == attempt, receipt.stage == stage,
                  receipt.providerID == providerID, receipt.modelID == modelID,
                  receipt.route == name, receipt.inputTokens == inputTokens,
                  receipt.outputTokens == outputTokens,
                  receipt.wallTimeMilliseconds == wallTimeMilliseconds,
                  receipt.responseFingerprint == subjectDigest,
                  success else {
                throw BuilderBudgetLedgerError.invalidObservation(
                    "CLI telemetry requires an exact sealed invocation receipt")
            }
        }
        if kind == .command {
            guard let commandReference, commandReference.isValid,
                  commandReference.observationID == id,
                  commandReference.bindingDigest == evidenceBindingDigest,
                  commandReference.exitCode == exitCode else {
                throw BuilderBudgetLedgerError.invalidObservation(
                    "command telemetry requires an exact sealed launcher reference")
            }
        }
    }

    func accountableBudgetObservation() throws -> BuilderTrustedBudgetObservation? {
        guard kind != .cliProviderInvocation else { return nil }
        return try budgetObservation()
    }

    private func budgetObservation() throws -> BuilderTrustedBudgetObservation {
        let source: BuilderBudgetObservationSource
        let calls: Int
        let tokens: Int
        switch kind {
        case .provider:
            source = .provider(try .init(providerID: providerID ?? "", modelID: modelID ?? ""))
            calls = 0; tokens = inputTokens + outputTokens
        case .tool, .command:
            source = .tool(name); calls = 1; tokens = 0
        case .cliProviderInvocation:
            preconditionFailure("evidence-only CLI telemetry is not budget-accountable")
        }
        return try BuilderTrustedBudgetObservation(
            id: id, contractFingerprint: contractFingerprint, nodeID: nodeID,
            attempt: attempt, stage: stage, source: source,
            toolCalls: calls, tokens: tokens,
            wallTimeMilliseconds: wallTimeMilliseconds,
            telemetrySeal: seal)
    }
}

final class BuilderTrustedTelemetrySession: @unchecked Sendable {
    let binding: BuilderTrustedTelemetryBinding
    let sessionID = "telemetry-\(UUID().uuidString.lowercased())"
    private let lock = NSLock()
    private var observations: [BuilderTrustedTelemetryObservation] = []
    init(binding: BuilderTrustedTelemetryBinding) { self.binding = binding }

    @discardableResult
    func append(kind: BuilderTrustedTelemetryKind, name: String,
                providerID: String? = nil, modelID: String? = nil,
                inputTokens: Int = 0, outputTokens: Int = 0,
                wallTimeMilliseconds: Int, exitCode: Int? = nil,
                success: Bool, warningCount: Int = 0,
                subjectDigest: String, evidenceBindingDigest: String? = nil,
                commandReference: BuilderTrustedCommandReference? = nil,
                cliRouteReceipt: BuilderTrustedCLIRouteReceipt? = nil,
                workspaceRootIdentity: BuilderWorkspaceRootIdentity? = nil,
                observationID: String? = nil) -> BuilderTrustedTelemetryObservation? {
        guard let observation = try? BuilderTrustedTelemetryObservation(
            binding: binding, kind: kind, name: name,
            providerID: providerID, modelID: modelID,
            inputTokens: inputTokens, outputTokens: outputTokens,
            wallTimeMilliseconds: wallTimeMilliseconds, exitCode: exitCode,
            success: success, warningCount: warningCount,
            subjectDigest: subjectDigest,
            evidenceBindingDigest: evidenceBindingDigest,
            commandReference: commandReference,
            cliRouteReceipt: cliRouteReceipt,
            workspaceRootIdentity: workspaceRootIdentity,
            observationID: observationID) else { return nil }
        lock.lock(); observations.append(observation); lock.unlock()
        return observation
    }

    func sealedObservations(registerBudgetAuthority: Bool = true) throws
        -> [BuilderTrustedTelemetryObservation] {
        lock.lock(); let values = observations; lock.unlock()
        guard Set(values.map(\.id)).count == values.count else {
            throw BuilderBudgetLedgerError.conflictingObservation("duplicate telemetry ID")
        }
        defer {
            for receipt in values.compactMap(\.cliRouteReceipt) {
                BuilderTrustedCLIInvocationAuthority.cancel(receipt)
            }
        }
        for value in values {
            try value.validate(binding: binding)
            if registerBudgetAuthority,
               let budget = try value.accountableBudgetObservation() {
                BuilderTrustedTelemetryAuthority.register(
                    id: budget.id, fingerprint: try budget.fingerprint(),
                    telemetrySeal: budget.telemetrySeal)
            }
        }
        return values
    }

    func consumeCLIInvocations(providerID: String, modelID: String)
        throws -> [BuilderTrustedCLIRouteReceipt] {
        lock.lock()
        let receipts = observations.compactMap(\.cliRouteReceipt).filter {
            $0.providerID.lowercased() == providerID.lowercased() && $0.modelID == modelID
        }
        lock.unlock()
        guard !receipts.isEmpty else {
            throw BuilderBudgetLedgerError.invalidObservation(
                "worker CLI identity has no actual CLIChatProvider invocation")
        }
        for receipt in receipts { try BuilderTrustedCLIInvocationAuthority.consume(receipt) }
        return receipts
    }
}

enum BuilderTrustedCLIInvocationAuthority {
    private static let lock = NSLock()
    private static var pending: [String: (String, String)] = [:]

    static func register(_ receipt: BuilderTrustedCLIRouteReceipt) -> Bool {
        guard receipt.isValid else { return false }
        lock.lock(); defer { lock.unlock() }
        guard pending[receipt.observationID] == nil, pending.count < 100_000 else { return false }
        pending[receipt.observationID] = (receipt.bindingDigest, receipt.seal)
        return true
    }

    static func consume(_ receipt: BuilderTrustedCLIRouteReceipt) throws {
        guard receipt.isValid else { throw BuilderBudgetLedgerError.tampered }
        lock.lock(); defer { lock.unlock() }
        guard let expected = pending[receipt.observationID],
              expected.0 == receipt.bindingDigest, expected.1 == receipt.seal else {
            throw BuilderBudgetLedgerError.conflictingObservation(
                "unregistered, forged, or reused CLI invocation \(receipt.observationID)")
        }
        pending.removeValue(forKey: receipt.observationID)
    }

    static func cancel(_ receipt: BuilderTrustedCLIRouteReceipt) {
        lock.lock(); defer { lock.unlock() }
        guard let expected = pending[receipt.observationID],
              expected.0 == receipt.bindingDigest, expected.1 == receipt.seal else { return }
        pending.removeValue(forKey: receipt.observationID)
    }
}

enum BuilderTrustedTelemetryAuthority {
    private static let lock = NSLock()
    private static var pending: [String: (String, String)] = [:]

    static func register(id: String, fingerprint: String, telemetrySeal: String?) {
        guard let telemetrySeal else { return }
        lock.lock(); defer { lock.unlock() }
        if pending.count < 100_000 { pending[id] = (fingerprint, telemetrySeal) }
    }

    static func consume(id: String, fingerprint: String, telemetrySeal: String?) throws {
        guard let telemetrySeal else {
            throw BuilderBudgetLedgerError.invalidObservation(
                "budget authority requires registered trusted telemetry")
        }
        lock.lock(); defer { lock.unlock() }
        guard let expected = pending.removeValue(forKey: id),
              expected.0 == fingerprint, expected.1 == telemetrySeal else {
            throw BuilderBudgetLedgerError.conflictingObservation(
                "unregistered, omitted, or reused telemetry observation \(id)")
        }
    }
}

enum BuilderTrustedTelemetry {
    @TaskLocal static var session: BuilderTrustedTelemetrySession?

    static func withScope<T: Sendable>(
        binding: BuilderTrustedTelemetryBinding,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> (T, [BuilderTrustedTelemetryObservation]) {
        let scoped = BuilderTrustedTelemetrySession(binding: binding)
        let value = try await $session.withValue(scoped) { try await operation() }
        return (value, try scoped.sealedObservations())
    }

    /// Capture observations even when the scoped operation throws. Callers must durably account
    /// the returned observations before rethrowing the captured failure.
    static func captureScope<T: Sendable>(
        binding: BuilderTrustedTelemetryBinding,
        registerBudgetAuthority: Bool = true,
        operation: @escaping @Sendable () async throws -> T
    ) async -> (Result<T, any Error>, [BuilderTrustedTelemetryObservation]) {
        let scoped = BuilderTrustedTelemetrySession(binding: binding)
        do {
            let value = try await $session.withValue(scoped) { try await operation() }
            do {
                return (.success(value), try scoped.sealedObservations(
                    registerBudgetAuthority: registerBudgetAuthority))
            }
            catch { return (.failure(error), []) }
        } catch {
            do {
                return (.failure(error), try scoped.sealedObservations(
                    registerBudgetAuthority: registerBudgetAuthority))
            }
            catch { return (.failure(error), []) }
        }
    }

    static func recordCommand(
        sink: BuilderTrustedCommandSink?, requestedArgumentsDigest: String,
        outcome: ProcessGroupRunner.Outcome, elapsedMilliseconds: Int
    ) -> BuilderTrustedCommandReference? {
        guard let sink,
              BuilderTrustedCommandInvocationAuthority.consume(sink) else { return nil }
        let observationID = "obs-\(UUID().uuidString.lowercased())"
        guard let reference = try? BuilderTrustedCommandReference(
            observationID: observationID, invocationID: sink.invocation.id,
            gateArgumentsDigest: sink.invocation.argumentsDigest,
            requestedArgumentsDigest: requestedArgumentsDigest,
            effectiveLauncherDigest: outcome.effectiveLauncherDigest,
            effectiveEnvironmentDigest: outcome.effectiveEnvironmentDigest,
            sandboxProfileDigest: outcome.sandboxProfileDigest,
            stdoutDigest: outcome.stdoutDigest, stderrDigest: outcome.stderrDigest,
            stdoutByteCount: outcome.stdoutByteCount,
            stderrByteCount: outcome.stderrByteCount,
            exitCode: Int(outcome.exitCode), timedOut: outcome.timedOut,
            wasSignalled: outcome.wasSignalled,
            wallTimeMilliseconds: elapsedMilliseconds) else { return nil }
        let warningCount = (outcome.stdout + "\n" + outcome.stderr)
            .lowercased().components(separatedBy: "warning:").count - 1
        let observation = sink.session.append(
            kind: .command, name: "process",
            wallTimeMilliseconds: elapsedMilliseconds,
            exitCode: Int(outcome.exitCode),
            success: outcome.exitCode == 0 && !outcome.timedOut && !outcome.wasSignalled,
            warningCount: warningCount, subjectDigest: reference.bindingDigest,
            evidenceBindingDigest: reference.bindingDigest,
            commandReference: reference, observationID: observationID)
        return observation == nil ? nil : reference
    }

    static func recordTool(name: String, argumentsDigest: String, success: Bool,
                           elapsedMilliseconds: Int,
                           workspaceRootIdentity: BuilderWorkspaceRootIdentity? = nil) {
        session?.append(kind: .tool, name: name,
                        wallTimeMilliseconds: elapsedMilliseconds, success: success,
                        subjectDigest: argumentsDigest,
                        workspaceRootIdentity: workspaceRootIdentity)
    }

    static func recordProvider(providerID: String, modelID: String,
                               inputTokens: Int, outputTokens: Int,
                               elapsedMilliseconds: Int, outputDigest: String,
                               success: Bool = true, mechanism: String = "completion") {
        session?.append(kind: .provider, name: mechanism,
                        providerID: providerID, modelID: modelID,
                        inputTokens: inputTokens, outputTokens: outputTokens,
                        wallTimeMilliseconds: elapsedMilliseconds,
                        success: success, subjectDigest: outputDigest)
    }

    static func recordCLIProviderInvocation(
        session: BuilderTrustedTelemetrySession?, providerID: String, modelID: String,
        route: String, inputTokens: Int, outputTokens: Int, usageReported: Bool,
        elapsedMilliseconds: Int, requestFingerprint: String, responseFingerprint: String
    ) {
        guard let session else { return }
        let observationID = "obs-\(UUID().uuidString.lowercased())"
        guard let receipt = try? BuilderTrustedCLIRouteReceipt(
            binding: session.binding, observationID: observationID,
            providerID: providerID, modelID: modelID, route: route,
            inputTokens: inputTokens, outputTokens: outputTokens,
            usageReported: usageReported, wallTimeMilliseconds: elapsedMilliseconds,
            requestFingerprint: requestFingerprint,
            responseFingerprint: responseFingerprint),
              BuilderTrustedCLIInvocationAuthority.register(receipt) else { return }
        let observation = session.append(
            kind: .cliProviderInvocation, name: route,
            providerID: providerID, modelID: modelID,
            inputTokens: inputTokens, outputTokens: outputTokens,
            wallTimeMilliseconds: elapsedMilliseconds, success: true,
            subjectDigest: responseFingerprint,
            cliRouteReceipt: receipt, observationID: observationID)
        if observation == nil { BuilderTrustedCLIInvocationAuthority.cancel(receipt) }
    }

    static func rebound(_ observations: [BuilderTrustedTelemetryObservation],
                        to binding: BuilderTrustedTelemetryBinding) throws
        -> [BuilderTrustedTelemetryObservation] {
        try observations.compactMap {
            // A CLI invocation is bound to the exact TaskLocal execution scope that launched it.
            // Rebinding it would turn genuine evidence into a synthetic route claim.
            guard $0.kind != .cliProviderInvocation else { return nil }
            let rebound = try BuilderTrustedTelemetryObservation(
                binding: binding, kind: $0.kind, name: $0.name,
                providerID: $0.providerID, modelID: $0.modelID,
                inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
                wallTimeMilliseconds: $0.wallTimeMilliseconds,
                exitCode: $0.exitCode, success: $0.success,
                warningCount: $0.warningCount, subjectDigest: $0.subjectDigest,
                evidenceBindingDigest: $0.evidenceBindingDigest,
                commandReference: $0.commandReference,
                cliRouteReceipt: nil,
                workspaceRootIdentity: $0.workspaceRootIdentity,
                observationID: $0.commandReference == nil ? nil : $0.id)
            guard let budget = try rebound.accountableBudgetObservation() else {
                throw BuilderBudgetLedgerError.invalidObservation(
                    "rebound telemetry unexpectedly contains evidence-only CLI usage")
            }
            BuilderTrustedTelemetryAuthority.register(
                id: budget.id, fingerprint: try budget.fingerprint(),
                telemetrySeal: budget.telemetrySeal)
            return rebound
        }
    }


    static func consumeCLIInvocations(providerID: String, modelID: String)
        throws -> [BuilderTrustedCLIRouteReceipt] {
        guard let session else {
            throw BuilderBudgetLedgerError.invalidObservation(
                "CLI invocation must be bound before its trusted telemetry scope closes")
        }
        return try session.consumeCLIInvocations(providerID: providerID, modelID: modelID)
    }
}

extension Collection where Element == BuilderTrustedTelemetryObservation {
    func hasSuccessfulProviderRoute(providerID: String, modelID: String) -> Bool {
        contains {
            $0.kind == .provider && $0.success
                && $0.providerID?.lowercased() == providerID.lowercased()
                && $0.modelID == modelID
        }
    }

    func hasAuthenticatedReviewerRoute(providerID: String, modelID: String) -> Bool {
        guard hasSuccessfulProviderRoute(providerID: providerID, modelID: modelID) else {
            return false
        }
        guard ["claude-cli", "codex-cli"].contains(providerID.lowercased()) else {
            return true
        }
        return contains {
            guard $0.kind == .cliProviderInvocation, $0.success,
                  $0.providerID?.lowercased() == providerID.lowercased(),
                  $0.modelID == modelID,
                  let receipt = $0.cliRouteReceipt else { return false }
            return receipt.isValid
                && receipt.providerID.lowercased() == providerID.lowercased()
                && receipt.modelID == modelID
                && receipt.observationID == $0.id
        }
    }
}

struct BuilderTrustedToolInvocation: Sendable {
    let id: String
    let toolName: String
    let argumentsDigest: String
    let seal: String

    static func make(toolName: String, argumentsDigest: String) -> Self {
        let id = "invoke-\(UUID().uuidString.lowercased())"
        let seal = ForgeSeal.sign(
            [id, toolName, argumentsDigest].joined(separator: "\u{0}"))
        return .init(id: id, toolName: toolName, argumentsDigest: argumentsDigest, seal: seal)
    }

    var isValid: Bool {
        !seal.isEmpty && ForgeSeal.verify(
            [id, toolName, argumentsDigest].joined(separator: "\u{0}"), seal: seal)
    }
}

enum BuilderTrustedToolInvocationScope {
    @TaskLocal static var current: BuilderTrustedToolInvocation?
}

struct BuilderTrustedCommandSink: @unchecked Sendable {
    let session: BuilderTrustedTelemetrySession
    let sessionID: String
    let invocation: BuilderTrustedToolInvocation
}

enum BuilderTrustedCommandInvocationAuthority {
    private static let lock = NSLock()
    private static var pending: [String: (String, String)] = [:]

    static func register(_ sink: BuilderTrustedCommandSink) -> Bool {
        guard sink.invocation.isValid, sink.invocation.toolName == "run_command" else { return false }
        lock.lock(); defer { lock.unlock() }
        guard pending[sink.invocation.id] == nil, pending.count < 100_000 else { return false }
        pending[sink.invocation.id] = (sink.sessionID, sink.invocation.seal)
        return true
    }

    static func consume(_ sink: BuilderTrustedCommandSink) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let expected = pending.removeValue(forKey: sink.invocation.id) else { return false }
        return expected.0 == sink.sessionID && expected.1 == sink.invocation.seal
    }
}

extension BuilderTrustedTelemetrySession {
    var commandSessionID: String { sessionID }
}

extension BuilderTrustedTelemetry {
    static func captureCommandSink() -> BuilderTrustedCommandSink? {
        guard let session, let invocation = BuilderTrustedToolInvocationScope.current else {
            return nil
        }
        let sink = BuilderTrustedCommandSink(
            session: session, sessionID: session.commandSessionID, invocation: invocation)
        return BuilderTrustedCommandInvocationAuthority.register(sink) ? sink : nil
    }

    static func commandEvidenceMatches(
        _ receipts: [BuilderCommandEvidenceReceipt],
        observations: [BuilderTrustedTelemetryObservation],
        contractFingerprint: String, subjectDigest: String,
        requireBuilderOSSandbox: Bool = false
    ) -> Bool {
        let commands = observations.filter { $0.kind == .command }
        guard !receipts.isEmpty, receipts.count == commands.count,
              Set(commands.map(\.id)).count == commands.count else { return false }
        let byID = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
        let references = receipts.compactMap(\.trustedCommandReference)
        guard references.count == receipts.count,
              Set(references.map(\.observationID)).count == references.count,
              Set(references.map(\.invocationID)).count == references.count,
              Set(references.map(\.observationID)) == Set(commands.map(\.id)) else {
            return false
        }
        return receipts.allSatisfy { receipt in
            guard let reference = receipt.trustedCommandReference,
                  let observation = byID[reference.observationID] else { return false }
            return receipt.isBound(
                contractFingerprint: contractFingerprint, subjectDigest: subjectDigest)
                && reference.isValid
                && (!requireBuilderOSSandbox || reference.isBuilderOSSandboxed)
                && receipt.argsFingerprint == reference.gateArgumentsDigest
                && observation.success && observation.exitCode == 0
                && receipt.exitCode == reference.exitCode
                && observation.commandReference == reference
                && observation.evidenceBindingDigest == reference.bindingDigest
                && observation.subjectDigest == reference.bindingDigest
        }
    }
}
