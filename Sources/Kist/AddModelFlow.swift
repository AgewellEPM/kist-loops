import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Interactive "Add a model" flow for the kist startup menu. Prompts for the few things a new
/// OpenAI-compatible model needs, then hands off to `ModelOnboarding` which self-heals the model
/// id, self-tests completion, pen-tests the agent-loop grip + decision-making, auto-detects native
/// tools, and auto-configures everything. Persists only when the verdict isn't FAIL.
enum AddModelFlow {
    private static func out(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    private static func prompt(_ s: String) -> String? {
        FileHandle.standardError.write(Data(s.utf8))
        return readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run the flow. Returns the onboarded provider id (to offer for selection this session), or nil.
    static func run() async -> String? {
        out("\n── Add a model (any OpenAI-compatible API) ─────────────────────")

        // 1. id (unique, slug)
        guard let rawId = prompt("short id (e.g. 'together', 'fireworks'): "), !rawId.isEmpty else {
            out("cancelled."); return nil
        }
        let id = rawId.lowercased()
        // ASCII-only [a-z0-9_-] — reject Unicode homoglyphs that could visually mimic a built-in id.
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        guard !id.isEmpty, id.allSatisfy({ allowed.contains($0) }) else {
            out("error: id may only contain ASCII letters, numbers, '_' or '-'."); return nil
        }
        guard CustomProviderStore.isIdAvailable(id) else {
            out("error: '\(id)' is already taken (built-in or custom). Pick another."); return nil
        }

        // 2. display name
        let name = prompt("display name [\(id)]: ").flatMap { $0.isEmpty ? nil : $0 } ?? id
        // The registry resolves a provider by id OR by lowercased name, so a name equal to a built-in
        // id/name would shadow it. Reject case-insensitive collisions.
        let reservedNames = Set(ProviderCatalog.all.flatMap { [$0.id.lowercased(), $0.name.lowercased()] })
        if reservedNames.contains(name.lowercased()) {
            out("error: display name '\(name)' collides with a built-in provider. Pick another."); return nil
        }

        // 3. base URL -> endpoint
        guard let rawURL = prompt("base URL (e.g. https://api.together.xyz/v1): "), !rawURL.isEmpty else {
            out("cancelled."); return nil
        }
        let endpoint = normalizeEndpoint(rawURL)
        out("  → endpoint: \(endpoint)")
        if endpoint.hasPrefix("http://"), !endpoint.contains("localhost"), !endpoint.contains("127.0.0.1") {
            out("  ! warning: plaintext http to a remote host — your key will be sent unencrypted.")
        }

        // 4. model id
        guard let model = prompt("model id (e.g. 'meta-llama/Llama-3-70b'): "), !model.isEmpty else {
            out("cancelled."); return nil
        }

        // 5. API key (hidden input; empty = local/no-key server)
        let key = readHiddenKey("API key (input hidden, blank for a local/no-key server): ")
        let isLocal = key.isEmpty && (endpoint.contains("localhost") || endpoint.contains("127.0.0.1"))
        let requiresKey = !key.isEmpty
        let keyAccount = SecretWriter.keyAccount(forCustomId: id)

        // Draft provider — native tools assumed true; onboarding will verify empirically.
        let draft = OpenAICompatibleProvider(
            id: id, name: name, iconName: "plus.app", keyAccount: keyAccount,
            endpoint: endpoint, defaultModel: model, availableModels: [AIModel(id: model)],
            requiresAPIKey: requiresKey, isLocal: isLocal, nativeToolsSupported: true)

        // Onboard + persist via the shared installer (self-heal · self-test · pen-test · save).
        guard let installed = await ModelInstall.onboardAndPersist(
            draft: draft, key: key, requiresKey: requiresKey, emit: { out($0) }) else { return nil }
        out(installed.message)
        return installed.id
    }

    // MARK: helpers

    /// Turn a base URL into a chat/completions endpoint, tolerating common shapes.
    static func normalizeEndpoint(_ raw: String) -> String {
        var u = raw.trimmingCharacters(in: .whitespaces)
        while u.hasSuffix("/") { u.removeLast() }
        if u.contains("/chat/completions") { return u }
        if u.hasSuffix("/v1") || u.range(of: "/v[0-9]+$", options: .regularExpression) != nil {
            return u + "/chat/completions"
        }
        return u + "/v1/chat/completions"
    }

    /// Read a secret without echoing it. Falls back to a visible readLine if no TTY.
    static func readHiddenKey(_ promptText: String) -> String {
        if let c = getpass(promptText) {
            return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prompt(promptText) ?? ""
    }
}
