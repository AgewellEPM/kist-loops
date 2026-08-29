import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum RunLedgerTrustWrite: Sendable, Equatable {
    case appended
    case alreadyPresent
}

public enum RunLedgerTrustError: Error, Sendable, Equatable, LocalizedError {
    case invalidTrustedRecord(String)
    case conflictingRunID
    case malformedStore
    case unsafeStore(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTrustedRecord(let field):
            return "trusted run record is invalid: \(field)"
        case .conflictingRunID:
            return "trusted run record conflicts with an existing run ID"
        case .malformedStore:
            return "trusted run ledger store is malformed"
        case .unsafeStore(let reason):
            return "unsafe trusted run ledger store: \(reason)"
        case .persistence(let operation):
            return "trusted run record persistence failed: \(operation)"
        }
    }
}

/// Durable, append-only decision→outcome history at `<root>/.kist/run-ledger.jsonl` — the persisted
/// Phase 3.5 spine. Mirrors `EffortMemory`'s storage discipline exactly (atomic read-append-write to
/// avoid interleaved partial lines under concurrent runs; bounded to `maxRecords`; fail-soft — a
/// missing/corrupt file just means "no history yet", never a crash). History is ADVISORY: a write
/// failure is swallowed, never blocking a run.
public final class RunLedger {
    private static let maximumTrustStoreBytes = 16 * 1_024 * 1_024
    private let path: String
    private let maxRecords: Int

    public init(projectRoot: String, maxRecords: Int = 1000) {
        self.path = projectRoot + "/.kist/run-ledger.jsonl"
        self.maxRecords = max(0, maxRecords)
    }

    /// Best-effort advisory append. It intentionally swallows failure, but shares the exact lock and
    /// owner-only atomic writer used by the trust-bound path. Advisory traffic therefore cannot race a
    /// trusted append, drop its row, or replace the 0600 ledger with a looser-mode file.
    public func record(_ run: RunRecord) {
        // A disabled advisory ledger must be a true no-op. In particular, it must not truncate a
        // trust-bound row which another RunLedger instance persisted with a nonzero capacity.
        guard maxRecords > 0 else { return }
        try? withTrustWriteLock {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let encoded = try encoder.encode(run)
            guard let text = String(data: encoded, encoding: .utf8) else {
                throw RunLedgerTrustError.persistence("encode UTF-8")
            }
            // Preserve the historical fail-soft per-line behavior for advisory content: malformed
            // UTF-8 lines are dropped, while every other line is retained verbatim.
            var lines = advisoryLines(from: try readTrustDataUnlocked())
            var protectedTrustRows = lines.map(Self.isCanonicalTrustBoundProjectionLine)
            lines.append(text)
            // `record(_:)` is advisory and therefore can never promote its own row to protected
            // merely by supplying trust-looking fields. When the cap is reached, evict only
            // advisory/legacy rows. If the store is already full of accepted projections, drop this
            // best-effort append instead of erasing dashboard authority.
            protectedTrustRows.append(false)
            while lines.count > maxRecords {
                guard let removable = protectedTrustRows.firstIndex(of: false) else { return }
                lines.remove(at: removable)
                protectedTrustRows.remove(at: removable)
            }
            let replacement = Data((lines.isEmpty
                ? "" : lines.joined(separator: "\n") + "\n").utf8)
            guard replacement.count <= Self.maximumTrustStoreBytes else {
                throw RunLedgerTrustError.persistence("store size limit")
            }
            try writeTrustAtomicUnlocked(replacement)
        }
    }

