import Foundation
import XCTest
@testable import AgentCore

final class EvolutionRollbackAnchorTests: XCTestCase {
    private let keyID = "external-anchor-1"
    private let challenge = String(repeating: "c", count: 32)
    private let now: Int64 = 1_800_000_000
    private var anchorNamespaceDigest: String { digest("f") }

    private enum StubError: Error {
        case unavailable
        case unexpectedRequest
        case mutationNotAuthorized
    }

    private struct FixedCASClient: EvolutionRollbackExternalCASClient {
        let witness: EvolutionSignedRollbackWitness
        let expectedRead: EvolutionRollbackCASReadRequest

        func readCurrent(
            _ request: EvolutionRollbackCASReadRequest
        ) async throws -> EvolutionSignedRollbackWitness {
            guard request == expectedRead else { throw StubError.unexpectedRequest }
            return witness
        }

        func compareAndSwap(
            _ request: EvolutionRollbackCASAdvanceRequest
        ) async throws -> EvolutionSignedRollbackWitness {
            throw StubError.mutationNotAuthorized
        }
    }

    private struct UnavailableCASClient: EvolutionRollbackExternalCASClient {
        func readCurrent(
            _ request: EvolutionRollbackCASReadRequest
        ) async throws -> EvolutionSignedRollbackWitness {
            throw StubError.unavailable
        }

        func compareAndSwap(
            _ request: EvolutionRollbackCASAdvanceRequest
        ) async throws -> EvolutionSignedRollbackWitness {
            throw StubError.unavailable
        }
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func checkpoint(
        lines: UInt64 = 10,
        bytes: UInt64 = 1_000,
        tail: Character = "b",
        head: Character = "c",
        fitnessEpoch: UInt64 = 3,
        corpus: Character = "d",
        harness: Character = "e",
        fitnessReceipt: Character = "f",
        previousWitnessDigest: String? = nil
    ) throws -> EvolutionRollbackCheckpoint {
        try EvolutionRollbackCheckpoint(
            projectIdentityDigest: digest("a"),
            archiveLineCount: lines,
            archiveByteCount: bytes,
            archiveTailHash: digest(tail),
            archiveHeadDigest: digest(head),
            fitnessEpoch: fitnessEpoch,
            fitnessCorpusDigest: digest(corpus),
            fitnessHarnessDigest: digest(harness),
            fitnessReceiptDigest: digest(fitnessReceipt),
            previousWitnessDigest: previousWitnessDigest ?? digest("9"))
    }

    private func signedWitness(
        checkpoint: EvolutionRollbackCheckpoint,
        keyPair: MythosCrypto.Ed25519KeyPair,
        revision: UInt64 = 7,
        challenge: String? = nil,
        issuedAt: Int64? = nil,
        keyID: String? = nil
    ) throws -> EvolutionSignedRollbackWitness {
        let statement = try EvolutionRollbackWitnessStatement(
            anchorNamespaceDigest: anchorNamespaceDigest,
            keyID: keyID ?? self.keyID,
            revision: revision,
            challenge: challenge ?? self.challenge,
            issuedAtUnixSeconds: issuedAt ?? now,
            checkpoint: checkpoint,
            priorWitnessDigest: checkpoint.previousWitnessDigest)
        let signature = try MythosCrypto.ed25519Sign(
            message: statement.canonicalPayload(),
            privateKeyRaw: keyPair.privateRaw)
        return try EvolutionSignedRollbackWitness(
            statement: statement,
            signatureBase64: signature.base64EncodedString())
    }

    private func verifier(
        _ keyPair: MythosCrypto.Ed25519KeyPair,
        freshness: EvolutionRollbackFreshnessPolicy = .standard
    ) throws -> EvolutionRollbackWitnessVerifier {
        try EvolutionRollbackWitnessVerifier(
            pinnedKeys: [try EvolutionRollbackPinnedPublicKey(
                keyID: keyID, publicKeyRaw: keyPair.publicRaw)],
            freshness: freshness)
    }

    private func context(
        challenge: String? = nil,
        now: Int64? = nil,
        revision: UInt64 = 6,
        witnessDigest: String? = nil,
        lastChallengeDigest: String? = nil
    ) throws -> EvolutionRollbackVerificationContext {
        try EvolutionRollbackVerificationContext(
            anchorNamespaceDigest: anchorNamespaceDigest,
            expectedChallenge: challenge ?? self.challenge,
            nowUnixSeconds: now ?? self.now,
            lastAcceptedRevision: revision,
            lastAcceptedWitnessDigest: witnessDigest ?? digest("9"),
            lastAcceptedChallengeDigest: lastChallengeDigest ?? digest("8"))
    }

