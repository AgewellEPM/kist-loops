import Foundation

/// The operating-system family that produced hard-containment evidence. This is bound into the
/// receipt so Linux-only cgroup evidence can never be replayed as a macOS containment claim.
public enum HardProcessContainmentPlatform: String, Sendable, Equatable {
    case macOS
    case linux
    case unsupported

    public static var current: Self {
        #if os(macOS)
        return .macOS
        #elseif os(Linux)
        return .linux
        #else
        return .unsupported
        #endif
    }
}

/// A mechanism name is not proof by itself. The classification is fixed by AgentCore rather than
/// supplied as a boolean by a child process, so advisory cleanup cannot relabel itself as hard.
public enum HardProcessContainmentMechanism: String, CaseIterable, Sendable, Equatable {
    case processGroup = "process-group"
    case macOSSeatbeltProcessGroup = "macos-seatbelt+process-group"
    case linuxBubblewrapProcessGroup = "linux-bubblewrap+process-group"
    case linuxDelegatedCgroupV2 = "linux-delegated-cgroup-v2"

    public var isQualifyingHardBackend: Bool {
        self == .linuxDelegatedCgroupV2
    }

    fileprivate var requiredPlatform: HardProcessContainmentPlatform? {
        switch self {
        case .processGroup: return nil
        case .macOSSeatbeltProcessGroup: return .macOS
        case .linuxBubblewrapProcessGroup, .linuxDelegatedCgroupV2: return .linux
        }
    }
}

/// Honest runtime status for the code that exists today. This does not probe or activate anything;
/// it prevents a caller from mistaking an advisory sandbox/process group for a production backend.
public struct HardProcessContainmentAvailability: Sendable, Equatable {
    public let available: Bool
    public let platform: HardProcessContainmentPlatform
    public let mechanism: HardProcessContainmentMechanism?
    public let reason: String

    fileprivate init(available: Bool, platform: HardProcessContainmentPlatform,
                     mechanism: HardProcessContainmentMechanism?, reason: String) {
        self.available = available
        self.platform = platform
        self.mechanism = mechanism
        self.reason = reason
    }
}

public enum HardProcessContainmentRuntime {
    /// No qualifying backend is currently wired into `ProcessGroupRunner`. In particular, Seatbelt
    /// constrains selected operations but does not provide aggregate CPU/RAM/PID accounting or an
    /// unescapable descendant scope, while the current Linux path has no delegated cgroup-v2 owner.
    public static var currentAvailability: HardProcessContainmentAvailability {
        switch HardProcessContainmentPlatform.current {
        case .macOS:
            return HardProcessContainmentAvailability(
                available: false, platform: .macOS,
                mechanism: .macOSSeatbeltProcessGroup,
                reason: unavailableReason(for: .macOS))
        case .linux:
            return HardProcessContainmentAvailability(
                available: false, platform: .linux,
                mechanism: .linuxBubblewrapProcessGroup,
                reason: unavailableReason(for: .linux))
        case .unsupported:
            return HardProcessContainmentAvailability(
                available: false, platform: .unsupported,
                mechanism: .processGroup,
                reason: unavailableReason(for: .unsupported))
        }
    }

    static func unavailableReason(for platform: HardProcessContainmentPlatform) -> String {
        switch platform {
        case .macOS:
            return "hard containment unavailable on macOS: the current Seatbelt + process-group backend cannot enforce aggregate CPU, memory, process-count, or daemon-descendant cleanup"
        case .linux:
            return "hard containment unavailable: the current Bubblewrap + process-group backend has no trusted delegated cgroup-v2 scope with aggregate limits and verified-empty cleanup"
        case .unsupported:
            return "hard containment unavailable on this platform"
        }
    }
}

/// Exact aggregate ceilings for one descendant scope. These are totals for the whole scope, never
/// per-process `rlimit` values. A requirement and a receipt must match all three values exactly.
public struct HardProcessContainmentLimits: Sendable, Equatable {
    public let aggregateCPUTimeMicros: UInt64
    public let aggregateMemoryBytes: UInt64
    public let aggregateProcessCount: UInt32

    public init(aggregateCPUTimeMicros: UInt64, aggregateMemoryBytes: UInt64,
                aggregateProcessCount: UInt32) {
        self.aggregateCPUTimeMicros = aggregateCPUTimeMicros
        self.aggregateMemoryBytes = aggregateMemoryBytes
        self.aggregateProcessCount = aggregateProcessCount
    }
}

