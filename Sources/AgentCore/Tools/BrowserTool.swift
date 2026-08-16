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
        ToolParameter(name: "allowed_hosts", type: "array", description: "Optional per-call host allowlist that narrows public-web access or the configured allowlist.", required: false),
    ]

    private let allowedHosts: Set<String>
    private let configuredAllowlistIsValid: Bool
    private let allowLocalhost: Bool
    static let maxActions = 64

    public init(allowedHosts: [String] = [], allowLocalhost: Bool = false) {
        let policy = WebFetchTool.normalizedHostPatterns(allowedHosts)
        self.allowedHosts = policy.patterns
        self.configuredAllowlistIsValid = policy.isValid
        self.allowLocalhost = allowLocalhost
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let url = try requireString("url", from: arguments)
        guard configuredAllowlistIsValid else {
            return .failure("refused (host allowlist): configured browser host allowlist contains an invalid pattern")
        }
        guard url.utf8.count <= PublicWebTransport.maxURLBytes else {
            return .failure("browse URL exceeds the public-web byte limit")
        }
        guard url.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }), !url.contains("\\"),
              let parsedURL = URL(string: url), let scheme = parsedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parsedURL.host,
              parsedURL.user == nil, parsedURL.password == nil,
              parsedURL.port.map({ (1...65_535).contains($0) }) ?? true else {
            return .failure("browse only loads http(s) URLs (got '\(url.prefix(40))')")
        }
        var callAllowlist: Set<String> = []
        if let raw = arguments["allowed_hosts"] {
            guard let hosts = raw as? [String], !hosts.isEmpty else {
                return .failure("refused (host allowlist): allowed_hosts must be a non-empty string array when provided")
            }
            let normalized = hosts.compactMap(WebFetchTool.normalizedHostPattern)
            guard normalized.count == hosts.count else {
                return .failure("refused (host allowlist): allowed_hosts contains an invalid host pattern")
            }
            callAllowlist = Set(normalized)
        }
        if let reason = WebFetchTool.allowlistBlockReason(host: host, configured: allowedHosts, perCall: callAllowlist) {
            return .failure("refused (host allowlist): \(reason)")
        }
        let localCaptureAllowed = allowLocalhost && Self.isAllowedLocalhostHost(host)
        let normalizedInitialHost = WebFetchTool.normalizedHostPattern(host)
        if !localCaptureAllowed {
            if normalizedInitialHost == "localhost"
                || normalizedInitialHost?.hasSuffix(".localhost") == true {
                return .failure("refused (SSRF guard): localhost is not allowed")
            }
            if let normalizedInitialHost,
               let literal = WebFetchTool.parsedIPAddress(normalizedInitialHost),
               !WebFetchTool.isGlobalUnicastAddress(literal) {
                return .failure("refused (SSRF guard): target is non-global/special-purpose")
            }
        }
        let actionDictionaries: [[String: Any]]
        if let rawActions = arguments["actions"] {
            guard let parsed = rawActions as? [[String: Any]], parsed.count <= Self.maxActions else {
                return .failure("actions must be an array of at most \(Self.maxActions) valid action objects")
            }
            actionDictionaries = parsed
        } else {
            actionDictionaries = []
        }
        let parsedActions = actionDictionaries.compactMap(BrowserAction.parse)
        guard parsedActions.count == actionDictionaries.count else {
            return .failure("actions contains an invalid browser action")
        }
        let actions: [BrowserAction]
        do {
            actions = try parsedActions.map { try $0.confined(to: context) }
        } catch {
            return .failure("refused screenshot path: \(error)")
        }
        let extract = (arguments["extract"] as? String ?? "text").lowercased()
        let env = ProcessInfo.processInfo.environment

        // Playwright (node) — full interactivity with per-request network policy.
        if let node = RunCommandTool.resolveExecutable("node", env: env) {
            let driverPath = NSTemporaryDirectory() + "kist-browser-driver-\(UUID().uuidString).js"
            let args = [driverPath, Self.playwrightModulePath()]
            if let reason = await context.shell.binaryRefusalReason(resolvedPath: node, args: args) {
                return .failure("browser blocked by shell policy: \(reason) (try --allow-shell)")
            }
            do {
                try createScreenshotParents(for: actions)
            } catch {
                return .failure("could not create screenshot directory: \(error.localizedDescription)")
            }
            let localCaptureHost = localCaptureAllowed ? Self.normalizedLocalhostHost(host) : nil
            let localCapturePort = localCaptureAllowed ? Self.normalizedPort(parsedURL) : nil
            let proxy: PublicWebSOCKSProxy
            do {
                proxy = try PublicWebSOCKSProxy.start(
                    configuredAllowedHosts: allowedHosts,
                    perCallAllowedHosts: callAllowlist,
                    localCaptureScheme: localCaptureAllowed ? scheme : nil,
                    localCaptureHost: localCaptureHost,
                    localCapturePort: localCapturePort.flatMap(UInt16.init))
            } catch {
                return .failure("could not start pinned browser proxy: \(error.localizedDescription)")
            }
            defer { proxy.stop() }
            guard let spec = BrowserSpec.jsonString(url: url, actions: actions, extract: extract,
                                                    configuredAllowedHosts: Array(allowedHosts).sorted(),
                                                    perCallAllowedHosts: Array(callAllowlist).sorted(),
                                                    allowLocalhost: localCaptureAllowed,
                                                    proxyServer: proxy.endpoint,
                                                    proxyUsername: proxy.proxyUsername,
                                                    proxyPassword: proxy.proxyPassword,
                                                    localCaptureScheme: localCaptureAllowed ? scheme : nil,
                                                    localCaptureHost: localCaptureHost,
                                                    localCapturePort: localCapturePort) else {
                return .failure("could not encode the browse spec")
            }
            do {
                try Self.writeDriver(at: driverPath)
            } catch {
                return .failure("could not create browser driver: \(error.localizedDescription)")
            }
            defer { try? FileManager.default.removeItem(atPath: driverPath) }
            // argv[3]: absolute playwright module path, so a GLOBAL `npm i -g playwright` resolves from
            // this temp-dir driver (Node won't search global node_modules otherwise). Empty ⇒ bare require.
            let specData = Data(spec.utf8)
            guard specData.count <= RunCommandTool.maxStdinBytes else {
                return .failure("browse spec exceeds the private input byte limit")
            }
            let run = await spawnBrowser(launchPath: node, args: args, context: context,
                                         timeout: 60, stdinData: specData,
                                         allowedProxyPort: proxy.port)
            if run.success {
                return ToolResult(success: true, output: run.output,
                                  metadata: ["engine": "playwright",
                                             "network_mode": "pinned-authenticated-http-proxy"])
            }
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
        return normalized == "::1"
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

    private func spawnBrowser(launchPath: String, args: [String], context: ToolContext, timeout: Int,
                              stdinData: Data, allowedProxyPort: UInt16) async -> ToolResult {
        let finalPath: String
        let finalArgs: [String]
        // Public browsing is never an unsandboxed subprocess capability. `--sandbox` controls ordinary
        // commands, but BrowserTool handles hostile remote content and therefore always establishes the
        // confined baseline itself. The only egress granted to Chromium is this invocation's exact,
        // authenticated loopback proxy port; the proxy owns DNS, SSRF, redirect and host-allowlist policy.
        let confinement = context.sandbox.enabled ? context.sandbox : SandboxPolicy.confined()
        let browserSandbox = confinement.allowingLoopbackTCPPort(allowedProxyPort)
        switch SeatbeltSandbox.wrap(launchPath: launchPath, args: args,
                                    root: context.projectRoot, policy: browserSandbox) {
        case .passthrough:
            finalPath = launchPath; finalArgs = args
        case .wrapped(let p, let a):
            finalPath = p; finalArgs = a
        case .unavailable(let reason):
            return .failure("OS sandbox required but unavailable: \(reason)")
        }

        return await RunCommandTool.spawnAndCollect(
            launchPath: finalPath, launchArgs: finalArgs,
            cwd: context.projectRoot, timeout: timeout, stdinData: stdinData
        )
    }
}
