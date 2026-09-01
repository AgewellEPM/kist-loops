import Foundation

/// The exact side-by-side GhostBridge capability Kist may plan for.  This is
/// deliberately narrower than the generic SML plugin surface: no command,
/// coordinate, guest, carrier path, or fallback model crosses this contract.
public enum SMLGhostBridgeRelayContract {
    public static let capabilityID = "ghostbridge.relay.stage.advance.v1"
    public static let invocationSchema = "ghostbridge.sml.capability-invocation.v1"
    public static let peelReceiptSchema = "ghostbridge.peel-grounding-receipt.v1"
    public static let captainPlanSchema = "ghostbridge.captain-admitted-plan.v1"
    public static let learningProposalSchema =
        "kist.quarantined-capability-learning-proposal.v1"
    public static let claimChunkBytes = 1_024
    public static let maximumRequestBytes = 1_048_576
}

public struct SMLGhostBridgeModelIdentity: Codable, Hashable, Sendable {
    public let provider: String
    public let model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }
}

public struct SMLGhostBridgeRelayInvocation: Codable, Equatable, Sendable {
    public let schema: String
    public let capabilityId: String
    public let invocationId: String
    public let relayId: String
    public let expectedFrontierDigest: String
    public let expectedCarrierKey: String
    public let model: SMLGhostBridgeModelIdentity

    public init(
        schema: String = SMLGhostBridgeRelayContract.invocationSchema,
        capabilityId: String = SMLGhostBridgeRelayContract.capabilityID,
        invocationId: String,
        relayId: String,
        expectedFrontierDigest: String,
        expectedCarrierKey: String,
        model: SMLGhostBridgeModelIdentity
    ) {
        self.schema = schema
        self.capabilityId = capabilityId
        self.invocationId = invocationId
        self.relayId = relayId
        self.expectedFrontierDigest = expectedFrontierDigest
        self.expectedCarrierKey = expectedCarrierKey
        self.model = model
    }
}

/// Host-derived symbolic state.  It is intentionally not Codable, so a model
/// request cannot mint its own grounding context.
public struct SMLGhostBridgeRelayGroundingContext: Sendable {
    public let relayID: String
    public let frontierDigest: String
    public let carrierKey: String
    public let nextSystem: String?
    public let verifiedSystems: [String]
    public let runningSystem: String?
    public let guestProfile: String
    public let guestProfileSHA256: String
    public let guestDiskSHA256: String
    public let allowedModels: Set<SMLGhostBridgeModelIdentity>

    public init(
        relayID: String,
        frontierDigest: String,
        carrierKey: String,
        nextSystem: String?,
        verifiedSystems: [String],
        runningSystem: String?,
        guestProfile: String,
        guestProfileSHA256: String,
        guestDiskSHA256: String,
        allowedModels: Set<SMLGhostBridgeModelIdentity>
    ) {
        self.relayID = relayID
        self.frontierDigest = frontierDigest
        self.carrierKey = carrierKey
        self.nextSystem = nextSystem
        self.verifiedSystems = verifiedSystems
        self.runningSystem = runningSystem
        self.guestProfile = guestProfile
        self.guestProfileSHA256 = guestProfileSHA256
        self.guestDiskSHA256 = guestDiskSHA256
        self.allowedModels = allowedModels
    }
}

public struct SMLExactGroundingChunk: Codable, Equatable, Sendable {
    public let index: Int
    public let offset: Int
    public let byteCount: Int
    public let sha256: String
}

public struct SMLExactGroundingCoverage: Codable, Equatable, Sendable {
    public let canonicalByteCount: Int
    public let canonicalSHA256: String
    public let chunkBytes: Int
    public let chunks: [SMLExactGroundingChunk]
    public let claimPaths: [String]
    public let covered: Bool
    public let truncated: Bool
}

public struct SMLGhostBridgeRelayPEELReceipt: Codable, Equatable, Sendable {
    public let schema: String
    public let floor: String
    public let policy: String
    public let verdict: String
    public let effectAllowed: Bool
    public let narrativeOnly: Bool
    public let contradictions: [String]
    public let contractSHA256: String
    public let requestSHA256: String
    public let coverage: SMLExactGroundingCoverage
    public let similarityAuthority: Bool
    public let prefixTruncation: Bool
    public let environmentBypass: Bool
}

public struct SMLGhostBridgeRelayAssessment: Sendable {
    public let invocation: SMLGhostBridgeRelayInvocation
    public let receipt: SMLGhostBridgeRelayPEELReceipt
}

