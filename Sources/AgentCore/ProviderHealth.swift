import Foundation

public enum ProviderHealthState: String, Sendable, Codable, Equatable {
    case ready
    case missingKey
    case staleCatalog
    case failed
    /// Key + catalog are fine, but a LIVE failure (rate limit / outage) was observed recently
    /// by some kist process — the router is sitting this provider out until the cooldown ends.
    /// Distinct from `failed`: it self-recovers and must not fail the health exit code.
    case cooling
}

public struct ProviderHealthRow: Sendable, Equatable {
    public let providerId: String
    public let model: String
    public let state: ProviderHealthState
    public let toolMode: ToolMode
    public let detail: String

    public init(providerId: String, model: String, state: ProviderHealthState,
                toolMode: ToolMode, detail: String) {
        self.providerId = providerId
        self.model = model
        self.state = state
        self.toolMode = toolMode
        self.detail = detail
    }
}

public struct ProviderHealthReport: Sendable, Equatable {
    public let rows: [ProviderHealthRow]

    public init(rows: [ProviderHealthRow]) {
        self.rows = rows
    }

    public var readyCount: Int { rows.filter { $0.state == .ready }.count }
    public var failedCount: Int { rows.count - readyCount }

    public func render() -> String {
        guard !rows.isEmpty else { return "provider health: no providers configured" }
        var out = "provider health · \(readyCount)/\(rows.count) ready\n"
        for row in rows.sorted(by: { $0.providerId < $1.providerId }) {
            let icon: String
            switch row.state {
            case .ready: icon = "✓"
            case .missingKey: icon = "!"
            case .staleCatalog: icon = "?"
            case .failed: icon = "✗"
            case .cooling: icon = "~"
            }
            out += "\(icon) \(row.providerId):\(row.model) · \(row.toolMode.rawValue) · \(row.detail)\n"
        }
        return out.trimmingCharacters(in: .newlines)
    }
}

public enum ProviderHealthChecker {
    public static let defaultLiveProbeTimeoutNanoseconds: UInt64 = 120_000_000_000

    /// `coolingDown` is the cross-process live-failure ledger (ProviderCooldownStore). Without it
    /// `--health` said "ready" while a provider was actively rate-limiting every lane — health must
    /// report keys AND the live state other kist processes just observed.
    public static func catalogReport(_ registry: ProviderRegistry,
                                     coolingDown: ((String) -> Bool)? = nil) -> ProviderHealthReport {
        ProviderHealthReport(rows: registry.providers.map { provider in
            let model = provider.defaultModel
            let listed = provider.availableModels.contains { $0.id == model || $0.name == model }
            let hasKey = registry.hasKey(for: provider)
            let caps = provider.capabilities(forModel: model)
            let mode: ToolMode = caps.nativeTools ? .native : .text
            if !hasKey {
                return ProviderHealthRow(providerId: provider.id, model: model, state: .missingKey,
                                         toolMode: mode, detail: "API key missing")
            }
            if !listed {
                return ProviderHealthRow(providerId: provider.id, model: model, state: .staleCatalog,
                                         toolMode: mode, detail: "default model is not in availableModels")
            }
            if coolingDown?(provider.id) == true {
                return ProviderHealthRow(providerId: provider.id, model: model, state: .cooling,
                                         toolMode: mode,
                                         detail: "recent live rate-limit/outage — cooling down, auto-recovers")
            }
            return ProviderHealthRow(providerId: provider.id, model: model, state: .ready,
                                     toolMode: mode, detail: caps.summaryFlags.joined(separator: ", "))
        })
    }