/// Host-selected bindings that must be satisfied by one and only one execution scope.
public struct HardProcessContainmentRequirement: Sendable, Equatable {
    public let scopeID: String
    public let mechanism: HardProcessContainmentMechanism
    public let limits: HardProcessContainmentLimits
    public let mechanismDigest: String
    public let policyDigest: String
    public let expectedExecutionDigest: String

    public init(scopeID: String, mechanism: HardProcessContainmentMechanism,
                limits: HardProcessContainmentLimits, mechanismDigest: String,
                policyDigest: String, expectedExecutionDigest: String) {
        self.scopeID = scopeID
        self.mechanism = mechanism
        self.limits = limits
        self.mechanismDigest = mechanismDigest
        self.policyDigest = policyDigest
        self.expectedExecutionDigest = expectedExecutionDigest
    }
}

/// Evidence captured by the trusted supervisor before the first untrusted instruction executes.
/// Separate fixed fields make partial backends fail closed instead of hiding behind `enforced=true`.
public struct HardProcessContainmentMembershipEvidence: Sendable, Equatable {
    public let scopeEstablishedBeforeExec: Bool
    public let launcherJoinedBeforeExec: Bool
    public let membershipEstablishedAtomically: Bool
    public let descendantsInheritMembership: Bool
    public let descendantEscapePrevented: Bool
    public let aggregateCPUTimeEnforced: Bool
    public let aggregateMemoryEnforced: Bool
    public let aggregateProcessCountEnforced: Bool
    public let scopeCreatedAtMillis: Int64
    public let membershipVerifiedAtMillis: Int64
    public let executionStartedAtMillis: Int64

    init(scopeEstablishedBeforeExec: Bool, launcherJoinedBeforeExec: Bool,
         membershipEstablishedAtomically: Bool, descendantsInheritMembership: Bool,
         descendantEscapePrevented: Bool, aggregateCPUTimeEnforced: Bool,
         aggregateMemoryEnforced: Bool, aggregateProcessCountEnforced: Bool,
         scopeCreatedAtMillis: Int64, membershipVerifiedAtMillis: Int64,
         executionStartedAtMillis: Int64) {
        self.scopeEstablishedBeforeExec = scopeEstablishedBeforeExec
        self.launcherJoinedBeforeExec = launcherJoinedBeforeExec
        self.membershipEstablishedAtomically = membershipEstablishedAtomically
        self.descendantsInheritMembership = descendantsInheritMembership
        self.descendantEscapePrevented = descendantEscapePrevented
        self.aggregateCPUTimeEnforced = aggregateCPUTimeEnforced
        self.aggregateMemoryEnforced = aggregateMemoryEnforced
        self.aggregateProcessCountEnforced = aggregateProcessCountEnforced
        self.scopeCreatedAtMillis = scopeCreatedAtMillis
        self.membershipVerifiedAtMillis = membershipVerifiedAtMillis
        self.executionStartedAtMillis = executionStartedAtMillis
    }
}

/// Terminal lifecycle evidence. A clean leader exit is insufficient: the trusted supervisor must
/// issue the scope-wide kill operation and then prove that zero members remain.
public struct HardProcessContainmentCleanupEvidence: Sendable, Equatable {
    public let killAllIssued: Bool
    public let killAllCompleted: Bool
    public let scopeEmptyVerified: Bool
    public let remainingProcessCount: UInt32
    public let killAllIssuedAtMillis: Int64
    public let emptyVerifiedAtMillis: Int64

    init(killAllIssued: Bool, killAllCompleted: Bool, scopeEmptyVerified: Bool,
         remainingProcessCount: UInt32, killAllIssuedAtMillis: Int64,
         emptyVerifiedAtMillis: Int64) {
        self.killAllIssued = killAllIssued
        self.killAllCompleted = killAllCompleted
        self.scopeEmptyVerified = scopeEmptyVerified
        self.remainingProcessCount = remainingProcessCount
        self.killAllIssuedAtMillis = killAllIssuedAtMillis
        self.emptyVerifiedAtMillis = emptyVerifiedAtMillis
    }
}

