import Foundation
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

    public init(root: String, readOnly: Bool = false) throws {
        guard let real = ToolContext.canonicalize(root) else {
            throw ToolError.configuration("project root does not exist: \(root)")
        }
        let fd = open(real, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw ToolError.configuration("project root is not an accessible directory: \(real) (\(Self.strerr()))")
        }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
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
        let fd = openat(parent, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw ToolError.execution("cannot create temp for \(path): \(Self.strerr())") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.write(data)
        try? handle.synchronize()
        handle.closeFile()
        // O_NOFOLLOW isn't a rename flag; renameat replaces leaf atomically. If leaf is a
        // symlink, we replace the LINK (not its target) — the link can't redirect the write.
        if renameat(parent, tmp, parent, leaf) != 0 {
            unlinkat(parent, tmp, 0)
            throw ToolError.execution("cannot write \(path): \(Self.strerr())")
        }
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

    /// Create a directory (and parents) confined to the root, O_NOFOLLOW the whole way.
    public func makeDirectory(_ path: String) throws {
        try requireWritable("make_dir", path)
        let comps = try relativeComponents(path)
        guard !comps.isEmpty else { return }   // root already exists
        let (parent, leafOpt) = try openParentDir(comps, createIntermediates: true)
        defer { close(parent) }
        guard let leaf = leafOpt else { return }
        if mkdirat(parent, leaf, 0o755) != 0 && errno != EEXIST {
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
                _ = mkdirat(dirfd, comps[i], 0o755)
                next = openat(dirfd, comps[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            close(dirfd)
            guard next >= 0 else {
                // ELOOP (symlink), ENOTDIR, ENOENT → treat as escape/blocked.
                throw ToolError.pathEscape(path: comps.joined(separator: "/"), root: rootPath)
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

    /// Map an `openat` failure to a tool error: `ELOOP` (symlink) → pathEscape; an
    /// expected-directory failure → execution; otherwise notFound.
    private static func openError(path: String, root: String, notDirIsError: Bool = false) -> ToolError {
        if errno == ELOOP { return .pathEscape(path: path, root: root) }
        if notDirIsError && errno == ENOTDIR { return .execution("not a directory: \(path)") }
        return .notFound(path)
    }
}
