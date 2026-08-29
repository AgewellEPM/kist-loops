import Foundation

/// Construction failures for the external rollback-witness data contract.
public enum EvolutionRollbackAnchorError: Error, LocalizedError, Sendable, Equatable {
    case invalidDigest(field: String)
    case invalidIdentifier(field: String)
    case invalidChallenge
    case inconsistentArchiveCounts
    case invalidRevision
    case invalidIssueTime
    case priorWitnessMismatch
    case invalidSignatureEncoding
    case invalidPublicKey
    case duplicatePinnedKey(String)
    case invalidFreshnessPolicy
    case nonMonotonicAdvance

    public var errorDescription: String? {
        switch self {
        case .invalidDigest(let field):
            return "invalid lowercase SHA-256 digest for \(field)"
        case .invalidIdentifier(let field):
            return "invalid bounded identifier for \(field)"
        case .invalidChallenge:
            return "rollback-witness challenge must be 32...128 canonical ASCII characters"
        case .inconsistentArchiveCounts:
            return "archive line and byte counts are inconsistent"
        case .invalidRevision:
            return "external witness revision must be positive"
        case .invalidIssueTime:
            return "external witness issue time must be nonnegative"
        case .priorWitnessMismatch:
            return "statement and checkpoint name different prior witnesses"
        case .invalidSignatureEncoding:
            return "rollback-witness signature is not one canonical 64-byte Ed25519 signature"
        case .invalidPublicKey:
            return "pinned rollback-witness public key is malformed"
        case .duplicatePinnedKey(let keyID):
            return "duplicate pinned rollback-witness key ID: \(keyID)"
        case .invalidFreshnessPolicy:
            return "rollback-witness freshness policy is outside its bounded range"
        case .nonMonotonicAdvance:
            return "CAS proposal is not a strict non-regressing advance of its verified head"
        }
    }
}