    /// Explicit, fail-closed first phase for a dashboard-bindable accepted run. It persists the exact
    /// canonical candidate row before the sealed receipt is minted. A ledger-only interruption remains
    /// amber; exact resume is idempotent, while a non-identical/duplicate mission row is rejected.
    @discardableResult
    func recordTrustCandidate(
        _ run: RunRecord,
        ledgerRecordDigest: String
    ) throws -> RunLedgerTrustWrite {
        guard run.success else {
            throw RunLedgerTrustError.invalidTrustedRecord("success")
        }
        guard run.verified else {
            throw RunLedgerTrustError.invalidTrustedRecord("verified")
        }
        guard let projectIdentity = run.projectIdentity,
              Self.isLowercaseHexDigest(projectIdentity) else {
            throw RunLedgerTrustError.invalidTrustedRecord("projectIdentity")
        }
        guard let contractID = run.contractID else {
            throw RunLedgerTrustError.invalidTrustedRecord("contractID")
        }
        guard let objectiveFingerprint = run.objectiveFingerprint else {
            throw RunLedgerTrustError.invalidTrustedRecord("objectiveFingerprint")
        }
        guard let verificationSubject = run.verificationSubject else {
            throw RunLedgerTrustError.invalidTrustedRecord("verificationSubject")
        }
        guard let verificationDigest = run.verificationDigest else {
            throw RunLedgerTrustError.invalidTrustedRecord("verificationDigest")
        }
        let binding = try AcceptedRunReceipt.Binding(
            runID: run.id, contractID: contractID, exactGoal: run.goal,
            projectIdentity: projectIdentity,
            verificationSubject: verificationSubject,
            verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest)
        guard binding.objectiveFingerprint == objectiveFingerprint else {
            throw RunLedgerTrustError.invalidTrustedRecord("objectiveFingerprint")
        }
        let canonical = try Self.canonicalRecordLine(run)
        guard Self.digest(canonical) == ledgerRecordDigest else {
            throw RunLedgerTrustError.invalidTrustedRecord("ledgerRecordDigest")
        }

        return try withTrustWriteLock {
            let existingData = try readTrustDataUnlocked()
            var records = try decodeTrustStore(existingData)
            let matching = records.filter { $0.id == run.id }
            if !matching.isEmpty {
                guard matching.count == 1, matching[0] == run else {
                    throw RunLedgerTrustError.conflictingRunID
                }
                return .alreadyPresent
            }
            guard maxRecords > 0 else {
                throw RunLedgerTrustError.persistence("ledger capacity")
            }
            records.append(run)
            while records.count > maxRecords {
                guard let removable = records.firstIndex(where: {
                    !Self.isTrustBoundProjection($0)
                }) else {
                    throw RunLedgerTrustError.persistence("ledger capacity")
                }
                records.remove(at: removable)
            }
            let replacement = try encodeTrustStore(records)
            try writeTrustAtomicUnlocked(replacement)
            let persisted = try decodeTrustStore(readTrustDataUnlocked())
                .filter { $0.id == run.id }
            guard persisted.count == 1, persisted[0] == run else {
                throw RunLedgerTrustError.persistence("post-write validation")
            }
            return .appended
        }
    }

