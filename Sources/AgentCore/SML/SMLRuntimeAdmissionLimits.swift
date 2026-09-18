import Foundation

/// Explicit host capacity. Raising these limits changes the operating envelope; it does not add
/// workers or prove throughput. Existing work always remains drainable when admission is closed.
public struct SMLRuntimeAdmissionLimits: Sendable, Codable, Equatable {
    public static let relativePath = ".kist/sml/limits.json"
    public let maximumHotTasks: Int
    public let maximumUnfinishedTasks: Int
    public let maximumHotBytes: Int

    public init(maximumHotTasks: Int = 500, maximumUnfinishedTasks: Int = 64,
        maximumHotBytes: Int = 2 * 1_024 * 1_024) {
        self.maximumHotTasks = max(1, maximumHotTasks)
        self.maximumUnfinishedTasks = max(1, maximumUnfinishedTasks)
        self.maximumHotBytes = max(1, maximumHotBytes)
    }

    public static func load(projectRoot: String) throws -> SMLRuntimeAdmissionLimits {
        let data: Data
        do { data = try SMLHostConfigurationFile.read(projectRoot: projectRoot, relativePath: relativePath) }
        catch SMLHostConfigurationFile.ReadError.missing { return Self() }
        let root = try SMLHostConfigurationFile.decodeRoot(from: data)
        try SMLHostConfigurationFile.requireOnlyKeys(root, allowed: ["schema_version", "maximum_hot_tasks",
            "maximum_unfinished_tasks", "maximum_hot_bytes"], path: "limits")
        guard try SMLHostConfigurationFile.requiredInteger(root["schema_version"], path: "limits.schema_version") == 1 else {
            throw SMLRuntimeStoreError.decoding("unsupported SML admission limits schema")
        }
        func limit(_ key: String, fallback: Int, maximum: Int) throws -> Int {
            let value = try SMLHostConfigurationFile.optionalInteger(root[key], path: "limits." + key) ?? fallback
            guard value > 0, value <= maximum else {
                throw SMLRuntimeStoreError.decoding("limits.\(key) must be in 1...\(maximum)")
            }
            return value
        }
        let defaults = Self()
        return try Self(maximumHotTasks: limit("maximum_hot_tasks", fallback: defaults.maximumHotTasks, maximum: 1_000_000),
            maximumUnfinishedTasks: limit("maximum_unfinished_tasks", fallback: defaults.maximumUnfinishedTasks, maximum: 10_000),
            maximumHotBytes: limit("maximum_hot_bytes", fallback: defaults.maximumHotBytes, maximum: 512 * 1_024 * 1_024))
    }

    func requireHeadroom(snapshot: SMLRuntimeSnapshot, hotBytes: Int) throws {
        if snapshot.tasks.count >= maximumHotTasks { throw SMLRuntimeCapacityError.hotTasks(maximumHotTasks) }
        if snapshot.tasks.values.filter({ !SMLRuntimeStore.isTerminal($0.status) }).count >= maximumUnfinishedTasks {
            throw SMLRuntimeCapacityError.unfinishedTasks(maximumUnfinishedTasks)
        }
        if hotBytes >= maximumHotBytes { throw SMLRuntimeCapacityError.hotBytes(maximumHotBytes) }
    }

    func requireFits(snapshot: SMLRuntimeSnapshot) throws {
        if snapshot.tasks.count > maximumHotTasks { throw SMLRuntimeCapacityError.hotTasks(maximumHotTasks) }
        if snapshot.tasks.values.filter({ !SMLRuntimeStore.isTerminal($0.status) }).count > maximumUnfinishedTasks {
            throw SMLRuntimeCapacityError.unfinishedTasks(maximumUnfinishedTasks)
        }
        if try SMLRuntimeStore.maintenanceEncode(snapshot).count > maximumHotBytes {
            throw SMLRuntimeCapacityError.hotBytes(maximumHotBytes)
        }
    }
}

public enum SMLRuntimeCapacityError: Error, Sendable, Equatable, CustomStringConvertible {
    case hotTasks(Int)
    case unfinishedTasks(Int)
    case hotBytes(Int)

    public var description: String {
        switch self {
        case .hotTasks(let limit):
            return "SML task history reached its \(limit)-task limit; archive completed tasks before starting more"
        case .unfinishedTasks(let limit):
            return "SML has reached its \(limit)-task unfinished-work limit; finish or reconcile existing work before starting more"
        case .hotBytes(let limit):
            return "SML task history would exceed its \(limit)-byte limit; archive completed tasks or reduce the new task input"
        }
    }
}

public struct SMLRuntimeAdmissionStatus: Sendable, Codable, Equatable {
    public let limits: SMLRuntimeAdmissionLimits
    public let hotTaskCount: Int
    public let unfinishedTaskCount: Int
    public let hotBytes: Int
    public let acceptingNewTasks: Bool
    public let qualifiedLimitsExceeded: Bool
}

extension SMLRuntimeStore {
    public func admissionStatus() throws -> SMLRuntimeAdmissionStatus {
        try withSidecarLock(exclusive: false) {
            let snapshot = try loadUnlocked()
            let bytes = validatedCurrentSnapshotByteCount
            return SMLRuntimeAdmissionStatus(limits: admissionLimits, hotTaskCount: snapshot.tasks.count,
                unfinishedTaskCount: snapshot.tasks.values.filter { !Self.isTerminal($0.status) }.count,
                hotBytes: bytes, acceptingNewTasks: (try? admissionLimits.requireHeadroom(snapshot: snapshot, hotBytes: bytes)) != nil,
                qualifiedLimitsExceeded: admissionLimits.maximumHotTasks > 500
                    || admissionLimits.maximumUnfinishedTasks > 64 || admissionLimits.maximumHotBytes > 2 * 1_024 * 1_024)
        }
    }

    /// Preview the exact task transition, including the command replay entry, without publishing
    /// anything. Rejected traffic cannot fill the replay table while the host is already full.
    func preflightTaskCreation(command: SMLCommandEnvelope, authority: SMLCommandAuthority,
        nowEpoch: Double, _ body: (inout SMLRuntimeSnapshot) throws -> Void) throws {
        try withSidecarLock(exclusive: false) {
            var snapshot = try loadUnlocked()
            try admissionLimits.requireHeadroom(snapshot: snapshot, hotBytes: validatedCurrentSnapshotByteCount)
            snapshot.replayClaims = snapshot.replayClaims.filter { $0.value > nowEpoch }
            snapshot.replayClaims[command.commandID] = command.issuedAtEpoch
                + authority.maximumCommandAgeSeconds + authority.maximumFutureSkewSeconds
            if try archivedTaskUnlocked(id: command.task, root: snapshot.archiveRoot) != nil {
                throw SMLRuntimeError.taskAlreadyExists(command.task)
            }
            try body(&snapshot)
            try admissionLimits.requireFits(snapshot: snapshot)
        }
    }
}
