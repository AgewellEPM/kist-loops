import Foundation

/// A host-minted, one-shot capability that upgrades one exact frozen Builder command from generic
/// shell heuristics to deterministic build/test evidence. It never appears in tool metadata or model
/// output. The seal binds the active Builder node attempt, exact executable/argv/cwd, the trusted
/// process observation, clean exit, and the immutable ToolResult payload.
struct BuilderVerificationCommandAuthorityReceipt: Codable, Sendable, Equatable {
    let id: String
    let contractFingerprint: String
    let nodeID: String
    let attempt: Int
    let stage: BuilderExecutionStage
    let commandDigest: String
    let gatedArgumentsDigest: String
    let commandObservationID: String
    let commandObservationDigest: String
    let resultDigest: String
    let exitCode: Int
    let bindingDigest: String
    let seal: String

    private struct Payload: Codable {
        let id: String
        let contractFingerprint: String
        let nodeID: String
        let attempt: Int
        let stage: BuilderExecutionStage
        let commandDigest: String
        let gatedArgumentsDigest: String
        let commandObservationID: String
        let commandObservationDigest: String
        let resultDigest: String
        let exitCode: Int
    }

    private var payload: Payload {
        .init(id: id, contractFingerprint: contractFingerprint, nodeID: nodeID,
              attempt: attempt, stage: stage, commandDigest: commandDigest,
              gatedArgumentsDigest: gatedArgumentsDigest,
              commandObservationID: commandObservationID,
              commandObservationDigest: commandObservationDigest,
              resultDigest: resultDigest, exitCode: exitCode)
    }

    fileprivate init(binding: BuilderTrustedTelemetryBinding, commandDigest: String,
                     gatedArgumentsDigest: String, reference: BuilderTrustedCommandReference,
                     resultDigest: String) throws {
        let payload = Payload(
            id: try BuilderExecutionValidation.identifier(
                "verify-command-\(UUID().uuidString.lowercased())",
                field: "verification command authority"),
            contractFingerprint: binding.contractFingerprint,
            nodeID: binding.nodeID, attempt: binding.attempt, stage: binding.stage,
            commandDigest: try BuilderExecutionValidation.digest(
                commandDigest, field: "verification command"),
            gatedArgumentsDigest: try BuilderExecutionValidation.digest(
                gatedArgumentsDigest, field: "verification gated arguments"),
            commandObservationID: try BuilderExecutionValidation.identifier(
                reference.observationID, field: "verification command observation"),
            commandObservationDigest: try BuilderExecutionValidation.digest(
                reference.bindingDigest, field: "verification command observation digest"),
            resultDigest: try BuilderExecutionValidation.digest(
                resultDigest, field: "verification command result"),
            exitCode: reference.exitCode)
        let canonical = String(
            decoding: try BuilderDurableIO.canonicalData(payload), as: UTF8.self)
        let bindingDigest = BuilderEvidenceDigest.sha256(
            "kist.builder.verification-command-authority.v1\u{0}" + canonical)
        let seal = ForgeSeal.sign(bindingDigest)
        guard !seal.isEmpty else { throw BuilderBudgetLedgerError.tampered }
        self.id = payload.id
        self.contractFingerprint = payload.contractFingerprint
        self.nodeID = payload.nodeID; self.attempt = payload.attempt; self.stage = payload.stage
        self.commandDigest = payload.commandDigest
        self.gatedArgumentsDigest = payload.gatedArgumentsDigest
        self.commandObservationID = payload.commandObservationID
        self.commandObservationDigest = payload.commandObservationDigest
        self.resultDigest = payload.resultDigest; self.exitCode = payload.exitCode
        self.bindingDigest = bindingDigest; self.seal = seal
    }

    var isCryptographicallyValid: Bool {
        guard attempt > 0, exitCode == 0,
              let canonical = try? BuilderDurableIO.canonicalData(payload) else { return false }
        let expected = BuilderEvidenceDigest.sha256(
            "kist.builder.verification-command-authority.v1\u{0}"
                + String(decoding: canonical, as: UTF8.self))
        return expected == bindingDigest && ForgeSeal.verify(bindingDigest, seal: seal)
    }
}

private enum BuilderVerificationCommandAuthorityStore {
    private static let lock = NSLock()
    private static var pending: [String: (String, String)] = [:]

    static func register(_ receipt: BuilderVerificationCommandAuthorityReceipt) -> Bool {
        guard receipt.isCryptographicallyValid else { return false }
        lock.lock(); defer { lock.unlock() }
        guard pending[receipt.id] == nil, pending.count < 100_000 else { return false }
        pending[receipt.id] = (receipt.bindingDigest, receipt.seal)
        return true
    }

