import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Self-heal, domain-learning, legal-research dispatch + usage/summary/status (run() decomposition — behavior-identical methods relocated from KistREPL.run())
extension KistREPL {
        // R4: arm a natural-language TEAM ("gemini be the eyes for deepseek", "deepseek codes and mimo
        // reviews", "work as a team"). Binds the lead (coder) + co (reviewer) across vendors and turns on
        // the review→fix loop, so a single goal is accomplished by the AIs working together, not one model.
        func armTeam(_ team: TeamIntent) {
            func resolve(_ name: String?) -> ProviderBinding? {
                guard let name, !name.isEmpty else { return nil }
                return Self.resolveModelSpec(name, currentProvider: roleSelection.fallback.providerId,
                                             knownProviders: providerAliases, providerModels: providerModels)
            }
            if let name = team.lead, resolve(name) == nil {
                print("\u{001B}[37m↳ team: no configured model for '\(name)' — keeping current lead\u{001B}[0m")
            }
            if let name = team.co, resolve(name) == nil {
                print("\u{001B}[37m↳ team: no configured model for '\(name)' — keeping current reviewer\u{001B}[0m")
            }
            if let lead = resolve(team.lead) {
                copilot.lead = lead
                _ = roleSelection.setDefault(lead, knownProviders: providerAliases)
                _ = roleSelection.assign(.coder, to: lead, knownProviders: providerAliases)
                autoRouting = false                          // a named lead pins the coding model
                activeBinding = roleSelection.fallback
                if let loopFactory {
                    loop = loopFactory(roleSelection.fallback, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking)
                }
            }
            if let co = resolve(team.co) {
                copilot.co = co
                _ = roleSelection.assign(.critic, to: co, knownProviders: providerAliases)
            }
            copilot.enabled = true
            let leadB = copilot.lead ?? roleSelection.fallback
            let coB = copilot.co ?? roleSelection.fallback
            // Don't let one model review AND fix its own code (no second model resolved). Keep the
            // review (advisory) but leave auto-fix off — a self-critique-then-self-fix is a no-op that
            // just burns tokens (review catch).
            let sameModel = leadB.providerId == coB.providerId && leadB.model == coB.model
            copilot.autoFix = !sameModel
            if sameModel {
                print("\u{001B}[35m⎇ team\u{001B}[0m · only one model configured — \(TeamLanguage.displayName(coB.providerId)) will review (advisory). Name a second model to enable review→fix.")
            } else {
                print("\u{001B}[35m⎇ team armed\u{001B}[0m · \(TeamLanguage.displayName(leadB.providerId)) building · "
                    + "\(TeamLanguage.displayName(coB.providerId)) reviewing · review→fix on")
            }
        }

        func consumeTurnUsageDelta() async -> [AgentSpan] {
            guard let traceRecorder else { return [] }
            let spans = await traceRecorder.all()
            let before = Set(usageSnapshot.map(\.id))
            let delta = spans.filter { !before.contains($0.id) }
            usageSnapshot = spans
            submittedTurnSpans.append(contentsOf: delta)
            if !UsageLedger.append(projectRoot: projectRoot, spans: delta) {
                print("\u{001B}[37musage ledger warning · could not persist local usage accounting\u{001B}[0m")
            }
            return delta
        }

        func printTurnUsage() async {
            let delta = await consumeTurnUsageDelta()
            let summary = UsageCost.summarize(spans: delta)
            guard summary.tokens > 0 else { return }
            print("\u{001B}[37m\(summary.render(label: "usage"))\u{001B}[0m")
        }

        func printSessionUsage() async {
            guard let traceRecorder else { print("usage: unavailable"); return }
            let spans = await traceRecorder.all()
            if !UsageLedger.append(projectRoot: projectRoot, spans: spans) {
                print("\u{001B}[37musage ledger warning · could not persist local usage accounting\u{001B}[0m")
            }
            print(UsagePanel.render(sessionSpans: spans, projectRoot: projectRoot,
                                    color: Self.stdoutColorEnabled(projectRoot: projectRoot)))
        }

