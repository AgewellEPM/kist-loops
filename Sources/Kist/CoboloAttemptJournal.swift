import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct CoboloAttemptJournalBinding: Sendable, Equatable {
    let runID: String
    let contractID: String
    let projectRoot: String
    let maximumAttempts: Int

    func validate() throws {
        guard Self.isHexDigest(runID), Self.isHexDigest(contractID),
              !projectRoot.isEmpty, maximumAttempts > 0 else {
            throw CoboloAttemptJournalError.invalidBinding
        }
    }

    static func isHexDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }
}

struct CoboloAttemptAnchor: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let runID: String
    let contractID: String
    let projectRoot: String
    let maximumAttempts: Int
    let highWater: Int
    let pendingRevision: Int?
    let pendingPlanDigest: String?
    let seal: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case runID
        case contractID
        case projectRoot
        case maximumAttempts
        case highWater
        case pendingRevision
        case pendingPlanDigest
        case seal
    }

    var canonicalSealInput: String {
        [
            "schema=\(schemaVersion)",
            "run=\(ForgeSeal.field(runID))",
            "contract=\(ForgeSeal.field(contractID))",
            "root=\(ForgeSeal.field(projectRoot))",
            "maximum=\(maximumAttempts)",
            "high_water=\(highWater)",
            "pending_revision=\(pendingRevision.map(String.init) ?? "none")",
            "pending_plan=\(ForgeSeal.field(pendingPlanDigest ?? "none"))"
        ].joined(separator: "|")
    }

    static func make(binding: CoboloAttemptJournalBinding, highWater: Int,
                     pendingRevision: Int?, pendingPlanDigest: String?) throws -> Self {
        try binding.validate()
        let provisional = Self(
            schemaVersion: currentSchemaVersion,
            runID: binding.runID,
            contractID: binding.contractID,
            projectRoot: binding.projectRoot,
            maximumAttempts: binding.maximumAttempts,
            highWater: highWater,
            pendingRevision: pendingRevision,
            pendingPlanDigest: pendingPlanDigest,
            seal: ""
        )
        try provisional.validateShape()
        let seal = ForgeSeal.sign(provisional.canonicalSealInput)
        guard !seal.isEmpty else { throw CoboloAttemptJournalError.sealingUnavailable }
        return Self(
            schemaVersion: provisional.schemaVersion,
            runID: provisional.runID,
            contractID: provisional.contractID,
            projectRoot: provisional.projectRoot,
            maximumAttempts: provisional.maximumAttempts,
            highWater: provisional.highWater,
            pendingRevision: provisional.pendingRevision,
            pendingPlanDigest: provisional.pendingPlanDigest,
            seal: seal
        )
    }

    func validated(for binding: CoboloAttemptJournalBinding) throws -> Self {
        try binding.validate()
        guard runID == binding.runID,
              contractID == binding.contractID,
              projectRoot == binding.projectRoot,
              maximumAttempts == binding.maximumAttempts else {
            throw CoboloAttemptJournalError.bindingMismatch
        }
        try validateShape()
        guard ForgeSeal.verify(canonicalSealInput, seal: seal) else {
            throw CoboloAttemptJournalError.invalidSeal
        }
        return self
    }

    private func validateShape() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              CoboloAttemptJournalBinding.isHexDigest(runID),
              CoboloAttemptJournalBinding.isHexDigest(contractID),
              !projectRoot.isEmpty,
              maximumAttempts > 0,
              highWater >= 0,
              highWater <= maximumAttempts else {
            throw CoboloAttemptJournalError.invalidRecord
        }
        if highWater == 0 {
            guard pendingRevision == nil, pendingPlanDigest == nil else {
                throw CoboloAttemptJournalError.invalidRecord
            }
        } else {
            guard pendingRevision == highWater - 1,
                  let pendingPlanDigest,
                  CoboloAttemptJournalBinding.isHexDigest(pendingPlanDigest) else {
                throw CoboloAttemptJournalError.invalidRecord
            }
        }
    }
}

protocol CoboloAttemptJournal: Sendable {
    func load(binding: CoboloAttemptJournalBinding) throws -> CoboloAttemptAnchor?
    func create(binding: CoboloAttemptJournalBinding) throws -> CoboloAttemptAnchor
    func advance(binding: CoboloAttemptJournalBinding, expectedHighWater: Int,
                 revision: Int, planDigest: String) throws -> CoboloAttemptAnchor
}

