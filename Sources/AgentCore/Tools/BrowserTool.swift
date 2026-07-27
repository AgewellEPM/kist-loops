import Foundation

/// Agent tool: drive a headless browser to load a JS-rendered page and (optionally) interact with it —
/// click, fill, wait, press, screenshot — then extract the rendered text/HTML. Interactivity uses
/// Playwright (node). Agent input is passed as a JSON spec to a CONSTANT driver, so selectors/values
/// can't inject code. Shell-gated. Every browser request (entry URL, redirects, and subresources) is
/// SSRF/allowlist checked before it leaves the process; screenshot paths are root-confined before launch.
/// Needs Playwright installed + --allow-shell. LIVE-VERIFIED (BrowserLiveTests: renders example.com and
/// extracts its text via Playwright when node+chromium are present).
public struct BrowserTool: AgentTool {
    public let name = "browse"
    public let description = """
    Load a web page in a headless browser (renders JavaScript) and return its text/HTML. Optionally \
    perform actions first: [{"do":"fill","selector":"#q","value":"hi"},{"do":"click","selector":"button"}]. \
    For interactive pages where fetch_url (static HTML) isn't enough.
    """
    public let parameters = [
        ToolParameter(name: "url", type: "string", description: "http(s) URL to load."),
        ToolParameter(name: "actions", type: "array", description: "Optional steps: objects with do=click/fill/wait/press/screenshot.", required: false),
        ToolParameter(name: "extract", type: "string", description: "text (default) or html.", required: false),
    ]

    private let allowedHosts: Set<String>
    private let allowLocalhost: Bool

    public init(allowedHosts: [String] = [], allowLocalhost: Bool = false) {
        self.allowedHosts = Set(allowedHosts.compactMap(WebFetchTool.normalizedHostPattern))
        self.allowLocalhost = allowLocalhost
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let url = try requireString("url", from: arguments)
        guard let parsedURL = URL(string: url), let scheme = parsedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parsedURL.host else {
            return .failure("browse only loads http(s) URLs (got '\(url.prefix(40))')")
        }
        let callAllowlist = (arguments["allowed_hosts"] as? [String])?
            .compactMap(WebFetchTool.normalizedHostPattern) ?? []
        if let reason = WebFetchTool.allowlistBlockReason(host: host, configured: allowedHosts, perCall: Set(callAllowlist)) {
            return .failure("refused (host allowlist): \(reason)")
        }
        let localCaptureAllowed = allowLocalhost && Self.isAllowedLocalhostHost(host)
        if let reason = WebFetchTool.ssrfBlockReason(host: host), !localCaptureAllowed {
            return .failure("refused (SSRF guard): \(reason)")
        }
        let parsedActions: [BrowserAction] = (arguments["actions"] as? [[String: Any]] ?? []).compactMap(BrowserAction.parse)
        let actions: [BrowserAction]
        do {
            actions = try parsedActions.map { try $0.confined(to: context) }
            try createScreenshotParents(for: actions)
        } catch {
            return .failure("refused screenshot path: \(error)")
        }
        let extract = (arguments["extract"] as? String ?? "text").lowercased()
        let env = ProcessInfo.processInfo.environment

        // Playwright (node) — full interactivity with per-request network policy.
        if let node = RunCommandTool.resolveExecutable("node", env: env) {
            let localCaptureHost = localCaptureAllowed ? Self.normalizedLocalhostHost(host) : nil
            let localCapturePort = localCaptureAllowed ? Self.normalizedPort(parsedURL) : nil
            guard let spec = BrowserSpec.jsonString(url: url, actions: actions, extract: extract,
                                                    configuredAllowedHosts: Array(allowedHosts).sorted(),
                                                    perCallAllowedHosts: callAllowlist.sorted(),
                                                    allowLocalhost: localCaptureAllowed,
                                                    localCaptureHost: localCaptureHost,
                                                    localCapturePort: localCapturePort) else {
                return .failure("could not encode the browse spec")
            }
            let driverPath = NSTemporaryDirectory() + "kist-browser-driver-\(UUID().uuidString).js"
            do {
                try Self.writeDriver(at: driverPath)
            } catch {
                return .failure("could not create browser driver: \(error.localizedDescription)")
            }
            defer { try? FileManager.default.removeItem(atPath: driverPath) }
            // argv[3]: absolute playwright module path, so a GLOBAL `npm i -g playwright` resolves from
            // this temp-dir driver (Node won't search global node_modules otherwise). Empty ⇒ bare require.
            let args = [driverPath, spec, Self.playwrightModulePath()]
            if let reason = await context.shell.binaryRefusalReason(resolvedPath: node, args: args) {
                return .failure("browser blocked by shell policy: \(reason) (try --allow-shell)")
            }
            let run = await spawnBrowser(launchPath: node, args: args, context: context, timeout: 60)
            if run.success { return ToolResult(success: true, output: run.output, metadata: ["engine": "playwright"]) }
            if (run.error ?? run.output).contains("Cannot find module 'playwright'") {
                return .failure("Playwright not installed. Run: npm i -g playwright && npx playwright install chromium")
            }
            return run
        }

        return .failure("no safe browser engine found. Install Node + Playwright: npm i -g playwright && npx playwright install chromium")
    }