        func dispatchSelfHealAgents(report: SelfHealMissionReport,
                                    objective: String,
                                    automatic: Bool) async {
            guard report.writeSucceeded else {
                print("\u{001B}[31mself-heal dispatch blocked: mission report was not durably written\u{001B}[0m")
                return
            }
            guard let runSpecialist else {
                print("\u{001B}[31mself-heal dispatch needs specialist run support in this REPL\u{001B}[0m")
                return
            }
            // Automatic repair must not run while the session is in plan mode
            // (read-only proposals). The builder/critic need edit_file+run_command;
            // in plan mode those are blocked mid-run, which is exactly the useless
            // "blocked by plan mode" half-dispatch we saw. Silently forcing execute
            // would be privilege escalation, so defer with an actionable message.
            if automatic && perm.effectivePlan {
                print("\u{001B}[33mCaptain self-heal deferred: plan mode is on (read-only). Turn plan mode off to let repair specialists act.\u{001B}[0m")
                return
            }
            let store = OrganizationalLearningStore(projectRoot: projectRoot)
            var priorEvidence: [String] = []
            // The clean HANDOFF: the researcher produces a machine-readable repair spec, and the BUILDER
            // receives ONLY that (not the research transcript) so it executes instead of re-researching.
            var researcherHandoff: SelfHealHandoff?
            if automatic {
                print("\u{001B}[33mCaptain supervisor dispatch\u{001B}[0m · \(report.agentAssignments.count) repair specialist(s) · clean handoff")
            }
            for assignment in report.agentAssignments {
                let agentColor = SpecialistRegistry(projectRoot: projectRoot)
                    .named(assignment.specialistName)
                    .flatMap { SpecialistDefinition.ansi(forColor: $0.color) }
                let tinted = agentColor.map { "\u{001B}[\($0)m\(assignment.specialistName)\u{001B}[0m" }
                    ?? assignment.specialistName
                let evidenceBrief = priorEvidence.isEmpty
                    ? ""
                    : "\n\nEvidence from earlier self-heal specialists:\n" + priorEvidence.joined(separator: "\n\n")
                // The builder gets the immutable handoff spec ONLY — no transcript, no "here's another
                // idea". Every other role keeps the chained evidence (they review/decide on the work).
                let taskForAgent: String
                if assignment.specialistName == "self-heal-builder", let h = researcherHandoff, h.isActionable {
                    taskForAgent = h.builderBrief()
                } else {
                    taskForAgent = assignment.task + evidenceBrief
                }
                print("\u{001B}[2m⇢ self-heal delegating to \(tinted) · \(assignment.role) · preferred \(assignment.preferredModel)\u{001B}[0m")
                if let summary = await runSpecialist(assignment.specialistName,
                                                      taskForAgent,
                                                      perm.effectiveApproval(),
                                                      perm.effectivePlan) {
                    print("\u{001B}[36;1m⇠ \(assignment.specialistName)\u{001B}[0m")
                    priorEvidence.append("## \(assignment.specialistName)\n\(summary)")
                    // Parse the researcher's handoff. ACTION-FIRST: if it didn't hand off an actionable
                    // repair, HALT — do not churn more research/review/teach tasks on an unproven cause.
                    if assignment.specialistName == "self-heal-researcher" {
                        researcherHandoff = SelfHealHandoff.parse(from: summary)
                        if let h = researcherHandoff, h.isActionable {
                            print("\u{001B}[36m⇢ handoff → builder\u{001B}[0m\u{001B}[2m · \(h.rootCause) · \(Int((h.confidence*100).rounded()))% · files: \(h.targetFiles.joined(separator: ", "))\u{001B}[0m")
                        } else {
                            _ = store.recordSelfHealSpecialistOutput(objective: objective,
                                                                     assignment: assignment, summary: summary)
                            let why = researcherHandoff?.blockedReason ?? "no actionable handoff (root cause not pinned)"
                            print("\u{001B}[33mself-heal halted after research: \(why). Escalate — not opening more research.\u{001B}[0m")
                            break
                        }
                    }
                    if let artifact = store.recordSelfHealSpecialistOutput(objective: objective,
                                                                            assignment: assignment,
                                                                            summary: summary) {
                        let memory = artifact.memoryRecorded ? "indexed" : "not indexed"
                        let ledger = artifact.evidenceLedgerRecorded ? "ledgered" : "ledger failed"
                        let taskIDs = artifact.updatedTaskIDs.isEmpty
                            ? "no task ids"
                            : "tasks " + artifact.updatedTaskIDs.map(String.init).joined(separator: ",")
                        print("\u{001B}[2mself-heal evidence: \(artifact.path) · \(memory) · \(ledger) · \(taskIDs) · task evidence updated: \(artifact.taskEvidenceUpdated)\u{001B}[0m")
                        let verificationEvidence = CaptainFailureAnalysis.extractStructuredEvidence(from: priorEvidence.joined(separator: "\n\n"))
                        if verificationEvidence.isEmpty {
                            print("\u{001B}[2mself-heal repair verification: awaiting explicit VERIFY/proof lines\u{001B}[0m")
                        } else if let verification = try? CaptainFailureAnalysis(projectRoot: projectRoot)
                            .recordRepairVerificationIfChanged(evidence: verificationEvidence) {
                                let missing = verification.missingVerification.isEmpty
                                    ? "all verification checks matched"
                                    : "\(verification.missingVerification.count) missing check(s)"
                                print("\u{001B}[2mself-heal repair verification: \(verification.status.rawValue) · \(missing)\u{001B}[0m")
                                if let evidence = verification.structuredEvidence, !evidence.isEmpty {
                                    let proof = CaptainFailureAnalysis.renderVerificationEvidenceSummary(evidence)
                                    print("\u{001B}[2mself-heal proof: \(proof)\u{001B}[0m")
                                }
                        }
                    } else {
                        print("\u{001B}[31mself-heal evidence capture failed for \(assignment.specialistName)\u{001B}[0m")
                        break
                    }
                } else {
                    print("\u{001B}[31mself-heal agent unavailable: \(assignment.specialistName)\u{001B}[0m")
                    break
                }
            }
        }

