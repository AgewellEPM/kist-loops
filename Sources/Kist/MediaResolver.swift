import Foundation
import AgentCore

/// Turns dragged-in file paths into agent attachments. When you drag an image / video / sound clip
/// from Finder into a macOS terminal, the terminal pastes the file's POSIX path as text (quoted or
/// backslash-escaped). This resolver finds those media paths in the typed line, decides inline vs
/// Files-API upload by size, and strips them from the prompt — so "what's in this? <dragged
/// photo.png>" reaches the model as the question PLUS the media. No terminal image protocol needed;
/// works in Terminal.app, iTerm2, Ghostty alike.
struct MediaResolver {
    /// Bytes at or below which we inline (base64 in-request). Above this, the file goes through the
    /// Gemini Files API (Phase 2). Gemini's inline ceiling is ~100MB; 20MB is a safe, fast default.
    static let inlineCapBytes = 20 * 1024 * 1024

    /// A media file too big to inline — the caller uploads it via the Files API, then attaches the uri.
    struct PendingUpload: Equatable {
        var path: String
        var kind: MediaAttachment.Kind
        var mimeType: String
        var size: Int
        var displayName: String { (path as NSString).lastPathComponent }
    }

    struct Result: Equatable {
        var prompt: String                 // the line with media paths removed
        var attachments: [MediaAttachment] // ready to send inline
        var uploads: [PendingUpload]       // need a Files-API upload first
        var notes: [String]                // human-facing notes (inlined/queued/unreadable)
    }

    /// Resolve media paths in `input` against the filesystem. `fileSize`/`read` are injectable for
    /// tests (and so we never read a multi-GB file just to measure it — size is checked first).
    static func resolve(_ input: String,
                        projectRoot: String,
                        inlineCap: Int = inlineCapBytes,
                        fileSize: (String) -> Int? = Self.defaultSize,
                        read: (String) -> Data? = Self.defaultRead) -> Result {
        let tokens = tokenize(input)
        var keptPrompt: [String] = []
        var attachments: [MediaAttachment] = []
        var uploads: [PendingUpload] = []
        var notes: [String] = []
        var seenMediaPaths = Set<String>()

        for token in tokens {
            guard let (kind, mime, path) = classify(token, projectRoot: projectRoot) else {
                keptPrompt.append(token)                       // ordinary word — keep in the prompt
                continue
            }
            let canonicalPath = ToolContext.canonicalize(path) ?? path
            if seenMediaPaths.contains(canonicalPath) {
                continue                                       // strip duplicate pasted/dragged media refs
            }
            guard let size = fileSize(path) else {
                notes.append("couldn't read \(name(path)) — left as text")
                keptPrompt.append(token)
                continue
            }
            if size <= inlineCap {
                guard let data = read(path) else {
                    notes.append("couldn't read \(name(path)) — left as text")
                    keptPrompt.append(token)
                    continue
                }
                seenMediaPaths.insert(canonicalPath)
                attachments.append(MediaAttachment(kind: kind, mimeType: mime,
                                                   payload: .inline(data), sourcePath: canonicalPath))
                notes.append("attached \(kind.rawValue): \(name(canonicalPath))")
            } else {
                seenMediaPaths.insert(canonicalPath)
                uploads.append(PendingUpload(path: canonicalPath, kind: kind, mimeType: mime, size: size))
                let mb = String(format: "%.0f", Double(size) / 1_048_576)
                notes.append("queued \(kind.rawValue) for upload: \(name(canonicalPath)) (\(mb)MB)")
            }
        }

        return Result(prompt: keptPrompt.joined(separator: " ").trimmingCharacters(in: .whitespaces),
                      attachments: attachments, uploads: uploads, notes: notes)
    }

    /// Classify a token as a media file. Accepts an optional leading `@` (explicit ref) and resolves
    /// relative paths against `projectRoot` and `~`. Returns nil for non-media or non-existent paths.
    static func classify(_ rawToken: String, projectRoot: String) -> (MediaAttachment.Kind, String, String)? {
        var token = rawToken
        if token.hasPrefix("@") { token.removeFirst() }                  // @file explicit ref
        guard !token.isEmpty else { return nil }

        let ext = (token as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let (kind, mime) = MediaAttachment.kindAndMime(forExtension: ext) else { return nil }

        for candidate in candidatePaths(token, projectRoot: projectRoot) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                return (kind, mime, candidate)
            }
        }
        return nil
    }

    /// Where a token might live: absolute as-is, ~-expanded, or relative to the project root.
    static func candidatePaths(_ token: String, projectRoot: String) -> [String] {
        if token.hasPrefix("/") { return [token] }
        if token.hasPrefix("~") { return [(token as NSString).expandingTildeInPath] }
        return [
            (projectRoot as NSString).appendingPathComponent(token),
            FileManager.default.currentDirectoryPath + "/" + token
        ]
    }

    /// Shell-lite word splitter: splits on unquoted whitespace, honoring '...' , "..." , and
    /// backslash escapes — exactly how a dragged path arrives (e.g. `/a/My\ Photo.png` or
    /// `'/a/My Photo.png'`). Returns unescaped/unquoted tokens; empty tokens are dropped.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var iterator = input.makeIterator()
        enum Mode { case normal, single, double }
        var mode: Mode = .normal

        func flush() { if hasCurrent { tokens.append(current) }; current = ""; hasCurrent = false }

        while let ch = iterator.next() {
            switch mode {
            case .normal:
                switch ch {
                case "\\":
                    if let next = iterator.next() { current.append(next); hasCurrent = true }
                case "'": mode = .single; hasCurrent = true
                case "\"": mode = .double; hasCurrent = true
                case " ", "\t", "\n": flush()
                default: current.append(ch); hasCurrent = true
                }
            case .single:
                if ch == "'" { mode = .normal } else { current.append(ch) }
            case .double:
                if ch == "\"" { mode = .normal }
                else if ch == "\\" { if let next = iterator.next() { current.append(next) } }
                else { current.append(ch) }
            }
        }
        flush()
        return tokens
    }

    static func defaultSize(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
    }

    static func defaultRead(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }
}
