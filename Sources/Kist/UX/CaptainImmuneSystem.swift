import Foundation
import AgentCore

struct CaptainImmuneSystemReport: Sendable, Equatable {
    enum Status: String, Sendable, Equatable {
        case pass = "PASS"
        case watch = "WATCH"
        case hold = "HOLD"
    }

    var path: String
    var text: String
    var status: Status
    var selfTestPath: String
    var selfHealPath: String?
    var simulationPath: String?
    var seededTasks: Int
    var blockers: [String]
    var writeSucceeded: Bool
    var writeError: String?
}

struct CaptainImmuneSystem: Sendable {
    let projectRoot: String
    private let now: @Sendable () -> Date

    init(projectRoot: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.projectRoot = ToolContext.canonicalize(projectRoot) ?? projectRoot
        self.now = now
    }

    func run(seedRepairs: Bool = true,
             trajectory: [ActionRecord] = []) -> CaptainImmuneSystemReport {
        let selfTest = CaptainSelfTestSuite(projectRoot: projectRoot, now: now)
            .run(seedFindings: seedRepairs)
        let plan = PlanStore(projectRoot: projectRoot).load()
        let store = OrganizationalLearningStore(projectRoot: projectRoot, now: now)
        let findings = selfTest.checks.filter { $0.status != .pass }
        let needsRepairMission = seedRepairs && (!findings.isEmpty || !selfTest.writeSucceeded)
        let objective = missionObjective(findings: findings, selfTest: selfTest)

        let selfHeal = needsRepairMission
            ? store.runSelfHealMission(plan: plan, trajectory: trajectory, objective: objective)
            : nil
        let simulation = needsRepairMission
            ? store.runSimulationGate(plan: plan,
                                      trajectory: trajectory,
                                      objective: objective,
                                      artifactObjective: objective,
                                      measuredTrialMode: .preflight)
            : nil

        var blockers: [String] = []
        if !selfTest.writeSucceeded {
            blockers.append("self-test report did not persist: \(selfTest.writeError ?? "unknown write error")")
        }
        if selfTest.failures > 0 {
            blockers.append("\(selfTest.failures) self-test failure(s)")
        }
        if let selfHeal, !selfHeal.writeSucceeded {
            blockers.append("self-heal mission did not persist: \(selfHeal.writeError ?? "unknown write error")")
        }
        if let simulation {
            if !simulation.writeSucceeded {
                blockers.append("simulation report did not persist: \(simulation.writeError ?? "unknown write error")")
            } else if !simulation.passesGate {
                blockers.append("simulation gate held: \(simulation.decision)")
            }
        }

        let status: CaptainImmuneSystemReport.Status
        if !blockers.isEmpty {
            status = .hold
        } else if selfTest.warnings > 0 {
            status = .watch
        } else {
            status = .pass
        }

        let timestamp = Int(now().timeIntervalSince1970)
        let root = projectRoot + "/.kist/learning/immune"
        let path = root + "/\(timestamp)-immune.md"
        let relativePath = Self.relative(path, root: projectRoot)
        let seededTasks = selfTest.seededTasks
            + (selfHeal?.seededTasks ?? 0)
            + (simulation?.seededTasks ?? 0)

        var text = render(status: status,
                          reportPath: relativePath,
                          objective: objective,
                          selfTest: selfTest,
                          selfHeal: selfHeal,
                          simulation: simulation,
                          seededTasks: seededTasks,
                          blockers: blockers,
                          seedRepairs: seedRepairs)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
            blockers.append("immune report did not persist: \(writeError ?? "unknown write error")")
            text = text.replacingOccurrences(of: "Status: \(status.rawValue)", with: "Status: HOLD")
            text += [
                "",
                "## Evidence Persistence",
                "Status: FAILED",
                "Error: \(safe(writeError ?? "unknown error"))",
                "Execution gate: HOLD; immune-system reports must persist before Captain can trust the loop."
            ].joined(separator: "\n")
        }