private enum EvolutionRollbackAnchorValidation {
    static func requireDigest(_ value: String, field: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw EvolutionRollbackAnchorError.invalidDigest(field: field)
        }
    }

    static func requireIdentifier(_ value: String, field: String) throws {
        guard (1...64).contains(value.utf8.count),
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte)
                      || (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
              }) else {
            throw EvolutionRollbackAnchorError.invalidIdentifier(field: field)
        }
    }

    static func requireChallenge(_ value: String) throws {
        guard (32...128).contains(value.utf8.count),
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte)
                      || (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
              }) else {
            throw EvolutionRollbackAnchorError.invalidChallenge
        }
    }

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func digest(_ data: Data) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in MythosCrypto.sha256(data) {
            bytes.append(alphabet[Int(byte >> 4)])
            bytes.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Exact local state to compare with an externally held monotonic witness.
///
/// Every field is explicit and content-addressed. There is no implicit empty/genesis checkpoint: an
/// intentionally empty archive still needs a real signed checkpoint with explicit zero counts and digests.
public struct EvolutionRollbackCheckpoint: Codable, Sendable, Equatable {
    public let projectIdentityDigest: String
    public let archiveLineCount: UInt64
    public let archiveByteCount: UInt64
    public let archiveTailHash: String
    public let archiveHeadDigest: String
    public let fitnessEpoch: UInt64
    public let fitnessCorpusDigest: String
    public let fitnessHarnessDigest: String
    public let fitnessReceiptDigest: String
    public let previousWitnessDigest: String

    public init(projectIdentityDigest: String,
                archiveLineCount: UInt64,
                archiveByteCount: UInt64,
                archiveTailHash: String,
                archiveHeadDigest: String,
                fitnessEpoch: UInt64,
                fitnessCorpusDigest: String,
                fitnessHarnessDigest: String,
                fitnessReceiptDigest: String,
                previousWitnessDigest: String) throws {
        try EvolutionRollbackAnchorValidation.requireDigest(
            projectIdentityDigest, field: "checkpoint.projectIdentityDigest")
        let bothEmpty = archiveLineCount == 0 && archiveByteCount == 0
        let bothPopulated = archiveLineCount > 0
            && archiveByteCount >= archiveLineCount
        guard bothEmpty || bothPopulated else {
            throw EvolutionRollbackAnchorError.inconsistentArchiveCounts
        }
        try EvolutionRollbackAnchorValidation.requireDigest(
            archiveTailHash, field: "checkpoint.archiveTailHash")
        try EvolutionRollbackAnchorValidation.requireDigest(
            archiveHeadDigest, field: "checkpoint.archiveHeadDigest")
        try EvolutionRollbackAnchorValidation.requireDigest(
            fitnessCorpusDigest, field: "checkpoint.fitnessCorpusDigest")
        try EvolutionRollbackAnchorValidation.requireDigest(
            fitnessHarnessDigest, field: "checkpoint.fitnessHarnessDigest")
        try EvolutionRollbackAnchorValidation.requireDigest(
            fitnessReceiptDigest, field: "checkpoint.fitnessReceiptDigest")
        try EvolutionRollbackAnchorValidation.requireDigest(
            previousWitnessDigest, field: "checkpoint.previousWitnessDigest")
        self.projectIdentityDigest = projectIdentityDigest
        self.archiveLineCount = archiveLineCount
        self.archiveByteCount = archiveByteCount
        self.archiveTailHash = archiveTailHash
        self.archiveHeadDigest = archiveHeadDigest
        self.fitnessEpoch = fitnessEpoch
        self.fitnessCorpusDigest = fitnessCorpusDigest
        self.fitnessHarnessDigest = fitnessHarnessDigest
        self.fitnessReceiptDigest = fitnessReceiptDigest
        self.previousWitnessDigest = previousWitnessDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectIdentityDigest: container.decode(
                String.self, forKey: .projectIdentityDigest),
            archiveLineCount: container.decode(UInt64.self, forKey: .archiveLineCount),
            archiveByteCount: container.decode(UInt64.self, forKey: .archiveByteCount),
            archiveTailHash: container.decode(String.self, forKey: .archiveTailHash),
            archiveHeadDigest: container.decode(String.self, forKey: .archiveHeadDigest),
            fitnessEpoch: container.decode(UInt64.self, forKey: .fitnessEpoch),
            fitnessCorpusDigest: container.decode(
                String.self, forKey: .fitnessCorpusDigest),
            fitnessHarnessDigest: container.decode(
                String.self, forKey: .fitnessHarnessDigest),
            fitnessReceiptDigest: container.decode(
                String.self, forKey: .fitnessReceiptDigest),
            previousWitnessDigest: container.decode(
                String.self, forKey: .previousWitnessDigest))
    }

    public func canonicalData() throws -> Data {
        try EvolutionRollbackAnchorValidation.canonicalData(self)
    }

    public func bindingDigest() throws -> String {
        EvolutionRollbackAnchorValidation.digest(try canonicalData())
    }
}

/// Exact payload signed by the external witness holder. The issue time uses integral Unix seconds so its
/// canonical representation cannot contain a non-finite or platform-dependent floating-point value.
public struct EvolutionRollbackWitnessStatement: Codable, Sendable, Equatable {
    public static let currentSchema = "kist.evolution.rollback-witness.v1"

    public let schema: String
    /// Operator-pinned external register namespace, independent of movable/recreatable repo paths.
    public let anchorNamespaceDigest: String
    public let keyID: String
    public let revision: UInt64
    public let challenge: String
    public let issuedAtUnixSeconds: Int64
    public let checkpoint: EvolutionRollbackCheckpoint
    public let priorWitnessDigest: String

