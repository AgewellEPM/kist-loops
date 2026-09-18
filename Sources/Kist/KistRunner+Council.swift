import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Council (agent conference to kanban to optional builder handoff) — extracted from KistRunner.swift to keep the core orchestration file under the
// size limit. Part of `enum KistRunner`.
extension KistRunner {
    // MARK: - Council (agent conference -> kanban -> optional builder handoff)

    static func runCouncil(_ opts: KistOptions, goal: String, execute: Bool,
                                   registry: ProviderRegistry, root: String,
                                   tools: ToolRegistry, context: ToolContext,
                                   providerId: String, model: String?,
                                   rolesOverride: RoleBindings? = nil,
                                   researchDossier: String? = nil,
                                   researchRunID: String? = nil,
                                   seedBoard: Bool = true,
                                   capture: CouncilPipelineCaptureBox? = nil) async -> Int32 {
        guard let requestedRoles = rolesOverride ?? resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }
        let roles = autoCouncilRoles(requestedRoles, registry: registry)
        let memory = opts.noMemory ? nil : ProjectMemory(root: root)
        let recorder = TraceRecorder(traceId: TraceID.make())
        if roles != requestedRoles {
            note("council · auto-team · \(roles.summary)")
        } else if !roles.isHeterogeneous {
            note("council · single-provider · assign roles with /roles coder deepseek /roles critic gemini, or configure more provider keys")
        }
        note("kist · council · \(roles.summary) · \(root)\(execute ? " · execute" : "")")

        let progress = councilResearchProgress(projectRoot: root, runID: researchRunID)
        // ONE ledger for the whole --budget run: council AND the plan-execute it hands off to draw
        // from the same cap (Codex gate C3#1 — a fresh ledger per stage doubled the effective budget).
        let runBudget = opts.makeBudget()
        let result = await AICouncil(providers: registry, roles: roles,
                                     memoryContext: memory?.planningContext(episodeLimit: 8),
                                     researchDossier: researchDossier,
                                     recorder: recorder,
                                     progress: progress,
                                     budget: runBudget,
                                     requireStructuredCriticVerdict: true,
                                     agentMemory: opts.noMemory ? nil : context.agentMemory).run(goal: goal)
        let path: String
        do {
            path = try writeCouncilArtifact(result.markdown, goal: goal, root: root)
        } catch {
            err("council · failed to write artifact: \(error)")
            return 1
        }
        capture?.set(CouncilPipelineCapture(result: result, artifactPath: path))

        if let criticFailure = requiredCouncilCriticFailure(result) {
            note("council · incomplete artifact saved · \(path)")
            err("council · incomplete: \(criticFailure)")
            memory?.recordEpisode(Episode(goal: "council: \(goal)", success: false,
                                          summary: criticFailure, at: Date()))
            for line in await recorder.summary().terminalLines() { note(line) }
            return 1
        }

        note("council · board saved · \(path)")
        // Legible primitive, not a wall of prose (#6/#7): mind gists → decision → next tasks → test plan.
        // The full board stays in the saved artifact (the proof drawer, #8).
        print(CouncilCard.render(result, artifactPath: path, color: TerminalCapabilities.stdoutIsInteractive))
        let projectPlan = seedCouncilProjectBoard(goal: goal, finalPlan: result.finalPlan,
                                                  artifactPath: path, root: root,
                                                  persist: seedBoard)
        if seedBoard {
            note("task board seeded · \(projectPlan.tasks.count) tasks · show with /goals")
        } else {
            note("research synthesis complete · task board unchanged")
        }
        memory?.recordEpisode(Episode(goal: "council: \(goal)", success: true,
                                      summary: String(result.finalPlan.prefix(800)), at: Date()))
        for line in await recorder.summary().terminalLines() { note(line) }

