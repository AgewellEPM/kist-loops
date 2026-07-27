import Foundation

/// Project-local tool forge. Lets an agent create small Python helpers when the fixed toolset is not
/// enough, then run them through Kist's required OS sandbox boundary. This is the autonomy valve:
/// the agent can make tools, but it cannot make a new trust boundary.
public struct CustomTool: AgentTool {
    public static let maxCodeBytes = 128 * 1024

    public let name = "custom_tool"
    public let description = """
    Create, list, and run project-local Python tools under .kist/generated-tools. Use this when the \
    current task needs a one-off parser, converter, analyzer, data cleaner, or validator that does not \
    exist as a built-in tool. Created tools are scripts, not new privileges: run executes via python3 \
    through required OS sandboxing, resource limits, scrubbed env, and the replay ledger. If the OS \
    sandbox is unavailable, custom_tool.run fails closed instead of running unsandboxed.
    """
    public let parameters = [
        ToolParameter(name: "action", type: "string", description: "create | list | run", required: true),
        ToolParameter(name: "name", type: "string", description: "Tool name: letters, numbers, underscore, dash (required for create/run)", required: false),
        ToolParameter(name: "description", type: "string", description: "Short purpose for create", required: false),
        ToolParameter(name: "code", type: "string", description: "Full Python source for create", required: false),
        ToolParameter(name: "args", type: "array", description: "String arguments passed to the generated tool on run", required: false),
        ToolParameter(name: "timeout", type: "integer", description: "Run timeout seconds (default 60, max 300)", required: false),
        ToolParameter(name: "memory_limit_mb", type: "integer", description: "Optional virtual memory limit for the Python child", required: false),
    ]

    public var supportedActions: [String] { ["create", "list", "run"] }
    public var unsupportedActions: [String] {
        ["run_unsandboxed", "install_global", "pip_install_global", "escape_project", "network_probe"]
    }
    public var capabilityNote: String? {
        "Generated tools are project-local Python scripts. Run requires an OS sandbox and fails closed if sandboxing is unavailable."
    }
    public var usageExamples: [String] {
        [
            "custom_tool(action=\"create\", name=\"csv_stats\", code=\"import csv,sys\\nprint('ok')\")",
            "custom_tool(action=\"run\", name=\"csv_stats\", args=[\"data.csv\"])",
        ]
    }

    public init() {}

    private struct Manifest: Codable {
        let name: String
        let description: String
        let script: String
        let codeSHA256: String?
        let codeBytes: Int?
        let createdAt: Double
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let action = try requireString("action", from: arguments).lowercased()
        switch action {
        case "create":
            return try create(arguments: arguments, context: context)
        case "list":
            return list(context: context)
        case "run":
            return try await run(arguments: arguments, context: context)
        default:
            return .failure("unknown custom_tool action '\(action)'; use create, list, or run")
        }
    }

