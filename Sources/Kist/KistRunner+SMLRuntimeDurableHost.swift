import Foundation
import AgentCore

/// How an SML runtime host session is provisioned.
///
/// `.ephemeralExport` is the offline install-proof posture: throwaway store, frozen clock,
/// rubber-stamp authority, workflow-derived catalog. `.durable` is the live posture: persistent
/// store at `<root>/.kist/sml/runtime.json`, real clock, deny-by-default authority from
/// `authority.json`, human-reviewed catalog from `catalog.json`, and an exclusive host lock so two
/// mutating hosts can never interleave one store's in-memory admission state.
enum SMLRuntimeHostMode: Sendable {
    case ephemeralExport
    case durable
}

enum SMLRuntimeDurableHostError: Error, CustomStringConvertible {
    case lockDirectoryUnavailable(path: String, reason: String)
    case lockUnavailable(path: String)
    case lockFailed(path: String, reason: String)

    var description: String {
        switch self {
        case .lockDirectoryUnavailable(let path, let reason):
            return "cannot prepare SML host directory \(path): \(reason)"
        case .lockUnavailable(let path):
            return "another SML runtime host holds \(path) — stop it (or wait for its one-shot "
                + "command to finish) before starting a durable host against this project"
        case .lockFailed(let path, let reason):
            return "cannot acquire SML host lock \(path): \(reason)"
        }
    }
}

/// Exclusive advisory lock held for the lifetime of a durable (mutating) host session.
/// `SMLRuntimeStore`'s own sidecar flock serializes file access, but `SMLRuntime` keeps admission
/// bindings in process memory — the host lock is what prevents two concurrent mutating hosts from
/// holding divergent views of one store. Read-only inspection paths do not take it.
final class SMLRuntimeHostLock {
    let path: String
    private var descriptor: Int32

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    static func acquire(directory: URL) throws -> SMLRuntimeHostLock {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw SMLRuntimeDurableHostError.lockDirectoryUnavailable(
                path: directory.path,
                reason: String(describing: error)
            )
        }
        let lockURL = directory.appendingPathComponent("host.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw SMLRuntimeDurableHostError.lockFailed(
                path: lockURL.path,
                reason: String(cString: strerror(errno))
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(descriptor)
            if reason == EWOULDBLOCK {
                throw SMLRuntimeDurableHostError.lockUnavailable(path: lockURL.path)
            }
            throw SMLRuntimeDurableHostError.lockFailed(
                path: lockURL.path,
                reason: String(cString: strerror(reason))
            )
        }
        return SMLRuntimeHostLock(path: lockURL.path, descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

/// Everything a durable host session needs, acquired together so a launch either has the lock,
/// the persistent store, the real clock, and deny-by-default authority — or nothing.
struct SMLRuntimeDurableHostEnvironment {
    let store: SMLRuntimeStore
    let lease: SMLRuntimeLeaseRegistry.Session
    let clock: @Sendable () -> Double
    let authorityResolver: @Sendable (SMLCommandEnvelope) async throws -> SMLCommandAuthority
    let lock: SMLRuntimeHostLock

    static func acquire(projectRoot: String) async throws -> SMLRuntimeDurableHostEnvironment {
        let smlDirectory = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".kist", isDirectory: true)
            .appendingPathComponent("sml", isDirectory: true)
        let lock = try SMLRuntimeHostLock.acquire(directory: smlDirectory)
        do {
            let authorityConfig = try SMLRuntimeAuthorityConfig.load(projectRoot: projectRoot)
            let clock: @Sendable () -> Double = { Date().timeIntervalSince1970 }
            let store = SMLRuntimeStore(
                fileURL: SMLRuntimeStore.defaultURL(projectRoot: projectRoot),
                clock: clock
            )
            let lease = SMLRuntimeLeaseRegistry.Session()
            // Adopt the store's existing tasks into this session's lease. Lease isolation exists
            // to keep CONCURRENT hosts out of each other's tasks — and the exclusive host lock
            // already guarantees this is the only mutating host. Choosing --sml-runtime-durable
            // on this project root IS the operator resuming this store; authority.json still
            // gates actor, role, operation, and scope on every command.
            if let snapshot = try? await store.load() {
                for taskID in snapshot.tasks.keys {
                    await lease.adopt(taskID: taskID)
                }
            }
            let resolver: @Sendable (SMLCommandEnvelope) async throws -> SMLCommandAuthority = {
                command in
                try await authorityConfig.resolveAuthority(for: command, lease: lease)
            }
            return SMLRuntimeDurableHostEnvironment(
                store: store,
                lease: lease,
                clock: clock,
                authorityResolver: resolver,
                lock: lock
            )
        } catch {
            lock.release()
            throw error
        }
    }
}
