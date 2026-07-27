import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum TerminalMediaRenderer {
    enum ProtocolKind: String, Equatable {
        case none
        case iterm2
        case kitty
        case ansiBlocks      // universal Unicode half-block fallback — works in Terminal.app
    }

    static let maxInlineBytes = 10 * 1024 * 1024

    static func detect(env: [String: String] = ProcessInfo.processInfo.environment,
                       isTTY: Bool = isatty(fileno(stdout)) != 0) -> ProtocolKind {
        guard isTTY, env["KIST_MEDIA_PREVIEW"] != "0" else { return .none }
        let term = (env["TERM"] ?? "").lowercased()
        let program = (env["TERM_PROGRAM"] ?? "").lowercased()
        if env["KITTY_WINDOW_ID"] != nil || term.contains("kitty") || program.contains("ghostty") {
            return .kitty
        }
        if program.contains("iterm") || program.contains("wezterm") || env["WEZTERM_PANE"] != nil {
            return .iterm2
        }
        // No pixel protocol (Terminal.app et al.) — but a TTY can still show ANSI colour blocks.
        return .ansiBlocks
    }

    /// Terminal width in columns for sizing ANSI-block renders. ioctl → COLUMNS env → default.
    static func terminalColumns(default def: Int = 80) -> Int {
        var ws = winsize()
        if ioctl(fileno(stdout), TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 { return Int(ws.ws_col) }
        if let c = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(c), n > 0 { return n }
        return def
    }

    /// Whether the terminal advertises 24-bit colour (so ANSI blocks use truecolor, else xterm-256).
    static func supportsTruecolor(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let ct = (env["COLORTERM"] ?? "").lowercased()
        return ct.contains("truecolor") || ct.contains("24bit")
    }

    static func status(env: [String: String] = ProcessInfo.processInfo.environment,
                       isTTY: Bool = isatty(fileno(stdout)) != 0) -> String {
        switch detect(env: env, isTTY: isTTY) {
        case .iterm2:
            return "terminal media preview: iTerm2/WezTerm inline image protocol"
        case .kitty:
            return "terminal media preview: Kitty graphics protocol"
        case .ansiBlocks:
            return "terminal media preview: ANSI half-block (works here; for crisp pixels use Kitty, Ghostty, iTerm2, or WezTerm)"
        case .none:
            return "terminal media preview unavailable (output is not a TTY or KIST_MEDIA_PREVIEW=0)."
        }
    }

    static func preview(attachments: [MediaAttachment],
                        env: [String: String] = ProcessInfo.processInfo.environment,
                        isTTY: Bool = isatty(fileno(stdout)) != 0) -> String? {
        let proto = detect(env: env, isTTY: isTTY)
        guard proto != .none else { return nil }
        let rendered = attachments.compactMap { preview(attachment: $0, protocolKind: proto) }
        guard !rendered.isEmpty else { return nil }
        return rendered.joined(separator: "\n")
    }

    static func previewFile(_ path: String,
                            projectRoot: String,
                            env: [String: String] = ProcessInfo.processInfo.environment,
                            isTTY: Bool = isatty(fileno(stdout)) != 0) -> String {
        let proto = detect(env: env, isTTY: isTTY)
        guard proto != .none else { return status(env: env, isTTY: isTTY) }

        let token = MediaResolver.tokenize(path).first ?? path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return "usage: /media <image-or-video-path>" }
        guard let (_, mime, resolved) = MediaResolver.classify(token, projectRoot: projectRoot) else {
            return "media preview: '\(token)' is not a recognized local image/video/audio/pdf file"
        }
        guard let (kind, _) = MediaAttachment.kindAndMime(forExtension: (resolved as NSString).pathExtension.lowercased()) else {
            return "media preview: unsupported file type"
        }

        switch kind {
        case .image:
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)) else {
                return "media preview: couldn't read \(token)"
            }
            return renderImage(data: data, mimeType: mime, name: (resolved as NSString).lastPathComponent, protocolKind: proto)
        case .video:
            guard let data = videoPosterFrame(path: resolved) else {
                return "media preview: video poster needs ffmpeg on PATH; model vision can still inspect the video attachment"
            }
            return renderImage(data: data, mimeType: "image/png", name: (resolved as NSString).lastPathComponent + ".poster.png", protocolKind: proto)
        case .audio:
            return "media preview: audio has no inline visual preview; it can still be sent to a media-capable model"
        case .pdf:
            return "media preview: PDF inline preview is not implemented yet; it can still be sent to a vision-capable model"
        }
    }

    private static func preview(attachment: MediaAttachment, protocolKind: ProtocolKind) -> String? {
        switch attachment.kind {
        case .image:
            guard let data = attachment.inlineData else { return nil }
            return renderImage(data: data, mimeType: attachment.mimeType, name: displayName(attachment), protocolKind: protocolKind)
        case .video:
            guard let path = attachment.sourcePath, FileManager.default.fileExists(atPath: path),
                  let data = videoPosterFrame(path: path) else { return nil }
            return renderImage(data: data, mimeType: "image/png", name: displayName(attachment) + ".poster.png", protocolKind: protocolKind)
        case .audio, .pdf:
            return nil
        }
    }

    static func renderImage(data: Data, mimeType: String, name: String, protocolKind: ProtocolKind) -> String {
        switch protocolKind {
        case .iterm2:
            guard data.count <= maxInlineBytes else {
                return "media preview: \(name) is over \(maxInlineBytes) bytes; not rendering inline"
            }
            return iterm2Sequence(data: data, name: name)
        case .kitty:
            guard data.count <= maxInlineBytes else {
                return "media preview: \(name) is over \(maxInlineBytes) bytes; not rendering inline"
            }
            return kittySequence(data: data)
        case .ansiBlocks:
            // Decode + downscale, so the source byte size doesn't matter (no inline cap needed).
            return AnsiImageRenderer.render(data: data, maxCols: terminalColumns(),
                                            truecolor: supportsTruecolor())
                ?? "media preview: couldn't decode \(name) as an image"
        case .none:
            return "terminal media preview unavailable here"
        }
    }

    static func iterm2Sequence(data: Data, name: String) -> String {
        let encoded = data.base64EncodedString()
        let encodedName = Data(name.utf8).base64EncodedString()
        return "\u{001B}]1337;File=inline=1;name=\(encodedName);width=80%;height=auto;preserveAspectRatio=1:\(encoded)\u{0007}"
    }

    /// Kitty graphics protocol. Per spec, ONLY the first chunk carries the control keys (f=100,a=T);
    /// every continuation chunk carries ONLY `m` (1 = more follows, 0 = final). The previous version
    /// repeated `f=100,a=T` on every chunk and omitted the terminating `m=0`, so any image large
    /// enough to span >1 chunk (i.e. essentially every real photo) failed to render. Fixed.
    static func kittySequence(data: Data, chunkSize: Int = 4096) -> String {
        let encoded = data.base64EncodedString()
        var out = ""
        var index = encoded.startIndex
        var isFirst = true
        while index < encoded.endIndex {
            let next = encoded.index(index, offsetBy: chunkSize, limitedBy: encoded.endIndex) ?? encoded.endIndex
            let chunk = String(encoded[index..<next])
            let more = next < encoded.endIndex ? "1" : "0"
            let control = isFirst ? "f=100,a=T,m=\(more)" : "m=\(more)"
            out += "\u{001B}_G\(control);\(chunk)\u{001B}\\"
            isFirst = false
            index = next
        }
        return out
    }

    private static func displayName(_ attachment: MediaAttachment) -> String {
        guard let source = attachment.sourcePath, source != "clipboard" else {
            return "clipboard.\(attachment.mimeType.split(separator: "/").last ?? "media")"
        }
        return (source as NSString).lastPathComponent
    }

    private static func videoPosterFrame(path: String) -> Data? {
        guard let ffmpeg = resolveExecutable("ffmpeg") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-ss", "00:00:01",
            "-i", path,
            "-frames:v", "1",
            "-f", "image2pipe",
            "-vcodec", "png",
            "-"
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            sema.signal()
        }
        guard sema.wait(timeout: .now() + 8) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty || data.count > maxInlineBytes ? nil : data
    }

    private static func resolveExecutable(_ name: String) -> String? {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = envPath.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
