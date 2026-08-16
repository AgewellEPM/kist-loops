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

    /// Extract the real code from a model reply meant to be a file's content. Handles the three
    /// shapes models actually return: (1) raw code (no fence) → unchanged; (2) a sole ```lang…```
    /// block → its inner content; (3) PROSE wrapping one or MORE fenced blocks (e.g. "Okay, here's
    /// the code:\n```asm\n<code>\n```\nHow to run:\n```bash\nnasm …\n```") → the LARGEST fenced
    /// block (the actual code; the sibling bash/output blocks are small). This is the 2026-08-04
    /// visual-dogfood bug: the model wrapped DOS asm in an essay + extra ```bash``` blocks, the
    /// whole essay was written to hello.asm, and nasm choked on "Okay, here's…".
    static func unwrapSoleCodeFence(_ text: String) -> String {
        // Never normalize the payload before inspecting it. Plain generated content is a byte-bearing
        // artifact, and leading whitespace / terminal newlines can be semantically required. Splitting
        // and rejoining only the selected fenced payload preserves every interior byte, including the
        // newline which separates its final content line from the closing fence.
        let lines = text.components(separatedBy: "\n")
        let isFence: (String) -> Bool = { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            return s.range(of: #"^```[A-Za-z0-9_+#.\-]*$"#, options: .regularExpression) != nil
        }
        // Pair fence markers into (open, close) blocks by toggling — code blocks don't nest.
        var blocks: [(open: Int, close: Int)] = []
        var open: Int? = nil
        for (i, line) in lines.enumerated() where isFence(line) {
            if let o = open { blocks.append((o, i)); open = nil } else { open = i }
        }
        // No COMPLETE fenced block ⇒ it's already raw content (or an unterminated fence) — leave it.
        guard let best = blocks.filter({ $0.close > $0.open + 1 })
                               .max(by: { ($0.close - $0.open) < ($1.close - $1.open) })
        else { return text }
        return lines[(best.open + 1)..<best.close].joined(separator: "\n") + "\n"
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
            let generated = Self.unwrapSoleCodeFence(text)
            let generatedIsEmpty = generated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    startedAt: started, endedAt: Date(), status: generatedIsEmpty ? .error : .ok))
            }
            if let budget, let id = reservationID {
                let usd = CompetitiveBenchmark.priceUSD(vendor: binding.providerId,
                                                        promptTokens: measured.promptTokens,
                                                        completionTokens: measured.completionTokens) ?? 0
                await budget.commit(reservation: id, actualTokens: measured.total, actualUSD: usd)
            }
            guard !generatedIsEmpty else { return ToolResult.failure("generate produced empty output") }
            return ToolResult(success: true, output: generated, metadata: ["provider": binding.providerId])
        } catch {
            // Release the reservation on failure so a failed call doesn't leak its hold.
            if let id = reservationID { await budget?.commit(reservation: id, actualTokens: 0, actualUSD: 0) }
            return ToolResult.failure("generate failed (\(binding.providerId)): \(error)")
        }
    }
}