enum CoboloAttemptJournalError: LocalizedError, Equatable {
    case unsafeRootOverlap
    case invalidBinding
    case invalidRecord
    case invalidSeal
    case bindingMismatch
    case missingRecord
    case nonPristineExistingRecord
    case counterMismatch(expected: Int, actual: Int)
    case exhausted
    case insecureStorage(String)
    case io(String)
    case sealingUnavailable

    var errorDescription: String? {
        switch self {
        case .unsafeRootOverlap:
            return "Cobolo attempt journal must be outside the governed project root"
        case .invalidBinding:
            return "Cobolo attempt journal binding is invalid"
        case .invalidRecord:
            return "Cobolo attempt journal record is malformed"
        case .invalidSeal:
            return "Cobolo attempt journal authentication failed"
        case .bindingMismatch:
            return "Cobolo attempt journal belongs to another contract or project"
        case .missingRecord:
            return "Cobolo attempt journal is missing"
        case .nonPristineExistingRecord:
            return "Cobolo attempt journal exists without matching durable run state"
        case .counterMismatch(let expected, let actual):
            return "Cobolo attempt journal counter mismatch: expected \(expected), found \(actual)"
        case .exhausted:
            return "Cobolo authenticated attempt cap is exhausted"
        case .insecureStorage(let detail):
            return "Cobolo attempt journal storage is insecure: \(detail)"
        case .io(let detail):
            return "Cobolo attempt journal I/O failed: \(detail)"
        case .sealingUnavailable:
            return "Cobolo attempt journal HMAC sealing is unavailable"
        }
    }
}

final class CoboloMemoryAttemptJournal: CoboloAttemptJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: CoboloAttemptAnchor] = [:]

    func load(binding: CoboloAttemptJournalBinding) throws -> CoboloAttemptAnchor? {
        try binding.validate()
        return try lock.withLock {
            try records[binding.runID]?.validated(for: binding)
        }
    }

    func create(binding: CoboloAttemptJournalBinding) throws -> CoboloAttemptAnchor {
        try binding.validate()
        return try lock.withLock {
            if let existing = records[binding.runID] {
                let validated = try existing.validated(for: binding)
                guard validated.highWater == 0 else {
                    throw CoboloAttemptJournalError.nonPristineExistingRecord
                }
                return validated
            }
            let created = try CoboloAttemptAnchor.make(
                binding: binding, highWater: 0,
                pendingRevision: nil, pendingPlanDigest: nil)
            records[binding.runID] = created
            return created
        }
    }

    func advance(binding: CoboloAttemptJournalBinding, expectedHighWater: Int,
                 revision: Int, planDigest: String) throws -> CoboloAttemptAnchor {
        try binding.validate()
        return try lock.withLock {
            guard let stored = records[binding.runID] else {
                throw CoboloAttemptJournalError.missingRecord
            }
            let current = try stored.validated(for: binding)
            guard current.highWater == expectedHighWater else {
                throw CoboloAttemptJournalError.counterMismatch(
                    expected: expectedHighWater, actual: current.highWater)
            }
            guard revision == expectedHighWater,
                  CoboloAttemptJournalBinding.isHexDigest(planDigest) else {
                throw CoboloAttemptJournalError.invalidRecord
            }
            guard current.highWater < binding.maximumAttempts else {
                throw CoboloAttemptJournalError.exhausted
            }
            let advanced = try CoboloAttemptAnchor.make(
                binding: binding, highWater: current.highWater + 1,
                pendingRevision: revision, pendingPlanDigest: planDigest)
            records[binding.runID] = advanced
            return advanced
        }
    }

    func removeAllForTesting() {
        lock.withLock { records.removeAll() }
    }

    func replaceForTesting(_ anchor: CoboloAttemptAnchor) {
        lock.withLock { records[anchor.runID] = anchor }
    }
}

final class CoboloFileAttemptJournal: CoboloAttemptJournal, @unchecked Sendable {
    private static let processLock = NSLock()
    private static let maximumRecordBytes = 65_536

    let baseDirectory: String

