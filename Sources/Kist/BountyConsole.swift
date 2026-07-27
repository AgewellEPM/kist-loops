import Foundation
import AgentCore

/// Injectable store set so the console (and its tests) can target isolated roots instead of `~/.kist`.
struct BountyStores {
    var engagements = EngagementStore()
    var rules = BountyRulesStore()
    var submissions = SubmissionTracker()
}

/// The `/bug-bounty` REPL command handler. Kept out of KistREPL so the switch case stays one line. Drives
/// the whole assistant: ingest a program spec, then run the guided wizard over an in-scope repo. It only
/// ever RENDERS — a human still submits. Offline-safe: without a model it uses the deterministic panel.
enum BountyConsole {

    /// Handle a `/bug-bounty <args>` invocation. `complete` is the model seam (nil ⇒ deterministic panel).
    static func handle(_ args: String, projectRoot: String,
                       complete: (@Sendable (String, String) async -> String?)?,
                       stores: BountyStores = BountyStores()) async -> String {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let sub = parts.first?.lowercased() ?? ""
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch sub {
        case "", "help":  return usage()
        case "list":      return renderList(stores)
        case "ingest":    return ingest(path: rest, stores: stores)
        case "run":       return await run(rest: rest, projectRoot: projectRoot, complete: complete, stores: stores)
        default:          return "unknown /bug-bounty subcommand '\(sub)'\n" + usage()
        }
    }

    static func usage() -> String {
        """
        \u{001B}[1mBug-bounty assistant\u{001B}[0m — verified-only, scope-gated, human-on-submit.
          /bug-bounty ingest <spec.json>     load + attest a program (scope + rules), fail-closed
          /bug-bounty run <program-id> [dir] run the guided wizard over an in-scope repo (default dir: project)
          /bug-bounty list                   list ingested programs
        A finding is only ever drafted if it's IN SCOPE, survives the skeptic panel, AND reproduces.
        Nothing is auto-submitted — you review and file every report yourself.
        """
    }

    static func renderList(_ stores: BountyStores) -> String {
        let engs = stores.engagements.list()
        guard !engs.isEmpty else { return "no programs ingested yet — /bug-bounty ingest <spec.json>" }
        return "programs:\n" + engs.map { "  \u{001B}[36m\($0.id)\u{001B}[0m · \($0.program) · \($0.targets.count) target(s)" }.joined(separator: "\n")
    }

    static func ingest(path: String, stores: BountyStores) -> String {
        guard !path.isEmpty else { return "usage: /bug-bounty ingest <spec.json>" }
        guard let data = FileManager.default.contents(atPath: path) else { return "\u{001B}[31mcannot read \(path)\u{001B}[0m" }
        let spec: ProgramSpec
        do { spec = try JSONDecoder().decode(ProgramSpec.self, from: data) }
        catch { return "\u{001B}[31mspec is not valid JSON: \(error)\u{001B}[0m" }
        do {
            let (eng, rules) = try ProgramIntake.ingest(spec, engagements: stores.engagements, rulesStore: stores.rules)
            return "\u{001B}[32m✓ ingested \(eng.id)\u{001B}[0m · \(eng.program)\n"
                + "  attested by: \(eng.attestedBy) @ \(eng.attestedAtISO)\n"
                + "  targets: \(eng.targets.map { "\($0.kind.rawValue):\($0.value)" }.joined(separator: ", "))\n"
                + "  automation: \(rules.automation.rawValue) · rate: \(rules.maxRequestsPerSecond.map { "\($0)/s" } ?? "unknown") · classes: \(rules.allowedVulnClasses.sorted().joined(separator: ", "))"
        } catch let e as ProgramIntake.IntakeError {
            return "\u{001B}[31mrefused: \(e)\u{001B}[0m — an unauthorized/underspecified program cannot be ingested"
        } catch {
            return "\u{001B}[31mingest failed: \(error)\u{001B}[0m"
        }
    }

    static func run(rest: String, projectRoot: String,
                    complete: (@Sendable (String, String) async -> String?)?,
                    stores: BountyStores) async -> String {
        let toks = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let id = toks.first, !id.isEmpty else { return "usage: /bug-bounty run <program-id> [repo-dir]" }
        let root = toks.count > 1 ? toks[1] : projectRoot

        guard let engagement = (try? stores.engagements.load(id: id)) ?? nil else {
            return "\u{001B}[31mno ingested program '\(id)'\u{001B}[0m — /bug-bounty list"
        }
        guard let rules = (try? stores.rules.load(id: id)) ?? nil else {
            return "\u{001B}[31mno rules stored for '\(id)'\u{001B}[0m (re-ingest the spec)"
        }
        guard let repoTarget = engagement.targets.first(where: { $0.kind == .repo }) else {
            return "\u{001B}[31mprogram '\(id)' has no in-scope repo target\u{001B}[0m — source recon needs one"
        }

        // Panel: real LLM skeptics when a model is available, else a deterministic floor panel.
        let panel: [FindingRefuter]
        let panelNote: String
        if let complete {
            panel = (0..<3).map { _ in LLMFindingRefuter(complete: complete) }
            panelNote = "adversarial panel: 3 model skeptics"
        } else {
            panel = [SeverityThresholdRefuter(minConfirmable: .medium)]
            panelNote = "adversarial panel: deterministic (no model) — severity floor"
        }

        let priors = stores.submissions.list(program: engagement.program)
        let outcome = await BountyWizard().run(
            target: ReconTarget(repo: repoTarget.value, root: root),
            engagement: engagement, rules: rules, panel: panel, priorSubmissions: priors)

        var s = "\u{001B}[1mBug-bounty run · \(engagement.program)\u{001B}[0m  (\(panelNote))\n"
        for step in outcome.steps {
            let flag = step.needsHuman ? " \u{001B}[33m[you]\u{001B}[0m" : ""
            s += "\n\u{001B}[36m▸ \(step.title)\u{001B}[0m\(flag)\n"
            s += "  \u{001B}[2m\(step.teaching)\u{001B}[0m\n"
            if !step.detail.isEmpty { s += indent(step.detail) + "\n" }
        }
        s += "\n\u{001B}[2m\(outcome.reportReadyCount)/\(outcome.candidateCount) candidate(s) report-ready. "
            + "Review any draft above and file it yourself — nothing was submitted.\u{001B}[0m"
        return s
    }

    private static func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }
}