    func testExactSignedCheckpointIsAnchoredThroughInjectedReadOnlyClient() async throws {
        let pair = MythosCrypto.ed25519GenerateKeyPair()
        let local = try checkpoint()
        let signed = try signedWitness(checkpoint: local, keyPair: pair)
        let expectedRead = try EvolutionRollbackCASReadRequest(
            anchorNamespaceDigest: anchorNamespaceDigest,
            projectIdentityDigest: local.projectIdentityDigest,
            challenge: challenge)
        let anchor = EvolutionRollbackAnchor(
            client: FixedCASClient(witness: signed, expectedRead: expectedRead),
            verifier: try verifier(pair))

        let assessment = await anchor.assess(local: local, context: try context())
        guard case .anchored(let verified) = assessment else {
            return XCTFail("exact externally signed checkpoint must be anchored: \(assessment)")
        }
        XCTAssertEqual(verified.signedWitness, signed)
        XCTAssertEqual(verified.verifiedKeyID, keyID)
        XCTAssertEqual(verified.witnessDigest, try signed.witnessDigest())
        XCTAssertEqual(verified.witnessDigest.count, 64)

        // A fresh challenge response for the already-current durable head keeps the same stable
        // witness digest and revision, but carries a new signature-bearing challenge envelope.
        let nextChallenge = String(repeating: "d", count: 32)
        let refreshed = try signedWitness(
            checkpoint: local,
            keyPair: pair,
            revision: 7,
            challenge: nextChallenge,
            issuedAt: now + 1)
        XCTAssertEqual(try refreshed.witnessDigest(), verified.witnessDigest)
        let refreshedAssessment = try verifier(pair).verify(
            refreshed,
            local: local,
            context: context(
                challenge: nextChallenge,
                now: now + 1,
                revision: 7,
                witnessDigest: verified.witnessDigest,
                lastChallengeDigest: EvolutionRollbackVerificationContext.challengeDigest(
                    challenge)))
        guard case .anchored = refreshedAssessment else {
            return XCTFail("fresh read of the same stable head must remain anchored")
        }

        let encoded = try signed.canonicalData()
        XCTAssertEqual(
            try JSONDecoder().decode(EvolutionSignedRollbackWitness.self, from: encoded),
            signed)
    }

    func testLocalStrictlyAheadIsUnanchoredRatherThanAccepted() throws {
        let pair = MythosCrypto.ed25519GenerateKeyPair()
        let external = try checkpoint(
            lines: 10, bytes: 1_000, tail: "1", head: "2",
            fitnessEpoch: 2, corpus: "3", harness: "4")
        let signedCurrent = try signedWitness(
            checkpoint: external, keyPair: pair, revision: 6)
        let currentDigest = try signedCurrent.witnessDigest()
        let local = try checkpoint(
            lines: 11, bytes: 1_100, tail: "5", head: "6",
            fitnessEpoch: 3, corpus: "7", harness: "8",
            previousWitnessDigest: currentDigest)
        let assessment = try verifier(pair).verify(
            signedCurrent,
            local: local,
            context: context(revision: 6, witnessDigest: currentDigest))

        guard case .localAheadUnanchored(let verified) = assessment else {
            return XCTFail("local state ahead of the witness must remain unanchored: \(assessment)")
        }
        XCTAssertEqual(verified.signedWitness.statement.checkpoint, external)
    }

    func testExternalWitnessDetectsCoordinatedLocalArchiveAndCursorRollback() throws {
        let pair = MythosCrypto.ed25519GenerateKeyPair()
        let rolledCursorDigest = digest("1")
        let rolledLocal = try checkpoint(
            lines: 4, bytes: 400, tail: "2", head: "3",
            fitnessEpoch: 1, corpus: "4", harness: "5",
            previousWitnessDigest: rolledCursorDigest)
        let externalCurrent = try checkpoint(
            lines: 12, bytes: 1_200, tail: "6", head: "7",
            fitnessEpoch: 4, corpus: "8", harness: "a",
            previousWitnessDigest: digest("b"))
        let assessment = try verifier(pair).verify(
            signedWitness(
                checkpoint: externalCurrent,
                keyPair: pair,
                revision: 12),
            local: rolledLocal,
            context: context(revision: 2, witnessDigest: rolledCursorDigest))

        guard case .witnessAheadRollback(let verified) = assessment else {
            return XCTFail("external state ahead of coordinated local rollback must be detected: \(assessment)")
        }
        XCTAssertEqual(verified.signedWitness.statement.revision, 12)
    }

    func testEqualCountersWithDifferentArchiveDigestIsMismatch() throws {
        let pair = MythosCrypto.ed25519GenerateKeyPair()
        let external = try checkpoint(head: "1")
        let local = try checkpoint(head: "2")
        let assessment = try verifier(pair).verify(
            signedWitness(checkpoint: external, keyPair: pair),
            local: local,
            context: context())

        guard case .mismatch(let verified) = assessment else {
            return XCTFail("equal counters cannot hide different archive identities: \(assessment)")
        }
        XCTAssertEqual(verified.signedWitness.statement.checkpoint.archiveHeadDigest, digest("1"))
    }

    func testSameFitnessEpochWithDifferentCompleteReceiptDigestIsMismatch() throws {
        let pair = MythosCrypto.ed25519GenerateKeyPair()
        let external = try checkpoint(fitnessReceipt: "1")
        let local = try checkpoint(fitnessReceipt: "2")
        let assessment = try verifier(pair).verify(
            signedWitness(checkpoint: external, keyPair: pair),
            local: local,
            context: context())

        guard case .mismatch = assessment else {
            return XCTFail("the complete capability-fitness receipt digest must be anchored")
        }
    }