    private func create(arguments: [String: Any], context: ToolContext) throws -> ToolResult {
        let toolName = try validateName(requireString("name", from: arguments))
        let code = try requireString("code", from: arguments)
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("code cannot be empty")
        }
        let source = code.hasSuffix("\n") ? code : code + "\n"
        let sourceData = Data(source.utf8)
        guard sourceData.count <= Self.maxCodeBytes else {
            return .failure("custom tool source is \(sourceData.count) bytes; max is \(Self.maxCodeBytes)")
        }
        let sourceSHA256 = Self.hex(MythosCrypto.sha256(sourceData))
        let description = ((arguments["description"] as? String) ?? "agent-created Python helper")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = baseDir + "/\(toolName)"
        let script = dir + "/tool.py"
        let manifest = dir + "/manifest.json"
        let confined = try context.confinedRoot()
        try confined.makeDirectory(dir)
        try confined.writeString(script, source, createParents: true)
        let m = Manifest(name: toolName, description: description.isEmpty ? "agent-created Python helper" : description,
                         script: script, codeSHA256: sourceSHA256, codeBytes: sourceData.count,
                         createdAt: Date().timeIntervalSince1970)
        let data = try JSONEncoder().encode(m)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try confined.writeString(manifest, json + "\n", createParents: true)
        return ToolResult(success: true,
                          output: "Created custom tool \(toolName) at \(script) (sha256 \(sourceSHA256), \(sourceData.count) bytes). Run with custom_tool(action=\"run\", name=\"\(toolName)\").",
                          metadata: ["name": toolName, "script": script,
                                     "code_sha256": sourceSHA256,
                                     "code_bytes": String(sourceData.count)])
    }

    private func list(context: ToolContext) -> ToolResult {
        do {
            let confined = try context.confinedRoot()
            let entries = (try? confined.entries(baseDir)) ?? []
            let dirs = entries.filter(\.isDir).map(\.name).sorted()
            guard !dirs.isEmpty else { return ToolResult(success: true, output: "No custom tools yet.") }
            let lines = dirs.map { name -> String in
                let manifestPath = "\(baseDir)/\(name)/manifest.json"
                if let text = try? confined.readString(manifestPath),
                   let data = text.data(using: .utf8),
                   let m = try? JSONDecoder().decode(Manifest.self, from: data) {
                    let hash = m.codeSHA256.map { ", sha256 \($0)" } ?? ""
                    return "- \(m.name): \(m.description) (\(m.script)\(hash))"
                }
                return "- \(name): missing manifest"
            }
            return ToolResult(success: true, output: lines.joined(separator: "\n"))
        } catch {
            return .failure("\(error)")
        }
    }

    private func run(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let toolName = try validateName(requireString("name", from: arguments))
        let scriptRel = "\(baseDir)/\(toolName)/tool.py"
        let script = try context.resolvedPath(scriptRel, mustExist: true)
        guard let python = RunCommandTool.resolveExecutable("python3", env: RunCommandTool.scrubbedEnvironment())
                ?? RunCommandTool.resolveExecutable("python", env: RunCommandTool.scrubbedEnvironment()) else {
            return .failure("python3 not found on PATH")
        }
        let userArgs = stringArgs(arguments["args"])
        let timeout = min(max(optionalInt("timeout", from: arguments) ?? 60, 1), 300)
        let argv = [script] + userArgs
        let limited = RunCommandTool.resourceLimitedLaunch(
            launchPath: python,
            launchArgs: argv,
            limits: RunCommandTool.ResourceLimits(
                cpuSeconds: timeout,
                fileSizeMB: 256,
                memoryMB: optionalInt("memory_limit_mb", from: arguments).map { min(max($0, 16), 8192) }
            )
        )
        let outcome = SandboxedProcessRunner.runRequired(launchPath: limited.launchPath,
                                                         launchArgs: limited.launchArgs,
                                                         root: context.projectRoot,
                                                         cwd: context.projectRoot,
                                                         env: RunCommandTool.scrubbedEnvironment(),
                                                         timeoutSeconds: timeout,
                                                         capPerStream: RunCommandTool.maxOutputBytes)
        let success = outcome.sandboxed && !outcome.timedOut && outcome.exitCode == 0
        let output = outcome.combined.isEmpty
            ? (success ? "(no output)" : "(no output, exit \(outcome.exitCode))")
            : outcome.combined
        let error: String?
        if success {
            error = nil
        } else if !outcome.sandboxed {
            error = outcome.combined.isEmpty ? "OS sandbox required but unavailable" : outcome.combined
        } else if outcome.timedOut {
            error = "command timed out after \(timeout)s"
        } else if outcome.combined.isEmpty {
            error = "exit code \(outcome.exitCode) with NO output captured"
        } else {
            error = "exit code \(outcome.exitCode)"
        }
        var meta = [
            "exit_code": String(outcome.exitCode),
            "timed_out": String(outcome.timedOut),
            "sandboxed": String(outcome.sandboxed),
            "sandbox": outcome.sandbox
        ]
        meta["name"] = toolName
        meta["script"] = scriptRel
        return ToolResult(success: success,
                          output: output,
                          error: error,
                          metadata: meta)
    }

    private let baseDir = ".kist/generated-tools"

    private func validateName(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...48).contains(value.count) else {
            throw ToolError.execution("custom tool name must be 1-48 characters")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ToolError.execution("custom tool name may contain only letters, numbers, underscore, and dash")
        }
        return value
    }

    private func stringArgs(_ raw: Any?) -> [String] {
        (raw as? [Any])?.map { "\($0)" } ?? (raw as? [String] ?? [])
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
