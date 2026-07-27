import Foundation

/// Agent tool: periodically capture the local screen and ask a vision model what changed.
/// macOS uses `screencapture`; other platforms fail clearly until an xdg/Wayland backend is added.
public struct LiveScreenWatchTool: AgentTool {
    public let name = "live_screen_watch"
    public let description = """
    Watch the current computer screen for a short bounded window by taking periodic screenshots and \
    asking a vision model what changed. Use for observing app/browser behavior after actions. Requires \
    screen-recording permission and shell access; macOS backend uses screencapture.
    """
    public let parameters = [
        ToolParameter(name: "seconds", type: "integer", description: "Total watch duration (default 10, max 60).", required: false),
        ToolParameter(name: "interval", type: "integer", description: "Seconds between screenshots (default 2, min 1, max 10).", required: false),
        ToolParameter(name: "question", type: "string", description: "Optional focused question, e.g. 'did Safari open?'.", required: false),
        ToolParameter(name: "out_dir", type: "string", description: "Project-relative folder to store screenshots.", required: false),
    ]

    private let capture: @Sendable (_ outDir: String, _ count: Int, _ interval: Int, _ context: ToolContext) async throws -> [String]
    private let analyze: @Sendable (_ frames: [MediaAttachment], _ prompt: String) async throws -> String

    public init(registry: ProviderRegistry, binding: ProviderBinding) {
        self.capture = { outDir, count, interval, context in
            try await Self.captureScreens(outDir: outDir, count: count, interval: interval, context: context)
        }
        self.analyze = { frames, prompt in
            try await registry.complete(providerId: binding.providerId, model: binding.model,
                                        messages: [
                                            ChatMessage(role: .system, content: "You are a precise screen observer. Compare screenshots in order and report only visible changes."),
                                            ChatMessage(role: .user, content: prompt, attachments: frames),
                                        ],
                                        settings: ModelSettings(temperature: 0.0, maxTokens: 2000))
        }
    }

    public init(capture: @escaping @Sendable (_ outDir: String, _ count: Int, _ interval: Int, _ context: ToolContext) async throws -> [String],
                analyze: @escaping @Sendable (_ frames: [MediaAttachment], _ prompt: String) async throws -> String) {
        self.capture = capture
        self.analyze = analyze
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let total = min(max(optionalInt("seconds", from: arguments) ?? 10, 1), 60)
        let interval = min(max(optionalInt("interval", from: arguments) ?? 2, 1), 10)
        let count = min(max(Int(ceil(Double(total) / Double(interval))) + 1, 1), 30)
        let outDirArg = (arguments["out_dir"] as? String) ?? ".mythos/screen-watch/\(Int(Date().timeIntervalSince1970))"
        let outDir = try context.resolvedPath(outDirArg, mustExist: false)
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let shots = try await capture(outDir, count, interval, context)
        guard !shots.isEmpty else { return .failure("no screenshots captured") }
        let attachments = try shots.map { path -> MediaAttachment in
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return MediaAttachment(kind: .image, mimeType: "image/png", payload: .inline(data), sourcePath: path)
        }
        let question = (arguments["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = Self.prompt(interval: interval, count: attachments.count, question: question)
        let report = try await analyze(attachments, prompt)
        let rel = shots.map { WatchVideoTool.relativePath($0, root: context.projectRoot) }
        return ToolResult(success: true,
                          output: "Live screen watch · \(attachments.count) screenshot(s), interval \(interval)s\nScreenshots:\n" +
                                  rel.map { "  \($0)" }.joined(separator: "\n") +
                                  "\n\n" + report.trimmingCharacters(in: .whitespacesAndNewlines),
                          metadata: ["screenshots": String(attachments.count), "out_dir": outDirArg])
    }

    static func captureScreens(outDir: String, count: Int, interval: Int, context: ToolContext) async throws -> [String] {
        #if os(macOS)
        let exe = "/usr/sbin/screencapture"
        if let reason = await context.shell.binaryRefusalReason(resolvedPath: exe, args: ["-x", outDir + "/screen_0001.png"]) {
            throw ToolError.shellDenied("screencapture blocked by shell policy: \(reason) (try --allow-shell)")
        }
        var paths: [String] = []
        for i in 1...count {
            let path = outDir + "/" + String(format: "screen_%04d.png", i)
            let run = await RunCommandTool.spawnAndCollect(launchPath: exe, launchArgs: ["-x", path],
                                                           cwd: context.projectRoot, timeout: 20)
            guard run.success, FileManager.default.fileExists(atPath: path) else {
                throw ToolError.execution(run.error ?? run.output)
            }
            paths.append(path)
            if i < count { try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000) }
        }
        return paths
        #else
        throw ToolError.configuration("live_screen_watch currently supports macOS screencapture only")
        #endif
    }

    static func prompt(interval: Int, count: Int, question: String) -> String {
        var p = """
        The attached screenshots are ordered captures from the user's screen, taken every \(interval) second(s) (\(count) capture(s)).
        Report:
        - what changed across screenshots
        - whether the expected app/page/state appears
        - visible errors, dialogs, loading states, or permission blockers
        - the next useful action
        """
        if !question.isEmpty { p += "\nFocus question: \(question)" }
        return p
    }
}
