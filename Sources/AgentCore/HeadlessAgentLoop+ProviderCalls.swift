import Foundation

// Extracted from HeadlessAgentLoop; shared ProviderCalls behavior for both protocols.
extension HeadlessAgentLoop {
    struct CompletionStreamResult: Sendable {
        let text: String
        let effortRecords: [ProviderEffortRecord]
        let reasoningHandles: [OpaqueProviderReasoningHandle]
    }

    func streamCompletion(messages: [ChatMessage], settings: ModelSettings,
                                  allowFallback: Bool = true,
                                  routePolicy: ProviderRoutePolicy? = nil,
                                  requestBudget: ProviderRequestBudget? = nil) async throws -> CompletionStreamResult {
        let started = Date()
        let promptChars = Self.promptCharacters(messages: messages, settings: settings)
        // Atomic reserve BEFORE the call (C2, aplus). Denied ⇒ throw so the caller halts without spending.
        guard let reservation = await reserveForCall(promptChars: promptChars,
                                                     maxOutputTokens: settings.maxTokens) else {
            throw BudgetDeniedError(reason: await budget?.exceededReason() ?? "budget would be exceeded by the next model call")
        }
        var text = ""
        var usage = TokenUsage.zero
        var effortRecords: [ProviderEffortRecord] = []
        var reasoningHandles: [OpaqueProviderReasoningHandle] = []
        do {
            // The stream() call is INSIDE this do so that a throw HERE (unknown provider, connection
            // refused, etc.) still releases the reservation — otherwise the hold leaks and falsely
            // denies every later call, wedging the run (Codex HIGH #1).
            let stream = try await providers.stream(providerId: providerId, model: model, messages: messages,
                                                    settings: settings, allowFallback: allowFallback,
                                                    routePolicy: routePolicy,
                                                    requestBudget: requestBudget)
            for try await event in stream {
                switch event {
                case .delta(let d):
                    // The visible text protocol is internal control data. Do not stream it to hosts,
                    // or terminal consumers will print raw action JSON and tool arguments.
                    text += d
                case .reasoning(let r): sink.emit(.reasoningDelta(r))
                case .reasoningHandle(let handle): reasoningHandles.append(handle)
                case .effortResolution(let record): effortRecords.append(record)
                case .usage(let p, let c): usage = TokenUsage(promptTokens: p, completionTokens: c)
                default: break
                }
            }
        } catch {
            // Release the reservation on ANY failure so a failed call doesn't leak its hold.
            let route = error as? ProviderRouteFailure
            await recordLLMSpan(usage: usage, promptChars: promptChars, completionChars: text.count,
                                started: started, status: .error, reservation: reservation,
                                actualProvider: route?.provider ?? effortRecords.last?.providerID,
                                actualModel: route?.model ?? effortRecords.last?.modelID)
            throw error
        }
        await recordLLMSpan(usage: usage,
                            promptChars: promptChars,
                            completionChars: text.count,
                            started: started,
                            status: .ok,
                            reservation: reservation,
                            actualProvider: effortRecords.last?.providerID,
                            actualModel: effortRecords.last?.modelID)
        return CompletionStreamResult(text: text,
                                      effortRecords: Array(effortRecords.suffix(32)),
                                      reasoningHandles: Array(reasoningHandles.suffix(32)))
    }

    func applyProviderReasoningEffort(_ settings: inout ModelSettings,
                                              checkpoint: inout LoopCheckpoint) {
        let resolution = providers.reasoningEffortResolution(providerId: providerId, model: model,
                                                             requested: providerReasoningEffort,
                                                             base: settings)
        settings = resolution.settings
        recordProviderEffort(resolution.record, checkpoint: &checkpoint)
    }

    func recordProviderMetadata(_ completion: CompletionStreamResult,
                                        checkpoint: inout LoopCheckpoint) {
        for record in completion.effortRecords { recordProviderEffort(record, checkpoint: &checkpoint) }
        recordProviderReasoningHandles(completion.reasoningHandles, checkpoint: &checkpoint)
    }

    func recordProviderEffort(_ record: ProviderEffortRecord,
                                      checkpoint: inout LoopCheckpoint) {
        var records = checkpoint.providerEffortRecords ?? []
        if records.last != record { records.append(record) }
        checkpoint.providerEffortRecords = Array(records.suffix(128))
    }

    func recordProviderReasoningHandles(_ handles: [OpaqueProviderReasoningHandle],
                                                checkpoint: inout LoopCheckpoint) {
        var stored = checkpoint.providerReasoningHandles ?? []
        for handle in handles {
            stored.removeAll {
                $0.providerID == handle.providerID && $0.modelID == handle.modelID
                    && $0.kind == handle.kind && $0.associationID == handle.associationID
            }
            stored.append(handle)
        }
        checkpoint.providerReasoningHandles = Array(stored.suffix(128))
    }

    /// A held reservation. `id` is the BudgetLedger reservation id to release at commit (nil when there
    /// is no budget → nothing to commit). Passed from the call site to recordLLMSpan so the hold is
    /// released and reconciled to actual at the single chokepoint.
    struct Reservation: Sendable { let id: Int? }

