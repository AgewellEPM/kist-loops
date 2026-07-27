import Foundation
import Combine

final class ProviderManager: ObservableObject {
    static let shared = ProviderManager()

    @Published var currentProvider: any AIProvider
    @Published var availableProviders: [any AIProvider]

    // Use Keychain for secure API key storage
    private let keychain = KeychainService.shared

    private init() {
        let providers: [any AIProvider] = [
            AnthropicProvider(),
            OpenAIProvider(),
            GeminiProvider(),
            MoonshotProvider(),
            ZhipuProvider(),
            MiMoProvider(),
            DeepSeekProvider(),
            GrokProvider(),
            OllamaProvider(),
            MLXProvider()
        ]

        self.availableProviders = providers

        // Migrate any existing keys from UserDefaults to Keychain
        keychain.migrateFromUserDefaults()

        // Restore last used provider or default to first
        let lastProviderId = UserDefaults.standard.string(forKey: "last_provider_id")
        let defaultProvider = providers.first ?? AnthropicProvider()

        if let providerId = lastProviderId,
           let provider = providers.first(where: { $0.id == providerId }) {
            self.currentProvider = provider
        } else {
            self.currentProvider = defaultProvider
        }
    }

    func selectProvider(id: String) {
        if let provider = availableProviders.first(where: { $0.id == id }) {
            currentProvider = provider
            UserDefaults.standard.set(id, forKey: "last_provider_id")
        }
    }

    // MARK: - API Key Management (now using Keychain)

    func setAPIKey(_ key: String, for provider: any AIProvider) {
        guard provider.requiresAPIKey else { return }

        if key.isEmpty {
            // Delete the key
            try? keychain.delete(key: provider.apiKeySettingKey)
        } else {
            // Save the key
            try? keychain.save(key: provider.apiKeySettingKey, value: key)
        }

        // Notify observers that the provider state may have changed
        objectWillChange.send()
    }

    func getAPIKey(for provider: any AIProvider) -> String {
        guard provider.requiresAPIKey else { return "" }
        return keychain.get(key: provider.apiKeySettingKey) ?? ""
    }

    func hasAPIKey(for provider: any AIProvider) -> Bool {
        guard provider.requiresAPIKey else { return true }
        return keychain.exists(key: provider.apiKeySettingKey)
    }

    // MARK: - Provider Info

    func provider(withId id: String) -> (any AIProvider)? {
        availableProviders.first(where: { $0.id == id })
    }

    var cloudProviders: [any AIProvider] {
        availableProviders.filter { $0.requiresAPIKey }
    }

    var localProviders: [any AIProvider] {
        availableProviders.filter { !$0.requiresAPIKey }
    }
}