    /// Absolute path to the `playwright` module if installed in a standard GLOBAL location (Node does
    /// not search global node_modules from a temp-dir script). Returns `playwright` for the driver to
    /// resolve normally when a local install / NODE_PATH covers it.
    static func playwrightModulePath() -> String {
        let roots = ["/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules", "/usr/lib/node_modules",
                     NSHomeDirectory() + "/.npm-global/lib/node_modules", NSHomeDirectory() + "/node_modules"]
        for root in roots where FileManager.default.fileExists(atPath: root + "/playwright") {
            return root + "/playwright"
        }
        return "playwright"
    }

    static func writeDriver(at path: String) throws {
        let data = Data(BrowserSpec.driverJS.utf8)
        let ok = FileManager.default.createFile(atPath: path, contents: data,
                                                attributes: [.posixPermissions: 0o600])
        if !ok {
            throw NSError(domain: "BrowserTool", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "createFile failed"])
        }
    }

    static func isAllowedLocalhostHost(_ host: String) -> Bool {
        let normalized = normalizedLocalhostHost(host)
        if normalized == "localhost" { return true }
        if normalized.hasPrefix("127.") { return true }
        return normalized == "::" || normalized == "::1"
    }

    static func normalizedLocalhostHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    static func normalizedPort(_ url: URL) -> String {
        if let port = url.port { return String(port) }
        return url.scheme?.lowercased() == "https" ? "443" : "80"
    }

    private func createScreenshotParents(for actions: [BrowserAction]) throws {
        for action in actions {
            if case .screenshot(let path) = action {
                let dir = (path as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }
    }

    private func spawnBrowser(launchPath: String, args: [String], context: ToolContext, timeout: Int) async -> ToolResult {
        let finalPath: String
        let finalArgs: [String]
        switch SeatbeltSandbox.wrap(launchPath: launchPath, args: args, root: context.projectRoot, policy: context.sandbox) {
        case .passthrough:
            finalPath = launchPath; finalArgs = args
        case .wrapped(let p, let a):
            finalPath = p; finalArgs = a
        case .unavailable(let reason):
            return .failure("OS sandbox required but unavailable: \(reason)")
        }

        let limited = RunCommandTool.resourceLimitedLaunch(
            launchPath: finalPath,
            launchArgs: finalArgs,
            limits: RunCommandTool.ResourceLimits(cpuSeconds: timeout, fileSizeMB: 512, memoryMB: nil)
        )
        return await RunCommandTool.spawnAndCollect(
            launchPath: limited.launchPath, launchArgs: limited.launchArgs,
            cwd: context.projectRoot, timeout: timeout
        )
    }
}
