import Foundation
import XCTest
@testable import AgentCore

final class PromotionSupportingEvidenceTests: XCTestCase {
    private actor CouncilProbe {
        private var count = 0
        func record() { count += 1 }
        func calls() -> Int { count }
    }

    private struct ShippingCouncil: PromotionCouncil {
        let probe: CouncilProbe
        func judge(_ ctx: PromotionContext, threshold: Int) async -> CouncilPromotionVerdict {
            await probe.record()
            return CouncilPromotionVerdict(votes: [], isShipWorthy: true,
                                           threshold: threshold, summary: "SHIP")
        }
    }

    private let contractID = "contract"
    private let objectiveFingerprint = BuilderEvidenceDigest.sha256("objective")
    private let completionFingerprint = "completion"
    private let obligationsFingerprint = "obligations"
    private let policyFingerprint = "policy"
    private let canonicalFingerprint = "canonical-objective"
    private let manifestPolicyFingerprint = "manifest-policy"
    private let manifestRevision = 5
    private let manifestDigest = "manifest"
    private let workspaceDigest = BuilderEvidenceDigest.sha256("workspace")
    private let verificationMission = String(repeating: "a", count: 64)

    private var obligations: [PlanSupportingObligation] {
        [
            .init(id: "build.clean-exit", kind: .build),
            .init(id: "fixture.valid", kind: .fixtureFileInput),
            .init(id: "fixture.invalid", kind: .expectedDomainFailure),
            .init(id: "stdin.valid", kind: .structuredStandardInput),
        ]
    }

    private func trustedReference(_ rawID: String, exitCode: Int = 0)
        -> BuilderTrustedCommandReference {
        let id = rawID.replacingOccurrences(of: ".", with: "-")
        return try! BuilderTrustedCommandReference(
            observationID: "obs-\(id)", invocationID: "invocation-\(id)",
            gateArgumentsDigest: BuilderEvidenceDigest.sha256("gate-\(id)"),
            requestedArgumentsDigest: BuilderEvidenceDigest.sha256("request-\(id)"),
            effectiveLauncherDigest: BuilderEvidenceDigest.sha256("launcher-\(id)"),
            stdoutDigest: BuilderEvidenceDigest.sha256("stdout-\(id)"),
            stderrDigest: BuilderEvidenceDigest.sha256("stderr-\(id)"),
            stdoutByteCount: 1, stderrByteCount: 0, exitCode: exitCode,
            timedOut: false, wasSignalled: false, wallTimeMilliseconds: 1)
    }

    private func support(
        missionInstanceID: String? = nil,
        id: String,
        ordinal: Int,
        executable: String,
        argv: [String],
        stdinDigest: String? = nil,
        stdinBytes: Int = 0,
        allowed: [Int] = [0],
        actual: Int = 0,
        semantic: String = "clean_exit",
        verificationEligible: Bool,
        excerpt: String,
        verification: ToolEffectObservation.Verification,
        satisfiedIDs: [String]? = nil
    ) -> PlanSupportingCommandReceipt {
        PlanSupportingCommandReceipt(
            missionInstanceID: missionInstanceID ?? verificationMission,
            contractID: contractID, captureOrdinal: ordinal, mutationFrontierOrdinal: 0,
            stepID: id, executable: executable, argv: argv,
            workingDirectory: "/tmp/project", hasStandardInput: stdinDigest != nil,
            standardInputDigest: stdinDigest, standardInputByteCount: stdinBytes,
            standardInputSourceKind: stdinDigest == nil ? .none : .governedPath,
            standardInputRelativePath: stdinDigest == nil ? nil : "Fixtures/stdin.txt",
            allowedExitCodes: allowed, actualExitCode: actual,
            wasSignalled: false, timedOut: false, semanticStatus: semantic,
            verificationEligible: verificationEligible, success: true,
            argsFingerprint: "args-\(id)", commandFingerprint: "command-\(id)",
            outputDigest: "output-\(id)", boundedRedactedOutputExcerpt: excerpt,
            effectObservation: .init(verification: verification), executionPhase: ordinal,
            completedAt: Date(timeIntervalSince1970: TimeInterval(ordinal)),
            completionContractFingerprint: completionFingerprint,
            obligationsFingerprint: obligationsFingerprint,
            executionPolicyFingerprint: policyFingerprint,
            workspaceManifestDigest: manifestDigest,
            governedWorkspaceDigest: workspaceDigest,
            satisfiedObligationIDs: satisfiedIDs ?? [id],
            canonicalFunctionalObjectiveFingerprint: canonicalFingerprint,
            workspaceManifestPolicyFingerprint: manifestPolicyFingerprint,
            workspaceManifestRevision: ordinal,
            planID: "plan-1", planRevision: 1,
            workspaceActionReceiptDigest: "action-\(id)",
            trustedCommandReference: trustedReference(id, exitCode: actual)
        )
    }

