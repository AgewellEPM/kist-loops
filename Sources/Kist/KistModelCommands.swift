import Foundation
import AgentCore

/// Model readiness & onboarding CLI commands — the "flawless loops" + "Drop a Key, Drop a Doc" verbs.
/// Extracted from KistRunner (RED-zone) to keep one responsibility per file: these all answer the same
/// question — "can this model actually run a clean tool loop, and is it ready to use?"
extension KistRunner {

    /// `--gemini-test`: fire one minimal real call at each Gemini client and print a pass/fail table.
    /// Exit code is non-zero if any probe failed, so it works in CI.
    static func runGeminiTest(_ registry: ProviderRegistry) async -> Int32 {
        guard let key = registry.apiKey(forProviderId: "gemini") else {
            err("error: no Gemini key configured. Set it in Settings or export the key, then retry --gemini-test.")
            return 2
        }
        let results = await GeminiCapabilityTest.runAll(GeminiCapabilityTest.probes(geminiKey: key, registry: registry))
        print(GeminiCapabilityTest.render(results))
        return results.allSatisfy { $0.ok } ? 0 : 1
    }

    /// `--probe-model <provider[:model]>`: the canary probe. Drives one model through the EXACT loop path
    /// the agent would (native function-calling or the text protocol) and reports ✓ready / ⚠partial / ✗broken,
    /// so onboarding a new key/model never silently ships a model that can't actually run a tool loop.
    /// Exit: 0 ready, 1 partial, 2 broken / misconfigured (CI-friendly).
    static func runModelProbe(_ spec: String, _ registry: ProviderRegistry) async -> Int32 {
        guard let binding = ProviderBinding.parse(spec), let provider = registry.provider(id: binding.providerId) else {
            err("error: unknown provider '\(spec)'. Use `--list-providers` to see configured ids (or `provider:model`).")
            return 2
        }
        if provider.requiresAPIKey && !registry.hasKey(for: provider) {
            err("error: no key configured for '\(provider.id)'. Set it in Settings (or export the key), then retry.")
            return 2
        }
        let report = await ModelLoopProbe.probe(registry: registry, providerId: provider.id, model: binding.model)
        print(ModelLoopProbe.render(report))
        switch report.readiness { case .ready: return 0; case .partial: return 1; case .broken: return 2 }
    }

    /// `--onboard <provider[:model]> [--onboard-doc <path>]`: the "Drop a Key, Drop a Doc" verify step.
    /// Reads the local template if a doc is given, drives the model through a real tool loop, and prints
    /// one verdict. Exit: 0 ready, 1 partial, 2 broken / misconfigured.
    static func runOnboard(_ spec: String, doc: String?, _ registry: ProviderRegistry) async -> Int32 {
        guard let binding = ProviderBinding.parse(spec), let provider = registry.provider(id: binding.providerId) else {
            err("error: unknown provider '\(spec)'. Use `--list-providers` to see configured ids (or `provider:model`).")
            return 2
        }
        if provider.requiresAPIKey && !registry.hasKey(for: provider) {
            err("error: no key configured for '\(provider.id)'. Drop the key in Settings (or export it), then retry.")
            return 2
        }
        let report = await ModelLoopVerify.onboard(registry: registry, providerId: provider.id,
                                                   model: binding.model, docPath: doc)
        print(ModelLoopVerify.render(report))
        // A dropped doc that couldn't be read is a hard failure even if the probe itself passed.
        if report.docError != nil { return 2 }
        // CONFIGURE half of Drop-a-Doc: persist the verified template so future runs of this model inject
        // its stop sequences automatically (the agent loop reads the same store).
        if let template = report.template {
            let saved = LocalModelProfileStore.default().record(providerId: provider.id, model: binding.model,
                                                                template: template, verifiedReady: report.ready)
            if saved, !template.stopSequences.isEmpty {
                note("✓ saved \(template.family.displayName) profile — future runs of \(provider.id)\(binding.model.map { ":\($0)" } ?? "") will stop on \(template.stopSequences.joined(separator: " "))")
            }
        }
        switch report.probe.readiness { case .ready: return 0; case .partial: return 1; case .broken: return 2 }
    }

