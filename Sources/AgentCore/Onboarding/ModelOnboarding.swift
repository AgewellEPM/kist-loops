import Foundation

/// One stage of the onboarding pipeline, for the printed report.
public struct OnboardingStage: Sendable, Equatable {
    public let name: String
    public let status: OnboardingProbes.Status
    public let detail: String
    public init(_ name: String, _ status: OnboardingProbes.Status, _ detail: String) {
        self.name = name; self.status = status; self.detail = detail
    }
}

/// The outcome of onboarding a model: the AUTO-CONFIGURED provider (healed id, model
/// list, empirically-detected native-tools flag), an honest verdict, and the per-stage trace.
public struct OnboardingResult: Sendable {
    public enum Verdict: String, Sendable { case pass, partial, fail }
    public let provider: OpenAICompatibleProvider
    public let verdict: Verdict
    public let stages: [OnboardingStage]
    public let healedModelId: String?
    public let judgeNote: String?

    public init(provider: OpenAICompatibleProvider, verdict: Verdict, stages: [OnboardingStage],
                healedModelId: String?, judgeNote: String?) {
        self.provider = provider; self.verdict = verdict; self.stages = stages
        self.healedModelId = healedModelId; self.judgeNote = judgeNote
    }

    public func render() -> String {
        func glyph(_ s: OnboardingProbes.Status) -> String {
            switch s { case .pass: return "✓"; case .partial: return "~"; case .fail: return "✗"; case .skipped: return "·" }
        }
        var out = "Onboarding \(provider.id) (\(provider.name)) — verdict: \(verdict.rawValue.uppercased())\n"
        if let h = healedModelId { out += "  self-healed model id → \(h)\n" }
        for st in stages { out += "  \(glyph(st.status)) \(st.name): \(st.detail)\n" }
        out += "  config: model=\(provider.defaultModel)  native-tools=\(provider.nativeToolsSupported)  "
            + "vision=\(provider.availableModels.first?.isVision ?? false)  models=\(provider.availableModels.count)\n"
        if let j = judgeNote { out += "  judge (\(j))\n" }
        return out
    }
}

/// The auto-onboarding pipeline: self-heal the model id, self-test completion, pen-test the
/// agent-loop grip + decision-making, auto-detect native multi-turn tools, and emit a
/// fully-configured provider. Reuses the existing doctor/resolver/probe primitives + the REAL
/// loop contract. Deterministic checks are the source of truth; the judge is advisory only.
public enum ModelOnboarding {
    public typealias ModelsFetch = @Sendable (_ modelsURL: String, _ apiKey: String?) async -> Result<[String], Error>

