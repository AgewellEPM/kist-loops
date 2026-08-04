import Foundation

/// An LLM-backed tool: a plan step that PRODUCES content (prose, code, a summary, an answer) by
/// asking a model, rather than reading it from the filesystem. This is how the CODER role becomes a
/// real teammate — `generate` is bound to the coder vendor, so a plan can have GPT write the code
/// while Claude planned it and Gemini reviews it, all in one loop. The output is captured like any
/// tool output, so a later step can `${ref}` it into write_file.
///
/// Unlike the filesystem tools, `generate` touches no files or shell — it only calls the bound
/// provider — so it needs no confinement; it is safe-by-default (not in the approval set).
public struct GenerateTool: AgentTool {
    public let name = "generate"
    public let description =
        "Generate text content (prose, code, a summary, an answer) with an AI model. Use this when a " +
        "step needs content produced by reasoning rather than read from files. The result is captured " +
        "and can be referenced by later steps via ${id}."
    public let parameters = [
        ToolParameter(name: "prompt", type: "string",
                      description: "Exactly what to produce. Be specific; the model sees only this.", required: true)
    ]

    private let providers: ProviderRegistry
    private let binding: ProviderBinding
    private let maxTokens: Int
    private let recorder: TraceRecorder?     // record a coder LLM-call span
    private let budget: BudgetLedger?        // meter tokens + refuse when over the cap
    private let sink: RuntimeEventSink?      // surface usage live (R0.4 sibling — see execute)

    public init(providers: ProviderRegistry, binding: ProviderBinding, maxTokens: Int = 2048,
                recorder: TraceRecorder? = nil, budget: BudgetLedger? = nil,
                sink: RuntimeEventSink? = nil) {
        self.providers = providers; self.binding = binding; self.maxTokens = maxTokens
        self.recorder = recorder; self.budget = budget; self.sink = sink
    }

    /// If the ENTIRE text is a single ```lang … ``` block, return the inner code; otherwise return
    /// it unchanged. Guards: the opening line must be ONLY a fence (+ optional lang tag), the last
    /// non-blank line must be exactly ```, and there must be no interior closing fence (which would
    /// mean multiple blocks / prose — leave those alone so a real answer keeps its code samples).
    static func unwrapSoleCodeFence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return text }
        var lines = t.components(separatedBy: "\n")
        guard lines.count >= 2 else { return text }
        let openLine = lines[0].trimmingCharacters(in: .whitespaces)
        guard openLine.range(of: #"^```[A-Za-z0-9_+#.\-]*$"#, options: .regularExpression) != nil else { return text }
        guard let closeIdx = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              closeIdx >= 1, lines[closeIdx].trimmingCharacters(in: .whitespaces) == "```" else { return text }
        // Any interior line that is exactly ``` means this isn't a single block — don't unwrap.
        if closeIdx > 1 {
            for i in 1..<closeIdx where lines[i].trimmingCharacters(in: .whitespaces) == "```" { return text }
        }
        return lines[1..<closeIdx].joined(separator: "\n")
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let prompt = try requireString("prompt", from: arguments)
        let settings = ModelSettings(temperature: 0.3, maxTokens: maxTokens)
        // Atomic reserve BEFORE the call (Codex C2 #3): account-after let two parallel fleet workers
        // both pass and both overspend on coder calls. Reserve the estimate; denied ⇒ refuse.
        let estPrompt = prompt.count / 4, estCompletion = maxTokens
        let estUSD = CompetitiveBenchmark.priceUSD(vendor: binding.providerId,
                                                   promptTokens: estPrompt, completionTokens: estCompletion) ?? 0
        var reservationID: Int? = nil
        if let budget {
            reservationID = await budget.reserve(tokens: estPrompt + estCompletion, usd: estUSD)
            if reservationID == nil { return ToolResult.failure("generate skipped: budget exceeded") }
        }
        let started = Date()
        do {
            let (text, usage) = try await providers.completeWithUsage(providerId: binding.providerId, model: binding.model,
                                                                      messages: [ChatMessage(role: .user, content: prompt)],
                                                                      settings: settings)
            // Strip a sole surrounding markdown code fence: models return ```lang\n<code>\n``` and a
            // later write_file wrote the backticks verbatim → the file was corrupt (2026-08-04: nasm
            // choked on ```asm at line 1). Only unwrapped when the WHOLE output is ONE fenced block,
            // so prose that merely contains a fence is left intact.
            let trimmed = Self.unwrapSoleCodeFence(text.trimmingCharacters(in: .whitespacesAndNewlines))
            let measured = usage.isZero ? TokenUsage.estimate(promptChars: prompt.count, completionChars: text.count) : usage
            // R0.4 sibling (review catch 2026-07-28): coder `generate` steps are often the LONGEST
            // calls in a plan and previously contributed nothing to the live token line — the same
            // "~0 tok looks hung" lie meteredComplete had, relocated to execution.
            sink?.emit(.usage(promptTokens: measured.promptTokens, completionTokens: measured.completionTokens,
                              estimated: usage.isZero))
            if let recorder {
                await recorder.record(AgentSpan(id: TraceID.make(), traceId: recorder.traceId, kind: .llmCall,
                    role: AgentRole.coder.rawValue, vendor: binding.providerId, model: binding.model,
                    promptTokens: measured.promptTokens, completionTokens: measured.completionTokens,
                    startedAt: started, endedAt: Date(), status: trimmed.isEmpty ? .error : .ok))
            }
            if let budget, let id = reservationID {
                let usd = CompetitiveBenchmark.priceUSD(vendor: binding.providerId,
                                                        promptTokens: measured.promptTokens,
                                                        completionTokens: measured.completionTokens) ?? 0
                await budget.commit(reservation: id, actualTokens: measured.total, actualUSD: usd)
            }
            guard !trimmed.isEmpty else { return ToolResult.failure("generate produced empty output") }
            return ToolResult(success: true, output: trimmed, metadata: ["provider": binding.providerId])
        } catch {
            // Release the reservation on failure so a failed call doesn't leak its hold.
            if let id = reservationID { await budget?.commit(reservation: id, actualTokens: 0, actualUSD: 0) }
            return ToolResult.failure("generate failed (\(binding.providerId)): \(error)")
        }
    }
}
