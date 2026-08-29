import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct AcceptedRunProjectIdentitySnapshot: Sendable, Equatable {
    let requestedRoot: String
    let canonicalRoot: String
    let deviceID: UInt64
    let inode: UInt64
    let digest: String

    static func capture(projectRoot: String) throws -> Self {
        let requested = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .standardizedFileURL.path
        guard requested.hasPrefix("/"), let resolvedPointer = realpath(requested, nil) else {
            throw AcceptedRunReceiptError.invalidField("projectRoot")
        }
        defer { free(resolvedPointer) }
        let canonical = String(cString: resolvedPointer)
        let descriptor = open(canonical, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AcceptedRunReceiptError.invalidField("projectRoot")
        }
        defer { _ = close(descriptor) }
        var descriptorInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              lstat(canonical, &pathInfo) == 0,
              (descriptorInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              descriptorInfo.st_uid == getuid(), pathInfo.st_uid == getuid(),
              descriptorInfo.st_dev == pathInfo.st_dev,
              descriptorInfo.st_ino == pathInfo.st_ino else {
            throw AcceptedRunReceiptError.invalidField("projectRoot")
        }
        let device = UInt64(descriptorInfo.st_dev)
        let inode = UInt64(descriptorInfo.st_ino)
        let digest = try AcceptedRunReceipt.computeProjectIdentity(
            canonicalResolvedProjectPath: canonical,
            deviceDecimal: String(device), inodeDecimal: String(inode))
        let snapshot = Self(
            requestedRoot: requested, canonicalRoot: canonical,
            deviceID: device, inode: inode, digest: digest)
        guard try snapshot.isStillCurrent() else {
            throw AcceptedRunReceiptError.invalidField("projectRoot")
        }
        return snapshot
    }

    func isStillCurrent() throws -> Bool {
        let current = try Self.captureWithoutRecheck(projectRoot: requestedRoot)
        return current.canonicalRoot == canonicalRoot
            && current.deviceID == deviceID && current.inode == inode
    }

    private static func captureWithoutRecheck(projectRoot: String) throws -> Self {
        guard let resolvedPointer = realpath(projectRoot, nil) else {
            throw AcceptedRunReceiptError.invalidField("projectRoot")
        }
        defer { free(resolvedPointer) }
        let canonical = String(cString: resolvedPointer)
        let descriptor = open(canonical, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AcceptedRunReceiptError.invalidField("projectRoot")
        }
        defer { _ = close(descriptor) }
        var descriptorInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              lstat(canonical, &pathInfo) == 0,
              (descriptorInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              descriptorInfo.st_uid == getuid(), pathInfo.st_uid == getuid(),
              descriptorInfo.st_dev == pathInfo.st_dev,
              descriptorInfo.st_ino == pathInfo.st_ino else {
            throw AcceptedRunReceiptError.invalidField("projectRoot")
        }
        let device = UInt64(descriptorInfo.st_dev)
        let inode = UInt64(descriptorInfo.st_ino)
        return Self(
            requestedRoot: projectRoot, canonicalRoot: canonical,
            deviceID: device, inode: inode,
            digest: try AcceptedRunReceipt.computeProjectIdentity(
                canonicalResolvedProjectPath: canonical,
                deviceDecimal: String(device), inodeDecimal: String(inode)))
    }
}

/// Host-minted proof that one exact PlanExecute mission crossed the final deterministic-verification
/// and independent-review boundary. This is deliberately separate from `RunRecord`: the run ledger is
/// useful observability, but its plain JSON booleans are not a trust root.
///
/// The receipt is persisted at `.kist/accepted-run-receipts.jsonl`. Every field which can change the
/// meaning of acceptance is covered by the install-local ForgeSeal HMAC. Consumers must additionally
/// enforce freshness and reject duplicate receipts for the same run ID; a valid line copied twice is a
/// replay, not two votes.
public struct AcceptedRunReceipt: Codable, Sendable, Equatable {
    public static let currentSchema = "kist.accepted-run-receipt.v2"
    public static let legacySchema = "kist.accepted-run-receipt.v1"
    public static let trustedIssuer = "kist.host.builder-final-verifier"
    public static let defaultFreshness: TimeInterval = 24 * 60 * 60
    public static let maximumFreshnessMillis: Int64 = 86_400_000
    public static let allowedFutureSkewMillis: Int64 = 300_000
    public static let maximumVerificationSubjectBytes = 4_096
    public static let maximumContractIDBytes = 256
    public static let maximumExactGoalBytes = 1_048_576

    public enum Decision: String, Codable, Sendable {
        case accepted
        case rejected
    }

    public enum ReviewGrade: String, Codable, Sendable {
        case independentProvider = "independent-provider"
        case sameModel = "same-model"
        case unavailable
    }

    enum FreshnessStatus: Sendable, Equatable {
        case active
        case expired
    }

    /// The run/evidence values a consumer is expected to possess independently. The exact goal stays
    /// out of the receipt, but its SHA-256 binding is recomputed with the signed contract ID.
    public struct Binding: Sendable, Equatable {
        public let runID: String
        public let projectIdentity: String
        public let contractID: String
        public let exactGoal: String
        public let objectiveFingerprint: String
        public let verificationSubject: String
        public let verificationDigest: String
        public let ledgerRecordDigest: String

        public init(runID: String, contractID: String, exactGoal: String,
                    projectIdentity: String,
                    verificationSubject: String, verificationDigest: String,
                    ledgerRecordDigest: String) throws {
            try AcceptedRunReceipt.validateRunID(runID)
            try AcceptedRunReceipt.validateDigest(
                projectIdentity, field: "projectIdentity")
            try AcceptedRunReceipt.validateContractID(contractID)
            try AcceptedRunReceipt.validateExactGoal(exactGoal)
            try AcceptedRunReceipt.validateSubject(verificationSubject)
            try AcceptedRunReceipt.validateDigest(
                verificationDigest, field: "verificationDigest")
            try AcceptedRunReceipt.validateDigest(
                ledgerRecordDigest, field: "ledgerRecordDigest")
            self.runID = runID
            self.projectIdentity = projectIdentity
            self.contractID = contractID
            self.exactGoal = exactGoal
            self.objectiveFingerprint = try AcceptedRunReceipt.computeObjectiveFingerprint(
                contractID: contractID, exactGoal: exactGoal)
            self.verificationSubject = verificationSubject
            self.verificationDigest = verificationDigest
            self.ledgerRecordDigest = ledgerRecordDigest
        }
    }

    public let schema: String
    public let issuer: String
    public let runID: String
    /// Nil only when decoding a legacy v1 row. V1 can be inspected but never validates as active trust.
    public let projectIdentity: String?
    public let contractID: String
    public let objectiveFingerprint: String
    public let verificationSubject: String
    public let verificationDigest: String
    /// SHA-256 of the exact canonical RunRecord JSON line bytes, without its terminal newline.
    /// Nil only for legacy v1 receipts, which are intentionally non-green.
    public let ledgerRecordDigest: String?
    public let decision: Decision
    public let accepted: Bool
    public let reviewGrade: ReviewGrade
    public let independentReview: Bool
    public let issuedAtMillis: Int64
    public let validUntilMillis: Int64
    public let seal: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, issuer, runID, projectIdentity, contractID, objectiveFingerprint
        case verificationSubject, verificationDigest, ledgerRecordDigest
        case decision, accepted, reviewGrade, independentReview
        case issuedAtMillis, validUntilMillis, seal
    }

    private static let legacyCodingKeyNames: Set<String> = [
        "schema", "issuer", "runID", "contractID", "objectiveFingerprint",
        "verificationSubject", "verificationDigest", "decision", "accepted",
        "reviewGrade", "independentReview", "issuedAtMillis", "validUntilMillis", "seal",
    ]

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private init(schema: String, issuer: String, runID: String, projectIdentity: String?,
                 contractID: String,
                 objectiveFingerprint: String, verificationSubject: String,
                 verificationDigest: String, ledgerRecordDigest: String?,
                 decision: Decision, accepted: Bool,
                 reviewGrade: ReviewGrade, independentReview: Bool,
                 issuedAtMillis: Int64, validUntilMillis: Int64, seal: String) {
        self.schema = schema
        self.issuer = issuer
        self.runID = runID
        self.projectIdentity = projectIdentity
        self.contractID = contractID
        self.objectiveFingerprint = objectiveFingerprint
        self.verificationSubject = verificationSubject
        self.verificationDigest = verificationDigest
        self.ledgerRecordDigest = ledgerRecordDigest
        self.decision = decision
        self.accepted = accepted
        self.reviewGrade = reviewGrade
        self.independentReview = independentReview
        self.issuedAtMillis = issuedAtMillis
        self.validUntilMillis = validUntilMillis
        self.seal = seal
    }

    /// Strict decoding prevents unsigned extension fields from acquiring ambiguous meaning in another
    /// consumer. Any future meaning change must use a new schema rather than extending this v2 envelope.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        let actualKeys = Set(raw.allKeys.map(\.stringValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try values.decode(String.self, forKey: .schema)
        let expectedKeys = decodedSchema == Self.legacySchema
            ? Self.legacyCodingKeyNames : Set(CodingKeys.allCases.map(\.rawValue))
        guard actualKeys == expectedKeys else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "accepted-run receipt keys do not exactly match its schema"))
        }
        self.schema = decodedSchema
        self.issuer = try values.decode(String.self, forKey: .issuer)
        self.runID = try values.decode(String.self, forKey: .runID)
        self.projectIdentity = try values.decodeIfPresent(String.self, forKey: .projectIdentity)
        self.contractID = try values.decode(String.self, forKey: .contractID)
        self.objectiveFingerprint = try values.decode(String.self, forKey: .objectiveFingerprint)
        self.verificationSubject = try values.decode(String.self, forKey: .verificationSubject)
        self.verificationDigest = try values.decode(String.self, forKey: .verificationDigest)
        self.ledgerRecordDigest = try values.decodeIfPresent(
            String.self, forKey: .ledgerRecordDigest)
        self.decision = try values.decode(Decision.self, forKey: .decision)
        self.accepted = try values.decode(Bool.self, forKey: .accepted)
        self.reviewGrade = try values.decode(ReviewGrade.self, forKey: .reviewGrade)
        self.independentReview = try values.decode(Bool.self, forKey: .independentReview)
        self.issuedAtMillis = try values.decode(Int64.self, forKey: .issuedAtMillis)
        self.validUntilMillis = try values.decode(Int64.self, forKey: .validUntilMillis)
        self.seal = try values.decode(String.self, forKey: .seal)
    }

    /// There is intentionally no caller-selectable review grade: this API can mint only the signed
    /// `independent-provider` / `independentReview=true` form. Same-model fixture evidence must remain
    /// advisory and cannot be converted into an accepted-run receipt through this seam.
    static func mintAccepted(
        runID: String,
        projectIdentity: String,
        contractID: String,
        exactGoal: String,
        objectiveFingerprint: String,
        verificationSubject: String,
        verificationDigest: String,
        ledgerRecordDigest: String,
        issuedAt: Date = Date(),
        freshness: TimeInterval = AcceptedRunReceipt.defaultFreshness
    ) throws -> AcceptedRunReceipt {
        try validateRunID(runID)
        try validateDigest(projectIdentity, field: "projectIdentity")
        try validateContractID(contractID)
        try validateExactGoal(exactGoal)
        try validateDigest(objectiveFingerprint, field: "objectiveFingerprint")
        guard objectiveFingerprint == (try computeObjectiveFingerprint(
            contractID: contractID, exactGoal: exactGoal)) else {
            throw AcceptedRunReceiptError.bindingMismatch("objectiveFingerprint")
        }
        try validateSubject(verificationSubject)
        try validateDigest(verificationDigest, field: "verificationDigest")
        try validateDigest(ledgerRecordDigest, field: "ledgerRecordDigest")
        guard freshness.isFinite, freshness > 0 else {
            throw AcceptedRunReceiptError.invalidField("freshness")
        }
        let freshnessMillisDouble = (freshness * 1_000).rounded(.down)
        guard freshnessMillisDouble >= 1,
              freshnessMillisDouble <= Double(maximumFreshnessMillis) else {
            throw AcceptedRunReceiptError.invalidField("freshness")
        }
        let issuedDouble = (issuedAt.timeIntervalSince1970 * 1_000).rounded(.down)
        guard issuedDouble.isFinite, issuedDouble > 0,
              issuedDouble <= Double(Int64.max - maximumFreshnessMillis) else {
            throw AcceptedRunReceiptError.invalidField("issuedAtMillis")
        }
        let issued = Int64(issuedDouble)
        let validUntil = issued + Int64(freshnessMillisDouble)
        let unsigned = AcceptedRunReceipt(
            schema: currentSchema, issuer: trustedIssuer, runID: runID,
            projectIdentity: projectIdentity, contractID: contractID,
            objectiveFingerprint: objectiveFingerprint,
            verificationSubject: verificationSubject,
            verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest,
            decision: .accepted, accepted: true,
            reviewGrade: .independentProvider, independentReview: true,
            issuedAtMillis: issued, validUntilMillis: validUntil, seal: "")
        let seal = ForgeSeal.sign(unsigned.canonicalSigningString)
        guard isLowercaseHexDigest(seal) else {
            throw AcceptedRunReceiptError.sealUnavailable
        }
        return AcceptedRunReceipt(
            schema: unsigned.schema, issuer: unsigned.issuer, runID: unsigned.runID,
            projectIdentity: unsigned.projectIdentity,
            contractID: unsigned.contractID,
            objectiveFingerprint: unsigned.objectiveFingerprint,
            verificationSubject: unsigned.verificationSubject,
            verificationDigest: unsigned.verificationDigest,
            ledgerRecordDigest: unsigned.ledgerRecordDigest,
            decision: unsigned.decision, accepted: unsigned.accepted,
            reviewGrade: unsigned.reviewGrade, independentReview: unsigned.independentReview,
            issuedAtMillis: unsigned.issuedAtMillis,
            validUntilMillis: unsigned.validUntilMillis, seal: seal)
    }

    /// Cross-language canonical form used by both AgentCore and the Python dashboard. All lines are
    /// ASCII and there is no trailing newline. The one free-text value is RFC 4648 base64 of its exact
    /// UTF-8 bytes, so delimiter injection and Unicode escaping differences cannot alter the message.
    public var canonicalSigningString: String {
        let contractBase64 = Data(contractID.utf8).base64EncodedString()
        let subjectBase64 = Data(verificationSubject.utf8).base64EncodedString()
        var fields = [
            "schema=\(schema)",
            "issuer=\(issuer)",
            "runID=\(runID)",
        ]
        if schema != Self.legacySchema {
            fields.append("projectIdentity=\(projectIdentity ?? "missing")")
        }
        fields += [
            "contractIDBase64=\(contractBase64)",
            "objectiveFingerprint=\(objectiveFingerprint)",
            "verificationSubjectBase64=\(subjectBase64)",
            "verificationDigest=\(verificationDigest)",
        ]
        if schema != Self.legacySchema {
            fields.append("ledgerRecordDigest=\(ledgerRecordDigest ?? "missing")")
        }
        fields += [
            "decision=\(decision.rawValue)",
            "accepted=\(accepted ? "true" : "false")",
            "reviewGrade=\(reviewGrade.rawValue)",
            "independentReview=\(independentReview ? "true" : "false")",
            "issuedAtMillis=\(issuedAtMillis)",
            "validUntilMillis=\(validUntilMillis)",
        ]
        return fields.joined(separator: "\n")
    }

    /// Validate schema, concrete evidence, ForgeSeal authenticity, and acceptance semantics without
    /// treating historical age as an authenticity failure.
    private func validateSignedEnvelope() throws {
        try Self.validateRunID(runID)
        guard let projectIdentity else {
            throw AcceptedRunReceiptError.invalidField("projectIdentity")
        }
        try Self.validateDigest(projectIdentity, field: "projectIdentity")
        try Self.validateContractID(contractID)
        try Self.validateDigest(objectiveFingerprint, field: "objectiveFingerprint")
        try Self.validateSubject(verificationSubject)
        try Self.validateDigest(verificationDigest, field: "verificationDigest")
        guard let ledgerRecordDigest else {
            throw AcceptedRunReceiptError.invalidField("ledgerRecordDigest")
        }
        try Self.validateDigest(ledgerRecordDigest, field: "ledgerRecordDigest")
        guard Self.isLowercaseHexDigest(seal) else {
            throw AcceptedRunReceiptError.invalidSeal
        }

        let (lifetime, overflow) = validUntilMillis.subtractingReportingOverflow(issuedAtMillis)
        guard !overflow, issuedAtMillis > 0, lifetime > 0,
              lifetime <= Self.maximumFreshnessMillis else {
            throw AcceptedRunReceiptError.invalidField("freshness")
        }
        guard ForgeSeal.verifyWithoutCreatingKey(canonicalSigningString, seal: seal) else {
            throw AcceptedRunReceiptError.invalidSeal
        }
        guard schema == Self.currentSchema else {
            throw AcceptedRunReceiptError.invalidField("schema")
        }
        guard issuer == Self.trustedIssuer else {
            throw AcceptedRunReceiptError.invalidField("issuer")
        }
        guard decision == .accepted, accepted else {
            throw AcceptedRunReceiptError.invalidField("decision")
        }
        guard reviewGrade == .independentProvider, independentReview else {
            throw AcceptedRunReceiptError.invalidField("reviewGrade")
        }
    }

    func freshnessStatus(now: Date = Date()) throws -> FreshnessStatus {
        let nowDouble = (now.timeIntervalSince1970 * 1_000).rounded(.down)
        guard nowDouble.isFinite, nowDouble >= 0, nowDouble <= Double(Int64.max) else {
            throw AcceptedRunReceiptError.invalidField("now")
        }
        let nowMillis = Int64(nowDouble)
        guard issuedAtMillis <= nowMillis + Self.allowedFutureSkewMillis else {
            throw AcceptedRunReceiptError.notYetValid
        }
        return nowMillis <= validUntilMillis ? .active : .expired
    }

    /// Validate schema, concrete evidence, ForgeSeal authenticity, acceptance semantics, and freshness.
    public func validate(now: Date = Date()) throws {
        try validateSignedEnvelope()
        guard try freshnessStatus(now: now) == .active else {
            throw AcceptedRunReceiptError.expired
        }
    }

    /// Exact project/ledger/HMAC authority, deliberately separated from temporal freshness so
    /// read-only recall can distinguish authentic history from an active acceptance gate.
    func validateCryptographicBinding(matching binding: Binding) throws {
        try validateSignedEnvelope()
        guard runID == binding.runID else {
            throw AcceptedRunReceiptError.bindingMismatch("runID")
        }
        guard projectIdentity == binding.projectIdentity else {
            throw AcceptedRunReceiptError.bindingMismatch("projectIdentity")
        }
        guard contractID == binding.contractID else {
            throw AcceptedRunReceiptError.bindingMismatch("contractID")
        }
        guard objectiveFingerprint == binding.objectiveFingerprint else {
            throw AcceptedRunReceiptError.bindingMismatch("objectiveFingerprint")
        }
        guard verificationSubject == binding.verificationSubject else {
            throw AcceptedRunReceiptError.bindingMismatch("verificationSubject")
        }
        guard verificationDigest == binding.verificationDigest else {
            throw AcceptedRunReceiptError.bindingMismatch("verificationDigest")
        }
        guard ledgerRecordDigest == binding.ledgerRecordDigest else {
            throw AcceptedRunReceiptError.bindingMismatch("ledgerRecordDigest")
        }
    }

    public func validate(matching binding: Binding, now: Date = Date()) throws {
        try validateCryptographicBinding(matching: binding)
        guard try freshnessStatus(now: now) == .active else {
            throw AcceptedRunReceiptError.expired
        }
    }

    private static func validateRunID(_ value: String) throws {
        guard isLowercaseHexDigest(value) else {
            throw AcceptedRunReceiptError.invalidField("runID")
        }
    }

    /// Builder's objective identity is SHA-256 over the exact contract ID, one NUL delimiter, and the
    /// exact unnormalized goal bytes. Dashboard display cleanup must never feed this function.
    public static func computeObjectiveFingerprint(
        contractID: String, exactGoal: String
    ) throws -> String {
        try validateContractID(contractID)
        try validateExactGoal(exactGoal)
        return MythosCrypto.sha256(Data((contractID + "\u{0}" + exactGoal).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Bind acceptance to the active project object, not merely to evidence paths copied from another
    /// checkout. Symlink aliases intentionally resolve to the same canonical target; renaming that target
    /// or replacing its root directory changes the identity and leaves copied evidence non-green.
    public static func computeProjectIdentity(projectRoot: String) throws -> String {
        try AcceptedRunProjectIdentitySnapshot.capture(projectRoot: projectRoot).digest
    }

    /// Internal deterministic vector shared with dashboard tests. Runtime callers must use the
    /// filesystem-derived overload above rather than supplying device/inode claims themselves.
    static func computeProjectIdentity(
        canonicalResolvedProjectPath: String,
        deviceDecimal: String,
        inodeDecimal: String
    ) throws -> String {
        let pathComponents = canonicalResolvedProjectPath.split(
            separator: "/", omittingEmptySubsequences: false)
        let lexicallyCanonicalPath = canonicalResolvedProjectPath == "/"
            || (canonicalResolvedProjectPath.hasPrefix("/")
                && !canonicalResolvedProjectPath.hasSuffix("/")
                && !canonicalResolvedProjectPath.contains("//")
                && pathComponents.dropFirst().allSatisfy { $0 != "." && $0 != ".." })
        guard canonicalResolvedProjectPath.hasPrefix("/"),
              lexicallyCanonicalPath,
              !canonicalResolvedProjectPath.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.value == 10 || $0.value == 13
              }),
              !deviceDecimal.isEmpty, deviceDecimal.utf8.allSatisfy({ (48...57).contains($0) }),
              !inodeDecimal.isEmpty, inodeDecimal.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw AcceptedRunReceiptError.invalidField("projectIdentityMaterial")
        }
        let material = canonicalResolvedProjectPath + "\u{0}" + deviceDecimal
            + "\u{0}" + inodeDecimal
        return BuilderEvidenceDigest.sha256(material)
    }

    private static func validateContractID(_ value: String) throws {
        let bytes = value.utf8
        guard (1...maximumContractIDBytes).contains(bytes.count),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              bytes.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte)
                      || (97...122).contains(byte) || [45, 46, 58, 95].contains(byte)
              }) else {
            throw AcceptedRunReceiptError.invalidField("contractID")
        }
    }

    private static func validateExactGoal(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= maximumExactGoalBytes else {
            throw AcceptedRunReceiptError.invalidField("exactGoal")
        }
    }

    private static func validateDigest(_ value: String, field: String) throws {
        guard isLowercaseHexDigest(value) else {
            throw AcceptedRunReceiptError.invalidField(field)
        }
    }

    private static func validateSubject(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= maximumVerificationSubjectBytes,
              !value.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.value == 10 || $0.value == 13
              }) else {
            throw AcceptedRunReceiptError.invalidField("verificationSubject")
        }
    }

    private static func isLowercaseHexDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public enum AcceptedRunReceiptError: Error, Sendable, Equatable, LocalizedError {
    case invalidField(String)
    case sealUnavailable
    case invalidSeal
    case notYetValid
    case expired
    case bindingMismatch(String)
    case receiptNotFound
    case replayDetected
    case malformedStore
    case unsafeStore(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidField(let field): return "invalid accepted-run receipt field: \(field)"
        case .sealUnavailable: return "ForgeSeal key is unavailable"
        case .invalidSeal: return "accepted-run receipt ForgeSeal is invalid"
        case .notYetValid: return "accepted-run receipt is from the future"
        case .expired: return "accepted-run receipt is stale"
        case .bindingMismatch(let field): return "accepted-run receipt does not match \(field)"
        case .receiptNotFound: return "no accepted-run receipt matches this run"
        case .replayDetected: return "duplicate accepted-run receipts detected for this run"
        case .malformedStore: return "accepted-run receipt store is malformed"
        case .unsafeStore(let reason): return "unsafe accepted-run receipt store: \(reason)"
        case .io(let operation): return "accepted-run receipt store I/O failed: \(operation)"
        }
    }
}