    public static func liveProbe(_ registry: ProviderRegistry,
                                 bindings: [ProviderBinding],
                                 maxTokens: Int = 4,
                                 timeoutNanoseconds: UInt64 = defaultLiveProbeTimeoutNanoseconds) async -> ProviderHealthReport {
        var immediateRows: [ProviderHealthRow] = []
        var targets: [LiveProbeTarget] = []
        for binding in bindings {
            guard let provider = registry.provider(id: binding.providerId) else {
                immediateRows.append(ProviderHealthRow(providerId: binding.providerId,
                                                       model: binding.model ?? "(default)",
                                                       state: .failed, toolMode: .text,
                                                       detail: "unknown provider"))
                continue
            }
            let model = provider.resolvedModel(binding.model)
            let caps = registry.capabilities(providerId: provider.id, model: model)
            let mode: ToolMode = caps.nativeTools ? .native : .text
            let apiKey = provider.requiresAPIKey ? registry.apiKey(forProviderId: provider.id) : nil
            guard !provider.requiresAPIKey || apiKey != nil else {
                immediateRows.append(ProviderHealthRow(providerId: provider.id, model: model,
                                                       state: .missingKey, toolMode: mode,
                                                       detail: "API key missing"))
                continue
            }
            targets.append(LiveProbeTarget(provider: provider, model: model, caps: caps, mode: mode, apiKey: apiKey))
        }
        let rows = await withTaskGroup(of: ProviderHealthRow.self) { group in
            for target in targets {
                group.addTask {
                    await liveProbeRow(target, maxTokens: maxTokens, timeoutNanoseconds: timeoutNanoseconds)
                }
            }
            var rows: [ProviderHealthRow] = []
            for await row in group { rows.append(row) }
            return rows
        }
        return ProviderHealthReport(rows: immediateRows + rows)
    }

    private struct LiveProbeTarget: Sendable {
        let provider: any ChatProvider
        let model: String
        let caps: ModelCapabilities
        let mode: ToolMode
        let apiKey: String?
    }

    private static func liveProbeRow(_ target: LiveProbeTarget,
                                     maxTokens: Int,
                                     timeoutNanoseconds: UInt64) async -> ProviderHealthRow {
        await withTaskGroup(of: ProviderHealthRow.self) { group in
            group.addTask {
                await probeProviderWithExpandedRetry(target, maxTokens: maxTokens)
            }
            group.addTask {
                if timeoutNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                }
                return ProviderHealthRow(providerId: target.provider.id, model: target.model,
                                         state: .failed, toolMode: target.mode,
                                         detail: "live probe timed out after \(timeoutNanoseconds / 1_000_000_000)s")
            }
            let row = await group.next() ?? ProviderHealthRow(providerId: target.provider.id, model: target.model,
                                                              state: .failed, toolMode: target.mode,
                                                              detail: "live probe cancelled")
            group.cancelAll()
            return row
        }
    }

    private static func probeProviderWithExpandedRetry(_ target: LiveProbeTarget,
                                                       maxTokens: Int) async -> ProviderHealthRow {
        do {
            return try await Self.probeProvider(target, maxTokens: maxTokens,
                                                expanded: false)
        } catch {
            if Self.emptyCompletionError(error), maxTokens < 128 {
                do {
                    return try await Self.probeProvider(target, maxTokens: 128, expanded: true)
                } catch {
                    return ProviderHealthRow(providerId: target.provider.id, model: target.model,
                                             state: Self.staleModelError(error) ? .staleCatalog : .failed,
                                             toolMode: target.mode,
                                             detail: "\(error)")
                }
            }
            return ProviderHealthRow(providerId: target.provider.id, model: target.model,
                                     state: Self.staleModelError(error) ? .staleCatalog : .failed,
                                     toolMode: target.mode,
                                     detail: "\(error)")
        }
    }

    private static func probeProvider(_ target: LiveProbeTarget,
                                      maxTokens: Int,
                                      expanded: Bool) async throws -> ProviderHealthRow {
        let messages = [ChatMessage(role: .user, content: "Reply with exactly: OK")]
        let settings = ModelSettings(temperature: 0, maxTokens: maxTokens, disableThinking: true)
        let stream = try await target.provider.stream(messages: messages, model: target.model,
                                                      settings: settings, apiKey: target.apiKey)
        var text = ""
        for try await event in stream {
            if case .delta(let delta) = event { text += delta }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIProviderError.transport("empty completion from \(target.provider.id):\(target.model)")
        }
        let ok = Self.exactOK(trimmed)
        let capLine = target.caps.summaryFlags.joined(separator: ", ")
        let budgetNote = expanded ? " after expanded probe budget" : ""
        let detail = ok ? "live probe OK\(budgetNote) · \(capLine)" :
            "live probe reached provider\(budgetNote) (non-OK response: \(String(trimmed.prefix(80)))) · \(capLine)"
        return ProviderHealthRow(providerId: target.provider.id, model: target.model,
                                 state: .ready, toolMode: target.mode,
                                 detail: detail)
    }

    private static func emptyCompletionError(_ error: Error) -> Bool {
        if case .transport(let message) = error as? AIProviderError {
            return message.localizedCaseInsensitiveContains("empty completion")
        }
        return "\(error)".localizedCaseInsensitiveContains("empty completion")
    }

    private static func exactOK(_ text: String) -> Bool {
        text.range(of: #"(?i)^\s*ok[.!]?\s*$"#, options: .regularExpression) != nil
    }

    static func staleModelError(_ error: Error) -> Bool {
        guard let providerError = error as? AIProviderError else { return false }
        if case .http(let status, let body) = providerError {
            return status == 404 || body.lowercased().contains("model") && body.lowercased().contains("does not exist")
        }
        if case .configuration(let msg) = providerError {
            return msg.lowercased().contains("unknown provider") || msg.lowercased().contains("model")
        }
        return false
    }
}