        let finalStatus: CaptainImmuneSystemReport.Status = blockers.isEmpty ? status : .hold
        return CaptainImmuneSystemReport(path: relativePath,
                                         text: text,
                                         status: finalStatus,
                                         selfTestPath: selfTest.path,
                                         selfHealPath: selfHeal?.path,
                                         simulationPath: simulation?.path,
                                         seededTasks: seededTasks,
                                         blockers: blockers,
                                         writeSucceeded: writeSucceeded,
                                         writeError: writeError)
    }

    private func missionObjective(findings: [CaptainSelfTestCheck],
                                  selfTest: CaptainSelfTestReport) -> String {
        if !selfTest.writeSucceeded {
            return "Captain immune-system repair: restore durable self-test evidence persistence before autonomous repair."
        }
        let failures = findings.filter { $0.status == .fail }
        if !failures.isEmpty {
            let titles = failures.prefix(3).map(\.title)
            return "Captain immune-system repair: " + titles.joined(separator: "; ")
        }
        let warnings = findings.filter { $0.status == .warn }
        if !warnings.isEmpty {
            let titles = warnings.prefix(3).map(\.title)
            return "Captain immune-system watch: " + titles.joined(separator: "; ")
        }
        return "Captain immune-system: no deterministic findings."
    }

    private func render(status: CaptainImmuneSystemReport.Status,
                        reportPath: String,
                        objective: String,
                        selfTest: CaptainSelfTestReport,
                        selfHeal: SelfHealMissionReport?,
                        simulation: CaptainSimulationGateReport?,
                        seededTasks: Int,
                        blockers: [String],
                        seedRepairs: Bool) -> String {
        var lines = [
            "# Captain Immune System",
            "",
            "Status: \(status.rawValue)",
            "Report: \(reportPath)",
            "Mode: \(modeDescription(status: status, seedRepairs: seedRepairs))",
            "\(objectiveLabel(status: status)): \(safe(objective))",
            "Seeded tasks: \(seededTasks)",
            "",
            "## Audit",
            "Self-test: \(selfTest.path)",
            "Checks: \(selfTest.passed) pass / \(selfTest.warnings) warn / \(selfTest.failures) fail",
            "Self-test persistence: \(selfTest.writeSucceeded ? "PASS" : "FAIL")",
        ]
        lines += ["", "## \(missionTitle(status: status))"]
        if let selfHeal {
            lines += [
                "Self-heal: \(selfHeal.path)",
                "Self-heal persistence: \(selfHeal.writeSucceeded ? "PASS" : "FAIL")",
                "Created specialists: \(selfHeal.createdSpecialists)",
                "Dispatch command: \(selfHeal.dispatchCommand)",
            ]
        } else {
            lines.append(status == .watch ? "No watch mission seeded in check-only mode." : "No repair mission needed.")
        }
        if let simulation {
            lines += [
                "",
                "## Simulation Gate",
                "Simulation: \(simulation.path)",
                "Simulation persistence: \(simulation.writeSucceeded ? "PASS" : "FAIL")",
                "Decision: \(simulation.decision)",
                "Estimated success: \(simulation.estimatedSuccess)%",
                "Failure risk: \(simulation.failureRisk)%",
            ]
        }
        lines += ["", "## Blockers"]
        if blockers.isEmpty {
            lines.append("- None.")
        } else {
            lines += blockers.map { "- \(safe($0))" }
        }
        let findings = selfTest.checks.filter { $0.status != .pass }
        lines += ["", "## Findings"]
        if findings.isEmpty {
            lines.append("- No deterministic self-test findings.")
        } else {
            for finding in findings.prefix(8) {
                lines += [
                    "- [\(finding.status.rawValue)] \(finding.title)",
                    "  Fix: \(safe(finding.fix))",
                ]
            }
        }
        lines += [
            "",
            "## Next",
            nextLine(status: status, selfHeal: selfHeal, seedRepairs: seedRepairs)
        ]
        return lines.joined(separator: "\n")
    }

    private func modeDescription(status: CaptainImmuneSystemReport.Status,
                                 seedRepairs: Bool) -> String {
        guard seedRepairs else { return "check-only" }
        switch status {
        case .pass:
            return "repair queue available"
        case .watch:
            return "watch queue seeded"
        case .hold:
            return "repair queue seeded"
        }
    }

    private func objectiveLabel(status: CaptainImmuneSystemReport.Status) -> String {
        switch status {
        case .pass:
            return "Objective"
        case .watch:
            return "Watch objective"
        case .hold:
            return "Repair objective"
        }
    }

    private func missionTitle(status: CaptainImmuneSystemReport.Status) -> String {
        switch status {
        case .watch:
            return "Watch Mission"
        case .pass, .hold:
            return "Repair Mission"
        }
    }

    private func nextLine(status: CaptainImmuneSystemReport.Status,
                          selfHeal: SelfHealMissionReport?,
                          seedRepairs: Bool) -> String {
        switch status {
        case .pass:
            return "No immune repair needed. Keep `/self-test` and full tests in the verification loop."
        case .watch:
            return seedRepairs
                ? "Review warning tasks in `/tasks`; dispatch `\(selfHeal?.dispatchCommand ?? "/self-heal run")` only if the warnings affect the next build."
                : "Run `/immune` to seed warning review tasks."
        case .hold:
            return seedRepairs
                ? "Do not expand autonomy until the blocker tasks pass and the repair mission has evidence."
                : "Run `/immune` to seed repair tasks and create a self-heal mission."
        }
    }

    private static func relative(_ path: String, root: String) -> String {
        let cleanRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        if path.hasPrefix(cleanRoot + "/") {
            return String(path.dropFirst(cleanRoot.count + 1))
        }
        return path
    }

    private func safe(_ text: String) -> String {
        let redacted = SecretScanner.redactSecrets(in: text)
        return redacted.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
