import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Internal fault-injection checkpoints. No request, permit or CLI selects these.
enum OperatorActionResultCheckpoint: Sendable, Equatable {
    case workspaceLeaseAcquired, effectObserved, resultCreated, resultWritten, resultFileSynced, resultDirectorySynced
}

/// Descriptor-relative metadata and single-use publication. This intentionally does not
/// follow symlinks, repair permissions, create authority directories, or migrate grants.
final class OperatorActionDirectory {
    let path: String
    let descriptor: Int32
    let device: String
    let inode: String

    init(path: String, ownerPrivate: Bool = false) throws {
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4096,
              path == path.precomposedStringWithCanonicalMapping,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw OperatorActionValidation.Failure.unsafe
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.isEmpty, components.count <= 64,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw OperatorActionValidation.Failure.unsafe
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OperatorActionValidation.Failure.io }
        var retained = false
        defer { if !retained { close(fd) } }
        for component in components {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw OperatorActionValidation.Failure.unsafe }
            close(fd)
            fd = next
        }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == geteuid(), status.st_mode & mode_t(0o022) == 0 else {
            throw OperatorActionValidation.Failure.unsafe
        }
        if ownerPrivate && status.st_mode & mode_t(0o7777) != mode_t(0o700) {
            throw OperatorActionValidation.Failure.unsafe
        }
        self.path = path
        descriptor = fd
        device = String(status.st_dev)
        inode = String(status.st_ino)
        retained = true
    }

    deinit { close(descriptor) }

    func revalidate() throws {
        let current = try OperatorActionDirectory(path: path)
        guard current.device == device, current.inode == inode else {
            throw OperatorActionValidation.Failure.unsafe
        }
    }

    func privateFile(_ name: String, maximumBytes: Int) throws -> Data {
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw OperatorActionValidation.Failure.unsafe }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1,
              before.st_uid == geteuid(), before.st_mode & mode_t(0o7777) == mode_t(0o600),
              before.st_size > 0, before.st_size <= maximumBytes else {
            throw OperatorActionValidation.Failure.unsafe
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(maximumBytes + 1, 4096))
        while data.count <= maximumBytes {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw OperatorActionValidation.Failure.io }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var named = stat()
        guard data.count <= maximumBytes, fstat(fd, &after) == 0,
              fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameFile(before, after), Self.sameFile(after, named),
              data.count == Int(after.st_size) else { throw OperatorActionValidation.Failure.unsafe }
        return data
    }

    /// Returns only after both the O_EXCL marker and its directory entry have been synced.
    /// A marker is never removed, even when dispatch or response delivery fails afterwards.
    func consume(name: String, data: Data) throws {
        let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else {
            if errno == EEXIST { throw OperatorActionValidation.Failure.replayed }
            throw OperatorActionValidation.Failure.io
        }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw OperatorActionValidation.Failure.io }
                offset += count
            }
        }
        guard fsync(fd) == 0, fsync(descriptor) == 0 else { throw OperatorActionValidation.Failure.io }
    }

    func requireUnused(name: String) throws {
        var status = stat()
        if fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            throw OperatorActionValidation.Failure.replayed
        }
        guard errno == ENOENT else { throw OperatorActionValidation.Failure.io }
    }

    /// Result names come only from the validated action UUID. A result is local
    /// same-attempt evidence, never an acceptance or historical recovery authority.
    static func resultName(actionID: String) throws -> String {
        guard OperatorActionValidation.uuid(actionID) != nil else {
            throw OperatorActionValidation.Failure.invalid
        }
        return ".result-v1-" + actionID.lowercased() + ".json"
    }

    func requireResultAbsent(actionID: String) throws {
        let name = try Self.resultName(actionID: actionID)
        try revalidateResultAuthority()
        var status = stat()
        if fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            throw OperatorActionValidation.Failure.unsafe
        }
        guard errno == ENOENT else { throw OperatorActionValidation.Failure.io }
        try revalidateResultAuthority()
    }

    /// Immutable publication after the typed effect was observed. A failed write
    /// leaves its slot intact: partial bytes can never be replaced or retried.
    /// Both the private regular file and its parent must be synced before return.
    func publishResult(actionID: String, data: Data,
                       checkpoint: @Sendable (OperatorActionResultCheckpoint) throws -> Void = { _ in }) throws {
        guard !data.isEmpty, data.count <= OperatorActionHost.maximumResultBytes else {
            throw OperatorActionValidation.Failure.invalid
        }
        let name = try Self.resultName(actionID: actionID)
        try requireResultAbsent(actionID: actionID)
        let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw OperatorActionValidation.Failure.io }
        defer { close(fd) }
        var created = stat()
        guard fstat(fd, &created) == 0 else { throw OperatorActionValidation.Failure.io }
        try checkpoint(.resultCreated)
        try validateResultFile(fd: fd, name: name, created: created, bytes: 0)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw OperatorActionValidation.Failure.io }
                offset += count
            }
        }
        try checkpoint(.resultWritten)
        try validateResultFile(fd: fd, name: name, created: created, bytes: data.count)
        guard fsync(fd) == 0 else { throw OperatorActionValidation.Failure.io }
        try checkpoint(.resultFileSynced)
        try revalidateResultAuthority()
        try validateResultFile(fd: fd, name: name, created: created, bytes: data.count)
        guard fsync(descriptor) == 0 else { throw OperatorActionValidation.Failure.io }
        try checkpoint(.resultDirectorySynced)
        try revalidateResultAuthority()
        try validateResultFile(fd: fd, name: name, created: created, bytes: data.count)
        guard try privateFile(name, maximumBytes: OperatorActionHost.maximumResultBytes) == data else {
            throw OperatorActionValidation.Failure.unsafe
        }
    }

    private func revalidateResultAuthority() throws {
        let current = try OperatorActionDirectory(path: path, ownerPrivate: true)
        var pinned = stat()
        guard current.device == device, current.inode == inode,
              fstat(descriptor, &pinned) == 0, String(pinned.st_dev) == device,
              String(pinned.st_ino) == inode, pinned.st_uid == geteuid(),
              pinned.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              pinned.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw OperatorActionValidation.Failure.unsafe
        }
    }

    private func validateResultFile(fd: Int32, name: String, created: stat, bytes: Int) throws {
        var current = stat(), named = stat()
        guard fstat(fd, &current) == 0,
              fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == created.st_dev, current.st_ino == created.st_ino,
              current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              current.st_mode & mode_t(0o7777) == mode_t(0o600),
              current.st_uid == geteuid(), current.st_nlink == 1, current.st_size == bytes,
              Self.sameFile(current, named) else { throw OperatorActionValidation.Failure.unsafe }
    }

    /// A create-only baseline must be absent, not merely unreadable. Inspect the
    /// leaf without opening it, so links, directories and FIFOs are conflicts too.
    /// This preflight grants no publication authority; conditionalReplace repeats
    /// its own checks at the mutation edge while the caller retains the lease.
    func requireMissingTarget(_ relativePath: String) throws {
        try OperatorActionValidation.mutationPath(relativePath)
        try revalidate()
        let components = relativePath.split(separator: "/").map(String.init)
        var parent = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard parent >= 0 else { throw OperatorActionValidation.Failure.io }
        defer { close(parent) }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw OperatorActionValidation.Failure.unsafe }
            close(parent)
            parent = next
        }
        var status = stat()
        let result = fstatat(parent, components.last!, &status, AT_SYMLINK_NOFOLLOW)
        let failure = errno
        guard result == 0 || failure == ENOENT else { throw OperatorActionValidation.Failure.io }
        try revalidate()
        guard result != 0 else { throw OperatorActionValidation.Failure.stale }
    }

    func entries(_ relativePath: String, maximumScanned: Int = 512) throws -> [OperatorActionDirectoryEntry] {
        var fd = dup(descriptor)
        guard fd >= 0 else { throw OperatorActionValidation.Failure.io }
        if relativePath != "." {
            for component in relativePath.split(separator: "/") {
                let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                close(fd)
                guard next >= 0 else { throw OperatorActionValidation.Failure.unsafe }
                fd = next
            }
        }
        guard let directory = fdopendir(fd) else {
            close(fd)
            throw OperatorActionValidation.Failure.io
        }
        defer { closedir(directory) }
        var result: [OperatorActionDirectoryEntry] = []
        var scanned = 0
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw OperatorActionValidation.Failure.io }
                break
            }
            scanned += 1
            guard scanned <= maximumScanned else { throw OperatorActionValidation.Failure.invalid }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw OperatorActionValidation.Failure.unsafe }
            if name == "." || name == ".." { continue }
            // Omit protected control/secret stores rather than disclose their names or contents.
            guard (try? OperatorActionValidation.relativePath(name)) != nil else { continue }
            var status = stat()
            guard fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw OperatorActionValidation.Failure.unsafe
            }
            let type = status.st_mode & mode_t(S_IFMT)
            let kind = type == mode_t(S_IFREG) ? "file" : type == mode_t(S_IFDIR) ? "directory" : "unavailable"
            result.append(.init(name: name, kind: kind))
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        guard a.st_dev == b.st_dev, a.st_ino == b.st_ino, a.st_size == b.st_size,
              a.st_mode == b.st_mode, a.st_uid == b.st_uid, a.st_nlink == b.st_nlink else { return false }
        #if canImport(Darwin)
        return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        #else
        return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec
            && a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec
        #endif
    }
}
