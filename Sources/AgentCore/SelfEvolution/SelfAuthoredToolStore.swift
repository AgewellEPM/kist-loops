import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SelfAuthoredToolStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidNamespace(String)
    case unsafePath(String)
    case invalidReview(String)
    case invalidEvidenceDigest(String)
    case invalidContainment(String)
    case replayedContainmentScope(String)
    case destinationExists(String)
    case unsafeArtifact(String)
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidNamespace(let value):
            return "‘\(value)’ is not in the self__ namespace"
        case .unsafePath(let value):
            return "unsafe self-authored tool path: \(value)"
        case .invalidReview(let value):
            return "self-authored activation review is invalid: \(value)"
        case .invalidEvidenceDigest(let value):
            return "self-authored activation evidence digest is invalid: \(value)"
        case .invalidContainment(let value):
            return "self-authored activation hard containment is invalid: \(value)"
        case .replayedContainmentScope(let value):
            return "self-authored activation hard-containment scope was already consumed: \(value)"
        case .destinationExists(let value):
            return "self-authored activation destination already exists: \(value)"
        case .unsafeArtifact(let value):
            return "unsafe self-authored activation artifact: \(value)"
        case .system(let operation, let code):
            return "\(operation): \(String(cString: strerror(code)))"
        }
    }
}

/// Honest production status for identity-distinct evolution review authority. Provider/model strings and a
/// fresh UUID are not actual-route evidence. Until ProviderRegistry exposes a host-pinned completion receipt
/// that binds the resolved backend, model lineage, prompt and response, production cannot mint this value.
public struct IdentityDistinctEvolutionReviewAvailability: Sendable, Equatable {
    public let available: Bool
    public let reason: String

    fileprivate init(available: Bool, reason: String) {
        self.available = available
        self.reason = reason
    }
}

public enum IdentityDistinctEvolutionReviewValidationError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case invalidReview(String)
    case invalidDigest(String)
    case invalidTime

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .invalidReview(let reason): return "invalid identity-distinct evolution review: \(reason)"
        case .invalidDigest(let field): return "invalid identity-distinct review digest: \(field)"
        case .invalidTime: return "invalid identity-distinct review validation time"
        }
    }
}

/// Opaque activation input. It is intentionally non-Codable and has no public initializer: raw
/// `EvolutionReviewReceipt` values are process prose, not authority. A future production validator must mint
/// this only from host-owned actual-route/pinned invocation attestations.
public struct ValidatedIdentityDistinctEvolutionReview: Sendable, Equatable {
    fileprivate let review: EvolutionReviewReceipt
    fileprivate let reviewedPromotionEvidenceDigest: String
    fileprivate let actualRouteAttestationDigest: String
    fileprivate let attestationSource: String
    fileprivate let validationID: String
    fileprivate let validatedAtMillis: Int64

    fileprivate init(review: EvolutionReviewReceipt,
                     reviewedPromotionEvidenceDigest: String,
                     actualRouteAttestationDigest: String,
                     attestationSource: String,
                     validationID: String,
                     validatedAtMillis: Int64) {
        self.review = review
        self.reviewedPromotionEvidenceDigest = reviewedPromotionEvidenceDigest
        self.actualRouteAttestationDigest = actualRouteAttestationDigest
        self.attestationSource = attestationSource
        self.validationID = validationID
        self.validatedAtMillis = validatedAtMillis
    }
}

public enum IdentityDistinctEvolutionReviewValidator {
    private static let unavailableReason =
        "identity-distinct evolution review authority unavailable: no host-pinned actual-route invocation attestation source is wired"
    fileprivate static let testAttestationSource = "test-only:pinned-actual-route-attestation"

    public static var currentAvailability: IdentityDistinctEvolutionReviewAvailability {
        IdentityDistinctEvolutionReviewAvailability(available: false, reason: unavailableReason)
    }

    /// Production entry point. It deliberately cannot upgrade caller-authored strings into authority.
    public static func validate(
        _ review: EvolutionReviewReceipt,
        reviewedPromotionEvidenceDigest: String
    ) throws -> ValidatedIdentityDistinctEvolutionReview {
        _ = review
        _ = reviewedPromotionEvidenceDigest
        throw IdentityDistinctEvolutionReviewValidationError.unavailable(unavailableReason)
    }