        @discardableResult
        func openFailureAnalysis(goal: String,
                                 summary: String,
                                 automaticRepair: Bool) async -> CaptainFailureAnalysisReport {
            let evo = SelfEvolutionEngine.decide(
                signals: FailureSignals.from(turnEvidenceSnapshot()),
                availableTools: loop.toolNames,
                ledgerHistory: SelfEvolutionLedger(projectRoot: projectRoot).load(),
                now: Date().timeIntervalSince1970)
            let deferred = Self.automaticRepairDeferral(summary: summary, decision: evo)
            let failure = CaptainFailureAnalysis(projectRoot: projectRoot)
                .analyze(goal: goal,
                         summary: summary,
                         trajectory: turnEvidenceSnapshot(),
                         proofEntries: proofStore?.lastEntries() ?? [],
                         seedTasks: deferred == nil)
            let persisted = failure.writeSucceeded
                ? failure.path
                : "write failed: \(failure.writeError ?? "unknown error")"
            print("\u{001B}[33mCaptain failure analysis\u{001B}[0m · \(failure.capsule.likelyLayer.rawValue) · confidence \(failure.capsule.confidence)% · \(persisted) · seeded \(failure.seededTasks) task(s)")
            if let deferred {
                print("\u{001B}[33mCaptain self-heal deferred: \(deferred)\u{001B}[0m")
                return failure
            }
            guard automaticRepair,
                  failure.writeSucceeded,
                  Self.shouldAutoSuperviseFailure(goal: goal)
            else { return failure }

            var objective = Self.supervisorRepairObjective(for: failure.capsule)
            // SELF-EVOLUTION: classify WHY this failed and steer the repair toward the RIGHT recovery instead
            // of assuming every failure is a code bug (which is why "unknown Windows 98 run command" gave up —
            // no file to repair). knowledgeGap → discover+retry; toolLimit → extend (kist auto / foreign spec,
            // never blend repos); blocked → surface authority; taskBug → repair. The loop-guard (ledger) stops
            // a self-evolution from repeating or churning the binary.
            let culprit = evo.culpritTool.map { " · \($0)" } ?? ""
            let skip = evo.skipped.map { " · \u{001B}[33mSKIPPED: \($0)\u{001B}[0m" } ?? ""
            print("\u{001B}[36mself-evolution\u{001B}[0m · \(evo.category.rawValue) → \(evo.kind.rawValue)\(culprit)\(skip)")
            objective = "\(objective)\n\n[self-evolution — \(evo.category.rawValue) → \(evo.kind.rawValue)]\n\(evo.brief)"
            // Record the risky (extendTool) attempts so the ledger loop-guard can refuse a repeat next time.
            if evo.kind == .extendTool, evo.skipped == nil, let sig = evo.signature {
                SelfEvolutionLedger(projectRoot: projectRoot).record(SelfEvolutionAttempt(
                    tool: evo.culpritTool ?? "?", category: evo.category.rawValue,
                    signature: sig, outcome: "attempted", atEpoch: Date().timeIntervalSince1970))
            }
            let report = Self.handleSelfHealCommand("self-heal run \(objective)",
                                                    projectRoot: projectRoot,
                                                    trajectory: turnEvidenceSnapshot())
            let mission = report.writeSucceeded ? report.path : "write failed: \(report.writeError ?? "unknown error")"
            print("\u{001B}[33mCaptain supervisor opened repair mission\u{001B}[0m · \(mission) · seeded \(report.seededTasks) task(s)")
            await dispatchSelfHealAgents(report: report, objective: objective, automatic: true)
            return failure
        }