    /// `--inspect-model <path>`: read a local model's (`.gguf`, `tokenizer_config.json`, or a dir with
    /// either) chat template + EOS, detect its family, and print the stop sequences the loop will enforce.
    /// This is what "Drop a Doc" onboarding uses to auto-configure a local model for clean-stop loops.
    /// Exit: 0 if a template family was identified, 1 if unreadable/unknown.
    static func runInspectModel(_ path: String) -> Int32 {
        guard let profile = LocalModelConfigReader.read(path: path) else {
            err("error: could not read a chat template from '\(path)'. Expected a .gguf, a tokenizer_config.json, or a directory containing one.")
            return 1
        }
        print("local model template · \(profile.family.displayName)")
        print("  source:  \(profile.source)")
        if let n = profile.modelName { print("  name:    \(n)") }
        if let e = profile.eosToken { print("  eos:     \(e)") }
        print("  stops:   \(profile.stopSequences.isEmpty ? "(none detected)" : profile.stopSequences.joined(separator: "  "))")
        if profile.family == .unknown {
            err("note: template family unknown — the loop will fall back to provider/server-side stops. Pass a richer tokenizer_config.json if available.")
            return 1
        }
        return 0
    }

    /// `--model-vet <hf:owner/repo|mlx:owner/repo|ollama:tag>`: live metadata + license/provenance
    /// gate before any local model download. This command never downloads a model.
    static func runModelMetadataGate(_ spec: String, root: String) async -> Int32 {
        let report = await OrganizationalLearningStore(projectRoot: root).runLiveModelMetadataGate(spec: spec)
        print(report.text)
        if report.writeSucceeded {
            note("written: \(report.path) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)")
        } else {
            err("error: metadata gate could not write its report: \(report.writeError ?? "unknown error")")
            return 2
        }
        if report.decision?.accepted == true, !report.manifestWriteSucceeded {
            err("error: metadata gate accepted but acquisition manifest was not written: \(report.manifestWriteError ?? "unknown error")")
            return 2
        }
        if report.fetchError != nil { return 2 }
        return report.decision?.accepted == true ? 0 : 1
    }

    /// `--model-acquire <manifest.json>`: verify a previously written acquisition manifest
    /// before anyone runs its dry-run/download/onboard commands. This command never downloads.
    static func runModelAcquisitionPreflight(_ manifestPath: String, root: String) -> Int32 {
        let report = OrganizationalLearningStore(projectRoot: root)
            .runLocalModelAcquisitionPreflight(manifestPath: manifestPath)
        print(report.text)
        if report.writeSucceeded {
            note("written: \(report.path) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)")
        } else {
            err("error: acquisition preflight could not write its report: \(report.writeError ?? "unknown error")")
            return 2
        }
        if report.loadError != nil { return 2 }
        return report.decision.accepted ? 0 : 1
    }

    /// `--model-run <stage> <manifest.json>`: execute one verified acquisition stage.
    /// This runs only structured commands regenerated from a valid manifest.
    static func runModelAcquisitionStage(_ stage: String, manifestPath: String, root: String) -> Int32 {
        let report = OrganizationalLearningStore(projectRoot: root)
            .runLocalModelAcquisitionStage(stage: stage, manifestPath: manifestPath)
        print(report.text)
        if report.writeSucceeded {
            let marker = report.markerPath.map { " · marker: \($0)" } ?? ""
            note("written: \(report.path)\(marker) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)")
        } else {
            err("error: acquisition run could not write its report: \(report.writeError ?? "unknown error")")
            return 2
        }
        if report.loadError != nil { return 2 }
        return report.outcome?.succeeded == true && report.decision.accepted ? 0 : 1
    }
}