    private func evidence(omitting omittedID: String? = nil) -> PromotionCompletionEvidence {
        let supports = [
            support(id: "build.clean-exit", ordinal: 1, executable: "swift", argv: ["build"],
                    verificationEligible: true, excerpt: "Build complete",
                    verification: .buildOrTest),
            support(id: "fixture.valid", ordinal: 2, executable: ".build/debug/app",
                    argv: ["--input", "Fixtures/valid.txt"], verificationEligible: false,
                    excerpt: "6 lines accepted", verification: .nonVerifyingCommand),
            support(id: "fixture.invalid", ordinal: 3, executable: ".build/debug/app",
                    argv: ["--input", "Fixtures/invalid.txt"], allowed: [1], actual: 1,
                    semantic: "expected_domain_status", verificationEligible: false,
                    excerpt: "line 2: invalid token; line 6: missing terminator",
                    verification: .nonVerifyingCommand),
            support(id: "stdin.valid", ordinal: 4, executable: ".build/debug/app", argv: [],
                    stdinDigest: "stdin-sha", stdinBytes: 42, verificationEligible: false,
                    excerpt: "stdin accepted", verification: .nonVerifyingCommand),
        ].filter { receipt in
            omittedID.map { !receipt.satisfiedObligationIDs.contains($0) } ?? true
        }
        let finalDate = Date(timeIntervalSince1970: 5)
        let final = PlanFinalVerificationReceipt(
            missionInstanceID: verificationMission,
            contractID: contractID, stepID: "final-swift-test", tool: "run_command",
            invocation: .init(executable: "swift", argv: ["test"],
                              workingDirectory: "/tmp/project", hasStandardInput: false),
            commandFingerprint: "final-command", expectedExitCode: 0, actualExitCode: 0,
            outputDigest: "final-output", boundedRedactedOutputExcerpt: "33 tests passed",
            governedWorkspaceDigest: workspaceDigest,
            completionContractFingerprint: completionFingerprint,
            executionPolicyFingerprint: policyFingerprint, verifiedAt: finalDate,
            freshAfterMutationFrontier: true, captureOrdinal: 5, mutationFrontierOrdinal: 0,
            obligationsFingerprint: obligationsFingerprint,
            workspaceManifestDigest: manifestDigest,
            canonicalFunctionalObjectiveFingerprint: canonicalFingerprint,
            workspaceManifestPolicyFingerprint: manifestPolicyFingerprint,
            workspaceManifestRevision: manifestRevision,
            planID: "plan-1", planRevision: 1,
            workspaceActionReceiptDigest: "action-final",
            trustedCommandReference: trustedReference("final", exitCode: 0))
        let finalCommand = BuilderCommandEvidenceReceipt.boundPrehashed(
            tool: "run_command", verifierStatus: .passed, exitCode: 0,
            allowedExitCodes: "0", semanticStatus: "success",
            argsFingerprint: final.commandFingerprint, outputDigest: final.outputDigest,
            boundedRedactedOutputExcerpt: final.boundedRedactedOutputExcerpt,
            subjectDigestAfter: workspaceDigest, contractFingerprint: objectiveFingerprint,
            completedAt: final.verifiedAt)
        return PromotionCompletionEvidence(
            schemaVersion: 2, contractID: contractID,
            objectiveFingerprint: objectiveFingerprint, completionMode: .verificationOnly,
            verificationSubject: "/tmp/project", baselineDigest: workspaceDigest,
            verifiedDigest: workspaceDigest, reviewEntryDigest: workspaceDigest,
            verifiedAt: finalDate, commandReceipts: [finalCommand],
            hostChecks: [.init(name: "final", passed: true, details: "passed")],
            producerIdentities: ["claude-cli:sonnet"], reviewerIdentity: "codex-cli:gpt-5.5-codex",
            requiredSupportingObligations: obligations,
            supportingCommandReceipts: supports, finalVerificationReceipt: final,
            missionInstanceID: verificationMission)
    }

