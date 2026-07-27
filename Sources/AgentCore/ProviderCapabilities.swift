import Foundation

/// What a given (provider, model) pair can actually do — the capability half of the neutral
/// provider IR. The agent loop routes on this so "uses all AIs" is HONEST: a model that can't
/// do native tool-calling (most local/small models) is driven by the universal text-protocol
/// ReAct loop instead of being force-fed a tools API it will silently fail.
public struct ModelCapabilities: Sendable, Equatable {
    /// The model reliably supports the provider's native function-calling API.
    public var nativeTools: Bool
    /// The model accepts image input.
    public var vision: Bool
    /// The model emits a separate reasoning/thinking stream.
    public var reasoning: Bool
    /// Advertised context window, when known.
    public var contextWindowTokens: Int?
    /// The model/provider path accepts video input directly or through a first-class media file ref.
    public var video: Bool
    /// The model/provider path accepts audio input directly or through a first-class media file ref.
    public var audio: Bool
    /// The provider has a first-class image generation path exposed to Kist.
    public var imageGeneration: Bool
    /// The provider has a first-class image editing path exposed to Kist.
    public var imageEditing: Bool
    /// The provider/model can execute code as a model-side tool (distinct from local shell tools).
    public var codeExecution: Bool
    /// The provider/model can ground answers with search or provider-native grounding.
    public var grounding: Bool
    /// The provider/model can read URLs through provider-native URL context.
    public var urlContext: Bool
    /// The provider/model has a native computer-use surface exposed to Kist.
    public var computerUse: Bool
    /// The provider/model supports realtime/live interaction beyond ordinary chat streaming.
    public var live: Bool
    /// The provider exposes a deep-research agent/tool surface to Kist.
    public var deepResearch: Bool
    /// The provider/model can reliably constrain responses to structured output.
    public var structuredOutput: Bool

    public init(nativeTools: Bool, vision: Bool = false, reasoning: Bool = false, contextWindowTokens: Int? = nil,
                video: Bool = false, audio: Bool = false, imageGeneration: Bool = false,
                imageEditing: Bool = false, codeExecution: Bool = false, grounding: Bool = false,
                urlContext: Bool = false, computerUse: Bool = false, live: Bool = false,
                deepResearch: Bool = false, structuredOutput: Bool = false) {
        self.nativeTools = nativeTools
        self.vision = vision
        self.reasoning = reasoning
        self.contextWindowTokens = contextWindowTokens
        self.video = video
        self.audio = audio
        self.imageGeneration = imageGeneration
        self.imageEditing = imageEditing
        self.codeExecution = codeExecution
        self.grounding = grounding
        self.urlContext = urlContext
        self.computerUse = computerUse
        self.live = live
        self.deepResearch = deepResearch
        self.structuredOutput = structuredOutput
    }

    public var summaryFlags: [String] {
        var out: [String] = []
        if nativeTools { out.append("native-tools") }
        else { out.append("text-tools") }
        if vision { out.append("vision") }
        if video { out.append("video") }
        if audio { out.append("audio") }
        if imageGeneration { out.append("image-gen") }
        if imageEditing { out.append("image-edit") }
        if codeExecution { out.append("code-exec") }
        if grounding { out.append("grounding") }
        if urlContext { out.append("url-context") }
        if computerUse { out.append("computer-use") }
        if live { out.append("live") }
        if deepResearch { out.append("deep-research") }
        if structuredOutput { out.append("structured-output") }
        if let contextWindowTokens { out.append("\(contextWindowTokens / 1000)k-context") }
        return out
    }
}

/// How the loop should obtain tool calls from the model:
///   • `.auto`   — native tool-calling when the (provider, model) supports it, else the text protocol.
///   • `.native` — force native tool-calling (for testing/power use; fails loudly if unsupported).
///   • `.text`   — force the universal text-protocol ReAct loop (works on ANY model, incl. local).
/// `.text` is the escape hatch when a "native-capable" model is actually flaky at tool-calling.
public enum ToolMode: String, Sendable, CaseIterable {
    case auto, native, text
}

public extension ChatProvider {
    /// Default capability resolution from the coarse `supportsNativeTools` flag + the model's
    /// `AIModel` metadata (vision). Providers override for model-specific nuance (e.g. local models).
    func capabilities(forModel model: String) -> ModelCapabilities {
        let meta = availableModels.first { $0.id == model || $0.name == model }
        return ModelCapabilities(nativeTools: supportsNativeTools,
                                 vision: meta?.isVision ?? false,
                                 contextWindowTokens: meta?.contextWindowTokens)
    }
}

public extension ProviderRegistry {
    /// Resolve capabilities for a (providerId, model). Unknown provider → all-false (safest: the
    /// loop then uses the text protocol, which works everywhere).
    func capabilities(providerId: String, model: String?) -> ModelCapabilities {
        guard let provider = provider(id: providerId) else { return ModelCapabilities(nativeTools: false) }
        return provider.capabilities(forModel: provider.resolvedModel(model))
    }

    /// Whether the loop should use the NATIVE path for (providerId, model, mode).
    func usesNativeTools(providerId: String, model: String?, mode: ToolMode) -> Bool {
        switch mode {
        case .native: return true
        case .text:   return false
        case .auto:   return capabilities(providerId: providerId, model: model).nativeTools
        }
    }
}
