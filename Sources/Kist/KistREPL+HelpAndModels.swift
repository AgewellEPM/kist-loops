import Foundation
import AgentCore

// Help text, the model/provider catalog printout, and provider-binding rendering.
// Extracted verbatim from KistREPL.swift.
extension KistREPL {
    func printHelp() {
        print("""
        \u{001B}[37m  /help             this help
          /code [prov[:m]]  coding mode — pin the strong coder (DeepSeek V4 Pro), routing off, research opt-in;
                            just describe what to build (e.g. /code claude-cli for the Max sub)  [alias /c]
          /model            arrow-key model picker (↑/↓ · filter · enter/esc); green = ready, red = needs a key  [alias /m]
          /model import <url>
                            import any OpenAI-compatible model: discover models at the URL → add API key →
                            self-heal/self-test/pen-test onboard → persists (shows green in the picker)
          /model scout <g> safe local/Hugging Face model acquisition plan; no downloads, writes eval gates
          /model vet <hf:model|mlx:model|ollama:model>
                            fetch live metadata and apply license/provenance/size gates before any download
          /model acquire <manifest.json>
                            verify acquisition manifest hash/commands and seed dry-run/download/onboard gates
          /model <prov[:m]> switch the model this conversation talks to (e.g. /model openai:gpt-5.5,
                            /model gemini, or /model :<model> to change model on the current provider)
          /chain "a" | "b"  run tasks in sequence, each as its own turn (stops on first failure)  [alias /pipeline]
          /copilot [on|off] auto second-AI review of the diff after each coding turn (advisory only)  [alias /cp]
          /copilot lead <m> · /copilot co <m>
                            assign who writes the code (lead) and who reviews the diff (co)
          /paste [question] read clipboard media (screenshot, image file, video, audio, PDF) and ask  [alias /v]
          <drag a file in>  drag an image / video / audio / PDF from Finder onto the line — the path
                            is detected, attached, and read by a vision model (Gemini for video/audio)
          /media <path>     preview an image/video poster inline in iTerm2, WezTerm, Kitty, or Ghostty
          /reasoning [on|off]
                            show/hide provider reasoning streams. Off by default; tool scratch text stays hidden.
          /plan [on|off]    plan mode: read-only; the agent proposes a plan (bare /plan toggles)
          /config [k=v]     settings panel over .kist/settings.json (bare shows, k=v sets)  [alias /settings]
          /context          estimated context-window breakdown (what's filling it)  [alias /ctx]
          /compact [focus]  summarize older history to free context; keeps recent turns verbatim
          /theme [name]     color palette: default/dark/light/daltonized(CVD)/high-contrast/mono(screen-reader)
          /skills           list discovered skills + token cost (what agents can preload)
          /mcp              list configured MCP servers (what agents can reach)
          /hooks            list lifecycle hooks (.kist/hooks.json)
          /permissions      current permission tier + which tools still prompt  [alias /perms]
          /goals            show the shared goal/action/test board  [aliases /goal /tasks /todo]
          1                 run task [1] from the board through plan→execute
          /action <step>    add an ACTION step to the shared board
          /test <step>      add a TEST step to the shared board
          /review <step>    add a REVIEW step to the shared board
                            add acceptance/proof with: | acceptance: ... | verify: ... | evidence: ...
          /build [goal]     BUILD IT — fire the plan→execute worker (real code + build/tests). No
                            args = build the plan just proposed (stop researching, start building).
          /plan-execute <g> build it as a typed plan-DAG (your team: planner→coder→critic)  [alias /pe]
          /council [--execute] <g>
                            ask researcher/architect/coder/critic/UX/memory minds, save a kanban board,
                            and optionally hand the builder brief to plan-execute  [alias /consult]
          /research <g>     gather an evidence dossier, run council over it, and seed the task board
          /competitive <t>  deep R&D cross-compare OUR project vs a competitor/product/URL  [alias /vs]
          /mode [x]         how Kist talks: conversation·science·build·friend·nobs·normal,
                            /mode level <1..8|highschool|college>, /mode persona <your own voice>
          /legal-research <g + optional doc path>
                            legal research mode: ingest/OCR-extract docs where possible, require jurisdiction,
                            official sources first, then hand off to /research for a cited memo
          /fleet-status     the Terminal Captain cockpit: latest fleet's per-agent status + merge-fate  [alias /cockpit]
          /fleet [--agents N|--agents=N] <g>
                            spawn a SUPERVISED parallel fleet for the goal — disjoint-lease agents,
                            forge-proof signoff, joined to a fresh integration branch (never main)  [alias /team]
          /roles            show role bindings used by /fleet and /plan-execute
          /roles coder deepseek
                            assign a provider/model to a role. Roles: planner, worker/researcher, coder/builder, critic
                            model form: provider:model, e.g. /roles critic gemini:gemini-3.1-pro
          /roles reset      reset every role to the default provider/model
          /roles save <n>   save the current AI team as a named profile
          /roles load <n>   load a saved AI team profile
          /roles profiles   list saved AI team profiles
          /roles delete <n> delete a saved AI team profile
          /agent new <desc> forge a reusable specialist/personality from plain English
                            aliases: /agents new, /persona new, /specialist new
          /agents           list saved specialists; /agents show <name> shows the prompt/tools/model
          /agents run <name> <task>
                            hard-spawn a specialist (own context/tools/model/limits); returns its summary
          /tasks            show the shared Plan/Action/Test/Review board (.kist/plan.json)
                            add/start/done/block/evidence/validate/clear; the agent uses this same board
          <plain English>   you can also just SAY it: "use deepseek as builder and gemini as critic",
                            "switch to gemini", "make me an agent that audits SwiftUI" — it rebinds
                            the runtime or forges the specialist
          /providers        list provider ids available for /roles
          /health           offline provider/model/router health
          /probe            live one-token provider probe (catches stale model ids)
          /usage            rich session + local-week token/cost panel
          /summary          simple human summary: happened / changed / failed / next
          /confidence       explain the last turn's score and what would raise it  [alias /why]
          /failures         show latest failure capsule; /failures verify <evidence> closes repair loop
          /reflect          show the latest Learning Capsule; /reflect now captures one from current state
          /knowledge        show persistent Knowledge Debt; add/done manage debt items
          /teach            show permanent organizational rules; add promotes a lesson into Captain
          /learning         show benchmark/live-eval model learning and promotion status
          /industry         show Strategic Intelligence records and evolution proposals
          /retrieve <g>     retrieve relevant disk-backed memory into Captain's context window
          /captain <g>      show research-first strategy, expertise needs, and specialist gaps for an objective
          /legal <g>        alias for /legal-research; research support only, not legal advice
          /domain <g>       learn an unfamiliar domain first; add run/now to dispatch research/simulation/critic specialists
          /model-acquire <manifest.json>
                            verify a local-model acquisition manifest without downloading
          /model run <stage> <manifest.json>
                            run a verified local-model acquisition stage: dry-run, download, inspect,
                            onboard, or benchmark
          /self-heal [run]  turn Captain's own observation into assigned repair agents + gated tasks
          /self-test        run Captain's deterministic self-audit and write a report; add run/--seed for repair tasks
          /immune [check]   run self-test + repair/simulation evidence loop; default seeds repair tasks
          /simulate <g>     sandbox-simulate a plan, run probabilistic trials, compare risk, seed evidence gates
          /symbolic         compile/reuse deterministic workflow gates: list · compile <g> · run <id> <target>
          /evolve           board meeting: reflect, rank knowledge debt, create specialists, seed research tasks
          /logs             proof drawer for the last turn: tools, outputs, failures  [alias /details]
          /replay [id]      durable run replay from .kist/runs (current: \(replayRunID ?? "none"))
          /bench <task>     provider bake-off for this task
          /eval <task>      deterministic agent-behavior eval for this task
          /protocols        MCP/A2A/browser/computer-control status
          /commands         list custom .kist/commands
          /save-chat [path] export this conversation to Markdown in the project root
          /clear            forget the conversation so far
          /exit /quit /q    leave
          prompt keys       ↑/↓ history · Tab completion · live command/code highlighting
          Enter sends only when the » prompt is visible; while a turn streams, wait for the next prompt.
          <anything else>   ask / build with the agent (it can read/search/edit/run in the project
                            and, with approval, control apps/browser/Desktop)\u{001B}[0m
        """)
    }

    func printModels(current: ProviderBinding) {
        print("model · \(Self.render(current))")
        guard !providerLabels.isEmpty else {
            print("\u{001B}[37m(provider catalog unavailable — use /providers)\u{001B}[0m")
            return
        }
        print("\u{001B}[37mswitch with: /model <provider[:model]>  or  /model :<model> (keep current provider)\u{001B}[0m")
        for label in providerLabels {
            // providerLabels entries look like "openai" or "openai (missing key)".
            let id = label.split(separator: " ").first.map(String.init) ?? label
            let models = providerModels[id.lowercased()] ?? []
            let modelList = models.isEmpty ? "" : "  \u{001B}[37m" + models.joined(separator: ", ") + "\u{001B}[0m"
            print("  \(label)\(modelList)")
        }
    }

    static func render(_ binding: ProviderBinding) -> String {
        binding.providerId + (binding.model.map { ":\($0)" } ?? "")
    }
}