/// Durable project-local store for accepted-run receipts. The append is a locked, atomic
/// read+append+rename transaction: readers see either the complete old JSONL or the complete new JSONL,
/// never a torn line, and cooperating processes cannot lose one another's receipt.
public struct AcceptedRunReceiptStore: Sendable {
    public static let relativePath = ".kist/accepted-run-receipts.jsonl"
    private static let maximumStoreBytes = 8 * 1_024 * 1_024

    public let fileURL: URL
    private var lockURL: URL { fileURL.appendingPathExtension("lock") }

    public init(projectRoot: String) {
        self.fileURL = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .standardizedFileURL
            .appendingPathComponent(Self.relativePath)
    }

    /// The Builder integration seam. Call this only after the host-owned final verification and
    /// provider-independent review have accepted; unavailable/non-digest evidence fails closed instead
    /// of minting dashboard trust. The underlying mint API has no same-model review mode.
    @discardableResult
    func mintAndAppendAccepted(
        runID: String,
        projectIdentity: String,
        contractID: String,
        exactGoal: String,
        objectiveFingerprint: String,
        verificationSubject: String,
        verificationDigest: String,
        ledgerRecordDigest: String,
        now: Date = Date(),
        freshness: TimeInterval = AcceptedRunReceipt.defaultFreshness
    ) throws -> AcceptedRunReceipt {
        let receipt = try AcceptedRunReceipt.mintAccepted(
            runID: runID, projectIdentity: projectIdentity,
            contractID: contractID, exactGoal: exactGoal,
            objectiveFingerprint: objectiveFingerprint,
            verificationSubject: verificationSubject,
            verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest,
            issuedAt: now, freshness: freshness)
        try append(receipt, now: now)
        return receipt
    }