        static func automaticRepairDeferral(summary: String, decision: SelfEvolutionDecision) -> String? {
            if BudgetLedger.isBudgetStop(summary) {
                return "the spending limit stopped this turn; no repair tasks or agents were started. " + summary
            }
            if summary.hasPrefix("blocked by project scope") { return summary }
            if decision.kind == .surfaceBlocked { return decision.brief }
            if let skipped = decision.skipped { return skipped }
            if summary.hasPrefix("provider error:") || summary.hasPrefix("provider request limit reached") {
                return "provider unavailable or request budget exhausted; no repair agents were started. \(summary)"
            }
            if summary.hasPrefix("stopped early —") {
                return "the turn reached an enforced stop; no repair agents were started. \(summary)"
            }
            return nil
        }

        func printTurnSummary(outcomeSummary: String? = nil, success: Bool = true) async {
            let trajectory = turnEvidenceSnapshot()
            // `outcomeSummary` is the MODEL'S prose — it was ALREADY shown live (streamed token-by-token
            // during the turn), so we deliberately do NOT reprint it here (that caused "every answer twice").
            // It is not thrown away: it drives the grounding check that sets the dashboard confidence.
            let grounded = outcomeSummary.map { GroundedReviewValidator.audit($0, projectRoot: projectRoot).isGrounded } ?? true
            // The deterministic four-part recap (happened / changed / failed / next) — the at-a-glance
            // operating summary, shown ABOVE the panel (Active Minds · Tasks · Next). Full detail: /summary.
            let spans = await consumeTurnUsageDelta()
            print(Self.renderSimpleSummary(projectRoot: projectRoot, spans: spans,
                                           trajectory: trajectory, sessionStartedAt: sessionStart))
            // R2a (review catch): an ESC'd turn is not a failure — auto-opening a repair mission
            // (self-heal dispatch, token spend) before the user's queued instruction is the exact
            // opposite of "your turn".
            if !success, !lastTurnInterrupted {
                let goal = humanTranscript.reversed().first { $0.role == .user }?.content ?? "unknown turn"
                await openFailureAnalysis(goal: goal,
                                          summary: outcomeSummary ?? "turn failed without a model summary",
                                          automaticRepair: true)
            }
            let dashboard = Self.buildDashboard(roles: roleSelection, projectRoot: projectRoot,
                                                trajectory: trajectory, grounded: grounded,
                                                sessionStartedAt: sessionStart)
            // Only remember the report for `/confidence` on a SUCCESSFUL turn: a provider failure after
            // one clean tool call computes a misleading ~95% that must not be inherited by the next
            // `/confidence` (Codex catch). A failed turn keeps the last successful turn's report.
            if success { lastConfidenceReport = dashboard.confidenceReport }
            let compact = !success || !Self.turnHasMutatingWork(trajectory)
            let panelColor = Self.stdoutColorEnabled(projectRoot: projectRoot)
            print(compact ? dashboard.renderCompact(color: panelColor) : dashboard.render(color: panelColor))
            let hint = "proof: /logs · cost: /usage · board: /tasks · /summary for detail"
            print(panelColor ? "\u{001B}[2m\(hint)\u{001B}[0m" : hint)
        }