    /// Load the (bounded) history, newest-last. Skips any corrupt line rather than failing the whole read.
    public func load() -> [RunRecord] {
        let all = existingLines().compactMap { line -> RunRecord? in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RunRecord.self, from: d)
        }
        return Array(all.suffix(maxRecords))
    }

    /// Security-sensitive read-only projection used by evidence consumers. Unlike `load()`, this
    /// rejects the entire store on a torn, noncanonical, malformed, or duplicate row. It performs no
    /// directory creation, locking-file creation, migration, or rewrite.
    func strictTrustRecordsReadOnly() throws -> [RunRecord] {
        try decodeTrustStore(readTrustDataUnlocked())
    }

    /// Resilient newline-split read: decode each record line INDEPENDENTLY so one corrupt byte anywhere in
    /// the file can never take down the whole history (used by both read paths). Splits on the raw newline
    /// byte at the Data layer, then decodes each line as UTF-8 — a non-decodable line is simply dropped.
    private func existingLines() -> [String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return advisoryLines(from: data)
    }

    private func advisoryLines(from data: Data) -> [String] {
        data.split(separator: 0x0A).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    private func decodedExistingRecords() -> [RunRecord] {
        existingLines().compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RunRecord.self, from: data)
        }
    }

    private func withTrustWriteLock<T>(_ body: () throws -> T) throws -> T {
        let directory = (path as NSString).deletingLastPathComponent
        try ensureTrustStoreDirectory(directory)
        let lockPath = path + ".trust.lock"
        let descriptor = open(
            lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw RunLedgerTrustError.persistence("open lock")
        }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(), (info.st_mode & mode_t(0o077)) == 0 else {
            throw RunLedgerTrustError.persistence("validate lock")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw RunLedgerTrustError.persistence("lock")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func ensureTrustStoreDirectory(_ directory: String) throws {
        var info = stat()
        if lstat(directory, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  info.st_uid == getuid(), (info.st_mode & mode_t(0o022)) == 0 else {
                throw RunLedgerTrustError.unsafeStore(".kist is not an owned directory")
            }
            return
        }
        guard errno == ENOENT else {
            throw RunLedgerTrustError.persistence("inspect directory")
        }
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw RunLedgerTrustError.persistence("create directory")
        }
        guard lstat(directory, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == getuid(), (info.st_mode & mode_t(0o022)) == 0 else {
            throw RunLedgerTrustError.unsafeStore("created .kist is not an owned directory")
        }
    }

    /// Strict trust read: unlike advisory `load`, one malformed/torn/non-UTF8 line invalidates the
    /// entire candidate store. The trusted writer must never launder a corrupt ledger into a green row.
    private func readTrustDataUnlocked() throws -> Data {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return Data() }
            if errno == ELOOP {
                throw RunLedgerTrustError.unsafeStore("ledger path is a symbolic link")
            }
            throw RunLedgerTrustError.persistence("open ledger")
        }
        defer { _ = close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == getuid(), (before.st_mode & mode_t(0o077)) == 0 else {
            throw RunLedgerTrustError.unsafeStore(
                "ledger is not an owner-only regular file")
        }
        guard before.st_size >= 0,
              before.st_size <= off_t(Self.maximumTrustStoreBytes) else {
            throw RunLedgerTrustError.persistence("store size limit")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            let data = try handle.readToEnd() ?? Data()
            guard data.count <= Self.maximumTrustStoreBytes else {
                throw RunLedgerTrustError.persistence("store size limit")
            }
            var after = stat()
            var pathInfo = stat()
            guard fstat(descriptor, &after) == 0,
                  lstat(path, &pathInfo) == 0,
                  (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size,
                  before.st_dev == pathInfo.st_dev, before.st_ino == pathInfo.st_ino,
                  before.st_size == pathInfo.st_size,
                  off_t(data.count) == before.st_size else {
                throw RunLedgerTrustError.persistence("ledger changed while reading")
            }
            return data
        } catch let error as RunLedgerTrustError {
            throw error
        } catch {
            throw RunLedgerTrustError.persistence("read ledger")
        }
    }

    private func decodeTrustStore(_ data: Data) throws -> [RunRecord] {
        guard !data.isEmpty else { return [] }
        guard data.last == 0x0A else { throw RunLedgerTrustError.malformedStore }
        let decoder = JSONDecoder()
        var records: [RunRecord] = []
        var seenIDs = Set<String>()
        for bytes in data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
            let line = Data(bytes)
            guard !line.isEmpty,
                  let record = try? decoder.decode(RunRecord.self, from: line),
                  let canonical = try? Self.canonicalRecordLine(record),
                  canonical == line else {
                throw RunLedgerTrustError.malformedStore
            }
            guard seenIDs.insert(record.id).inserted else {
                throw RunLedgerTrustError.conflictingRunID
            }
            records.append(record)
        }
        return records
    }

    private func encodeTrustStore(_ records: [RunRecord]) throws -> Data {
        var result = Data()
        for record in records {
            let line: Data
            do {
                line = try Self.canonicalRecordLine(record)
            } catch {
                throw RunLedgerTrustError.persistence("encode")
            }
            guard result.count <= Self.maximumTrustStoreBytes - line.count - 1 else {
                throw RunLedgerTrustError.persistence("store size limit")
            }
            result.append(line)
            result.append(0x0A)
        }
        return result
    }

    static func canonicalRecordLine(_ record: RunRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }

    static func canonicalRecordDigest(_ record: RunRecord) throws -> String {
        digest(try canonicalRecordLine(record))
    }

    /// Classify only projections which could have crossed `recordTrustCandidate`. This deliberately
    /// treats a syntactically trust-looking advisory row as protected after it is on disk: preserving
    /// a possible authority row is safer than allowing a later best-effort writer to erase it. It does
    /// not make the row green; the signed receipt and exact ledger digest remain independently required.
    private static func isTrustBoundProjection(_ record: RunRecord) -> Bool {
        guard record.success, record.verified,
              let projectIdentity = record.projectIdentity,
              let contractID = record.contractID,
              let objectiveFingerprint = record.objectiveFingerprint,
              let verificationSubject = record.verificationSubject,
              let verificationDigest = record.verificationDigest,
              let binding = try? AcceptedRunReceipt.Binding(
                  runID: record.id,
                  contractID: contractID,
                  exactGoal: record.goal,
                  projectIdentity: projectIdentity,
                  verificationSubject: verificationSubject,
                  verificationDigest: verificationDigest,
                  ledgerRecordDigest: String(repeating: "0", count: 64)) else {
            return false
        }
        return binding.objectiveFingerprint == objectiveFingerprint
    }

    private static func isCanonicalTrustBoundProjectionLine(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let record = try? JSONDecoder().decode(RunRecord.self, from: data),
              let canonical = try? canonicalRecordLine(record),
              canonical == data else {
            return false
        }
        return isTrustBoundProjection(record)
    }

    private static func digest(_ data: Data) -> String {
        MythosCrypto.sha256(data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseHexDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func writeTrustAtomicUnlocked(_ data: Data) throws {
        let fileURL = URL(fileURLWithPath: path)
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        var descriptor = open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw RunLedgerTrustError.persistence("create temporary")
        }
        var published = false
        defer {
            if descriptor >= 0 { _ = close(descriptor) }
            if !published { _ = unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(
                    descriptor, base.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw RunLedgerTrustError.persistence("write temporary")
                }
                guard written > 0 else {
                    throw RunLedgerTrustError.persistence("short write temporary")
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw RunLedgerTrustError.persistence("sync temporary")
        }
        guard close(descriptor) == 0 else {
            descriptor = -1
            throw RunLedgerTrustError.persistence("close temporary")
        }
        descriptor = -1
        guard rename(temporary.path, path) == 0 else {
            throw RunLedgerTrustError.persistence("publish ledger")
        }
        published = true
        let directoryDescriptor = open(
            directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else {
            throw RunLedgerTrustError.persistence("open ledger directory")
        }
        defer { _ = close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw RunLedgerTrustError.persistence("sync ledger directory")
        }
    }

    // MARK: - Convenience slices for the meta-loop (thin wrappers over pure RunAnalytics)

    /// Runs for one task class (signature), optionally scoped to one org config version.
    public func runs(signature: String, orgVersion: String? = nil) -> [RunRecord] {
        load().filter { $0.signature == signature && (orgVersion == nil || $0.orgVersion == orgVersion) }
    }

    /// The routing decisions the accumulated history says are systematically mis-sized.
    public func routingSignals(minSamples: Int = 8, threshold: Double = 0.25) -> [RunAnalytics.RoutingSignal] {
        RunAnalytics.routingSignals(load(), minSamples: minSamples, threshold: threshold)
    }

    /// The before/after lift of a config change on ONE task class: its runs under `before` vs `after`
    /// orgVersion. This is the honest "did the Captain's self-change actually help?" primitive.
    public func lift(signature: String, before: String, after: String, minSamples: Int = 8) -> RunAnalytics.Lift {
        let history = load().filter { $0.signature == signature }
        return RunAnalytics.lift(before: history.filter { $0.orgVersion == before },
                                 after: history.filter { $0.orgVersion == after },
                                 minSamples: minSamples)
    }
}
