import Foundation

/// "DROP A KEY, DROP A DOC" — the zero-config onboarding capstone. Ties the loop-readiness primitives
/// into one verdict: you add a model (a key, or a local doc/weights path) and we (1) read its chat
/// template + stops if it's local, (2) drive it through a real tool loop, and (3) say plainly whether
/// it's ready to use. Pure orchestration over already-tested pieces — no provider registration here
/// (that's onboarding-UI territory); this is the VERIFY step that makes a dropped model trustworthy.
public enum ModelLoopVerify {

    public struct Report: Sendable, Equatable {
        public var providerId: String
        public var model: String?
        public var template: LocalModelTemplate?     // present when a local doc was supplied AND readable
        public var docError: String?                 // set when a doc WAS supplied but could not be read
        public var probe: ModelLoopProbe.Report
        public var ready: Bool                        // onboarded AND a real loop ran clean

        public init(providerId: String, model: String?, template: LocalModelTemplate?, docError: String? = nil,
                    probe: ModelLoopProbe.Report, ready: Bool) {
            self.providerId = providerId; self.model = model
            self.template = template; self.docError = docError; self.probe = probe; self.ready = ready
        }
    }

    /// Readiness rule (pure, unit-pinned): a model is onboarded-ready ONLY if its real loop probe came
    /// back `.ready` AND any supplied doc was actually readable. A doc that the user dropped but we
    /// couldn't parse is a HARD failure — never silently ignored (fail-closed). An ABSENT doc is fine
    /// (the template is informational; the server may handle stops).
    public static func isReady(probe: ModelLoopProbe.Report, docError: String?) -> Bool {
        probe.readiness == .ready && docError == nil
    }

    public static func onboard(registry: ProviderRegistry, providerId: String, model: String?,
                               docPath: String?) async -> Report {
        // Distinguish "no doc" (fine) from "doc given but unreadable" (a hard onboarding error) —
        // collapsing both to nil would let a malformed drop report READY.
        var template: LocalModelTemplate? = nil
        var docError: String? = nil
        if let docPath {
            if let t = LocalModelConfigReader.read(path: docPath) { template = t }
            else { docError = "could not read a chat template from '\(docPath)' (expected a .gguf, tokenizer_config.json, or a dir with one)" }
        }
        let probe = await ModelLoopProbe.probe(registry: registry, providerId: providerId, model: model)
        return Report(providerId: providerId, model: model, template: template, docError: docError,
                      probe: probe, ready: isReady(probe: probe, docError: docError))
    }

    public static func render(_ r: Report) -> String {
        let label = r.providerId + (r.model.map { ":\($0)" } ?? "")
        var lines = ["onboarding · \(label) · \(r.ready ? "READY TO USE" : "NOT READY")", ""]
        if let t = r.template {
            lines.append("template: \(t.family.displayName)  (\(t.source))")
            lines.append("stops:    \(t.stopSequences.isEmpty ? "(provider/server-side)" : t.stopSequences.joined(separator: "  "))")
            lines.append("")
        }
        if let docError = r.docError {
            lines.append("✗ doc:    \(docError)")
            lines.append("")
        }
        lines.append(ModelLoopProbe.render(r.probe))
        if !r.ready {
            lines.append("")
            let reason: String
            if r.docError != nil { reason = "the dropped doc could not be read — fix the path/format and retry" }
            else if r.probe.readiness == .partial { reason = "usable with caveats — see above before relying on it" }
            else { reason = "not usable yet — the loop did not run clean" }
            lines.append("→ \(reason)")
        }
        return lines.joined(separator: "\n")
    }
}