    public init(schema: String = EvolutionRollbackWitnessStatement.currentSchema,
                anchorNamespaceDigest: String,
                keyID: String,
                revision: UInt64,
                challenge: String,
                issuedAtUnixSeconds: Int64,
                checkpoint: EvolutionRollbackCheckpoint,
                priorWitnessDigest: String) throws {
        guard schema == Self.currentSchema else {
            throw EvolutionRollbackAnchorError.invalidIdentifier(field: "statement.schema")
        }
        try EvolutionRollbackAnchorValidation.requireDigest(
            anchorNamespaceDigest, field: "statement.anchorNamespaceDigest")
        try EvolutionRollbackAnchorValidation.requireIdentifier(keyID, field: "statement.keyID")
        guard revision > 0 else { throw EvolutionRollbackAnchorError.invalidRevision }
        try EvolutionRollbackAnchorValidation.requireChallenge(challenge)
        guard issuedAtUnixSeconds >= 0 else {
            throw EvolutionRollbackAnchorError.invalidIssueTime
        }
        try EvolutionRollbackAnchorValidation.requireDigest(
            priorWitnessDigest, field: "statement.priorWitnessDigest")
        guard priorWitnessDigest == checkpoint.previousWitnessDigest else {
            throw EvolutionRollbackAnchorError.priorWitnessMismatch
        }
        self.schema = schema
        self.anchorNamespaceDigest = anchorNamespaceDigest
        self.keyID = keyID
        self.revision = revision
        self.challenge = challenge
        self.issuedAtUnixSeconds = issuedAtUnixSeconds
        self.checkpoint = checkpoint
        self.priorWitnessDigest = priorWitnessDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(String.self, forKey: .schema),
            anchorNamespaceDigest: container.decode(
                String.self, forKey: .anchorNamespaceDigest),
            keyID: container.decode(String.self, forKey: .keyID),
            revision: container.decode(UInt64.self, forKey: .revision),
            challenge: container.decode(String.self, forKey: .challenge),
            issuedAtUnixSeconds: container.decode(Int64.self, forKey: .issuedAtUnixSeconds),
            checkpoint: container.decode(
                EvolutionRollbackCheckpoint.self, forKey: .checkpoint),
            priorWitnessDigest: container.decode(
                String.self, forKey: .priorWitnessDigest))
    }

    /// Canonical bytes covered by the external Ed25519 signature.
    public func canonicalPayload() throws -> Data {
        try EvolutionRollbackAnchorValidation.canonicalData(self)
    }

    /// Stable external current-head identity. Challenge, issue time, signer key, and signature are
    /// deliberately excluded so a fresh signed read response does not change the durable CAS identity.
    public func witnessDigest() throws -> String {
        let head = EvolutionRollbackStableHead(
            schema: "kist.evolution.rollback-head.v1",
            anchorNamespaceDigest: anchorNamespaceDigest,
            revision: revision,
            checkpoint: checkpoint,
            priorWitnessDigest: priorWitnessDigest)
        return EvolutionRollbackAnchorValidation.digest(
            try EvolutionRollbackAnchorValidation.canonicalData(head))
    }
}

private struct EvolutionRollbackStableHead: Encodable {
    let schema: String
    let anchorNamespaceDigest: String
    let revision: UInt64
    let checkpoint: EvolutionRollbackCheckpoint
    let priorWitnessDigest: String
}

/// A detached external Ed25519 signature over one exact witness statement.
public struct EvolutionSignedRollbackWitness: Codable, Sendable, Equatable {
    public let statement: EvolutionRollbackWitnessStatement
    public let signatureBase64: String

    public init(statement: EvolutionRollbackWitnessStatement,
                signatureBase64: String) throws {
        guard let signature = Data(base64Encoded: signatureBase64),
              signature.count == 64,
              signature.base64EncodedString() == signatureBase64 else {
            throw EvolutionRollbackAnchorError.invalidSignatureEncoding
        }
        self.statement = statement
        self.signatureBase64 = signatureBase64
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            statement: container.decode(
                EvolutionRollbackWitnessStatement.self, forKey: .statement),
            signatureBase64: container.decode(String.self, forKey: .signatureBase64))
    }

    public func canonicalData() throws -> Data {
        try EvolutionRollbackAnchorValidation.canonicalData(self)
    }

    /// Stable durable-head identity. A successor and CAS request bind this value; fresh challenge
    /// responses for the same revision intentionally return the same digest.
    public func witnessDigest() throws -> String {
        try statement.witnessDigest()
    }
}

/// Pinned external verification key. It contains public material only.
public struct EvolutionRollbackPinnedPublicKey: Sendable, Equatable {
    public let keyID: String
    public let publicKeyRaw: Data