    func testUnavailableExternalStoreNeverBecomesEmptyOrRootAnchor() async throws {
        let pair = MythosCrypto.ed25519GenerateKeyPair()
        let explicitEmpty = try checkpoint(
            lines: 0, bytes: 0, tail: "0", head: "0", fitnessEpoch: 0)
        let anchor = EvolutionRollbackAnchor(
            client: UnavailableCASClient(), verifier: try verifier(pair))

        let assessment = await anchor.assess(
            local: explicitEmpty,
            context: try context())
        XCTAssertEqual(assessment, .unavailable)
    }

    func testStaleAndFarFutureStatementsAreRejected() throws {
        let pair = MythosCrypto.ed25519GenerateKeyPair()
        let local = try checkpoint()
        let pinned = try verifier(pair)

        XCTAssertEqual(
            pinned.verify(
                try signedWitness(
                    checkpoint: local, keyPair: pair, issuedAt: now - 301),
                local: local,
                context: try context()),
            .stale)
        XCTAssertEqual(
            pinned.verify(
                try signedWitness(
                    checkpoint: local, keyPair: pair, issuedAt: now + 31),
                local: local,
                context: try context()),
            .stale)
    }

    func testConsumedChallengeResponseIsReplayEvenWithValidSignature() throws {
        let pair = MythosCrypto.ed25519GenerateKeyPair()
        let local = try checkpoint()
        let replay = try signedWitness(
            checkpoint: local, keyPair: pair, revision: 6)

        XCTAssertEqual(
            try verifier(pair).verify(
                replay,
                local: local,
                context: context(
                    revision: 6,
                    lastChallengeDigest: EvolutionRollbackVerificationContext.challengeDigest(
                        challenge))),
            .replay)
    }

    func testWrongFreshChallengeIsRejected() throws {
        let pair = MythosCrypto.ed25519GenerateKeyPair()
        let local = try checkpoint()
        let wrongChallenge = String(repeating: "d", count: 32)
        let signed = try signedWitness(
            checkpoint: local, keyPair: pair, challenge: wrongChallenge)

        XCTAssertEqual(
            try verifier(pair).verify(signed, local: local, context: context()),
            .challengeMismatch)
    }

    func testSignatureFromUnpinnedPrivateKeyIsRejected() throws {
        let pinnedPair = MythosCrypto.ed25519GenerateKeyPair()
        let attackerPair = MythosCrypto.ed25519GenerateKeyPair()
        let local = try checkpoint()
        let forged = try signedWitness(checkpoint: local, keyPair: attackerPair)

        XCTAssertEqual(
            try verifier(pinnedPair).verify(forged, local: local, context: context()),
            .badSignature)
    }

    func testCASAdvanceBindsExpectedRevisionDigestAndCheckpointPredecessor() throws {
        let pair = MythosCrypto.ed25519GenerateKeyPair()
        let currentCheckpoint = try checkpoint()
        let currentSigned = try signedWitness(
            checkpoint: currentCheckpoint, keyPair: pair, revision: 6)
        let currentAssessment = try verifier(pair).verify(
            currentSigned,
            local: currentCheckpoint,
            context: context(revision: 5, witnessDigest: digest("9")))
        guard case .anchored(let current) = currentAssessment else {
            return XCTFail("fixture must produce a verified current head")
        }
        let next = try checkpoint(
            lines: 11, bytes: 1_100, tail: "1", head: "2",
            fitnessEpoch: 4, corpus: "3", harness: "4", fitnessReceipt: "5",
            previousWitnessDigest: current.witnessDigest)
        let advanceChallenge = String(repeating: "d", count: 32)
        let request = try EvolutionRollbackCASAdvanceRequest(
            current: current,
            checkpoint: next,
            challenge: advanceChallenge)
        XCTAssertEqual(request.expectedRevision, 6)
        XCTAssertEqual(request.expectedWitnessDigest, next.previousWitnessDigest)
        XCTAssertEqual(request.anchorNamespaceDigest, anchorNamespaceDigest)

        XCTAssertThrowsError(try EvolutionRollbackCASAdvanceRequest(
            current: current,
            checkpoint: try checkpoint(
                lines: 11, bytes: 1_100,
                previousWitnessDigest: digest("8")),
            challenge: advanceChallenge)) { error in
            XCTAssertEqual(error as? EvolutionRollbackAnchorError, .priorWitnessMismatch)
        }

        XCTAssertThrowsError(try EvolutionRollbackCASAdvanceRequest(
            current: current,
            checkpoint: try checkpoint(previousWitnessDigest: current.witnessDigest),
            challenge: advanceChallenge)) { error in
            XCTAssertEqual(error as? EvolutionRollbackAnchorError, .nonMonotonicAdvance)
        }

        XCTAssertThrowsError(try EvolutionRollbackCASAdvanceRequest(
            current: current,
            checkpoint: next,
            challenge: challenge)) { error in
            XCTAssertEqual(error as? EvolutionRollbackAnchorError, .invalidChallenge)
        }
    }
}