    #if DEBUG
    /// Internal, debug-build-only test seam. It preserves a real opaque boundary for external callers while
    /// allowing `@testable` contract tests to exercise sealed persistence. Release builds contain no raw-value
    /// constructor at all; a future production constructor must consume host-pinned route attestations.
    static func validateForTesting(
        _ review: EvolutionReviewReceipt,
        reviewedPromotionEvidenceDigest: String,
        actualRouteAttestationDigest: String,
        now: Date = Date()
    ) throws -> ValidatedIdentityDistinctEvolutionReview {
        try validateReviewFacts(review)
        guard isDigest(reviewedPromotionEvidenceDigest) else {
            throw IdentityDistinctEvolutionReviewValidationError.invalidDigest("reviewedPromotionEvidenceDigest")
        }
        guard isDigest(actualRouteAttestationDigest) else {
            throw IdentityDistinctEvolutionReviewValidationError.invalidDigest("actualRouteAttestationDigest")
        }
        let millis = (now.timeIntervalSince1970 * 1_000).rounded(.down)
        guard millis.isFinite, millis > 0, millis <= Double(Int64.max) else {
            throw IdentityDistinctEvolutionReviewValidationError.invalidTime
        }
        return ValidatedIdentityDistinctEvolutionReview(
            review: review,
            reviewedPromotionEvidenceDigest: reviewedPromotionEvidenceDigest,
            actualRouteAttestationDigest: actualRouteAttestationDigest,
            attestationSource: testAttestationSource,
            validationID: UUID().uuidString.lowercased(),
            validatedAtMillis: Int64(millis))
    }
    #endif

    fileprivate static func validateReviewFacts(_ review: EvolutionReviewReceipt) throws {
        let author = review.authorIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let critic = review.criticIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func identityParts(_ value: String) -> (provider: Substring, model: Substring)? {
            guard value == value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let separator = value.firstIndex(of: ":"),
                  separator != value.startIndex,
                  separator != value.index(before: value.endIndex) else { return nil }
            return (value[..<separator], value[value.index(after: separator)...])
        }
        guard let authorParts = identityParts(author), let criticParts = identityParts(critic),
              review.grade == .independent, review.independent,
              review.freshConversation, review.separateInvocation,
              review.authorIdentity == author, review.criticIdentity == critic,
              author != critic, authorParts.provider != criticParts.provider,
              !review.authorInvocationID.isEmpty, !review.criticInvocationID.isEmpty,
              review.authorInvocationID != review.criticInvocationID else {
            throw IdentityDistinctEvolutionReviewValidationError.invalidReview(
                "independent/fresh/separate review with distinct canonical providers, identities and invocations is required")
        }
    }

    fileprivate static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

private struct SelfAuthoredProjectIdentity: Codable, Sendable, Equatable {
    let canonicalPath: String
    let deviceID: UInt64
    let inode: UInt64

