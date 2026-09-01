import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Durable state of a headless run, so a crashed/interrupted/paused loop can resume EXACTLY
/// where it left off. Because the loop is message-based (the text protocol), its entire state
/// is the conversation + cursor — trivially `Codable` (no DTO mirroring needed, unlike the GUI
/// monolith's plan-object checkpoint). Persisted after every iteration.
/// A tool action recorded as "about to run", persisted BEFORE its side effect so that if the
/// process dies mid-tool, resume can RECONCILE (verify state, don't blindly replay) instead of
/// risking a double write/command.
public struct PendingAction: Codable, Sendable {
    public let tool: String
    public let argsSummary: String
    public let iteration: Int
    /// Pre-execution effect classification. Optional so checkpoints written before this field existed
    /// still decode; reconciliation falls back to the conservative legacy classifier when it is absent.
    public let predictedEffects: ToolEffectObservation?
    public init(tool: String, argsSummary: String, iteration: Int,
                predictedEffects: ToolEffectObservation? = nil) {
        self.tool = tool; self.argsSummary = argsSummary; self.iteration = iteration
        self.predictedEffects = predictedEffects
    }
}

public struct LoopCheckpoint: Codable, Sendable {
    /// `abandoned` (R1, 2026-07-28): the user double-ESC'd the turn. Excluded from resumable()
    /// so it never clutters --list, but the file is KEPT — an explicit `--resume <id>` can still
    /// revive it (panic ESC-hammering must never destroy work irreversibly).
    public enum Status: String, Codable, Sendable { case running, completed, failed, paused, abandoned }

    public let id: String
    public var goal: String
    /// The raw operator request, separate from any compiled Captain prompt in `goal`.
    /// Optional for backward compatibility with checkpoints written before the turn contract existed.
    public var rawRequest: String?
    /// One semantic decision for the whole turn. Downstream systems consume this value rather than
    /// independently guessing whether the turn is chat, research, planning, or a state-changing build.
    public var intent: TaskBrief.Intent?
    public var expectedOutcome: TaskBrief.ExpectedOutcome?
    /// Exact host-derived child scope for `.delegate` turns. Optional for backward compatibility;
    /// resume deterministically reconstructs it from `rawRequest` when possible.
    public var delegationGrant: DelegationGrant?
    /// Background handles created by this exact turn. Delegation controls are accepted only for these
    /// handles, preventing a later turn from joining/steering a stale process-global registry entry.
    /// Optional for backward compatibility with checkpoints written before handle ownership shipped.
    public var delegationHandles: [String]?
    public var providerId: String
    public var model: String?
    public var projectRoot: String
    public var messages: [ChatMessage]   // full conversation = the resumable state
    public var iteration: Int            // last COMPLETED iteration (resume continues at +1)
    public var status: Status
    public var summary: String?
    public var pendingAction: PendingAction?   // set before a tool runs; nil once it completed
    /// The complete, ordered tool-evidence ledger for this run. Optional only for checkpoints written
    /// before trajectory persistence shipped; new checkpoints always initialize it to an empty ledger.
    /// Completion verification reconstructs its recorder from this field on resume, so a pause cannot
    /// erase an unverified mutation; execution proof is then deliberately invalidated at the unbound
    /// workspace resume boundary until a fresh build/test succeeds.
    public var trajectory: [ActionRecord]?
    /// Typed provider effort decisions observed for this run. Optional for old checkpoints.
    public var providerEffortRecords: [ProviderEffortRecord]?
    /// Bounded opaque continuation state mirrored from assistant messages. Optional for old checkpoints.
    public var providerReasoningHandles: [OpaqueProviderReasoningHandle]?
    /// Exact, time-bounded native-tool rejection observed for this run. Optional for checkpoints
    /// written before capability quarantine shipped.
    public var nativeToolFallback: NativeToolFallbackState?
    /// Exact positive proof that this provider/model accepted the advertised tool schema. Optional
    /// for old checkpoints; used to prevent a later contextual error from becoming a negative cache.
    public var nativeToolCapability: NativeToolPositiveState?
    /// Successful native assistant→tool-result exchanges in this checkpoint's run. Optional for
    /// old checkpoints; new turns initialize it to zero instead of scanning cross-turn transcript.
    public var nativeToolRoundTrips: Int?
    /// Absolute number of concrete provider requests durably admitted for this run. Optional so
    /// pre-ledger checkpoints decode; legacy checkpoints conservatively seed it from `iteration`.
    public var providerRequestsConsumed: Int?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, goal: String, rawRequest: String? = nil,
                intent: TaskBrief.Intent? = nil,
                expectedOutcome: TaskBrief.ExpectedOutcome? = nil,
                delegationGrant: DelegationGrant? = nil,
                delegationHandles: [String]? = [],
                providerId: String, model: String?,
                projectRoot: String, messages: [ChatMessage], iteration: Int = 0,
                status: Status = .running, summary: String? = nil, pendingAction: PendingAction? = nil,
                trajectory: [ActionRecord]? = [],
                providerEffortRecords: [ProviderEffortRecord]? = [],
                providerReasoningHandles: [OpaqueProviderReasoningHandle]? = [],
                nativeToolFallback: NativeToolFallbackState? = nil,
                nativeToolCapability: NativeToolPositiveState? = nil,
                nativeToolRoundTrips: Int? = 0,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.goal = goal; self.rawRequest = rawRequest
        self.intent = intent; self.expectedOutcome = expectedOutcome
        self.delegationGrant = delegationGrant
        self.delegationHandles = delegationHandles.map { Array(Set($0)).sorted() }
        self.providerId = providerId; self.model = model
        self.projectRoot = projectRoot; self.messages = messages; self.iteration = iteration
        self.status = status; self.summary = summary; self.pendingAction = pendingAction
        self.trajectory = trajectory
        self.providerEffortRecords = providerEffortRecords
        self.providerReasoningHandles = providerReasoningHandles.map { Array($0.suffix(128)) }
        self.nativeToolFallback = nativeToolFallback
        self.nativeToolCapability = nativeToolCapability
        self.nativeToolRoundTrips = nativeToolRoundTrips
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Short, human-friendly one-liner for `kist --list`.
    public var title: String {
        let g = goal.split(separator: "\n").first.map(String.init) ?? goal
        return String(g.prefix(60))
    }
}

