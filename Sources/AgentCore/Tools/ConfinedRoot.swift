import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// TOCTOU-safe filesystem confinement (closes Codex HIGH#2).
///
/// `ToolContext.resolvedPath` canonicalizes to a STRING and the tool then re-opens by
/// name — a local attacker can swap a path (or an ancestor dir) for a symlink between
/// the check and the open, escaping the root. `ConfinedRoot` instead opens every path
/// component RELATIVE TO A TRUSTED ROOT DIRECTORY FD with `O_NOFOLLOW`, so a symlink
/// swapped in mid-path or at the leaf yields `ELOOP` and is refused — there is no
/// window between check and use. All file content I/O for the headless tools routes
/// through here.
///
/// Trade-off (deliberate, security-first): symlinks inside the root are NOT followed —
/// reading/writing/walking through a symlink is refused. The root itself is trusted and
/// canonicalized once at construction.
public final class ConfinedRoot: Sendable {
    public struct FileMetadata: Sendable, Equatable {
        public let bytes: Int
        public let modifiedNanos: Int64
        public let isRegular: Bool
    }

    /// The exact state a conditional publication is allowed to replace. Keeping the
    /// missing-file case explicit prevents `nil` from being misread as "do not check".
    public enum ConditionalBaseline: Sendable, Equatable {
        case missing
        case sha256(Data)
    }

    struct TransactionPreimage: Sendable, Equatable {
        let deviceID: UInt64
        let inode: UInt64
        let linkCount: UInt64
        let mode: UInt16
        let sha256: Data
    }

    /// Canonical absolute path to the confinement root (symlinks already resolved).
    public let rootPath: String
    /// When true, every mutating operation (write/move/remove/mkdir) throws — the root is
    /// readable only. Used for explicitly-armed external read roots (e.g. `--allow-read
    /// /Volumes`): reads route here, writes stay confined to the project root. Enforced at
    /// the primitive level so no future tool can write through a read root by accident.
    public let readOnly: Bool
    /// A trusted directory fd for the root, opened ONCE with `O_NOFOLLOW`. Every descendant
    /// `openat` dups this fd instead of reopening `rootPath` by name, so the root and its
    /// ancestors are resolved a single time — a pathname swapped to a symlink after
    /// canonicalize fails the open here (O_NOFOLLOW), and there is no per-operation
    /// re-resolution-by-name window. (Residual: an ANCESTOR of the root swapped before the
    /// init open is still resolved by name once — out of scope, same as realpath.)
    private let rootFD: Int32

    /// Signals used by the interactive terminal can interrupt a directory open. Retrying only
    /// `EINTR` preserves every confinement flag; the small cap prevents a signal storm from
    /// turning a read into an infinite loop and fails closed with the final errno.
    private static func openRootDirectory(_ path: String) -> Int32 {
        for attempt in 0..<3 {
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 || errno != EINTR || attempt == 2 { return fd }
        }
        return -1
    }