public enum SMLGhostBridgeRelayGovernanceError: Error, Equatable, Sendable,
    CustomStringConvertible {
    case malformedInvocation
    case nonCanonicalInvocation
    case invalidInvocationIdentity
    case groundingContradiction([String])
    case invalidLearningProposal

    public var description: String {
        switch self {
        case .malformedInvocation:
            return "GhostBridge relay invocation is malformed"
        case .nonCanonicalInvocation:
            return "GhostBridge relay invocation is not strict canonical JSON"
        case .invalidInvocationIdentity:
            return "GhostBridge relay invocation identity is invalid"
        case .groundingContradiction(let fields):
            return "mandatory PEEL floor found contradictions: "
                + fields.joined(separator: ",")
        case .invalidLearningProposal:
            return "qualification learning proposal is not strict quarantine-only evidence"
        }
    }
}

/// Opaque proof that the entire canonical invocation crossed the exact PEEL
/// floor.  Only this type can enter the Captain compiler below.
public struct SMLAdmittedGhostBridgeRelayInvocation: Sendable {
    let invocation: SMLGhostBridgeRelayInvocation
    let peel: SMLGhostBridgeRelayPEELReceipt

    public var invocationID: String { invocation.invocationId }
    public var requestSHA256: String { peel.requestSHA256 }
}

public enum SMLGhostBridgeRelayPEEL {
    private static let requestKeys: Set<String> = [
        "schema", "capabilityId", "invocationId", "relayId",
        "expectedFrontierDigest", "expectedCarrierKey", "model",
    ]
    private static let modelKeys: Set<String> = ["provider", "model"]

    public static func assess(
        canonicalRequest: Data,
        context: SMLGhostBridgeRelayGroundingContext
    ) throws -> SMLGhostBridgeRelayAssessment {
        guard !canonicalRequest.isEmpty,
              canonicalRequest.count <= SMLGhostBridgeRelayContract.maximumRequestBytes,
              let text = String(data: canonicalRequest, encoding: .utf8),
              let canonical = JSONCanonicalizer.canonical(text) else {
            throw SMLGhostBridgeRelayGovernanceError.malformedInvocation
        }
        guard canonical.data(using: .utf8) == canonicalRequest else {
            throw SMLGhostBridgeRelayGovernanceError.nonCanonicalInvocation
        }
        guard let object = try? JSONSerialization.jsonObject(with: canonicalRequest),
              let root = object as? [String: Any],
              Set(root.keys) == requestKeys,
              let modelObject = root["model"] as? [String: Any],
              Set(modelObject.keys) == modelKeys,
              let invocation = try? JSONDecoder().decode(
                SMLGhostBridgeRelayInvocation.self, from: canonicalRequest
              ),
              validIdentifier(invocation.invocationId, minimum: 8, maximum: 128),
              validIdentifier(invocation.relayId, minimum: 8, maximum: 128),
              validProvider(invocation.model.provider),
              validModel(invocation.model.model),
              isSHA256(invocation.expectedFrontierDigest),
              isSHA256(invocation.expectedCarrierKey),
              invocation.schema == SMLGhostBridgeRelayContract.invocationSchema,
              invocation.capabilityId == SMLGhostBridgeRelayContract.capabilityID else {
            throw SMLGhostBridgeRelayGovernanceError.invalidInvocationIdentity
        }

        var contradictions: [String] = []
        if invocation.relayId != context.relayID { contradictions.append("relayId") }
        if invocation.expectedFrontierDigest != context.frontierDigest {
            contradictions.append("expectedFrontierDigest")
        }
        if invocation.expectedCarrierKey != context.carrierKey {
            contradictions.append("expectedCarrierKey")
        }
        if !context.allowedModels.contains(invocation.model) {
            contradictions.append("model")
        }
        if context.nextSystem != "windows95" || !context.verifiedSystems.isEmpty {
            contradictions.append("routeHead")
        }
        if context.runningSystem != nil { contradictions.append("concurrentOrUnreconciledStage") }
        if context.guestProfile != "legacy-i386"
            || !isSHA256(context.guestProfileSHA256)
            || !isSHA256(context.guestDiskSHA256) {
            contradictions.append("guestProfile")
        }

        let contract: [String: Any] = [
            "capabilityId": SMLGhostBridgeRelayContract.capabilityID,
            "cleanupRequired": true,
            "effect": "reversible_external",
            "guestDiskSHA256": context.guestDiskSHA256,
            "guestProfile": context.guestProfile,
            "guestProfileSHA256": context.guestProfileSHA256,
            "modelFallbackAllowed": false,
            "modelMayChooseCommands": false,
            "network": "none",
            "routeIndex": 0,
            "systemId": "windows95",
        ]
        guard let contractData = canonicalData(contract) else {
            throw SMLGhostBridgeRelayGovernanceError.malformedInvocation
        }
        let coverage = exactCoverage(canonicalRequest, object: root)
        let allowed = contradictions.isEmpty && coverage.covered && !coverage.truncated
        let receipt = SMLGhostBridgeRelayPEELReceipt(
            schema: SMLGhostBridgeRelayContract.peelReceiptSchema,
            floor: "mandatory",
            policy: "exact-symbolic-contract-v1",
            verdict: allowed ? "positive-consistent" : "contradiction",
            effectAllowed: allowed,
            narrativeOnly: !allowed,
            contradictions: contradictions,
            contractSHA256: hex(MythosCrypto.sha256(contractData)),
            requestSHA256: hex(MythosCrypto.sha256(canonicalRequest)),
            coverage: coverage,
            similarityAuthority: false,
            prefixTruncation: false,
            environmentBypass: false
        )
        return SMLGhostBridgeRelayAssessment(invocation: invocation, receipt: receipt)
    }

