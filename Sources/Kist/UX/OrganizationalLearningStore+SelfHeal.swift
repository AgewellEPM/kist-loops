import Foundation
import AgentCore

extension OrganizationalLearningStore {
    func runSelfHealMission(plan: Plan, trajectory: [ActionRecord],
                            objective: String = "") -> SelfHealMissionReport {
        let instant = now()
        let cleanObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let missionObjective = cleanObjective.isEmpty
            ? "Captain self-heal: convert observations into assigned research, build, review, benchmark, and Teach Captain gates."
            : cleanObjective
        let boardMeeting = runBoardMeeting(plan: plan, trajectory: trajectory, at: instant)
        let currentPlan = PlanStore(projectRoot: projectRoot).load()
        let insights = DashboardResearchPlanner.build(for: currentPlan, projectRoot: projectRoot,
                                                       trajectory: trajectory, limit: 6)
        let weakness = selfHealWeakness(insights: insights,
                                        debts: openKnowledgeDebt(limit: 6, at: instant),
                                        latest: latestTemporallyEligibleCapsule(at: instant))
        let assignments = selfHealAssignments(weakness: weakness, objective: missionObjective)
        let createdSpecialists = createSelfHealSpecialists(assignments: assignments)
        let seededTasks = seedSelfHealTasks(weakness: weakness,
                                            objective: missionObjective,
                                            assignments: assignments,
                                            boardMeetingPath: boardMeeting.path)

        let timestamp = Int(instant.timeIntervalSince1970)
        let path = selfHealRoot + "/\(timestamp)-self-heal.md"
        let dispatchCommand = "/self-heal run"
        var text = renderSelfHealMission(objective: missionObjective,
                                          weakness: weakness,
                                          assignments: assignments,
                                          boardMeeting: boardMeeting,
                                          seededTasks: seededTasks,
                                          createdSpecialists: createdSpecialists,
                                          dispatchCommand: dispatchCommand)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: selfHealRoot, withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
            text += [
                "",
                "## Evidence Persistence",
                "Status: FAILED",
                "Error: \(Self.safe(writeError ?? "unknown error"))",
                "Dispatch gate: HOLD; self-heal agents cannot run until the mission report is durably written."
            ].joined(separator: "\n")
        }
        return SelfHealMissionReport(path: Self.projectRelative(path, root: projectRoot),
                                     text: text,
                                     boardMeetingPath: boardMeeting.path,
                                     seededTasks: seededTasks,
                                     createdSpecialists: createdSpecialists,
                                     promotedRules: boardMeeting.promotedRules,
                                     agentAssignments: assignments,
                                     dispatchCommand: dispatchCommand,
                                     writeSucceeded: writeSucceeded,
                                     writeError: writeError)
    }

    @discardableResult
    func recordSelfHealSpecialistOutput(objective rawObjective: String,
                                        assignment: SelfHealAgentAssignment,
                                        summary rawSummary: String) -> SelfHealSpecialistArtifact? {
        ensureMemoryArchitecture()
        let objective = Self.safe(rawObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Captain self-heal specialist output"
            : rawObjective.trimmingCharacters(in: .whitespacesAndNewlines))
        let summary = Self.safe(rawSummary.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !summary.isEmpty else { return nil }

        let instant = OrganizationalMemoryTemporal.canonicalInstant(now())
        let timestamp = Int(instant.timeIntervalSince1970)
        let path = selfHealRoot + "/specialists/"
            + "\(timestamp)-\(Self.slug(objective))-\(Self.slug(assignment.specialistName)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        let text = [
            "# Self-Heal Specialist Output",
            "",
            "Objective: \(objective)",
            "Specialist: \(Self.safe(assignment.specialistName))",
            "Role: \(Self.safe(assignment.role))",
            "Preferred model: \(Self.safe(assignment.preferredModel))",
            "",
            "## Assigned Repair Task",
            Self.safe(assignment.task),
            "",
            "## Specialist Summary",
            summary,
            "",
            "## Evidence Contract",
            "This artifact is captured so Captain's repair loop can be reviewed, benchmarked, and taught from durable evidence instead of terminal-only output.",
            "",
            "Source: \(relativePath)"
        ].joined(separator: "\n")

        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        let memoryRecorded = appendGenericMemory(DiskMemoryRecord(
            id: "AA-self-heal-specialist-\(timestamp)-\(Self.slug(assignment.specialistName))",
            title: "Self-Heal Specialist: \(assignment.specialistName)",
            summary: "\(assignment.role): \(excerpt(summary, limit: 180))",
            body: [
                "Objective: \(objective)",
                "Preferred model: \(assignment.preferredModel)",
                "Task: \(assignment.task.singleLine)",
                "Summary: \(summary)"
            ].joined(separator: "\n"),
            source: relativePath,
            confidence: 76,
            impact: 5,
            tags: ["self-heal", "specialist-output", assignment.specialistName]
        ), to: knowledgeIndexPath, decayRate: .medium, at: instant)

        let planStore = PlanStore(projectRoot: projectRoot)
        let plan = planStore.load()
        var updatedTaskIDs: [Int] = []
        for task in plan.tasks where task.owner == assignment.specialistName && !task.evidence.contains(relativePath) {
            if planStore.update(id: task.id, appendEvidence: [relativePath]) != nil {
                updatedTaskIDs.append(task.id)
            }
        }
        let ledgerRecorded = recordSpecialistEvidenceLedger(kind: .selfHealSpecialist,
                                                            objective: objective,
                                                            specialistName: assignment.specialistName,
                                                            role: assignment.role,
                                                            preferredModel: assignment.preferredModel,
                                                            artifactPath: relativePath,
                                                            memoryRecorded: memoryRecorded,
                                                            taskIDs: updatedTaskIDs)

        return SelfHealSpecialistArtifact(path: relativePath,
                                          memoryRecorded: memoryRecorded,
                                          taskEvidenceUpdated: updatedTaskIDs.count,
                                          updatedTaskIDs: updatedTaskIDs,
                                          evidenceLedgerRecorded: ledgerRecorded)
    }

    struct SelfHealWeakness: Equatable {
        var title: String
        var reason: String
        var supportingEvidence: [String]
        var benchmarkPlan: String
        var teachableRule: String
    }

    func selfHealWeakness(insights: DashboardInsightBundle,
                                  debts: [KnowledgeDebtRecord],
                                  latest: LearningCapsule?) -> SelfHealWeakness {
        var evidence: [String] = [
            "dashboard observation",
            "knowledge debt queue",
            "strategic intelligence board meeting"
        ]
        if let topResearch = insights.research.first {
            evidence.append("top research: \(topResearch.title) -- \(topResearch.reason)")
            if !topResearch.visit.isEmpty { evidence.append("source target: \(topResearch.visit)") }
        }
        if let topDebt = debts.first {
            evidence.append("top debt: \(topDebt.topic) -- \(topDebt.reason)")
        }
        if let latest {
            evidence.append("latest capsule: \(latest.taskTitle) \(latest.status.rawValue)")
        }
        if let failure = CaptainFailureAnalysis.latest(projectRoot: projectRoot) {
            evidence.append("latest failure capsule: \(failure.id) -- \(failure.observed)")
            evidence.append("likely failure layer: \(failure.likelyLayer.rawValue) @ \(failure.confidence)%")
            evidence.append(contentsOf: failure.evidence.prefix(3))
            return SelfHealWeakness(
                title: "Failure analysis: \(failure.observed)",
                reason: "Captain has a concrete failure capsule. Self-heal must investigate the likely \(failure.likelyLayer.rawValue) layer, confirm or reject the ranked hypotheses, repair the root cause, verify, and teach the permanent lesson.",
                supportingEvidence: Array(evidence.prefix(10)),
                benchmarkPlan: failure.verificationPlan.isEmpty
                    ? "Reproduce the failure, add a focused regression, then run the relevant suite."
                    : failure.verificationPlan.joined(separator: "; "),
                teachableRule: failure.teachCandidate
            )
        }
        return SelfHealWeakness(
            title: "Captain self-heal handoff loop",
            reason: "Captain can identify weaknesses and generate research/build queues, but the next step must become an assigned repair mission with independent research, implementation, review, benchmark evidence, and a Teach Captain accept/reject gate.",
            supportingEvidence: Array(evidence.prefix(8)),
            benchmarkPlan: "Run focused self-heal tests, then the full suite. Accept only if the mission seeds tasks, creates specialists, preserves operator gates, and produces a teachable decision.",
            teachableRule: "Captain self-healing must turn observations into assigned research, build, review, benchmark, and Teach Captain gates before changing platform behavior."
        )
    }

    @discardableResult
    func seedSelfHealTasks(weakness: SelfHealWeakness,
                                   objective: String,
                                   assignments: [SelfHealAgentAssignment],
                                   boardMeetingPath: String) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        let activeBefore = store.load().active
        var firstAddedID: Int?
        var count = 0
        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String,
                 _ verification: String, _ evidence: [String] = []) {
            guard !selfHealTaskExists(title: title) else { return }
            let task = store.add(title: title,
                                 detail: detail,
                                 owner: owner,
                                 kind: kind,
                                 acceptance: acceptance,
                                 verification: verification,
                                 evidence: evidence)
            if firstAddedID == nil { firstAddedID = task.id }
            count += 1
        }

        add("PLAN: Captain self-heal mission -- \(weakness.title)", .plan, "captain",
            "Objective: \(objective)\nWeakness: \(weakness.reason)",
            "Weakness, assigned agents, gates, and rollback path are explicit.",
            "/self-heal shows the mission report and dispatch plan.",
            [boardMeetingPath])
        add("RESEARCH: Self-heal evidence scan -- \(weakness.title)", .research, "self-heal-researcher",
            assignments.first { $0.specialistName == "self-heal-researcher" }?.task ?? weakness.reason,
            "Primary sources, competitor/source comparison, and benchmark implications are attached.",
            "Attach research archive notes and source targets to this task.",
            weakness.supportingEvidence)
        add("REPRODUCE: Prove the original failure first -- \(weakness.title)", .action, "self-heal-builder",
            "Before ANY fix: reproduce the EXACT original failure and capture its repro (command/input) "
                + "and observed error. A repair can only be proven if the failure it targets was first "
                + "shown to actually happen.\nWeakness: \(weakness.reason)",
            "The exact original failure is reproduced; its repro command + error are captured as evidence.",
            "Emit: VERIFY: <repro command> => FAIL: <captured error>  (the failure reproduced BEFORE the fix).",
            weakness.supportingEvidence)
        add("ACTION: Implement highest-confidence self-heal fix", .action, "self-heal-builder",
            assignments.first { $0.specialistName == "self-heal-builder" }?.task ?? weakness.reason,
            "Implementation is scoped, reversible, and tied to the mission weakness.",
            "RE-RUN the SAME repro from the REPRODUCE task — it must now PASS (emit VERIFY: <repro> => PASS "
                + "proving the exact original failure is gone) — then run focused tests for the touched subsystem.",
            [])
        add("REVIEW: Independent AI review of self-heal fix", .review, "self-heal-critic",
            assignments.first { $0.specialistName == "self-heal-critic" }?.task ?? weakness.reason,
            "Review identifies blocking findings or explicitly clears the change with evidence.",
            "Attach reviewer findings and commands run.",
            [])
        add("TEST: Benchmark self-heal behavior", .test, "self-heal-captain-gate",
            weakness.benchmarkPlan,
            "Focused tests and the full suite pass, or failures are recorded as blockers.",
            "swift test; git diff --check",
            [])
        add("DECISION: Teach Captain or reject self-heal lesson", .decision, "self-heal-captain-gate",
            assignments.first { $0.specialistName == "self-heal-captain-gate" }?.task ?? weakness.teachableRule,
            "Captain either promotes the lesson with evidence or writes the next repair task.",
            "/teach add <lesson> only after research, implementation, review, and tests pass.",
            [])

        if activeBefore == nil, let firstAddedID {
            _ = store.update(id: firstAddedID, status: .inProgress)
        }
        return count
    }

    func renderSelfHealMission(objective: String,
                                       weakness: SelfHealWeakness,
                                       assignments: [SelfHealAgentAssignment],
                                       boardMeeting: EvolutionBoardReport,
                                       seededTasks: Int,
                                       createdSpecialists: Int,
                                       dispatchCommand: String) -> String {
        var lines = [
            "# Captain Self-Heal Mission",
            "",
            "Objective: \(objective)",
            "",
            "## Diagnosed Weakness",
            weakness.title,
            "",
            "Reason: \(weakness.reason)",
            "",
            "Supporting evidence:",
        ]
        lines += weakness.supportingEvidence.map { "- \($0)" }
        lines += [
            "",
            "## Agent Dispatch",
        ]
        for assignment in assignments {
            lines += [
                "- \(assignment.specialistName) -- \(assignment.role)",
                "  Preferred model: \(assignment.preferredModel)",
                "  Task: \(assignment.task.replacingOccurrences(of: "\n", with: "\n  "))",
            ]
        }
        lines += [
            "",
            "## Acceptance Gate",
            "- Research evidence is attached before implementation hardens.",
            "- Builder changes are scoped and reversible.",
            "- Independent critic review either clears the change or blocks it.",
            "- Benchmarks/tests pass before acceptance.",
            "- Teach Captain promotes the lesson only after evidence.",
            "",
            "Benchmark plan: \(weakness.benchmarkPlan)",
            "Teachable rule candidate: \(weakness.teachableRule)",
            "",
            "## Dispatch",
            "Run now: \(dispatchCommand)",
            "Manual sequence:",
        ]
        lines += assignments.map { "- /agents run \($0.specialistName) \($0.task.singleLine)" }
        lines += [
            "",
            "## Artifacts",
            "Board meeting: \(boardMeeting.path)",
            "Seeded self-heal tasks: \(seededTasks)",
            "Created self-heal specialists: \(createdSpecialists)",
            "Promoted rules during board meeting: \(boardMeeting.promotedRules)",
        ]
        return lines.joined(separator: "\n")
    }

}
