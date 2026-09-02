import Crypto
import Foundation

/// Approve-everything policy for durable SML hosts, optionally relaxed per capability from
/// `<projectRoot>/.kist/sml/policy.json`. A missing file IS the locked default: every externally
/// advanced instruction gets a human gate. Relaxation is explicit, per-entry, and human-edited —
/// there is no code path that widens execution without a policy file saying so.
public struct SMLApprovalPolicy: Sendable, Equatable {
    public enum Mode: String, Sendable, Codable, Equatable {
        /// Every externally advanced instruction is gated. The shipped default.
        case approveAlways = "approve_always"
        /// Read-only observation/retrieval run ungated; everything else is gated.
        case approveSideEffects = "approve_side_effects"
        /// No gate for this entry. The catalog admission gate still applies.
        case freeRun = "free_run"
    }

    public static let schemaVersion = 1
    public static let relativePath = ".kist/sml/policy.json"
    /// The gate owner used when no policy file names one. Durable hosts must list this owner in
    /// `catalog.json` `approval_authorities` or gated workflows fail admission — loudly, which is
    /// the correct failure for an unconfigured approval chain.
    public static let defaultApprovalOwner = "host-operator"

    public let defaultMode: Mode
    /// Keyed by "<OP>:<reference>", e.g. "CALL_TOOL:read_file" or "RETRIEVE:project-notes".
    public let overrides: [String: Mode]
    public let approvalOwner: String

    public init(
        defaultMode: Mode = .approveAlways,
        overrides: [String: Mode] = [:],
        approvalOwner: String = SMLApprovalPolicy.defaultApprovalOwner
    ) {
        self.defaultMode = defaultMode
        self.overrides = overrides
        self.approvalOwner = approvalOwner
    }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case unreadable(path: String, reason: String)
        case malformed(path: String, reason: String)
        case unsupportedSchemaVersion(Int)
        case invalidOwner(String)
        case invalidOverrideKey(String)

        public var description: String {
            switch self {
            case .unreadable(let path, let reason):
                return "SML approval policy is unreadable: \(path) (\(reason))"
            case .malformed(let path, let reason):
                return "SML approval policy is malformed: \(path) (\(reason))"
            case .unsupportedSchemaVersion(let version):
                return "SML approval policy schema_version \(version) is unsupported "
                    + "(expected \(schemaVersion))"
            case .invalidOwner(let owner):
                return "SML approval policy approval_owner is not a valid identifier: '\(owner)'"
            case .invalidOverrideKey(let key):
                return "SML approval policy override key must be '<OP>:<reference>' with a known "
                    + "instruction operation: '\(key)'"
            }
        }
    }

    private struct FileFormat: Decodable {
        let schemaVersion: Int
        let defaultMode: Mode?
        let overrides: [String: Mode]?
        let approvalOwner: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case defaultMode = "default"
            case overrides
            case approvalOwner = "approval_owner"
        }
    }

    public static func defaultURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
    }

    /// Loads the policy, treating an ABSENT file as the locked approve-everything default.
    /// A present-but-broken file fails closed instead of silently reverting to defaults, so a
    /// typo can never silently change gating.
    public static func load(projectRoot: String) throws -> SMLApprovalPolicy {
        let url = defaultURL(projectRoot: projectRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SMLApprovalPolicy()
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(path: url.path, reason: String(describing: error))
        }
        let decoded: FileFormat
        do {
            decoded = try JSONDecoder().decode(FileFormat.self, from: data)
        } catch {
            throw LoadError.malformed(path: url.path, reason: String(describing: error))
        }
        guard decoded.schemaVersion == schemaVersion else {
            throw LoadError.unsupportedSchemaVersion(decoded.schemaVersion)
        }
        let owner = decoded.approvalOwner ?? defaultApprovalOwner
        guard SMLValidationSupport.identifierIsValid(owner) else {
            throw LoadError.invalidOwner(owner)
        }
        for key in (decoded.overrides ?? [:]).keys {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  SMLInstructionOperation(rawValue: String(parts[0])) != nil,
                  !parts[1].isEmpty else {
                throw LoadError.invalidOverrideKey(key)
            }
        }
        return SMLApprovalPolicy(
            defaultMode: decoded.defaultMode ?? .approveAlways,
            overrides: decoded.overrides ?? [:],
            approvalOwner: owner
        )
    }

    /// The mode governing one instruction: exact "<OP>:<reference>" override, else the default.
    public func mode(for instruction: SMLInstruction) -> Mode {
        if let reference = SMLWorkflowApprovalGating.capabilityReference(of: instruction),
           let override = overrides["\(instruction.op.rawValue):\(reference)"] {
            return override
        }
        return defaultMode
    }

    /// Stable 8-hex digest over the policy's effective content. Suffixed into gated workflow
    /// versions so a policy change yields a DIFFERENT admitted workflow version — running tasks
    /// stay pinned to the graph (and gates) they started with; relaxation is never silent.
    public var stableHash: String {
        var canonical = "v\(Self.schemaVersion)|default=\(defaultMode.rawValue)|owner=\(approvalOwner)"
        for key in overrides.keys.sorted() {
            canonical += "|\(key)=\(overrides[key]!.rawValue)"
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).lowercased()
    }
}

