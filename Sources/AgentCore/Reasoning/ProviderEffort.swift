import Foundation

public enum ProviderReasoningEffort: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case none
    case light
    case deep
}

/// A provider-native control that an adapter can encode without reinterpreting a Boolean hint.
public enum ProviderReasoningNativeControl: Codable, Sendable, Equatable {
    case openAIReasoningEffort(String)
    case anthropic(thinking: String?, effort: String?)
    case geminiThinkingBudget(Int)
    case geminiThinkingLevel(String)
    case mimoThinking(String)

    public var disablesThinking: Bool {
        switch self {
        case .openAIReasoningEffort(let value): return value == "none"
        case .anthropic(let thinking, _): return thinking == "disabled"
        case .geminiThinkingBudget(let value): return value == 0
        case .mimoThinking(let value): return value == "disabled"
        case .geminiThinkingLevel: return false
        }
    }
}

/// Honest capability declaration: some requests are native controls, while others are only left
/// to the provider. A provider-managed level is not reported as applied.
public struct ProviderReasoningEffortSupport: Sendable, Equatable {
    public let applied: Set<ProviderReasoningEffort>
    public let providerManaged: Set<ProviderReasoningEffort>

    public init(applied: Set<ProviderReasoningEffort> = [],
                providerManaged: Set<ProviderReasoningEffort> = []) {
        self.applied = applied
        self.providerManaged = providerManaged
    }

    public static let unsupported = ProviderReasoningEffortSupport()
}

public enum ProviderEffortApplication: String, Codable, Sendable, Equatable {
    case applied
    case providerManaged
    case unsupported
}

public struct ProviderEffortRecord: Codable, Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public let requested: ProviderReasoningEffort
    public let application: ProviderEffortApplication
    public let effectiveThinkingBudget: Int?
    public let nativeControl: ProviderReasoningNativeControl?
    public let note: String

    public init(providerID: String, modelID: String, requested: ProviderReasoningEffort,
                application: ProviderEffortApplication, effectiveThinkingBudget: Int? = nil,
                nativeControl: ProviderReasoningNativeControl? = nil, note: String) {
        self.providerID = providerID
        self.modelID = modelID
        self.requested = requested
        self.application = application
        self.effectiveThinkingBudget = effectiveThinkingBudget
        self.nativeControl = nativeControl
        self.note = note
    }
}

public struct ProviderEffortResolution: Sendable {
    public let settings: ModelSettings
    public let record: ProviderEffortRecord
}