    private func finalReceipt(missionInstanceID: String?) -> PlanFinalVerificationReceipt {
        PlanFinalVerificationReceipt(
            missionInstanceID: missionInstanceID,
            contractID: contractID, stepID: "optional-final", tool: "run_command",
            invocation: .init(executable: "swift", argv: ["test"],
                              workingDirectory: "/tmp/project", hasStandardInput: false),
            commandFingerprint: "optional-final-command", expectedExitCode: 0,
            actualExitCode: 0, outputDigest: "optional-final-output",
            boundedRedactedOutputExcerpt: "tests passed",
            governedWorkspaceDigest: workspaceDigest,
            completionContractFingerprint: completionFingerprint,
            executionPolicyFingerprint: policyFingerprint,
            verifiedAt: Date(timeIntervalSince1970: 8), freshAfterMutationFrontier: true,
            captureOrdinal: 8, mutationFrontierOrdinal: 0,
            obligationsFingerprint: obligationsFingerprint,
            workspaceManifestDigest: manifestDigest,
            trustedCommandReference: trustedReference("optional-final", exitCode: 0))
    }

    private func buildEvidence(
        missionInstanceID: String?,
        supporting: [PlanSupportingCommandReceipt] = [],
        final: PlanFinalVerificationReceipt? = nil
    ) -> PromotionCompletionEvidence {
        let command = BuilderCommandEvidenceReceipt.bound(
            tool: "run_command", verifierStatus: .passed, exitCode: 0,
            allowedExitCodes: "0", semanticStatus: "success",
            argsFingerprint: "swift-build", output: "Build complete",
            subjectDigestAfter: workspaceDigest, contractFingerprint: objectiveFingerprint)
        let mutation = try! BuilderObservedMutation(
            kind: .create, path: "Sources/App.swift", preimageSHA256: nil,
            postimageSHA256: BuilderEvidenceDigest.sha256("created app source"))
        let promotion = try! BuilderTransactionPromotionReceipt(
            contractFingerprint: objectiveFingerprint, builderContractID: contractID,
            nodeID: "build", attempt: 1, workspaceDigest: workspaceDigest,
            verifierSubjectDigest: workspaceDigest, operations: [mutation])
        return PromotionCompletionEvidence(
            schemaVersion: 3, contractID: contractID,
            objectiveFingerprint: objectiveFingerprint, completionMode: .build,
            verificationSubject: "/tmp/project", baselineDigest: "before",
            verifiedDigest: workspaceDigest, reviewEntryDigest: workspaceDigest,
            verifiedAt: Date(timeIntervalSince1970: 9), commandReceipts: [command],
            hostChecks: [.init(name: "mutation", passed: true, details: "changed")],
            producerIdentities: ["claude-cli:sonnet"],
            reviewerIdentity: "codex-cli:gpt-5.5-codex", hadChanges: true,
            changedPaths: ["Sources/App.swift"], diffSummary: "1 file changed",
            mutationReceipts: [promotion],
            supportingCommandReceipts: supporting, finalVerificationReceipt: final,
            missionInstanceID: missionInstanceID)
    }

    func testFiveCommandPacketIsVisibleAndKeepsFinalReplayAsSoleVerifier() {
        let packet = evidence()
        XCTAssertNil(packet.validationFailure)
        let prompt = CouncilPromotionJudge.completionEvidencePrompt(packet)
        XCTAssertTrue(prompt.contains("executable=swift; argv=[build]"), prompt)
        XCTAssertTrue(prompt.contains("argv=[--input | Fixtures/valid.txt]"), prompt)
        XCTAssertTrue(prompt.contains("exit=1; allowed=[1]"), prompt)
        XCTAssertTrue(prompt.contains("line 2: invalid token"), prompt)
        XCTAssertTrue(prompt.contains("stdinProvided=true; stdinSHA256=stdin-sha"), prompt)
        XCTAssertTrue(prompt.contains("FINAL VERIFIER; ordinal=5; executable=swift; argv=[test]"), prompt)
        XCTAssertTrue(prompt.contains("Supporting receipts prove functional coverage only"), prompt)
        XCTAssertEqual(packet.commandReceipts.filter { $0.verifierStatus == .passed }.count, 1)
    }

