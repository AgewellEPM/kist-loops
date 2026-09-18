import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Full immutable history of a retired task. Archiving does not erase evidence or release its ID.
public struct SMLRuntimeArchivedTask: Sendable, Codable, Equatable {
    public let task: SMLRuntimeTask
    public let workflow: SMLRuntimeWorkflowRecord
    public let receipts: [SMLRuntimeReceipt]
}

struct SMLRuntimeArchiveObject: Sendable, Codable {
    let task: SMLRuntimeArchivedTask?
    let pivot: String?
    let left: String?
    let right: String?
}

extension SMLRuntimeStore {
    var archiveObjectsURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("archive/objects", isDirectory: true)
    }

    static func maintenanceDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func maintenanceEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func isArchiveDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    func archiveObjectURL(_ digest: String) throws -> URL {
        guard Self.isArchiveDigest(digest) else {
            throw SMLRuntimeStoreError.decoding("invalid archive object digest")
        }
        return archiveObjectsURL.appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest + ".json")
    }

    func readArchiveObject(_ digest: String) throws -> (SMLRuntimeArchiveObject, Data) {
        let data = try Self.readMaintenanceFile(archiveObjectURL(digest))
        guard Self.maintenanceDigest(data) == digest else {
            throw SMLRuntimeStoreError.decoding("archive object checksum mismatch: \(digest)")
        }
        return (try JSONDecoder().decode(SMLRuntimeArchiveObject.self, from: data), data)
    }

    func writeArchiveObject(_ data: Data, digest: String) throws {
        guard Self.maintenanceDigest(data) == digest else {
            throw SMLRuntimeStoreError.decoding("archive object checksum mismatch")
        }
        let url = try archiveObjectURL(digest)
        try Self.createDurableMaintenanceDirectory(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Self.readMaintenanceFile(url) == data else {
                throw SMLRuntimeStoreError.decoding("existing immutable archive object differs")
            }
        } else {
            try Self.writeDurableAtomic(data, to: url)
        }
    }

    /// O(log archived task count), without loading archived payloads into mutable runtime state.
    public func archivedTask(id: String) throws -> SMLRuntimeArchivedTask? {
        try withSidecarLock(exclusive: false) {
            try archivedTaskUnlocked(id: id, root: loadUnlocked().archiveRoot)
        }
    }

    func archivedTaskUnlocked(id: String, root: String?) throws -> SMLRuntimeArchivedTask? {
        var next = root
        var visited = Set<String>()
        while let digest = next {
            guard visited.insert(digest).inserted, visited.count <= 128 else {
                throw SMLRuntimeStoreError.decoding("archive index cycle or excessive depth")
            }
            let (object, _) = try readArchiveObject(digest)
            if let archived = object.task {
                guard object.pivot == nil, object.left == nil, object.right == nil else {
                    throw SMLRuntimeStoreError.decoding("malformed archive leaf")
                }
                return archived.task.taskID == id ? archived : nil
            }
            guard let pivot = object.pivot, let left = object.left, let right = object.right else {
                throw SMLRuntimeStoreError.decoding("malformed archive index branch")
            }
            next = id < pivot ? left : right
        }
        return nil
    }

    /// Explicit history queries may scan history; ordinary dispatch/load/write operations do not.
    public func archivedTasks() throws -> [SMLRuntimeArchivedTask] {
        try withSidecarLock(exclusive: false) {
            var objects: [String: Data] = [:]
            return try collectArchive(root: loadUnlocked().archiveRoot, objects: &objects)
        }
    }

    func collectArchive(root: String?, objects: inout [String: Data]) throws -> [SMLRuntimeArchivedTask] {
        guard let root else { return [] }
        var visited = Set<String>()
        func walk(_ digest: String, depth: Int) throws -> [SMLRuntimeArchivedTask] {
            guard depth <= 128, visited.insert(digest).inserted else {
                throw SMLRuntimeStoreError.decoding("archive index cycle, duplicate child, or excessive depth")
            }
            let (object, data) = try readArchiveObject(digest)
            objects[digest] = data
            if let task = object.task {
                guard object.pivot == nil, object.left == nil, object.right == nil else {
                    throw SMLRuntimeStoreError.decoding("malformed archive leaf")
                }
                return [task]
            }
            guard let pivot = object.pivot, let left = object.left, let right = object.right else {
                throw SMLRuntimeStoreError.decoding("malformed archive branch")
            }
            let lower = try walk(left, depth: depth + 1)
            let upper = try walk(right, depth: depth + 1)
            guard let last = lower.last, let first = upper.first,
                  last.task.taskID < pivot, first.task.taskID == pivot else {
                throw SMLRuntimeStoreError.decoding("archive index ordering mismatch")
            }
            return lower + upper
        }
        return try walk(root, depth: 0)
    }

    func buildArchive(_ tasks: [SMLRuntimeArchivedTask]) throws -> String? {
        let sorted = tasks.sorted { $0.task.taskID < $1.task.taskID }
        guard Set(sorted.map { $0.task.taskID }).count == sorted.count else {
            throw SMLRuntimeStoreError.decoding("duplicate archived task ID")
        }
        func build(_ slice: ArraySlice<SMLRuntimeArchivedTask>) throws -> String {
            let object: SMLRuntimeArchiveObject
            if slice.count == 1 {
                object = SMLRuntimeArchiveObject(task: slice.first!, pivot: nil, left: nil, right: nil)
            } else {
                let mid = slice.startIndex + slice.count / 2
                object = SMLRuntimeArchiveObject(task: nil, pivot: slice[mid].task.taskID,
                    left: try build(slice[..<mid]), right: try build(slice[mid...]))
            }
            let data = try Self.maintenanceEncode(object)
            let digest = Self.maintenanceDigest(data)
            try writeArchiveObject(data, digest: digest)
            return digest
        }
        return sorted.isEmpty ? nil : try build(sorted[...])
    }

    /// Branches contain only disposable index metadata. Leaf objects containing receipts are never
    /// deleted. Old backup bundles carry their own complete graph and do not depend on these files.
    func pruneUnreferencedArchiveBranches(root: String?) throws {
        var reachable: [String: Data] = [:]
        _ = try collectArchive(root: root, objects: &reachable)
        guard let enumerator = FileManager.default.enumerator(at: archiveObjectsURL,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let digest = url.deletingPathExtension().lastPathComponent
            guard Self.isArchiveDigest(digest), reachable[digest] == nil else { continue }
            let data = try Self.readMaintenanceFile(url)
            guard Self.maintenanceDigest(data) == digest else {
                throw SMLRuntimeStoreError.decoding("unreferenced archive object is corrupt")
            }
            let object = try JSONDecoder().decode(SMLRuntimeArchiveObject.self, from: data)
            if object.task == nil { try FileManager.default.removeItem(at: url) }
        }
    }

    static func createDurableMaintenanceDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw SMLRuntimeStoreError.io("maintenance directory is not a directory")
            }
            return
        }
        guard errno == ENOENT else { throw posixIOError("inspect maintenance directory") }
        let parent = directory.deletingLastPathComponent()
        try createDurableMaintenanceDirectory(parent)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let descriptor = try openStoreDirectory(parent)
        defer { _ = close(descriptor) }
        try synchronizeDirectory(descriptor)
    }

    static func readMaintenanceFile(_ url: URL, maximumBytes: Int = 512 * 1_024 * 1_024) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixIOError("open maintenance file \(url.lastPathComponent)") }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= maximumBytes else {
            throw SMLRuntimeStoreError.io("maintenance input must be an owned regular file within \(maximumBytes) bytes")
        }
        let data = try readAll(descriptor)
        guard data.count <= maximumBytes else { throw SMLRuntimeStoreError.io("maintenance input exceeded byte limit") }
        return data
    }
}
