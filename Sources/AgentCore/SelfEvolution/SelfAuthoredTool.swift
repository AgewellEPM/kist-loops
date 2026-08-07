import Foundation

/// A capability kist authored for itself, made callable at runtime WITHOUT a recompile (Phase 0 fork).
/// It is a script + a manifest; `ScriptTool` runs it. The manifest is the ONLY interface — kist never
/// executes self-authored code except through `ScriptTool.execute`, which sandboxes it unconditionally.
public struct SelfAuthoredManifest: Codable, Sendable, Equatable {
    public let name: String            // MUST be in the self__ namespace
    public let description: String
    public let interpreter: String     // absolute path: /bin/bash, /usr/bin/python3, …
    public let scriptFile: String       // filename of the script, relative to the tool's home dir
    public let parameters: [Param]
    public let contract: String         // NL behavior contract (fed to the symbolic veto)
    /// The author's own acceptance check: run the script with these args and require this substring in stdout.
    public let testArgs: [String: String]
    public let testExpectSubstring: String

    public struct Param: Codable, Sendable, Equatable {
        public let name: String
        public let description: String
        public let required: Bool
        public init(name: String, description: String, required: Bool = true) {
            self.name = name; self.description = description; self.required = required
        }
    }
    public init(name: String, description: String, interpreter: String, scriptFile: String,
                parameters: [Param], contract: String, testArgs: [String: String], testExpectSubstring: String) {
        self.name = name; self.description = description; self.interpreter = interpreter
        self.scriptFile = scriptFile; self.parameters = parameters; self.contract = contract
        self.testArgs = testArgs; self.testExpectSubstring = testExpectSubstring
    }
}

/// Runs a self-authored script as a tool — with MANDATORY containment. A `self__` script is NOT a
/// user-directed command, so it never inherits the session's `--allow-shell` permissiveness: EVERY run is
/// wrapped in the confined Seatbelt/bubblewrap sandbox (network denied, writes confined to a fresh scratch
/// dir — NEVER projectRoot — secret reads denied, time/output capped). If the sandbox is unavailable it
/// REFUSES to run (fail-closed). The gates prove a tool WORKS; this is what keeps a working-but-harmful
/// script from doing damage — the adversary hunts contract violations, not malice, so containment is the
/// only safety layer and it cannot be optional.
public struct ScriptTool: AgentTool {
    public let manifest: SelfAuthoredManifest
    public let homeDir: String           // where the script lives
    public let timeoutSeconds: Int
    public let maxOutputBytes: Int

    public init(manifest: SelfAuthoredManifest, homeDir: String,
                timeoutSeconds: Int = 20, maxOutputBytes: Int = 256 * 1024) {
        self.manifest = manifest; self.homeDir = homeDir
        self.timeoutSeconds = timeoutSeconds; self.maxOutputBytes = maxOutputBytes
    }

    public var name: String { manifest.name }
    public var description: String { manifest.description }
    public var parameters: [ToolParameter] {
        manifest.parameters.map { ToolParameter(name: $0.name, type: "string", description: $0.description, required: $0.required) }
    }

    /// Serialize tool args to CLI args as `--name value` pairs, in the manifest's declared order (stable,
    /// so the script can parse positionally or by flag). Only declared params are passed.
    static func cliArgs(from arguments: [String: Any], manifest: SelfAuthoredManifest) -> [String] {
        var out: [String] = []
        for p in manifest.parameters {
            guard let v = arguments[p.name] else { continue }
            out.append("--\(p.name)")
            out.append(String(describing: v))
        }
        return out
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let scriptPath = (homeDir as NSString).appendingPathComponent(manifest.scriptFile)
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            return ToolResult(success: false, output: "", error: "self__ script missing at \(scriptPath)")
        }
        let cli = Self.cliArgs(from: arguments, manifest: manifest)
        return await Self.runContained(interpreter: manifest.interpreter, scriptPath: scriptPath, args: cli,
                                        timeoutSeconds: timeoutSeconds, maxOutputBytes: maxOutputBytes)
    }

    /// The one execution path — used by both `execute` and the gate's acceptance test, so what the gate
    /// verifies is EXACTLY what will later run. Always sandboxed; refuses if the sandbox is unavailable.
    public static func runContained(interpreter: String, scriptPath: String, args: [String],
                                    timeoutSeconds: Int = 20, maxOutputBytes: Int = 256 * 1024) async -> ToolResult {
        // Fresh scratch dir per run — the sandbox write-confinement root. NEVER projectRoot.
        let scratch = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("kist-self-run-\(scriptPath.hashValue &* 2654435761)")
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        // MANDATORY confinement — enabled unconditionally; a self__ run is never passthrough.
        let policy = SandboxPolicy.confined(denyNetwork: true, confineWrites: true)
        let wrap = SeatbeltSandbox.wrap(launchPath: interpreter, args: [scriptPath] + args,
                                        root: scratch, policy: policy, cwd: scratch)
        let launchPath: String, launchArgs: [String]
        switch wrap {
        case .wrapped(let p, let a):
            launchPath = p; launchArgs = a
        case .unavailable(let reason):
            return ToolResult(success: false, output: "",
                              error: "self__ mandatory sandbox unavailable: \(reason) — refusing to run unsandboxed")
        case .passthrough:
            // Should be impossible (policy.enabled == true), but if the sandbox layer ever returns
            // passthrough for a self__ run we REFUSE rather than run uncontained.
            return ToolResult(success: false, output: "",
                              error: "self__ sandbox returned passthrough — refusing to run a self-authored script uncontained")
        }

        let outcome = await withCheckedContinuation { (cont: CheckedContinuation<ProcessGroupRunner.Outcome, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let o = ProcessGroupRunner.run(launchPath: launchPath, launchArgs: launchArgs, cwd: scratch,
                                               env: RunCommandTool.scrubbedEnvironment(),
                                               timeoutSeconds: timeoutSeconds, capPerStream: maxOutputBytes)
                cont.resume(returning: o)
            }
        }
        return ToolResult(success: !outcome.timedOut && outcome.exitCode == 0,
                          output: outcome.combined.isEmpty ? "(no output)" : outcome.combined,
                          error: outcome.exitCode == 0 ? nil : "exit \(outcome.exitCode)\(outcome.timedOut ? " (timed out)" : "")",
                          metadata: ["exit_code": String(outcome.exitCode), "sandboxed": "true"])
    }
}
