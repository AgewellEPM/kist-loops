import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum BuilderWorkspaceEntryType: String, Codable, Sendable, Equatable {
    case directory, regular, symlink, special
}

public struct BuilderWorkspaceManifestEntry: Codable, Sendable, Equatable {
    public let path: String
    public let type: BuilderWorkspaceEntryType
    public let mode: UInt16
    public let byteCount: Int64
    public let contentDigest: String?
    public let linkTarget: String?
    public let deviceID: UInt64?
    public let inode: UInt64?
    public let linkCount: UInt64?

    public init(path: String, type: BuilderWorkspaceEntryType, mode: UInt16,
                byteCount: Int64, contentDigest: String?, linkTarget: String?,
                deviceID: UInt64? = nil, inode: UInt64? = nil,
                linkCount: UInt64? = nil) {
        self.path = path
        self.type = type
        self.mode = mode
        self.byteCount = byteCount
        self.contentDigest = contentDigest
        self.linkTarget = linkTarget
        self.deviceID = deviceID
        self.inode = inode
        self.linkCount = linkCount
    }

    /// Content equality deliberately excludes filesystem identity. Device/inode/link-count are
    /// retained for the atomic preimage CAS, while copied staged trees and a proven rollback are
    /// compared by path/type/mode/raw bytes rather than by inherently different inode numbers.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path && lhs.type == rhs.type && lhs.mode == rhs.mode
            && lhs.byteCount == rhs.byteCount && lhs.contentDigest == rhs.contentDigest
            && lhs.linkTarget == rhs.linkTarget
    }
}

public struct BuilderWorkspaceManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let entries: [BuilderWorkspaceManifestEntry]
    public let totalBytes: Int64

    public init(entries: [BuilderWorkspaceManifestEntry], totalBytes: Int64) {
        self.schemaVersion = 1
        self.entries = entries.sorted { $0.path < $1.path }
        self.totalBytes = totalBytes
    }

    public func digest() throws -> String {
        BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(self), as: UTF8.self))
    }

    /// Stable across a staged copy and its published project tree. Transactional `digest()` keeps
    /// device/inode/link-count identity; verification receipts use this content-only form when
    /// proving that publication preserved the accepted bytes, paths, modes, and link targets.
    public func contentDigest() throws -> String {
        let normalized = entries.map {
            BuilderWorkspaceManifestEntry(
                path: $0.path, type: $0.type, mode: $0.mode,
                byteCount: $0.byteCount, contentDigest: $0.contentDigest,
                linkTarget: $0.linkTarget)
        }
        return try BuilderWorkspaceManifest(
            entries: normalized, totalBytes: totalBytes).digest()
    }

    public func entry(_ path: String) -> BuilderWorkspaceManifestEntry? {
        entries.first { $0.path == path }
    }
}

public struct BuilderWorkspaceTraversalLimits: Sendable, Equatable {
    public let maxEntries: Int
    public let maxBytes: Int64
    public let maxDepth: Int
    public let maxFileBytes: Int

    public init(maxEntries: Int = 100_000, maxBytes: Int64 = 4 * 1024 * 1024 * 1024,
                maxDepth: Int = 128, maxFileBytes: Int = 512 * 1024 * 1024) throws {
        guard maxEntries > 0, maxBytes > 0, maxDepth > 0, maxFileBytes > 0 else {
            throw BuilderWorkspaceTransactionError.invalidConfiguration(
                "workspace traversal limits must be positive")
        }
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
        self.maxDepth = maxDepth
        self.maxFileBytes = maxFileBytes
    }
}

enum BuilderWorkspaceManifestScanner {
    enum ScanMode { case strict, restoration }