    static func capture(_ projectRoot: String) throws -> Self {
        let standardized = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .standardizedFileURL.path
        guard standardized.hasPrefix("/"), let pointer = realpath(standardized, nil) else {
            throw SelfAuthoredToolStoreError.unsafePath("project root is not an existing absolute directory")
        }
        defer { free(pointer) }
        let resolved = String(cString: pointer)
        var info = stat()
        guard lstat(resolved, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == geteuid() else {
            throw SelfAuthoredToolStoreError.unsafePath("project root is not an owner-owned physical directory")
        }
        return Self(canonicalPath: resolved, deviceID: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

private struct SelfAuthoredContainmentBinding: Codable, Sendable, Equatable {
    let scopeID: String
    let executionDigest: String
    let mechanism: String
    let aggregateCPUTimeMicros: UInt64
    let aggregateMemoryBytes: UInt64
    let aggregateProcessCount: UInt32

    init(_ validated: ValidatedHardProcessContainment) {
        scopeID = validated.scopeID
        executionDigest = validated.executionDigest
        mechanism = validated.mechanism.rawValue
        aggregateCPUTimeMicros = validated.limits.aggregateCPUTimeMicros
        aggregateMemoryBytes = validated.limits.aggregateMemoryBytes
        aggregateProcessCount = validated.limits.aggregateProcessCount
    }
}

private struct SelfAuthoredReviewAuthorityBinding: Codable, Sendable, Equatable {
    let review: EvolutionReviewReceipt
    let reviewSHA256: String
    let reviewedPromotionEvidenceSHA256: String
    let actualRouteAttestationSHA256: String
    let attestationSource: String
    let validationID: String
    let validatedAtMillis: Int64

    init(_ validated: ValidatedIdentityDistinctEvolutionReview) throws {
        review = validated.review
        reviewSHA256 = SelfAuthoredActivationIO.sha256Hex(
            try SelfAuthoredActivationIO.canonicalData(validated.review))
        reviewedPromotionEvidenceSHA256 = validated.reviewedPromotionEvidenceDigest
        actualRouteAttestationSHA256 = validated.actualRouteAttestationDigest
        attestationSource = validated.attestationSource
        validationID = validated.validationID
        validatedAtMillis = validated.validatedAtMillis
    }
}

/// Second one-use boundary for hard containment. The hard-containment validator consumes its raw receipt, but
/// the returned value is an ordinary copyable Swift struct. Activation must therefore burn its scope again at
/// the point where it becomes durable authority. Consumption happens before any artifact write; a later
/// failure may burn the scope, which is safer than permitting replay.
private enum SelfAuthoredActivationScopeConsumer {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var consumedScopeIDs: Set<String> = []

    static func consume(_ scopeID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard consumedScopeIDs.insert(scopeID).inserted else {
            throw SelfAuthoredToolStoreError.replayedContainmentScope(scopeID)
        }
    }
}

/// Durable authority for one runtime-loadable self-authored tool. The seal is over every field except
/// `seal`; artifact bytes are covered by their SHA-256 digests, while the physical project identity prevents
/// copying a valid tool home into another checkout. This type deliberately remains private: callers receive
/// activation through `SelfAuthoredToolStore.savePromoted`, never by constructing receipt JSON themselves.
private struct SelfAuthoredActivationReceipt: Codable, Sendable, Equatable {
    static let schemaVersion = 2
    static let fileName = "activation.receipt.json"

    let schema: Int
    let project: SelfAuthoredProjectIdentity
    let toolName: String
    let manifestSHA256: String
    let scriptSHA256: String
    let reviewAuthority: SelfAuthoredReviewAuthorityBinding
    let reviewAuthoritySHA256: String
    let promotionEvidenceSHA256: String
    let smokeEvidenceSHA256: String
    let containment: SelfAuthoredContainmentBinding
    let issuedAtMillis: Int64
    let seal: String

    private struct Unsigned: Codable {
        let schema: Int
        let project: SelfAuthoredProjectIdentity
        let toolName: String
        let manifestSHA256: String
        let scriptSHA256: String
        let reviewAuthority: SelfAuthoredReviewAuthorityBinding
        let reviewAuthoritySHA256: String
        let promotionEvidenceSHA256: String
        let smokeEvidenceSHA256: String
        let containment: SelfAuthoredContainmentBinding
        let issuedAtMillis: Int64
    }

    init(project: SelfAuthoredProjectIdentity, toolName: String,
         manifestSHA256: String, scriptSHA256: String,
         reviewAuthority: SelfAuthoredReviewAuthorityBinding,
         reviewAuthoritySHA256: String,
         promotionEvidenceSHA256: String, smokeEvidenceSHA256: String,
         containment: SelfAuthoredContainmentBinding, issuedAtMillis: Int64) throws {
        let unsigned = Unsigned(
            schema: Self.schemaVersion, project: project, toolName: toolName,
            manifestSHA256: manifestSHA256, scriptSHA256: scriptSHA256,
            reviewAuthority: reviewAuthority,
            reviewAuthoritySHA256: reviewAuthoritySHA256,
            promotionEvidenceSHA256: promotionEvidenceSHA256,
            smokeEvidenceSHA256: smokeEvidenceSHA256,
            containment: containment, issuedAtMillis: issuedAtMillis)
        let canonical = String(decoding: try SelfAuthoredActivationIO.canonicalData(unsigned), as: UTF8.self)
        let generatedSeal = ForgeSeal.sign(canonical)
        guard !generatedSeal.isEmpty else {
            throw SelfAuthoredToolStoreError.unsafeArtifact("ForgeSeal key unavailable")
        }
        schema = Self.schemaVersion
        self.project = project
        self.toolName = toolName
        self.manifestSHA256 = manifestSHA256
        self.scriptSHA256 = scriptSHA256
        self.reviewAuthority = reviewAuthority
        self.reviewAuthoritySHA256 = reviewAuthoritySHA256
        self.promotionEvidenceSHA256 = promotionEvidenceSHA256
        self.smokeEvidenceSHA256 = smokeEvidenceSHA256
        self.containment = containment
        self.issuedAtMillis = issuedAtMillis
        seal = generatedSeal
    }

    func verifiesSealWithoutCreatingKey() -> Bool {
        let unsigned = Unsigned(
            schema: schema, project: project, toolName: toolName,
            manifestSHA256: manifestSHA256, scriptSHA256: scriptSHA256,
            reviewAuthority: reviewAuthority,
            reviewAuthoritySHA256: reviewAuthoritySHA256,
            promotionEvidenceSHA256: promotionEvidenceSHA256,
            smokeEvidenceSHA256: smokeEvidenceSHA256,
            containment: containment, issuedAtMillis: issuedAtMillis)
        guard let data = try? SelfAuthoredActivationIO.canonicalData(unsigned) else { return false }
        return ForgeSeal.verifyWithoutCreatingKey(String(decoding: data, as: UTF8.self), seal: seal)
    }
}

private enum SelfAuthoredActivationIO {
    static let maximumManifestBytes = 1_048_576
    static let maximumScriptBytes = 8 * 1_048_576
    static let maximumReceiptBytes = 1_048_576

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256Hex(_ data: Data) -> String {
        MythosCrypto.sha256(data).map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    static func openProject(_ identity: SelfAuthoredProjectIdentity) throws -> Int32 {
        let descriptor = open(identity.canonicalPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw system("open physical project root") }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              UInt64(info.st_dev) == identity.deviceID,
              UInt64(info.st_ino) == identity.inode else {
            _ = close(descriptor)
            throw SelfAuthoredToolStoreError.unsafePath("physical project identity changed")
        }
        return descriptor
    }

    static func openDirectory(parent: Int32, name: String, create: Bool,
                              exactMode: mode_t?, repairMode: Bool = false) throws -> Int32 {
        guard name == ".kist" || PathConfinement.safeComponent(name) != nil else {
            throw SelfAuthoredToolStoreError.unsafePath(name)
        }
        if create, mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST {
            throw system("create \(name) directory")
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw system("open \(name) directory") }
        if repairMode, let exactMode, fchmod(descriptor, exactMode) != 0 {
            let code = errno
            _ = close(descriptor)
            throw SelfAuthoredToolStoreError.system("secure \(name) directory", code)
        }
        var opened = stat()
        var named = stat()
        let inspected = fstat(descriptor, &opened) == 0
            && fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0
        let baseSafe = inspected
            && (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && (named.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && opened.st_uid == geteuid() && named.st_uid == geteuid()
            && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
            && (opened.st_mode & mode_t(0o022)) == 0
            && (named.st_mode & mode_t(0o022)) == 0
        let modeSafe = exactMode.map {
            (opened.st_mode & mode_t(0o777)) == $0 && (named.st_mode & mode_t(0o777)) == $0
        } ?? true
        guard baseSafe, modeSafe else {
            _ = close(descriptor)
            throw SelfAuthoredToolStoreError.unsafeArtifact("\(name) is not a stable owner-owned directory with safe permissions")
        }
        return descriptor
    }

    static func writeExclusive(_ data: Data, directory: Int32, name: String) throws {
        guard PathConfinement.safeComponent(name) != nil else {
            throw SelfAuthoredToolStoreError.unsafePath(name)
        }
        let descriptor = openat(
            directory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else { throw system("create \(name)") }
        var complete = false
        defer {
            _ = close(descriptor)
            if !complete { _ = unlinkat(directory, name, 0) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let amount = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw system("write \(name)")
                }
                guard amount > 0 else { throw SelfAuthoredToolStoreError.unsafeArtifact("short write to \(name)") }
                offset += amount
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
            throw system("sync \(name)")
        }
        complete = true
    }

    static func readSecure(directory: Int32, name: String, maximumBytes: Int) throws -> Data {
        guard PathConfinement.safeComponent(name) != nil else {
            throw SelfAuthoredToolStoreError.unsafePath(name)
        }
        let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw system("open \(name)") }
        defer { _ = close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == geteuid(), before.st_nlink == 1,
              (before.st_mode & mode_t(0o777)) == mode_t(0o600),
              before.st_size >= 0, before.st_size <= off_t(maximumBytes) else {
            throw SelfAuthoredToolStoreError.unsafeArtifact("\(name) is not a bounded owner-owned 0600 regular file")
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let amount = buffer.withUnsafeMutableBytes { raw -> Int in
                read(descriptor, raw.baseAddress, raw.count)
            }
            if amount < 0 {
                if errno == EINTR { continue }
                throw system("read \(name)")
            }
            if amount == 0 { break }
            data.append(contentsOf: buffer[0..<amount])
            guard data.count <= maximumBytes else {
                throw SelfAuthoredToolStoreError.unsafeArtifact("\(name) exceeds its size limit")
            }
        }
        var after = stat()
        var named = stat()
        guard fstat(descriptor, &after) == 0,
              fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              stableFile(before, after), stableFile(before, named),
              (after.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (named.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              after.st_uid == geteuid(), named.st_uid == geteuid(),
              after.st_nlink == 1, named.st_nlink == 1,
              (after.st_mode & mode_t(0o777)) == mode_t(0o600),
              (named.st_mode & mode_t(0o777)) == mode_t(0o600),
              data.count == Int(before.st_size) else {
            throw SelfAuthoredToolStoreError.unsafeArtifact("\(name) changed while it was read")
        }
        return data
    }

    static func stableFile(_ lhs: stat, _ rhs: stat) -> Bool {
        guard lhs.st_dev == rhs.st_dev, lhs.st_ino == rhs.st_ino,
              lhs.st_size == rhs.st_size else { return false }
        #if canImport(Darwin)
        return lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
        #else
        return lhs.st_mtim.tv_sec == rhs.st_mtim.tv_sec
            && lhs.st_mtim.tv_nsec == rhs.st_mtim.tv_nsec
            && lhs.st_ctim.tv_sec == rhs.st_ctim.tv_sec
            && lhs.st_ctim.tv_nsec == rhs.st_ctim.tv_nsec
        #endif
    }

    static func system(_ operation: String) -> SelfAuthoredToolStoreError {
        .system(operation, errno)
    }
}

/// Persists self-authored (`self__`) tools and loads them back as callable `ScriptTool`s. This is the
/// "activation" last-mile: a promoted candidate is written here, and at startup kist loads every stored
/// tool into its registry — runtime-loadable, no recompile (Phase 0 fork). Only the evolution loop's
/// PROMOTE path writes here; nothing else may add a self__ tool.
public struct SelfAuthoredToolStore {
    public let root: String   // <projectRoot>/.kist/self-tools
    private let projectRoot: String

    public init(projectRoot: String) {
        self.projectRoot = projectRoot
        self.root = (projectRoot as NSString).appendingPathComponent(".kist/self-tools")
    }

    /// Persist one promoted tool as a runtime-loadable activation. A neural review object is not authority by
    /// itself: it must describe an independent, fresh, separate, identity-distinct invocation, and it must be
    /// accompanied by a host-validated HARD process-containment value whose execution digest is the exact smoke
    /// evidence digest. `ValidatedHardProcessContainment` has no public initializer, so advisory child output
    /// and the current ProcessGroup runner cannot mint this authority.
    @discardableResult
    public func savePromoted(
        manifest: SelfAuthoredManifest,
        scriptBody: String,
        reviewAuthority: ValidatedIdentityDistinctEvolutionReview,
        promotionEvidenceDigest: String,
        smokeEvidenceDigest: String,
        containment: ValidatedHardProcessContainment,
        issuedAt: Date = Date()
    ) throws -> String {
        try Self.validate(manifest: manifest)
        guard SelfAuthoredActivationIO.isDigest(promotionEvidenceDigest) else {
            throw SelfAuthoredToolStoreError.invalidEvidenceDigest("promotion")
        }
        guard SelfAuthoredActivationIO.isDigest(smokeEvidenceDigest) else {
            throw SelfAuthoredToolStoreError.invalidEvidenceDigest("smoke")
        }
        guard containment.mechanism.isQualifyingHardBackend,
              containment.executionDigest == smokeEvidenceDigest,
              !containment.scopeID.isEmpty,
              containment.limits.aggregateCPUTimeMicros > 0,
              containment.limits.aggregateMemoryBytes > 0,
              containment.limits.aggregateProcessCount > 0 else {
            throw SelfAuthoredToolStoreError.invalidContainment(
                "qualifying mechanism and executionDigest == smokeEvidenceDigest are required")
        }
        let boundReview = try SelfAuthoredReviewAuthorityBinding(reviewAuthority)
        guard boundReview.reviewedPromotionEvidenceSHA256 == promotionEvidenceDigest else {
            throw SelfAuthoredToolStoreError.invalidReview(
                "identity-distinct review authority belongs to different promotion evidence")
        }
        guard Self.validate(reviewAuthority: boundReview, allowTestAuthority: true) else {
            throw SelfAuthoredToolStoreError.invalidReview(
                "opaque identity-distinct review authority failed its host binding contract")
        }
        let issuedDouble = (issuedAt.timeIntervalSince1970 * 1_000).rounded(.down)
        guard issuedDouble.isFinite, issuedDouble > 0, issuedDouble <= Double(Int64.max) else {
            throw SelfAuthoredToolStoreError.unsafeArtifact("invalid activation issue time")
        }
        let identity = try SelfAuthoredProjectIdentity.capture(projectRoot)
        let manifestData = try SelfAuthoredActivationIO.canonicalData(manifest)
        let scriptData = Data(scriptBody.utf8)
        let reviewAuthorityData = try SelfAuthoredActivationIO.canonicalData(boundReview)
        guard manifestData.count <= SelfAuthoredActivationIO.maximumManifestBytes,
              scriptData.count <= SelfAuthoredActivationIO.maximumScriptBytes else {
            throw SelfAuthoredToolStoreError.unsafeArtifact("activation artifact exceeds its size limit")
        }
        let receipt = try SelfAuthoredActivationReceipt(
            project: identity, toolName: manifest.name,
            manifestSHA256: SelfAuthoredActivationIO.sha256Hex(manifestData),
            scriptSHA256: SelfAuthoredActivationIO.sha256Hex(scriptData),
            reviewAuthority: boundReview,
            reviewAuthoritySHA256: SelfAuthoredActivationIO.sha256Hex(reviewAuthorityData),
            promotionEvidenceSHA256: promotionEvidenceDigest,
            smokeEvidenceSHA256: smokeEvidenceDigest,
            containment: SelfAuthoredContainmentBinding(containment),
            issuedAtMillis: Int64(issuedDouble))
        let receiptData = try SelfAuthoredActivationIO.canonicalData(receipt)
        guard receiptData.count <= SelfAuthoredActivationIO.maximumReceiptBytes else {
            throw SelfAuthoredToolStoreError.unsafeArtifact("activation receipt exceeds its size limit")
        }
        // Burn the validated execution scope immediately before the durable write. This lock is process-wide;
        // concurrent or later copies of the same opaque containment value cannot authorize another activation.
        try SelfAuthoredActivationScopeConsumer.consume(containment.scopeID)
        return try writeHome(
            identity: identity, manifest: manifest, manifestData: manifestData,
            scriptData: scriptData, receiptData: receiptData)
    }

    /// Internal test/candidate seam. It writes the same confined bytes but deliberately emits NO activation
    /// receipt, so `load()` can never turn it into a callable tool. Production callers in another module cannot
    /// access this method. Candidate-gate tests use it only as a convenient untrusted workdir writer.
    @discardableResult
    func stageForTesting(manifest: SelfAuthoredManifest, scriptBody: String) throws -> String {
        try Self.validate(manifest: manifest)
        let identity = try SelfAuthoredProjectIdentity.capture(projectRoot)
        return try writeHome(
            identity: identity, manifest: manifest,
            manifestData: SelfAuthoredActivationIO.canonicalData(manifest),
            scriptData: Data(scriptBody.utf8), receiptData: nil)
    }

    private func writeHome(identity: SelfAuthoredProjectIdentity,
                           manifest: SelfAuthoredManifest,
                           manifestData: Data, scriptData: Data,
                           receiptData: Data?) throws -> String {
        guard manifest.name.hasPrefix(kistSelfAuthoredPrefix) else {
            throw SelfAuthoredToolStoreError.invalidNamespace(manifest.name)
        }
        let projectFD = try SelfAuthoredActivationIO.openProject(identity)
        defer { _ = close(projectFD) }
        let kistFD = try SelfAuthoredActivationIO.openDirectory(
            parent: projectFD, name: ".kist", create: true, exactMode: nil)
        defer { _ = close(kistFD) }
        let storeFD = try SelfAuthoredActivationIO.openDirectory(
            parent: kistFD, name: "self-tools", create: true,
            exactMode: mode_t(0o700), repairMode: true)
        defer { _ = close(storeFD) }
        var existing = stat()
        if fstatat(storeFD, manifest.name, &existing, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
            throw SelfAuthoredToolStoreError.destinationExists(manifest.name)
        }
        guard mkdirat(storeFD, manifest.name, mode_t(0o700)) == 0 else {
            if errno == EEXIST { throw SelfAuthoredToolStoreError.destinationExists(manifest.name) }
            throw SelfAuthoredActivationIO.system("create self-authored tool home")
        }
        let homeFD: Int32
        do {
            homeFD = try SelfAuthoredActivationIO.openDirectory(
                parent: storeFD, name: manifest.name, create: false, exactMode: mode_t(0o700))
        } catch {
            _ = unlinkat(storeFD, manifest.name, AT_REMOVEDIR)
            throw error
        }
        var published = false
        defer {
            if !published {
                _ = unlinkat(homeFD, SelfAuthoredActivationReceipt.fileName, 0)
                _ = unlinkat(homeFD, "manifest.json", 0)
                _ = unlinkat(homeFD, manifest.scriptFile, 0)
            }
            _ = close(homeFD)
            if !published {
                _ = unlinkat(storeFD, manifest.name, AT_REMOVEDIR)
            }
        }
        try SelfAuthoredActivationIO.writeExclusive(scriptData, directory: homeFD, name: manifest.scriptFile)
        try SelfAuthoredActivationIO.writeExclusive(manifestData, directory: homeFD, name: "manifest.json")
        // Receipt is deliberately written LAST. A crash or failed write leaves, at worst, an unsigned home
        // that the loader ignores; authority can never precede the artifact bytes it binds.
        if let receiptData {
            try SelfAuthoredActivationIO.writeExclusive(
                receiptData, directory: homeFD, name: SelfAuthoredActivationReceipt.fileName)
        }
        guard fsync(homeFD) == 0, fsync(storeFD) == 0 else {
            throw SelfAuthoredActivationIO.system("sync self-authored activation")
        }
        published = true
        return (identity.canonicalPath as NSString)
            .appendingPathComponent(".kist/self-tools/\(manifest.name)")
    }

    /// Load only independently reviewed, hard-contained, ForgeSeal-authenticated activations. Legacy
    /// manifest/script pairs have no receipt and therefore load ZERO. One malformed home is skipped without
    /// weakening validation for its neighbours.
    public func load() -> [ScriptTool] {
        load(allowTestAuthority: false)
    }

    #if DEBUG
    /// Internal test-only loader for receipts minted through `validateForTesting`. Public runtime loading never
    /// accepts that authority source, including in debug builds. Keep the runtime guard as a second boundary so
    /// ordinary AgentCore debug code cannot opt itself into test activations merely because it has `internal`
    /// visibility.
    func loadForTesting() -> [ScriptTool] {
        let arguments = ProcessInfo.processInfo.arguments
        let executable = arguments.first ?? ""
        guard Bundle.main.bundleURL.pathExtension == "xctest"
                || URL(fileURLWithPath: executable).lastPathComponent == "xctest"
                || arguments.contains(where: { $0.contains(".xctest") }) else { return [] }
        return load(allowTestAuthority: true)
    }
    #endif

    private func load(allowTestAuthority: Bool) -> [ScriptTool] {
        guard let identity = try? SelfAuthoredProjectIdentity.capture(projectRoot),
              let projectFD = try? SelfAuthoredActivationIO.openProject(identity) else { return [] }
        defer { _ = close(projectFD) }
        guard let kistFD = try? SelfAuthoredActivationIO.openDirectory(
            parent: projectFD, name: ".kist", create: false, exactMode: nil) else { return [] }
        defer { _ = close(kistFD) }
        guard let storeFD = try? SelfAuthoredActivationIO.openDirectory(
            parent: kistFD, name: "self-tools", create: false, exactMode: mode_t(0o700)) else { return [] }
        defer { _ = close(storeFD) }
        let physicalRoot = (identity.canonicalPath as NSString).appendingPathComponent(".kist/self-tools")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: physicalRoot) else { return [] }
        var tools: [ScriptTool] = []
        for name in entries.sorted() where name.hasPrefix(kistSelfAuthoredPrefix) {
            guard PathConfinement.safeComponent(name) != nil,
                  let homeFD = try? SelfAuthoredActivationIO.openDirectory(
                    parent: storeFD, name: name, create: false, exactMode: mode_t(0o700)) else { continue }
            defer { _ = close(homeFD) }
            guard let manifestData = try? SelfAuthoredActivationIO.readSecure(
                    directory: homeFD, name: "manifest.json",
                    maximumBytes: SelfAuthoredActivationIO.maximumManifestBytes),
                  let receiptData = try? SelfAuthoredActivationIO.readSecure(
                    directory: homeFD, name: SelfAuthoredActivationReceipt.fileName,
                    maximumBytes: SelfAuthoredActivationIO.maximumReceiptBytes),
                  let manifest = try? JSONDecoder().decode(SelfAuthoredManifest.self, from: manifestData),
                  let receipt = try? JSONDecoder().decode(SelfAuthoredActivationReceipt.self, from: receiptData),
                  let canonicalManifest = try? SelfAuthoredActivationIO.canonicalData(manifest),
                  let canonicalReceipt = try? SelfAuthoredActivationIO.canonicalData(receipt),
                  canonicalManifest == manifestData, canonicalReceipt == receiptData,
                  manifest.name == name,
                  receipt.toolName == name,
                  (try? Self.validate(manifest: manifest)) != nil,
                  let scriptData = try? SelfAuthoredActivationIO.readSecure(
                    directory: homeFD, name: manifest.scriptFile,
                    maximumBytes: SelfAuthoredActivationIO.maximumScriptBytes),
                  Self.validate(
                    receipt: receipt, project: identity, manifestData: manifestData,
                    scriptData: scriptData, now: Date(),
                    allowTestAuthority: allowTestAuthority) else { continue }
            let home = (physicalRoot as NSString).appendingPathComponent(name)
            tools.append(ScriptTool(manifest: manifest, homeDir: home))
        }
        return tools
    }

    public func names() -> [String] { load().map { $0.name } }

    private static func validate(manifest: SelfAuthoredManifest) throws {
        guard manifest.name.hasPrefix(kistSelfAuthoredPrefix) else {
            throw SelfAuthoredToolStoreError.invalidNamespace(manifest.name)
        }
        guard PathConfinement.safeComponent(manifest.name) != nil,
              PathConfinement.safeComponent(manifest.scriptFile) != nil,
              manifest.scriptFile != "manifest.json",
              manifest.scriptFile != SelfAuthoredActivationReceipt.fileName else {
            throw SelfAuthoredToolStoreError.unsafePath(
                "\(manifest.name) / \(manifest.scriptFile)")
        }
    }

    private static func validate(reviewAuthority: SelfAuthoredReviewAuthorityBinding,
                                 allowTestAuthority: Bool) -> Bool {
        guard (try? IdentityDistinctEvolutionReviewValidator.validateReviewFacts(
                reviewAuthority.review)) != nil,
              let reviewData = try? SelfAuthoredActivationIO.canonicalData(reviewAuthority.review),
              reviewAuthority.reviewSHA256 == SelfAuthoredActivationIO.sha256Hex(reviewData),
              SelfAuthoredActivationIO.isDigest(
                reviewAuthority.reviewedPromotionEvidenceSHA256),
              SelfAuthoredActivationIO.isDigest(
                reviewAuthority.actualRouteAttestationSHA256),
              reviewAuthority.validatedAtMillis > 0,
              let validationUUID = UUID(uuidString: reviewAuthority.validationID),
              validationUUID.uuidString.lowercased() == reviewAuthority.validationID else { return false }

        // Schema v2 has no production attestation source. DEBUG builds accept only the projection minted by
        // the internal, debug-only test seam AND only when an explicitly test-only save/load path opts in.
        // Public load always passes false; release builds reject every v2 authority. A future real source must
        // add a new schema/validator instead of relabeling this test source.
        #if DEBUG
        guard allowTestAuthority,
              reviewAuthority.attestationSource
                == IdentityDistinctEvolutionReviewValidator.testAttestationSource else { return false }
        return true
        #else
        return false
        #endif
    }

    private static func validate(receipt: SelfAuthoredActivationReceipt,
                                 project: SelfAuthoredProjectIdentity,
                                 manifestData: Data, scriptData: Data,
                                 now: Date, allowTestAuthority: Bool) -> Bool {
        guard receipt.schema == SelfAuthoredActivationReceipt.schemaVersion,
              receipt.project == project,
              receipt.toolName.hasPrefix(kistSelfAuthoredPrefix),
              validate(
                reviewAuthority: receipt.reviewAuthority,
                allowTestAuthority: allowTestAuthority),
              let reviewAuthorityData = try? SelfAuthoredActivationIO.canonicalData(
                receipt.reviewAuthority),
              receipt.manifestSHA256 == SelfAuthoredActivationIO.sha256Hex(manifestData),
              receipt.scriptSHA256 == SelfAuthoredActivationIO.sha256Hex(scriptData),
              receipt.reviewAuthoritySHA256
                == SelfAuthoredActivationIO.sha256Hex(reviewAuthorityData),
              SelfAuthoredActivationIO.isDigest(receipt.promotionEvidenceSHA256),
              receipt.reviewAuthority.reviewedPromotionEvidenceSHA256
                == receipt.promotionEvidenceSHA256,
              SelfAuthoredActivationIO.isDigest(receipt.smokeEvidenceSHA256),
              SelfAuthoredActivationIO.isDigest(receipt.containment.executionDigest),
              receipt.containment.executionDigest == receipt.smokeEvidenceSHA256,
              receipt.containment.mechanism == HardProcessContainmentMechanism.linuxDelegatedCgroupV2.rawValue,
              !receipt.containment.scopeID.isEmpty,
              receipt.containment.aggregateCPUTimeMicros > 0,
              receipt.containment.aggregateMemoryBytes > 0,
              receipt.containment.aggregateProcessCount > 0,
              receipt.issuedAtMillis > 0,
              receipt.reviewAuthority.validatedAtMillis <= receipt.issuedAtMillis else { return false }
        let nowMillis = now.timeIntervalSince1970 * 1_000
        guard nowMillis.isFinite,
              Double(receipt.issuedAtMillis) <= nowMillis + 5 * 60 * 1_000 else { return false }
        return receipt.verifiesSealWithoutCreatingKey()
    }
}

/// P2 gate for a script candidate. Production `ScriptTool.runContained` currently refuses before execution
/// because no hard descendant/resource backend is wired, so every executable candidate remains quarantined.
/// A future gate must receive exact per-execution hard-containment authority through a separately typed path;
/// advisory sandbox output is never a pass or promotion receipt.
public struct ScriptCandidateGate: CandidateGate {
    public init() {}

    public func verify(_ candidate: CapabilityCandidate) async -> (passed: Bool, reason: String) {
        // Load whatever the author just wrote into the candidate workdir (manifest.json + script).
        guard let (manifest, scriptPath) = SelfAuthoredManifest.loadFrom(workdir: candidate.workdir) else {
            return (false, "candidate manifest/script missing in \(candidate.workdir)")
        }
        // An EMPTY expected-substring makes the check below vacuously true (`contains("")` == true), so a tool
        // with no real assertion would launder through the gate. Refuse it up-front — a self__ tool MUST carry a
        // non-empty expectation it can be proven against (review #1).
        guard !manifest.testExpectSubstring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "manifest.testExpectSubstring is empty — an unprovable tool, refused")
        }
        // Production execution is fail-closed until the exact run can return hard-containment authority.
        let cli = ScriptTool.cliArgs(from: manifest.testArgs, manifest: manifest)
        let r = await ScriptTool.runContained(interpreter: manifest.interpreter, scriptPath: scriptPath, args: cli)
        guard r.success else {
            return (false, "acceptance test did not run cleanly: \(r.error ?? "unknown")")
        }
        guard r.output.contains(manifest.testExpectSubstring) else {
            return (false, "acceptance test ran but output missing ‘\(manifest.testExpectSubstring)’ — got: \(r.output.prefix(200))")
        }
        return (true, "acceptance test passed under the contained runner")
    }
}