        guard execute else { return 0 }
        note("council · handing builder brief to plan→execute")
        // `--execute` is explicit host authority to mutate. Keep that authority in a
        // host-authored objective; council prose is useful planning context, not a source of
        // permissions or completion requirements.
        let executionGoal = "Build and verify the council-selected implementation for:\n\(goal)"
        var builderOptions = opts
        builderOptions.goal = executionGoal
        builderOptions.planExecute = true
        let references = HeavyRouteResult.verifiedArtifactReferences(
            [path, ".kist/plan.json"], projectRoot: root)
        let advisoryContext = PriorResultContext(
            substantiveSummary: result.builderBrief,
            artifactReferences: references)
        return await runBuilderCompatibility(builderOptions, goal: executionGoal, registry: registry,
                                             root: root, tools: tools, context: context,
                                             checkpoints: nil, toolMode: .auto,
                                             providerId: providerId, model: model,
                                             rolesOverride: roles, budgetOverride: runBudget,
                                             riskObjective: executionGoal,
                                             advisoryContext: advisoryContext)
    }

    /// "Dig in deep" — the WIDE council: every reachable model answers the SAME question, synthesized into
    /// one verdict. Same CouncilCard render; no plan-execute hand-off (it's a consultation, not a build).
    static func runWideCouncil(_ opts: KistOptions, goal: String,
                                       registry: ProviderRegistry, root: String,
                                       providerId: String, model: String?,
                                       rolesOverride: RoleBindings? = nil,
                                       capture: CouncilPipelineCaptureBox? = nil) async -> Int32 {
        guard let requestedRoles = rolesOverride ?? resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }
        let roles = autoCouncilRoles(requestedRoles, registry: registry)
        let recorder = TraceRecorder(traceId: TraceID.make())
        let reachable = registry.providers.filter { registry.hasKey(for: $0) }.count
        note("kist · dig in deep · consulting up to \(min(reachable, 5)) model(s) · \(root)")
        let runBudget = opts.makeBudget()
        let agentMemory: AgentMemoryAccess?
        do { agentMemory = try Self.sharedAgentMemory(root: root, opts: opts) }
        catch { err("council shared memory setup failed: \(error)"); return 2 }
        let result = await AICouncil(providers: registry, roles: roles,
                                     recorder: recorder, budget: runBudget, agentMemory: agentMemory).runWide(goal: goal)
        let path: String
        do {
            path = try writeCouncilArtifact(result.markdown, goal: goal, root: root)
        } catch {
            err("dig in deep · failed to write panel artifact: \(error)")
            return 1
        }
        note("dig in deep · panel saved · \(path)")
        print(CouncilCard.render(result, artifactPath: path, color: TerminalCapabilities.stdoutIsInteractive))
        for line in await recorder.summary().terminalLines() { note(line) }
        guard usableWideCouncilResult(result) else {
            err("dig in deep · incomplete: no model returned a usable result")
            return 1
        }
        capture?.set(CouncilPipelineCapture(result: result, artifactPath: path))
        return 0
    }

    static func usableWideCouncilResult(_ result: CouncilRunResult) -> Bool {
        result.minds.contains(where: { !$0.failed })
            && !result.finalPlan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func councilResearchProgress(projectRoot: String, runID: String?) -> AICouncil.ProgressSink? {
        guard let runID, !runID.isEmpty else { return nil }
        return { status, message in
            guard let store = try? ResearchRunStore.open(projectRoot: projectRoot, runID: runID) else { return }
            _ = try? store.heartbeat(status: status, message: message)
        }
    }

    @discardableResult
    static func seedCouncilProjectBoard(goal: String, finalPlan: String, artifactPath: String,
                                        root: String, persist: Bool = true) -> Plan {
        let projectPlan = CouncilBoardCompiler.compile(goal: goal, finalPlan: finalPlan, artifactPath: artifactPath)
        if persist {
            PlanStore(projectRoot: root).replace(title: projectPlan.title, tasks: projectPlan.tasks)
        }
        return projectPlan
    }

    /// A council only earns the name if multiple minds can disagree. When the caller has not
    /// assigned a heterogeneous team, form a best-effort one from configured providers while
    /// keeping the planner on the current session model.
    static func autoCouncilRoles(_ roles: RoleBindings, registry: ProviderRegistry) -> RoleBindings {
        guard !roles.isHeterogeneous else { return roles }

        var next = roles
        let fallback = roles.fallback.providerId.lowercased()

        func firstAvailable(_ ids: [String]) -> ProviderBinding? {
            for id in ids {
                guard id.lowercased() != fallback,
                      let provider = registry.provider(id: id),
                      registry.hasKey(for: provider) else { continue }
                return ProviderBinding(providerId: provider.id)
            }
            return nil
        }

        if let worker = firstAvailable(["deepseek", "mimo", "qwen", "zhipu", "moonshot", "ollama", "mlx"]) {
            next = next.binding(.worker, to: worker)
        }
        if let coder = firstAvailable(["deepseek", "mimo", "qwen", "zhipu", "moonshot", "ollama", "mlx"]) {
            next = next.binding(.coder, to: coder)
        }
        if let critic = firstAvailable(["gemini", "grok", "anthropic", "openai", "deepseek"]) {
            next = next.binding(.critic, to: critic)
        }

        return next
    }

    private static func writeCouncilArtifact(_ markdown: String, goal: String, root: String) throws -> String {
        let dir = URL(fileURLWithPath: root).appendingPathComponent(".mythos/council", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = councilTimestamp()
        let slug = councilSlug(goal)
        let url = dir.appendingPathComponent("\(stamp)-\(slug).md")
        try Data(markdown.utf8).write(to: url, options: [.atomic])
        return url.path
    }

    private static func councilTimestamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func councilSlug(_ goal: String) -> String {
        let lower = goal.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
            if out.count >= 48 { break }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "council" : trimmed
    }

    // MARK: - Fleet (supervised parallel, heterogeneous)

}
