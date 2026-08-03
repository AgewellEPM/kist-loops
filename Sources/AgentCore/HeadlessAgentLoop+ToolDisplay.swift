import Foundation

// Human-facing tool argument/description rendering for approval prompts and the live status
// line, with secret redaction. Extracted verbatim from HeadlessAgentLoop.swift — behavior unchanged.
extension HeadlessAgentLoop {
    /// A short, single-line render of tool arguments for an approval prompt.
    static func compactArgs(_ params: [String: Any]) -> String {
        params.keys.sorted().map { k in
            "\(k): \(displayValue(params[k]!, key: k, limit: 60))"
        }.joined(separator: ", ")
    }

    /// What the terminal shows while a tool is running. It is deliberately concrete (path/query/command),
    /// but single-line and secret-redacted so the live lane stays readable.
    static func toolDisplayDescription(tool: String, args: [String: Any], thinking: String? = nil) -> String {
        let detail: String
        switch tool {
        case "run_command":
            if let command = stringArg(args, "command", "cmd") {
                detail = "shell: \(displayValue(command, key: "command", limit: 140))"
            } else if let executable = stringArg(args, "executable") {
                let argv = stringArrayArg(args, "args").joined(separator: " ")
                let cwd = stringArg(args, "cwd").map { "  cwd: \($0)" } ?? ""
                detail = (argv.isEmpty ? executable : executable + " " + argv) + cwd
            } else {
                detail = compactArgs(args)
            }
        case "custom_tool":
            detail = customToolDisplayDescription(args)
        case "read_file", "view_image", "analyze_media", "read_spreadsheet":
            detail = fileDisplayDescription(args, defaultPath: nil)
        case "write_file", "edit_file", "apply_patch":
            detail = stringArg(args, "path", "file", "target").map { "path=\($0)" } ?? compactArgs(args)
        case "move_file":
            let from = stringArg(args, "from", "source", "src") ?? "?"
            let to = stringArg(args, "to", "destination", "dst") ?? "?"
            detail = "\(from) -> \(to)"
        case "list_files", "glob_files":
            detail = directoryDisplayDescription(tool: tool, args: args)
        case "search_code", "grep", "ast_grep":
            let query = stringArg(args, "pattern", "query", "rule") ?? "?"
            let path = stringArg(args, "path", "directory", "root").map { " in \($0)" } ?? ""
            detail = "\(query)\(path)"
        case "web_search":
            detail = stringArg(args, "query", "goal", "task") ?? compactArgs(args)
        case "research_run":
            detail = researchRunDisplayDescription(args)
        case "fetch_url", "web_fetch", "browse":
            detail = stringArg(args, "url", "target") ?? compactArgs(args)
        case "ask_user":
            detail = stringArg(args, "question", "prompt") ?? compactArgs(args)
        case "spawn_agent", "spawn_specialist":
            detail = stringArg(args, "task", "goal", "role") ?? compactArgs(args)
        default:
            detail = compactArgs(args)
        }

        let cleanDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanThinking = (thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanThinking.isEmpty || cleanThinking == tool { return cleanDetail.isEmpty ? tool : cleanDetail }
        if cleanDetail.isEmpty { return cleanThinking }
        // Put the concrete target first. The terminal status line is intentionally truncated; if
        // model "thinking" comes first, the user loses the command/path and sees only narration.
        return "\(cleanDetail) · \(cleanThinking)"
    }

    private static func stringArg(_ args: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let s = args[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return displayValue(s, key: key, limit: 160)
            }
        }
        return nil
    }

    private static func fileDisplayDescription(_ args: [String: Any], defaultPath: String?) -> String {
        guard let path = stringArg(args, "path", "file", "target") ?? defaultPath else {
            return compactArgs(args)
        }
        var pieces = ["path=\(path)"]
        if let start = args["start_line"] ?? args["startLine"] {
            pieces.append("start=\(displayValue(start, key: "start_line", limit: 20))")
        }
        if let end = args["end_line"] ?? args["endLine"] {
            pieces.append("end=\(displayValue(end, key: "end_line", limit: 20))")
        }
        return pieces.joined(separator: " ")
    }

    private static func directoryDisplayDescription(tool: String, args: [String: Any]) -> String {
        if tool == "glob_files" {
            var pieces: [String] = []
            if let pattern = stringArg(args, "pattern") { pieces.append("pattern=\(pattern)") }
            pieces.append("path=\(stringArg(args, "path", "directory", "root") ?? ".")")
            if let limit = args["limit"] { pieces.append("limit=\(displayValue(limit, key: "limit", limit: 20))") }
            return pieces.joined(separator: " ")
        }
        return "path=\(stringArg(args, "path", "directory", "root") ?? ".")"
    }

    private static func customToolDisplayDescription(_ args: [String: Any]) -> String {
        let action = stringArg(args, "action") ?? "?"
        var pieces = ["action=\(action)"]
        if let name = stringArg(args, "name") { pieces.append("name=\(name)") }
        if let timeout = args["timeout"] { pieces.append("timeout=\(displayValue(timeout, key: "timeout", limit: 20))s") }
        if action == "run", let runArgs = args["args"] {
            let rendered = displayValue(runArgs, key: "args", limit: 80)
            if !rendered.isEmpty { pieces.append("args=\(rendered)") }
        }
        if action == "create", args["code"] != nil {
            pieces.append("code=<hidden>")
        }
        return pieces.joined(separator: " ")
    }

    private static func researchRunDisplayDescription(_ args: [String: Any]) -> String {
        let action = stringArg(args, "action") ?? "?"
        var pieces = ["action=\(action)"]
        for key in ["run_id", "query", "url", "goal", "path", "title"] {
            if let value = stringArg(args, key) {
                pieces.append("\(key)=\(value)")
                break
            }
        }
        return pieces.joined(separator: " ")
    }

    private static func stringArrayArg(_ args: [String: Any], _ key: String) -> [String] {
        if let arr = args[key] as? [String] { return arr.map { displayValue($0, key: key, limit: 80) } }
        if let arr = args[key] as? [Any] { return arr.map { displayValue($0, key: key, limit: 80) } }
        return []
    }

    private static func displayValue(_ value: Any, key: String, limit: Int) -> String {
        if isSecretKey(key) { return "[redacted]" }
        let raw: String
        if let s = value as? String {
            raw = s
        } else if let arr = value as? [Any] {
            raw = arr.map { displayValue($0, key: key, limit: limit) }.joined(separator: " ")
        } else {
            raw = String(describing: value)
        }
        let redacted = SecretMasker.mask(SecretScanner.redactSecrets(in: raw))
        let oneLine = redacted.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count <= limit ? oneLine : String(oneLine.prefix(limit)) + "..."
    }

    private static func isSecretKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return k.contains("key") || k.contains("token") || k.contains("secret")
            || k.contains("password") || k.contains("authorization")
    }
}
