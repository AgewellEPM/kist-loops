import Dispatch
import Foundation
import XCTest
@testable import AgentCore

final class AcceptedRunPersistenceTests: XCTestCase {
    private enum VoteShape {
        case threeShipOneFailed
        case twoShipTwoFailed
        case threeShipOneHold
        case wrongLens
        case failedVoteClaimsAccepted
    }

    private struct Fixture {
        let run: RunRecord
        let authority: BuilderFinalAcceptanceAuthority
        let childContractFingerprint: String
    }

    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let missionID = String(repeating: "a", count: 64)
    private let contractID = "build.verify.v1"
    private let goal = "build and verify"
    private let childContractFingerprint = String(repeating: "d", count: 64)

    override func setUp() {
        super.setUp()
        ForgeSeal.forceEphemeralKeyForTesting()
    }

    override func tearDown() {
        ForgeSeal.resetCacheForTesting()
        super.tearDown()
    }

    private func temporaryRoot(_ prefix: String = "accepted-run-persistence") throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return root
    }

    private func runID(_ value: Int) -> String {
        let suffix = String(value, radix: 16)
        return String(repeating: "0", count: 64 - suffix.count) + suffix
    }

    private func ledgerURL(_ root: URL) -> URL {
        root.appendingPathComponent(".kist/run-ledger.jsonl")
    }

    private func receiptURL(_ root: URL) -> URL {
        root.appendingPathComponent(".kist/accepted-run-receipts.jsonl")
    }

    private func fixture(
        root: URL,
        missionID: String? = nil,
        success: Bool = true,
        verified: Bool = true,
        runRoute: String = BuilderRoute.planned.rawValue,
        runAt: Date? = nil,
        runObjectiveOverride: String? = nil,
        reviewGrade: EvolutionReviewGrade = .independent,
        independent: Bool = true,
        voteShape: VoteShape = .threeShipOneFailed,
        reviewThreshold: Int = 3
    ) async throws -> Fixture {
        let mission = missionID ?? self.missionID
        let objective = try AcceptedRunReceipt.computeObjectiveFingerprint(
            contractID: contractID, exactGoal: goal)
        let projectIdentity = try AcceptedRunReceipt.computeProjectIdentity(
            projectRoot: root.path)
        let subject = root.path
        let subjectDigest = BuilderEvidenceDigest.sha256("subject:\(root.path)")
        let arguments: [String: Any] = [
            "executable": "/usr/bin/printf",
            "args": ["%s", "verified"],
        ]
        let telemetryBinding = try BuilderTrustedTelemetryBinding(
            contractFingerprint: childContractFingerprint,
            nodeID: "final-verification", attempt: 1, stage: .verification)
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: telemetryBinding, registerBudgetAuthority: false) {
                await ToolRegistry([RunCommandTool()]).execute(
                    name: "run_command", arguments: arguments,
                    context: ToolContext(
                        projectRoot: root.path,
                        shell: ShellPolicy(
                            enabled: true, autoApprove: true, allow: ["printf"]),
                        sandbox: .disabled))
            }
        let result = try captured.0.get()
        let reference = try XCTUnwrap(result.trustedCommandReference)
        let command = BuilderCommandEvidenceReceipt.boundPrehashed(
            tool: "run_command", verifierStatus: .passed,
            exitCode: reference.exitCode, allowedExitCodes: "0",
            semanticStatus: "clean_exit",
            argsFingerprint: reference.gateArgumentsDigest,
            // Real Kist evidence may bind stdout here while PlanFinal binds the full stream.
            outputDigest: reference.stdoutDigest,
            boundedRedactedOutputExcerpt: result.output,
            subjectDigestAfter: subjectDigest,
            contractFingerprint: childContractFingerprint,
            trustedCommandReference: reference, completedAt: now)
        let planReceipt = PlanFinalVerificationReceipt(
            missionInstanceID: mission, contractID: contractID,
            stepID: "final-verify", tool: "run_command",
            invocation: PlanFinalVerificationInvocation(
                executable: "/usr/bin/printf", argv: ["%s", "verified"],
                hasStandardInput: false),
            commandFingerprint: BuilderEvidenceDigest.sha256("final-command"),
            expectedExitCode: 0, actualExitCode: reference.exitCode,
            outputDigest: reference.fullStreamDigest,
            boundedRedactedOutputExcerpt: result.output,
            governedWorkspaceDigest: subjectDigest,
            completionContractFingerprint: BuilderEvidenceDigest.sha256("completion"),
            executionPolicyFingerprint: BuilderEvidenceDigest.sha256("policy"),
            verifiedAt: now, freshAfterMutationFrontier: true,
            captureOrdinal: 2, mutationFrontierOrdinal: 1,
            obligationsFingerprint: BuilderEvidenceDigest.sha256("obligations"),
            workspaceManifestDigest: BuilderEvidenceDigest.sha256("manifest"),
            trustedCommandReference: reference)

        let producerIdentity = "producer:model"
        let reviewerIdentity = reviewGrade == .independent
            ? "reviewer:model" : producerIdentity
        let reviewerParts = reviewerIdentity.split(separator: ":", maxSplits: 1).map(String.init)
        let lenses = voteShape == .wrongLens
            ? ["Correctness", "Security", "Worth", "Style"]
            : ["Correctness", "Security", "Worth", "Completeness"]
        let votes: [BuilderReviewVoteReceipt] = lenses.enumerated().map { index, lens in
            let accepted: Bool
            let failed: Bool
            switch voteShape {
            case .threeShipOneFailed, .wrongLens:
                accepted = index < 3
                failed = index == 3
            case .twoShipTwoFailed:
                accepted = index < 2
                failed = index >= 2
            case .threeShipOneHold:
                accepted = index < 3
                failed = false
            case .failedVoteClaimsAccepted:
                accepted = true
                failed = index == 3
            }
            return BuilderReviewVoteReceipt(
                lens: lens, accepted: accepted,
                reason: accepted ? "SHIP" : (failed ? "review failed" : "HOLD"),
                failed: failed,
                provider: reviewerParts[0], model: reviewerParts[1],
                invocationID: failed ? nil : "review-invocation-\(index)",
                freshConversation: failed ? nil : true)
        }
        let review = BuilderReviewReceipt(
            provider: reviewerParts[0], model: reviewerParts[1], accepted: true,
            checks: [.init(name: "council decision", passed: true)],
            workerIdentities: [producerIdentity], reviewerIdentity: reviewerIdentity,
            evidencePacketDigest: BuilderEvidenceDigest.sha256("evidence-packet"),
            votes: votes, reviewGrade: reviewGrade, independent: independent,
            freshConversation: reviewGrade == .independent ? nil : true,
            separateInvocation: reviewGrade == .independent ? nil : true,
            reviewThreshold: reviewThreshold)
        let verification = BuilderVerifierReceipt(
            scope: .final, provider: "kist", model: "deterministic",
            deterministic: true, passed: true,
            checks: [.init(name: "final deterministic verification", passed: true)],
            verificationSubject: subject, baselineDigest: subjectDigest,
            subjectDigest: subjectDigest,
            contractFingerprint: childContractFingerprint,
            completionMode: .verificationOnly, commandEvidence: [command],
            verifiedAt: now, planFinalVerificationReceipt: planReceipt,
            missionInstanceID: mission)
        let worker = BuilderWorkerReceipt(
            nodeID: "build", provider: "producer", model: "model",
            checks: [.init(name: "worker", passed: true)],
            missionInstanceID: mission)
        let unsignedFinal = BuilderFinalReceipt(
            contractID: contractID, route: .planned, workers: [worker],
            verification: verification, review: review, accepted: true,
            completedAt: now)
        let parentFingerprint = BuilderEvidenceDigest.sha256("parent-contract")
        let graphFingerprint = BuilderEvidenceDigest.sha256("graph")
        let commitEpoch = BuilderEvidenceDigest.sha256("commit-epoch")
        let sealedFinal = try unsignedFinal.authorizing(
            parentContractFingerprint: parentFingerprint,
            graphFingerprint: graphFingerprint,
            objectiveFingerprint: objective,
            commitEpoch: commitEpoch,
            trustedTelemetry: captured.1)
        let authority = try BuilderFinalAcceptanceAuthority(
            finalReceipt: sealedFinal, trustedTelemetry: captured.1,
            parentContractFingerprint: parentFingerprint,
            graphFingerprint: graphFingerprint,
            objectiveFingerprint: objective, commitEpoch: commitEpoch)
        let run = RunRecord(
            id: mission, at: (runAt ?? now).timeIntervalSince1970, goal: goal,
            signature: "accepted-run", orgVersion: "test", route: runRoute,
            complexity: 80, thinking: "deep", planning: "graph", team: "builder",
            modelTier: "frontier", decisionReason: "typed Builder authority",
            specialists: ["coder", "critic"], provider: "producer", model: "model",
            success: success, verified: verified, failureRate: 0,
            iterationsUsed: 1, iterationBudget: 3, replansUsed: 0,
            wasStuck: false, toolCalls: 2, durationMs: 100, totalTokens: 10,
            projectIdentity: projectIdentity, contractID: contractID,
            objectiveFingerprint: runObjectiveOverride ?? objective,
            verificationSubject: subject, verificationDigest: subjectDigest)
        return Fixture(
            run: run, authority: authority,
            childContractFingerprint: childContractFingerprint)
    }

    func testAcceptedThreeShipOneFailedPersistsExactLedgerThenReceiptAndResumes()
        async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try await fixture(root: root)
        let persistence = AcceptedRunPersistence(projectRoot: root.path)

        XCTAssertNotEqual(value.childContractFingerprint, value.run.objectiveFingerprint,
                          "child verification contract is not the sealed mission objective")
        let first = try persistence.persistPlanExecuteAccepted(
            value.run, authorizing: value.authority, now: now, freshness: 3_600)
        XCTAssertEqual(first.ledgerWrite, RunLedgerTrustWrite.appended)
        let resumed = try persistence.persistPlanExecuteAccepted(
            value.run, authorizing: value.authority,
            now: now.addingTimeInterval(1), freshness: 30)
        XCTAssertEqual(resumed.ledgerWrite, RunLedgerTrustWrite.alreadyPresent)
        XCTAssertEqual(resumed.receipt, first.receipt)

        var exactLedgerLine = try Data(contentsOf: ledgerURL(root))
        XCTAssertEqual(exactLedgerLine.popLast(), 0x0A)
        XCTAssertEqual(exactLedgerLine, try RunLedger.canonicalRecordLine(value.run))
        XCTAssertEqual(first.receipt.ledgerRecordDigest,
                       try RunLedger.canonicalRecordDigest(value.run))
        XCTAssertEqual(try AcceptedRunReceiptStore(projectRoot: root.path).allReceipts(),
                       [first.receipt])
        XCTAssertEqual(RunLedger(projectRoot: root.path).load(), [value.run])
    }

    func testLedgerFailureMintsNothingAndReceiptFailureLeavesAmberLedgerForResume()
        async throws {
        let noCapacityRoot = try temporaryRoot("accepted-no-capacity")
        defer { try? FileManager.default.removeItem(at: noCapacityRoot) }
        let noCapacity = try await fixture(root: noCapacityRoot)
        XCTAssertThrowsError(try AcceptedRunPersistence(
            projectRoot: noCapacityRoot.path, maxLedgerRecords: 0)
            .persistPlanExecuteAccepted(
                noCapacity.run, authorizing: noCapacity.authority, now: now)) { error in
                    XCTAssertEqual(error as? RunLedgerTrustError,
                                   .persistence("ledger capacity"))
                }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL(noCapacityRoot).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL(noCapacityRoot).path))

        let root = try temporaryRoot("accepted-receipt-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try await fixture(root: root)
        let kist = root.appendingPathComponent(".kist", isDirectory: true)
        try FileManager.default.createDirectory(
            at: kist, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let sentinel = root.appendingPathComponent("outside-receipts")
        try Data("sentinel".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: receiptURL(root), withDestinationURL: sentinel)
        XCTAssertThrowsError(try AcceptedRunPersistence(projectRoot: root.path)
            .persistPlanExecuteAccepted(
                value.run, authorizing: value.authority, now: now))
        XCTAssertEqual(RunLedger(projectRoot: root.path).load(), [value.run],
                       "ledger-first interruption must remain amber and recoverable")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))

        try FileManager.default.removeItem(at: receiptURL(root))
        let resumed = try AcceptedRunPersistence(projectRoot: root.path)
            .persistPlanExecuteAccepted(
                value.run, authorizing: value.authority,
                now: now.addingTimeInterval(1))
        XCTAssertEqual(resumed.ledgerWrite, RunLedgerTrustWrite.alreadyPresent)
        XCTAssertEqual(try AcceptedRunReceiptStore(projectRoot: root.path).allReceipts(),
                       [resumed.receipt])
    }

    func testFailedUnverifiedAndSameModelAuthorityNeverMint() async throws {
        let cases: [(Bool, Bool, EvolutionReviewGrade, Bool)] = [
            (false, true, .independent, true),
            (true, false, .independent, true),
            (true, true, .freshContextSameModel, false),
        ]
        for (success, verified, grade, independent) in cases {
            let root = try temporaryRoot("accepted-refused")
            defer { try? FileManager.default.removeItem(at: root) }
            let value = try await fixture(
                root: root, success: success, verified: verified,
                reviewGrade: grade, independent: independent)
            XCTAssertThrowsError(try AcceptedRunPersistence(projectRoot: root.path)
                .persistPlanExecuteAccepted(
                    value.run, authorizing: value.authority, now: now))
            XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL(root).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL(root).path))
        }
    }

    func testCouncilQuorumHoldThresholdAndLensTamperAreFailClosed() async throws {
        let cases: [(VoteShape, Int)] = [
            (.twoShipTwoFailed, 3),
            (.threeShipOneHold, 3),
            (.threeShipOneFailed, 2),
            (.wrongLens, 3),
            (.failedVoteClaimsAccepted, 3),
        ]
        for (shape, threshold) in cases {
            let root = try temporaryRoot("accepted-quorum-refused")
            defer { try? FileManager.default.removeItem(at: root) }
            let value = try await fixture(
                root: root, voteShape: shape, reviewThreshold: threshold)
            XCTAssertThrowsError(try AcceptedRunPersistence(projectRoot: root.path)
                .persistPlanExecuteAccepted(
                    value.run, authorizing: value.authority, now: now))
            XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL(root).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL(root).path))
        }
    }

    func testObjectiveRouteAndTimestampProjectionTamperAreRejectedBeforeWrites()
        async throws {
        let cases: [(String?, String, Date?)] = [
            (String(repeating: "f", count: 64), BuilderRoute.planned.rawValue, nil),
            (nil, BuilderRoute.direct.rawValue, nil),
            (nil, BuilderRoute.planned.rawValue, now.addingTimeInterval(1)),
        ]
        for (objective, route, at) in cases {
            let root = try temporaryRoot("accepted-projection-refused")
            defer { try? FileManager.default.removeItem(at: root) }
            let value = try await fixture(
                root: root, runRoute: route, runAt: at,
                runObjectiveOverride: objective)
            XCTAssertThrowsError(try AcceptedRunPersistence(projectRoot: root.path)
                .persistPlanExecuteAccepted(
                    value.run, authorizing: value.authority, now: now))
            XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL(root).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL(root).path))
        }
    }

    func testDuplicateAndMalformedLedgerCannotBeLaunderedOnResume() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try await fixture(root: root)
        let persistence = AcceptedRunPersistence(projectRoot: root.path)
        _ = try persistence.persistPlanExecuteAccepted(
            value.run, authorizing: value.authority, now: now)
        let once = try Data(contentsOf: ledgerURL(root))
        let handle = try FileHandle(forWritingTo: ledgerURL(root))
        try handle.seekToEnd()
        try handle.write(contentsOf: once)
        try handle.close()
        XCTAssertThrowsError(try persistence.persistPlanExecuteAccepted(
            value.run, authorizing: value.authority,
            now: now.addingTimeInterval(1))) { error in
                XCTAssertEqual(error as? RunLedgerTrustError, .conflictingRunID)
            }

        let malformedRoot = try temporaryRoot("accepted-malformed")
        defer { try? FileManager.default.removeItem(at: malformedRoot) }
        let malformed = try await fixture(root: malformedRoot)
        let kist = malformedRoot.appendingPathComponent(".kist", isDirectory: true)
        try FileManager.default.createDirectory(at: kist, withIntermediateDirectories: true)
        let corruption = Data("{not-json}\n".utf8)
        try corruption.write(to: ledgerURL(malformedRoot))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: ledgerURL(malformedRoot).path)
        XCTAssertThrowsError(try AcceptedRunPersistence(projectRoot: malformedRoot.path)
            .persistPlanExecuteAccepted(
                malformed.run, authorizing: malformed.authority, now: now)) { error in
                    XCTAssertEqual(error as? RunLedgerTrustError, .malformedStore)
                }
        XCTAssertEqual(try Data(contentsOf: ledgerURL(malformedRoot)), corruption)
    }

    func testCrossProjectCopyCannotValidateAgainstActiveRoot() async throws {
        let source = try temporaryRoot("accepted-project-a")
        let target = try temporaryRoot("accepted-project-b")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let value = try await fixture(root: source)
        _ = try AcceptedRunPersistence(projectRoot: source.path)
            .persistPlanExecuteAccepted(
                value.run, authorizing: value.authority, now: now)
        let copied = target.appendingPathComponent("copied-kist", isDirectory: true)
        try FileManager.default.copyItem(
            at: source.appendingPathComponent(".kist"), to: copied)
        let targetKist = target.appendingPathComponent(".kist", isDirectory: true)
        try FileManager.default.moveItem(at: copied, to: targetKist)

        let targetIdentity = try AcceptedRunReceipt.computeProjectIdentity(
            projectRoot: target.path)
        let binding = try AcceptedRunReceipt.Binding(
            runID: value.run.id, contractID: contractID, exactGoal: goal,
            projectIdentity: targetIdentity,
            verificationSubject: try XCTUnwrap(value.run.verificationSubject),
            verificationDigest: try XCTUnwrap(value.run.verificationDigest),
            ledgerRecordDigest: try RunLedger.canonicalRecordDigest(value.run))
        XCTAssertThrowsError(try AcceptedRunReceiptStore(projectRoot: target.path)
            .validatedReceipt(matching: binding, now: now)) { error in
                XCTAssertEqual(error as? AcceptedRunReceiptError,
                               .bindingMismatch("projectIdentity"))
            }
    }

    func testWritableKistDirectoryAndLedgerSymlinkAreRejected() async throws {
        let writableRoot = try temporaryRoot("accepted-writable-dir")
        defer { try? FileManager.default.removeItem(at: writableRoot) }
        let writable = try await fixture(root: writableRoot)
        let kist = writableRoot.appendingPathComponent(".kist", isDirectory: true)
        try FileManager.default.createDirectory(at: kist, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: kist.path)
        XCTAssertThrowsError(try AcceptedRunPersistence(projectRoot: writableRoot.path)
            .persistPlanExecuteAccepted(
                writable.run, authorizing: writable.authority, now: now))

        let symlinkRoot = try temporaryRoot("accepted-ledger-symlink")
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        let symlinked = try await fixture(root: symlinkRoot)
        let symlinkKist = symlinkRoot.appendingPathComponent(".kist", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkKist, withIntermediateDirectories: true)
        let outside = symlinkRoot.appendingPathComponent("outside-ledger")
        try Data("sentinel\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: ledgerURL(symlinkRoot), withDestinationURL: outside)
        XCTAssertThrowsError(try AcceptedRunPersistence(projectRoot: symlinkRoot.path)
            .persistPlanExecuteAccepted(
                symlinked.run, authorizing: symlinked.authority, now: now))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "sentinel\n")
    }

    func testConcurrentTrustedAndAdvisoryWritersShareLosslessOwnerOnlyLedger()
        async throws {
        let root = try temporaryRoot("accepted-concurrent")
        defer { try? FileManager.default.removeItem(at: root) }
        var trusted: [Fixture] = []
        for value in 1...6 {
            trusted.append(try await fixture(root: root, missionID: runID(value)))
        }
        let advisory = (1...6).map { value in
            RunRecord(
                id: "advisory-\(value)", at: now.timeIntervalSince1970,
                goal: "observe \(value)", signature: "advisory", orgVersion: "test",
                route: "fast", complexity: 1, thinking: "light", planning: "direct",
                team: "solo", modelTier: "fast", decisionReason: "advisory",
                success: true, verified: false, failureRate: 0,
                iterationsUsed: 1, iterationBudget: 1, replansUsed: 0,
                wasStuck: false, toolCalls: 0, durationMs: 1, totalTokens: 0)
        }
        let lock = NSLock()
        var errors: [Error] = []
        let fixedNow = now
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            if index.isMultiple(of: 2) {
                let value = trusted[index / 2]
                do {
                    _ = try AcceptedRunPersistence(projectRoot: root.path)
                        .persistPlanExecuteAccepted(
                            value.run, authorizing: value.authority, now: fixedNow)
                } catch {
                    lock.lock(); errors.append(error); lock.unlock()
                }
            } else {
                RunLedger(projectRoot: root.path).record(advisory[index / 2])
            }
        }
        XCTAssertTrue(errors.isEmpty, "mixed persistence errors: \(errors)")
        let loaded = RunLedger(projectRoot: root.path).load()
        XCTAssertEqual(loaded.count, 12)
        XCTAssertEqual(Set(loaded.map(\.id)), Set((trusted.map(\.run) + advisory).map(\.id)))
        let attributes = try FileManager.default.attributesOfItem(atPath: ledgerURL(root).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try AcceptedRunReceiptStore(projectRoot: root.path).allReceipts().count, 6)
    }

    func testBoundedLedgerNeverEvictsAcceptedProjectionForAdvisoryOrSecondTrust()
        async throws {
        let root = try temporaryRoot("accepted-ledger-capacity")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await fixture(root: root, missionID: runID(1))
        let persistence = AcceptedRunPersistence(projectRoot: root.path, maxLedgerRecords: 1)
        _ = try persistence.persistPlanExecuteAccepted(
            first.run, authorizing: first.authority, now: now)
        let acceptedBytes = try Data(contentsOf: ledgerURL(root))

        let advisory = RunRecord(
            id: "advisory-at-capacity", at: now.timeIntervalSince1970,
            goal: "observe only", signature: "advisory", orgVersion: "test",
            route: "fast", complexity: 1, thinking: "light", planning: "direct",
            team: "solo", modelTier: "fast", decisionReason: "advisory",
            success: true, verified: false, failureRate: 0,
            iterationsUsed: 1, iterationBudget: 1, replansUsed: 0,
            wasStuck: false, toolCalls: 0, durationMs: 1, totalTokens: 0)
        RunLedger(projectRoot: root.path, maxRecords: 1).record(advisory)
        XCTAssertEqual(try Data(contentsOf: ledgerURL(root)), acceptedBytes)
        XCTAssertEqual(RunLedger(projectRoot: root.path).load(), [first.run])

        let second = try await fixture(root: root, missionID: runID(2))
        XCTAssertThrowsError(try persistence.persistPlanExecuteAccepted(
            second.run, authorizing: second.authority, now: now)) { error in
                XCTAssertEqual(error as? RunLedgerTrustError,
                               .persistence("ledger capacity"))
            }
        XCTAssertEqual(try Data(contentsOf: ledgerURL(root)), acceptedBytes)
        XCTAssertEqual(RunLedger(projectRoot: root.path).load(), [first.run])
        XCTAssertEqual(
            try AcceptedRunReceiptStore(projectRoot: root.path).allReceipts().map(\.runID),
            [first.run.id])
    }
}
