import Foundation

/// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0). Exposes
/// FloatingChatApp's providers so an MCP client (e.g. Claude Code) can list
/// models and ask them — brainstorm/build with MiMo/GLM/Kimi/etc. using the
/// keys stored in the app.
///
/// IMPORTANT: only JSON-RPC goes to stdout. All logs go to stderr (stdout is
/// the protocol channel).
struct MCPServer {
    static let protocolVersion = "2024-11-05"
    static let version = "0.1.0"

    static func log(_ message: String) {
        FileHandle.standardError.write(("fca-mcp: " + message + "\n").data(using: .utf8)!)
    }

    func run() {
        Self.log("started; \(Providers.all.count) providers")
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) else {
                // -32700 Parse error (id unknown -> null) so a strict client
                // doesn't hang waiting for a reply.
                writeError(id: NSNull(), code: -32700, message: "Parse error")
                continue
            }
            if let batch = obj as? [Any] {
                // MCP doesn't use JSON-RPC batching, but respond spec-shaped: a
                // JSON ARRAY of -32600 errors (one per element that has a real
                // id). Empty array -> single -32600 (id null). All-notifications
                // -> no response.
                handleUnsupportedBatch(batch)
                continue
            }
            guard let msg = obj as? [String: Any] else {
                writeError(id: NSNull(), code: -32600, message: "Invalid Request")
                continue
            }
            handle(msg)
        }
    }

    private func handle(_ msg: [String: Any]) {
        let id = msg["id"]   // absent / null => notification (no reply)
        guard (msg["jsonrpc"] as? String) == "2.0", let method = msg["method"] as? String else {
            if let rid = responseId(id) {
                writeError(id: rid, code: -32600, message: "Invalid Request")
            }
            return
        }

        switch method {
        case "initialize":
            reply(id: id, result: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "fca-mcp", "version": Self.version]
            ])
        case "notifications/initialized", "notifications/cancelled":
            break   // notifications: no response
        case "ping":
            reply(id: id, result: [:])
        case "tools/list":
            reply(id: id, result: ["tools": Self.toolSpecs])
        case "tools/call":
            handleToolCall(id: id, params: msg["params"] as? [String: Any] ?? [:])
        default:
            if id != nil {
                replyError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    // MARK: - Tools

    static let toolSpecs: [[String: Any]] = [
        [
            "name": "list_models",
            "description": "List FloatingChatApp's AI providers, their default models, and which have an API key configured.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "run_agent",
            "description": "Delegate a whole coding task to an autonomous agent (plan→read→edit→run→repeat) confined to project_path, driven by one of FCA's models. Use for 'read this code, find vulnerabilities, fix and verify' style jobs. Returns a transcript of steps + final summary.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "task": ["type": "string", "description": "What the agent should accomplish"],
                    "project_path": ["type": "string", "description": "Absolute path of the project the agent is confined to"],
                    "provider": ["type": "string", "description": "Provider id (default: mimo)"],
                    "model": ["type": "string", "description": "Optional model id"],
                    "max_iterations": ["type": "integer", "description": "Max agent steps (default 12, clamped 1–30)"],
                    "allow_shell": ["type": "boolean", "description": "Allow the agent to run shell commands (build/test). Default false; file edits are confined to project_path regardless."]
                ],
                "required": ["task", "project_path"]
            ]
        ],
        [
            "name": "ask",
            "description": "Ask one of FloatingChatApp's models a question (brainstorm, review, or help build). Uses the key stored in the app.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "provider": ["type": "string", "description": "Provider id: mimo, zhipu, moonshot, deepseek, openai, grok, anthropic, gemini"],
                    "prompt": ["type": "string", "description": "The message to send"],
                    "model": ["type": "string", "description": "Optional model id; defaults to the provider's default"],
                    "system": ["type": "string", "description": "Optional system prompt"],
                    "max_tokens": ["type": "integer", "description": "Optional max tokens (default 2048; raise for reasoning models)"]
                ],
                "required": ["provider", "prompt"]
            ]
        ]
    ]

    private func handleToolCall(id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case "run_agent":
            guard let task = args["task"] as? String,
                  let projectPath = args["project_path"] as? String,
                  !projectPath.trimmingCharacters(in: .whitespaces).isEmpty else {
                reply(id: id, result: toolText("Error: 'task' and a non-empty 'project_path' are required", isError: true)); return
            }
            let maxIter = min(max((args["max_iterations"] as? Int) ?? 12, 1), 30)
            var agent = Agent(
                providerId: (args["provider"] as? String) ?? "mimo",
                model: args["model"] as? String,
                tools: AgentTools(root: projectPath),
                maxIterations: maxIter
            )
            agent.allowShell = (args["allow_shell"] as? Bool) ?? false
            let result = agent.run(task: task)
            // Structured done flag (not transcript text) so the task string can't
            // spoof success.
            reply(id: id, result: toolText(result.text, isError: !result.done))
        case "list_models":
            reply(id: id, result: toolText(listModels()))
        case "ask":
            guard let provider = args["provider"] as? String, let prompt = args["prompt"] as? String else {
                reply(id: id, result: toolText("Error: 'provider' and 'prompt' are required", isError: true)); return
            }
            do {
                let answer = try Providers.chat(
                    providerId: provider,
                    model: args["model"] as? String,
                    system: args["system"] as? String,
                    prompt: prompt,
                    maxTokens: (args["max_tokens"] as? Int) ?? 2048
                )
                reply(id: id, result: toolText(answer))
            } catch {
                reply(id: id, result: toolText("Error: \(error)", isError: true))
            }
        default:
            reply(id: id, result: toolText("Unknown tool: \(name)", isError: true))
        }
    }

    private func listModels() -> String {
        Providers.all.map { p in
            let hasKey = Keychain.get(p.keychainAccount) != nil
            return "\(hasKey ? "✅" : "⬜️") \(p.id) — \(p.name) (default: \(p.defaultModel))"
        }.joined(separator: "\n")
    }

    // MARK: - JSON-RPC plumbing

    private func toolText(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    /// A usable response id, or nil when the message is a notification (no id)
    /// OR has an explicit JSON `null` id — neither gets a reply.
    private func responseId(_ id: Any?) -> Any? {
        guard let id = id, !(id is NSNull) else { return nil }
        return id
    }

    private func reply(id: Any?, result: [String: Any]) {
        guard let rid = responseId(id) else { return }
        write(["jsonrpc": "2.0", "id": rid, "result": result])
    }

    private func replyError(id: Any?, code: Int, message: String) {
        guard let rid = responseId(id) else { return }
        write(["jsonrpc": "2.0", "id": rid, "error": ["code": code, "message": message]])
    }

    /// Always writes an error (id may be NSNull) — for parse/invalid-request
    /// failures where the spec requires a response even with a null id.
    private func writeError(id: Any, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// Respond to a JSON-RPC batch (unsupported by MCP) with a spec-shaped array.
    private func handleUnsupportedBatch(_ batch: [Any]) {
        if batch.isEmpty {
            writeError(id: NSNull(), code: -32600, message: "Invalid Request")
            return
        }
        let responses: [[String: Any]] = batch.compactMap { element in
            guard let rid = responseId((element as? [String: Any])?["id"]) else { return nil }
            return ["jsonrpc": "2.0", "id": rid, "error": ["code": -32600, "message": "Batch requests are not supported"]]
        }
        guard !responses.isEmpty else { return }   // all notifications -> no reply
        if let data = try? JSONSerialization.data(withJSONObject: responses),
           let line = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
        }
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
    }
}
