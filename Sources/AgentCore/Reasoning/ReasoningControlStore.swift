import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public typealias ReasoningStateMutation = @Sendable (inout ReasoningControlState) throws -> Void

public protocol ReasoningControlStateStoring: Sendable {
    func load(runID: String) async throws -> ReasoningControlState?
    func createIfAbsent(_ state: ReasoningControlState) async throws -> ReasoningControlState
    @discardableResult
    func save(_ state: ReasoningControlState) async throws -> ReasoningControlState
    @discardableResult
    func update(runID: String, create: ReasoningControlState?,
                _ mutation: ReasoningStateMutation) async throws -> ReasoningControlState
}

public extension ReasoningControlStateStoring {
    func createIfAbsent(_ state: ReasoningControlState) async throws -> ReasoningControlState {
        guard try await load(runID: state.id) == nil else {
            throw ReasoningControlError.invalidState("reasoning checkpoint already exists")
        }
        return try await save(state)
    }
}

/// Actor isolation serializes in-process updates; Data.write(.atomic) gives each checkpoint an
/// atomic replace on disk. Save rejects counter, accepted-plan, and evidence regressions.
public actor AtomicReasoningControlStore: ReasoningControlStateStoring {
    private let directory: URL
    private let clock: @Sendable () -> Double
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, clock: @escaping @Sendable () -> Double = {
        Date().timeIntervalSince1970
    }) {
        self.directory = directory
        self.clock = clock
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
    }

    public init(projectRoot: String,
                clock: @escaping @Sendable () -> Double = {
                    Date().timeIntervalSince1970
                }) {
        self.directory = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".kist", isDirectory: true)
            .appendingPathComponent("reasoning", isDirectory: true)
        self.clock = clock
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func load(runID: String) throws -> ReasoningControlState? {
        try withRunLock(runID: runID) {
            let url = fileURL(runID: runID)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let original = try Data(contentsOf: url)
            let state = try decoder.decode(ReasoningControlState.self, from: original)
            try state.validateWorkspaceLifecycle()
            let migrated = try encoder.encode(state)
            if migrated != original { try durableReplace(migrated, at: url) }
            return state
        }
    }

    @discardableResult
    public func createIfAbsent(_ state: ReasoningControlState) throws -> ReasoningControlState {
        guard !state.id.isEmpty else { throw ReasoningControlError.invalidState("empty run id") }
        return try withRunLock(runID: state.id) {
            guard try read(runID: state.id) == nil else {
                throw ReasoningControlError.invalidState("reasoning checkpoint already exists")
            }
            var next = state
            try next.validateWorkspaceLifecycle()
            next.schemaVersion = ReasoningControlState.currentSchemaVersion
            next.revision = 0
            next.updatedAt = clock()
            let data = try encoder.encode(next)
            do {
                try durableCreate(data, at: fileURL(runID: next.id))
            } catch {
                throw ReasoningControlError.invalidState(
                    "reasoning checkpoint reservation failed: \(error)")
            }
            return try decoder.decode(ReasoningControlState.self, from: data)
        }
    }

    @discardableResult
    public func save(_ state: ReasoningControlState) throws -> ReasoningControlState {
        guard !state.id.isEmpty else { throw ReasoningControlError.invalidState("empty run id") }
        return try withRunLock(runID: state.id) { try saveLocked(state) }
    }

    @discardableResult
    public func update(runID: String, create: ReasoningControlState?,
                       _ mutation: ReasoningStateMutation) throws -> ReasoningControlState {
        try withRunLock(runID: runID) {
            var state: ReasoningControlState
            if let existing = try read(runID: runID) {
                state = existing
            } else if let create {
                guard create.id == runID else {
                    throw ReasoningControlError.invalidState("create state id does not match run id")
                }
                state = create
            } else {
                throw ReasoningControlError.missingState(runID)
            }
            try mutation(&state)
            return try saveLocked(state)
        }
    }

    public func delete(runID: String) throws {
        try withRunLock(runID: runID) {
            let url = fileURL(runID: runID)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                try syncDirectory(directory)
            }
        }
    }

    private func saveLocked(_ state: ReasoningControlState) throws -> ReasoningControlState {
        let current = try read(runID: state.id)
        if let current {
            guard state.revision == current.revision else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "stale reasoning checkpoint revision")
            }
            try validateMonotonic(next: state, after: current)
        } else {
            guard state.revision == 0 else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "new reasoning checkpoint must begin at revision zero")
            }
        }
        var next = state
        try next.validateWorkspaceLifecycle()
        next.schemaVersion = ReasoningControlState.currentSchemaVersion
        next.revision = current.map { $0.revision + 1 } ?? 0
        next.updatedAt = clock()
        let data = try encoder.encode(next)
        let persisted = try decoder.decode(ReasoningControlState.self, from: data)
        if current == nil {
            try durableCreate(data, at: fileURL(runID: next.id))
        } else {
            try durableReplace(data, at: fileURL(runID: next.id))
        }
        return persisted
    }

    private func read(runID: String) throws -> ReasoningControlState? {
        let url = fileURL(runID: runID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ReasoningControlState.self, from: Data(contentsOf: url))
    }

    private func fileURL(runID: String) -> URL {
        let name = Data(runID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(name + ".json", isDirectory: false)
    }

    private func validateMonotonic(next: ReasoningControlState,
                                   after current: ReasoningControlState) throws {
        guard next.id == current.id else {
            throw ReasoningControlError.nonMonotonicUpdate("run identity changed")
        }
        guard next.missionInstanceID == current.missionInstanceID else {
            throw ReasoningControlError.nonMonotonicUpdate("mission instance identity changed")
        }
        guard next.projectIdentity == current.projectIdentity else {
            throw ReasoningControlError.nonMonotonicUpdate("project identity changed")
        }
        try next.validateWorkspaceLifecycle()
        if let objective = current.canonicalFunctionalObjectiveFingerprint {
            guard next.canonicalFunctionalObjectiveFingerprint == objective else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "canonical functional objective binding changed")
            }
        }
        if let policy = current.workspaceManifestPolicyFingerprint {
            guard next.workspaceManifestPolicyFingerprint == policy else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "workspace manifest policy binding changed")
            }
        }
        let oldWorkspaceReceipts = current.workspaceActionReceipts ?? []
        let newWorkspaceReceipts = next.workspaceActionReceipts ?? []
        guard newWorkspaceReceipts.count >= oldWorkspaceReceipts.count,
              Array(newWorkspaceReceipts.prefix(oldWorkspaceReceipts.count)) == oldWorkspaceReceipts,
              newWorkspaceReceipts.count <= oldWorkspaceReceipts.count + 1 else {
            throw ReasoningControlError.nonMonotonicUpdate(
                "workspace action receipt history was removed, changed, or skipped")
        }
        switch (current.activeWorkspaceAction, next.activeWorkspaceAction) {
        case (nil, nil):
            guard newWorkspaceReceipts.count == oldWorkspaceReceipts.count else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "workspace action completion has no prior STARTED intent")
            }
            if current.workspaceManifestRevision != nil {
                guard next.workspaceManifestRevision == current.workspaceManifestRevision,
                      next.workspaceManifestDigest == current.workspaceManifestDigest,
                      next.previousWorkspaceManifestDigest == current.previousWorkspaceManifestDigest,
                      next.lastAcknowledgedGovernedWorkspaceDigest
                        == current.lastAcknowledgedGovernedWorkspaceDigest else {
                    throw ReasoningControlError.nonMonotonicUpdate(
                        "workspace lifecycle head changed without an action completion")
                }
            }
        case (nil, .some):
            guard newWorkspaceReceipts == oldWorkspaceReceipts,
                  next.workspaceManifestRevision == current.workspaceManifestRevision,
                  next.workspaceManifestDigest == current.workspaceManifestDigest,
                  next.previousWorkspaceManifestDigest == current.previousWorkspaceManifestDigest,
                  next.lastAcknowledgedGovernedWorkspaceDigest
                    == current.lastAcknowledgedGovernedWorkspaceDigest else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "STARTED workspace action also changed its durable head")
            }
        case let (.some(oldIntent), .some(newIntent)):
            guard oldIntent == newIntent, newWorkspaceReceipts == oldWorkspaceReceipts,
                  next.workspaceManifestRevision == current.workspaceManifestRevision,
                  next.workspaceManifestDigest == current.workspaceManifestDigest,
                  next.previousWorkspaceManifestDigest == current.previousWorkspaceManifestDigest,
                  next.lastAcknowledgedGovernedWorkspaceDigest
                    == current.lastAcknowledgedGovernedWorkspaceDigest else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "active workspace action or lifecycle head changed before completion")
            }
        case let (.some(oldIntent), nil):
            guard newWorkspaceReceipts.count == oldWorkspaceReceipts.count + 1,
                  let completion = newWorkspaceReceipts.last,
                  completion.intent == oldIntent,
                  completion.hasValidReceiptDigest,
                  next.workspaceManifestRevision == completion.postWorkspaceManifestRevision,
                  next.workspaceManifestDigest == completion.postWorkspaceManifestDigest,
                  next.previousWorkspaceManifestDigest == current.workspaceManifestDigest,
                  next.lastAcknowledgedGovernedWorkspaceDigest
                    == completion.postGovernedWorkspaceDigest else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "workspace action completion transition is invalid")
            }
        }
        guard next.cycle >= current.cycle,
              next.tokensSpent >= current.tokensSpent,
              next.replanCount >= current.replanCount,
              next.nudgeCount >= current.nudgeCount,
              next.recoveryCount >= current.recoveryCount,
              next.progress.revision >= current.progress.revision else {
            throw ReasoningControlError.nonMonotonicUpdate("a durable counter regressed")
        }
        guard current.acceptedPlanNodeIDs.isSubset(of: next.acceptedPlanNodeIDs) else {
            throw ReasoningControlError.nonMonotonicUpdate("accepted plan nodes were removed")
        }
        let nextEvidence = Set(next.evidenceReferences.map(\.id))
        let nextFeedback = Set(next.feedbackReferences.map(\.id))
        guard Set(current.evidenceReferences.map(\.id)).isSubset(of: nextEvidence),
              Set(current.feedbackReferences.map(\.id)).isSubset(of: nextFeedback),
              Set(current.childCheckpointIDs.keys).isSubset(of: Set(next.childCheckpointIDs.keys)) else {
            throw ReasoningControlError.nonMonotonicUpdate("durable references were removed")
        }
        guard current.acceptedPlanNodeIDs.allSatisfy({ next.planNodes[$0] != nil }) else {
            throw ReasoningControlError.nonMonotonicUpdate("an accepted plan node record was removed")
        }
        let oldPlans = Set((current.executablePlanSnapshots ?? []).map(\.id))
        let newPlans = Set((next.executablePlanSnapshots ?? []).map(\.id))
        guard oldPlans.isSubset(of: newPlans),
              (current.approvedExecutablePlanIDs ?? []).isSubset(of: next.approvedExecutablePlanIDs ?? []) else {
            throw ReasoningControlError.nonMonotonicUpdate("durable executable plan history regressed")
        }
        let oldRejected = current.rejectedPlanAttemptReceipts ?? []
        let newRejected = next.rejectedPlanAttemptReceipts ?? []
        guard newRejected.count >= oldRejected.count,
              Array(newRejected.prefix(oldRejected.count)) == oldRejected else {
            throw ReasoningControlError.nonMonotonicUpdate(
                "durable rejected plan attempt history was removed, reordered, or changed")
        }
        guard newRejected.enumerated().allSatisfy({ index, receipt in
            receipt.ordinal == index + 1 && !receipt.planFingerprint.isEmpty
        }) else {
            throw ReasoningControlError.nonMonotonicUpdate(
                "durable rejected plan attempt history is internally inconsistent")
        }
        if let oldControl = current.verificationControl {
            guard let newControl = next.verificationControl else {
                throw ReasoningControlError.nonMonotonicUpdate("durable verification control was removed")
            }
            guard oldControl.missionInstanceID == newControl.missionInstanceID,
                  oldControl.completionContractFingerprint == newControl.completionContractFingerprint,
                  oldControl.obligationsFingerprint == newControl.obligationsFingerprint,
                  oldControl.executionPolicyFingerprint == newControl.executionPolicyFingerprint,
                  oldControl.workspaceManifestDigest == newControl.workspaceManifestDigest,
                  oldControl.attemptLimit == newControl.attemptLimit else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "durable verification bindings or attempt limit changed")
            }
            guard newControl.recipes.count >= oldControl.recipes.count,
                  Array(newControl.recipes.prefix(oldControl.recipes.count)) == oldControl.recipes else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "durable verification recipes were removed, reordered, or changed")
            }
            guard newControl.seenReplayStateKeys.count >= oldControl.seenReplayStateKeys.count,
                  Array(newControl.seenReplayStateKeys.prefix(oldControl.seenReplayStateKeys.count))
                    == oldControl.seenReplayStateKeys,
                  newControl.attemptsStarted >= oldControl.attemptsStarted else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "durable verification replay ledger regressed")
            }
        }
        if let control = next.verificationControl {
            let recipeIDs = control.recipes.map(\.id)
            guard control.attemptLimit > 0,
                  control.attemptsStarted >= 0,
                  control.attemptsStarted <= control.attemptLimit,
                  control.attemptsStarted == control.seenReplayStateKeys.count,
                  Set(control.seenReplayStateKeys).count == control.seenReplayStateKeys.count,
                  Set(recipeIDs).count == recipeIDs.count else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "durable verification control is internally inconsistent")
            }
            guard control.recipes.allSatisfy({ recipe in
                recipe.completionContractFingerprint == control.completionContractFingerprint
                    && recipe.obligationsFingerprint == control.obligationsFingerprint
                    && recipe.executionPolicyFingerprint == control.executionPolicyFingerprint
                    && recipe.workspaceManifestDigest == control.workspaceManifestDigest
            }) else {
                throw ReasoningControlError.nonMonotonicUpdate(
                    "durable verification recipe escaped its configured bindings")
            }
        }
    }

    private func withRunLock<T>(runID: String, _ body: () throws -> T) throws -> T {
        try ensurePrivateDirectory(directory)
        // Checkpoint consumers may enumerate this directory as durable JSON records.
        // Keep synchronization metadata beside that collection rather than inside it.
        let lockDirectory = directory.deletingLastPathComponent().appendingPathComponent(
            directory.lastPathComponent + "-locks", isDirectory: true)
        try ensurePrivateDirectory(lockDirectory)
        let lockURL = lockDirectory.appendingPathComponent(fileURL(runID: runID).lastPathComponent + ".lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError("open reasoning checkpoint lock") }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid() else {
            throw ReasoningControlError.invalidState("reasoning checkpoint lock is not a private regular file")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw posixError("lock reasoning checkpoint")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            throw ReasoningControlError.invalidState(
                "reasoning checkpoint directory is not a private owned directory")
        }
        guard chmod(url.path, mode_t(0o700)) == 0 else {
            throw posixError("secure reasoning checkpoint directory")
        }
    }

    private func durableCreate(_ data: Data, at url: URL) throws {
        try ensurePrivateDirectory(directory)
        let temporary = try writeDurableTemporary(data, beside: url)
        defer { _ = unlink(temporary.path) }
        guard link(temporary.path, url.path) == 0 else {
            throw posixError("publish new reasoning checkpoint")
        }
        guard chmod(url.path, mode_t(0o600)) == 0 else {
            throw posixError("secure new reasoning checkpoint")
        }
        try syncDirectory(directory)
    }

    private func durableReplace(_ data: Data, at url: URL) throws {
        try ensurePrivateDirectory(directory)
        let temporary = try writeDurableTemporary(data, beside: url)
        var published = false
        defer { if !published { _ = unlink(temporary.path) } }
        guard rename(temporary.path, url.path) == 0 else {
            throw posixError("replace reasoning checkpoint")
        }
        published = true
        guard chmod(url.path, mode_t(0o600)) == 0 else {
            throw posixError("secure reasoning checkpoint")
        }
        try syncDirectory(directory)
    }

    private func writeDurableTemporary(_ data: Data, beside url: URL) throws -> URL {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path,
                              O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                              mode_t(0o600))
        guard descriptor >= 0 else { throw posixError("create reasoning checkpoint temporary") }
        var keep = false
        defer {
            _ = close(descriptor)
            if !keep { _ = unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write reasoning checkpoint temporary")
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw posixError("sync reasoning checkpoint temporary")
        }
        keep = true
        return temporary
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError("open reasoning checkpoint directory") }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw posixError("sync reasoning checkpoint directory")
        }
    }

    private func posixError(_ operation: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
    }
}