/// Process-lifetime ownership of one checkpoint run. `flock` is attached to the open file
/// description, so the kernel releases a stale lease on crash; no PID-file expiry guessing is needed.
public final class LoopCheckpointRunLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32?

    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { release() }

    public func release() {
        stateLock.lock()
        guard let descriptor else { stateLock.unlock(); return }
        self.descriptor = nil
        stateLock.unlock()
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// JSON-file-per-run checkpoint store (cross-platform). Every data mutation is serialized by a
/// kernel file lock and committed as fsync(temp) -> renameat -> fsync(parent). Directory, lock, and
/// data descriptors are opened without following the final symlink and validated as user-owned
/// regular/single-link objects before use.
public struct LoopCheckpointStore: Sendable {
    public let directory: String
    private static let maxCheckpointBytes = 64 * 1_024 * 1_024

    public init(directory: String = LoopCheckpointStore.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory() -> String {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        return base + "/Mythos/checkpoints"
        #else
        let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"] ?? (NSHomeDirectory() + "/.local/state")
        return xdg + "/kist/checkpoints"
        #endif
    }

    private func validateID(_ id: String) throws {
        guard !id.isEmpty, id.count <= 128,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { throw ToolError.configuration("invalid checkpoint id: \(id)") }
    }

    public func save(_ cp: LoopCheckpoint) throws {
        try withDataLock(id: cp.id, exclusive: true) { directoryFD in
            try saveLocked(cp, directoryFD: directoryFD)
        }
    }

    public func load(id: String) throws -> LoopCheckpoint {
        try withDataLock(id: id, exclusive: false) { directoryFD in
            guard let checkpoint = try loadLocked(id: id, directoryFD: directoryFD) else {
                throw StoreError("checkpoint not found: \(id)")
            }
            return checkpoint
        }
    }

    /// Acquire exclusive ownership for the complete lifetime of a run/resume. Nonblocking refusal
    /// prevents two processes from concurrently driving and overwriting the same transcript.
    public func acquireRunLease(id: String) throws -> LoopCheckpointRunLease {
        try validateID(id)
        let directoryFD = try secureDirectoryFD(create: true)
        defer { close(directoryFD) }
        let descriptor = try openLock(
            name: ".\(id).run.lock", directoryFD: directoryFD,
            operation: LOCK_EX | LOCK_NB)
        return LoopCheckpointRunLease(descriptor: descriptor)
    }

    /// Once a run lease is held, disk is authoritative over a caller's possibly stale snapshot.
    /// A not-yet-persisted fresh checkpoint is the only case where the caller value is retained.
    public func reconcileForResume(_ candidate: LoopCheckpoint) throws -> LoopCheckpoint {
        try withDataLock(id: candidate.id, exclusive: false) { directoryFD in
            try loadLocked(id: candidate.id, directoryFD: directoryFD) ?? candidate
        }
    }

    /// Atomically consume one provider-request slot from durable state. `minimumConsumed` is the
    /// calling actor's last observed total; a newer durable total always wins. The returned value is
    /// the only counter value the actor may adopt.
    public func admitProviderRequest(
        id: String, minimumConsumed: Int, limit: Int
    ) throws -> Int {
        try withDataLock(id: id, exclusive: true) { directoryFD in
            guard var checkpoint = try loadLocked(id: id, directoryFD: directoryFD) else {
                throw StoreError("checkpoint not found during provider admission: \(id)")
            }
            let durable = max(checkpoint.providerRequestsConsumed ?? checkpoint.iteration,
                              checkpoint.iteration)
            let consumed = max(max(0, minimumConsumed), max(0, durable))
            guard limit > 0, consumed < limit else {
                throw ProviderRequestBudgetError.exhausted(limit: max(0, limit), consumed: consumed)
            }
            let admitted = consumed + 1
            checkpoint.providerRequestsConsumed = admitted
            checkpoint.iteration = admitted
            checkpoint.updatedAt = Date()
            try saveLocked(checkpoint, directoryFD: directoryFD)
            return admitted
        }
    }

    public func delete(id: String) {
        try? withDataLock(id: id, exclusive: true) { directoryFD in
            let result = "\(id).json".withCString { unlinkat(directoryFD, $0, 0) }
            if result != 0, errno != ENOENT { throw StoreError.posix("delete checkpoint") }
            guard fsync(directoryFD) == 0 else { throw StoreError.posix("fsync checkpoint directory") }
        }
    }

    /// Mark a checkpoint abandoned (double-ESC): hidden from resumable(), file kept so an explicit
    /// `--resume <id>` can still revive it. A misread double-ESC must never be irreversible.
    public func abandon(id: String) {
        try? withDataLock(id: id, exclusive: true) { directoryFD in
            guard var checkpoint = try loadLocked(id: id, directoryFD: directoryFD) else { return }
            checkpoint.status = .abandoned
            checkpoint.updatedAt = Date()
            try saveLocked(checkpoint, directoryFD: directoryFD)
        }
    }

    /// All checkpoints (any status), newest first.
    public func all() -> [LoopCheckpoint] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { name in
                let id = String(name.dropLast(".json".count))
                return try? load(id: id)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Runs that can be resumed (not completed) — newest first.
    public func resumable() -> [LoopCheckpoint] {
        all().filter { $0.status == .running || $0.status == .paused || $0.status == .failed }
    }

    private func withDataLock<T>(
        id: String, exclusive: Bool,
        _ body: (Int32) throws -> T
    ) throws -> T {
        try validateID(id)
        let directoryFD = try secureDirectoryFD(create: true)
        defer { close(directoryFD) }
        let operation: Int32 = exclusive ? LOCK_EX : LOCK_SH
        let lockFD = try openLock(name: ".\(id).data.lock", directoryFD: directoryFD,
                                  operation: operation)
        defer {
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
        }
        return try body(directoryFD)
    }

    private func secureDirectoryFD(create: Bool) throws -> Int32 {
        if create {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let descriptor = directory.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw StoreError.posix("open checkpoint directory") }
        do {
            let metadata = try validatedStat(descriptor, kind: .directory,
                                             label: "checkpoint directory")
            guard metadata.st_mode & mode_t(0o022) == 0 else {
                throw StoreError("checkpoint directory is group/world writable")
            }
            guard fchmod(descriptor, mode_t(0o700)) == 0 else {
                throw StoreError.posix("secure checkpoint directory permissions")
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func openLock(name: String, directoryFD: Int32, operation: Int32) throws -> Int32 {
        let descriptor = name.withCString {
            openat(directoryFD, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw StoreError.posix("open checkpoint lock") }
        do {
            _ = try validatedStat(descriptor, kind: .regular, label: "checkpoint lock")
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw StoreError.posix("secure checkpoint lock permissions")
            }
            guard flock(descriptor, operation) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    throw StoreError("checkpoint is already active in another process")
                }
                throw StoreError.posix("lock checkpoint")
            }
            guard fsync(directoryFD) == 0 else {
                _ = flock(descriptor, LOCK_UN)
                throw StoreError.posix("fsync checkpoint lock directory")
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func loadLocked(id: String, directoryFD: Int32) throws -> LoopCheckpoint? {
        let descriptor = "\(id).json".withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw StoreError.posix("open checkpoint data")
        }
        defer { close(descriptor) }
        let metadata = try validatedStat(descriptor, kind: .regular, label: "checkpoint data")
        guard metadata.st_size >= 0, metadata.st_size <= off_t(Self.maxCheckpointBytes) else {
            throw StoreError("checkpoint exceeds the secure size limit")
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw StoreError.posix("read checkpoint data")
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
            guard data.count <= Self.maxCheckpointBytes else {
                throw StoreError("checkpoint exceeds the secure size limit")
            }
        }
        return try JSONDecoder().decode(LoopCheckpoint.self, from: data)
    }

    private func saveLocked(_ checkpoint: LoopCheckpoint, directoryFD: Int32) throws {
        var checkpoint = checkpoint
        checkpoint.delegationHandles = checkpoint.delegationHandles.map {
            Array(Set($0)).sorted()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checkpoint)
        guard data.count <= Self.maxCheckpointBytes else {
            throw StoreError("checkpoint exceeds the secure size limit")
        }
        let temporary = ".\(checkpoint.id).\(UUID().uuidString).tmp"
        let descriptor = temporary.withCString {
            openat(directoryFD, $0,
                   O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                   mode_t(0o600))
        }
        guard descriptor >= 0 else { throw StoreError.posix("create checkpoint temporary file") }
        var keepTemporary = true
        defer {
            close(descriptor)
            if keepTemporary {
                _ = temporary.withCString { unlinkat(directoryFD, $0, 0) }
            }
        }
        _ = try validatedStat(descriptor, kind: .regular, label: "checkpoint temporary file")
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw StoreError.posix("write checkpoint data")
                }
                guard written > 0 else { throw StoreError("short checkpoint write") }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw StoreError.posix("fsync checkpoint data") }
        let target = "\(checkpoint.id).json"
        let renamed = temporary.withCString { source in
            target.withCString { destination in
                renameat(directoryFD, source, directoryFD, destination)
            }
        }
        guard renamed == 0 else { throw StoreError.posix("commit checkpoint data") }
        keepTemporary = false
        guard fsync(directoryFD) == 0 else { throw StoreError.posix("fsync checkpoint directory") }
    }

    private enum ExpectedKind { case regular, directory }

    private func validatedStat(_ descriptor: Int32, kind: ExpectedKind, label: String) throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw StoreError.posix("stat \(label)") }
        let expected = kind == .regular ? mode_t(S_IFREG) : mode_t(S_IFDIR)
        guard metadata.st_mode & mode_t(S_IFMT) == expected,
              metadata.st_uid == geteuid() else {
            throw StoreError("\(label) is not a user-owned \(kind == .regular ? "regular file" : "directory")")
        }
        if kind == .regular, metadata.st_nlink != 1 {
            throw StoreError("\(label) has an unsafe hard-link count")
        }
        return metadata
    }

    private struct StoreError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        static func posix(_ action: String) -> StoreError {
            StoreError("\(action) failed: \(String(cString: strerror(errno)))")
        }
        var errorDescription: String? { message }
    }
}
