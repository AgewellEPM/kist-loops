import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Research pipeline + local code-dive entry points, extracted from KistRunner.swift
// to keep the core orchestration file under the size limit. Part of `enum KistRunner`.
extension KistRunner {
    static func runResearch(_ opts: KistOptions, goal: String,
                                    registry: ProviderRegistry, root: String,
                                    tools: ToolRegistry, context: ToolContext,
                                    providerId: String, model: String?,
                                    rolesOverride: RoleBindings? = nil,
                                    runCouncilAfterResearch: Bool = true,
                                    capture: ResearchPipelineCaptureBox? = nil,
                                    requirePEEL: Bool = false) async -> Int32 {
        note("kist · research · \(root)")
        // LIVE PROGRESS (Luke 2026-08-02): research used to go dead-silent between blocking tool calls
        // (only terse note() lines), unlike the build path's live "thinking" display. Show a Codex-style
        // checklist instead — each step announces what it's doing NOW, then lights up green (✓) when done
        // or red (✗) if it failed — so the user can see it working rather than staring at a frozen screen.
        let colored = KistREPL.stdoutColorEnabled(projectRoot: root)
        func dim(_ s: String) -> String { colored ? "\u{001B}[2m\(s)\u{001B}[0m" : s }
        func researchStep(_ emoji: String, _ label: String,
                          _ run: () async -> ToolResult) async -> ToolResult {
            note(dim("│ \(emoji) \(label) · working…"))
            let r = await run()
            if r.success {
                note(colored ? "\u{001B}[32m│ ✓ \(label)\u{001B}[0m" : "│ ✓ \(label)")
            } else {
                let why = r.error ?? r.output
                note(colored ? "\u{001B}[31m│ ✗ \(label) · \(why)\u{001B}[0m" : "│ ✗ \(label) · \(why)")
            }
            return r
        }
    note(dim("▤ research · named URL fetch → web search → repo context → estate sweep → synthesize"))

        let start = await researchStep("🔎", "start research run") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "start", "goal": goal], context: context)
        }
        guard start.success, let runID = start.metadata["run_id"] else {
            err("research · failed to start: \(start.error ?? start.output)")
            return 1
    }
    note(dim("│   run \(runID)"))

    let requiredURLs = ResearchRunTool.canonicalGoalURLs(in: goal)
    for url in requiredURLs {
        let fetched = await researchStep("🔗", "fetch primary URL") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "fetch", "run_id": runID,
                                            "url": url,
                                            "max_bytes": ResearchEvidencePolicy.primaryFetchByteLimit],
                                context: context)
        }
        guard usablePrimaryResearchEvidence(fetched) else {
            let why = fetched.error ?? fetched.output
            err("research · incomplete: required URL fetch produced no usable evidence (\(url)): \(why)")
            return 1
        }
    }

    let webEvidence = await researchStep("🌐", "web search") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "search", "run_id": runID,
                                            "query": goal, "limit": 5], context: context)
        }

        if requirePEEL {
            let alreadyRequired = Set(requiredURLs)
            let candidates = ResearchEvidencePolicy.rankedPrimarySourceURLs(
                searchOutput: webEvidence.output, goal: goal)
            var verified = ResearchEvidencePolicy.verifiedPrimarySources(
                in: ResearchRunStore.loadEvidence(projectRoot: root, runID: runID))
            var relevant = ResearchEvidencePolicy.firstRelevantPrimarySource(
                goal: goal, in: verified)
            if relevant == nil {
                for candidate in candidates where !alreadyRequired.contains(candidate) {
                    let fetched = await researchStep("🔗", "fetch discovered primary source") {
                        await tools.execute(
                            name: "research_run",
                            arguments: [
                                "action": "fetch", "run_id": runID, "url": candidate,
                                "max_bytes": ResearchEvidencePolicy.primaryFetchByteLimit,
                            ],
                            context: context)
                    }
                    if usablePrimaryResearchEvidence(fetched) {
                        verified = ResearchEvidencePolicy.verifiedPrimarySources(
                            in: ResearchRunStore.loadEvidence(projectRoot: root, runID: runID))
                        relevant = ResearchEvidencePolicy.firstRelevantPrimarySource(
                            goal: goal, in: verified)
                        if relevant != nil { break }
                    }
                }
            }
            guard relevant != nil else {
                err("research · incomplete: no fetched, digest-bound primary source was relevant to the original goal")
                return 1
            }
        }

        let repoEvidence = await researchStep("📂", "repo context") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "context", "run_id": runID,
                                            "query": goal, "limit": 8], context: context)
        }
        if repoEvidence.success {
            for contextID in ResearchEvidencePolicy.contextChunkIDs(
                searchOutput: repoEvidence.output, limit: 3) {
                let exact = await researchStep("📄", "load exact repo evidence") {
                    await tools.execute(name: "research_run", arguments: [
                        "action": "context", "run_id": runID,
                        "context_id": contextID, "max_chars": 24_000,
                    ], context: context)
                }
                if requirePEEL && !exact.success {
                    err("research · incomplete: advertised repo chunk could not be retrieved exactly (\(contextID))")
                    return 1
                }
            }
        }
    guard !requiredURLs.isEmpty
            || usablePrimaryResearchEvidence(webEvidence)
            || usablePrimaryResearchEvidence(repoEvidence) else {
        err("research · incomplete: named URL fetch, web search, and repo context produced no usable evidence")
        return 1
        }

        // DEEP ESTATE SWEEP (Luke 2026-07-31): on TOP of the web + current-repo evidence, sweep our OWN
        // system files across ~ and /Volumes IN-PROCESS (bypasses the tool sandbox → reaches our real source
        // at /Volumes/PRO-G40/kist-loops and the rest of the estate). Record the sweep in the SAME durable
        // evidence ledger before synthesis; otherwise a zero-source dossier could be laundered into a
        // successful council artifact, and estate provenance would exist only in transient prompt text.
        let estate = await researchStep("🧠", "estate sweep (our own files)") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "estate", "run_id": runID,
                                            "query": goal], context: context)
        }
        if estate.success {
            note(dim("│   \(estate.metadata["files"] ?? "0") system file(s) recorded"))
        }

        let evidencePath = ".kist/research-runs/\(runID)/evidence.jsonl"
        let verifiedPrimary = ResearchEvidencePolicy.verifiedPrimarySources(
            in: ResearchRunStore.loadEvidence(projectRoot: root, runID: runID))
            .first { ResearchEvidencePolicy.symbolicPEEL(goal: goal, primary: $0) != nil }
        let peelReceipt: PEELEvidenceReceipt
        if tools.all().contains(where: { $0.name == "jeeves_research" }) {
            let peelQuery = verifiedPrimary.map {
                ResearchEvidencePolicy.peelQuery(goal: goal, primary: $0)
            } ?? goal
            let peel = await researchStep("◫", "symbolic PEEL proof gate") {
                var arguments: [String: Any] = ["query": peelQuery]
                if let primary = verifiedPrimary {
                    arguments["research_goal"] = goal
                    arguments["primary_evidence_id"] = primary.evidenceID
                    arguments["primary_url"] = primary.url
                    arguments["primary_status"] = primary.httpStatus
                    arguments["primary_digest"] = primary.contentSHA256
                    arguments["primary_evidence_text"] = primary.text
                }
                return await tools.execute(
                    name: "jeeves_research", arguments: arguments, context: context)
            }
            if peel.success {
                do {
                    if requirePEEL {
                        guard let primary = verifiedPrimary else {
                            throw ToolError.execution("symbolic PEEL has no verified primary evidence binding")
                        }
                        guard peel.metadata["grounded"] == "true",
                              ResearchEvidencePolicy.peelIsRelevant(
                                goal: goal, output: peel.output, primary: primary) else {
                            throw ToolError.execution(
                                "symbolic PEEL output is not relevant to the goal and fetched primary evidence")
                        }
                    }
                    let boundOutput = verifiedPrimary.map {
                        ResearchEvidencePolicy.bindPEELOutput(peel.output, primary: $0)
                    } ?? peel.output
                    let digest = PEELEvidenceReceipt.contentDigest(boundOutput)
                    var metadata = peel.metadata
                    metadata["digest"] = digest
                    metadata["research_run_id"] = runID
                    if let primary = verifiedPrimary {
                        metadata["primary_evidence_id"] = primary.evidenceID
                        metadata["primary_url"] = primary.url
                        metadata["primary_content_sha256"] = primary.contentSHA256
                        metadata["relevance"] = "passed"
                    }
                    let store = try ResearchRunStore.open(projectRoot: root, runID: runID)
                    let item = try store.appendEvidence(
                        kind: "symbolic_peel", title: "Symbolic PEEL contradiction/proof gate",
                        text: boundOutput, path: evidencePath, metadata: metadata
                    )
                    peelReceipt = PEELEvidenceReceipt(
                        researchRunID: runID, status: .passed, evidenceID: item.id,
                        locator: evidencePath, digest: digest,
                        summary: "grounded symbolic evidence committed as \(item.id)"
                            + (verifiedPrimary.map { " and bound to \($0.evidenceID)" } ?? "")
                    )
                } catch {
                    peelReceipt = PEELEvidenceReceipt(
                        researchRunID: runID,
                        status: requirePEEL ? .blockedRequired : .failed,
                        summary: "symbolic evidence could not be committed: \(error.localizedDescription)"
                    )
                }
            } else {
                peelReceipt = PEELEvidenceReceipt(
                    researchRunID: runID,
                    status: requirePEEL ? .blockedRequired : .failed,
                    summary: peel.error ?? peel.output
                )
            }
        } else {
            peelReceipt = PEELEvidenceReceipt(
                researchRunID: runID,
                status: requirePEEL ? .blockedRequired : .skippedUnavailable,
                summary: "jeeves_research is not registered in the authorized tool set"
            )
        }

        let synth = await researchStep("📝", "synthesize dossier") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "synthesize", "run_id": runID], context: context)
        }
        guard synth.success else {
            err("research · incomplete: \(synth.error ?? synth.output)")
            return 1
        }
        if let report = synth.metadata["report"] { note(dim("│   dossier saved · \(report)")) }
        let dossier = synth.output
        let manifestPath = ".kist/research-runs/\(runID)/manifest.json"
        let reportPath = ".kist/research-runs/\(runID)/report.md"
        if let reportedPath = synth.metadata["report"],
           reportedPath != reportPath && reportedPath != root + "/" + reportPath {
            err("research · report lineage mismatch for run \(runID): \(reportedPath)")
            return 1
        }
        capture?.set(ResearchPipelineCapture(
            runID: runID, manifestPath: manifestPath, evidencePath: evidencePath,
            reportPath: reportPath, dossier: dossier,
            dossierDigest: PEELEvidenceReceipt.contentDigest(dossier),
            peelReceipt: peelReceipt
        ))
        guard !requirePEEL || peelReceipt.satisfiesRequiredGate else {
            err("research · blocked: required symbolic PEEL evidence did not pass (\(peelReceipt.status.rawValue))")
            return 1
        }
        guard runCouncilAfterResearch else { return 0 }

        return await runCouncil(opts, goal: goal, execute: opts.councilExecute,
                                registry: registry, root: root, tools: tools, context: context,
                                providerId: providerId, model: model, rolesOverride: rolesOverride,
                                researchDossier: dossier, researchRunID: runID,
                                seedBoard: opts.councilExecute)
    }

    /// `/dive` — a MULTI-AGENT deep-dive of OUR OWN CURRENT repo. `/research` is the wrong tool for "what
    /// does OUR code do": it hits the web and sweeps the whole estate across ~ and /Volumes, which is how
    /// "why does our build queue never change" wandered into an unrelated repo. Dive stays LOCAL and
    /// REPO-SCOPED: it reads the actual files under `root`, grounds a dossier in them, then hands that real
    /// code to every reachable model (wide council) for a synthesized, file-cited truth. No web search, no
    /// cross-repo estate sweep — the answer is grounded in the code we actually shipped.
    static func runDive(_ opts: KistOptions, goal: String,
                                registry: ProviderRegistry, root: String,
                                tools: ToolRegistry, context: ToolContext,
                                providerId: String, model: String?,
                                rolesOverride: RoleBindings? = nil) async -> Int32 {
        let colored = KistREPL.stdoutColorEnabled(projectRoot: root)
        func dim(_ s: String) -> String { colored ? "\u{001B}[2m\(s)\u{001B}[0m" : s }
        func paint(_ code: String, _ s: String) -> String { colored ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
        func diveStep(_ emoji: String, _ label: String, _ run: () async -> ToolResult) async -> ToolResult {
            note(dim("│ \(emoji) \(label) · working…"))
            let r = await run()
            note(r.success ? paint("32", "│ ✓ \(label)") : paint("31", "│ ✗ \(label) · \(r.error ?? r.output)"))
            return r
        }

        note("kist · dive · reading OUR code · \(root)")
        // Launched from HOME (not a repo) → there is no single codebase to read, so the grounded answer will
        // be thin. Say so plainly; the honest fix is to run /dive from inside the target repo.
        if root == FileManager.default.homeDirectoryForCurrentUser.path {
            note(paint("33", "│ ⚠ this is your HOME dir, not a repo — cd into the project and re-run /dive for a real code read"))
        }
        note(dim("▤ dive · repo map → code read (LOCAL, no web) → multi-model → synthesize"))

        let start = await diveStep("🔎", "start dive run") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "start", "goal": goal], context: context)
        }
        guard start.success, let runID = start.metadata["run_id"] else {
            err("dive · failed to start: \(start.error ?? start.output)")
            return 1
        }

        // REPO CONTEXT ONLY — the current project's own files. Deliberately NO web search and NO /Volumes
        // estate sweep: those two steps are exactly what mis-routed a codebase question into another repo.
        _ = await diveStep("📂", "repo context (our files)") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "context", "run_id": runID,
                                            "query": goal, "limit": 12], context: context)
        }

        let synth = await diveStep("📝", "synthesize from our code") {
            await tools.execute(name: "research_run",
                                arguments: ["action": "synthesize", "run_id": runID], context: context)
        }
        guard synth.success else {
            err("dive · incomplete: \(synth.error ?? synth.output)")
            return 1
        }

        // MULTI-AGENT READ: every reachable model analyzes the SAME grounded code dossier; the panel is
        // synthesized into one file-cited verdict. Wide council = consultation (no build hand-off): dive
        // answers the question, it does not edit.
        let brief = """
        Deep-dive question about OUR OWN codebase (repo root: \(root)): \(goal)

        Answer ONLY from the code evidence below — this is a LOCAL code read, NOT web research. Cite the
        concrete files/paths the evidence names. If the evidence doesn't settle it, say exactly what's
        missing and which file to open next. Do NOT speculate about other repos or the outside world.

        ── CODE EVIDENCE (from our repo) ──
        \(synth.output)
        """
        return await runWideCouncil(opts, goal: brief, registry: registry, root: root,
                                    providerId: providerId, model: model, rolesOverride: rolesOverride)
    }
}
