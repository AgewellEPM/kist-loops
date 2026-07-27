import Foundation

/// A headless autonomous coding agent: plan → act (tool) → observe → repeat,
/// driven by one of FCA's models. Confined to a project root via AgentTools.
/// This is what `run_agent` exposes over MCP, so Claude Code can delegate a
/// whole task (e.g. "find vulnerabilities and fix them") and get a transcript.
struct Agent {
    let providerId: String
    let model: String?
    let tools: AgentTools
    let maxIterations: Int
    /// Shell (`run_command`) is OFF by default — the agent is read/write-confined
    /// unless the caller explicitly enables shell (needed for build/test).
    var allowShell: Bool = false

    static let knownTools: Set<String> = ["read_file", "write_file", "edit_file", "list_files", "grep", "run_command", "done"]
    private static let transcriptCap = 16_000

    static let systemPrompt = """
    You are an autonomous coding agent working INSIDE a single project directory.
    Work step by step. On EACH turn reply with EXACTLY ONE JSON object — no prose,
    no markdown fences:
    {"thought":"brief reasoning","action":{"tool":"<name>","args":{...}}}

    Tools:
    - read_file    {"path":"..."}
    - write_file   {"path":"...","content":"..."}
    - edit_file    {"path":"...","old_text":"...","new_text":"..."}
    - list_files   {"dir":"."}
    - grep         {"pattern":"...","dir":"."}
    - run_command  {"command":"..."}    (shell; runs in the project root)
    - done         {"summary":"..."}    (when the task is complete)

    Rules: read files before editing; make minimal, correct changes; after edits
    that affect code, verify with run_command (build/test) when relevant; finish
    with `done` and a clear summary of what you found/changed.
    """

    struct Action { let tool: String; let args: [String: Any] }

    struct Result { let text: String; let done: Bool }

    func run(task: String) -> Result {
        var transcript = "TASK: \(task)\n"
        var log: [String] = []
        var replans = 0

        for i in 1...maxIterations {
            let reply: String
            do {
                reply = try Providers.chat(
                    providerId: providerId, model: model,
                    system: Self.systemPrompt,
                    prompt: transcript + "\nReply with the next action as a single JSON object.",
                    maxTokens: 2048
                )
            } catch {
                return finalize(log, status: "LLM error: \(error)", done: false)
            }

            guard let action = Self.parseAction(reply), Self.knownTools.contains(action.tool) else {
                replans += 1
                if replans > 3 { return finalize(log, status: "stopped: model kept producing invalid/unknown actions", done: false) }
                let why = Self.parseAction(reply) == nil ? "not a single valid JSON action" : "unknown tool"
                transcript += "\n[your last reply was \(why) — reply with one valid action JSON]"
                log.append("iter \(i): invalid/unknown action (retry \(replans))")
                continue
            }

            if action.tool == "done" {
                let summary = (action.args["summary"] as? String) ?? "(no summary)"
                log.append("iter \(i): done")
                return finalize(log, status: "DONE: \(summary)", done: true)
            }

            let result = execute(action)
            let argsDesc = Self.compactJSON(action.args)
            log.append("iter \(i): \(action.tool) \(argsDesc.prefix(80)) -> \(result.prefix(120).replacingOccurrences(of: "\n", with: " "))")
            transcript += "\nACTION: \(action.tool) \(argsDesc)\nRESULT:\n\(result.prefix(4000))\n"

            // Cap transcript growth (token/cost blowup): keep the TASK line + tail.
            if transcript.count > Self.transcriptCap {
                let head = transcript.prefix(while: { $0 != "\n" })
                transcript = head + "\n…(earlier steps truncated)…\n" + String(transcript.suffix(Self.transcriptCap - 2000))
            }
        }
        return finalize(log, status: "stopped: max iterations (\(maxIterations)) reached", done: false)
    }

    // MARK: - Execution

    private func execute(_ action: Action) -> String {
        do {
            switch action.tool {
            case "read_file":    return try tools.readFile(Self.str(action.args, "path"))
            case "write_file":   return try tools.writeFile(Self.str(action.args, "path"), content: Self.str(action.args, "content"))
            case "edit_file":    return try tools.editFile(Self.str(action.args, "path"), oldText: Self.str(action.args, "old_text"), newText: Self.str(action.args, "new_text"))
            case "list_files":   return try tools.listFiles(Self.str(action.args, "dir"))
            case "grep":         return try tools.grep(Self.str(action.args, "pattern"), dir: action.args["dir"] as? String)
            case "run_command":
                guard allowShell else { return "run_command is disabled for this run (the caller did not pass allow_shell:true)" }
                return try tools.runCommand(Self.str(action.args, "command"))
            default:             return "ERROR: unknown tool '\(action.tool)'"
            }
        } catch {
            return "ERROR: \(error)"
        }
    }

    private func finalize(_ log: [String], status: String, done: Bool) -> Result {
        Result(
            text: "Agent run (\(providerId)/\(model ?? "default")) — \(status)\n\nSteps:\n" + log.joined(separator: "\n"),
            done: done
        )
    }

    // MARK: - Helpers

    static func str(_ args: [String: Any], _ key: String) -> String { args[key] as? String ?? "" }

    static func compactJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Parse the model's reply into an Action: extract the JSON object, read
    /// `action.tool` + `action.args` (tolerant of markdown fences / extra prose).
    static func parseAction(_ reply: String) -> Action? {
        var s = reply.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") else { return nil }
        s = String(s[start...end])
        guard let data = s.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Accept {"action":{"tool","args"}} or a bare {"tool","args"}.
        let actionObj = (json["action"] as? [String: Any]) ?? json
        guard let tool = actionObj["tool"] as? String else { return nil }
        let args = (actionObj["args"] as? [String: Any]) ?? [:]
        return Action(tool: tool, args: args)
    }
}