    public static func admit(
        canonicalRequest: Data,
        context: SMLGhostBridgeRelayGroundingContext
    ) throws -> SMLAdmittedGhostBridgeRelayInvocation {
        let assessment = try assess(canonicalRequest: canonicalRequest, context: context)
        guard assessment.receipt.effectAllowed,
              assessment.receipt.verdict == "positive-consistent",
              assessment.receipt.floor == "mandatory" else {
            throw SMLGhostBridgeRelayGovernanceError.groundingContradiction(
                assessment.receipt.contradictions
            )
        }
        return SMLAdmittedGhostBridgeRelayInvocation(
            invocation: assessment.invocation,
            peel: assessment.receipt
        )
    }

    private static func exactCoverage(
        _ bytes: Data, object: [String: Any]
    ) -> SMLExactGroundingCoverage {
        var chunks: [SMLExactGroundingChunk] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + SMLGhostBridgeRelayContract.claimChunkBytes)
            let chunk = bytes.subdata(in: offset..<end)
            chunks.append(SMLExactGroundingChunk(
                index: chunks.count,
                offset: offset,
                byteCount: chunk.count,
                sha256: hex(MythosCrypto.sha256(chunk))
            ))
            offset = end
        }
        var paths: [String] = []
        collectClaimPaths(object, path: "$", into: &paths)
        return SMLExactGroundingCoverage(
            canonicalByteCount: bytes.count,
            canonicalSHA256: hex(MythosCrypto.sha256(bytes)),
            chunkBytes: SMLGhostBridgeRelayContract.claimChunkBytes,
            chunks: chunks,
            claimPaths: paths,
            covered: chunks.reduce(0) { $0 + $1.byteCount } == bytes.count,
            truncated: false
        )
    }

    private static func collectClaimPaths(
        _ value: Any, path: String, into paths: inout [String]
    ) {
        paths.append(path)
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() {
                let escaped = key.replacingOccurrences(of: "~", with: "~0")
                    .replacingOccurrences(of: "/", with: "~1")
                if let child = object[key] {
                    collectClaimPaths(child, path: "\(path)/\(escaped)", into: &paths)
                }
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                collectClaimPaths(child, path: "\(path)/\(index)", into: &paths)
            }
        }
    }

    fileprivate static func canonicalData(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value),
              let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8),
              let canonical = JSONCanonicalizer.canonical(text) else { return nil }
        return canonical.data(using: .utf8)
    }

    fileprivate static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }
    }

    private static func validIdentifier(_ value: String, minimum: Int, maximum: Int) -> Bool {
        guard (minimum...maximum).contains(value.count),
              let first = value.first, first.isASCII,
              first.isLetter || first.isNumber else { return false }
        return value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))
        }
    }

    private static func validProvider(_ value: String) -> Bool {
        guard (1...64).contains(value.count), value == value.lowercased() else { return false }
        return validIdentifier(value, minimum: 1, maximum: 64)
    }

    private static func validModel(_ value: String) -> Bool {
        guard (1...128).contains(value.count), let first = value.first,
              first.isASCII, first.isLetter || first.isNumber else { return false }
        return value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "._:/-".contains($0))
        }
    }
}

public struct SMLGhostBridgeRelayCaptainPlan: Codable, Equatable, Sendable {
    public let schema: String
    public let decision: String
    public let invocationID: String
    public let requestSHA256: String
    public let systemID: String
    public let routeIndex: Int
    public let driverID: String
    public let maximumNewStages: Int
    public let routeFinalizationAllowed: Bool
    public let network: String
    public let cleanupProofRequired: Bool
    public let modelFallbackAllowed: Bool
    public let directLegacyMCPMutationAllowed: Bool
}