    init(baseDirectory: String? = nil, projectRoot: String) throws {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let requested = baseDirectory ?? home + "/.mythos/cobolo-attempts-v1"
        let canonicalProject = Self.canonical(projectRoot)
        let canonicalBase = Self.canonical(requested)
        guard !Self.contains(parent: canonicalProject, child: canonicalBase),
              !Self.contains(parent: canonicalBase, child: canonicalProject) else {
            throw CoboloAttemptJournalError.unsafeRootOverlap
        }
        self.baseDirectory = canonicalBase
        try prepareDirectory()
    }

    func load(binding: CoboloAttemptJournalBinding) throws -> CoboloAttemptAnchor? {
        try binding.validate()
        return try withLockedDirectory(runID: binding.runID) { directoryFD in
            try readRecord(directoryFD: directoryFD, binding: binding)
        }
    }

    func create(binding: CoboloAttemptJournalBinding) throws -> CoboloAttemptAnchor {
        try binding.validate()
        return try withLockedDirectory(runID: binding.runID) { directoryFD in
            if let existing = try readRecord(directoryFD: directoryFD, binding: binding) {
                guard existing.highWater == 0 else {
                    throw CoboloAttemptJournalError.nonPristineExistingRecord
                }
                return existing
            }
            let created = try CoboloAttemptAnchor.make(
                binding: binding, highWater: 0,
                pendingRevision: nil, pendingPlanDigest: nil)
            try writeRecord(created, directoryFD: directoryFD)
            return created
        }
    }

    func advance(binding: CoboloAttemptJournalBinding, expectedHighWater: Int,
                 revision: Int, planDigest: String) throws -> CoboloAttemptAnchor {
        try binding.validate()
        return try withLockedDirectory(runID: binding.runID) { directoryFD in
            guard let current = try readRecord(directoryFD: directoryFD, binding: binding) else {
                throw CoboloAttemptJournalError.missingRecord
            }
            guard current.highWater == expectedHighWater else {
                throw CoboloAttemptJournalError.counterMismatch(
                    expected: expectedHighWater, actual: current.highWater)
            }
            guard revision == expectedHighWater,
                  CoboloAttemptJournalBinding.isHexDigest(planDigest) else {
                throw CoboloAttemptJournalError.invalidRecord
            }
            guard current.highWater < binding.maximumAttempts else {
                throw CoboloAttemptJournalError.exhausted
            }
            let advanced = try CoboloAttemptAnchor.make(
                binding: binding, highWater: current.highWater + 1,
                pendingRevision: revision, pendingPlanDigest: planDigest)
            try writeRecord(advanced, directoryFD: directoryFD)
            return advanced
        }
    }