    /// Thrown by the text path's streamCompletion when a reservation is denied, so the caller halts
    /// with an honest budget message rather than a generic provider error.
    struct BudgetDeniedError: Error { let reason: String }

    /// Atomic reserve-before-spend (C2): estimate this call's cost and reserve it BEFORE issuing it.
    /// Returns nil = DENIED (the reservation would breach a cap → the caller halts without calling).
    /// On an uncapped ledger (or no budget) returns a zero reservation (always allowed).
    func reserveForCall(promptChars: Int, maxOutputTokens: Int) async -> Reservation? {
        guard let budget else { return Reservation(id: nil) }   // no budget → nothing to reserve/commit
        let resolvedModel = providers.provider(id: providerId)?.resolvedModel(model) ?? model ?? "default"
        let framing = await budget.promptOverhead(for: providerId + ":" + resolvedModel,
            subscriptionCLI: ["codex-cli", "claude-cli"].contains(providerId.lowercased()))
        let estPrompt = max(0, promptChars) / 4 + framing
        let estCompletion = max(0, maxOutputTokens)
        let estTokens = estPrompt + estCompletion
        let estUSD = CompetitiveBenchmark.priceUSD(vendor: providerId,
                                                   promptTokens: estPrompt, completionTokens: estCompletion) ?? 0
        guard let id = await budget.reserve(tokens: estTokens, usd: estUSD) else { return nil }   // denied
        return Reservation(id: id)
    }

    /// Halt when a reservation was denied (the next call would breach the cap).
    func budgetDeniedHalt(_ cp: inout LoopCheckpoint) async -> (Outcome, LoopCheckpoint) {
        let reason = await budget?.exceededReason()
            ?? "budget would be exceeded by the next model call"
        sink.emit(.stateChanged(.failed))
        return finishFailed(&cp, reason, "\(reason) — inspect /usage; reduce context or split the remaining work before retrying")
    }

    func recordLLMSpan(usage: TokenUsage, promptChars: Int, completionChars: Int,
                               started: Date, status: SpanStatus, reservation: Reservation? = nil,
                               actualProvider: String? = nil, actualModel: String? = nil) async {
        // Budget accounting runs at THIS single chokepoint (both the native and text drive paths
        // funnel every model call through recordLLMSpan), and BEFORE the trace guard so the cap is
        // enforced even when no trace recorder is attached. Measured tokens when the provider reports
        // them; a clearly-labeled ~4-char estimate otherwise.
        let measured = usage.isZero ? TokenUsage.estimate(promptChars: promptChars, completionChars: completionChars) : usage
        if !usage.isZero {
            let routedProvider = actualProvider ?? providerId
            let routedModel = actualModel ?? providers.provider(id: routedProvider)?.resolvedModel(model) ?? model ?? "default"
            await budget?.observePromptUsage(route: routedProvider + ":" + routedModel,
                promptCharacters: promptChars, measuredTokens: usage.promptTokens)
        }
        let usd = CompetitiveBenchmark.priceUSD(vendor: actualProvider ?? providerId,
                                                promptTokens: measured.promptTokens,
                                                completionTokens: measured.completionTokens) ?? 0
        // Commit (aplus): release the pre-call reservation (by id) and book the ACTUAL spend (atomic
        // reserve→commit). A reservation with a nil id means there was no budget — nothing to commit.
        // Legacy callers without a reservation (post-loop synthesis) fall back to a plain add.
        if let reservation {
            if let id = reservation.id {
                await budget?.commit(reservation: id, actualTokens: measured.total, actualUSD: usd)
            }
        } else {
            await budget?.add(tokens: measured.total, usd: usd)
        }
        // main: emit the live token-usage signal for the UI (aplus dropped this — restored).
        sink.emit(.usage(promptTokens: measured.promptTokens,
                         completionTokens: measured.completionTokens,
                         estimated: usage.isZero))
        guard let traceRecorder else { return }
        await traceRecorder.record(AgentSpan(id: TraceID.make(), traceId: traceRecorder.traceId,
                                             kind: .llmCall, role: traceRole,
                                             vendor: actualProvider ?? providerId, model: actualModel ?? model,
                                             promptTokens: measured.promptTokens,
                                             completionTokens: measured.completionTokens,
                                             attributes: ["usage.reported": String(!usage.isZero)],
                                             startedAt: started, endedAt: Date(),
                                             status: status))
    }

    /// The live tool contract for THIS loop (what the model sees) — used by `/tools` so the user can audit it.
    public func renderToolContract() -> String {
        ToolContractBook.render(tools: tools, disabled: ToolContractBook.disabledMap(shellEnabled: context.shell.enabled))
    }

    /// The names of every tool callable this turn — used by self-evolution's CapabilityDiscovery to point a
    /// knowledge-gap recovery at a tool's real "list capabilities" sibling (only ones that actually exist).
    public var toolNames: [String] { tools.all().map { $0.name } }

    /// Whether run_command may actually execute this turn — needed to apply the same execution-grounding
    /// verifier the great loop uses (GreatLoopVerifier) to the interactive turn-end scorecard (P6 fix).
    public var shellEnabled: Bool { context.shell.enabled }

}
