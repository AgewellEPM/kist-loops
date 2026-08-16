import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum WorkspaceExecutionCoordinatorError: Error, Sendable, Equatable {
    case invalidProjectRoot(String)
    case insecureLockDirectory(String)
    case insecureLockFile(String)
    case lockUnavailable(String)
    case systemCall(String, Int32)
}

/// Kernel-backed authority for one canonical project root. Metadata in the lock file is diagnostic;
/// possession of this open, flocked descriptor is the authority.
public final class WorkspaceExecutionLease: @unchecked Sendable {
    public let canonicalProjectRoot: String
    public let missionInstanceID: String
    public let lockFileURL: URL

    private let stateLock = NSLock()
    private var descriptor: Int32?

    fileprivate init(canonicalProjectRoot: String, missionInstanceID: String,
                     lockFileURL: URL, descriptor: Int32) {
        self.canonicalProjectRoot = canonicalProjectRoot
        self.missionInstanceID = missionInstanceID
        self.lockFileURL = lockFileURL
        self.descriptor = descriptor
    }

    public func release() {
        stateLock.lock()
        let owned = descriptor
        descriptor = nil
        stateLock.unlock()
        guard let owned else { return }
        _ = flock(owned, LOCK_UN)
        _ = close(owned)
    }

    deinit { release() }
}

/// Serializes workspace digest, mutation, receipt, and checkpoint publication across processes.
/// The default lock estate is stable and user-private, so symlink aliases of a project contend on
/// the same SHA-256(realpath(root)) lock rather than creating repository-local split authority.
public struct WorkspaceExecutionCoordinator: Sendable {
    public let lockDirectory: URL

    public init(lockDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".kist", isDirectory: true)
        .appendingPathComponent("workspace-locks", isDirectory: true)) {
        self.lockDirectory = lockDirectory
    }

    public func acquire(projectRoot: String, missionInstanceID: String,
                        blocking: Bool = true) throws -> WorkspaceExecutionLease {
        guard !missionInstanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceExecutionCoordinatorError.invalidProjectRoot(
                "mission instance ID is empty")
        }
        let canonicalRoot = try canonicalProjectRoot(projectRoot)
        try preparePrivateLockEstate()
        let key = SHA256.hash(data: Data(canonicalRoot.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let lockURL = lockDirectory.appendingPathComponent(key + ".lock", isDirectory: false)
        let descriptor = open(lockURL.path,
                              O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                              mode_t(0o600))
        guard descriptor >= 0 else { throw systemError("open workspace lock") }
        var retained = false
        defer { if !retained { _ = close(descriptor) } }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              (status.st_mode & mode_t(0o077)) == 0 else {
            throw WorkspaceExecutionCoordinatorError.insecureLockFile(lockURL.path)
        }
        let operation = blocking ? LOCK_EX : (LOCK_EX | LOCK_NB)
        guard flock(descriptor, operation) == 0 else {
            if !blocking && (errno == EWOULDBLOCK || errno == EAGAIN) {
                throw WorkspaceExecutionCoordinatorError.lockUnavailable(canonicalRoot)
            }
            throw systemError("acquire workspace lock")
        }
        do {
            try writeMetadata(descriptor: descriptor, canonicalRoot: canonicalRoot,
                              missionInstanceID: missionInstanceID)
        } catch {
            _ = flock(descriptor, LOCK_UN)
            throw error
        }
        retained = true
        return WorkspaceExecutionLease(canonicalProjectRoot: canonicalRoot,
                                       missionInstanceID: missionInstanceID,
                                       lockFileURL: lockURL, descriptor: descriptor)
    }

    public func withExclusiveLease<T>(projectRoot: String, missionInstanceID: String,
                                      _ operation: (WorkspaceExecutionLease) throws -> T) throws -> T {
        let lease = try acquire(projectRoot: projectRoot, missionInstanceID: missionInstanceID)
        defer { lease.release() }
        return try operation(lease)
    }

    private func canonicalProjectRoot(_ projectRoot: String) throws -> String {
        guard let pointer = realpath(projectRoot, nil) else {
            throw WorkspaceExecutionCoordinatorError.invalidProjectRoot(projectRoot)
        }
        defer { free(pointer) }
        let canonical = String(cString: pointer)
        var status = stat()
        guard lstat(canonical, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
            throw WorkspaceExecutionCoordinatorError.invalidProjectRoot(projectRoot)
        }
        return canonical
    }

    private func preparePrivateLockEstate() throws {
        let parent = lockDirectory.deletingLastPathComponent()
        try secureDirectory(parent)
        try secureDirectory(lockDirectory)
    }

    private func secureDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            var preflight = stat()
            guard lstat(url.path, &preflight) == 0,
                  (preflight.st_mode & S_IFMT) == S_IFDIR else {
                throw WorkspaceExecutionCoordinatorError.insecureLockDirectory(url.path)
            }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        }
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            throw WorkspaceExecutionCoordinatorError.insecureLockDirectory(url.path)
        }
        guard chmod(url.path, mode_t(0o700)) == 0 else {
            throw systemError("secure workspace lock directory")
        }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw WorkspaceExecutionCoordinatorError.insecureLockDirectory(url.path)
        }
        _ = close(descriptor)
    }

    private func writeMetadata(descriptor: Int32, canonicalRoot: String,
                               missionInstanceID: String) throws {
        let metadata: [String: Any] = [
            "canonical_project_root": canonicalRoot,
            "mission_instance_id": missionInstanceID,
            "pid": Int(getpid()),
            "acquired_at": Date().timeIntervalSince1970,
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw systemError("reset workspace lock metadata")
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError("write workspace lock metadata")
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw systemError("sync workspace lock metadata") }
    }

    private func systemError(_ operation: String) -> WorkspaceExecutionCoordinatorError {
        .systemCall(operation, errno)
    }
}
