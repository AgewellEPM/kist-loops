import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Lifecycle hooks — user-configured shell commands that fire around tool execution, the
/// Claude-Code parity surface for "run my own command before/after the agent touches anything."
///
/// Three events:
///   • **PreToolUse**  — before a tool runs. The hook may BLOCK it (non-zero exit, or stdout JSON
///     `{"block":true,"reason":"…"}`); the loop then tells the model the action was blocked.
///   • **PostToolUse** — after a tool runs (observe/log; cannot block — the side effect already happened).
///   • **Stop**        — when the run finishes (notify/cleanup).
///
/// Hooks are USER configuration (a different trust domain than the agent), so — like Claude Code —
/// they run as ordinary shell commands. They are OFF unless a `.kist/hooks.json` exists.
/// Foundation-only + `Sendable` so the loop stays portable (macOS + Linux).
public enum HookEvent: String, Sendable, Codable {
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case stop = "Stop"
    // Lifecycle notification events (observe/log/notify — cannot block):
    case sessionStart = "SessionStart"        // a session begins
    case userPromptSubmit = "UserPromptSubmit" // the user submits a turn
    case subagentStop = "SubagentStop"        // a spawned sub-agent finishes
    case preCompact = "PreCompact"            // before context is compacted/trimmed
}

/// One configured hook: an event, an optional tool-name matcher (regex; nil/`*` = all tools), and
/// the shell command line to run (fed the event payload as JSON on stdin).
public struct HookSpec: Sendable, Codable {
    public let event: HookEvent
    public let matcher: String?
    public let command: String
    public init(event: HookEvent, matcher: String?, command: String) {
        self.event = event; self.matcher = matcher; self.command = command
    }

    /// True if this hook applies to `tool`. nil / "*" / "" matches everything; otherwise the
    /// matcher is an anchored regex against the tool name (falls back to substring if not valid regex).
    func matches(tool: String) -> Bool {
        guard let m = matcher, m != "*", !m.isEmpty else { return true }
        if let re = try? NSRegularExpression(pattern: m) {
            let range = NSRange(tool.startIndex..., in: tool)
            return re.firstMatch(in: tool, range: range) != nil
        }
        return tool.contains(m)
    }
}

/// The outcome of firing the PreToolUse hooks for an action.
public struct HookDecision: Sendable {
    public let blocked: Bool
    public let reason: String?
    public static let allow = HookDecision(blocked: false, reason: nil)
    public init(blocked: Bool, reason: String?) { self.blocked = blocked; self.reason = reason }
}

/// Executes a single hook command with a JSON payload on stdin. Injectable so tests don't spawn
/// real processes. Returns (exitCode, combined stdout+stderr).
public protocol HookRunner: Sendable {
    func run(command: String, payloadJSON: String) async -> (exitCode: Int32, output: String)
}

/// Default runner: `/bin/sh -c <command>`, payload on stdin, output captured, killed after a timeout
/// so a hung hook can't wedge the agent.
public struct ProcessHookRunner: HookRunner {
    public let timeoutSeconds: Double
    public init(timeoutSeconds: Double = 15) { self.timeoutSeconds = timeoutSeconds }

    /// Best-effort resource limits applied to the hook shell BEFORE the user command runs — defense in
    /// depth atop the wall-clock timeout. CPU seconds (-t), file size (-f), max user processes (-u,
    /// anti-fork-bomb), address space (-v). Each ulimit is tolerant: a shell that doesn't support one
    /// (e.g. `-v` on macOS) emits to /dev/null and the next runs, so a legit hook is never broken.
    /// Only PER-PROCESS limits are set here. `-t` (CPU seconds) and `-f` (file size) are safe
    /// cross-platform. `-v` (RLIMIT_AS / address space) is gated to Linux — on macOS a process's
    /// virtual footprint far exceeds a sane cap, so setting it there kills legitimate commands.
    /// Deliberately NOT set: `-u` (RLIMIT_NPROC) is a PER-USER count of ALL the user's processes, so a
    /// low value breaks the very next fork on a busy session (anti-fork-bomb via ulimit is unreliable);
    /// the wall-clock timeout remains the primary runaway guard, and hooks are user-authored config.
    /// `command -p uname` uses the shell's DEFAULT PATH (not the inherited/attacker-influenced one), so a
    /// repo can't shadow `uname` with a planted binary in a `.`-on-PATH environment (Codex).
    private static let rlimitPreamble =
        "ulimit -t 20 2>/dev/null; ulimit -f 1048576 2>/dev/null; [ \"$(command -p uname)\" = Linux ] && ulimit -v 2097152 2>/dev/null; "

    public func run(command: String, payloadJSON: String) async -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.rlimitPreamble + command]
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = outPipe

        do { try process.run() } catch {
            return (127, "hook failed to launch: \(error.localizedDescription)")
        }
        // Feed the payload, then close stdin so the hook's read terminates.
        inPipe.fileHandleForWriting.write(Data(payloadJSON.utf8))
        try? inPipe.fileHandleForWriting.close()

        // Enforce the timeout out-of-band (Process has no built-in deadline).
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: deadline)

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}

