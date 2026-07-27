import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `/model import <url>` — the URL-first model importer. You point it at any OpenAI-compatible base URL;
/// it hits `GET /models` to DISCOVER the available models (no manual typing), lets you pick the default,
/// takes the API key, then runs the same self-heal/self-test/pen-test install as `/model add` (via
/// `ModelInstall`). After it saves, the provider's models show GREEN in the picker on next launch; a
/// provider you never keyed shows RED. Pure URL helpers are unit-tested; the flow itself is interactive.
enum ImportModelWizard {
    private static func out(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    private static func prompt(_ s: String) -> String? {
        FileHandle.standardError.write(Data(s.utf8))
        return readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func readHiddenKey(_ p: String) -> String {
        if let c = getpass(p) { return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines) }
        return prompt(p) ?? ""
    }

    /// Run the importer. `initialURL` comes from `/model import <url>`; nil ⇒ prompt for it. Returns the
    /// onboarded provider id, or nil on cancel/failure.
    static func run(url initialURL: String?) async -> String? {
        out("\n── Import a model by URL (any OpenAI-compatible API) ─────────────")

        // 1. base URL
        let rawURL: String
        if let u = initialURL, !u.isEmpty { rawURL = u; out("  url: \(u)") }
        else {
            guard let u = prompt("model API base URL (e.g. https://api.together.xyz/v1): "), !u.isEmpty else {
                out("cancelled."); return nil
            }
            rawURL = u
        }
        let modelsURL = modelsEndpoint(fromBase: rawURL)
        let chatEndpoint = AddModelFlow.normalizeEndpoint(rawURL)
        if chatEndpoint.hasPrefix("http://"), !chatEndpoint.contains("localhost"), !chatEndpoint.contains("127.0.0.1") {
            out("  ! warning: plaintext http to a remote host — your key will be sent unencrypted.")
        }

        // 2. discover models — try without a key; if that fails (auth/unreachable), take the key and retry.
        out("  → discovering models at \(modelsURL) …")
        var key = ""
        var discovered = await discover(modelsURL: modelsURL, key: nil) ?? []
        if discovered.isEmpty {
            out("  · couldn't list models unauthenticated — add a key to discover (or skip to enter one manually).")
            key = readHiddenKey("API key (input hidden, blank to skip discovery): ")
            if !key.isEmpty { discovered = await discover(modelsURL: modelsURL, key: key) ?? [] }
        }

        if !discovered.isEmpty {
            out("  ✓ found \(discovered.count) model(s):")
            for (i, m) in discovered.prefix(40).enumerated() { out("     \(i + 1). \(m)") }
            if discovered.count > 40 { out("     … +\(discovered.count - 40) more") }
        } else {
            out("  · no models auto-discovered — enter one manually.")
        }

        // 3. choose the default model
        let defaultModel: String
        if discovered.isEmpty {
            guard let m = prompt("model id (e.g. 'meta-llama/Llama-3-70b'): "), !m.isEmpty else { out("cancelled."); return nil }
            defaultModel = m
            discovered = [m]
        } else {
            let pick = prompt("default model number [1]: ") ?? ""
            if pick.isEmpty { defaultModel = discovered[0] }
            else if let n = Int(pick), n >= 1, n <= discovered.count { defaultModel = discovered[n - 1] }
            else if discovered.contains(pick) { defaultModel = pick }
            else { defaultModel = discovered[0]; out("  · '\(pick)' not in the list — using \(defaultModel)") }
        }

        // 4. id + display name
        let suggested = suggestedId(fromURL: rawURL)
        let id = (prompt("short id [\(suggested)]: ").flatMap { $0.isEmpty ? nil : $0 } ?? suggested).lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        guard !id.isEmpty, id.allSatisfy({ allowed.contains($0) }) else {
            out("error: id may only contain ASCII letters, numbers, '_' or '-'."); return nil
        }
        guard CustomProviderStore.isIdAvailable(id) else {
            out("error: '\(id)' is already taken (built-in or custom). Re-run and pick another."); return nil
        }
        let name = prompt("display name [\(id)]: ").flatMap { $0.isEmpty ? nil : $0 } ?? id
        let reservedNames = Set(ProviderCatalog.all.flatMap { [$0.id.lowercased(), $0.name.lowercased()] })
        if reservedNames.contains(name.lowercased()) {
            out("error: display name '\(name)' collides with a built-in provider. Pick another."); return nil
        }

        // 5. API key (reuse the one captured during discovery, if any)
        if key.isEmpty {
            key = readHiddenKey("API key (input hidden, blank for a local/no-key server): ")
        }
        let isLocal = key.isEmpty && (chatEndpoint.contains("localhost") || chatEndpoint.contains("127.0.0.1"))
        let requiresKey = !key.isEmpty

        // 6. onboard + persist — ALL discovered models registered under this provider; chosen default.
        let keyAccount = SecretWriter.keyAccount(forCustomId: id)
        let models = discovered.map { AIModel(id: $0) }
        let draft = OpenAICompatibleProvider(
            id: id, name: name, iconName: "plus.app", keyAccount: keyAccount,
            endpoint: chatEndpoint, defaultModel: defaultModel,
            availableModels: models.isEmpty ? [AIModel(id: defaultModel)] : models,
            requiresAPIKey: requiresKey, isLocal: isLocal, nativeToolsSupported: true)

        guard let installed = await ModelInstall.onboardAndPersist(
            draft: draft, key: key, requiresKey: requiresKey, emit: { out($0) }) else { return nil }
        out(installed.message)
        out("  ↳ \(discovered.count) model(s) registered under '\(id)'. Restart kist to see them (green) in /model.")
        return installed.id
    }

    private static func discover(modelsURL: String, key: String?) async -> [String]? {
        switch await ProviderDoctor.liveFetch(modelsURL: modelsURL, apiKey: key) {
        case .success(let ids): return ids.sorted()
        case .failure: return nil
        }
    }

    // MARK: - pure helpers (unit-tested)

    /// Turn a base URL into a `GET /models` URL, tolerating the common shapes.
    static func modelsEndpoint(fromBase raw: String) -> String {
        var u = raw.trimmingCharacters(in: .whitespaces)
        while u.hasSuffix("/") { u.removeLast() }
        if u.hasSuffix("/models") { return u }
        if u.contains("/chat/completions") { return u.replacingOccurrences(of: "/chat/completions", with: "/models") }
        if u.hasSuffix("/v1") || u.range(of: "/v[0-9]+$", options: .regularExpression) != nil { return u + "/models" }
        return u + "/v1/models"
    }

    /// Suggest a short provider id from a URL's host: `https://api.together.xyz/v1` → "together".
    static func suggestedId(fromURL raw: String) -> String {
        var host = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let r = host.range(of: "://") { host = String(host[r.upperBound...]) }
        host = host.split(whereSeparator: { $0 == "/" || $0 == ":" }).first.map(String.init) ?? host
        if host.isEmpty { return "custom" }
        if host == "localhost" || host.hasPrefix("127.") { return "local" }
        var parts = host.split(separator: ".").map(String.init)
        while let f = parts.first, f == "api" || f == "www", parts.count > 1 { parts.removeFirst() }
        if parts.count > 1 { parts.removeLast() }                       // drop the TLD
        let candidate = parts.last ?? parts.first ?? "custom"
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let slug = String(candidate.filter { allowed.contains($0) })
        return slug.isEmpty ? "custom" : slug
    }
}
