import Foundation

/// R6 (2026-07-29): the SYMBOLIC-FIRST research primitive — a first-class tool so ANY loop
/// (plan-execute, great-loop, single-turn, fleet) can ground a factual/engineering question on TRUE
/// FACTS instead of raw LLM guessing. It runs Luke's Jeeves link-wheel bridge (`~/bin/jeeves-research`):
/// Tavily gathers verbatim web content → PEEL-tile promotion (contradiction gate + proof-score) →
/// GraphReasoner answers grounded on committed facts, naturalized by a local model.
///
/// Before this, the wheel was reachable ONLY via the manual `/research` REPL command — no autonomous
/// loop could consult it, so the LLM just guessed on a knowledge-miss. Now it's a tool the model (or a
/// plan step) can call. FAIL-CLOSED: if the bridge isn't installed we return an honest error naming the
/// gap, never a silent fall-through that would masquerade an ungrounded guess as "grounded research".
public struct JeevesResearchTool: AgentTool {
    /// Bridge path + max wall-clock, injectable for tests. Default = the real `~/bin/jeeves-research`.
    public typealias Runner = @Sendable (_ query: String) async -> ToolResult
    private let runner: Runner

    public init(runner: Runner? = nil) {
        self.runner = runner ?? JeevesResearchTool.defaultRunner
    }

    public let name = "jeeves_research"
    public let description = """
    Ground a FACTUAL or engineering question on true facts via the Jeeves symbolic link-wheel \
    (Tavily → PEEL tiles with contradiction + proof-score gates → GraphReasoner), NOT raw model \
    guessing. Use this when you are UNSURE of a fact, API, version, spec, or engineering rule and a \
    wrong answer would matter — prefer it over answering from memory. Returns the grounded answer plus \
    the evidence the wheel committed. If the symbolic bridge is unavailable it fails with a clear \
    reason instead of guessing.
    """
    public let parameters = [
        ToolParameter(name: "query", type: "string",
                      description: "The factual/engineering question to ground on true facts.", required: true),
    ]

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let query = ((arguments["query"] as? String) ?? (arguments["goal"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .failure("jeeves_research needs a non-empty 'query'") }
        return await runner(query)
    }

    /// Max wall-clock for a grounding call — a wedged wheel must NOT stall the loop forever.
    static let timeoutSeconds = 180
    static let outputCap = 200_000

    /// The real bridge: run `~/bin/jeeves-research <query>` through `ProcessGroupRunner` — which
    /// enforces a hard timeout (kills the whole process group), drains stdout+stderr on CONCURRENT
    /// threads (no full-pipe deadlock), and takes an EXPLICIT SCRUBBED env (the parent's provider/Tavily
    /// secrets are NOT leaked to the child — the bridge re-sources its own keys from ~/.config/kist).
    /// Fail-closed on a missing/erroring/timed-out bridge — never a silent ungrounded guess.
    static let defaultRunner: Runner = { query in
        let bridge = (NSHomeDirectory() as NSString).appendingPathComponent("bin/jeeves-research")
        guard FileManager.default.isExecutableFile(atPath: bridge) else {
            return .failure("symbolic research bridge not installed at ~/bin/jeeves-research — "
                + "cannot ground this question. Do NOT guess; tell the user the grounded path is unavailable.")
        }
        // ProcessGroupRunner.run BLOCKS (spawn + group teardown + reap) — run it off the actor.
        let outcome: ProcessGroupRunner.Outcome = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: ProcessGroupRunner.run(
                    launchPath: bridge,
                    launchArgs: [query],
                    cwd: NSHomeDirectory(),
                    env: scrubbedEnvironment(),
                    timeoutSeconds: timeoutSeconds,
                    capPerStream: outputCap))
            }
        }
        if outcome.timedOut {
            return .failure("symbolic research timed out after \(timeoutSeconds)s — the wheel is wedged. "
                + "Do NOT guess; report the grounded path was unavailable.")
        }
        guard outcome.exitCode == 0 else {
            let e = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure("symbolic research failed (exit \(outcome.exitCode)): "
                + (e.isEmpty ? "no detail" : String(e.prefix(500))))
        }
        let text = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResult(success: true,
                          output: text.isEmpty ? "(the symbolic wheel returned no grounded answer)" : text,
                          metadata: ["source": "jeeves-link-wheel", "grounded": "true"])
    }

    /// Least-privilege child environment: PATH/HOME/etc. only — NO provider/API secrets. The bridge
    /// re-sources what it legitimately needs from ~/.config/kist/secrets.env itself.
    static func scrubbedEnvironment() -> [String: String] {
        let allow: Set<String> = ["PATH", "HOME", "USER", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "SHELL", "PWD"]
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for k in allow where parent[k] != nil { env[k] = parent[k] }
        return env
    }
}
