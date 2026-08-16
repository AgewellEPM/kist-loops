import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum BuilderDurableIOError: Error, LocalizedError {
    case unsafeFile(String)
    case oversizedFile(String)
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeFile(let path): return "Unsafe durable builder file: \(path)"
        case .oversizedFile(let path): return "Durable builder file is oversized: \(path)"
        case .system(let operation, let code):
            return "\(operation): \(String(cString: strerror(code)))"
        }
    }
}

enum BuilderDurableIO {
    static let maximumBytes = 8 * 1_024 * 1_024

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func readSecure(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw system("open durable builder file") }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw system("inspect durable builder file") }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (info.st_mode & mode_t(0o077)) == 0 else {
            throw BuilderDurableIOError.unsafeFile(url.path)
        }
        guard info.st_size >= 0, info.st_size <= off_t(maximumBytes) else {
            throw BuilderDurableIOError.oversizedFile(url.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= maximumBytes else { throw BuilderDurableIOError.oversizedFile(url.path) }
        return data
    }

    static func writeAtomic(_ data: Data, to url: URL) throws {
        guard data.count <= maximumBytes else { throw BuilderDurableIOError.oversizedFile(url.path) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            throw system("secure durable builder directory")
        }
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path,
                              O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                              mode_t(0o600))
        guard descriptor >= 0 else { throw system("create durable builder temporary") }
        var published = false
        defer {
            _ = close(descriptor)
            if !published { _ = unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw system("write durable builder temporary")
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw system("sync durable builder temporary") }
        guard rename(temporary.path, url.path) == 0 else { throw system("publish durable builder file") }
        published = true
        guard chmod(url.path, mode_t(0o600)) == 0 else { throw system("secure durable builder file") }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw system("open durable builder directory") }
        defer { _ = close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw system("sync durable builder directory") }
    }

    static func writeExclusive(_ data: Data, to url: URL) throws {
        guard data.count <= maximumBytes else { throw BuilderDurableIOError.oversizedFile(url.path) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            throw system("secure durable builder directory")
        }
        let descriptor = open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else { throw system("create durable builder file") }
        var complete = false
        defer {
            _ = close(descriptor)
            if !complete { _ = unlink(url.path) }
        }
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else { throw system("sync durable builder file") }
        let directoryDescriptor = open(
            directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw system("open durable builder directory") }
        defer { _ = close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw system("sync durable builder directory")
        }
        complete = true
    }

    static func appendDurable(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            throw system("secure durable builder directory")
        }
        let descriptor = open(
            url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else { throw system("open durable builder journal") }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw system("lock durable builder journal")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else { throw system("sync durable builder journal") }
        let directoryDescriptor = open(
            directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw system("open durable builder directory") }
        defer { _ = close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw system("sync durable builder directory")
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw system("write durable builder file")
                }
                offset += count
            }
        }
    }

    private static func system(_ operation: String) -> BuilderDurableIOError {
        .system(operation, errno)
    }
}