    public init(keyID: String, publicKeyRaw: Data) throws {
        try EvolutionRollbackAnchorValidation.requireIdentifier(keyID, field: "pinnedKey.keyID")
        guard MythosCrypto.ed25519ValidPublicKey(publicKeyRaw) else {
            throw EvolutionRollbackAnchorError.invalidPublicKey
        }
        self.keyID = keyID
        self.publicKeyRaw = publicKeyRaw
    }
}

/// Bounded freshness window applied after signature verification.
public struct EvolutionRollbackFreshnessPolicy: Sendable, Equatable {
    public static let standard = EvolutionRollbackFreshnessPolicy(
        maximumAgeSeconds: 300,
        maximumFutureSkewSeconds: 30,
        validated: ())

    public let maximumAgeSeconds: Int64
    public let maximumFutureSkewSeconds: Int64

    public init(maximumAgeSeconds: Int64 = 300,
                maximumFutureSkewSeconds: Int64 = 30) throws {
        guard (1...604_800).contains(maximumAgeSeconds),
              (0...3_600).contains(maximumFutureSkewSeconds) else {
            throw EvolutionRollbackAnchorError.invalidFreshnessPolicy
        }
        self.maximumAgeSeconds = maximumAgeSeconds
        self.maximumFutureSkewSeconds = maximumFutureSkewSeconds
    }

    private init(maximumAgeSeconds: Int64,
                 maximumFutureSkewSeconds: Int64,
                 validated: Void) {
        self.maximumAgeSeconds = maximumAgeSeconds
        self.maximumFutureSkewSeconds = maximumFutureSkewSeconds
    }
}

/// Caller-owned monotonic cursor and one-use challenge. There is deliberately no default/root cursor.
public struct EvolutionRollbackVerificationContext: Sendable, Equatable {
    public let anchorNamespaceDigest: String
    public let expectedChallenge: String
    public let nowUnixSeconds: Int64
    public let lastAcceptedRevision: UInt64
    public let lastAcceptedWitnessDigest: String
    public let lastAcceptedChallengeDigest: String

    public init(anchorNamespaceDigest: String,
                expectedChallenge: String,
                nowUnixSeconds: Int64,
                lastAcceptedRevision: UInt64,
                lastAcceptedWitnessDigest: String,
                lastAcceptedChallengeDigest: String) throws {
        try EvolutionRollbackAnchorValidation.requireDigest(
            anchorNamespaceDigest, field: "context.anchorNamespaceDigest")
        try EvolutionRollbackAnchorValidation.requireChallenge(expectedChallenge)
        guard nowUnixSeconds >= 0 else { throw EvolutionRollbackAnchorError.invalidIssueTime }
        guard lastAcceptedRevision > 0 else {
            throw EvolutionRollbackAnchorError.invalidRevision
        }
        try EvolutionRollbackAnchorValidation.requireDigest(
            lastAcceptedWitnessDigest, field: "context.lastAcceptedWitnessDigest")
        try EvolutionRollbackAnchorValidation.requireDigest(
            lastAcceptedChallengeDigest, field: "context.lastAcceptedChallengeDigest")
        self.anchorNamespaceDigest = anchorNamespaceDigest
        self.expectedChallenge = expectedChallenge
        self.nowUnixSeconds = nowUnixSeconds
        self.lastAcceptedRevision = lastAcceptedRevision
        self.lastAcceptedWitnessDigest = lastAcceptedWitnessDigest
        self.lastAcceptedChallengeDigest = lastAcceptedChallengeDigest
    }

    public static func challengeDigest(_ challenge: String) throws -> String {
        try EvolutionRollbackAnchorValidation.requireChallenge(challenge)
        return EvolutionRollbackAnchorValidation.digest(Data(challenge.utf8))
    }
}

/// Strict request for an external current-head read.
public struct EvolutionRollbackCASReadRequest: Sendable, Equatable {
    public let anchorNamespaceDigest: String
    public let projectIdentityDigest: String
    public let challenge: String