    /// Run onboarding for `draft`, which MUST already be registered in `registry` with its key
    /// resolvable (use an `OverlayKeyStore` for an unsaved key). `judgeProviderId`, if set and keyed,
    /// adds a non-binding second opinion from an existing model.
    public static func run(provider draft: OpenAICompatibleProvider,
                           registry: ProviderRegistry,
                           fetch: @escaping ModelsFetch = { await ProviderDoctor.liveFetch(modelsURL: $0, apiKey: $1) },
                           judgeProviderId: String? = nil) async -> OnboardingResult {
        var stages: [OnboardingStage] = []

        // --- Stage 1: self-heal the model id + auto-fill the model list from /models ---------
        var model = draft.defaultModel
        var healed: String? = nil
        var models: [AIModel] = draft.availableModels.isEmpty ? [AIModel(id: model)] : draft.availableModels
        let modelsURL = ProviderDoctor.modelsEndpoint(for: draft)
        let apiKey = registry.apiKey(forProviderId: draft.id)
        switch await fetch(modelsURL, apiKey) {
        case .success(let live) where !live.isEmpty:
            if let resolved = ModelResolver.resolve(requested: model, default: model, live: live), resolved != model {
                healed = resolved; model = resolved
                stages.append(OnboardingStage("model-id", .pass, "'\(draft.defaultModel)' not found; healed to '\(resolved)'"))
            } else {
                stages.append(OnboardingStage("model-id", .pass, "'\(model)' verified against \(live.count) live models"))
            }
            var built = Array(live.prefix(40)).map { AIModel(id: $0) }
            if !built.contains(where: { $0.id == model }) { built.insert(AIModel(id: model), at: 0) }
            models = built
        default:
            stages.append(OnboardingStage("model-id", .skipped, "no reachable /models list; using entered id '\(model)'"))
        }

        func assemble(nativeTools: Bool) -> OpenAICompatibleProvider {
            OpenAICompatibleProvider(id: draft.id, name: draft.name, iconName: draft.iconName,
                                     keyAccount: draft.keyAccount, endpoint: draft.endpoint,
                                     defaultModel: model, availableModels: models,
                                     requiresAPIKey: draft.requiresAPIKey, isLocal: draft.isLocal,
                                     nativeToolsSupported: nativeTools)
        }

        // --- Stage 2: completion self-test (must return non-empty; reasoning-budget heal built in) ---
        do {
            let probe = ChatMessage(role: .user, content: "Reply with exactly: OK")
            let (text, _) = try await registry.completeWithUsage(
                providerId: draft.id, model: model, messages: [probe],
                settings: ModelSettings(temperature: 0, topP: 1, maxTokens: 24, disableThinking: true),
                allowFallback: false, allowModelResolution: false)   // test EXACTLY the id we persist
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            stages.append(OnboardingStage("completion", .pass, "live reply: \"\(String(trimmed.prefix(40)))\""))
        } catch {
            stages.append(OnboardingStage("completion", .fail, "no usable completion: \(String("\(error)".prefix(140)))"))
            // Can't even complete — stop here, do not save. Verdict FAIL.
            return OnboardingResult(provider: assemble(nativeTools: false), verdict: .fail,
                                    stages: stages, healedModelId: healed, judgeNote: nil)
        }

        // --- Stage 3 + 4: pen-test the loop grip + decision-making against the real contract ---
        let grip = await OnboardingProbes.gripProbe(registry: registry, providerId: draft.id, model: model)
        stages.append(OnboardingStage("tool-grip", grip.status, grip.detail))
        let decision = await OnboardingProbes.decisionProbe(registry: registry, providerId: draft.id, model: model)
        stages.append(OnboardingStage("decision", decision.status, decision.detail))

        // --- Stage 5: auto-detect native multi-turn tools (the MiMo/DeepSeek signature) ---
        var nativeTools = false
        if draft.isLocal {
            stages.append(OnboardingStage("native-tools", .skipped, "local server → universal text protocol"))
        } else {
            let (supported, outcome) = await OnboardingProbes.nativeToolsProbe(registry: registry, providerId: draft.id, model: model)
            nativeTools = supported
            stages.append(OnboardingStage("native-tools", supported ? .pass : outcome.status, outcome.detail))
        }

        // --- Verdict (deterministic; judge never overrides) ---
        // Either CORE loop probe failing = hard FAIL (fail-closed): a model that can't emit a
        // parseable, REAL tool action, or won't follow a finish instruction, is not saved as usable.
        let verdict: OnboardingResult.Verdict
        if grip.status == .fail || decision.status == .fail {
            verdict = .fail
        } else if grip.status == .pass && decision.status == .pass && (nativeTools || draft.isLocal) {
            verdict = .pass
        } else {
            verdict = .partial
        }
        let configured = assemble(nativeTools: nativeTools)

        // --- Optional advisory judge (uses an EXISTING configured model; non-binding) ---
        var judgeNote: String? = nil
        if let judgeId = judgeProviderId, judgeId != draft.id {
            judgeNote = await advisoryJudge(registry: registry, judgeId: judgeId, stages: stages, verdict: verdict)
        }

        return OnboardingResult(provider: configured, verdict: verdict, stages: stages,
                                healedModelId: healed, judgeNote: judgeNote)
    }

    /// A second opinion from an already-configured model. ADVISORY ONLY — it summarizes the
    /// deterministic results; it cannot change the verdict (trustworthy-by-construction discipline).
    private static func advisoryJudge(registry: ProviderRegistry, judgeId: String,
                                      stages: [OnboardingStage], verdict: OnboardingResult.Verdict) async -> String? {
        let trace = stages.map { "\($0.name)=\($0.status.rawValue): \($0.detail)" }.joined(separator: "\n")
        let prompt = """
        A new AI model was just onboarded into our agent runtime. Here are the deterministic test results:
        \(trace)
        Deterministic verdict: \(verdict.rawValue).
        In ONE short sentence, give a plain-language assessment a developer would find useful. Do not restate the verdict.
        """
        let msg = ChatMessage(role: .user, content: prompt)
        guard let text = try? await registry.complete(
            providerId: judgeId, model: nil, messages: [msg],
            settings: ModelSettings(temperature: 0.2, topP: 1, maxTokens: 120, disableThinking: true))
        else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : "\(judgeId): \(String(clean.prefix(200)))"
    }
}