    public init(root: String, readOnly: Bool = false) throws {
        guard let real = ToolContext.canonicalize(root) else {
            throw ToolError.configuration("project root does not exist: \(root)")
        }
        let fd = Self.openRootDirectory(real)
        guard fd >= 0 else {
            throw ToolError.configuration("project root is not an accessible directory: \(real) (\(Self.strerr()))")
        }
        var st = stat()
        var statResult: Int32 = -1
        for attempt in 0..<3 {
            statResult = fstat(fd, &st)
            if statResult == 0 || errno != EINTR || attempt == 2 { break }
        }
        guard statResult == 0, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            close(fd)
            throw ToolError.configuration("project root is not a directory: \(real)")
        }
        self.rootPath = real
        self.rootFD = fd
        self.readOnly = readOnly
    }

    /// Throws unless mutation is allowed on this root. Called by EVERY mutating primitive
    /// (per-site, not per-caller — a new caller can't forget it).
    private func requireWritable(_ op: String, _ path: String) throws {
        if readOnly {
            throw ToolError.execution("\(op) refused: \(rootPath) is an external READ-ONLY root — writes are confined to the project root")
        }
        _ = path   // reserved for richer messages; keeps the call sites uniform
    }

    deinit { close(rootFD) }

    // MARK: - Public file operations

    public func readString(_ path: String) throws -> String {
        guard let s = String(data: try readData(path), encoding: .utf8) else {
            throw ToolError.execution("file is not valid UTF-8: \(path)")
        }
        return s
    }

    public func readData(_ path: String) throws -> Data { try readData(path, maxBytes: nil) }

    /// Read a bounded regular file from one confined descriptor and prove that descriptor did not
    /// change while it was being consumed. This is the primitive for command stdin fixtures: callers
    /// hash and pass the returned bytes directly to the child, never reopening the pathname.
    public func readStableData(_ path: String, maxBytes: Int) throws -> Data {
        guard maxBytes >= 0, maxBytes < Int.max else {
            throw ToolError.execution("invalid byte limit for \(path)")
        }
        let comps = try relativeComponents(path)
        let (parent, leaf) = try openParentDir(comps, createIntermediates: false)
        defer { close(parent) }
        guard let leaf else { throw ToolError.notFound(path) }
        // O_NONBLOCK is security-significant: opening a FIFO read-only otherwise blocks before the
        // same-fd fstat can classify and reject it. Regular files ignore the flag.
        let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Self.openError(path: path, root: rootPath) }
        defer { close(fd) }

        var before = stat()
        guard fstat(fd, &before) == 0 else {
            throw ToolError.execution("cannot stat \(path): \(Self.strerr())")
        }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ToolError.execution("not a regular file: \(path)")
        }
        guard before.st_size >= 0, before.st_size <= maxBytes else {
            throw ToolError.execution("file exceeds \(maxBytes) bytes: \(path)")
        }

        var data = Data()
        data.reserveCapacity(min(Int(before.st_size), maxBytes))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maxBytes + 1))
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                while true {
                    let value = read(fd, raw.baseAddress, raw.count)
                    if value < 0 && errno == EINTR { continue }
                    return value
                }
            }
            guard count >= 0 else {
                throw ToolError.execution("cannot read \(path): \(Self.strerr())")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maxBytes else {
                throw ToolError.execution("file exceeds \(maxBytes) bytes: \(path)")
            }
        }

        var after = stat()
        guard fstat(fd, &after) == 0 else {
            throw ToolError.execution("cannot restat \(path): \(Self.strerr())")
        }
        guard Self.sameStableFile(before, after), data.count == Int(after.st_size) else {
            throw ToolError.execution("file changed while being read: \(path)")
        }
        return data
    }

    /// Read at most `maxBytes` from a confined regular file without following symlinks. Unlike
    /// `readData(_:maxBytes:)`, this is a deliberate prefix capture: oversized files are returned
    /// with `truncated == true` instead of being rejected. The extra byte is read from the same
    /// `O_NOFOLLOW` descriptor, so callers can distinguish an exact-size file from a truncated one
    /// without a metadata/read race.
    public func readDataPrefix(_ path: String, maxBytes: Int) throws -> (data: Data, truncated: Bool) {
        guard maxBytes >= 0, maxBytes < Int.max else {
            throw ToolError.execution("invalid byte limit for \(path)")
        }
        let comps = try relativeComponents(path)
        let (parent, leaf) = try openParentDir(comps, createIntermediates: false)
        defer { close(parent) }
        guard let leaf else { throw ToolError.notFound(path) }
        let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Self.openError(path: path, root: rootPath) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw ToolError.execution("cannot stat \(path): \(Self.strerr())")
        }
        guard st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(fd)
            throw ToolError.execution("not a regular file: \(path)")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let captured = handle.readData(ofLength: maxBytes + 1)
        return (Data(captured.prefix(maxBytes)), captured.count > maxBytes)
    }

    /// Read a confined regular file, optionally BOUNDED to `maxBytes`. The size check and the read happen
    /// on the SAME O_NOFOLLOW file descriptor (fstat then a length-capped read) — no check-then-read
    /// TOCTOU. A file that is small at a prior metadata stat but grows/replaced before the read cannot
    /// bypass the cap: the read itself is bounded and rejects at `maxBytes + 1`.
    public func readData(_ path: String, maxBytes: Int?) throws -> Data {
        let comps = try relativeComponents(path)
        let (parent, leaf) = try openParentDir(comps, createIntermediates: false)
        defer { close(parent) }
        guard let leaf else { throw ToolError.notFound(path) }   // root is a dir, not a file
        let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Self.openError(path: path, root: rootPath) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw ToolError.execution("cannot stat \(path): \(Self.strerr())")
        }
        guard st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(fd)
            throw ToolError.execution("not a regular file: \(path)")
        }
        if let maxBytes, st.st_size > maxBytes {
            close(fd)
            throw ToolError.execution("file exceeds \(maxBytes) bytes: \(path)")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let maxBytes else { return handle.readDataToEndOfFile() }
        // Read one past the cap so a file that grew since fstat is caught by the actual byte count.
        let data = handle.readData(ofLength: maxBytes + 1)
        guard data.count <= maxBytes else {
            throw ToolError.execution("file exceeds \(maxBytes) bytes: \(path)")
        }
        return data
    }

    public func readString(_ path: String, maxBytes: Int) throws -> String {
        guard let s = String(data: try readData(path, maxBytes: maxBytes), encoding: .utf8) else {
            throw ToolError.execution("file is not valid UTF-8: \(path)")
        }
        return s
    }

    /// Streaming SHA-256 of a confined regular file. This keeps generated images/audio/video out of
    /// memory while still letting callers prove that an overwrite changed the artifact. The file is
    /// opened relative to the trusted root descriptor with `O_NOFOLLOW`, exactly like `readData`.
    public func fileSHA256(_ path: String, chunkSize: Int = 1_048_576) throws -> Data {
        let comps = try relativeComponents(path)
        let (parent, leaf) = try openParentDir(comps, createIntermediates: false)
        defer { close(parent) }
        guard let leaf else { throw ToolError.notFound(path) }
        let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Self.openError(path: path, root: rootPath) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw ToolError.execution("cannot stat \(path): \(Self.strerr())")
        }
        guard st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(fd)
            throw ToolError.execution("not a regular file: \(path)")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: max(1, chunkSize))
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return Data(hasher.finalize())
    }

    /// Symlink-safe metadata lookup used by scanners to reject oversized files before
    /// reading contents into memory.
    public func fileMetadata(_ path: String) throws -> FileMetadata {
        let comps = try relativeComponents(path)
        let (parent, leafOpt) = try openParentDir(comps, createIntermediates: false)
        defer { close(parent) }
        guard let leaf = leafOpt else { throw ToolError.notFound(path) }
        var st = stat()
        guard fstatat(parent, leaf, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Self.openError(path: path, root: rootPath)
        }
        let kind = st.st_mode & mode_t(S_IFMT)
        return FileMetadata(bytes: Int(st.st_size),
                            modifiedNanos: Self.modifiedNanos(st),
                            isRegular: kind == mode_t(S_IFREG))
    }

    /// Atomic confined write: write to a temp in the SAME confined dir, then `renameat`.
    public func writeString(_ path: String, _ content: String, createParents: Bool) throws {
        try writeData(path, Data(content.utf8), createParents: createParents)
    }

    /// Atomic confined binary write: write to a temp in the SAME confined dir, then `renameat`.
    public func writeData(_ path: String, _ data: Data, createParents: Bool) throws {
        try requireWritable("write", path)
        let comps = try relativeComponents(path)
        guard !comps.isEmpty else { throw ToolError.execution("cannot write to the root directory") }
        let (parent, leafOpt) = try openParentDir(comps, createIntermediates: createParents)
        defer { close(parent) }
        guard let leaf = leafOpt else { throw ToolError.execution("invalid write path: \(path)") }

        let tmp = ".agentcore-tmp-\(UUID().uuidString)"
        let fd = openat(parent, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ToolError.execution("cannot create temp for \(path): \(Self.strerr())") }
        defer {
            close(fd)
            _ = unlinkat(parent, tmp, 0)
        }
        try Self.writeAll(data, to: fd, path: path)
        guard Self.sync(fd) else {
            throw ToolError.execution("cannot fsync temp for \(path): \(Self.strerr())")
        }
        // O_NOFOLLOW isn't a rename flag; renameat replaces leaf atomically. If leaf is a
        // symlink, we replace the LINK (not its target) — the link can't redirect the write.
        if renameat(parent, tmp, parent, leaf) != 0 {
            throw ToolError.execution("cannot write \(path): \(Self.strerr())")
        }
        guard Self.sync(parent) else {
            throw ToolError.execution("write directory fsync failed for \(path): \(Self.strerr())")
        }
    }

    /// Lease-bound compare-and-swap publication for verified artifacts. The target is read and
    /// hashed through an `O_NOFOLLOW` descriptor, the replacement is durably staged in the same
    /// directory, and the target inode plus digest are checked again immediately before the atomic
    /// publication. The caller must retain `lease` for the whole call; its canonical root is checked
    /// here so a lease for another workspace can never authorize this mutation.
    @discardableResult
    public func conditionalReplace(_ path: String, with data: Data,
                                   expectedSHA256 baseline: ConditionalBaseline,
                                   lease: WorkspaceExecutionLease) throws -> Data {
        try requireWritable("conditional replace", path)
        guard lease.canonicalProjectRoot == rootPath else {
            throw ToolError.execution(
                "conditional replace refused: workspace lease root \(lease.canonicalProjectRoot) does not match \(rootPath)")
        }

        let comps = try relativeComponents(path)
        guard !comps.isEmpty else {
            throw ToolError.execution("cannot conditionally replace the root directory")
        }
        let (parent, leafOpt) = try openParentDir(comps, createIntermediates: false)
        defer { close(parent) }
        guard let leaf = leafOpt else {
            throw ToolError.execution("invalid conditional replace path: \(path)")
        }

        var originalStatus: stat?
        switch baseline {
        case .missing:
            try Self.requireMissingLeaf(parent: parent, leaf: leaf, path: path)
        case .sha256(let expected):
            guard expected.count == 32 else {
                throw ToolError.execution("invalid SHA-256 baseline for \(path)")
            }
            let current = try Self.hashRegularLeaf(parent: parent, leaf: leaf, path: path)
            guard current.digest == expected else {
                throw ToolError.execution("conditional replace refused: stale baseline for \(path)")
            }
            originalStatus = current.status
        }

        let replacementDigest = Data(SHA256.hash(data: data))
        let temp = ".agentcore-cas-\(UUID().uuidString)"
        let tempFD = openat(parent, temp,
                            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                            mode_t(0o600))
        guard tempFD >= 0 else {
            throw ToolError.execution("cannot create conditional temp for \(path): \(Self.strerr())")
        }
        defer {
            close(tempFD)
            _ = unlinkat(parent, temp, 0)
        }

        try Self.writeAll(data, to: tempFD, path: path)
        guard Self.sync(tempFD) else {
            throw ToolError.execution("cannot fsync conditional temp for \(path): \(Self.strerr())")
        }
        var stagedStatus = stat()
        guard fstat(tempFD, &stagedStatus) == 0,
              stagedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ToolError.execution("cannot stat conditional temp for \(path): \(Self.strerr())")
        }

        // Re-open the random temp name so rename cannot publish a name another process swapped.
        let staged = try Self.hashRegularLeaf(parent: parent, leaf: temp, path: path)
        guard Self.sameIdentity(stagedStatus, staged.status),
              staged.digest == replacementDigest else {
            throw ToolError.execution("conditional temp changed before publication: \(path)")
        }

        // This is deliberately the last pathname operation before publication. The workspace
        // lease serializes cooperating writers; the inode+digest check detects stale/unlocked state.
        switch baseline {
        case .missing:
            try Self.requireMissingLeaf(parent: parent, leaf: leaf, path: path)
            // `linkat` gives the missing case atomic no-replace semantics on both Darwin and Linux.
            // The staged inode is already fsynced; unlinking its private name leaves the published link.
            guard linkat(parent, temp, parent, leaf, 0) == 0 else {
                throw ToolError.execution("conditional create refused for \(path): \(Self.strerr())")
            }
            _ = unlinkat(parent, temp, 0)
        case .sha256(let expected):
            let current = try Self.hashRegularLeaf(parent: parent, leaf: leaf, path: path)
            guard let originalStatus,
                  Self.sameIdentity(originalStatus, current.status),
                  current.digest == expected else {
                throw ToolError.execution("conditional replace refused: target changed before publication: \(path)")
            }
            guard renameat(parent, temp, parent, leaf) == 0 else {
                throw ToolError.execution("cannot conditionally replace \(path): \(Self.strerr())")
            }
        }

        guard Self.sync(parent) else {
            throw ToolError.execution("conditional publication directory fsync failed for \(path): \(Self.strerr())")
        }
        return replacementDigest
    }

    /// Lease-bound compare-and-swap removal for a regular file. The leaf is opened and hashed
    /// with `O_NOFOLLOW`, then its inode and digest are revalidated as the final operation before
    /// `unlinkat`. The parent directory is fsynced so a successful return means the removal is
    /// durable. The workspace lease serializes cooperating writers for the complete operation.
    @discardableResult
    public func conditionalRemove(_ path: String, expectedSHA256 expected: Data,
                                  lease: WorkspaceExecutionLease) throws -> Data {
        try requireWritable("conditional remove", path)
        guard lease.canonicalProjectRoot == rootPath else {
            throw ToolError.execution(
                "conditional remove refused: workspace lease root \(lease.canonicalProjectRoot) does not match \(rootPath)")
        }
        guard expected.count == 32 else {
            throw ToolError.execution("invalid SHA-256 baseline for \(path)")
        }

        let comps = try relativeComponents(path)
        guard !comps.isEmpty else {
            throw ToolError.execution("cannot conditionally remove the root directory")
        }
        let (parent, leafOpt) = try openParentDir(comps, createIntermediates: false)
        defer { close(parent) }
        guard let leaf = leafOpt else {
            throw ToolError.execution("invalid conditional remove path: \(path)")
        }

        let original = try Self.hashRegularLeaf(parent: parent, leaf: leaf, path: path)
        guard original.digest == expected else {
            throw ToolError.execution("conditional remove refused: stale baseline for \(path)")
        }

        // Keep this re-open/hash as the final pathname operation before unlink. The held lease
        // serializes cooperating mutations; identity plus digest rejects stale or replaced state.
        let current = try Self.hashRegularLeaf(parent: parent, leaf: leaf, path: path)
        guard Self.sameIdentity(original.status, current.status),
              current.digest == expected else {
            throw ToolError.execution("conditional remove refused: target changed before removal: \(path)")
        }
        guard unlinkat(parent, leaf, 0) == 0 else {
            throw ToolError.execution("cannot conditionally remove \(path): \(Self.strerr())")
        }
        guard Self.sync(parent) else {
            throw ToolError.execution("conditional removal directory fsync failed for \(path): \(Self.strerr())")
        }
        return current.digest
    }

    /// Atomic transaction publication used by the Builder workspace protocol. Every pathname
    /// operation is relative to a held directory fd. A modify exchanges the staged and live
    /// directory entries on Darwin before validating the moved preimage; a delete first moves the
    /// live entry to quarantine; a create uses an exclusive hard-link publication. A mismatched
    /// moved preimage is atomically restored before this method fails.
    func transactionPublish(_ path: String, data: Data?, mode: UInt16,
                            expected: TransactionPreimage?, kind: BuilderMutationKind,
                            tempLeaf: String, quarantineLeaf: String) throws {
        try requireWritable("transaction publish", path)
        guard !tempLeaf.contains("/"), !quarantineLeaf.contains("/"),
              tempLeaf != quarantineLeaf else {
            throw ToolError.execution("invalid transaction artifact name for \(path)")
        }
        let comps = try relativeComponents(path)
        guard !comps.isEmpty else { throw ToolError.execution("cannot mutate root directory") }
        let (parent, leafOpt) = try openParentDir(
            comps, createIntermediates: kind == .create)
        defer { close(parent) }
        guard let leaf = leafOpt else { throw ToolError.execution("invalid transaction path: \(path)") }

        switch kind {
        case .create:
            guard expected == nil, let data else {
                throw ToolError.execution("invalid create transaction for \(path)")
            }
            try stageTransactionLeaf(parent: parent, leaf: tempLeaf, data: data, mode: mode, path: path)
            defer { _ = unlinkat(parent, tempLeaf, 0) }
            guard linkat(parent, tempLeaf, parent, leaf, 0) == 0 else {
                throw ToolError.execution("exclusive create refused for \(path): \(Self.strerr())")
            }
        case .modify:
            guard let expected, let data else {
                throw ToolError.execution("invalid modify transaction for \(path)")
            }
            try stageTransactionLeaf(parent: parent, leaf: tempLeaf, data: data, mode: mode, path: path)
            defer {
                _ = unlinkat(parent, tempLeaf, 0)
                _ = unlinkat(parent, quarantineLeaf, 0)
            }
            #if canImport(Darwin)
            guard renameatx_np(parent, tempLeaf, parent, leaf, UInt32(RENAME_SWAP)) == 0 else {
                throw ToolError.execution("atomic exchange refused for \(path): \(Self.strerr())")
            }
            let moved = try Self.hashRegularLeaf(parent: parent, leaf: tempLeaf, path: path)
            guard Self.matches(moved.status, digest: moved.digest, expected: expected) else {
                guard renameatx_np(parent, tempLeaf, parent, leaf, UInt32(RENAME_SWAP)) == 0 else {
                    throw ToolError.execution("preimage mismatch and atomic restore failed for \(path): \(Self.strerr())")
                }
                throw ToolError.execution("transaction preimage mismatch for \(path)")
            }
            guard renameat(parent, tempLeaf, parent, quarantineLeaf) == 0 else {
                guard renameatx_np(parent, tempLeaf, parent, leaf, UInt32(RENAME_SWAP)) == 0 else {
                    throw ToolError.execution("cannot quarantine or restore preimage for \(path)")
                }
                throw ToolError.execution("cannot quarantine preimage for \(path): \(Self.strerr())")
            }
            #else
            guard renameat(parent, leaf, parent, quarantineLeaf) == 0 else {
                throw ToolError.execution("cannot quarantine preimage for \(path): \(Self.strerr())")
            }
            let moved = try Self.hashRegularLeaf(parent: parent, leaf: quarantineLeaf, path: path)
            guard Self.matches(moved.status, digest: moved.digest, expected: expected) else {
                _ = renameat(parent, quarantineLeaf, parent, leaf)
                throw ToolError.execution("transaction preimage mismatch for \(path)")
            }
            guard renameat(parent, tempLeaf, parent, leaf) == 0 else {
                _ = renameat(parent, quarantineLeaf, parent, leaf)
                throw ToolError.execution("cannot publish transaction replacement for \(path): \(Self.strerr())")
            }
            #endif
        case .delete:
            guard let expected, data == nil else {
                throw ToolError.execution("invalid delete transaction for \(path)")
            }
            defer { _ = unlinkat(parent, quarantineLeaf, 0) }
            guard renameat(parent, leaf, parent, quarantineLeaf) == 0 else {
                throw ToolError.execution("cannot quarantine delete preimage for \(path): \(Self.strerr())")
            }
            let moved = try Self.hashRegularLeaf(parent: parent, leaf: quarantineLeaf, path: path)
            guard Self.matches(moved.status, digest: moved.digest, expected: expected) else {
                var leafStatus = stat()
                if fstatat(parent, leaf, &leafStatus, AT_SYMLINK_NOFOLLOW) == 0 {
                    #if canImport(Darwin)
                    guard renameatx_np(parent, quarantineLeaf, parent, leaf, UInt32(RENAME_SWAP)) == 0 else {
                        throw ToolError.execution("delete preimage mismatch and atomic restore failed for \(path)")
                    }
                    #else
                    throw ToolError.execution("delete preimage mismatch could not be restored atomically for \(path)")
                    #endif
                } else {
                    guard renameat(parent, quarantineLeaf, parent, leaf) == 0 else {
                        throw ToolError.execution("delete preimage mismatch and restore failed for \(path)")
                    }
                }
                throw ToolError.execution("transaction preimage mismatch for \(path)")
            }
        }
        guard Self.sync(parent) else {
            throw ToolError.execution("transaction directory fsync failed for \(path): \(Self.strerr())")
        }
    }

    private func stageTransactionLeaf(parent: Int32, leaf: String, data: Data,
                                      mode: UInt16, path: String) throws {
        let fd = openat(parent, leaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        mode_t(mode))
        guard fd >= 0 else {
            throw ToolError.execution("cannot create transaction temp for \(path): \(Self.strerr())")
        }
        defer { close(fd) }
        try Self.writeAll(data, to: fd, path: path)
        guard fchmod(fd, mode_t(mode)) == 0, Self.sync(fd) else {
            throw ToolError.execution("cannot sync transaction temp for \(path): \(Self.strerr())")
        }
    }

    private static func matches(_ status: stat, digest: Data,
                                expected: TransactionPreimage) -> Bool {
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && UInt64(status.st_dev) == expected.deviceID
            && UInt64(status.st_ino) == expected.inode
            && UInt64(status.st_nlink) == expected.linkCount
            && UInt16(status.st_mode & 0o7777) == expected.mode
            && digest == expected.sha256
    }

    /// Move/rename `from` → `to`, both confined. Each path's parent is opened O_NOFOLLOW relative to the
    /// trusted root fd, then `renameat` swaps the leaves atomically — a symlinked dir mid-path yields ELOOP
    /// and is refused, so neither side can escape. Destination parents are created if `createParents`.
    public func move(_ from: String, _ to: String, createParents: Bool = true) throws {
        try requireWritable("move", from)
        let fromComps = try relativeComponents(from)
        guard !fromComps.isEmpty else { throw ToolError.execution("cannot move the root directory") }
        let toComps = try relativeComponents(to)
        guard !toComps.isEmpty else { throw ToolError.execution("invalid move destination: \(to)") }
        let (fromParent, fromLeafOpt) = try openParentDir(fromComps, createIntermediates: false)
        defer { close(fromParent) }
        guard let fromLeaf = fromLeafOpt else { throw ToolError.notFound(from) }
        let (toParent, toLeafOpt) = try openParentDir(toComps, createIntermediates: createParents)
        defer { close(toParent) }
        guard let toLeaf = toLeafOpt else { throw ToolError.execution("invalid move destination: \(to)") }
        if renameat(fromParent, fromLeaf, toParent, toLeaf) != 0 {
            throw ToolError.execution("cannot move \(from) → \(to): \(Self.strerr())")
        }
    }

    /// Remove a file (not a directory), confined + O_NOFOLLOW. A symlinked leaf is unlinked as the LINK,
    /// never its target.
    public func removeFile(_ path: String) throws {
        try requireWritable("remove", path)
        let comps = try relativeComponents(path)
        guard !comps.isEmpty else { throw ToolError.execution("cannot remove the root directory") }
        let (parent, leafOpt) = try openParentDir(comps, createIntermediates: false)
        defer { close(parent) }
        guard let leaf = leafOpt else { throw ToolError.execution("invalid path: \(path)") }
        if unlinkat(parent, leaf, 0) != 0 { throw ToolError.execution("cannot remove \(path): \(Self.strerr())") }
    }

    /// Remove an empty directory without resolving any attacker-controlled path component.
    func removeDirectory(_ path: String) throws {
        try requireWritable("remove_dir", path)
        let comps = try relativeComponents(path)
        guard !comps.isEmpty else {
            throw ToolError.execution("cannot remove the root directory")
        }
        let (parent, leafOpt) = try openParentDir(comps, createIntermediates: false)
        defer { close(parent) }
        guard let leaf = leafOpt else { throw ToolError.execution("invalid path: \(path)") }
        guard unlinkat(parent, leaf, AT_REMOVEDIR) == 0 else {
            throw ToolError.execution("cannot remove directory \(path): \(Self.strerr())")
        }
        guard Self.sync(parent) else {
            throw ToolError.execution("cannot fsync removed directory parent for \(path)")
        }
    }

    /// Atomically replace a symbolic-link leaf. Intermediate components remain O_NOFOLLOW.
    func replaceSymlink(_ path: String, target: String, createParents: Bool) throws {
        try requireWritable("replace_symlink", path)
        let comps = try relativeComponents(path)
        guard !comps.isEmpty else {
            throw ToolError.execution("cannot replace the root with a symbolic link")
        }
        let (parent, leafOpt) = try openParentDir(
            comps, createIntermediates: createParents)
        defer { close(parent) }
        guard let leaf = leafOpt else { throw ToolError.execution("invalid path: \(path)") }
        let staged = ".agentcore-link-\(UUID().uuidString)"
        guard symlinkat(target, parent, staged) == 0 else {
            throw ToolError.execution("cannot stage symbolic link \(path): \(Self.strerr())")
        }
        defer { _ = unlinkat(parent, staged, 0) }
        guard renameat(parent, staged, parent, leaf) == 0 else {
            throw ToolError.execution("cannot replace symbolic link \(path): \(Self.strerr())")
        }
        guard Self.sync(parent) else {
            throw ToolError.execution("cannot fsync symbolic link parent for \(path)")
        }
    }

    /// Descriptor-relative mode update followed by fsync. Symlinks are intentionally refused.
    func setModeAndSync(_ path: String, mode: UInt16) throws {
        try requireWritable("chmod", path)
        let comps = try relativeComponents(path)
        guard !comps.isEmpty else { throw ToolError.execution("cannot chmod the root directory") }
        let (parent, leafOpt) = try openParentDir(comps, createIntermediates: false)
        defer { close(parent) }
        guard let leaf = leafOpt else { throw ToolError.execution("invalid path: \(path)") }
        let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.openError(path: path, root: rootPath) }
        defer { close(fd) }
        guard fchmod(fd, mode_t(mode)) == 0, Self.sync(fd), Self.sync(parent) else {
            throw ToolError.execution("cannot persist mode for \(path): \(Self.strerr())")
        }
    }

    /// Create a directory (and parents) confined to the root, O_NOFOLLOW the whole way.
    public func makeDirectory(_ path: String) throws {
        try requireWritable("make_dir", path)
        let comps = try relativeComponents(path)
        guard !comps.isEmpty else { return }   // root already exists
        let (parent, leafOpt) = try openParentDir(comps, createIntermediates: true)
        defer { close(parent) }
        guard let leaf = leafOpt else { return }
        if mkdirat(parent, leaf, 0o755) == 0 {
            guard Self.sync(parent) else {
                throw ToolError.execution("cannot fsync directory parent for \(path): \(Self.strerr())")
            }
        } else if errno != EEXIST {
            throw ToolError.execution("cannot create directory \(path): \(Self.strerr())")
        }
    }

    /// (exists, isDir) via `fstatat` with `AT_SYMLINK_NOFOLLOW` — a symlinked leaf reports
    /// as itself (and isDir=false), never as its target.
    public func fileType(_ path: String) throws -> (exists: Bool, isDir: Bool) {
        let comps = try relativeComponents(path)
        let (parent, leafOpt) = try openParentDir(comps, createIntermediates: false)
        defer { close(parent) }
        guard let leaf = leafOpt else { return (true, true) }   // root itself
        var st = stat()
        guard fstatat(parent, leaf, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return (false, false) }
        return (true, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
    }

    /// Immediate directory entries (non-recursive), each tagged dir/not. Symlinks are
    /// reported as non-dir (never traversed).
    public func entries(_ path: String) throws -> [(name: String, isDir: Bool)] {
        let comps = try relativeComponents(path)
        let (parent, leafOpt) = try openParentDir(comps, createIntermediates: false)
        let dirfd: Int32
        if let leaf = leafOpt {
            dirfd = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(parent)
            guard dirfd >= 0 else { throw Self.openError(path: path, root: rootPath, notDirIsError: true) }
        } else {
            dirfd = parent   // root
        }
        guard let dirp = fdopendir(dirfd) else { close(dirfd); throw ToolError.execution("cannot read directory: \(path)") }
        defer { closedir(dirp) }   // also closes dirfd
        var out: [(String, Bool)] = []
        while let ent = readdir(dirp) {
            let name = Self.direntName(ent)
            if name == "." || name == ".." { continue }
            var st = stat()
            let isDir = fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && (st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
            out.append((name, isDir))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Recursively visit entries under `base`, confined by O_NOFOLLOW directory opens —
    /// a symlinked directory is never descended, so the walk cannot escape the root.
    /// `visit` receives the path RELATIVE TO `base`.
    public func walk(_ base: String, skipDirs: Set<String> = [],
                     skipRelativePrefixes: Set<String> = [],
                     visit: (_ relPath: String, _ isDir: Bool) throws -> Void) throws {
        let comps = try relativeComponents(base)
        let (parent, leafOpt) = try openParentDir(comps, createIntermediates: false)
        let baseFD: Int32
        if let leaf = leafOpt {
            baseFD = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(parent)
            guard baseFD >= 0 else { throw Self.openError(path: base, root: rootPath, notDirIsError: true) }
        } else {
            baseFD = parent
        }
        try walkFD(baseFD, prefix: "", skipDirs: skipDirs,
                   skipRelativePrefixes: skipRelativePrefixes, visit: visit)   // takes ownership of baseFD
    }

    // MARK: - Internals

    /// Split a caller path into safe components relative to the root. Absolute paths must
    /// already be inside the canonical root; `..` is rejected outright.
    func relativeComponents(_ path: String) throws -> [String] {
        let rel: String
        if path.hasPrefix("/") {
            // rootPath + "/" becomes "//" when rootPath == "/"; handle that case explicitly.
            let rootSlash = rootPath == "/" ? "/" : rootPath + "/"
            if path == rootPath { rel = "" }
            else if path.hasPrefix(rootSlash) { rel = String(path.dropFirst(rootSlash.count)) }
            else { throw ToolError.pathEscape(path: path, root: rootPath) }
        } else {
            rel = path
        }
        var comps: [String] = []
        for part in rel.split(separator: "/", omittingEmptySubsequences: true) {
            let s = String(part)
            if s == "." { continue }
            if s == ".." { throw ToolError.pathEscape(path: path, root: rootPath) }
            comps.append(s)
        }
        return comps
    }

    /// A fresh, closeable handle on the TRUSTED root fd (never a re-open by name), so callers
    /// can `close()` it after a walk without touching the held `rootFD`.
    private func openRootFD() throws -> Int32 {
        let fd = fcntl(rootFD, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw ToolError.configuration("cannot dup root fd for \(rootPath)") }
        return fd
    }

    /// Walk to the parent directory of the final component, opening each intermediate
    /// with `O_NOFOLLOW | O_DIRECTORY`. Returns (parentFD, leafName?). `leaf == nil`
    /// means the path is the root itself. Caller closes parentFD.
    private func openParentDir(_ comps: [String], createIntermediates: Bool) throws -> (Int32, String?) {
        let rootFD = try openRootFD()
        guard !comps.isEmpty else { return (rootFD, nil) }
        if comps.count == 1 { return (rootFD, comps[0]) }

        var dirfd = rootFD
        for i in 0..<(comps.count - 1) {
            var next = openat(dirfd, comps[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if next < 0 && createIntermediates && errno == ENOENT {
                let created = mkdirat(dirfd, comps[i], 0o755) == 0
                if created && !Self.sync(dirfd) {
                    let detail = Self.strerr()
                    close(dirfd)
                    let createdPath = comps.prefix(i + 1).joined(separator: "/")
                    throw ToolError.execution(
                        "cannot fsync directory parent for \(createdPath): \(detail)")
                }
                next = openat(dirfd, comps[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            let code = next < 0 ? errno : 0
            let componentError = next < 0
                ? Self.componentOpenError(
                    code: code, parent: dirfd, component: comps[i],
                    path: comps.prefix(i + 1).joined(separator: "/"), root: rootPath)
                : nil
            close(dirfd)
            guard next >= 0 else {
                throw componentError ?? ToolError.execution("cannot open confined path component")
            }
            dirfd = next
        }
        return (dirfd, comps.last)
    }

    private func walkFD(_ dirfd: Int32, prefix: String, skipDirs: Set<String>,
                        skipRelativePrefixes: Set<String>,
                        visit: (_ relPath: String, _ isDir: Bool) throws -> Void) throws {
        guard let dirp = fdopendir(dirfd) else { close(dirfd); return }
        defer { closedir(dirp) }
        var subdirs: [String] = []
        while let ent = readdir(dirp) {
            let name = Self.direntName(ent)
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = st.st_mode & mode_t(S_IFMT)
            let rel = prefix.isEmpty ? name : prefix + "/" + name
            if skipRelativePrefixes.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
                continue
            }
            if kind == mode_t(S_IFDIR) {
                if skipDirs.contains(name) { continue }
                try visit(rel, true)
                subdirs.append(name)
            } else if kind == mode_t(S_IFREG) {
                try visit(rel, false)
            }
            // symlinks and other types are skipped (never followed)
        }
        for name in subdirs {
            let sub = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard sub >= 0 else { continue }
            let rel = prefix.isEmpty ? name : prefix + "/" + name
            try walkFD(sub, prefix: rel, skipDirs: skipDirs,
                       skipRelativePrefixes: skipRelativePrefixes, visit: visit)
        }
    }

    // MARK: - C helpers

    private static func direntName(_ ent: UnsafeMutablePointer<dirent>) -> String {
        withUnsafeBytes(of: &ent.pointee.d_name) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    private static func strerr() -> String { String(cString: strerror(errno)) }

    private static func modifiedNanos(_ st: stat) -> Int64 {
        #if canImport(Darwin)
        return Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        #else
        return Int64(st.st_mtim.tv_sec) * 1_000_000_000 + Int64(st.st_mtim.tv_nsec)
        #endif
    }

    private static func changedNanos(_ st: stat) -> Int64 {
        #if canImport(Darwin)
        return Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec)
        #else
        return Int64(st.st_ctim.tv_sec) * 1_000_000_000 + Int64(st.st_ctim.tv_nsec)
        #endif
    }

    private static func sameStableFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode & mode_t(S_IFMT) == rhs.st_mode & mode_t(S_IFMT)
            && lhs.st_size == rhs.st_size
            && modifiedNanos(lhs) == modifiedNanos(rhs)
            && changedNanos(lhs) == changedNanos(rhs)
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && rhs.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func hashRegularLeaf(parent: Int32, leaf: String,
                                        path: String) throws -> (digest: Data, status: stat) {
        let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw openError(path: path, root: "confined root") }
        defer { close(fd) }

        var before = stat()
        guard fstat(fd, &before) == 0 else {
            throw ToolError.execution("cannot stat \(path): \(strerr())")
        }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ToolError.execution("not a regular file: \(path)")
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                while true {
                    let value = read(fd, raw.baseAddress, raw.count)
                    if value < 0 && errno == EINTR { continue }
                    return value
                }
            }
            guard count >= 0 else {
                throw ToolError.execution("cannot hash \(path): \(strerr())")
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }

        var after = stat()
        guard fstat(fd, &after) == 0 else {
            throw ToolError.execution("cannot restat \(path): \(strerr())")
        }
        guard sameStableFile(before, after) else {
            throw ToolError.execution("file changed while being hashed: \(path)")
        }
        return (Data(hasher.finalize()), after)
    }

    private static func requireMissingLeaf(parent: Int32, leaf: String, path: String) throws {
        var status = stat()
        if fstatat(parent, leaf, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw ToolError.pathEscape(path: path, root: "confined root")
            }
            throw ToolError.execution("conditional create refused: target already exists: \(path)")
        }
        guard errno == ENOENT else {
            if errno == ELOOP {
                throw ToolError.pathEscape(path: path, root: "confined root")
            }
            throw ToolError.execution("cannot inspect conditional target \(path): \(strerr())")
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw ToolError.execution("cannot stage conditional replacement for \(path): \(strerr())")
                }
                offset += count
            }
        }
    }

    private static func sync(_ fd: Int32) -> Bool {
        for attempt in 0..<3 {
            if fsync(fd) == 0 { return true }
            if errno != EINTR || attempt == 2 { return false }
        }
        return false
    }

    /// Map an `openat` failure to a tool error: `ELOOP` (symlink) → pathEscape; an
    /// expected-directory failure → execution; otherwise notFound.
    private static func openError(path: String, root: String, notDirIsError: Bool = false) -> ToolError {
        openError(code: errno, path: path, root: root, notDirIsError: notDirIsError)
    }

    private static func openError(code: Int32, path: String, root: String,
                                  notDirIsError: Bool = false) -> ToolError {
        if code == ELOOP { return .pathEscape(path: path, root: root) }
        if code == ENOENT { return .notFound(path) }
        if notDirIsError && code == ENOTDIR { return .execution("not a directory: \(path)") }
        return .execution("cannot open \(path): \(strerr(code))")
    }

    /// Darwin commonly reports O_NOFOLLOW|O_DIRECTORY against a symlink as ENOTDIR
    /// rather than ELOOP. Inspect the same component relative to the still-open parent
    /// descriptor so symlinks retain path-escape semantics while regular files do not.
    private static func componentOpenError(code: Int32, parent: Int32, component: String,
                                           path: String, root: String) -> ToolError {
        if code == ENOTDIR {
            var status = stat()
            if fstatat(parent, component, &status, AT_SYMLINK_NOFOLLOW) == 0,
               status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                return .pathEscape(path: path, root: root)
            }
        }
        return openError(code: code, path: path, root: root, notDirIsError: true)
    }

    private static func strerr(_ code: Int32) -> String { String(cString: strerror(code)) }
}