    func testLiveInvalidFixtureReceiptSatisfiesFixtureAndExpectedDomainObligations() {
        let primaryID = "fixture-file.invalid.exit-1"
        let domainID = "expected-domain-failure.fixture-file.invalid.exit-1"
        let base = evidence()

        func packet(allowed: [Int], excerpt: String) -> PromotionCompletionEvidence {
            let liveReceipt = support(
                id: domainID, ordinal: 4, executable: ".build/debug/receipt-ledger",
                argv: ["--input", "Fixtures/invalid.ndjson"], allowed: allowed, actual: 1,
                semantic: "expected_domain_status", verificationEligible: false,
                excerpt: excerpt, verification: .nonVerifyingCommand,
                satisfiedIDs: [primaryID, domainID])
            return PromotionCompletionEvidence(
                schemaVersion: base.schemaVersion, contractID: base.contractID,
                objectiveFingerprint: base.objectiveFingerprint,
                completionMode: base.completionMode,
                verificationSubject: base.verificationSubject,
                baselineDigest: base.baselineDigest, verifiedDigest: base.verifiedDigest,
                reviewEntryDigest: base.reviewEntryDigest, verifiedAt: base.verifiedAt,
                commandReceipts: base.commandReceipts, hostChecks: base.hostChecks,
                producerIdentities: base.producerIdentities,
                reviewerIdentity: base.reviewerIdentity,
                hadChanges: base.hadChanges, changedPaths: base.changedPaths,
                diffSummary: base.diffSummary,
                requiredSupportingObligations: base.requiredSupportingObligations + [
                    .init(id: primaryID, kind: .fixtureFileInput),
                    .init(id: domainID, kind: .expectedDomainFailure),
                ],
                supportingCommandReceipts: base.supportingCommandReceipts + [liveReceipt],
                finalVerificationReceipt: base.finalVerificationReceipt,
                missionInstanceID: base.missionInstanceID)
        }

        XCTAssertNil(packet(
            allowed: [1],
            excerpt: "Line 2: malformed JSON; Line 3: negative amount").validationFailure)
        XCTAssertNotNil(packet(
            allowed: [0, 1],
            excerpt: "Line 2: malformed JSON; Line 3: negative amount").validationFailure,
            "an expected exit must remain an exact singleton allowlist")
        XCTAssertNotNil(packet(
            allowed: [1], excerpt: "malformed JSON without a location").validationFailure,
            "expected-domain support must retain line-numbered diagnostics")
    }

    func testMissingAnyRequiredSupportRejectsBeforeShippingCouncilCanAccept() async {
        for obligation in obligations {
            let probe = CouncilProbe()
            let packet = evidence(omitting: obligation.id)
            let build = ShipPipeline.BuildResult(
                hadChanges: false, diffSummary: "", testsPassed: true,
                testSummary: "33 tests passed", signoffSummary: "verified",
                completionEvidence: packet)
            let decision = await ShipPipeline(council: ShippingCouncil(probe: probe)).review(
                goal: "verify fixture, stdin, diagnostics, and tests",
                build: build, allowVerifiedReadOnly: true)
            XCTAssertFalse(decision.canDeploy, obligation.id)
            XCTAssertNil(decision.verdict, obligation.id)
            XCTAssertTrue(decision.reason.contains(obligation.id), decision.reason)
            let calls = await probe.calls()
            XCTAssertEqual(calls, 0, obligation.id)
        }
    }

    func testSchemaThreeBuildAcceptsValidMissionAndDigestBindsIt() {
        let firstMission = String(repeating: "a", count: 64)
        let secondMission = String(repeating: "b", count: 64)
        let first = buildEvidence(missionInstanceID: firstMission)
        let second = buildEvidence(missionInstanceID: secondMission)
        XCTAssertNil(first.validationFailure)
        XCTAssertNil(second.validationFailure)
        XCTAssertNotEqual(first.packetDigest, second.packetDigest)
        XCTAssertEqual(first.withChanges(
            hadChanges: true, changedPaths: ["Sources/App.swift"],
            diffSummary: "updated").missionInstanceID, firstMission)
    }

    func testSchemaThreeBuildRejectsMissingOrMalformedMission() {
        XCTAssertNotNil(buildEvidence(missionInstanceID: nil).validationFailure)
        XCTAssertNotNil(buildEvidence(missionInstanceID: "ABC123").validationFailure)
        XCTAssertNotNil(buildEvidence(
            missionInstanceID: String(repeating: "A", count: 64)).validationFailure)
    }

    func testSchemaThreeBuildRejectsOptionalSupportOrFinalMissionMismatch() {
        let mission = String(repeating: "c", count: 64)
        let other = String(repeating: "d", count: 64)
        let mismatchedSupport = support(
            missionInstanceID: other, id: "build.clean-exit", ordinal: 1,
            executable: "swift", argv: ["build"], verificationEligible: true,
            excerpt: "Build complete", verification: .buildOrTest)
        XCTAssertNotNil(buildEvidence(
            missionInstanceID: mission, supporting: [mismatchedSupport]).validationFailure)
        XCTAssertNotNil(buildEvidence(
            missionInstanceID: mission,
            final: finalReceipt(missionInstanceID: other)).validationFailure)
    }
}
