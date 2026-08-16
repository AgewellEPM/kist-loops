import Foundation
import AgentCore

extension KistREPL {
    struct ModelSubstitutionDecision: Equatable {
        var current: ProviderBinding
        var replacement: ProviderBinding
        var reason: String
    }

    static func modelSubstitutionDecision(success: Bool,
                                          summary: String,
                                          trajectory: [ActionRecord],
                                          current: ProviderBinding,
                                          roles: RoleBindings,
                                          providerHasKey: ((String) -> Bool)?,
                                          providerModels: [String: [String]]) -> ModelSubstitutionDecision? {
        guard let reason = modelSubstitutionReason(success: success, summary: summary) else { return nil }
        guard trajectorySafeToReplayForModelSubstitution(trajectory) else { return nil }
        guard let replacement = modelSubstitutionReplacement(current: current,
                                                             roles: roles,
                                                             providerHasKey: providerHasKey,
                                                             providerModels: providerModels)
        else { return nil }
        return ModelSubstitutionDecision(current: current, replacement: replacement, reason: reason)
    }

    static func modelSubstitutionReason(success: Bool, summary: String) -> String? {
        guard !success else { return nil }
        let lower = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return "empty failed turn" }
        guard !looksLikeHardSafetyStop(lower) else { return nil }

        let protocolFailures = [
            "provider error", "bad request", "malformed", "no parseable action",
            "model did not emit", "invalid request", "unknown variant",
            "tool protocol", "rejected the request as malformed"
        ]
        if protocolFailures.contains(where: { lower.contains($0) }) {
            return "provider/protocol failure"
        }

        // "ratelimited" (one word) is how AIProviderError.rateLimited renders in a turn summary
        // ("provider 'gemini' error: rateLimited") — without it the EXACT live failure string was
        // classified as non-transient and no lane ever substituted or cooled the provider down.
        let transientProviderFailures = [
            "429", "rate limit", "rate-limited", "ratelimited", "over quota", "quota exceeded",
            "overloaded", "500", "502", "503", "server error", "internal error",
            "service unavailable"
        ]
        if transientProviderFailures.contains(where: { lower.contains($0) }) {
            return "provider/transient failure"
        }

        let connectivityFailures = [
            "timed out", "timeout", "network", "connection", "could not connect",
            "dns", "host unreachable", "connection reset", "connection refused"
        ]
        if connectivityFailures.contains(where: { lower.contains($0) }) {
            return "provider/connectivity failure"
        }

        let refusalPhrases = [
            "i can't", "i cannot", "i’m unable", "i am unable", "unable to comply",
            "can't comply", "cannot comply", "can't help", "cannot help",
            "i won't", "i will not", "as an ai", "not able to assist",
            "not allowed to", "i must refuse", "i have to refuse", "request is not something i can"
        ]
        if refusalPhrases.contains(where: { lower.contains($0) }) {
            return "model refusal/non-cooperation"
        }

        return nil
    }

    static func trajectorySafeToReplayForModelSubstitution(_ trajectory: [ActionRecord]) -> Bool {
        trajectory.allSatisfy { safeReplayToolsForModelSubstitution.contains($0.tool) }
    }

    private static let safeReplayToolsForModelSubstitution: Set<String> = [
        "read_file", "list_files", "glob_files", "search_code", "ast_grep", "git", "symbols",
        "context_brain", "read_spreadsheet", "query_data", "ask_user", "fetch_url", "web_search"
    ]

    static func modelSubstitutionReplacement(current: ProviderBinding,
                                             roles: RoleBindings,
                                             providerHasKey: ((String) -> Bool)?,
                                             providerModels: [String: [String]]) -> ProviderBinding? {
        let roleCandidates = [AgentRole.coder, .worker, .planner, .critic]
            .map { roles.binding(for: $0) }
        let priorityCandidates = [
            "openai", "deepseek", "gemini", "grok", "mimo", "ollama", "mlx"
        ].map { ProviderBinding(providerId: $0) }

        var seen = Set<String>()
        for candidate in roleCandidates + priorityCandidates {
            let key = candidate.providerId.lowercased() + ":" + (candidate.model ?? "")
            guard seen.insert(key).inserted else { continue }
            guard candidate.providerId.lowercased() != current.providerId.lowercased() else { continue }
            guard providerHasKey?(candidate.providerId) ?? true else { continue }
            if !providerModels.isEmpty, providerModels[candidate.providerId.lowercased()] == nil {
                continue
            }
            return candidate
        }
        return nil
    }

    /// True when a failed turn's summary shows a LIVE provider failure that clears with time
    /// (rate limit / outage / connectivity) — the only reasons that cool a provider down
    /// cross-process. Protocol failures and refusals are the model's fault, not the wire's,
    /// and stay with the scorecard.
    static func transientProviderFailure(summary: String) -> Bool {
        let reason = modelSubstitutionReason(success: false, summary: summary)
        return reason == "provider/transient failure" || reason == "provider/connectivity failure"
    }

    /// Media-turn provider pick: first vision candidate NOT in live cooldown; fail-open to the
    /// preferred engine when everything vision-capable is cooling (the cooldown store may only
    /// reduce eagerness, never block the last resort). Gemini-only attachments (video/audio,
    /// Files-API refs) restrict the pool to gemini.
    static func chooseVisionProvider(candidates: [String], mustUseGemini: Bool,
                                     coolingDown: (String) -> Bool) -> String? {
        let pool = mustUseGemini ? candidates.filter { $0.lowercased() == "gemini" } : candidates
        return pool.first { !coolingDown($0) } ?? pool.first
    }

    struct MediaSubstitutionDecision: Equatable {
        var replacement: String
        var reason: String
    }

    /// Substitution for a FAILED media turn — parity with the text-turn lane (same failure
    /// classification + safe-replay gate), but the replacement must come from the VISION lane
    /// and never be the provider that just failed or one already cooling down.
    static func mediaSubstitutionDecision(success: Bool, summary: String,
                                          trajectory: [ActionRecord],
                                          failedProviderId: String,
                                          candidates: [String], mustUseGemini: Bool,
                                          coolingDown: (String) -> Bool) -> MediaSubstitutionDecision? {
        guard let reason = modelSubstitutionReason(success: success, summary: summary) else { return nil }
        guard trajectorySafeToReplayForModelSubstitution(trajectory) else { return nil }
        let pool = mustUseGemini ? candidates.filter { $0.lowercased() == "gemini" } : candidates
        guard let next = pool.first(where: {
            $0.lowercased() != failedProviderId.lowercased() && !coolingDown($0)
        }) else { return nil }
        return MediaSubstitutionDecision(replacement: next, reason: reason)
    }

    private static func looksLikeHardSafetyStop(_ lower: String) -> Bool {
        let refusalish = lower.contains("can't")
            || lower.contains("cannot")
            || lower.contains("unable")
            || lower.contains("refuse")
            || lower.contains("not allowed")
        guard refusalish else { return false }
        let hardSafetySignals = [
            "malware", "phishing", "credential theft", "steal credentials", "ransomware",
            "exploit a real target", "weapon", "bomb", "biological", "terrorist",
            "child sexual", "sexual content involving minors", "self-harm", "suicide"
        ]
        return hardSafetySignals.contains { lower.contains($0) }
    }
}
