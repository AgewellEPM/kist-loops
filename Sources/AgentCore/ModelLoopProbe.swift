import Foundation

/// THE CANARY PROBE — the state-of-the-art way to know a model can actually run a tool-calling LOOP
/// before you trust it with real work. Per the research: there is no reliable auto-detector for chat
/// templates / tool conventions / stop tokens, so you PROBE — fire a trivial tool round-trip and verify
/// it (a) emits a parseable tool call in the convention this model's path expects, (b) stops cleanly,
/// (c) round-trips a tool result into a clean final answer. Works for ANY configured model (key or local),
/// driving it through the EXACT path the agent loop would (native function-calling or the text protocol).
///
/// SCOPE (deliberate): this is a smoke test of loop MECHANICS — can the model emit a tool call in its
/// path's convention and close the loop — using a minimal prompt to ISOLATE that signal. It does NOT
/// replay the full agent system prompt (tool contracts, skills, plan banner); a heavier prompt would
/// trade false-passes for false-fails driven by prompt size, not loop capability. It also probes ONLY
/// the requested provider (fallback disabled) so a passing verdict is never borrowed from another model.
public enum ModelLoopProbe {
    public enum Outcome: Sendable, Equatable {
        case ok(String)
        case degraded(String)
        case failed(String)
        case skipped(String)
        public var passed: Bool { if case .ok = self { return true }; return false }
        public var isSkipped: Bool { if case .skipped = self { return true }; return false }
        public var symbol: String {
            switch self { case .ok: return "✓"; case .degraded: return "⚠"; case .failed: return "✗"; case .skipped: return "·" }
        }
        public var detail: String {
            switch self { case .ok(let s), .degraded(let s), .failed(let s), .skipped(let s): return s }
        }
    }

    public enum Readiness: String, Sendable, Equatable { case ready, partial, broken }

    public struct Report: Sendable, Equatable {
        public var providerId: String
        public var model: String
        public var usesNative: Bool          // which path the loop will actually drive this model through
        public var path: Outcome             // the ACTIVE path's tool round-trip
        public var roundTrip: Outcome        // feeding a tool result back → clean final answer
        public var readiness: Readiness
    }

    /// AGGREGATION (pure, unit-pinned): the model's ACTIVE path must work to be `ready`. A degraded
    /// active path or a degraded round-trip is `partial`; a failed active path is `broken`.
    public static func readiness(path: Outcome, roundTrip: Outcome) -> Readiness {
        switch path {
        case .failed: return .broken
        case .ok where roundTrip.passed || roundTrip.isSkipped: return .ready
        case .ok, .degraded: return .partial
        case .skipped: return .broken   // we couldn't even run the active path
        }
    }

    public static func render(_ r: Report) -> String {
        let pathLabel = r.usesNative ? "native tool-calling" : "text protocol"
        var out = ["model loop probe · \(r.providerId)\(r.model.isEmpty ? "" : ":" + r.model) · \(r.readiness.rawValue.uppercased())", ""]
        out.append("\(r.path.symbol) \(pathLabel.padding(toLength: 20, withPad: " ", startingAt: 0)) \(r.path.detail)")
        out.append("\(r.roundTrip.symbol) \("tool round-trip".padding(toLength: 20, withPad: " ", startingAt: 0)) \(r.roundTrip.detail)")
        return out.joined(separator: "\n")
    }

    private static let echoTool = ToolSpec(
        name: "echo", description: "Echo the input text back verbatim.",
        parameters: [ToolParameter(name: "text", type: "string", description: "the text to echo back", required: true)])
    private static let echoText = "ping"

    /// Hard wall-clock ceiling for the whole probe — a hung/stalled provider must not block the CLI
    /// (or CI / onboarding) forever. Two round-trip turns over a slow link should finish well under this.
    public static let timeoutSeconds: Double = 45

    /// Live probe — drives the model through its real path, bounded by a timeout so an unresponsive
    /// provider fails the probe instead of hanging.
    public static func probe(registry: ProviderRegistry, providerId: String, model: String?,
                             timeout: Double = timeoutSeconds) async -> Report {
        let usesNative = registry.usesNativeTools(providerId: providerId, model: model, mode: .auto)
        let outcome: (Outcome, Outcome)
        do {
            outcome = try await withProbeTimeout(seconds: timeout) {
                if usesNative { return await probeNative(registry: registry, providerId: providerId, model: model) }
                return await probeText(registry: registry, providerId: providerId, model: model)
            }
        } catch {
            outcome = (.failed("probe timed out after \(Int(timeout))s (provider unresponsive)"), .skipped("timed out"))
        }
        return Report(providerId: providerId, model: model ?? "", usesNative: usesNative,
                      path: outcome.0, roundTrip: outcome.1, readiness: readiness(path: outcome.0, roundTrip: outcome.1))
    }

    private struct ProbeTimeout: Error {}

    /// Race the probe against a deadline; on timeout, cancel the in-flight network work and throw.
    private static func withProbeTimeout(seconds: Double,
                                         _ op: @escaping @Sendable () async -> (Outcome, Outcome)) async throws -> (Outcome, Outcome) {
        try await withThrowingTaskGroup(of: (Outcome, Outcome).self) { group in
            group.addTask { await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
                throw ProbeTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ProbeTimeout() }
            return first
        }
    }

    // MARK: native path — a real function-call round-trip