/// Loaded set of hooks. `nil` (no config) means "no hooks" — the loop calls into this only when present.
public struct AgentHooks: Sendable {
    public let specs: [HookSpec]
    private let runner: HookRunner
    private let projectRoot: String

    public init(specs: [HookSpec], runner: HookRunner = ProcessHookRunner(), projectRoot: String) {
        self.specs = specs; self.runner = runner; self.projectRoot = projectRoot
    }

    /// Load hooks from a JSON file. Two accepted shapes:
    ///   • flat:    `[ {"event":"PreToolUse","matcher":"write_file","command":"…"} ]`
    ///   • grouped: `{ "preToolUse": [ {"matcher":"…","command":"…"} ], "stop": [ … ] }`
    /// Returns nil if the file is absent or unparseable (hooks are strictly opt-in; a broken config
    /// must not silently change behavior — the caller surfaces the parse error).
    public static func load(fromFile path: String, runner: HookRunner = ProcessHookRunner(), projectRoot: String) -> AgentHooks? {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let specs = parse(data) else { return nil }
        return AgentHooks(specs: specs, runner: runner, projectRoot: projectRoot)
    }

    /// User-level hook config paths — a trust domain the user OWNS, so these always load. The
    /// workspace-local `<root>/.kist/hooks.json` is deliberately NOT here (see `loadTrusted`).
    static func userHookPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [(home as NSString).appendingPathComponent(".kist/hooks.json"),
                (home as NSString).appendingPathComponent(".config/agentcore/hooks.json")]
    }

    /// The workspace-local hooks file. Loading this from an UNTRUSTED workspace is the danger.
    static func projectHookPath(projectRoot: String) -> String {
        (projectRoot as NSString).appendingPathComponent(".kist/hooks.json")
    }

    /// Trust-gated loader. SECURITY (CRITICAL): a checked-out repo can ship `.kist/hooks.json`, and
    /// hooks run as `/bin/sh -c <command>` (`ProcessHookRunner`). Auto-loading a workspace hooks file
    /// is therefore arbitrary code execution the instant the agent touches a tool — the SAME class of
    /// untrusted-workspace RCE that `MCPClientConfig` blocks for `.mcp.json`. So:
    ///   • user-level hooks (`~/.kist/hooks.json`, `~/.config/agentcore/hooks.json`) ALWAYS load — the
    ///     user owns that config;
    ///   • the workspace `<root>/.kist/hooks.json` loads ONLY when `allowProjectHooks == true` (opt-in;
    ///     the caller sets it only for a workspace the user has explicitly trusted).
    /// Returns the merged hooks plus `projectHooksRefused` — true when a workspace hooks file EXISTS
    /// but was refused, so the caller surfaces a VISIBLE note instead of silently dropping it (silent
    /// drop is a foot-gun; silent load is the RCE — a visible refusal is the correct middle).
    public static func loadTrusted(projectRoot: String, runner: HookRunner = ProcessHookRunner(),
                                   allowProjectHooks: Bool = false) -> (hooks: AgentHooks?, projectHooksRefused: Bool) {
        func norm(_ p: String) -> String { (p as NSString).standardizingPath }   // resolve ~, .., //
        let userPaths = userHookPaths()
        let userNorms = Set(userPaths.map(norm))

        let projectPath = projectHookPath(projectRoot: projectRoot)
        // If the workspace hooks path IS actually a user hook file (e.g. projectRoot == $HOME), it's
        // already covered as USER config — never treat it as an untrusted workspace file (no double
        // load when trusted, no false refusal when not).
        let projectIsUserFile = userNorms.contains(norm(projectPath))
        let projectExists = !projectRoot.isEmpty && !projectIsUserFile
            && FileManager.default.fileExists(atPath: projectPath)

        var paths = userPaths
        if allowProjectHooks, projectExists { paths.append(projectPath) }   // trusted → append last

        var specs: [HookSpec] = []
        var seen = Set<String>()
        for path in paths where seen.insert(norm(path)).inserted {          // load each distinct file once
            guard let data = FileManager.default.contents(atPath: path), let parsed = parse(data) else { continue }
            specs.append(contentsOf: parsed)
        }
        let hooks = specs.isEmpty ? nil : AgentHooks(specs: specs, runner: runner, projectRoot: projectRoot)
        return (hooks, projectExists && !allowProjectHooks)
    }

    /// Parse either supported shape into a flat `[HookSpec]`. Internal for tests.
    static func parse(_ data: Data) -> [HookSpec]? {
        let obj = try? JSONSerialization.jsonObject(with: data)
        // Flat array shape.
        if let arr = obj as? [[String: Any]] {
            return arr.compactMap { specFromDict($0, event: ($0["event"] as? String).flatMap(HookEvent.init)) }
        }
        // Grouped object shape: key -> [ {matcher, command} ].
        if let dict = obj as? [String: Any] {
            let keyMap: [String: HookEvent] = [
                "preToolUse": .preToolUse, "PreToolUse": .preToolUse,
                "postToolUse": .postToolUse, "PostToolUse": .postToolUse,
                "stop": .stop, "Stop": .stop,
                "sessionStart": .sessionStart, "SessionStart": .sessionStart,
                "userPromptSubmit": .userPromptSubmit, "UserPromptSubmit": .userPromptSubmit,
                "subagentStop": .subagentStop, "SubagentStop": .subagentStop,
                "preCompact": .preCompact, "PreCompact": .preCompact,
            ]
            var out: [HookSpec] = []
            for (key, event) in keyMap {
                guard let list = dict[key] as? [[String: Any]] else { continue }
                out.append(contentsOf: list.compactMap { specFromDict($0, event: event) })
            }
            return out
        }
        return nil
    }

    private static func specFromDict(_ d: [String: Any], event: HookEvent?) -> HookSpec? {
        guard let event, let command = d["command"] as? String, !command.isEmpty else { return nil }
        return HookSpec(event: event, matcher: d["matcher"] as? String, command: command)
    }

    public var isEmpty: Bool { specs.isEmpty }

    // MARK: - Firing

    /// Fire PreToolUse hooks for `tool`. The FIRST hook that blocks wins (fail-closed): a non-zero
    /// exit blocks, or stdout JSON `{"block":true,"reason":"…"}`. Returns `.allow` if none block.
    public func firePreToolUse(tool: String, arguments: [String: Any]) async -> HookDecision {
        for spec in specs where spec.event == .preToolUse && spec.matches(tool: tool) {
            let payload = Self.payloadJSON(event: .preToolUse, tool: tool, arguments: arguments,
                                           projectRoot: projectRoot, result: nil, summary: nil)
            let (code, output) = await runner.run(command: spec.command, payloadJSON: payload)
            if let decision = Self.decision(fromOutput: output), decision.blocked { return decision }
            if code != 0 {
                let reason = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return HookDecision(blocked: true, reason: reason.isEmpty ? "hook exited \(code)" : reason)
            }
        }
        return .allow
    }

    /// Fire PostToolUse hooks (observe only — the side effect already happened).
    public func firePostToolUse(tool: String, arguments: [String: Any], success: Bool, output: String) async {
        for spec in specs where spec.event == .postToolUse && spec.matches(tool: tool) {
            let payload = Self.payloadJSON(event: .postToolUse, tool: tool, arguments: arguments,
                                           projectRoot: projectRoot,
                                           result: ["success": success, "output": String(output.prefix(4000))], summary: nil)
            _ = await runner.run(command: spec.command, payloadJSON: payload)
        }
    }

    /// Fire Stop hooks when the run finishes.
    public func fireStop(summary: String, success: Bool) async {
        for spec in specs where spec.event == .stop {
            let payload = Self.payloadJSON(event: .stop, tool: nil, arguments: nil,
                                           projectRoot: projectRoot,
                                           result: ["success": success], summary: summary)
            _ = await runner.run(command: spec.command, payloadJSON: payload)
        }
    }

    /// Fire an observe-only lifecycle event (SessionStart / UserPromptSubmit / SubagentStop / PreCompact).
    /// Non-blocking: the hook's exit code and output are ignored (these events can't veto). `detail` is
    /// passed as the summary so a hook can log/notify with context (the prompt text, the sub-agent id…).
    public func fireNotification(_ event: HookEvent, detail: String) async {
        for spec in specs where spec.event == event {
            let payload = Self.payloadJSON(event: event, tool: nil, arguments: nil,
                                           projectRoot: projectRoot, result: nil, summary: detail)
            _ = await runner.run(command: spec.command, payloadJSON: payload)
        }
    }

    // MARK: - Payload / decision helpers

    static func payloadJSON(event: HookEvent, tool: String?, arguments: [String: Any]?,
                            projectRoot: String, result: [String: Any]?, summary: String?) -> String {
        var dict: [String: Any] = ["event": event.rawValue, "projectRoot": projectRoot]
        if let tool { dict["tool"] = tool }
        if let arguments { dict["arguments"] = arguments }
        if let result { dict["result"] = result }
        if let summary { dict["summary"] = summary }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Parse an optional `{"block":bool,"reason":string}` decision from hook stdout (nil if absent).
    /// Balance-aware extraction (via ActionParser) so a hook can print logs around the JSON.
    ///
    /// Fail-SAFE across multiple objects: a hook that prints logs (`debug {...}`) before its decision,
    /// or emits several objects, must not let the FIRST object hide a block. We scan every candidate and
    /// any `block:true` wins immediately; otherwise the last decision object (if any) is returned.
    static func decision(fromOutput output: String) -> HookDecision? {
        var lastDecision: HookDecision? = nil
        for candidate in ActionParser.candidateJSONObjects(output) {
            guard let data = candidate.json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let block = obj["block"] as? Bool else { continue }
            let decision = HookDecision(blocked: block, reason: obj["reason"] as? String)
            if block { return decision }           // fail-safe: honor any block immediately
            lastDecision = decision
        }
        return lastDecision
    }
}