/// In-memory evidence returned only by a future trusted backend inside AgentCore. It intentionally
/// has no public initializer and no Codable conformance: JSON supplied by candidate code is never a
/// hard-containment authority. Adding a production backend must construct this value from host-owned
/// observations after cleanup, not from child output.
public struct HardProcessContainmentReceipt: Sendable, Equatable {
    public let scopeID: String
    public let platform: HardProcessContainmentPlatform
    public let mechanism: HardProcessContainmentMechanism
    public let limits: HardProcessContainmentLimits
    public let mechanismDigest: String
    public let policyDigest: String
    public let executionDigest: String
    public let membership: HardProcessContainmentMembershipEvidence
    public let cleanup: HardProcessContainmentCleanupEvidence
    public let issuedAtMillis: Int64
    public let validUntilMillis: Int64

    init(scopeID: String, platform: HardProcessContainmentPlatform,
         mechanism: HardProcessContainmentMechanism, limits: HardProcessContainmentLimits,
         mechanismDigest: String, policyDigest: String, executionDigest: String,
         membership: HardProcessContainmentMembershipEvidence,
         cleanup: HardProcessContainmentCleanupEvidence,
         issuedAtMillis: Int64, validUntilMillis: Int64) {
        self.scopeID = scopeID
        self.platform = platform
        self.mechanism = mechanism
        self.limits = limits
        self.mechanismDigest = mechanismDigest
        self.policyDigest = policyDigest
        self.executionDigest = executionDigest
        self.membership = membership
        self.cleanup = cleanup
        self.issuedAtMillis = issuedAtMillis
        self.validUntilMillis = validUntilMillis
    }
}

/// A value returned only after every hard invariant passes and the scope ID is atomically consumed.
public struct ValidatedHardProcessContainment: Sendable, Equatable {
    public let scopeID: String
    public let executionDigest: String
    public let limits: HardProcessContainmentLimits
    public let mechanism: HardProcessContainmentMechanism

    fileprivate init(receipt: HardProcessContainmentReceipt) {
        scopeID = receipt.scopeID
        executionDigest = receipt.executionDigest
        limits = receipt.limits
        mechanism = receipt.mechanism
    }
}

public enum HardProcessContainmentError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case invalidField(String)
    case advisoryMechanism(HardProcessContainmentMechanism)
    case platformMismatch
    case bindingMismatch(String)
    case limitMismatch(String)
    case preExecMembershipUnproven(String)
    case aggregateLimitUnproven(String)
    case cleanupUnproven(String)
    case invalidTimeline
    case notYetValid
    case expired
    case replayedScope

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .invalidField(let field): return "invalid hard-containment field: \(field)"
        case .advisoryMechanism(let mechanism):
            return "\(mechanism.rawValue) is advisory and cannot satisfy hard containment"
        case .platformMismatch: return "hard-containment platform does not match the executing host"
        case .bindingMismatch(let field): return "hard-containment binding mismatch: \(field)"
        case .limitMismatch(let field): return "hard-containment aggregate limit mismatch: \(field)"
        case .preExecMembershipUnproven(let field):
            return "hard-containment pre-exec membership is unproven: \(field)"
        case .aggregateLimitUnproven(let field):
            return "hard-containment aggregate enforcement is unproven: \(field)"
        case .cleanupUnproven(let field): return "hard-containment cleanup is unproven: \(field)"
        case .invalidTimeline: return "hard-containment evidence timeline is invalid"
        case .notYetValid: return "hard-containment receipt is not yet valid"
        case .expired: return "hard-containment receipt expired"
        case .replayedScope: return "hard-containment scope was already consumed"
        }
    }
}

/// Atomic, one-use consumer for hard-containment receipts. The owner must retain one guard for the
/// full authority lifetime (for example, one evolution evaluation session); creating a new guard is
/// an authority reset and therefore belongs only at a new host-owned session boundary.
public final class HardProcessContainmentReplayGuard: @unchecked Sendable {
    /// Process-wide replay boundary for production consumers. Its initializer is intentionally not
    /// public, so another module cannot reset one-use state by constructing a fresh guard.
    public static let shared = HardProcessContainmentReplayGuard()

    private let lock = NSLock()
    private var consumedScopeIDs: Set<String> = []

    init() {}