    static func consume(_ receipt: BuilderVerificationCommandAuthorityReceipt) -> Bool {
        guard receipt.isCryptographicallyValid else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let expected = pending[receipt.id],
              expected.0 == receipt.bindingDigest, expected.1 == receipt.seal else { return false }
        pending.removeValue(forKey: receipt.id)
        return true
    }
}

enum BuilderVerificationCommandAuthority {
    private struct CommandPayload: Codable {
        let executable: String
        let arguments: [String]
        let workingDirectory: String
    }

    private struct ResultPayload: Codable {
        let success: Bool
        let outputDigest: String
        let errorDigest: String?
        let metadata: [String: String]
        let commandObservationDigest: String
    }

    private static func commandDigest(_ arguments: [String: Any]) -> String? {
        guard arguments["command"] == nil,
              let executable = arguments["executable"] as? String, !executable.isEmpty,
              arguments["args"] == nil || arguments["args"] is [String],
              arguments["cwd"] == nil || arguments["cwd"] is String else { return nil }
        let payload = CommandPayload(
            executable: executable,
            arguments: arguments["args"] as? [String] ?? [],
            workingDirectory: arguments["cwd"] as? String ?? ".")
        guard let canonical = try? BuilderDurableIO.canonicalData(payload) else { return nil }
        return BuilderEvidenceDigest.sha256(
            "kist.builder.verification-command.v1\u{0}"
                + String(decoding: canonical, as: UTF8.self))
    }

    private static func resultDigest(_ result: ToolResult,
                                     reference: BuilderTrustedCommandReference) -> String? {
        let payload = ResultPayload(
            success: result.success,
            outputDigest: BuilderEvidenceDigest.sha256(result.output),
            errorDigest: result.error.map(BuilderEvidenceDigest.sha256),
            metadata: result.metadata,
            commandObservationDigest: reference.bindingDigest)
        guard let canonical = try? BuilderDurableIO.canonicalData(payload) else { return nil }
        return BuilderEvidenceDigest.sha256(
            "kist.builder.verification-command-result.v1\u{0}"
                + String(decoding: canonical, as: UTF8.self))
    }

    static func mint(arguments: [String: Any], result: ToolResult)
        -> BuilderVerificationCommandAuthorityReceipt? {
        guard let binding = BuilderTrustedTelemetry.session?.binding,
              result.success,
              result.metadata["verification_eligible"] == "true",
              let reference = result.trustedCommandReference,
              reference.isValid, reference.exitCode == 0,
              !reference.timedOut, !reference.wasSignalled,
              let commandDigest = commandDigest(arguments),
              AuditLog.digest(arguments).1 == reference.gateArgumentsDigest,
              let resultDigest = resultDigest(result, reference: reference),
              let receipt = try? BuilderVerificationCommandAuthorityReceipt(
                binding: binding, commandDigest: commandDigest,
                gatedArgumentsDigest: reference.gateArgumentsDigest,
                reference: reference, resultDigest: resultDigest),
              BuilderVerificationCommandAuthorityStore.register(receipt) else { return nil }
        return receipt
    }

    static func consume(arguments: [String: Any], result: ToolResult) -> Bool {
        guard let receipt = result.trustedBuilderVerification,
              let binding = BuilderTrustedTelemetry.session?.binding,
              receipt.contractFingerprint == binding.contractFingerprint,
              receipt.nodeID == binding.nodeID,
              receipt.attempt == binding.attempt,
              receipt.stage == binding.stage,
              result.success,
              result.metadata["verification_eligible"] == "true",
              let reference = result.trustedCommandReference,
              reference.isValid, reference.exitCode == 0,
              !reference.timedOut, !reference.wasSignalled,
              receipt.gatedArgumentsDigest == reference.gateArgumentsDigest,
              receipt.commandObservationID == reference.observationID,
              receipt.commandObservationDigest == reference.bindingDigest,
              receipt.commandDigest == commandDigest(arguments),
              receipt.resultDigest == resultDigest(result, reference: reference) else { return false }
        return BuilderVerificationCommandAuthorityStore.consume(receipt)
    }
}

public extension ToolResult {
    /// Called only by a host-owned wrapper after exact matching against a frozen Builder preflight
    /// command. Outside an active Builder telemetry scope, or without a real sealed process result,
    /// this returns the result unchanged and grants no authority.
    func authorizingBuilderContractVerification(arguments: [String: Any]) -> ToolResult {
        guard let receipt = BuilderVerificationCommandAuthority.mint(
            arguments: arguments, result: self) else { return self }
        return ToolResult(
            success: success, output: output, error: error, metadata: metadata,
            trustedCommandReference: trustedCommandReference,
            trustedBuilderVerification: receipt)
    }
}