    public init(anchorNamespaceDigest: String,
                projectIdentityDigest: String,
                challenge: String) throws {
        try EvolutionRollbackAnchorValidation.requireDigest(
            anchorNamespaceDigest, field: "casRead.anchorNamespaceDigest")
        try EvolutionRollbackAnchorValidation.requireDigest(
            projectIdentityDigest, field: "casRead.projectIdentityDigest")
        try EvolutionRollbackAnchorValidation.requireChallenge(challenge)
        self.anchorNamespaceDigest = anchorNamespaceDigest
        self.projectIdentityDigest = projectIdentityDigest
        self.challenge = challenge
    }
}

/// Proposed atomic head advance. Both revision and digest participate in the CAS comparison, preventing
/// stale writers and ABA-by-content. The external holder—not this runtime—issues and signs the result.
public struct EvolutionRollbackCASAdvanceRequest: Sendable, Equatable {
    public let anchorNamespaceDigest: String
    public let expectedRevision: UInt64
    public let expectedWitnessDigest: String
    public let checkpoint: EvolutionRollbackCheckpoint
    public let challenge: String

    public init(current: EvolutionVerifiedRollbackWitness,
                checkpoint: EvolutionRollbackCheckpoint,
                challenge: String) throws {
        let currentStatement = current.signedWitness.statement
        let currentCheckpoint = currentStatement.checkpoint
        guard checkpoint.previousWitnessDigest == current.witnessDigest else {
            throw EvolutionRollbackAnchorError.priorWitnessMismatch
        }
        guard checkpoint.projectIdentityDigest == currentCheckpoint.projectIdentityDigest,
              Self.isStrictAdvance(checkpoint, over: currentCheckpoint) else {
            throw EvolutionRollbackAnchorError.nonMonotonicAdvance
        }
        try EvolutionRollbackAnchorValidation.requireChallenge(challenge)
        guard EvolutionRollbackAnchorValidation.digest(Data(challenge.utf8))
                != current.challengeDigest else {
            throw EvolutionRollbackAnchorError.invalidChallenge
        }
        self.anchorNamespaceDigest = currentStatement.anchorNamespaceDigest
        self.expectedRevision = currentStatement.revision
        self.expectedWitnessDigest = current.witnessDigest
        self.checkpoint = checkpoint
        self.challenge = challenge
    }

    private static func isStrictAdvance(
        _ proposed: EvolutionRollbackCheckpoint,
        over current: EvolutionRollbackCheckpoint
    ) -> Bool {
        let archiveSame = proposed.archiveLineCount == current.archiveLineCount
            && proposed.archiveByteCount == current.archiveByteCount
            && proposed.archiveTailHash == current.archiveTailHash
            && proposed.archiveHeadDigest == current.archiveHeadDigest
        let archiveAhead = proposed.archiveLineCount > current.archiveLineCount
            && proposed.archiveByteCount > current.archiveByteCount
        let fitnessSame = proposed.fitnessEpoch == current.fitnessEpoch
            && proposed.fitnessCorpusDigest == current.fitnessCorpusDigest
            && proposed.fitnessHarnessDigest == current.fitnessHarnessDigest
            && proposed.fitnessReceiptDigest == current.fitnessReceiptDigest
        let fitnessAhead = proposed.fitnessEpoch > current.fitnessEpoch
        return (archiveSame || archiveAhead)
            && (fitnessSame || fitnessAhead)
            && (archiveAhead || fitnessAhead)
    }
}

/// Boundary for an operator-supplied external atomic current-head register. AgentCore ships no local-file or
/// network implementation. In particular, the verifier below never calls `compareAndSwap`; advancement must be
/// an explicitly authorized workflow outside this slice.
public protocol EvolutionRollbackExternalCASClient: Sendable {
    func readCurrent(
        _ request: EvolutionRollbackCASReadRequest
    ) async throws -> EvolutionSignedRollbackWitness

    func compareAndSwap(
        _ request: EvolutionRollbackCASAdvanceRequest
    ) async throws -> EvolutionSignedRollbackWitness
}

/// A witness that passed pinned-key signature verification. Only the verifier in this file can mint one.
public struct EvolutionVerifiedRollbackWitness: Sendable, Equatable {
    public let signedWitness: EvolutionSignedRollbackWitness
    public let witnessDigest: String
    public let challengeDigest: String
    public let verifiedKeyID: String