    public var consumedScopeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return consumedScopeIDs.count
    }

    /// Validate against the actual host platform, then consume the scope ID exactly once.
    public func consume(_ receipt: HardProcessContainmentReceipt,
                        satisfying requirement: HardProcessContainmentRequirement,
                        now: Date = Date()) throws -> ValidatedHardProcessContainment {
        let availability = HardProcessContainmentRuntime.currentAvailability
        guard availability.available else {
            throw HardProcessContainmentError.unavailable(availability.reason)
        }
        let nowDouble = (now.timeIntervalSince1970 * 1_000).rounded(.down)
        guard nowDouble.isFinite, nowDouble > 0, nowDouble <= Double(Int64.max) else {
            throw HardProcessContainmentError.invalidField("now")
        }
        return try consume(receipt, satisfying: requirement,
                           hostPlatform: .current, nowMillis: Int64(nowDouble))
    }

    /// Pure validation seam used by cross-platform contract tests and by a future trusted backend.
    /// It does not make that backend exist; current runtime availability remains explicitly false.
    func consume(_ receipt: HardProcessContainmentReceipt,
                 satisfying requirement: HardProcessContainmentRequirement,
                 hostPlatform: HardProcessContainmentPlatform,
                 nowMillis: Int64) throws -> ValidatedHardProcessContainment {
        try HardProcessContainmentContract.validate(
            receipt, satisfying: requirement, hostPlatform: hostPlatform, nowMillis: nowMillis)
        lock.lock()
        defer { lock.unlock() }
        guard consumedScopeIDs.insert(receipt.scopeID).inserted else {
            throw HardProcessContainmentError.replayedScope
        }
        return ValidatedHardProcessContainment(receipt: receipt)
    }
}

enum HardProcessContainmentContract {
    static let maximumReceiptLifetimeMillis: Int64 = 5 * 60 * 1_000
    static let maximumIssuanceDelayMillis: Int64 = 30 * 1_000
    static let allowedFutureSkewMillis: Int64 = 5 * 1_000