    private func prepareDirectory() throws {
        let parent = (baseDirectory as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true)
        } catch {
            throw CoboloAttemptJournalError.io("cannot create journal parent: \(error.localizedDescription)")
        }
        if mkdir(baseDirectory, mode_t(0o700)) != 0, errno != EEXIST {
            throw CoboloAttemptJournalError.io("cannot create journal directory: \(Self.systemError())")
        }
        let fd = open(baseDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw CoboloAttemptJournalError.insecureStorage("journal directory is not a real directory")
        }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw CoboloAttemptJournalError.insecureStorage(
                "journal directory must be owner-owned mode 0700")
        }
    }

    private func withLockedDirectory<T>(
        runID: String, _ body: (Int32) throws -> T
    ) throws -> T {
        guard CoboloAttemptJournalBinding.isHexDigest(runID) else {
            throw CoboloAttemptJournalError.invalidBinding
        }
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try prepareDirectory()
        let directoryFD = open(baseDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw CoboloAttemptJournalError.insecureStorage("cannot open journal directory")
        }
        defer { close(directoryFD) }
        let lockName = "\(runID).lock"
        let lockFD = openat(
            directoryFD, lockName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600))
        guard lockFD >= 0 else {
            throw CoboloAttemptJournalError.insecureStorage("cannot securely open journal lock")
        }
        defer {
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
        }
        var lockStatus = stat()
        guard fchmod(lockFD, mode_t(0o600)) == 0,
              fstat(lockFD, &lockStatus) == 0,
              lockStatus.st_uid == getuid(),
              lockStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              lockStatus.st_mode & mode_t(0o7777) == mode_t(0o600),
              flock(lockFD, LOCK_EX) == 0 else {
            throw CoboloAttemptJournalError.insecureStorage(
                "journal lock must be an owner-only regular file")
        }
        return try body(directoryFD)
    }

    private func readRecord(
        directoryFD: Int32, binding: CoboloAttemptJournalBinding
    ) throws -> CoboloAttemptAnchor? {
        let name = "\(binding.runID).json"
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw CoboloAttemptJournalError.insecureStorage("cannot securely open journal record")
        }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_mode & mode_t(0o7777) == mode_t(0o600),
              status.st_size >= 0,
              status.st_size <= off_t(Self.maximumRecordBytes) else {
            throw CoboloAttemptJournalError.insecureStorage(
                "journal record must be owner-owned mode 0600 and bounded")
        }
        let data = try Self.readAll(fd: fd, expectedBytes: Int(status.st_size))
        let allowedKeys = Set(CoboloAttemptAnchor.CodingKeys.allCases.map(\.rawValue))
        let requiredKeys: Set<String> = [
            "schemaVersion", "runID", "contractID", "projectRoot",
            "maximumAttempts", "highWater", "seal",
        ]
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: allowedKeys),
              requiredKeys.isSubset(of: Set(object.keys)),
              let decoded = try? JSONDecoder().decode(CoboloAttemptAnchor.self, from: data) else {
            throw CoboloAttemptJournalError.invalidRecord
        }
        return try decoded.validated(for: binding)
    }

    private func writeRecord(_ record: CoboloAttemptAnchor, directoryFD: Int32) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(record)
        } catch {
            throw CoboloAttemptJournalError.io("cannot encode journal record")
        }
        guard data.count <= Self.maximumRecordBytes else {
            throw CoboloAttemptJournalError.invalidRecord
        }
        let finalName = "\(record.runID).json"
        let temporaryName = ".\(record.runID)-\(UUID().uuidString).tmp"
        let fd = openat(
            directoryFD, temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600))
        guard fd >= 0 else {
            throw CoboloAttemptJournalError.io("cannot securely create journal temp")
        }
        var renamed = false
        defer {
            close(fd)
            if !renamed { _ = unlinkat(directoryFD, temporaryName, 0) }
        }
        try Self.writeAll(data, fd: fd)
        guard Self.sync(fd) else {
            throw CoboloAttemptJournalError.io("journal temp fsync failed")
        }
        var status = stat()
        guard fstat(fd, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_mode & mode_t(0o7777) == mode_t(0o600) else {
            throw CoboloAttemptJournalError.insecureStorage(
                "journal temp is not owner-only mode 0600")
        }
        guard renameat(directoryFD, temporaryName, directoryFD, finalName) == 0 else {
            throw CoboloAttemptJournalError.io("journal atomic rename failed: \(Self.systemError())")
        }
        renamed = true
        guard Self.sync(directoryFD) else {
            throw CoboloAttemptJournalError.io("journal directory fsync failed")
        }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func contains(parent: String, child: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private static func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw CoboloAttemptJournalError.io("journal temp write failed")
                }
                offset += count
            }
        }
    }

    private static func readAll(fd: Int32, expectedBytes: Int) throws -> Data {
        var output = Data()
        output.reserveCapacity(expectedBytes)
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(fd, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw CoboloAttemptJournalError.io("journal record read failed")
            }
            if count == 0 { break }
            output.append(contentsOf: buffer[0..<count])
            guard output.count <= maximumRecordBytes else {
                throw CoboloAttemptJournalError.invalidRecord
            }
        }
        return output
    }

    private static func sync(_ fd: Int32) -> Bool {
        for attempt in 0..<3 {
            if fsync(fd) == 0 { return true }
            if errno != EINTR || attempt == 2 { return false }
        }
        return false
    }

    private static func systemError() -> String {
        String(cString: strerror(errno))
    }
}

enum CoboloAttemptJournalFactory {
    private static let testJournal = CoboloMemoryAttemptJournal()

    static func make(projectRoot: String) throws -> any CoboloAttemptJournal {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || CommandLine.arguments.contains(where: { $0.hasSuffix(".xctest") || $0.contains(".xctest/") })
        {
            return testJournal
        }
        return try CoboloFileAttemptJournal(projectRoot: projectRoot)
    }
}