    /// Resume-safe integration hook. The first call mints and appends one receipt. A resumed copy of
    /// the *same exact mission/evidence binding* returns that existing receipt instead of manufacturing
    /// a second vote. Any conflicting row or duplicate in the store remains fail-closed.
    @discardableResult
    func mintOrValidateAccepted(
        runID: String,
        projectIdentity: String,
        contractID: String,
        exactGoal: String,
        objectiveFingerprint: String,
        verificationSubject: String,
        verificationDigest: String,
        ledgerRecordDigest: String,
        now: Date = Date(),
        freshness: TimeInterval = AcceptedRunReceipt.defaultFreshness
    ) throws -> AcceptedRunReceipt {
        let binding = try AcceptedRunReceipt.Binding(
            runID: runID, contractID: contractID, exactGoal: exactGoal,
            projectIdentity: projectIdentity,
            verificationSubject: verificationSubject,
            verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest)
        guard binding.objectiveFingerprint == objectiveFingerprint else {
            throw AcceptedRunReceiptError.bindingMismatch("objectiveFingerprint")
        }
        return try withExclusiveLock {
            let existingData = try readDataUnlocked()
            let matchingRun = try decodeStore(existingData).filter { $0.runID == runID }
            if !matchingRun.isEmpty {
                guard matchingRun.count == 1 else {
                    throw AcceptedRunReceiptError.replayDetected
                }
                let existing = matchingRun[0]
                try existing.validate(matching: binding, now: now)
                return existing
            }

            let receipt = try AcceptedRunReceipt.mintAccepted(
                runID: runID, projectIdentity: projectIdentity,
                contractID: contractID, exactGoal: exactGoal,
                objectiveFingerprint: objectiveFingerprint,
                verificationSubject: verificationSubject,
                verificationDigest: verificationDigest,
                ledgerRecordDigest: ledgerRecordDigest,
                issuedAt: now, freshness: freshness)
            try appendUnlocked(receipt, to: existingData)
            return receipt
        }
    }