public enum ModelRouter {
    /// Conservative provider fallbacks. The primary still gets first attempt; these only run when
    /// the provider/model/key/network is unavailable. Bad request / malformed transcript errors do
    /// not fall through, because fallback must not hide runtime bugs.
    public static let defaultFallbackProviderIds: [String: [String]] = [
        "grok": ["openai", "gemini", "deepseek", "mimo", "ollama", "mlx"],
        "openai": ["gemini", "deepseek", "mimo", "ollama", "mlx"],
        "gemini": ["openai", "deepseek", "mimo", "ollama", "mlx"],
        "deepseek": ["mimo", "openai", "gemini", "ollama", "mlx"],
        "mimo": ["deepseek", "openai", "gemini", "ollama", "mlx"],
        "anthropic": ["openai", "gemini", "deepseek", "mimo", "ollama", "mlx"],
        "qwen": ["deepseek", "mimo", "openai", "gemini", "ollama", "mlx"],
        "zhipu": ["deepseek", "mimo", "openai", "gemini", "ollama", "mlx"],
        "moonshot": ["deepseek", "mimo", "openai", "gemini", "ollama", "mlx"],
    ]

    public static func bestEffortRoles(default binding: ProviderBinding,
                                       registry: ProviderRegistry) -> RoleBindings {
        var roles = RoleBindings(default: binding)
        func firstAvailable(_ ids: [String]) -> ProviderBinding? {
            for id in ids {
                guard let provider = registry.provider(id: id), registry.hasKey(for: provider) else { continue }
                return ProviderBinding(providerId: provider.id)
            }
            return nil
        }
        if let planner = firstAvailable(["gemini", "openai", "deepseek", "mimo"]) {
            roles = roles.binding(.planner, to: planner)
        }
        if let worker = firstAvailable(["deepseek", "mimo", "qwen", "ollama", "mlx"]) {
            roles = roles.binding(.worker, to: worker)
        }
        if let coder = firstAvailable(["deepseek", "mimo", "qwen", "openai", "ollama", "mlx"]) {
            roles = roles.binding(.coder, to: coder)
        }
        if let critic = firstAvailable(["gemini", "openai", "anthropic", "deepseek"]) {
            roles = roles.binding(.critic, to: critic)
        }
        return roles
    }
}