/// Deterministic IR→IR transform injecting a `WAIT_APPROVAL` gate ahead of every externally
/// advanced instruction the policy says to gate. Runs BEFORE validation so the DAG/terminal-path
/// proofs hold for the GATED graph. Refusal paths terminate in an injected `ESCALATE` — a refused
/// step is a visible, human-owned terminal state, never a validator dead-end.
public enum SMLWorkflowApprovalGating {
    /// The instruction set the runtime advances via external capability dispatch — exactly the
    /// operations a human must approve under approve-everything (mirrors the runtime's park set
    /// plus verify/commit, which are externally evidenced).
    public static let externallyAdvancedOperations: Set<SMLInstructionOperation> = [
        .observe, .retrieve, .callTool, .callModel, .invokeVCard,
        .runPlugin, .runWorkflow, .verify, .commit,
    ]

    /// Read-only operations `approve_side_effects` lets through ungated.
    public static let readOnlyOperations: Set<SMLInstructionOperation> = [.observe, .retrieve]

    public enum GatingError: Error, Equatable, CustomStringConvertible {
        case gateIdentifierCollision(String)

        public var description: String {
            switch self {
            case .gateIdentifierCollision(let id):
                return "approval gating cannot inject '\(id)': the workflow already declares that "
                    + "instruction id — rename it, the gate-/-refused namespace is reserved"
            }
        }
    }

    /// The admission-relevant reference of an instruction (what the human is approving).
    static func capabilityReference(of instruction: SMLInstruction) -> String? {
        switch instruction.op {
        case .observe, .retrieve: return instruction.source
        case .callTool, .invokeVCard: return instruction.capability
        case .callModel: return instruction.purpose
        case .runWorkflow: return instruction.workflow
        case .verify, .commit: return instruction.verifier
        case .runPlugin: return instruction.plugin?.id
        default: return nil
        }
    }

    private static func shouldGate(_ instruction: SMLInstruction, policy: SMLApprovalPolicy) -> Bool {
        guard externallyAdvancedOperations.contains(instruction.op) else { return false }
        switch policy.mode(for: instruction) {
        case .approveAlways: return true
        case .approveSideEffects: return !readOnlyOperations.contains(instruction.op)
        case .freeRun: return false
        }
    }

    public static func gateID(for instructionID: String) -> String { "gate-\(instructionID)" }
    public static func refusalID(for instructionID: String) -> String { "gate-\(instructionID)-refused" }

