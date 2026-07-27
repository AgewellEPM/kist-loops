import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Streams a video INSIDE the terminal grid (local file or URL) by driving `mpv` with a
/// terminal-native video output. No separate window opens.
///
/// Output driver is chosen by terminal capability:
///   • Kitty / Ghostty  → `--vo=kitty`  (crisp, native graphics protocol)
///   • everything else   → `--vo=tct`    (Unicode + ANSI colour cells — works in Terminal.app)
///
/// URLs stream via mpv's yt-dlp integration when present (`mpv <youtube-url>`). Honest, fail-fast:
/// if mpv (or yt-dlp for a URL) is missing we return the exact `brew install` command, never a hang.
enum TerminalVideoPlayer {
    enum Driver: String { case kitty, tct }

    static func driver(env: [String: String] = ProcessInfo.processInfo.environment) -> Driver {
        let program = (env["TERM_PROGRAM"] ?? "").lowercased()
        let term = (env["TERM"] ?? "").lowercased()
        if env["KITTY_WINDOW_ID"] != nil || term.contains("kitty") || program.contains("ghostty") {
            return .kitty
        }
        return .tct
    }

    static func isURL(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://")
    }

    /// Build the mpv argument list for a target. `tctWidth` caps the terminal-cell render width.
    static func arguments(for target: String, driver: Driver, tctWidth: Int) -> [String] {
        var args = ["--really-quiet", "--vo=\(driver.rawValue)"]
        if driver == .tct { args.append("--vo-tct-width=\(max(1, tctWidth))") }
        args.append(target)
        return args
    }

    /// Play `target` (a resolved local path or a URL), blocking until playback ends. Returns a
    /// human-facing status string; nil on a clean finish (nothing to print).
    static func play(target: String,
                     env: [String: String] = ProcessInfo.processInfo.environment,
                     columns: Int) -> String? {
        guard let mpv = resolveExecutable("mpv", env: env) else {
            return "video streaming needs mpv — install it: brew install mpv"
        }
        if isURL(target), resolveExecutable("yt-dlp", env: env) == nil, resolveExecutable("youtube-dl", env: env) == nil {
            return "streaming a URL needs yt-dlp — install it: brew install yt-dlp"
        }
        let drv = driver(env: env)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: mpv)
        proc.arguments = arguments(for: target, driver: drv, tctWidth: columns)
        // mpv draws to the live terminal — inherit stdio so its frames land in this window.
        do { try proc.run() } catch {
            return "couldn't launch mpv: \(error.localizedDescription)"
        }
        proc.waitUntilExit()
        return proc.terminationStatus == 0 ? nil
            : "mpv exited with status \(proc.terminationStatus) (driver \(drv.rawValue))"
    }

    static func resolveExecutable(_ name: String, env: [String: String]) -> String? {
        let envPath = env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = envPath.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