/// Converts one provider-neutral effort request into settings the current adapters actually
/// honor. Unsupported combinations are explicit records, never silent pretend-success.
public enum ProviderEffortMapper {
    public static func support(providerID: String, modelID: String) -> ProviderReasoningEffortSupport {
        let provider = providerID.lowercased()
        let model = modelID.lowercased()
        let all = Set(ProviderReasoningEffort.allCases)

        if provider == "mimo" {
            return ProviderReasoningEffortSupport(applied: [.none], providerManaged: [.light, .deep])
        }
        if provider == "openai" {
            if model.contains("-pro") { return ProviderReasoningEffortSupport(applied: [.deep]) }
            if model.hasPrefix("gpt-5") {
                return ProviderReasoningEffortSupport(applied: all)
            }
            if model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") {
                return ProviderReasoningEffortSupport(applied: [.light, .deep])
            }
            return .unsupported
        }
        if provider.contains("gemini") || provider == "google" {
            if model.hasPrefix("gemini-3") {
                return ProviderReasoningEffortSupport(applied: [.light, .deep])
            }
            if model.contains("2.5-pro") {
                return ProviderReasoningEffortSupport(applied: [.light, .deep])
            }
            if model.hasPrefix("gemini-2.5") {
                return ProviderReasoningEffortSupport(applied: all)
            }
            return .unsupported
        }
        if provider.contains("anthropic") || provider.contains("claude") {
            if model.contains("fable-5") || model.contains("mythos-5") || model.contains("opus-5") {
                return ProviderReasoningEffortSupport(applied: all)
            }
            if model.contains("opus-4-8") || model.contains("opus-4-7") || model.contains("opus-4-6") {
                return ProviderReasoningEffortSupport(applied: [.none], providerManaged: [.light, .deep])
            }
            return .unsupported
        }
        return .unsupported
    }

    public static func resolve(providerID: String, modelID: String,
                               requested: ProviderReasoningEffort,
                               base: ModelSettings) -> ProviderEffortResolution {
        resolve(providerID: providerID, modelID: modelID, requested: requested,
                support: support(providerID: providerID, modelID: modelID), base: base)
    }

    public static func resolve(providerID: String, modelID: String,
                               requested: ProviderReasoningEffort,
                               support: ProviderReasoningEffortSupport,
                               base: ModelSettings) -> ProviderEffortResolution {
        let provider = providerID.lowercased()
        let model = modelID.lowercased()
        var settings = base
        settings.reasoningEffort = requested
        settings.providerReasoningControl = nil
        settings.thinkingBudget = nil

        func result(_ application: ProviderEffortApplication,
                    control: ProviderReasoningNativeControl? = nil, budget: Int? = nil,
                    _ note: String) -> ProviderEffortResolution {
            settings.providerReasoningControl = control
            // Even when a provider has no proven native effort knob, preserve the host-side typed
            // contract: `.none` keeps reasoning disabled, while `.light`/`.deep` leave it enabled.
            // The application record remains `.unsupported`; this does not pretend a native control
            // was applied, but it must not invert the caller's safe default.
            settings.disableThinking = control?.disablesThinking ?? (requested == .none)
            return ProviderEffortResolution(
                settings: settings,
                record: ProviderEffortRecord(providerID: providerID, modelID: modelID,
                                             requested: requested, application: application,
                                             effectiveThinkingBudget: budget,
                                             nativeControl: control, note: note)
            )
        }

        if support.providerManaged.contains(requested) {
            return result(.providerManaged, "provider chooses this reasoning depth; no native level was sent")
        }
        guard support.applied.contains(requested) else {
            return result(.unsupported, "provider/model has no proven native control for this level")
        }

        if provider.contains("gemini") || provider == "google" {
            if model.hasPrefix("gemini-3") {
                let level = requested == .light ? "low" : "high"
                return result(.applied, control: .geminiThinkingLevel(level),
                              "mapped to Gemini thinkingLevel=\(level)")
            }
            switch requested {
            case .none:
                return result(.applied, control: .geminiThinkingBudget(0), budget: 0,
                              "mapped to Gemini thinkingBudget=0")
            case .light, .deep:
                let budget = requested == .light ? 1_024 : 8_192
                settings.thinkingBudget = budget
                return result(.applied, control: .geminiThinkingBudget(budget), budget: budget,
                              "mapped to Gemini thinkingBudget=\(budget)")
            }
        }

        if provider.contains("anthropic") || provider.contains("claude") {
            switch requested {
            case .none:
                return result(.applied, control: .anthropic(thinking: "disabled", effort: nil),
                              "mapped to Anthropic thinking.type=disabled")
            case .light:
                return result(.applied, control: .anthropic(thinking: nil, effort: "low"),
                              "mapped to Anthropic output_config.effort=low")
            case .deep:
                return result(.applied, control: .anthropic(thinking: nil, effort: "high"),
                              "mapped to Anthropic output_config.effort=high")
            }
        }

        if provider == "mimo" {
            return result(.applied, control: .mimoThinking("disabled"),
                          "mapped to MiMo thinking.type=disabled")
        }

        if provider == "openai" {
            let value: String
            switch requested {
            case .none: value = "none"
            case .light: value = "low"
            case .deep: value = "high"
            }
            return result(.applied, control: .openAIReasoningEffort(value),
                          "mapped to OpenAI reasoning_effort=\(value)")
        }

        return result(.unsupported, "provider mapping is unavailable")
    }
}