    fileprivate init(signedWitness: EvolutionSignedRollbackWitness,
                     witnessDigest: String,
                     challengeDigest: String,
                     verifiedKeyID: String) {
        self.signedWitness = signedWitness
        self.witnessDigest = witnessDigest
        self.challengeDigest = challengeDigest
        self.verifiedKeyID = verifiedKeyID
    }
}

/// Complete fail-closed classification. Only the first four cases contain a signature-verified witness.
public enum EvolutionRollbackAnchorAssessment: Sendable, Equatable {
    case anchored(EvolutionVerifiedRollbackWitness)
    case localAheadUnanchored(EvolutionVerifiedRollbackWitness)
    case witnessAheadRollback(EvolutionVerifiedRollbackWitness)
    case mismatch(EvolutionVerifiedRollbackWitness)
    case unavailable
    case stale
    case badSignature
    case replay
    case challengeMismatch
}

/// Pinned-key, freshness, replay, continuity, and local-vs-external state verifier.
public struct EvolutionRollbackWitnessVerifier: Sendable {
    private let publicKeys: [String: Data]
    private let freshness: EvolutionRollbackFreshnessPolicy

    public init(pinnedKeys: [EvolutionRollbackPinnedPublicKey],
                freshness: EvolutionRollbackFreshnessPolicy = .standard) throws {
        var keys: [String: Data] = [:]
        for key in pinnedKeys {
            guard keys[key.keyID] == nil else {
                throw EvolutionRollbackAnchorError.duplicatePinnedKey(key.keyID)
            }
            keys[key.keyID] = key.publicKeyRaw
        }
        self.publicKeys = keys
        self.freshness = freshness
    }

    public var isEmpty: Bool { publicKeys.isEmpty }

    public func verify(
        _ signed: EvolutionSignedRollbackWitness,
        local: EvolutionRollbackCheckpoint,
        context: EvolutionRollbackVerificationContext
    ) -> EvolutionRollbackAnchorAssessment {
        let statement = signed.statement
        guard let publicKey = publicKeys[statement.keyID],
              let signature = Data(base64Encoded: signed.signatureBase64),
              signature.count == 64,
              signature.base64EncodedString() == signed.signatureBase64,
              (try? statement.canonicalPayload()).map({ payload in
                  MythosCrypto.ed25519Verify(
                      signature: signature, message: payload, publicKeyRaw: publicKey)
              }) == true,
              let witnessDigest = try? signed.witnessDigest() else {
            return .badSignature
        }
        let challengeDigest = EvolutionRollbackAnchorValidation.digest(
            Data(statement.challenge.utf8))

        let verified = EvolutionVerifiedRollbackWitness(
            signedWitness: signed,
            witnessDigest: witnessDigest,
            challengeDigest: challengeDigest,
            verifiedKeyID: statement.keyID)
        guard statement.anchorNamespaceDigest == context.anchorNamespaceDigest else {
            return .mismatch(verified)
        }
        guard statement.checkpoint.projectIdentityDigest == local.projectIdentityDigest else {
            return .mismatch(verified)
        }
        guard statement.revision >= context.lastAcceptedRevision else {
            return .replay
        }
        guard challengeDigest != context.lastAcceptedChallengeDigest else { return .replay }
        guard statement.challenge == context.expectedChallenge else {
            return .challengeMismatch
        }
        guard isFresh(statement.issuedAtUnixSeconds, now: context.nowUnixSeconds) else {
            return .stale
        }

        let relation = Self.relation(local: local, witness: statement.checkpoint)
        let isCurrentHead = statement.revision == context.lastAcceptedRevision
            && witnessDigest == context.lastAcceptedWitnessDigest
        if statement.revision == context.lastAcceptedRevision, !isCurrentHead {
            return .mismatch(verified)
        }
        let (nextRevision, overflowed) = context.lastAcceptedRevision.addingReportingOverflow(1)
        let isDirectSuccessor = !overflowed
            && statement.revision == nextRevision
            && statement.priorWitnessDigest == context.lastAcceptedWitnessDigest
        switch relation {
        case .exact:
            guard isCurrentHead || isDirectSuccessor else {
                return .mismatch(verified)
            }
            return .anchored(verified)
        case .localAhead:
            guard isCurrentHead,
                  local.previousWitnessDigest == witnessDigest else {
                return .mismatch(verified)
            }
            return .localAheadUnanchored(verified)
        case .witnessAhead:
            // A valid external state strictly dominates the supplied local checkpoint. This stays a
            // rollback classification even when the local cursor was rolled back in coordination with
            // local archive bytes and therefore no longer names the external prior witness.
            return .witnessAheadRollback(verified)
        case .mismatch:
            return .mismatch(verified)
        }
    }