    func append(_ receipt: AcceptedRunReceipt, now: Date = Date()) throws {
        try receipt.validate(now: now)
        try withExclusiveLock {
            let existingData = try readDataUnlocked()
            let existing = try decodeStore(existingData)
            guard !existing.contains(where: { $0.runID == receipt.runID }) else {
                throw AcceptedRunReceiptError.replayDetected
            }
            try appendUnlocked(receipt, to: existingData)
        }
    }

    public func allReceipts() throws -> [AcceptedRunReceipt] {
        try withExclusiveLock {
            try decodeStore(readDataUnlocked())
        }
    }

    /// Strict read-only snapshot for projections. Atomic publishers plus descriptor/path stability
    /// make a reader lock unnecessary, and avoiding `withExclusiveLock` means a query never creates
    /// `.kist`, a lock file, or any other durable state.
    func strictReceiptsReadOnly() throws -> [AcceptedRunReceipt] {
        try decodeStore(readDataUnlocked())
    }

    /// A valid receipt may appear exactly once. Copying the same signed line twice is rejected as replay.
    public func validatedReceipt(
        matching binding: AcceptedRunReceipt.Binding,
        now: Date = Date()
    ) throws -> AcceptedRunReceipt {
        let candidates = try allReceipts().filter { $0.runID == binding.runID }
        guard !candidates.isEmpty else { throw AcceptedRunReceiptError.receiptNotFound }
        guard candidates.count == 1 else { throw AcceptedRunReceiptError.replayDetected }
        let receipt = candidates[0]
        try receipt.validate(matching: binding, now: now)
        return receipt
    }

