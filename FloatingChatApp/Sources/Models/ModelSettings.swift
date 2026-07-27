import Foundation

/// Model parameters that can be adjusted per provider
struct ModelSettings: Codable, Equatable {
    var temperature: Double = 0.7
    var topP: Double = 0.9
    var topK: Int = 40
    var maxTokens: Int = 2048
    var frequencyPenalty: Double = 0.0
    var presencePenalty: Double = 0.0
    var repeatPenalty: Double = 1.1
    var seed: Int? = nil
    var streamResponses: Bool = true
    var systemPrompt: String = "You are a helpful AI assistant."

    // Parameter ranges for UI
    static let temperatureRange: ClosedRange<Double> = 0.0...2.0
    static let topPRange: ClosedRange<Double> = 0.0...1.0
    static let topKRange: ClosedRange<Int> = 1...100
    static let maxTokensRange: ClosedRange<Int> = 256...8192
    static let frequencyPenaltyRange: ClosedRange<Double> = -2.0...2.0
    static let presencePenaltyRange: ClosedRange<Double> = -2.0...2.0
    static let repeatPenaltyRange: ClosedRange<Double> = 1.0...2.0

    static let `default` = ModelSettings()
}

/// System prompt presets
struct SystemPromptPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var prompt: String
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, prompt: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.isBuiltIn = isBuiltIn
    }

    static let builtInPresets: [SystemPromptPreset] = [
        SystemPromptPreset(
            name: "Default Assistant",
            prompt: "You are a helpful AI assistant. Be concise and accurate in your responses.",
            isBuiltIn: true
        ),
        SystemPromptPreset(
            name: "Code Expert",
            prompt: "You are an expert programmer. Write clean, efficient, well-documented code. Explain your reasoning when asked.",
            isBuiltIn: true
        ),
        SystemPromptPreset(
            name: "Creative Writer",
            prompt: "You are a creative writer with a vivid imagination. Write engaging, descriptive prose with rich details.",
            isBuiltIn: true
        ),
        SystemPromptPreset(
            name: "Analyst",
            prompt: "You are a data analyst. Provide detailed, structured analysis. Use bullet points and clear formatting.",
            isBuiltIn: true
        ),
        SystemPromptPreset(
            name: "Concise",
            prompt: "Be extremely concise. Answer in as few words as possible while being accurate.",
            isBuiltIn: true
        )
    ]
}

/// Manages model settings persistence
@MainActor
final class ModelSettingsManager: ObservableObject {
    static let shared = ModelSettingsManager()

    @Published var globalSettings: ModelSettings {
        didSet { saveSettings() }
    }

    @Published var customPresets: [SystemPromptPreset] {
        didSet { savePresets() }
    }

    @Published var selectedPresetId: UUID? {
        didSet {
            // Defer any additional publishes to avoid publishing during a view update cycle
            if let preset = allPresets.first(where: { $0.id == selectedPresetId }) {
                DispatchQueue.main.async { [weak self] in
                    self?.globalSettings.systemPrompt = preset.prompt
                }
            }
            UserDefaults.standard.set(selectedPresetId?.uuidString, forKey: "selected_preset_id")
        }
    }

    var allPresets: [SystemPromptPreset] {
        SystemPromptPreset.builtInPresets + customPresets
    }

    private init() {
        // Load settings
        if let data = UserDefaults.standard.data(forKey: "model_settings"),
           let settings = try? JSONDecoder().decode(ModelSettings.self, from: data) {
            self.globalSettings = settings
        } else {
            self.globalSettings = .default
        }

        // Load custom presets
        if let data = UserDefaults.standard.data(forKey: "custom_presets"),
           let presets = try? JSONDecoder().decode([SystemPromptPreset].self, from: data) {
            self.customPresets = presets
        } else {
            self.customPresets = []
        }

        // Load selected preset
        if let idString = UserDefaults.standard.string(forKey: "selected_preset_id"),
           let id = UUID(uuidString: idString) {
            self.selectedPresetId = id
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(globalSettings) {
            UserDefaults.standard.set(data, forKey: "model_settings")
        }
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(data, forKey: "custom_presets")
        }
    }

    func addCustomPreset(name: String, prompt: String) {
        let preset = SystemPromptPreset(name: name, prompt: prompt, isBuiltIn: false)
        customPresets.append(preset)
    }

    func deletePreset(_ preset: SystemPromptPreset) {
        guard !preset.isBuiltIn else { return }
        customPresets.removeAll { $0.id == preset.id }
    }

    func resetToDefaults() {
        globalSettings = .default
        selectedPresetId = SystemPromptPreset.builtInPresets.first?.id
    }
}
