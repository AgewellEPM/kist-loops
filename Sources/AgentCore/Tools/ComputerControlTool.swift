import Foundation

/// Controlled OS automation for the conversational Kist surface.
///
/// This deliberately exposes a small set of typed actions instead of raw shell:
/// open an app, open a URL, search YouTube, or clean the Desktop by moving visible
/// items into a timestamped folder. Kist marks this tool as sensitive so the REPL
/// asks before it controls the user's machine.
public struct ComputerControlTool: AgentTool {
    public typealias ProcessRunner = @Sendable (_ launchPath: String, _ args: [String], _ cwd: String, _ timeout: Int) async -> ToolResult

    public let name = "computer_control"
    public let description = """
    Control the local computer through safe, typed actions. Use for requests like opening Safari, opening a web page, searching YouTube, or cleaning the Desktop. Cleaning moves visible Desktop items into a timestamped folder; it never deletes them.
    """
    public let parameters = [
        ToolParameter(name: "action", type: "string", description: "One of: open_app, open_url, youtube_search, clean_desktop."),
        ToolParameter(name: "target", type: "string", description: "App name, URL, YouTube search query, or optional cleanup label.", required: false),
        ToolParameter(name: "dry_run", type: "boolean", description: "For clean_desktop: preview what would move without changing files. Default false.", required: false),
    ]

    // CAPABILITY CONTRACT — the live fix for the model inventing actions like move_file / run_script / help.
    public var supportedActions: [String] { ["open_app", "open_url", "youtube_search", "clean_desktop"] }
    public var unsupportedActions: [String] {
        ["move_file", "move_files", "organize_files", "delete_file", "rename_file", "run_script", "run_command", "help"]
    }
    public var capabilityNote: String? {
        "Does NOT move, rename, organize, or delete arbitrary files, and does NOT run scripts. `clean_desktop` "
        + "ONLY sweeps loose Desktop items into one timestamped folder — it can't target a specific subfolder. "
        + "For real file operations use run_command (only if shell is enabled); if shell is off, say so and ask the user."
    }
    public var usageExamples: [String] {
        ["computer_control(action=\"open_app\", target=\"Safari\")",
         "computer_control(action=\"clean_desktop\", dry_run=true)"]
    }

    private let desktopPath: String?
    private let runner: ProcessRunner