    private func ensureStoreDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  info.st_uid == getuid(), (info.st_mode & mode_t(0o022)) == 0 else {
                throw AcceptedRunReceiptError.unsafeStore(".kist is not an owned directory")
            }
            return
        }
        guard errno == ENOENT else { throw AcceptedRunReceiptError.io("inspect .kist") }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw AcceptedRunReceiptError.io("create .kist")
        }
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == getuid(), (info.st_mode & mode_t(0o022)) == 0 else {
            throw AcceptedRunReceiptError.unsafeStore("created .kist is not an owned directory")
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try ensureStoreDirectory()
        let descriptor = open(
            lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AcceptedRunReceiptError.io("open lock") }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(), (info.st_mode & mode_t(0o077)) == 0 else {
            throw AcceptedRunReceiptError.unsafeStore("lock is not an owner-only regular file")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw AcceptedRunReceiptError.io("lock store")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func readDataUnlocked() throws -> Data {
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return Data() }
            throw AcceptedRunReceiptError.io("open store")
        }
        defer { _ = close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == getuid(), (before.st_mode & mode_t(0o077)) == 0 else {
            throw AcceptedRunReceiptError.unsafeStore("receipt file is not owner-only regular data")
        }
        guard before.st_size >= 0, before.st_size <= off_t(Self.maximumStoreBytes) else {
            throw AcceptedRunReceiptError.io("store size limit")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            let data = try handle.readToEnd() ?? Data()
            guard data.count <= Self.maximumStoreBytes else {
                throw AcceptedRunReceiptError.io("store size limit")
            }
            var after = stat()
            var pathInfo = stat()
            guard fstat(descriptor, &after) == 0,
                  lstat(fileURL.path, &pathInfo) == 0,
                  (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size,
                  before.st_dev == pathInfo.st_dev, before.st_ino == pathInfo.st_ino,
                  before.st_size == pathInfo.st_size,
                  off_t(data.count) == before.st_size else {
                throw AcceptedRunReceiptError.io("store changed while reading")
            }
            return data
        } catch let error as AcceptedRunReceiptError {
            throw error
        } catch {
            throw AcceptedRunReceiptError.io("read store")
        }
    }

    private func decodeStore(_ data: Data) throws -> [AcceptedRunReceipt] {
        guard !data.isEmpty else { return [] }
        guard data.last == 0x0A else { throw AcceptedRunReceiptError.malformedStore }
        let decoder = JSONDecoder()
        var receipts: [AcceptedRunReceipt] = []
        var seenRunIDs = Set<String>()
        for bytes in data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
            let line = Data(bytes)
            guard !line.isEmpty,
                  let receipt = try? decoder.decode(AcceptedRunReceipt.self, from: line),
                  let canonical = try? canonicalLine(receipt), canonical == line else {
                throw AcceptedRunReceiptError.malformedStore
            }
            guard seenRunIDs.insert(receipt.runID).inserted else {
                // Count every structurally canonical duplicate before seal/freshness validation. One
                // valid row plus an invalid or expired copied row is still replay ambiguity.
                throw AcceptedRunReceiptError.replayDetected
            }
            receipts.append(receipt)
        }
        return receipts
    }

    private func canonicalLine(_ receipt: AcceptedRunReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(receipt)
    }

    private func appendUnlocked(_ receipt: AcceptedRunReceipt, to existingData: Data) throws {
        var line = try canonicalLine(receipt)
        line.append(0x0A)
        guard existingData.count <= Self.maximumStoreBytes - line.count else {
            throw AcceptedRunReceiptError.io("store size limit")
        }
        var replacement = existingData
        replacement.append(line)
        try writeAtomicUnlocked(replacement)
    }

    private func writeAtomicUnlocked(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        var descriptor = open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else { throw AcceptedRunReceiptError.io("create temporary") }
        var published = false
        defer {
            if descriptor >= 0 { _ = close(descriptor) }
            if !published { _ = unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AcceptedRunReceiptError.io("write temporary")
                }
                guard written > 0 else {
                    throw AcceptedRunReceiptError.io("short write temporary")
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw AcceptedRunReceiptError.io("sync temporary")
        }
        guard close(descriptor) == 0 else {
            descriptor = -1
            throw AcceptedRunReceiptError.io("close temporary")
        }
        descriptor = -1
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw AcceptedRunReceiptError.io("publish store")
        }
        published = true
        let directoryDescriptor = open(
            directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else {
            throw AcceptedRunReceiptError.io("open store directory")
        }
        defer { _ = close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw AcceptedRunReceiptError.io("sync store directory")
        }
    }
}
