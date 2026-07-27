import Foundation

/// Empirical probes that test a candidate model against the REAL agent-loop contract
/// (the universal text protocol + native tool-calling), using the same `ActionParser`
/// and `systemPrompt` the live loop trusts. Each probe is fail-safe: any error becomes a
/// FAIL/PARTIAL outcome, never a thrown crash, so onboarding always produces a verdict.
public enum OnboardingProbes {
    public enum Status: String, Sendable, Equatable { case pass, partial, fail, skipped }

    public struct Outcome: Sendable, Equatable {
        public let status: Status
        public let detail: String
        public init(_ status: Status, _ detail: String) { self.status = status; self.detail = detail }
    }

    private static func short(_ error: Error) -> String {
        let s = "\(error)"
        return s.count > 160 ? String(s.prefix(160)) + "…" : s
    }

    // MARK: Probe 1 — text-protocol "grip": can it emit a parseable tool action?

    public static func gripProbe(registry: ProviderRegistry, providerId: String, model: String) async -> Outcome {
        let sys = HeadlessAgentLoop.systemPrompt(tools: ToolRegistry.headless(),
                                                 projectRoot: NSTemporaryDirectory(),
                                                 shellEnabled: false)
        let settings = ModelSettings(temperature: 0, topP: 1, maxTokens: 1400, systemPrompt: sys)
        let user = ChatMessage(role: .user,
                               content: "Read the file README.md to find the answer. Take exactly ONE action now.")
        // The tool names the real loop will accept. A hallucinated name must FAIL the probe.
        let validTools = Set(ToolRegistry.headless().toolSpecs().map { $0.name })
        do {
            // Test THIS exact model — no fallback provider, no silent same-provider id resolution.
            let (text, _) = try await registry.completeWithUsage(providerId: providerId, model: model,
                                                                messages: [user], settings: settings,
                                                                allowFallback: false, allowModelResolution: false)
            guard let action = ActionParser.parse(text) else {
                return Outcome(.fail, "reply did not parse as a protocol action (no JSON tool object)")
            }
            if let tool = action.tool, !tool.isEmpty {
                guard validTools.contains(tool) else {
                    return Outcome(.fail, "emitted unknown tool '\(tool)' not in the agent tool registry")
                }
                return tool == "read_file"
                    ? Outcome(.pass, "emitted a valid read_file action")
                    : Outcome(.pass, "emitted a valid tool action (\(tool))")
            }
            if action.done {
                return Outcome(.partial, "finished immediately without taking a tool action")
            }
            return Outcome(.fail, "parsed but carried neither a tool nor done")
        } catch {
            return Outcome(.fail, "completion failed: \(short(error))")
        }
    }

    // MARK: Probe 2 — decision/instruction-following: does it finish correctly on cue?

    public static func decisionProbe(registry: ProviderRegistry, providerId: String, model: String) async -> Outcome {
        let sys = HeadlessAgentLoop.systemPrompt(tools: ToolRegistry.headless(),
                                                 projectRoot: NSTemporaryDirectory(),
                                                 shellEnabled: false)
        let settings = ModelSettings(temperature: 0, topP: 1, maxTokens: 1400, systemPrompt: sys)
        let user = ChatMessage(role: .user,
                               content: "The answer is 42. You already have everything you need — do NOT call any tool. Finish now and report the answer.")
        do {
            let (text, _) = try await registry.completeWithUsage(providerId: providerId, model: model,
                                                                messages: [user], settings: settings,
                                                                allowFallback: false, allowModelResolution: false)
            guard let action = ActionParser.parse(text) else {
                return Outcome(.fail, "reply did not parse as a protocol action")
            }
            if action.done {
                let summary = action.summary ?? ""
                return summary.contains("42")
                    ? Outcome(.pass, "finished with the correct answer (42)")
                    : Outcome(.partial, "finished but summary missing the expected answer")
            }
            return Outcome(.partial, "kept acting instead of finishing on instruction")
        } catch {
            return Outcome(.fail, "completion failed: \(short(error))")
        }
    }

    // MARK: Probe 3 — native multi-turn tools (the MiMo/DeepSeek round-2 signature)

    /// Returns whether native tool-calling is usable for a MULTI-TURN loop, plus a human note.
    /// Round 1 must emit a tool call; round 2 (echoing the call + a tool result) must NOT 400.
    public static func nativeToolsProbe(registry: ProviderRegistry, providerId: String, model: String) async -> (supported: Bool, outcome: Outcome) {
        let spec = ToolSpec(name: "get_time",
                            description: "Get the current time. Takes no arguments.",
                            parameters: [])
        let settings = ModelSettings(temperature: 0, topP: 1, maxTokens: 1024,
                                     systemPrompt: "You are a tool-using assistant. When asked, call the provided tool.",
                                     disableThinking: true)
        let r1 = [ChatMessage(role: .user, content: "Call the get_time tool now to fetch the current time.")]

        // Round 1: must emit a native tool call.
        var callId = "", callName = "", callArgs = "{}"
        do {
            let stream = try await registry.streamTools(providerId: providerId, model: model,
                                                        messages: r1, settings: settings, tools: [spec])
            for try await ev in stream {
                if case let .toolCall(id, name, args) = ev {
                    callId = id; callName = name
                    callArgs = args.isEmpty ? "{}" : args
                    break
                }
            }
        } catch {
            return (false, Outcome(.partial, "native tools unavailable (round 1: \(short(error))) → text protocol"))
        }
        guard !callId.isEmpty || !callName.isEmpty else {
            return (false, Outcome(.partial, "model did not emit a native tool call → text protocol"))
        }

        // Round 2: echo the assistant tool call + a tool result; a 400 here is the broken-history signature.
        let assistant = ChatMessage(role: .assistant, content: "",
                                    toolCalls: [ToolCallRef(id: callId, name: callName.isEmpty ? "get_time" : callName,
                                                            argumentsJSON: callArgs)])
        let toolMsg = ChatMessage.toolResult(callId: callId, content: "12:00 UTC")
        let r2 = r1 + [assistant, toolMsg]
        do {
            let stream = try await registry.streamTools(providerId: providerId, model: model,
                                                        messages: r2, settings: settings, tools: [spec])
            for try await _ in stream { /* drain — success is reaching the end without a throw */ }
            return (true, Outcome(.pass, "native multi-turn tools confirmed working"))
        } catch let e as AIProviderError {
            if case let .http(status, _) = e, status == 400 {
                return (false, Outcome(.partial, "round-2 tool history rejected (HTTP 400) → routed to text protocol"))
            }
            return (false, Outcome(.partial, "native tools error round 2 (\(short(e))) → text protocol"))
        } catch {
            return (false, Outcome(.partial, "native tools error round 2 (\(short(error))) → text protocol"))
        }
    }
}
