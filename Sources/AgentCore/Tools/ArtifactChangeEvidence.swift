import Foundation
import Crypto

/// Pre/post evidence for a built-in tool output. The target is normalized to a project-relative path
/// once, then every content read goes through `ConfinedRoot` (O_NOFOLLOW). File payloads are hashed in
/// chunks, and directory snapshots hash a deterministic manifest of names + per-file hashes.
struct ArtifactOutputEvidence: Sendable {
    enum Kind: String, Sendable {
        case file
        case directory
    }

    private enum Snapshot: Sendable, Equatable {
        case missing
        case other
        case file(bytes: Int, sha256: Data)
        case directory(sha256: Data)
    }

    let relativePath: String
    let absolutePath: String
    let kind: Kind
    private let before: Snapshot

    static func prepare(path: String, kind: Kind, context: ToolContext) throws -> Self {
        let root = try context.confinedRoot()
        let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ToolError.execution("artifact output path is empty") }

        // resolvedPath is the canonical confinement check and normalizes the actual target. Metadata
        // and the write use this same project-relative path, so the reported artifact cannot diverge.
        let candidate = try context.resolvedPath(raw, mustExist: false)
        let prefix = root.rootPath == "/" ? "/" : root.rootPath + "/"
        guard candidate.hasPrefix(prefix), candidate != root.rootPath else {
            throw ToolError.pathEscape(path: path, root: root.rootPath)
        }
        let relative = String(candidate.dropFirst(prefix.count))
        guard !relative.isEmpty, relative != "." else {
            throw ToolError.execution("artifact output must be below the project root")
        }
        return Self(relativePath: relative, absolutePath: candidate, kind: kind,
                    before: try snapshot(relativePath: relative, root: root))
    }

    func ensureParentDirectory(context: ToolContext) throws {
        guard kind == .file else { return }
        let parent = (relativePath as NSString).deletingLastPathComponent
        if !parent.isEmpty, parent != "." {
            try context.confinedRoot().makeDirectory(parent)
        }
    }

    /// Metadata consumed by `ToolEffectCatalog`. `artifact_confined=true` is emitted only by this
    /// helper after a confined post-write snapshot of the exact normalized target succeeds.
    func resultMetadata(context: ToolContext) throws -> [String: String] {
        let root = try context.confinedRoot()
        let after = try Self.snapshot(relativePath: relativePath, root: root)
        switch (kind, after) {
        case (.file, .file), (.directory, .directory): break
        default:
            throw ToolError.execution("artifact tool reported success but did not produce the expected \(kind.rawValue): \(relativePath)")
        }
        return [
            "artifact_path": relativePath,
            "artifact_kind": kind.rawValue,
            "artifact_confined": "true",
            "changed": before == after ? "false" : "true",
        ]
    }

    /// Validate a path returned by an injected/native capture backend as a regular descendant of this
    /// output directory, and return its project-relative spelling for confined reads.
    func confinedDescendant(_ path: String, context: ToolContext) throws -> String {
        guard kind == .directory else {
            throw ToolError.execution("artifact descendant validation requires a directory target")
        }
        let resolved = try context.resolvedPath(path, mustExist: true)
        let prefix = absolutePath.hasSuffix("/") ? absolutePath : absolutePath + "/"
        guard resolved.hasPrefix(prefix) else {
            throw ToolError.pathEscape(path: path, root: absolutePath)
        }
        let root = try context.confinedRoot()
        let rootPrefix = root.rootPath == "/" ? "/" : root.rootPath + "/"
        guard resolved.hasPrefix(rootPrefix) else {
            throw ToolError.pathEscape(path: path, root: root.rootPath)
        }
        let relative = String(resolved.dropFirst(rootPrefix.count))
        let metadata = try root.fileMetadata(relative)
        guard metadata.isRegular else { throw ToolError.execution("not a regular artifact file: \(relative)") }
        return relative
    }

    private static func snapshot(relativePath: String, root: ConfinedRoot) throws -> Snapshot {
        let type: (exists: Bool, isDir: Bool)
        do {
            type = try root.fileType(relativePath)
        } catch {
            // `fileType` cannot open a missing intermediate directory. Distinguish that ordinary
            // absent-output case from a present but blocked/symlinked path, which must fail closed.
            let absolute = root.rootPath + "/" + relativePath
            guard !FileManager.default.fileExists(atPath: absolute) else { throw error }
            return .missing
        }
        guard type.exists else { return .missing }
        if type.isDir { return .directory(sha256: try directorySHA256(relativePath, root: root)) }
        let metadata = try root.fileMetadata(relativePath)
        guard metadata.isRegular else { return .other }
        return .file(bytes: metadata.bytes, sha256: try root.fileSHA256(relativePath))
    }

    /// Deterministic, streaming directory snapshot. Only entry names and 32-byte file digests are kept
    /// in the hasher; generated videos/images themselves are never loaded into memory.
    private static func directorySHA256(_ relativePath: String, root: ConfinedRoot) throws -> Data {
        var hasher = SHA256()
        var pending: [(path: String, display: String)] = [(relativePath, "")]
        while let directory = pending.popLast() {
            let entries = try root.entries(directory.path) // sorted by name
            var childDirectories: [(path: String, display: String)] = []
            for entry in entries {
                let childPath = directory.path + "/" + entry.name
                let display = directory.display.isEmpty ? entry.name : directory.display + "/" + entry.name
                if entry.isDir {
                    hasher.update(data: Data("d\0\(display)\0".utf8))
                    childDirectories.append((childPath, display))
                } else {
                    let metadata = try root.fileMetadata(childPath)
                    // Symlinks/devices are represented by their name/type only and never followed.
                    guard metadata.isRegular else {
                        hasher.update(data: Data("o\0\(display)\0".utf8))
                        continue
                    }
                    hasher.update(data: Data("f\0\(display)\0\(metadata.bytes)\0".utf8))
                    hasher.update(data: try root.fileSHA256(childPath))
                }
            }
            // LIFO stack: push reverse-sorted so subdirectories are traversed in sorted order.
            pending.append(contentsOf: childDirectories.reversed())
        }
        return Data(hasher.finalize())
    }
}

extension Dictionary where Key == String, Value == String {
    mutating func mergeArtifactMetadata(_ evidence: ArtifactOutputEvidence,
                                        context: ToolContext) throws {
        merge(try evidence.resultMetadata(context: context), uniquingKeysWith: { _, new in new })
    }
}