    public init(desktopPath: String? = nil, runner: ProcessRunner? = nil) {
        self.desktopPath = desktopPath
        self.runner = runner ?? Self.defaultRunner
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let action = try requireString("action", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = (arguments["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch action {
        case "open_app":
            guard !target.isEmpty else { return .failure("target is required for open_app") }
            return await openApp(target, context: context)
        case "open_url":
            guard let url = Self.validWebURL(target) else {
                return .failure("target must be an http(s) URL")
            }
            return await openURL(url.absoluteString, context: context)
        case "youtube_search":
            guard !target.isEmpty else { return .failure("target is required for youtube_search") }
            guard let url = Self.youtubeSearchURL(query: target) else {
                return .failure("could not build YouTube search URL")
            }
            return await openURL(url, context: context)
        case "clean_desktop":
            return cleanDesktop(label: target, dryRun: optionalBool("dry_run", from: arguments))
        default:
            return .failure("unsupported computer_control action: \(action)")
        }
    }

    // MARK: - Public pure helpers for tests and hosts

    public static func youtubeSearchURL(query: String) -> String? {
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return components?.url?.absoluteString
    }

    public static func validWebURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    // MARK: - App / URL control

    private func openApp(_ app: String, context: ToolContext) async -> ToolResult {
        #if os(macOS)
        return await runner("/usr/bin/open", Self.macOSOpenAppArgs(for: app), context.projectRoot, 30)
        #elseif os(Linux)
        let commands = Self.linuxAppCommands(for: app)
        guard !commands.isEmpty else {
            return .failure("unsupported Linux app target: \(app). Try a known app like firefox, chrome, chromium, files, or terminal.")
        }
        for command in commands {
            if let path = RunCommandTool.resolveExecutable(command.executable, env: RunCommandTool.scrubbedEnvironment()) {
                return await runner(path, command.args, context.projectRoot, 30)
            }
        }
        return .failure("Linux app launcher not found for: \(app)")
        #else
        return .failure("open_app is not supported on this platform")
        #endif
    }

    #if os(macOS)
    static func macOSOpenAppArgs(for app: String) -> [String] {
        let normalized = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let browserApps: Set<String> = [
            "arc", "brave", "brave browser", "chrome", "chromium", "firefox",
            "google chrome", "microsoft edge", "safari"
        ]
        guard browserApps.contains(normalized) else { return ["-a", app] }
        // Opening a browser app by name can leave an already-running app with no visible window.
        // A blank URL gives the user a concrete browser window while preserving the plain "open app" intent.
        return ["-a", app, "about:blank"]
    }
    #endif

    private func openURL(_ url: String, context: ToolContext) async -> ToolResult {
        #if os(macOS)
        return await runner("/usr/bin/open", [url], context.projectRoot, 30)
        #elseif os(Linux)
        guard let opener = RunCommandTool.resolveExecutable("xdg-open", env: RunCommandTool.scrubbedEnvironment()) else {
            return .failure("xdg-open is required to open URLs on Linux")
        }
        return await runner(opener, [url], context.projectRoot, 30)
        #else
        return .failure("open_url is not supported on this platform")
        #endif
    }

    #if os(Linux)
    static func linuxAppCommands(for app: String) -> [(executable: String, args: [String])] {
        let key = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "firefox": return [("firefox", [])]
        case "chrome", "google chrome", "google-chrome":
            return [("google-chrome", []), ("google-chrome-stable", [])]
        case "chromium", "chromium browser", "chromium-browser":
            return [("chromium-browser", []), ("chromium", [])]
        case "files", "file manager", "folder", "home folder":
            return [("xdg-open", [FileManager.default.homeDirectoryForCurrentUser.path])]
        case "terminal", "shell":
            return [("x-terminal-emulator", []), ("gnome-terminal", []), ("konsole", [])]
        case "safari":
            return []
        default:
            return []
        }
    }
    #endif

    // MARK: - Desktop cleanup

    private func cleanDesktop(label: String, dryRun: Bool) -> ToolResult {
        let fm = FileManager.default
        let desktop = desktopPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: desktop.path, isDirectory: &isDir), isDir.boolValue else {
            return .failure("Desktop folder not found at \(desktop.path)")
        }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: desktop, includingPropertiesForKeys: nil, options: [])
        } catch {
            return .failure("could not list Desktop: \(error.localizedDescription)")
        }

        let movable = entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .filter { !$0.lastPathComponent.hasPrefix("Mythos Desktop Cleanup") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !movable.isEmpty else {
            return ToolResult(success: true, output: "desktop already clean")
        }

        let folderLabel = Self.cleanupFolderName(label: label)
        let destination = uniqueDirectoryURL(in: desktop, named: folderLabel)
        let preview = movable.map { "- \($0.lastPathComponent)" }.joined(separator: "\n")

        if dryRun {
            return ToolResult(
                success: true,
                output: "Would move \(movable.count) Desktop item(s) into \(destination.path):\n\(preview)",
                metadata: ["count": String(movable.count), "destination": destination.path, "dry_run": "true"]
            )
        }

        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            for item in movable {
                let target = uniqueChildURL(in: destination, named: item.lastPathComponent)
                try fm.moveItem(at: item, to: target)
            }
        } catch {
            return .failure("could not clean Desktop: \(error.localizedDescription)")
        }

        return ToolResult(
            success: true,
            output: "Moved \(movable.count) Desktop item(s) into \(destination.path):\n\(preview)",
            metadata: ["count": String(movable.count), "destination": destination.path, "dry_run": "false"]
        )
    }

    private static func cleanupFolderName(label: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let suffix = formatter.string(from: Date())
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Mythos Desktop Cleanup \(suffix)" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        var safe = ""
        for scalar in trimmed.unicodeScalars {
            safe.unicodeScalars.append(allowed.contains(scalar) ? scalar : UnicodeScalar("-"))
        }
        let limited = String(safe.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
        guard !limited.isEmpty else { return "Mythos Desktop Cleanup \(suffix)" }
        return "Mythos Desktop Cleanup \(limited) \(suffix)"
    }

    private func uniqueDirectoryURL(in parent: URL, named name: String) -> URL {
        uniqueChildURL(in: parent, named: name)
    }

    private func uniqueChildURL(in parent: URL, named name: String) -> URL {
        let fm = FileManager.default
        let base = parent.appendingPathComponent(name)
        if !fm.fileExists(atPath: base.path) { return base }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = parent.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func optionalBool(_ key: String, from arguments: [String: Any]) -> Bool {
        if let b = arguments[key] as? Bool { return b }
        if let s = arguments[key] as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "y", "1": return true
            default: return false
            }
        }
        if let n = arguments[key] as? Int { return n != 0 }
        return false
    }

    private static let defaultRunner: ProcessRunner = { launchPath, args, cwd, timeout in
        await RunCommandTool.spawnAndCollect(launchPath: launchPath, launchArgs: args, cwd: cwd, timeout: timeout)
    }
}
