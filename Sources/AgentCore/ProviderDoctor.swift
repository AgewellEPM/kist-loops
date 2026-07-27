import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Layer D of the provider-resilience plan: a PREFLIGHT that catches model-id drift before a task hits it.
/// For each keyed provider it fetches the live `GET /models` list and diffs it against the shipped
/// `ProviderCatalog` — surfacing dead/stale ids (e.g. Grok's retired `grok-2-latest`), an invalid default
/// model, and newly-available ids worth adding. The diff is PURE (testable offline); the network fetch is
/// injected. Run it on demand or in CI so the catalog can never silently rot into 404s.
public struct ProviderModelReport: Sendable, Equatable {
    public let providerId: String
    public let reachable: Bool
    public let liveModelIds: [String]
    public let staleCatalogIds: [String]   // shipped in availableModels but NOT live → dead, will 404
    public let defaultIsValid: Bool        // is defaultModel present in the live list?
    public let reasoningModelIds: [String] // live ids that need the reasoning budget floor (Layer A)
    public let newLiveIds: [String]        // live but not in the catalog → candidates to add
    public let error: String?

    public var isHealthy: Bool { reachable && staleCatalogIds.isEmpty && defaultIsValid && error == nil }
}

public enum ProviderDoctor {

    /// The `/models` URL for an OpenAI-compatible chat endpoint (…/chat/completions → …/models).
    public static func modelsEndpoint(for provider: OpenAICompatibleProvider) -> String {
        let e = provider.endpoint
        if let r = e.range(of: "/chat/completions") { return e.replacingCharacters(in: r, with: "/models") }
        if let slash = e.lastIndex(of: "/") { return String(e[..<slash]) + "/models" }
        return e + "/models"
    }

    /// PURE diff: given a provider and the live model ids it reported, compute its health report.
    public static func diff(provider: OpenAICompatibleProvider, liveModelIds: [String]) -> ProviderModelReport {
        let live = Set(liveModelIds)
        let catalogIds = provider.availableModels.map(\.id)
        let stale = catalogIds.filter { !live.contains($0) }
        let known = Set(catalogIds)
        let newIds = liveModelIds.filter { !known.contains($0) }
        let reasoning = liveModelIds.filter { OpenAICompatibleProvider.modelLooksLikeReasoning($0) }
        return ProviderModelReport(providerId: provider.id, reachable: true, liveModelIds: liveModelIds,
                                   staleCatalogIds: stale, defaultIsValid: live.contains(provider.defaultModel),
                                   reasoningModelIds: reasoning, newLiveIds: newIds, error: nil)
    }

    /// A report for a provider that couldn't be reached / had no key.
    public static func unreachable(provider: OpenAICompatibleProvider, error: String) -> ProviderModelReport {
        ProviderModelReport(providerId: provider.id, reachable: false, liveModelIds: [], staleCatalogIds: [],
                            defaultIsValid: false, reasoningModelIds: [], newLiveIds: [], error: error)
    }

    /// Check the given providers. `apiKey` returns nil for providers without a key (skipped honestly, not
    /// reported as broken). `fetch` returns the live model ids for a `/models` URL — injected for tests.
    public static func check(
        providers: [OpenAICompatibleProvider],
        apiKey: @Sendable (OpenAICompatibleProvider) -> String?,
        fetch: @Sendable (_ modelsURL: String, _ apiKey: String?) async -> Result<[String], Error>
    ) async -> [ProviderModelReport] {
        var reports: [ProviderModelReport] = []
        for p in providers {
            // A keyed provider with no key isn't broken — it's just not configured. Skip it.
            if p.requiresAPIKey, apiKey(p) == nil {
                reports.append(unreachable(provider: p, error: "no API key configured"))
                continue
            }
            switch await fetch(modelsEndpoint(for: p), apiKey(p)) {
            case .success(let ids): reports.append(diff(provider: p, liveModelIds: ids))
            case .failure(let e):   reports.append(unreachable(provider: p, error: "\(e)"))
            }
        }
        return reports
    }

    /// The default live fetch: `GET {modelsURL}` with Bearer auth, parsing the OpenAI `{data:[{id}]}` shape.
    public static func liveFetch(modelsURL: String, apiKey: String?, timeout: TimeInterval = 15) async -> Result<[String], Error> {
        guard let url = URL(string: modelsURL) else { return .failure(AIProviderError.configuration("bad models URL")) }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(AIProviderError.http(status: http.statusCode,
                                                     body: String(data: data, encoding: .utf8) ?? ""))
            }
            return .success(parseModelIds(data))
        } catch { return .failure(error) }
    }

    /// Parse `{ "data": [ { "id": "…" } ] }` (OpenAI /models). Tolerant: also accepts a bare `["id", …]`.
    public static func parseModelIds(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let obj = json as? [String: Any], let arr = obj["data"] as? [[String: Any]] {
            return arr.compactMap { $0["id"] as? String }
        }
        if let arr = json as? [String] { return arr }
        return []
    }

    /// Human-readable report. Flags dead ids + invalid defaults loudly; one block per provider.
    public static func render(_ reports: [ProviderModelReport]) -> String {
        guard !reports.isEmpty else { return "No providers to check." }
        var out = "Provider doctor — \(reports.count) provider(s)\n"
        for r in reports.sorted(by: { $0.providerId < $1.providerId }) {
            // Distinguish "no key configured" (skipped — expected) from a real fetch error (unreachable).
            let badge: String
            if !r.reachable {
                badge = (r.error?.contains("no API key") ?? false) ? "⬜️ skipped" : "🔌 unreachable"
            } else {
                badge = r.isHealthy ? "✅ healthy" : "⚠️ drift"
            }
            out += "\n\(badge)  \(r.providerId)\n"
            if let error = r.error { out += "   \(error)\n"; continue }
            if !r.defaultIsValid { out += "   ❌ default model not in live list — calls will 404\n" }
            if !r.staleCatalogIds.isEmpty { out += "   ❌ dead catalog ids (remove): \(r.staleCatalogIds.joined(separator: ", "))\n" }
            if !r.reasoningModelIds.isEmpty { out += "   🧠 reasoning models (budget-floored): \(r.reasoningModelIds.joined(separator: ", "))\n" }
            if !r.newLiveIds.isEmpty { out += "   ➕ new live ids (consider adding): \(r.newLiveIds.prefix(8).joined(separator: ", "))\n" }
        }
        return out
    }
}
