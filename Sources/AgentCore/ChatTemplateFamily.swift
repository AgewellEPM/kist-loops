import Foundation

/// FLAWLESS-LOOPS SAFETY NET #3 (brain): chat-template + stop awareness for local models.
///
/// A local model only runs a clean loop if the runtime stops generation at the model's REAL turn
/// boundary. Each family ends a turn with a different token (`<|eot_id|>`, `<|im_end|>`, `</s>`,
/// `<end_of_turn>`, …). Pick the wrong one and the model bleeds past its turn — the #1 cause of a
/// "broken loop" on local weights. We detect the family from the embedded chat template / metadata and
/// hand back the stop sequences the loop should pass through to generation.
public enum ChatTemplateFamily: String, Sendable, Equatable, CaseIterable {
    case llama3        // <|eot_id|> / <|start_header_id|>
    case chatml        // <|im_start|> / <|im_end|>  (Qwen, Yi, many fine-tunes)
    case mistral       // [INST] … [/INST] … </s>
    case gemma         // <start_of_turn> / <end_of_turn>  (no system role)
    case phi           // <|user|> <|assistant|> <|end|>
    case deepseek      // <｜begin▁of▁sentence｜> / <｜end▁of▁sentence｜>
    case unknown

    /// Stop sequences for this family — generation halts when any is produced, so the turn ends clean.
    /// INVARIANT: only turn-END / EOS tokens. NEVER a turn-START token — not the model's own
    /// (`<|im_start|>`, `<start_of_turn>`) which would self-truncate, and not the next (user) turn's
    /// start (`[INST]`, `<|user|>`) which a model could legitimately emit in output and get cut off.
    /// The end tokens alone close the turn cleanly; run-on is already bounded by maxTokens + the loop's
    /// single-action parse.
    public var stopSequences: [String] {
        switch self {
        case .llama3:   return ["<|eot_id|>", "<|end_of_text|>"]
        case .chatml:   return ["<|im_end|>", "<|endoftext|>"]
        case .mistral:  return ["</s>"]
        case .gemma:    return ["<end_of_turn>", "<eos>"]
        case .phi:      return ["<|end|>", "<|endoftext|>"]
        case .deepseek: return ["<｜end▁of▁sentence｜>", "<|EOT|>"]
        case .unknown:  return []
        }
    }

    public var displayName: String {
        switch self {
        case .llama3: return "Llama 3 (<|eot_id|>)"
        case .chatml: return "ChatML (<|im_end|>)"
        case .mistral: return "Mistral ([INST]/</s>)"
        case .gemma: return "Gemma (<end_of_turn>)"
        case .phi: return "Phi (<|end|>)"
        case .deepseek: return "DeepSeek (<｜end▁of▁sentence｜>)"
        case .unknown: return "unknown"
        }
    }

    /// Detect the family from the strongest available signal: the chat template string first (most
    /// reliable — it literally contains the turn tokens), then the EOS token, then the model name.
    /// Order matters: more specific markers are checked before generic ones.
    public static func detect(chatTemplate: String?, eosToken: String?, modelName: String?) -> ChatTemplateFamily {
        if let t = chatTemplate, !t.isEmpty {
            if t.contains("<|eot_id|>") || t.contains("<|start_header_id|>") { return .llama3 }
            if t.contains("<|im_start|>") || t.contains("<|im_end|>") { return .chatml }
            if t.contains("<start_of_turn>") || t.contains("<end_of_turn>") { return .gemma }
            if t.contains("｜end▁of▁sentence｜") || t.contains("｜begin▁of▁sentence｜") { return .deepseek }
            if t.contains("<|assistant|>") && t.contains("<|end|>") { return .phi }
            if t.contains("[INST]") { return .mistral }
        }
        if let e = eosToken, let fam = familyFromToken(e) { return fam }
        if let n = modelName, let fam = familyFromName(n) { return fam }
        return .unknown
    }

    static func familyFromToken(_ token: String) -> ChatTemplateFamily? {
        switch token {
        // `<|eot_id|>` is llama3-specific; `<|end_of_text|>` is a GENERIC EOS used by many models, so it
        // is NOT decisive on its own — let the template/name signals classify those instead (GPT review).
        case "<|eot_id|>": return .llama3
        case "<|im_end|>": return .chatml
        case "<end_of_turn>": return .gemma
        case "<|end|>": return .phi
        case "</s>": return .mistral
        default:
            if token.contains("end▁of▁sentence") { return .deepseek }
            return nil
        }
    }

    static func familyFromName(_ name: String) -> ChatTemplateFamily? {
        let n = name.lowercased()
        if n.contains("llama-3") || n.contains("llama3") || n.contains("llama 3") { return .llama3 }
        if n.contains("qwen") || n.contains("yi-") || n.contains("hermes") { return .chatml }
        if n.contains("mistral") || n.contains("mixtral") { return .mistral }
        if n.contains("gemma") { return .gemma }
        if n.contains("phi-") || n.contains("phi3") || n.contains("phi-3") { return .phi }
        if n.contains("deepseek") { return .deepseek }
        return nil
    }
}

/// The resolved profile for a local model: which template family, the stop sequences to enforce, and
/// the raw signals we detected it from (for honest reporting — never claim a family we can't show).
public struct LocalModelTemplate: Sendable, Equatable {
    public var family: ChatTemplateFamily
    public var stopSequences: [String]
    public var chatTemplate: String?
    public var eosToken: String?
    public var modelName: String?
    public var source: String          // where we read it (e.g. "tokenizer_config.json", "GGUF metadata", "model name")

    public init(family: ChatTemplateFamily, chatTemplate: String? = nil, eosToken: String? = nil,
                modelName: String? = nil, source: String) {
        self.family = family
        self.chatTemplate = chatTemplate
        self.eosToken = eosToken
        self.modelName = modelName
        self.source = source
        // Prefer the family's known stops; if the model declares an EOS we don't already cover, add it.
        var stops = family.stopSequences
        if let e = eosToken, !e.isEmpty, !stops.contains(e) { stops.append(e) }
        self.stopSequences = stops
    }

    /// Build from raw signals, detecting the family.
    public static func from(chatTemplate: String?, eosToken: String?, modelName: String?, source: String) -> LocalModelTemplate {
        let fam = ChatTemplateFamily.detect(chatTemplate: chatTemplate, eosToken: eosToken, modelName: modelName)
        return LocalModelTemplate(family: fam, chatTemplate: chatTemplate, eosToken: eosToken, modelName: modelName, source: source)
    }
}
