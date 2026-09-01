import XCTest
@testable import AgentCore

final class SMLGhostBridgeRelayGovernanceTests: XCTestCase {
    private let relayID = "invoice-glue-universal-live-001"
    private let frontierDigest = String(repeating: "a", count: 64)
    private let carrierKey = String(repeating: "b", count: 64)
    private let model = SMLGhostBridgeModelIdentity(provider: "openai", model: "gpt-5.5")

    private func context(
        frontier: String? = nil,
        nextSystem: String? = "windows95",
        verified: [String] = [],
        running: String? = nil
    ) -> SMLGhostBridgeRelayGroundingContext {
        SMLGhostBridgeRelayGroundingContext(
            relayID: relayID,
            frontierDigest: frontier ?? frontierDigest,
            carrierKey: carrierKey,
            nextSystem: nextSystem,
            verifiedSystems: verified,
            runningSystem: running,
            guestProfile: "legacy-i386",
            guestProfileSHA256: String(repeating: "c", count: 64),
            guestDiskSHA256: String(repeating: "d", count: 64),
            allowedModels: [model]
        )
    }

    private func invocationData(extra: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = [
            "schema": SMLGhostBridgeRelayContract.invocationSchema,
            "capabilityId": SMLGhostBridgeRelayContract.capabilityID,
            "invocationId": "qualification-proof-0001",
            "relayId": relayID,
            "expectedFrontierDigest": frontierDigest,
            "expectedCarrierKey": carrierKey,
            "model": ["provider": model.provider, "model": model.model],
        ]
        extra.forEach { value[$0.key] = $0.value }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    func testMandatoryPEELCoversEveryCanonicalByteAndClaim() throws {
        let data = try invocationData()

        let assessment = try SMLGhostBridgeRelayPEEL.assess(
            canonicalRequest: data,
            context: context()
        )

        XCTAssertTrue(assessment.receipt.effectAllowed)
        XCTAssertEqual(assessment.receipt.floor, "mandatory")
        XCTAssertEqual(assessment.receipt.policy, "exact-symbolic-contract-v1")
        XCTAssertEqual(assessment.receipt.verdict, "positive-consistent")
        XCTAssertFalse(assessment.receipt.similarityAuthority)
        XCTAssertFalse(assessment.receipt.prefixTruncation)
        XCTAssertFalse(assessment.receipt.environmentBypass)
        XCTAssertTrue(assessment.receipt.coverage.covered)
        XCTAssertFalse(assessment.receipt.coverage.truncated)
        XCTAssertEqual(
            assessment.receipt.coverage.chunks.reduce(0) { $0 + $1.byteCount },
            data.count
        )
        XCTAssertTrue(assessment.receipt.coverage.claimPaths.contains("$/model/provider"))
        XCTAssertTrue(assessment.receipt.coverage.claimPaths.contains("$/expectedCarrierKey"))
    }

    func testCaptainCanOnlyCompileAnOpaquePositiveAdmission() throws {
        let admitted = try SMLGhostBridgeRelayPEEL.admit(
            canonicalRequest: invocationData(),
            context: context()
        )

        let plan = SMLGhostBridgeRelayCaptain.plan(admitted)

        XCTAssertEqual(plan.decision, "admit-one-fixed-instruction")
        XCTAssertEqual(plan.systemID, "windows95")
        XCTAssertEqual(plan.routeIndex, 0)
        XCTAssertEqual(plan.maximumNewStages, 1)
        XCTAssertFalse(plan.routeFinalizationAllowed)
        XCTAssertEqual(plan.network, "none")
        XCTAssertTrue(plan.cleanupProofRequired)
        XCTAssertFalse(plan.modelFallbackAllowed)
        XCTAssertFalse(plan.directLegacyMCPMutationAllowed)
    }

    func testContradictoryFrontierIsNarrativeOnlyAndCannotReachCaptain() throws {
        let assessment = try SMLGhostBridgeRelayPEEL.assess(
            canonicalRequest: invocationData(),
            context: context(frontier: String(repeating: "e", count: 64))
        )

        XCTAssertFalse(assessment.receipt.effectAllowed)
        XCTAssertTrue(assessment.receipt.narrativeOnly)
        XCTAssertEqual(assessment.receipt.contradictions, ["expectedFrontierDigest"])
        XCTAssertThrowsError(
            try SMLGhostBridgeRelayPEEL.admit(
                canonicalRequest: invocationData(),
                context: context(frontier: String(repeating: "e", count: 64))
            )
        )
    }

    func testInvocationRejectsUnknownCommandCoordinateAndFallbackFields() throws {
        for field in ["command", "coordinate", "path", "fallbackModel"] {
            XCTAssertThrowsError(
                try SMLGhostBridgeRelayPEEL.assess(
                    canonicalRequest: invocationData(extra: [field: "forbidden"]),
                    context: context()
                ),
                "unknown field \(field) must fail closed"
            )
        }
    }

    func testInvocationRejectsWhitespaceAndNonCanonicalBytes() throws {
        let canonical = try invocationData()
        let padded = Data(" \n".utf8) + canonical

        XCTAssertThrowsError(
            try SMLGhostBridgeRelayPEEL.assess(
                canonicalRequest: padded,
                context: context()
            )
        ) { error in
            XCTAssertEqual(
                error as? SMLGhostBridgeRelayGovernanceError,
                .nonCanonicalInvocation
            )
        }
    }

    private func proposalData(
        autoPromoted: Bool = false,
        extra: [String: Any] = [:]
    ) throws -> Data {
        var value: [String: Any] = [
            "schema": SMLGhostBridgeRelayContract.learningProposalSchema,
            "state": "quarantined",
            "authority": "advisory-only",
            "invocationId": "qualification-proof-0001",
            "capabilityId": SMLGhostBridgeRelayContract.capabilityID,
            "outcome": "verified",
            "evidenceSHA256": String(repeating: "f", count: 64),
            "failure": NSNull(),
            "mutationAllowed": false,
            "autoPromoted": autoPromoted,
            "productionEligible": false,
            "requiresHeldOutHostOwnedEvaluation": true,
            "recordedUnixNS": Int64(1_900_000_000_000_000_000),
        ]
        extra.forEach { value[$0.key] = $0.value }
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    func testLearningIntakeStaysQuarantinedAndHasNoAuthority() throws {
        let admitted = try SMLGhostBridgeQualificationLearningGate.quarantine(
            canonicalJSONLine: proposalData()
        )

        XCTAssertEqual(admitted.proposal.state, "quarantined")
        XCTAssertEqual(admitted.proposal.authority, "advisory-only")
        XCTAssertFalse(admitted.proposal.mutationAllowed)
        XCTAssertFalse(admitted.proposal.autoPromoted)
        XCTAssertFalse(admitted.proposal.productionEligible)
        XCTAssertTrue(admitted.proposal.requiresHeldOutHostOwnedEvaluation)
        XCTAssertFalse(admitted.isExecutionAuthority)
        XCTAssertFalse(admitted.isPromotionAuthority)
        XCTAssertEqual(admitted.proposalSHA256.count, 64)
    }

    func testLearningIntakeRejectsSelfPromotionAndUnknownFields() throws {
        XCTAssertThrowsError(
            try SMLGhostBridgeQualificationLearningGate.quarantine(
                canonicalJSONLine: proposalData(autoPromoted: true)
            )
        )
        XCTAssertThrowsError(
            try SMLGhostBridgeQualificationLearningGate.quarantine(
                canonicalJSONLine: proposalData(extra: ["captainScore": 1])
            )
        )
    }
}