        /// Persist exactly one learning capsule for the submitted turn, after review/repair and the final
        /// deterministic contract have settled. Interim phase summaries remain display-only so a primary
        /// success cannot survive as a false pass when its automatic repair later fails.
        func recordSubmittedTurnLearning(outcomeSummary: String, success: Bool,
                                         authoredBy: ProviderBinding? = nil) async {
            let clean = outcomeSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !lastTurnInterrupted else { return }
            let trajectory = turnEvidenceSnapshot()
            let plan = PlanStore(projectRoot: projectRoot).load()
            let currentObjective = humanTranscript.reversed().first { $0.role == .user }?.content
            _ = OrganizationalLearningStore(projectRoot: projectRoot)
                .recordTurn(plan: plan, spans: submittedTurnSpans, trajectory: trajectory,
                            outcomeSummary: clean, success: success,
                            objective: currentObjective)

            // PER-MODEL SCORECARD (interactive path): record THIS turn's model outcome so /fix, /build and
            // normal turns also teach the Captain which models fail/loop. Success is REFEREE-measured
            // (settled turn success AND grounded), NEVER the model's raw claim, so a confident wrong answer
            // cannot score a model as strong. Feeds captainStrongRoles / ModelEscalator's pick.
            let goalText = currentObjective ?? clean
            let report = TrajectoryAnalyzer.analyze(trajectory, taskIntent: PromptCompiler.compile(goalText).intent)
            let toolFails = trajectory.filter { !$0.success }.count
            let failureRate = trajectory.isEmpty ? 0 : Double(toolFails) / Double(trajectory.count)
            let grounded = GroundedReviewValidator.audit(clean, projectRoot: projectRoot).isGrounded
            // P6 (two-gate consistency): the interactive scorecard was WEAKER than the great-loop done-gate —
            // `grounded` is only GroundedReviewValidator (a textual file-path check that doesn't even flag
            // bare filenames), missing EXECUTION grounding. So a "done" turn that mutated code but never ran a
            // real build/test — or gamed the verifier — could be logged verified=true and poison the model
            // scorecard / interactive policy learning. AND in the SAME GreatLoopVerifier the great loop
            // already trusts at KistRunner+GreatLoop.swift:219. Only computed when the turn otherwise counts
            // as verified (a success we might over-credit) — a failure is unverified regardless, so we skip
            // the git-diff cost.
            var verified = success && grounded
            if verified {
                let strongVerdict = GreatLoopVerifier.verify(
                    trajectory: trajectory, canRunCommands: loop.shellEnabled,
                    changedFiles: KistREPL.workingTreeChangedFiles(projectRoot: projectRoot),
                    diff: KistREPL.workingTreeDiff(projectRoot: projectRoot))
                verified = strongVerdict.isVerified
            }
            let author = authoredBy ?? activeBinding
            CaptainLearningStore(projectRoot: projectRoot).record(CaptainLearningSample(
                taskSignature: EffortController.signature(for: goalText),
                taskTags: CaptainLearningSample.inferTaskTags(from: goalText),
                language: nil, role: "turn",
                providerId: author.providerId, model: author.model,
                source: .liveEval, success: verified,
                tokens: UsageCost.summarize(spans: submittedTurnSpans).tokens,
                toolFailures: toolFails, atEpoch: Date().timeIntervalSince1970,
                failureReason: !success && Self.looksLikeRefusalOrPermissionStop(clean)
                    ? CaptainLearningSample.refusalOrPermissionStopReason
                    : verified ? nil
                    : CaptainLearningSample.scorecardReason(
                        providerFault: false, flaky: false, verificationRejected: false,
                        loopKind: report.issues.first?.kind.rawValue, failureRate: failureRate, ungrounded: success),
                failedAt: verified ? nil : "act",
                loopKinds: report.issues.map { $0.kind.rawValue },
                wasStuck: !report.healthy, failureRate: failureRate))

            // Roadmap #3: on a locally verified win, capture the evidence clock and durable replay
            // locator before detaching the advisory semantic-memory write.
            if verified, let rememberLesson, let replayRunID {
                let verifiedAt = Date()
                let boundedGoal = String(goalText.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }.joined(separator: " ").prefix(240))
                let observedKinds = report.issues.map { $0.kind.rawValue }.sorted().prefix(8)
                    .joined(separator: ", ")
                let lesson = "Locally checked self-heal completed for task: \(boundedGoal). Observed loop classes: \(observedKinds.isEmpty ? "none" : observedKinds). Consult the replay locator and re-run verification before reuse."
                let deposit = SemanticLessonDeposit(
                    text: lesson,
                    evidence: SemanticVerifiedEvidence(
                        observedAt: verifiedAt,
                        sourceLocator: "run:\(replayRunID)",
                        kind: .locallyCheckedLesson))
                await rememberLesson(deposit)
            }
        }

        func runSelfHealCommand(_ rawArgs: String) async {
            let report = Self.handleSelfHealCommand(rawArgs,
                                                    projectRoot: projectRoot,
                                                    trajectory: recorder?.snapshot() ?? [])
            print(report.text)
            let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
            print("\u{001B}[2m\(persisted) · board meeting: \(report.boardMeetingPath) · seeded self-heal tasks: \(report.seededTasks) · created specialists: \(report.createdSpecialists)\u{001B}[0m")
            guard Self.selfHealShouldRun(rawArgs) else {
                print("\u{001B}[2mrun \(report.dispatchCommand) to dispatch the self-heal agents\u{001B}[0m")
                return
            }
            let objective = Self.normalizedSelfHealObjective(rawArgs)
            await dispatchSelfHealAgents(report: report, objective: objective, automatic: false)
        }

        func runDomainLearningCommand(_ rawArgs: String) async {
            let report = Self.handleDomainLearningCommand(rawArgs,
                                                          projectRoot: projectRoot,
                                                          trajectory: recorder?.snapshot() ?? [])
            print(report.text)
            let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
            print("\u{001B}[2m\(persisted) · confidence: \(report.understandingConfidence)%/\(report.confidenceThreshold)% · seeded tasks: \(report.seededTasks) · knowledge debt: \(report.knowledgeDebtCreated) · created specialists: \(report.createdSpecialists)\u{001B}[0m")
            guard Self.domainLearningShouldRun(rawArgs) else {
                print("\u{001B}[2mrun \(report.dispatchCommand) to dispatch the domain-learning specialists\u{001B}[0m")
                return
            }
            guard report.writeSucceeded else {
                print("\u{001B}[31mdomain-learning dispatch blocked: report was not durably written\u{001B}[0m")
                return
            }
            guard let runSpecialist else {
                print("\u{001B}[31mdomain-learning dispatch needs specialist run support in this REPL\u{001B}[0m")
                return
            }
            let assignments = report.canExecute
                ? report.agentAssignments
                : report.agentAssignments.filter { assignment in
                    let name = assignment.specialistName.lowercased()
                    return name.contains("research") || name.contains("critic")
                        || name.contains("simulation") || name.contains("scout")
                        || name.contains("symbolic")
                }
            if !report.canExecute {
                print("\u{001B}[33mdomain-learning gate HOLD — dispatching research/simulation/critic specialists only\u{001B}[0m")
            }
            for assignment in assignments {
                let agentColor = SpecialistRegistry(projectRoot: projectRoot)
                    .named(assignment.specialistName)
                    .flatMap { SpecialistDefinition.ansi(forColor: $0.color) }
                let tinted = agentColor.map { "\u{001B}[\($0)m\(assignment.specialistName)\u{001B}[0m" }
                    ?? assignment.specialistName
                print("\u{001B}[2m⇢ domain learning delegating to \(tinted) · \(assignment.role) · preferred \(assignment.preferredModel)\u{001B}[0m")
                if let summary = await runSpecialist(assignment.specialistName,
                                                      assignment.task,
                                                      perm.effectiveApproval(),
                                                      perm.effectivePlan) {
                    // The specialist's output already streamed live through the
                    // spawner's own TerminalEventSink; re-printing `summary` here
                    // duplicated the whole answer (and dumped raw plan/CoT twice).
                    // Emit only a compact completion marker — the full text is still
                    // captured into evidence + the artifact below.
                    print("\u{001B}[36;1m⇠ \(assignment.specialistName)\u{001B}[0m")
                    if let artifact = OrganizationalLearningStore(projectRoot: projectRoot)
                        .recordDomainLearningSpecialistOutput(objective: report.objective,
                                                              assignment: assignment,
                                                              summary: summary) {
                        let memory = artifact.memoryRecorded ? "indexed" : "not indexed"
                        let ledger = artifact.evidenceLedgerRecorded ? "ledgered" : "ledger failed"
                        let taskIDs = artifact.updatedTaskIDs.isEmpty
                            ? "no task ids"
                            : "tasks " + artifact.updatedTaskIDs.map(String.init).joined(separator: ",")
                        print("\u{001B}[2mdomain-learning evidence: \(artifact.path) · \(memory) · \(ledger) · \(taskIDs) · task evidence updated: \(artifact.taskEvidenceUpdated)\u{001B}[0m")
                    } else {
                        print("\u{001B}[31mdomain-learning evidence capture failed for \(assignment.specialistName)\u{001B}[0m")
                    }
                } else {
                    print("\u{001B}[31mdomain-learning agent unavailable: \(assignment.specialistName)\u{001B}[0m")
                }
            }
        }

        func dispatchLegalResearchAgents(report: LegalResearchReport) async {
            guard report.writeSucceeded else {
                print("\u{001B}[31mlegal research dispatch blocked: dossier was not durably written\u{001B}[0m")
                return
            }
            guard let runSpecialist else {
                print("\u{001B}[31mlegal research dispatch needs specialist run support in this REPL\u{001B}[0m")
                return
            }
            var priorEvidence: [String] = []
            for assignment in report.agentAssignments {
                let agentColor = SpecialistRegistry(projectRoot: projectRoot)
                    .named(assignment.specialistName)
                    .flatMap { SpecialistDefinition.ansi(forColor: $0.color) }
                let tinted = agentColor.map { "\u{001B}[\($0)m\(assignment.specialistName)\u{001B}[0m" }
                    ?? assignment.specialistName
                let evidenceBrief = priorEvidence.isEmpty
                    ? ""
                    : "\n\nEvidence from earlier legal-research specialists:\n" + priorEvidence.joined(separator: "\n\n")
                print("\u{001B}[2m⇢ legal research delegating to \(tinted) · \(assignment.role) · preferred \(assignment.preferredModel)\u{001B}[0m")
                if let summary = await runSpecialist(assignment.specialistName,
                                                      assignment.task + evidenceBrief,
                                                      perm.effectiveApproval(),
                                                      perm.effectivePlan) {
                    // The specialist's output already streamed live through the
                    // spawner's own TerminalEventSink; re-printing `summary` here
                    // duplicated the whole answer (and dumped raw plan/CoT twice).
                    // Emit only a compact completion marker — the full text is still
                    // captured into evidence + the artifact below.
                    print("\u{001B}[36;1m⇠ \(assignment.specialistName)\u{001B}[0m")
                    priorEvidence.append("## \(assignment.specialistName)\n\(summary)")
                } else {
                    print("\u{001B}[31mlegal research agent unavailable: \(assignment.specialistName)\u{001B}[0m")
                }
            }
        }

        func runLegalResearchCommand(_ rawArgs: String, forceResearch: Bool) async {
            let report = Self.handleLegalResearchCommand(rawArgs,
                                                         projectRoot: projectRoot,
                                                         trajectory: recorder?.snapshot() ?? [])
            print(report.text)
            let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
            let jurisdiction = report.jurisdiction ?? "unknown jurisdiction"
            print("\u{001B}[2m\(persisted) · \(jurisdiction) · sources: \(report.extractedSourceCount)/\(report.sourceCount) extracted · seeded tasks: \(report.seededTasks) · created specialists: \(report.createdSpecialists) · memory: \(report.memoryRecords)\u{001B}[0m")

            guard report.writeSucceeded else {
                await openFailureAnalysis(goal: rawArgs,
                                          summary: "legal research workflow failed to write dossier: \(report.writeError ?? "unknown error")",
                                          automaticRepair: true)
                return
            }

            guard report.readyForResearch else {
                print("\u{001B}[33mlegal research gate HOLD\u{001B}[0m · " + report.blockers.joined(separator: "; "))
                print("\u{001B}[2manswer the blocker(s), then run \(report.dispatchCommand)\u{001B}[0m")
                return
            }

            guard forceResearch || Self.legalResearchShouldRun(rawArgs) else {
                print("\u{001B}[2mrun \(report.dispatchCommand) to hand this into evidence-first research\u{001B}[0m")
                return
            }

            if report.extractedSourceCount > 0 && !Self.legalResearchHasExternalDocumentConsent(rawArgs) {
                print("\u{001B}[33mlegal privacy gate HOLD\u{001B}[0m · document text was extracted locally but not sent to external research/models")
                print("\u{001B}[2mrerun with --send-docs or --allow-external after confirming you want this legal document text included in model/research handoff\u{001B}[0m")
                return
            }

            if let research {
                print("\u{001B}[33mlegal research handoff\u{001B}[0m · evidence-first /research")
                await runHeavyRoute(goal: report.researchGoal, intent: .research, mode: .inline,
                                    execution: "research", startProof: true) {
                    await research(report.researchGoal, roleSelection.bindings)
                }
            } else if runSpecialist != nil {
                print("\u{001B}[33mlegal research handoff\u{001B}[0m · specialist fallback")
                await dispatchLegalResearchAgents(report: report)
            } else {
                print("\u{001B}[31mlegal research handoff unavailable: no /research runner or specialist runner in this mode\u{001B}[0m")
                print("\u{001B}[2mmanual handoff: /research \(report.researchGoal.prefix(180))...\u{001B}[0m")
            }
        }

        func compactCost(_ s: UsageCostSummary) -> String {
            guard s.tokens > 0 else { return "—" }
            let tok = s.tokens >= 1000 ? String(format: "%.1fk tok", Double(s.tokens) / 1000) : "\(s.tokens) tok"
            return (s.knownUSD > 0 ? String(format: "$%.4f · ", s.knownUSD) : "") + tok
        }

        // The always-visible status line (#3): model/team in plain words, mode, cost, active + next task.
        // The persisted plan's doing:/next: line shows ONLY when the plan belongs to THIS session (its
        // file was written at/after sessionStart). A plan left on disk by a prior session — or auto-seeded
        // by an earlier council run — must not greet a cold start as "next:" (confusing, unrelated noise);
        // it stays silent until this session advances it, and is always reachable via /tasks.
        func renderStatusLine() async -> String {
            let bindings = roleSelection.bindings
            // Non-team case shows the model the loop is ACTUALLY running (activeBinding), not the startup
            // default — so the always-visible status line never lies after an auto-route switch (invariant).
            let modelLabel = TeamLanguage.describeTeam(bindings)
                ?? (TeamLanguage.displayName(activeBinding.providerId)
                    + (activeBinding.model.map { " (\($0))" } ?? ""))
            let cost = traceRecorder == nil ? "—" : compactCost(UsageCost.summarize(spans: await traceRecorder!.all()))
            let store = PlanStore(projectRoot: projectRoot)
            let persisted = store.load()
            let currentActive = persisted.active(since: sessionStart)
            // Show doing:/next: for work THIS session is on — but never greet a cold start with a stale
            // prior-session task (see PlanStatusVisibility). The board is always on /tasks.
            let showPlan = PlanStatusVisibility.shouldShow(planModifiedAt: store.modifiedAt(),
                                                           sessionStart: sessionStart,
                                                           hasActiveTask: currentActive != nil)
            let plan = showPlan ? persisted : Plan()
            var modeLabel: String
            switch perm.mode {
            case .normal: modeLabel = "chat"
            case .acceptEdits: modeLabel = "accept-edits"
            case .plan: modeLabel = "plan"
            case .bypass: modeLabel = "bypass"
            }
            // "Lois" wake word armed the required PEEL gate — keep that visible at every prompt so
            // the operator always knows research is running fail-closed symbolic-first.
            if peelMode.isActive { modeLabel += " · ◫lois" }
            return StatusLine(modelLabel: modelLabel,
                              mode: modeLabel,
                              cost: cost,
                              activeTask: (showPlan ? currentActive : nil).map { "[\($0.id)] \($0.title)" },
                              nextStep: (showPlan ? (currentActive ?? plan.nextActionable ?? plan.next) : nil)
                                .map { "[\($0.id)] \($0.title)" }).render()
        }

        func completionCandidates() -> [String] {
            if cachedSymbols == nil {
                cachedSymbols = InputCompleter.projectSymbols(projectRoot: projectRoot)
            }
            let providers = providerLabels.map { $0.split(separator: " ").first.map(String.init) ?? $0 }
            let models = providerModels.values.flatMap { $0 }
            return InputCompleter.candidates(commands: commands.names,
                                             providers: providers,
                                             models: models,
                                             projectRoot: projectRoot,
                                             symbolCache: { cachedSymbols ?? [] })
        }
}