    static func scan(root: URL, limits: BuilderWorkspaceTraversalLimits,
                     copyTo destination: URL? = nil,
                     mode scanMode: ScanMode = .strict) throws -> BuilderWorkspaceManifest {
        let rootPath = root.standardizedFileURL.path
        let confined = try ConfinedRoot(root: rootPath)
        if let destination {
            try createDirectorySecure(destination, mode: 0o700)
        }
        var enumerationFailure: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in
                enumerationFailure = error
                return false
            }) else {
            throw BuilderWorkspaceTransactionError.stateMismatch("cannot enumerate governed root")
        }
        let destinationRoot = try destination.map { try ConfinedRoot(root: $0.path) }
        var entries: [BuilderWorkspaceManifestEntry] = []
        var bytes: Int64 = 0
        while let item = enumerator.nextObject() as? URL {
            let absolute = item.standardizedFileURL.path
            guard absolute.hasPrefix(rootPath + "/") else {
                throw BuilderWorkspaceTransactionError.invalidPath(absolute)
            }
            let relative = String(absolute.dropFirst(rootPath.count + 1))
            if BuilderPathSecurity.containsControlComponent(relative) {
                enumerator.skipDescendants()
                continue
            }
            let depth = relative.split(separator: "/", omittingEmptySubsequences: false).count
            guard depth <= limits.maxDepth else {
                throw BuilderWorkspaceTransactionError.traversalLimit
            }
            guard entries.count < limits.maxEntries else {
                throw BuilderWorkspaceTransactionError.traversalLimit
            }
            var info = stat()
            guard lstat(absolute, &info) == 0 else {
                throw BuilderWorkspaceTransactionError.stateMismatch("cannot lstat \(relative)")
            }
            let kind = info.st_mode & mode_t(S_IFMT)
            let mode = UInt16(info.st_mode & 0o7777)
            let identity = (UInt64(info.st_dev), UInt64(info.st_ino), UInt64(info.st_nlink))
            if kind == mode_t(S_IFDIR) {
                entries.append(.init(path: relative, type: .directory, mode: mode,
                                     byteCount: 0, contentDigest: nil, linkTarget: nil,
                                     deviceID: identity.0, inode: identity.1,
                                     linkCount: identity.2))
                if let destination {
                    let target = destination.appendingPathComponent(relative, isDirectory: true)
                    try createDirectorySecure(target, mode: mode_t(mode))
                }
            } else if kind == mode_t(S_IFREG) {
                guard scanMode == .restoration || info.st_nlink == 1 else {
                    throw BuilderWorkspaceTransactionError.specialFile(
                        "hard-linked regular file: \(relative)")
                }
                guard info.st_size >= 0, info.st_size <= limits.maxFileBytes else {
                    throw BuilderWorkspaceTransactionError.traversalLimit
                }
                let data = try confined.readStableData(relative, maxBytes: limits.maxFileBytes)
                bytes += Int64(data.count)
                guard bytes <= limits.maxBytes else {
                    throw BuilderWorkspaceTransactionError.traversalLimit
                }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                entries.append(.init(path: relative, type: .regular, mode: mode,
                                     byteCount: Int64(data.count), contentDigest: digest,
                                     linkTarget: nil, deviceID: identity.0,
                                     inode: identity.1, linkCount: identity.2))
                if let destinationRoot, let destination {
                    try destinationRoot.writeData(relative, data, createParents: true)
                    guard chmod(destination.appendingPathComponent(relative).path, mode_t(mode)) == 0 else {
                        throw BuilderWorkspaceTransactionError.stateMismatch(
                            "cannot preserve mode for \(relative)")
                    }
                }
            } else if kind == mode_t(S_IFLNK) {
                guard scanMode == .restoration || info.st_nlink == 1 else {
                    throw BuilderWorkspaceTransactionError.specialFile(
                        "hard-linked symbolic link: \(relative)")
                }
                let target = try readLink(absolute, relative: relative)
                try validateLink(target, at: relative)
                let digest = BuilderEvidenceDigest.sha256(target)
                entries.append(.init(path: relative, type: .symlink, mode: mode,
                                     byteCount: Int64(target.utf8.count), contentDigest: digest,
                                     linkTarget: target, deviceID: identity.0,
                                     inode: identity.1, linkCount: identity.2))
                if let destination {
                    let targetURL = destination.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(
                        at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.createSymbolicLink(
                        atPath: targetURL.path, withDestinationPath: target)
                }
            } else {
                guard scanMode == .restoration, destination == nil else {
                    throw BuilderWorkspaceTransactionError.specialFile(relative)
                }
                entries.append(.init(
                    path: relative, type: .special, mode: mode, byteCount: 0,
                    contentDigest: nil, linkTarget: nil, deviceID: identity.0,
                    inode: identity.1, linkCount: identity.2))
            }
        }
        if let enumerationFailure {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "governed-root enumeration failed: \(enumerationFailure.localizedDescription)")
        }
        return BuilderWorkspaceManifest(entries: entries, totalBytes: bytes)
    }

    private static func validateLink(_ target: String, at path: String) throws {
        guard !target.hasPrefix("/"), !target.hasPrefix("~") else {
            throw BuilderWorkspaceTransactionError.escapingSymlink(path)
        }
        var resolved = path.split(separator: "/").dropLast().map(String.init)
        for component in target.split(separator: "/", omittingEmptySubsequences: false) {
            let value = String(component)
            if value.isEmpty || value == "." { continue }
            if value == ".." {
                guard !resolved.isEmpty else {
                    throw BuilderWorkspaceTransactionError.escapingSymlink(path)
                }
                resolved.removeLast()
            } else {
                guard !BuilderPathSecurity.isControlComponent(value) else {
                    throw BuilderWorkspaceTransactionError.controlPath(path)
                }
                resolved.append(value)
            }
        }
    }

    private static func readLink(_ absolute: String, relative: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4097)
        let count = readlink(absolute, &buffer, 4096)
        guard count >= 0, count < 4096 else {
            throw BuilderWorkspaceTransactionError.escapingSymlink(relative)
        }
        buffer[Int(count)] = 0
        return String(cString: buffer)
    }

    private static func createDirectorySecure(_ url: URL, mode: mode_t) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard chmod(url.path, mode) == 0 else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "cannot set directory mode at \(url.path)")
        }
    }
}

enum BuilderPathSecurity {
    private static let control = Set([".git", ".kist"])

    static func canonicalComponent(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func isControlComponent(_ value: String) -> Bool {
        control.contains(canonicalComponent(value))
    }

    static func containsControlComponent(_ path: String) -> Bool {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .contains { isControlComponent(String($0)) }
    }

    static func authorityKey(_ path: String) throws -> String {
        let normalized = try BuilderExecutionValidation.path(path)
        guard !containsControlComponent(normalized) else {
            throw BuilderWorkspaceTransactionError.controlPath(normalized)
        }
        return normalized.split(separator: "/").map { canonicalComponent(String($0)) }
            .joined(separator: "/")
    }
}