public enum SMLGhostBridgeRelayCaptain {
    public static func plan(
        _ admitted: SMLAdmittedGhostBridgeRelayInvocation
    ) -> SMLGhostBridgeRelayCaptainPlan {
        SMLGhostBridgeRelayCaptainPlan(
            schema: SMLGhostBridgeRelayContract.captainPlanSchema,
            decision: "admit-one-fixed-instruction",
            invocationID: admitted.invocation.invocationId,
            requestSHA256: admitted.peel.requestSHA256,
            systemID: "windows95",
            routeIndex: 0,
            driverID: "ghostbridge.enterprise-win95-relay-driver.v1",
            maximumNewStages: 1,
            routeFinalizationAllowed: false,
            network: "none",
            cleanupProofRequired: true,
            modelFallbackAllowed: false,
            directLegacyMCPMutationAllowed: false
        )
    }
}

public struct SMLGhostBridgeQualificationLearningProposal: Codable, Equatable, Sendable {
    public let schema: String
    public let state: String
    public let authority: String
    public let invocationId: String
    public let capabilityId: String
    public let outcome: String
    public let evidenceSHA256: String?
    public let failure: String?
    public let mutationAllowed: Bool
    public let autoPromoted: Bool
    public let productionEligible: Bool
    public let requiresHeldOutHostOwnedEvaluation: Bool
    public let recordedUnixNS: Int64
}

/// Opaque, read-only projection.  It has no conversion to
/// `CaptainLearningSample`, `Lesson`, promotion evidence, or an SML command.
public struct SMLQuarantinedGhostBridgeLearning: Sendable {
    public let proposal: SMLGhostBridgeQualificationLearningProposal
    public let proposalSHA256: String
    public var isExecutionAuthority: Bool { false }
    public var isPromotionAuthority: Bool { false }
}

public enum SMLGhostBridgeQualificationLearningGate {
    private static let exactKeys: Set<String> = [
        "schema", "state", "authority", "invocationId", "capabilityId", "outcome",
        "evidenceSHA256", "failure", "mutationAllowed", "autoPromoted",
        "productionEligible", "requiresHeldOutHostOwnedEvaluation", "recordedUnixNS",
    ]

    public static func quarantine(
        canonicalJSONLine: Data
    ) throws -> SMLQuarantinedGhostBridgeLearning {
        guard !canonicalJSONLine.isEmpty,
              canonicalJSONLine.count <= SMLGhostBridgeRelayContract.maximumRequestBytes else {
            throw SMLGhostBridgeRelayGovernanceError.invalidLearningProposal
        }
        let body: Data
        if canonicalJSONLine.last == 0x0A {
            body = canonicalJSONLine.dropLast()
            guard !body.isEmpty, !body.contains(0x0A), !body.contains(0x0D) else {
                throw SMLGhostBridgeRelayGovernanceError.invalidLearningProposal
            }
        } else {
            body = canonicalJSONLine
        }
        guard let text = String(data: body, encoding: .utf8),
              let canonical = JSONCanonicalizer.canonical(text),
              canonical.data(using: .utf8) == body,
              let raw = try? JSONSerialization.jsonObject(with: body),
              let object = raw as? [String: Any],
              Set(object.keys) == exactKeys,
              let proposal = try? JSONDecoder().decode(
                SMLGhostBridgeQualificationLearningProposal.self, from: body
              ),
              proposal.schema == SMLGhostBridgeRelayContract.learningProposalSchema,
              proposal.state == "quarantined",
              proposal.authority == "advisory-only",
              proposal.capabilityId == SMLGhostBridgeRelayContract.capabilityID,
              ["verified", "failed", "blocked"].contains(proposal.outcome),
              proposal.mutationAllowed == false,
              proposal.autoPromoted == false,
              proposal.productionEligible == false,
              proposal.requiresHeldOutHostOwnedEvaluation == true,
              proposal.recordedUnixNS > 0,
              (proposal.evidenceSHA256 == nil
                || SMLGhostBridgeRelayPEEL.isSHA256(proposal.evidenceSHA256!)),
              proposal.outcome != "verified" || proposal.evidenceSHA256 != nil else {
            throw SMLGhostBridgeRelayGovernanceError.invalidLearningProposal
        }
        return SMLQuarantinedGhostBridgeLearning(
            proposal: proposal,
            proposalSHA256: SMLGhostBridgeRelayPEEL.hex(MythosCrypto.sha256(body))
        )
    }
}