    /// Injects approval gates per policy and returns the gated workflow, its version suffixed
    /// with the effective-policy hash. Deterministic (same input + policy → identical output) and
    /// idempotent (author-supplied gates are respected; gating a gated workflow changes nothing).
    public static func gate(
        _ workflow: SMLWorkflow,
        policy: SMLApprovalPolicy = SMLApprovalPolicy()
    ) throws -> SMLWorkflow {
        let existingIDs = Set(workflow.instructions.map(\.id))

        // An instruction whose EVERY inbound edge is already the approve-path of a WAIT_APPROVAL
        // (and which is not the raw entrypoint) is author-gated: injecting again would double-gate.
        var inboundNonGateEdges: [String: Int] = [:]
        var inboundGateEdges: [String: Int] = [:]
        func countEdge(_ target: String?, fromApproveNext: Bool) {
            guard let target else { return }
            if fromApproveNext {
                inboundGateEdges[target, default: 0] += 1
            } else {
                inboundNonGateEdges[target, default: 0] += 1
            }
        }
        countEdge(workflow.entrypoint, fromApproveNext: false)
        for instruction in workflow.instructions {
            let isApproval = instruction.op == .waitApproval
            countEdge(instruction.next, fromApproveNext: isApproval)
            countEdge(instruction.onPass, fromApproveNext: false)
            countEdge(instruction.onFailure, fromApproveNext: false)
            countEdge(instruction.trueTarget, fromApproveNext: false)
            countEdge(instruction.falseTarget, fromApproveNext: false)
            countEdge(instruction.retryPolicy?.target, fromApproveNext: false)
        }

        var gatedIDs: [String] = []
        for instruction in workflow.instructions where shouldGate(instruction, policy: policy) {
            let authorGated = inboundNonGateEdges[instruction.id, default: 0] == 0
                && inboundGateEdges[instruction.id, default: 0] > 0
            if authorGated { continue }
            gatedIDs.append(instruction.id)
        }
        guard !gatedIDs.isEmpty else { return workflow }

        for id in gatedIDs {
            for injected in [gateID(for: id), refusalID(for: id)]
            where existingIDs.contains(injected) {
                throw GatingError.gateIdentifierCollision(injected)
            }
        }
        let gatedSet = Set(gatedIDs)

        func redirect(_ target: String?) -> String? {
            guard let target, gatedSet.contains(target) else { return target }
            return gateID(for: target)
        }

        var rewritten: [SMLInstruction] = []
        var referenceByID: [String: String] = [:]
        for instruction in workflow.instructions {
            referenceByID[instruction.id] = capabilityReference(of: instruction)
            rewritten.append(SMLInstruction(
                id: instruction.id,
                op: instruction.op,
                source: instruction.source,
                purpose: instruction.purpose,
                capability: instruction.capability,
                workflow: instruction.workflow,
                verifier: instruction.verifier,
                outputSchema: instruction.outputSchema,
                reason: instruction.reason,
                owner: instruction.owner,
                arguments: instruction.arguments,
                scope: instruction.scope,
                expectedState: instruction.expectedState,
                condition: instruction.condition,
                plugin: instruction.plugin,
                retryPolicy: instruction.retryPolicy.map {
                    SMLRetryPolicy(
                        target: redirect($0.target) ?? $0.target,
                        maximumAttempts: $0.maximumAttempts,
                        backoffSeconds: $0.backoffSeconds
                    )
                },
                receiptFields: instruction.receiptFields,
                next: redirect(instruction.next),
                onPass: redirect(instruction.onPass),
                onFailure: redirect(instruction.onFailure),
                trueTarget: redirect(instruction.trueTarget),
                falseTarget: redirect(instruction.falseTarget)
            ))
        }

        for id in gatedIDs {
            let opName = workflow.instructions.first(where: { $0.id == id })?.op.rawValue ?? "step"
            let reference = referenceByID[id].map { " \($0)" } ?? ""
            rewritten.append(SMLInstruction(
                id: gateID(for: id),
                op: .waitApproval,
                reason: "Approve \(opName)\(reference) (instruction '\(id)')",
                owner: policy.approvalOwner,
                next: id,
                onFailure: refusalID(for: id)
            ))
            rewritten.append(SMLInstruction(
                id: refusalID(for: id),
                op: .escalate,
                reason: "Refused: \(opName)\(reference) (instruction '\(id)') was not approved",
                owner: policy.approvalOwner
            ))
        }

        return SMLWorkflow(
            irVersion: workflow.irVersion,
            id: workflow.id,
            version: policyStampedVersion(workflow.version, policy: policy),
            name: workflow.name,
            source: workflow.source,
            trigger: workflow.trigger,
            stateSchema: workflow.stateSchema,
            interface: workflow.interface,
            entrypoint: redirect(workflow.entrypoint) ?? workflow.entrypoint,
            instructions: rewritten
        )
    }

    /// Suffixes the effective-policy hash as semver build metadata, replacing any prior gating
    /// stamp (re-gating under a new policy re-stamps; it never accumulates suffixes).
    static func policyStampedVersion(_ version: String, policy: SMLApprovalPolicy) -> String {
        let stamp = "g\(policy.stableHash)"
        guard let plusIndex = version.firstIndex(of: "+") else {
            return "\(version)+\(stamp)"
        }
        let base = String(version[..<plusIndex])
        let metadata = String(version[version.index(after: plusIndex)...])
        let kept = metadata.split(separator: ".").filter { !$0.hasPrefix("g") }
        let parts = kept.map(String.init) + [stamp]
        return "\(base)+\(parts.joined(separator: "."))"
    }
}
