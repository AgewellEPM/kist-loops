import Foundation
import AgentCore

/// The shared tail of onboarding a model: given a draft OpenAI-compatible provider + its key, run the
/// full self-heal / self-test / pen-test (`ModelOnboarding`) against a registry that has the unsaved key
/// overlaid, and persist the provider + key only when the verdict isn't FAIL. Both `/model add`
/// (AddModelFlow) and `/model import` (ImportModelWizard) route through here so their "install all the
/// loops" behavior can never drift apart.
enum ModelInstall {
    struct Installed { let id: String; let message: String }

    static func onboardAndPersist(draft: OpenAICompatibleProvider,
                                  key: String,
                                  requiresKey: Bool,
                                  emit: (String) -> Void) async -> Installed? {
        let keyAccount = draft.keyAccount
        // Registry for onboarding: built-ins + existing custom + the draft, with the unsaved key overlaid
        // so probes can authenticate. Existing providers keep their real keys (for the advisory judge).
        let base = DefaultKeyStore.make()
        let overlay = OverlayKeyStore(overlay: requiresKey ? [keyAccount: key] : [:], base: base)
        let others = (ProviderCatalog.all + CustomProviderStore.load()).filter { $0.id != draft.id }
        let registry = ProviderRegistry(providers: others + [draft], keyStore: overlay)

        // Judge = first EXISTING configured cloud model (use already-working models to assess the new one).
        let judgeId = others.first { $0.requiresAPIKey && registry.hasKey(for: $0) }?.id

        emit("\nOnboarding '\(draft.id)' — self-heal · self-test · pen-test (this makes live calls)…\n")
        let result = await ModelOnboarding.run(provider: draft, registry: registry, judgeProviderId: judgeId)
        emit(result.render())

        guard result.verdict != .fail else {
            emit("Not saved — '\(draft.id)' failed onboarding (it can't complete or drive the loop). Fix the URL/key/model and retry.")
            return nil
        }
        do {
            if requiresKey { try SecretWriter.write(account: keyAccount, key: key) }
            try CustomProviderStore.upsert(CustomProviderRecord(provider: result.provider))
        } catch {
            emit("error: onboarding passed but saving failed: \(error)")
            return nil
        }
        let tier = result.verdict == .pass ? "fully enabled (native tools)" : "enabled on the universal text protocol"
        return Installed(id: result.provider.id, message: "Saved '\(result.provider.id)' — \(tier). It's now in your model menu.")
    }
}
