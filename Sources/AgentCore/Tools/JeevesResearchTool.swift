import Foundation

public enum PEELEvidenceStatus: String, Codable, Sendable, Equatable {
    case passed
    case failed
    case skippedUnavailable
    case blockedRequired
}

/// Durable, bounded proof that a particular research run crossed (or failed to cross) the symbolic
/// PEEL gate. It stores lineage and a content digest, never private model reasoning.
public struct PEELEvidenceReceipt: Codable, Sendable, Equatable {
    public let researchRunID: String
    public let status: PEELEvidenceStatus
    public let evidenceID: String?
    public let locator: String?
    public let digest: String?
    public let summary: String

    public init(researchRunID: String, status: PEELEvidenceStatus,
                evidenceID: String? = nil, locator: String? = nil,
                digest: String? = nil, summary: String) {
        self.researchRunID = researchRunID
        self.status = status
        self.evidenceID = evidenceID
        self.locator = locator
        self.digest = digest
        self.summary = String(summary.prefix(1_000))
    }

    public var satisfiesRequiredGate: Bool {
        status == .passed && evidenceID != nil && locator != nil && digest != nil
    }

    public func reasoningReference(nodeID: String) -> ReasoningEvidenceReference {
        ReasoningEvidenceReference(
            id: "peel:\(researchRunID):\(evidenceID ?? status.rawValue)",
            kind: .research, nodeID: nodeID, locator: locator, digest: digest,
            summary: "symbolic PEEL gate \(status.rawValue): \(summary)"
        )
    }

    public static func contentDigest(_ text: String) -> String {
        BuilderEvidenceDigest.sha256(text)
    }
}

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
        ToolParameter(name: "research_goal", type: "string",
                      description: "Original unrendered goal required by evidence-bound PEEL.", required: false),
        ToolParameter(name: "primary_evidence_id", type: "string",
                      description: "Optional trusted research-ledger evidence ID for evidence-bound PEEL.", required: false),
        ToolParameter(name: "primary_url", type: "string",
                      description: "Fetched source URL paired with primary_evidence_text.", required: false),
        ToolParameter(name: "primary_status", type: "integer",
                      description: "Successful HTTP status paired with primary evidence.", required: false),
        ToolParameter(name: "primary_digest", type: "string",
                      description: "SHA-256 of the exact stored primary evidence text.", required: false),
        ToolParameter(name: "primary_evidence_text", type: "string",
                      description: "Exact bounded fetched evidence for deterministic PEEL.", required: false),
    ]

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let query = ((arguments["query"] as? String) ?? (arguments["goal"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .failure("jeeves_research needs a non-empty 'query'") }
        let evidenceKeys = [
            "primary_evidence_id", "primary_url", "primary_status", "primary_digest",
            "primary_evidence_text",
        ]
        if evidenceKeys.contains(where: { arguments[$0] != nil }) {
            guard let researchGoal = (arguments["research_goal"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !researchGoal.isEmpty,
                  let evidenceID = arguments["primary_evidence_id"] as? String,
                  evidenceID.range(of: #"^E[0-9]{3,}$"#, options: .regularExpression) != nil,
                  let url = arguments["primary_url"] as? String,
                  let status = arguments["primary_status"] as? Int,
                  let digest = arguments["primary_digest"] as? String,
                  let text = arguments["primary_evidence_text"] as? String,
                  text.utf8.count <= ResearchEvidencePolicy.primaryFetchByteLimit else {
                return .failure("evidence-bound PEEL requires one complete bounded primary evidence binding")
            }
            let candidate = ResearchEvidence(
                sequence: 1, id: evidenceID, kind: "fetch_url", title: url,
                url: url, path: nil, text: text,
                metadata: [
                    "status": String(status),
                    "fetch_status": status == 206 ? "partial" : "complete",
                    "content_sha256": digest,
                ],
                at: 0)
            guard let primary = ResearchEvidencePolicy.verifiedPrimarySources(
                in: [candidate]).first,
                  let proof = ResearchEvidencePolicy.symbolicPEEL(
                    goal: researchGoal, primary: primary) else {
                return .failure(
                    "evidence-bound PEEL rejected an invalid, tampered, contradictory, or irrelevant primary source")
            }
            return ToolResult(success: true, output: proof, metadata: [
                "source": "kist-evidence-bound-peel",
                "grounded": "true",
                "primary_evidence_id": primary.evidenceID,
                "primary_url": primary.url,
                "primary_content_sha256": primary.contentSHA256,
                "relevance": "passed",
            ])
        }
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
