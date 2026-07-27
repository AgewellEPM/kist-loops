import Foundation

// MARK: - MCP Client Config (AgentCore)
//
// Loads the set of EXTERNAL MCP servers AgentCore (Kist / mcp-server / the GUI) is
// allowed to spawn as a client. Mirrors the Claude Code / `.mcp.json` shape:
//
//   { "mcpServers": { "<name>": { "command": "...", "args": [...], "env": {...} } } }
//
// SECURITY: spawning an external process from on-disk config is the single most
// dangerous thing this feature does. Every entry is validated + allowlisted here
// BEFORE it reaches `Process`. Trust boundary:
//   - config file is user-owned (we read it, never write it)
//   - command must be an ABSOLUTE path to a real, regular, executable file
//   - command/args may NOT contain shell metacharacters or `..` traversal
//   - inherited env is allowlisted; the host's arbitrary environment is NOT passed
//
// Config search order (first file to define a server name wins; later files only
// ADD new names, never override):
//   1. ~/.mcp.json                    (user-owned)
//   2. ~/.config/agentcore/mcp.json   (canonical, cross-platform XDG-style)
//
// SECURITY (CRITICAL): the workspace-local `<projectRoot>/.mcp.json` is NOT loaded by
// default. A checked-out repo could otherwise drop a `.mcp.json` pointing `command`
// at `/bin/sh` + a repo-local script and get arbitrary code execution at discovery
// time — an untrusted-workspace RCE. Project-local config is opt-in only, via
// `allowProjectConfig: true`, which a caller should set ONLY for a workspace the user
// has explicitly trusted.

/// One external MCP server definition, post-validation. Sendable so it can be
/// handed to the connection actor.
public struct MCPServerConfig: Sendable, Equatable {
    public let name: String
    public let command: String
    public let args: [String]
    public let env: [String: String]
    /// HTTP (Streamable-HTTP) transport: when non-nil, this server is reached over HTTP JSON-RPC at
    /// `url` (command/args/env unused). `headers` are sent on every request (auth, e.g. Authorization).
    public let url: String?
    public let headers: [String: String]

    public init(name: String, command: String = "", args: [String] = [], env: [String: String] = [:],
                url: String? = nil, headers: [String: String] = [:]) {
        self.name = name; self.command = command; self.args = args; self.env = env
        self.url = url; self.headers = headers
    }

    /// True for the HTTP transport (vs stdio subprocess).
    public var isHTTP: Bool { url != nil }
}

/// A non-fatal problem found while loading config. One bad entry must never block
/// the others.
public struct MCPConfigIssue: Sendable, Equatable {
    public let server: String
    public let reason: String
}

public enum MCPClientConfig {

    /// Host env keys we will INHERIT and pass to a spawned server. Anything else is
    /// dropped so a server can't be handed our API keys by accident. The server's
    /// own `env` block (from config) is applied on top — the user opted into those.
    static let inheritedEnvAllowlist: Set<String> = ["PATH", "HOME", "LANG", "LC_ALL", "TZ", "USER", "TMPDIR"]

    /// Substrings that, in a config-supplied env KEY, trigger a warning (not a block —
    /// e.g. a github server legitimately needs a token). Makes secret-handling visible.
    static let secretKeyHints: [String] = ["TOKEN", "SECRET", "KEY", "PASSWORD", "PASSWD", "CREDENTIAL"]

    /// Characters never allowed in a command path or argument. We never invoke a
    /// shell, so these aren't directly exploitable, but rejecting them is cheap
    /// defense-in-depth and catches misconfigured entries early.
    private static let forbiddenMetacharacters: Set<Character> = [";", "&", "|", "`", "$", "\n", "\r", "\0", "<", ">"]

    // MARK: - Loading

    /// Load + validate all configured servers. Never throws; a missing/garbage file
    /// yields `[]`.
    ///
    /// - Parameter allowProjectConfig: when true, ALSO load `<projectRoot>/.mcp.json`.
    ///   Off by default — see the CRITICAL note above. Only enable for a workspace the
    ///   user has explicitly trusted.
    public static func load(projectRoot: String, allowProjectConfig: Bool = false,
                            includeUserConfig: Bool = true) -> (servers: [MCPServerConfig], issues: [MCPConfigIssue]) {
        var servers: [MCPServerConfig] = []
        var issues: [MCPConfigIssue] = []
        var seen: Set<String> = []

        for path in candidatePaths(projectRoot: projectRoot, allowProjectConfig: allowProjectConfig,
                                   includeUserConfig: includeUserConfig) {
            guard let raw = rawServers(atPath: path) else { continue }
            for (name, entry) in raw {
                guard !seen.contains(name) else { continue }   // first file wins
                seen.insert(name)
                switch validate(name: name, entry: entry) {
                case .success(let cfg, let warnings):
                    servers.append(cfg)
                    issues.append(contentsOf: warnings)
                case .failure(let reason):
                    issues.append(MCPConfigIssue(server: name, reason: reason))
                }
            }
        }
        return (servers, issues)
    }