    private func isFresh(_ issued: Int64, now: Int64) -> Bool {
        if issued > now {
            return issued - now <= freshness.maximumFutureSkewSeconds
        }
        return now - issued <= freshness.maximumAgeSeconds
    }

    private enum Relation {
        case exact
        case localAhead
        case witnessAhead
        case mismatch
    }

    private enum Direction {
        case same
        case localAhead
        case witnessAhead
        case mismatch
    }

    private static func relation(
        local: EvolutionRollbackCheckpoint,
        witness: EvolutionRollbackCheckpoint
    ) -> Relation {
        guard local.projectIdentityDigest == witness.projectIdentityDigest else { return .mismatch }
        let archive = archiveDirection(local: local, witness: witness)
        let fitness = fitnessDirection(local: local, witness: witness)
        guard archive != .mismatch, fitness != .mismatch else { return .mismatch }

        if archive == .same, fitness == .same {
            return local == witness ? .exact : .mismatch
        }
        if archive != .witnessAhead, fitness != .witnessAhead {
            return .localAhead
        }
        if archive != .localAhead, fitness != .localAhead {
            return .witnessAhead
        }
        return .mismatch
    }

    private static func archiveDirection(
        local: EvolutionRollbackCheckpoint,
        witness: EvolutionRollbackCheckpoint
    ) -> Direction {
        if local.archiveLineCount == witness.archiveLineCount,
           local.archiveByteCount == witness.archiveByteCount {
            return local.archiveTailHash == witness.archiveTailHash
                && local.archiveHeadDigest == witness.archiveHeadDigest ? .same : .mismatch
        }
        if local.archiveLineCount > witness.archiveLineCount,
           local.archiveByteCount > witness.archiveByteCount {
            return .localAhead
        }
        if local.archiveLineCount < witness.archiveLineCount,
           local.archiveByteCount < witness.archiveByteCount {
            return .witnessAhead
        }
        return .mismatch
    }

    private static func fitnessDirection(
        local: EvolutionRollbackCheckpoint,
        witness: EvolutionRollbackCheckpoint
    ) -> Direction {
        if local.fitnessEpoch == witness.fitnessEpoch {
            return local.fitnessCorpusDigest == witness.fitnessCorpusDigest
                && local.fitnessHarnessDigest == witness.fitnessHarnessDigest
                && local.fitnessReceiptDigest == witness.fitnessReceiptDigest ? .same : .mismatch
        }
        return local.fitnessEpoch > witness.fitnessEpoch ? .localAhead : .witnessAhead
    }
}

/// Read-only use of an injected external CAS boundary. Transport/storage errors are classified as unavailable;
/// they never manufacture an empty witness. This type has no method that advances the CAS head.
public struct EvolutionRollbackAnchor: Sendable {
    private let client: any EvolutionRollbackExternalCASClient
    private let verifier: EvolutionRollbackWitnessVerifier

    public init(client: any EvolutionRollbackExternalCASClient,
                verifier: EvolutionRollbackWitnessVerifier) {
        self.client = client
        self.verifier = verifier
    }

    public func assess(
        local: EvolutionRollbackCheckpoint,
        context: EvolutionRollbackVerificationContext
    ) async -> EvolutionRollbackAnchorAssessment {
        do {
            let request = try EvolutionRollbackCASReadRequest(
                anchorNamespaceDigest: context.anchorNamespaceDigest,
                projectIdentityDigest: local.projectIdentityDigest,
                challenge: context.expectedChallenge)
            let signed = try await client.readCurrent(request)
            return verifier.verify(signed, local: local, context: context)
        } catch {
            return .unavailable
        }
    }
}
