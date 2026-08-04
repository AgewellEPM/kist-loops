import Foundation

/// The human changelog behind `/version` — so typing `/version` in the terminal shows the version,
/// WHAT we worked on in it, and WHEN it shipped (build stamp from the deployment manifest). Curated
/// by hand and compiled into the binary (the single-binary deploy has no sidecar resources), newest
/// release first. Keep the top entry in sync with `KistBuildInfo.productVersion` on every bump.
enum KistChangelog {
    struct Release: Equatable, Sendable {
        let version: String
        let date: String        // ISO date the release shipped
        let headline: String
        let changes: [String]
    }

    static let releases: [Release] = [
        Release(version: "0.17.3", date: "2026-08-03",
                headline: "IBM watsonx.ai as a model — hand the thinking to Watson",
                changes: [
                    "watsonx (IBM) is now a built-in provider — talk to it with /model watsonx, or let kist drive the conversation and hand the hard reasoning to Watson via /roles critic watsonx, /roles planner watsonx, or /copilot co watsonx",
                    "Models: Llama 3.3 70B, Mistral Large, Granite 3 8B, Llama 3.2 90B Vision (pick with /model watsonx:<id> or WATSONX_MODEL)",
                    "Handles IBM's real auth: IAM API-key→bearer-token exchange (cached ~1h, auto-refresh) — not a static key",
                    "Setup: export WATSONX_API_KEY and WATSONX_PROJECT_ID (region via WATSONX_URL, default us-south). Missing project id fails fast with exact guidance",
                    "Routes through the universal text tool-protocol, so Watson keeps full tool access and won't break on multi-turn tool histories",
                ]),
        Release(version: "0.17.2", date: "2026-08-03",
                headline: "/chain — a visual automation center",
                changes: [
                    "/chain — opens a local visual workflow builder (Zapier × LangGraph for Kist): drag a trigger into a graph of Kist steps + conditions, connect them, Save and Run",
                    "Chains are saved as JSON in .kist/chains/ and can be run from the terminal too: /chain list · /chain run <name>",
                    "Each 'Kist step' passes its output to the next ({{input}}); conditions branch on the text; schedule triggers are ready for daily automations",
                    "Next: real tool-using turns per step + Scribe import + daily-email→respond wiring",
                ]),
        Release(version: "0.17.1", date: "2026-08-03",
                headline: "Action-first builds, /mode, honest goals",
                changes: [
                    "/build — fire the plan→execute worker on a plan (stop researching, start building); a clear build request now auto-runs it",
                    "/mode — set how Kist talks: conversation · science · build · friend · nobs; /mode level <grade..college>; /mode persona <write your own voice>",
                    "/competitive <target> — deep R&D cross-compare OUR project vs a competitor/product/URL",
                    "Routing: 'ask/use/bring <model>' actually switches models now; the strongest keyed provider is the default (no more defaulting to MiMo, which 400s)",
                    "BUILD STATUS: every build turn ends with a PATCH→APPLY→FILES→BUILD/TEST→BOARD checklist, so 'done' can't be faked",
                    "Self-heal: the researcher hands the builder a clean machine-readable spec (not the whole transcript), reproduces the failure first, halts instead of churning more research, and escalates to a heavy-hitter model",
                    "Goals & research now reflect YOUR project — the hardcoded Cursor/OpenHands/Claude-Code watch-list only appears when developing Kist itself",
                    "Fixed: mouse-scroll no longer cancels your turn or eats Enter at the approval prompt",
                    "Fixed: Gemini's private thinking no longer leaks into the answer",
                    "Internal: KistREPL's 2,992-line run() decomposed into focused modules (720-line core), fully test-verified",
                ]),
        Release(version: "0.17.0", date: "2026-08-02",
                headline: "Readable terminal — color, confidence, sticky bar",
                changes: [
                    "Neon per-category dashboard sections + green battery confidence gauge",
                    "/confidence (/why): why the score is what it is and how to raise it",
                    "Tool lane: an emoji per tool, category colors, dimmed metadata",
                    "Streamed answers get markdown coloring (bold / code / headers / lists); code fences stay raw",
                    "Bottom input bar now stays glued through turns (sticky-turns on by default; --no-sticky-turns opts out)",
                    "NO_COLOR + mono screen-reader theme honored on every surface",
                    "/version: this changelog view, as a bordered card",
                    "/usage: in-depth card — per-provider (incl. claude-cli / codex-cli subscription) tokens + cost, subagents, tools, MCP servers, weekly split",
                    "/usage: cost-by-activity — attributes budget to Architecture / Code / Review & tests / Research / Orchestration",
                    "/autonomy: where the time went — Thinking / Researching / Coding / Running / Delegating bars",
                ]),
        Release(version: "0.16.0", date: "2026-08-01",
                headline: "Consensus reviews + self-fixing captain",
                changes: [
                    "/ultra: consensus of minds — each model reviews then fixes until flawless",
                    "/bughunt: a fleet of isolated hunters for real-world bug hunting",
                    "The reviewer now auto-fixes what it finds",
                    "Auto-explore: answers lookup questions from our own files instead of hallucinating",
                    "Keyless claude-cli / codex-cli subscription providers",
                ]),
    ]

    /// The release matching the running binary's version, else the newest known.
    static func current(version: String = KistBuildInfo.productVersion) -> Release? {
        releases.first { $0.version == version } ?? releases.first
    }

    /// Render the `/version` panel as a bordered CARD (like Codex's `/status`): version + headline in
    /// the top border, the real build stamp (commit/branch/date from the manifest), the current
    /// release's changes in full, and earlier releases compact. Every row is padded to the same cell
    /// width so the box stays square even with emoji + ANSI inside (widths via TerminalCellText).
    static func render(provenance: KistBuildInfo.Provenance,
                       version: String = KistBuildInfo.productVersion,
                       color: Bool,
                       width: Int = 76) -> String {
        let cur = current(version: version)
        return TerminalCard.build(title: "🚀 kist v\(version)", color: color, width: width) { b in
            if let h = cur?.headline { b.bullet(" ", glyphCode: "2", h, textCode: "37;1") }
            b.blank()

            // Build stamp — the honest "when / what shipped" line.
            var stamp: [String] = []
            if let sc = provenance.shortCommit { stamp.append(b.c("94", sc)) }
            if let br = provenance.branch { stamp.append(b.c("94", br)) }
            if let d = provenance.builtAt { stamp.append(b.c("94", isoStamp(d))) }
            if provenance.sourceDirty == true { stamp.append(b.c("33;1", "dirty")) }
            b.row(stamp.isEmpty ? b.c("2", "build stamp unavailable (unmanaged build)")
                                : b.c("2", "build ") + stamp.joined(separator: b.c("2", " · ")))
            b.blank()

            if let cur {
                b.row(b.c("95;1", "What's new in \(cur.version)") + b.c("2", " · \(cur.date)"))
                for change in cur.changes { b.bullet("•", glyphCode: "92;1", change) }
                b.blank()
            }

            let earlier = releases.filter { $0.version != (cur?.version ?? version) }
            if !earlier.isEmpty {
                b.heading("Earlier releases", "2")
                for r in earlier {
                    b.bullet("▪", glyphCode: "94;1", "\(r.version) · \(r.date) · \(r.headline)")
                }
            }
        }
    }

    /// A stable `YYYY-MM-DD HH:MM` in the local zone (no Date.now — takes the instant explicitly).
    private static func isoStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