    static func candidatePaths(projectRoot: String, allowProjectConfig: Bool = false,
                               includeUserConfig: Bool = true) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        // Project-local config FIRST only when explicitly trusted (opt-in).
        if allowProjectConfig, !projectRoot.isEmpty {
            paths.append((projectRoot as NSString).appendingPathComponent(".mcp.json"))
        }
        if includeUserConfig {
            paths.append((home as NSString).appendingPathComponent(".mcp.json"))
            paths.append((home as NSString).appendingPathComponent(".config/agentcore/mcp.json"))
        }
        return paths
    }

    // MARK: - Parsing

    private static func rawServers(atPath path: String) -> [String: [String: Any]]? {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else {
            return nil
        }
        var result: [String: [String: Any]] = [:]
        for (name, value) in servers {
            if let entry = value as? [String: Any] { result[name] = entry }
        }
        return result
    }

    // MARK: - Validation

    private enum ValidationOutcome {
        case success(MCPServerConfig, warnings: [MCPConfigIssue])
        case failure(reason: String)
    }

    /// Validate an HTTP-transport server entry: an http(s) `url` (SSRF-guarded so a config can't point at
    /// internal/link-local hosts) + optional `headers` for auth. Header values expand `${ENV}` so secrets
    /// live in the environment, not the config file on disk.
    private static func validateHTTP(name: String, entry: [String: Any]) -> ValidationOutcome {
        guard let urlStr = (entry["url"] as? String)?.trimmingCharacters(in: .whitespaces), !urlStr.isEmpty else {
            return .failure(reason: "http transport requires a 'url'")
        }
        guard let url = URL(string: urlStr), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            return .failure(reason: "'url' must be an http(s) URL with a host")
        }
        // A user's OWN local MCP server (explicit loopback host) is a legit, common case — allow it. Any
        // other host is SSRF-guarded (blocks internal/link-local/cloud-metadata, and a public host that
        // resolves to internal = rebinding). The distinction is whether the CONFIG explicitly said loopback.
        let loopback = isLoopbackHost(host)
        if !loopback, let reason = WebFetchTool.ssrfBlockReason(host: host) {
            return .failure(reason: "url refused (SSRF guard): \(reason)")
        }
        var headers: [String: String] = [:]
        var warnings: [MCPConfigIssue] = []
        if let raw = entry["headers"] {
            guard let dict = raw as? [String: String] else {
                return .failure(reason: "'headers' must be an object of string values")
            }
            for (k, v) in dict {
                if [k, v].contains(where: { $0.contains("\0") || $0.contains("\n") || $0.contains("\r") }) {
                    return .failure(reason: "'headers' contains a control character")
                }
                // Warn if a ${VAR} reference is unset — an empty auth header is a silent misconfig (Codex).
                if let missing = unsetEnvReference(in: v) {
                    warnings.append(MCPConfigIssue(server: name, reason: "header '\(k)' references unset env var ${\(missing)} — it will be empty"))
                }
                headers[k] = expandEnv(v)
            }
        }
        // Require HTTPS for any non-loopback endpoint. Beyond keeping auth off the wire, TLS cert
        // validation is our DNS-REBINDING PIN: a host that (re)resolves to an internal IP can't present a
        // valid certificate for the configured public hostname, so the handshake fails BEFORE any request
        // body or Authorization header is sent — closing the resolve-time-of-check/time-of-use gap that a
        // hostname re-check alone leaves open (Codex). Loopback http is fine (never leaves the machine).
        if scheme == "http", !loopback {
            return .failure(reason: "http (cleartext) url is refused for a non-loopback MCP server — use https (also the DNS-rebinding pin)")
        }
        return .success(MCPServerConfig(name: name, url: urlStr, headers: headers), warnings: warnings)
    }

    /// True when a host explicitly names loopback (localhost / 127.0.0.0/8 / ::1) — a user's own local
    /// server, which is allowed. A public host that later *resolves* to loopback is NOT this (that's
    /// rebinding, caught by the request-time SSRF re-resolve).
    static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") || h == "::1" { return true }
        let parts = h.split(separator: ".")
        if parts.count == 4, parts.first == "127", parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return false
    }

    /// Replace `${VAR}` in a header value with the environment value (empty when unset), so tokens are
    /// referenced by name in config and supplied via the environment.
    /// The name of the first `${VAR}` reference that is unset in the environment, or nil if all resolve.
    static func unsetEnvReference(in s: String) -> String? {
        guard s.contains("${") else { return nil }
        let env = ProcessInfo.processInfo.environment
        var rest = Substring(s)
        while let open = rest.range(of: "${"), let close = rest.range(of: "}", range: open.upperBound..<rest.endIndex) {
            let key = String(rest[open.upperBound..<close.lowerBound])
            if env[key] == nil { return key }
            rest = rest[close.upperBound...]
        }
        return nil
    }

    static func expandEnv(_ s: String) -> String {
        guard s.contains("${") else { return s }
        let env = ProcessInfo.processInfo.environment
        var out = ""
        var rest = Substring(s)
        while let open = rest.range(of: "${"), let close = rest.range(of: "}", range: open.upperBound..<rest.endIndex) {
            out += rest[rest.startIndex..<open.lowerBound]
            let key = String(rest[open.upperBound..<close.lowerBound])
            out += env[key] ?? ""
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }

    private static func validate(name: String, entry: [String: Any]) -> ValidationOutcome {
        guard isSafeIdentifier(name) else {
            return .failure(reason: "server name '\(name)' is not a safe identifier (letters, digits, _ , -)")
        }
        // HTTP (Streamable-HTTP) transport: a `url` is present, or transport is http/streamable-http/sse.
        let transport = (entry["transport"] as? String)?.lowercased()
        if entry["url"] != nil || transport == "http" || transport == "streamable-http" || transport == "sse" {
            return validateHTTP(name: name, entry: entry)
        }
        // Otherwise stdio: a spawned subprocess.
        guard let command = (entry["command"] as? String)?.trimmingCharacters(in: .whitespaces), !command.isEmpty else {
            return .failure(reason: "missing 'command'")
        }
        // Absolute path only — no PATH resolution (an attacker who drops a binary
        // earlier in PATH would otherwise hijack execution).
        guard command.hasPrefix("/") else {
            return .failure(reason: "'command' must be an absolute path, got '\(command)'")
        }
        if command.contains("..") {
            return .failure(reason: "'command' must not contain '..'")
        }
        if let bad = firstForbiddenCharacter(in: command) {
            return .failure(reason: "'command' contains forbidden character '\(bad)'")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: command, isDirectory: &isDir), !isDir.boolValue else {
            return .failure(reason: "'command' is not an existing regular file: \(command)")
        }
        guard FileManager.default.isExecutableFile(atPath: command) else {
            return .failure(reason: "'command' is not executable: \(command)")
        }

        var args: [String] = []
        if let rawArgs = entry["args"] {
            guard let arr = rawArgs as? [String] else {
                return .failure(reason: "'args' must be an array of strings")
            }
            for a in arr {
                if let bad = firstForbiddenCharacter(in: a) {
                    return .failure(reason: "arg '\(a)' contains forbidden character '\(bad)'")
                }
                args.append(a)
            }
        }

        var env: [String: String] = [:]
        var warnings: [MCPConfigIssue] = []
        if let rawEnv = entry["env"] {
            guard let dict = rawEnv as? [String: String] else {
                return .failure(reason: "'env' must be an object of string values")
            }
            for (k, v) in dict {
                if k.contains("\0") || v.contains("\0") {
                    return .failure(reason: "'env' contains NUL byte")
                }
                if secretKeyHints.contains(where: { k.uppercased().contains($0) }) {
                    warnings.append(MCPConfigIssue(server: name, reason: "env key '\(k)' looks like a secret; it will be passed to the spawned process"))
                }
                env[k] = v
            }
        }

        return .success(MCPServerConfig(name: name, command: command, args: args, env: env), warnings: warnings)
    }

    /// Final environment for `Process`: allowlisted host vars + the server's explicit
    /// env (server env wins on collision).
    static func resolvedEnvironment(for config: MCPServerConfig) -> [String: String] {
        var result: [String: String] = [:]
        let host = ProcessInfo.processInfo.environment
        for key in inheritedEnvAllowlist {
            if let v = host[key] { result[key] = v }
        }
        for (k, v) in config.env { result[k] = v }
        return result
    }

    // MARK: - Helpers

    private static func isSafeIdentifier(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }
        // `__` is RESERVED as the server↔tool namespace separator (`<server>__<tool>`). A server name that
        // embeds it makes the split ambiguous and lets a scoped specialist reach an unintended server (Codex
        // HIGH, registration side). Single underscores are fine; reject the double-underscore sequence.
        guard !s.contains(MCPClientManager.namespaceSeparator) else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private static func firstForbiddenCharacter(in s: String) -> Character? {
        s.first { forbiddenMetacharacters.contains($0) }
    }
}