    private static func probeNative(registry: ProviderRegistry, providerId: String, model: String?) async -> (Outcome, Outcome) {
        let ask = [ChatMessage(role: .user, content: "Call the echo tool with text set to exactly: ping")]
        var call: (id: String, name: String, args: String)?
        var truncated = false
        do {
            let stream = try await registry.streamTools(providerId: providerId, model: model,
                                                        messages: ask, settings: ModelSettings(maxTokens: 256),
                                                        tools: [echoTool], allowFallback: false)
            for try await event in stream {
                switch event {
                case .toolCall(let id, let name, let args): if call == nil { call = (id, name, args) }
                case .finish(let r): if isTruncation(r) { truncated = true }
                default: break
                }
            }
        } catch {
            return (.failed("native tool call errored: \("\(error)".prefix(100))"), .skipped("path failed"))
        }
        guard let call, call.name == "echo" else {
            return (.failed("model did not emit an `echo` tool call (native function-calling not working on this path)"), .skipped("path failed"))
        }
        guard stringArgument(call.args, key: "text") == echoText else {
            return (.failed("model emitted `echo` but with wrong/missing text argument"), .skipped("path failed"))
        }
        if truncated { return (.degraded("emitted the tool call but the stream truncated (check max tokens / stop)"), .skipped("path degraded")) }

        // Round-trip: feed the tool result back through the same native path the loop uses on its next
        // iteration. A plain `complete` call would not encode assistant tool_calls + tool results and can
        // falsely pass providers whose native second turn rejects the active transcript shape.
        let assistant = ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRef(id: call.id, name: "echo", argumentsJSON: call.args)])
        let result = ChatMessage.toolResult(callId: call.id, content: echoText)
        var answer = ""
        var calledAgain = false
        var roundTripTruncated = false
        do {
            let stream = try await registry.streamTools(providerId: providerId, model: model,
                                                        messages: ask + [assistant, result],
                                                        settings: ModelSettings(maxTokens: 256),
                                                        tools: [echoTool], allowFallback: false)
            for try await event in stream {
                switch event {
                case .delta(let d): answer += d
                case .toolCall: calledAgain = true
                case .finish(let r): if isTruncation(r) { roundTripTruncated = true }
                default: break
                }
            }
            let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if calledAgain {
                return (.ok("emitted a clean `echo` tool call"), .degraded("tool result caused another native tool call instead of a final answer"))
            }
            if roundTripTruncated {
                return (.ok("emitted a clean `echo` tool call"), .degraded("tool result round-trip truncated"))
            }
            return (.ok("emitted a clean `echo` tool call"),
                    clean.contains(echoText) ? .ok("tool result -> clean final answer") : .degraded("tool result final answer did not mention the echo result"))
        } catch {
            return (.ok("emitted a clean `echo` tool call"), .failed("feeding a tool result back errored: \("\(error)".prefix(80))"))
        }
    }

    // MARK: text path — the JSON action protocol round-trip

    private static func probeText(registry: ProviderRegistry, providerId: String, model: String?) async -> (Outcome, Outcome) {
        let system = """
        You are a tool-using agent. Reply with ONLY a single JSON object and nothing else - no prose, no markdown fences.
        Available tool names are EXACTLY: echo.
        To run the tool, reply exactly like: {"tool":"echo","parameters":{"text":"ping"}}
        After the tool output arrives, finish with: {"done":true,"summary":"<answer using the tool output>"}
        """
        let ask = [ChatMessage(role: .system, content: system),
                   ChatMessage(role: .user, content: "Call the echo tool with text set to exactly: ping")]
        let raw: String
        do {
            raw = try await registry.completeWithUsage(providerId: providerId, model: model, messages: ask,
                                                       settings: ModelSettings(maxTokens: 256), allowFallback: false).text
        } catch {
            return (.failed("text-protocol call errored: \("\(error)".prefix(100))"), .skipped("path failed"))
        }
        guard let action = ActionParser.parse(raw) else {
            return (.failed("model did not emit a parseable JSON action (text protocol failing — likely needs a gentler prompt / few-shot for this tier)"), .skipped("path failed"))
        }
        guard action.tool == "echo" else {
            return (.failed("model did not emit the requested `echo` tool action"), .skipped("path failed"))
        }
        guard action.parameters["text"] as? String == echoText else {
            return (.failed("model emitted `echo` but with wrong/missing text parameter"), .skipped("path failed"))
        }

        let observation = HeadlessAgentLoop.toolOutputEnvelope(tool: "echo", success: true, body: echoText)
        let followUp = ask + [ChatMessage(role: .assistant, content: raw),
                              ChatMessage(role: .user, content: observation)]
        let finalRaw: String
        do {
            finalRaw = try await registry.completeWithUsage(providerId: providerId, model: model, messages: followUp,
                                                            settings: ModelSettings(maxTokens: 256), allowFallback: false).text
        } catch {
            return (.ok("emitted a parseable `echo` tool action"), .failed("feeding a text-protocol observation back errored: \("\(error)".prefix(80))"))
        }
        guard let final = ActionParser.parse(finalRaw), final.done else {
            return (.ok("emitted a parseable `echo` tool action"), .failed("tool observation did not produce a parseable done action"))
        }
        let summary = (final.summary ?? final.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            return (.ok("emitted a parseable `echo` tool action"), .degraded("done action had an empty summary"))
        }
        return (.ok("emitted a parseable `echo` tool action"),
                summary.contains(echoText) ? .ok("tool observation -> clean final answer") : .degraded("final answer did not mention the echo result"))
    }

    private static func stringArgument(_ raw: String, key: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj[key] as? String
    }

    /// Tolerant across provider wordings: OpenAI `length`, Anthropic `max_tokens`, Gemini `MAX_TOKENS`.
    private static func isTruncation(_ reason: String?) -> Bool {
        guard let reason else { return false }
        let r = reason.uppercased()
        return r.contains("MAX") || r.contains("LENGTH")
    }
}