    static func validate(_ receipt: HardProcessContainmentReceipt,
                         satisfying requirement: HardProcessContainmentRequirement,
                         hostPlatform: HardProcessContainmentPlatform,
                         nowMillis: Int64) throws {
        guard nowMillis > 0 else { throw HardProcessContainmentError.invalidField("now") }
        try validateScopeID(requirement.scopeID)
        try validateScopeID(receipt.scopeID)
        try validateLimits(requirement.limits, prefix: "requirement")
        try validateLimits(receipt.limits, prefix: "receipt")
        try validateDigest(requirement.mechanismDigest, field: "required mechanismDigest")
        try validateDigest(requirement.policyDigest, field: "required policyDigest")
        try validateDigest(requirement.expectedExecutionDigest, field: "expectedExecutionDigest")
        try validateDigest(receipt.mechanismDigest, field: "receipt mechanismDigest")
        try validateDigest(receipt.policyDigest, field: "receipt policyDigest")
        try validateDigest(receipt.executionDigest, field: "receipt executionDigest")

        guard requirement.mechanism.isQualifyingHardBackend else {
            throw HardProcessContainmentError.advisoryMechanism(requirement.mechanism)
        }
        guard receipt.mechanism.isQualifyingHardBackend else {
            throw HardProcessContainmentError.advisoryMechanism(receipt.mechanism)
        }
        guard hostPlatform != .macOS else {
            throw HardProcessContainmentError.unavailable(
                HardProcessContainmentRuntime.unavailableReason(for: .macOS))
        }
        guard hostPlatform == .linux, receipt.platform == hostPlatform,
              receipt.mechanism.requiredPlatform == hostPlatform else {
            throw HardProcessContainmentError.platformMismatch
        }

        guard receipt.scopeID == requirement.scopeID else {
            throw HardProcessContainmentError.bindingMismatch("scopeID")
        }
        guard receipt.mechanism == requirement.mechanism else {
            throw HardProcessContainmentError.bindingMismatch("mechanism")
        }
        guard receipt.limits.aggregateCPUTimeMicros == requirement.limits.aggregateCPUTimeMicros else {
            throw HardProcessContainmentError.limitMismatch("aggregateCPUTimeMicros")
        }
        guard receipt.limits.aggregateMemoryBytes == requirement.limits.aggregateMemoryBytes else {
            throw HardProcessContainmentError.limitMismatch("aggregateMemoryBytes")
        }
        guard receipt.limits.aggregateProcessCount == requirement.limits.aggregateProcessCount else {
            throw HardProcessContainmentError.limitMismatch("aggregateProcessCount")
        }
        guard receipt.mechanismDigest == requirement.mechanismDigest else {
            throw HardProcessContainmentError.bindingMismatch("mechanismDigest")
        }
        guard receipt.policyDigest == requirement.policyDigest else {
            throw HardProcessContainmentError.bindingMismatch("policyDigest")
        }
        guard receipt.executionDigest == requirement.expectedExecutionDigest else {
            throw HardProcessContainmentError.bindingMismatch("executionDigest")
        }

        let membership = receipt.membership
        guard membership.scopeEstablishedBeforeExec else {
            throw HardProcessContainmentError.preExecMembershipUnproven("scopeEstablishedBeforeExec")
        }
        guard membership.launcherJoinedBeforeExec else {
            throw HardProcessContainmentError.preExecMembershipUnproven("launcherJoinedBeforeExec")
        }
        guard membership.membershipEstablishedAtomically else {
            throw HardProcessContainmentError.preExecMembershipUnproven("membershipEstablishedAtomically")
        }
        guard membership.descendantsInheritMembership else {
            throw HardProcessContainmentError.preExecMembershipUnproven("descendantsInheritMembership")
        }
        guard membership.descendantEscapePrevented else {
            throw HardProcessContainmentError.preExecMembershipUnproven("descendantEscapePrevented")
        }
        guard membership.aggregateCPUTimeEnforced else {
            throw HardProcessContainmentError.aggregateLimitUnproven("aggregateCPUTime")
        }
        guard membership.aggregateMemoryEnforced else {
            throw HardProcessContainmentError.aggregateLimitUnproven("aggregateMemory")
        }
        guard membership.aggregateProcessCountEnforced else {
            throw HardProcessContainmentError.aggregateLimitUnproven("aggregateProcessCount")
        }

        let cleanup = receipt.cleanup
        guard cleanup.killAllIssued else {
            throw HardProcessContainmentError.cleanupUnproven("killAllIssued")
        }
        guard cleanup.killAllCompleted else {
            throw HardProcessContainmentError.cleanupUnproven("killAllCompleted")
        }
        guard cleanup.scopeEmptyVerified else {
            throw HardProcessContainmentError.cleanupUnproven("scopeEmptyVerified")
        }
        guard cleanup.remainingProcessCount == 0 else {
            throw HardProcessContainmentError.cleanupUnproven("remainingProcessCount")
        }

        let timeline = [
            membership.scopeCreatedAtMillis,
            membership.membershipVerifiedAtMillis,
            membership.executionStartedAtMillis,
            cleanup.killAllIssuedAtMillis,
            cleanup.emptyVerifiedAtMillis,
            receipt.issuedAtMillis,
            receipt.validUntilMillis,
        ]
        guard timeline.allSatisfy({ $0 > 0 }),
              zip(timeline, timeline.dropFirst()).allSatisfy({ $0 <= $1 }) else {
            throw HardProcessContainmentError.invalidTimeline
        }
        let (lifetime, lifetimeOverflow) = receipt.validUntilMillis
            .subtractingReportingOverflow(receipt.issuedAtMillis)
        let (issuanceDelay, issuanceOverflow) = receipt.issuedAtMillis
            .subtractingReportingOverflow(cleanup.emptyVerifiedAtMillis)
        guard !lifetimeOverflow, lifetime > 0, lifetime <= maximumReceiptLifetimeMillis,
              !issuanceOverflow, issuanceDelay >= 0,
              issuanceDelay <= maximumIssuanceDelayMillis else {
            throw HardProcessContainmentError.invalidTimeline
        }
        let (futureBoundary, futureOverflow) = nowMillis
            .addingReportingOverflow(allowedFutureSkewMillis)
        guard !futureOverflow, receipt.issuedAtMillis <= futureBoundary else {
            throw HardProcessContainmentError.notYetValid
        }
        guard nowMillis <= receipt.validUntilMillis else {
            throw HardProcessContainmentError.expired
        }
    }

    private static func validateScopeID(_ value: String) throws {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
            throw HardProcessContainmentError.invalidField("scopeID")
        }
    }

    private static func validateLimits(_ limits: HardProcessContainmentLimits,
                                       prefix: String) throws {
        guard limits.aggregateCPUTimeMicros > 0 else {
            throw HardProcessContainmentError.invalidField("\(prefix).aggregateCPUTimeMicros")
        }
        guard limits.aggregateMemoryBytes > 0 else {
            throw HardProcessContainmentError.invalidField("\(prefix).aggregateMemoryBytes")
        }
        guard limits.aggregateProcessCount > 0 else {
            throw HardProcessContainmentError.invalidField("\(prefix).aggregateProcessCount")
        }
    }

    private static func validateDigest(_ value: String, field: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
            throw HardProcessContainmentError.invalidField(field)
        }
    }
}
