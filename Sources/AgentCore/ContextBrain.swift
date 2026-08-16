import Foundation

/// Project-local context index: a deterministic map of every non-ignored regular file and
/// retrievable text chunks. This is the "hot load / swap out" layer for models with finite
/// context windows: keep a small stable map in prompt, then fetch exact shards on demand.
public struct ContextBrainIndex: Sendable, Equatable {
    public struct FileRecord: Sendable, Equatable {
        public let path: String
        public let bytes: Int
        public let isText: Bool
        public let chunkIDs: [String]
        public let note: String?
    }

    public struct Chunk: Sendable, Equatable {
        public let id: String
        public let path: String
        public let startLine: Int
        public let endLine: Int
        public let characters: Int
        public let text: String
    }

    public let root: String
    public let files: [FileRecord]
    public let chunks: [Chunk]
    public let skippedDirectories: [String]

    public var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }
    public var indexedTextBytes: Int { files.filter(\.isText).reduce(0) { $0 + $1.bytes } }
    public var textFileCount: Int { files.filter(\.isText).count }
    public var binaryOrLargeCount: Int { files.count - textFileCount }

    public static let defaultSkipDirectories: Set<String> = [
        ".git", ".build", ".kist", "DerivedData", "node_modules", ".swiftpm",
        ".claude", ".codex", "build", "dist", ".next",
        // Language/package managers keep downloaded SDKs, package registries, and
        // generated artifacts here. They are never project context and can dwarf a
        // home-root workspace by millions of entries.
        ".cache", ".cargo", ".gradle", ".npm", ".nvm", ".rustup", ".local",
        ".gem", ".nuget", ".android", ".docker", ".wine", ".Trash",
        // A launch-root workspace may intentionally be the user's home. The
        // macOS Library is OS/app state rather than project source and can hold
        // multi-million-entry app bundles and iCloud mirrors; indexing it makes
        // an otherwise valid headless run appear permanently stuck.
        "Library"
    ]

    public static func build(root: String,
                             chunkCharacters: Int = 12_000,
                             maxFileBytes: Int = 2_000_000,
                             maxTotalTextBytes: Int = 64_000_000,
                             maxWalkEntries: Int = 25_000,
                             skipDirectories: Set<String> = defaultSkipDirectories) throws -> ContextBrainIndex {
        let confined = try ConfinedRoot(root: root)
        let canonicalRoot = confined.rootPath
        var filePaths: [String] = []
        var walkedEntries = 0
        try confined.walk("", skipDirs: skipDirectories) { relPath, isDir in
            walkedEntries += 1
            guard walkedEntries <= max(1, maxWalkEntries) else {
                throw ToolError.execution(
                    "context index entry budget exceeded (\(maxWalkEntries)); " +
                    "use a narrower project root or exclude generated/cache directories")
            }
            if !isDir { filePaths.append(relPath) }
        }
        filePaths.sort()

        var files: [FileRecord] = []
        var chunks: [Chunk] = []
        var indexedBytes = 0
        for path in filePaths {
            let meta = try confined.fileMetadata(path)
            guard meta.isRegular else { continue }
            if meta.bytes > maxFileBytes {
                files.append(FileRecord(path: path, bytes: meta.bytes, isText: false, chunkIDs: [],
                                        note: "too_large_for_inline_index"))
                continue
            }
            if indexedBytes + meta.bytes > maxTotalTextBytes {
                files.append(FileRecord(path: path, bytes: meta.bytes, isText: false, chunkIDs: [],
                                        note: "index_total_byte_budget_exceeded"))
                continue
            }
            let data = try confined.readData(path)
            if data.count > maxFileBytes {
                files.append(FileRecord(path: path, bytes: data.count, isText: false, chunkIDs: [],
                                        note: "too_large_for_inline_index"))
                continue
            }
            if indexedBytes + data.count > maxTotalTextBytes {
                files.append(FileRecord(path: path, bytes: data.count, isText: false, chunkIDs: [],
                                        note: "index_total_byte_budget_exceeded"))
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else {
                files.append(FileRecord(path: path, bytes: data.count, isText: false, chunkIDs: [],
                                        note: "binary_or_non_utf8"))
                continue
            }
            let made = makeChunks(path: path, text: text, chunkCharacters: chunkCharacters)
            chunks += made
            indexedBytes += data.count
            files.append(FileRecord(path: path, bytes: data.count, isText: true,
                                    chunkIDs: made.map(\.id), note: made.isEmpty ? "empty_text_file" : nil))
        }

        return ContextBrainIndex(root: canonicalRoot, files: files, chunks: chunks,
                                 skippedDirectories: Array(skipDirectories).sorted())
    }

    public static func sourceSignature(root: String,
                                       maxWalkEntries: Int = 25_000,
                                       skipDirectories: Set<String> = defaultSkipDirectories) throws -> String {
        let confined = try ConfinedRoot(root: root)
        var parts: [String] = []
        var walkedEntries = 0
        try confined.walk("", skipDirs: skipDirectories) { relPath, isDir in
            walkedEntries += 1
            guard walkedEntries <= max(1, maxWalkEntries) else {
                throw ToolError.execution(
                    "context index entry budget exceeded (\(maxWalkEntries)); " +
                    "use a narrower project root or exclude generated/cache directories")
            }
            guard !isDir else { return }
            let meta = try confined.fileMetadata(relPath)
            guard meta.isRegular else { return }
            parts.append("\(relPath)\u{0}\(meta.bytes)\u{0}\(meta.modifiedNanos)")
        }
        return parts.sorted().joined(separator: "\u{1f}")
    }

    public func chunk(id: String) -> Chunk? {
        chunks.first { $0.id == id }
    }

    public func chunks(forPath path: String) -> [Chunk] {
        chunks.filter { $0.path == path }
    }

    public func search(_ query: String, limit: Int = 12) -> [Chunk] {
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return [] }
        return chunks.compactMap { chunk -> (Chunk, Int)? in
            let haystack = (chunk.path + "\n" + chunk.text).lowercased()
            var score = 0
            for term in terms {
                if chunk.path.lowercased().contains(term) { score += 8 }
                score += haystack.components(separatedBy: term).count - 1
            }
            return score > 0 ? (chunk, score) : nil
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.id < $1.0.id
        }
        .prefix(max(1, limit))
        .map(\.0)
    }

    public func coverageBatches(maxCharacters: Int) -> [[Chunk]] {
        let budget = max(2_000, maxCharacters)
        var batches: [[Chunk]] = []
        var current: [Chunk] = []
        var used = 0
        for chunk in chunks {
            let cost = chunk.characters + chunk.id.count + 64
            if !current.isEmpty, used + cost > budget {
                batches.append(current)
                current = []
                used = 0
            }
            current.append(chunk)
            used += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    public func renderMap(limit: Int = 120) -> String {
        var lines: [String] = [
            "Context brain index",
            "Root: \(root)",
            "Files: \(files.count) · text: \(textFileCount) · metadata-only: \(binaryOrLargeCount) · chunks: \(chunks.count) · indexed text bytes: \(indexedTextBytes) · bytes: \(totalBytes)",
            "Skipped directories: \(skippedDirectories.joined(separator: ", "))",
            "",
        ]
        for file in files.prefix(max(1, limit)) {
            let chunkPart = file.chunkIDs.isEmpty ? "no text chunks" : "\(file.chunkIDs.count) chunk(s)"
            let note = file.note.map { " · \($0)" } ?? ""
            lines.append("- \(file.path) · \(file.bytes) bytes · \(chunkPart)\(note)")
            if let first = file.chunkIDs.first {
                lines.append("  first: \(first)")
            }
        }
        if files.count > limit { lines.append("... \(files.count - limit) more file(s)") }
        return lines.joined(separator: "\n")
    }

    static func makeChunks(path: String, text: String, chunkCharacters: Int) -> [Chunk] {
        guard !text.isEmpty else { return [] }
        let budget = max(1_000, chunkCharacters)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [Chunk] = []
        var start = 1
        var current: [String] = []
        var chars = 0

        func flush(endLine: Int) {
            guard !current.isEmpty else { return }
            let body = current.joined(separator: "\n")
            let id = "\(path):L\(start)-L\(endLine)"
            out.append(Chunk(id: id, path: path, startLine: start, endLine: endLine,
                             characters: body.count, text: body))
        }

        for (idx, line) in lines.enumerated() {
            let lineNo = idx + 1
            if !current.isEmpty, chars + line.count + 1 > budget {
                flush(endLine: lineNo - 1)
                current = []
                chars = 0
                start = lineNo
            }
            current.append(line)
            chars += line.count + 1
        }
        flush(endLine: lines.count)
        return out
    }

    static func parseChunkID(_ id: String) -> (path: String, start: Int, end: Int)? {
        guard let marker = id.range(of: ":L", options: .backwards) else { return nil }
        let path = String(id[..<marker.lowerBound])
        let range = id[marker.upperBound...]
        let pieces = range.split(separator: "-", maxSplits: 1).map(String.init)
        guard pieces.count == 2,
              let start = Int(pieces[0].replacingOccurrences(of: "L", with: "")),
              let end = Int(pieces[1].replacingOccurrences(of: "L", with: "")),
              start > 0, end >= start else { return nil }
        return (path, start, end)
    }

    static func terms(_ query: String) -> [String] {
        query.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map(String.init)
            .filter { $0.count >= 2 }
    }
}
