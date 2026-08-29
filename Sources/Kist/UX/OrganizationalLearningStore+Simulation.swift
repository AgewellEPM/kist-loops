import Foundation
import AgentCore

extension OrganizationalLearningStore {
    func runSimulationGate(plan: Plan, trajectory: [ActionRecord],
                           objective: String = "",
                           artifactObjective: String? = nil,
                           measuredTrialMode: CaptainSimulationMeasuredTrialMode = .preflight,
                           judgedTrialMode: CaptainSimulationMeasuredTrialMode = .interactive,
                           persist: Bool = true) -> CaptainSimulationGateReport {
        let evidence = CaptainProjectEvidence.capture(projectRoot: projectRoot)
        var draftRun = CaptainSimulationLab.build(objective: objective,
                                                  artifactObjective: artifactObjective,
                                                  plan: plan,
                                                  evidence: evidence,
                                                  generatedAt: now())
        // How coverage is JUDGED (full interactive suite vs preflight's own trials) — set before
        // any verdict is computed; attachingMeasuredTrials copies it forward on the run value.
        draftRun.judgedTrialMode = judgedTrialMode
        // NO-WRITE path (`--no-memory`, persist == false): compute + enforce the gate DECISION from the pure
        // `draftRun`, but WRITE nothing and RUN no measured trials. Measured trials call simulationEnvironment(),
        // which durably creates `.kist/simulation-{home,tmp}` under the project — so they MUST be skipped here or
        // --no-memory leaks disk state (caught by Codex, 2026-07-03). ensureMemoryArchitecture() also creates
        // durable dirs, so the guard precedes it too. The read above (CaptainProjectEvidence.capture) is a
        // read-only git/tree scan needed for the verdict; --no-memory suppresses PERSISTENCE + durable side
        // effects, not the reads/heuristics that inform the safety verdict. persistenceRequired:false tells the
        // enforcer NOT to fail-closed on the (intentional) absence of a write; the decision string is
        // contaminated so no human/log mistakes an unpersisted pass for a fully-vetted, recorded one.
        guard persist else {
            let text = CaptainSimulationLab.render(draftRun, reportPath: "",
                                                   seededTasks: 0, createdSpecialists: 0, benchmarkRecords: 0)
            return CaptainSimulationGateReport(path: "", text: text,
                                               objective: draftRun.objective, domainTitle: draftRun.domain.title,
                                               recommendedStrategy: draftRun.recommendedStrategy.name,
                                               decision: "[NON-PERSISTENT] " + draftRun.decision,
                                               acceptanceThreshold: draftRun.acceptanceThreshold,
                                               estimatedSuccess: draftRun.estimatedSuccess,
                                               failureRisk: draftRun.failureRisk,
                                               seededTasks: 0, createdSpecialists: 0, benchmarkRecords: 0,
                                               writeSucceeded: false, writeError: nil,
                                               persistenceRequired: false)
        }
        ensureMemoryArchitecture()
        let measuredTrials = runMeasuredSimulationTrials(run: draftRun,
                                                         evidence: evidence,
                                                         mode: measuredTrialMode)
        let run = CaptainSimulationLab.attachingMeasuredTrials(measuredTrials, to: draftRun)
        let path = simulationsRoot + "/\(run.id)-simulation.md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        let createdSpecialists = createSimulationSpecialists()
        let seededTasks = seedSimulationTasks(run: run, reportPath: relativePath)
        var benchmarkRecords = 0
        let persistenceFailureDecision = "HOLD EXECUTION; simulation evidence report could not be persisted."
        var text = CaptainSimulationLab.render(run,
                                               reportPath: relativePath,
                                               seededTasks: seededTasks,
                                               createdSpecialists: createdSpecialists,
                                               benchmarkRecords: benchmarkRecords)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: simulationsRoot, withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
            text = text.replacingOccurrences(of: "Decision: \(run.decision)",
                                             with: "Decision: \(persistenceFailureDecision)")
            text += [
                "",
                "## Evidence Persistence",
                "Status: FAILED",
                "Error: \(Self.safe(writeError ?? "unknown error"))",
                "Execution gate: \(persistenceFailureDecision)"
            ].joined(separator: "\n")
        }
        if writeSucceeded && run.passesGate {
            benchmarkRecords = recordSimulationBenchmark(run: run,
                                                         reportPath: relativePath,
                                                         trajectory: trajectory)
        }
        return CaptainSimulationGateReport(path: relativePath,
                                           text: text,
                                           objective: run.objective,
                                           domainTitle: run.domain.title,
                                           recommendedStrategy: run.recommendedStrategy.name,
                                           decision: writeSucceeded
                                                ? run.decision
                                                : persistenceFailureDecision,
                                           acceptanceThreshold: run.acceptanceThreshold,
                                           estimatedSuccess: run.estimatedSuccess,
                                           failureRisk: run.failureRisk,
                                           seededTasks: seededTasks,
                                           createdSpecialists: createdSpecialists,
                                           benchmarkRecords: benchmarkRecords,
                                           writeSucceeded: writeSucceeded,
                                           writeError: writeError)
    }

    @discardableResult
    func createSimulationSpecialists() -> Int {
        let registry = makeSpecialistRegistry(projectRoot)
        let existing = Set(registry.load().map(\.name))
        var created = 0
        let defs = [
            SpecialistDefinition(
                name: "simulation-architect",
                description: "Designs sandbox environments, probabilistic trial matrices, and verification evidence before real-world execution.",
                systemPrompt: """
                You are Kist's simulation architect. Before implementation reaches the real world, define the sandbox, assumptions, trial matrix, fake services or digital twin, success threshold, failure modes, and verification commands. Do not edit product code unless Captain explicitly assigns implementation elsewhere.
                """,
                toolAllowlist: ["read_file", "search_code", "run_command", "tasks"],
                modelAlias: "inherit",
                maxTurns: 6,
                memory: "project",
                color: "blue",
                source: "captain-simulation"),
            SpecialistDefinition(
                name: "risk-model-critic",
                description: "Critiques simulation assumptions, failure probabilities, blast radius, and accept/reject thresholds.",
                systemPrompt: """
                You are Kist's risk-model critic. Be skeptical of optimistic simulations. Look for missing failure modes, weak probability estimates, inadequate sandbox fidelity, and unsafe execution gates. Prefer concrete evidence and blocked recommendations over vague confidence.
                """,
                toolAllowlist: ["read_file", "search_code", "run_command", "tasks"],
                modelAlias: "inherit",
                maxTurns: 5,
                memory: "project",
                color: "purple",
                source: "captain-simulation")
        ]
        for def in defs where !existing.contains(def.name) {
            if (try? registry.save(def)) != nil { created += 1 }
        }
        return created
    }

    @discardableResult
    func seedSimulationTasks(run: CaptainSimulationRun,
                                     reportPath: String) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        let activeBefore = store.load().active
        var firstAddedID: Int?
        var count = 0
        let recommended = run.recommendedStrategy
        let commandProof = recommended.verificationCommands.isEmpty
            ? "Attach sandbox logs and trial evidence."
            : recommended.verificationCommands.joined(separator: "; ")

        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String,
                 _ verification: String, _ evidence: [String] = []) {
            guard !simulationTaskExists(title: title) else { return }
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

        add("PLAN: Simulation gate -- \(run.objective)", .plan, "captain",
            "Domain: \(run.domain.title). Recommended strategy: \(recommended.name). Decision: \(run.decision)",
            "Sandbox domain, risk threshold, strategy comparison, and rollback/evidence requirements are explicit.",
            "/simulate shows the simulation report and trial matrix.",
            [reportPath])
        add("RESEARCH: Define sandbox assumptions -- \(run.domain.title)", .research, "simulation-architect",
            "Document what the sandbox represents, what it does not represent, and which failure modes could escape it.",
            "Assumptions and known gaps are attached before the test task is marked done.",
            "Attach sandbox assumptions and failure-mode notes.",
            recommended.failureModes)
        add("TEST: Run probabilistic sandbox trials -- \(recommended.name)", .test, "simulation-architect",
            "Trial matrix: \(recommended.passedTrials)/\(recommended.trials) passed; estimated success \(recommended.estimatedSuccess)%; failure risk \(recommended.failureRisk)%.",
            "A repeatable sandbox trial log exists and the acceptance threshold is either met or explicitly blocked.",
            commandProof,
            [reportPath])
        add("TEST: Benchmark selected strategy -- \(recommended.name)", .test, "simulation-architect",
            "Convert the recommended strategy into a real benchmark/live-eval harness or a domain-specific experiment.",
            "Benchmark result can be retrieved later from Captain's benchmark memory.",
            commandProof,
            [Self.projectRelative(benchmarksPath, root: projectRoot)])
        add("REVIEW: Critique simulation risk model -- \(recommended.name)", .review, "risk-model-critic",
            "Challenge the probability estimate, sandbox fidelity, failure modes, and execution gate.",
            "Independent critique either clears the simulation gate or names blockers.",
            "Attach risk review notes and any commands run.",
            recommended.failureModes)
        add("DECISION: Execute or hold after simulation -- \(run.objective)", .decision, "captain",
            "Compare sandbox evidence, benchmark output, and risk critique before real execution.",
            "Captain either authorizes execution with evidence or holds the plan and writes the next research/simulation task.",
            "Do not execute until simulation, benchmark, review, and evidence tasks are done.",
            [reportPath])

        if activeBefore == nil, let firstAddedID {
            _ = store.update(id: firstAddedID, status: .inProgress)
        }
        return count
    }

    @discardableResult
    func recordSimulationBenchmark(run: CaptainSimulationRun,
                                           reportPath: String,
                                           trajectory: [ActionRecord]) -> Int {
        let strategy = run.recommendedStrategy
        let measured = run.measuredTrials.map {
            "\($0.command): \($0.status.rawValue) exit=\($0.exitCode.map(String.init) ?? "n/a") elapsed=\(String(format: "%.2fs", $0.elapsedSeconds))"
        }.joined(separator: "; ")
        let record = DiskMemoryRecord(
            id: "simulation-\(run.id)",
            title: "Simulation Gate: \(run.objective)",
            summary: "\(run.domain.title): \(strategy.name) measured-adjusted \(run.estimatedSuccess)% success / \(run.failureRisk)% failure risk.",
            body: [
                "Decision: \(run.decision)",
                "Trials: \(strategy.passedTrials)/\(strategy.trials) passed",
                "Executable trials: \(measured.isEmpty ? "none" : measured)",
                "Expected value: \(strategy.expectedValue)%",
                "Failure modes: \(strategy.failureModes.joined(separator: "; "))",
                "Required evidence: \(strategy.requiredEvidence.joined(separator: "; "))",
            "Verification commands: \(strategy.verificationCommands.joined(separator: "; "))",
            "Trajectory tools observed: \(Set(trajectory.map(\.tool)).sorted().joined(separator: ", "))"
        ].joined(separator: "\n"),
            source: reportPath,
            confidence: run.estimatedSuccess,
            impact: min(5, max(1, strategy.expectedValue / 20)),
            tags: ["simulation-gate", run.domain.rawValue, "probabilistic-trials", "benchmark"]
        )
        return appendGenericMemory(
            record, to: benchmarksPath, decayRate: .fast,
            at: Date(timeIntervalSince1970: run.generatedAt)) ? 1 : 0
    }

    struct MeasuredSimulationCommand {
        var display: String
        var launchPath: String
        var launchArgs: [String]
    }

    func runMeasuredSimulationTrials(run: CaptainSimulationRun,
                                             evidence: CaptainProjectEvidence,
                                             mode: CaptainSimulationMeasuredTrialMode) -> [CaptainSimulationMeasuredTrial] {
        guard run.domain == .software else { return [] }
        let commands = measuredSimulationCommandCandidates(run: run,
                                                           evidence: evidence,
                                                           mode: mode)
        guard !commands.isEmpty else { return [] }
        let timeout = mode == .preflight ? 20 : 120
        return commands.map {
            executeMeasuredSimulationCommand($0, timeoutSeconds: timeout)
        }
    }

    func measuredSimulationCommandCandidates(run: CaptainSimulationRun,
                                                     evidence: CaptainProjectEvidence,
                                                     mode: CaptainSimulationMeasuredTrialMode) -> [MeasuredSimulationCommand] {
        let rawCommands: [String]
        switch mode {
        case .preflight:
            rawCommands = isGitRepository(projectRoot) ? ["git diff --check"] : []
        case .interactive:
            var commands = run.recommendedStrategy.verificationCommands
            if isGitRepository(projectRoot) { commands.append("git diff --check") }
            rawCommands = commands
        }

        var seen = Set<String>()
        var out: [MeasuredSimulationCommand] = []
        for command in rawCommands {
            let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !seen.contains(clean) else { continue }
            seen.insert(clean)
            if let spec = measuredSimulationCommandSpec(clean, evidence: evidence) {
                out.append(spec)
            } else if mode == .interactive {
                out.append(MeasuredSimulationCommand(display: clean,
                                                     launchPath: "",
                                                     launchArgs: []))
            }
        }
        return out
    }

    func measuredSimulationCommandSpec(_ command: String,
                                               evidence: CaptainProjectEvidence) -> MeasuredSimulationCommand? {
        let root = projectRoot
        switch command {
        case "git diff --check":
            guard isGitRepository(root), let git = trustedSimulationExecutable("git") else { return nil }
            return MeasuredSimulationCommand(display: command, launchPath: git, launchArgs: ["diff", "--check"])
        case "./test.sh":
            let script = (root as NSString).appendingPathComponent("test.sh")
            guard let trustedScript = trustedProjectScript(script) else { return nil }
            return MeasuredSimulationCommand(display: command, launchPath: trustedScript, launchArgs: [])
        case "swift test":
            guard evidence.testEntrypoints.contains(command),
                  FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("Package.swift")),
                  let swift = trustedSimulationExecutable("swift") else { return nil }
            return MeasuredSimulationCommand(display: command, launchPath: swift, launchArgs: ["test"])
        case "npm test":
            guard evidence.testEntrypoints.contains(command),
                  FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("package.json")),
                  let npm = trustedSimulationExecutable("npm") else { return nil }
            return MeasuredSimulationCommand(display: command, launchPath: npm, launchArgs: ["test"])
        case "cargo test":
            guard evidence.testEntrypoints.contains(command),
                  FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("Cargo.toml")),
                  let cargo = trustedSimulationExecutable("cargo") else { return nil }
            return MeasuredSimulationCommand(display: command, launchPath: cargo, launchArgs: ["test"])
        case "go test ./...":
            guard evidence.testEntrypoints.contains(command),
                  FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("go.mod")),
                  let go = trustedSimulationExecutable("go") else { return nil }
            return MeasuredSimulationCommand(display: command, launchPath: go, launchArgs: ["test", "./..."])
        default:
            return nil
        }
    }

    func executeMeasuredSimulationCommand(_ command: MeasuredSimulationCommand,
                                                  timeoutSeconds: Int) -> CaptainSimulationMeasuredTrial {
        let started = Date()
        guard !command.launchPath.isEmpty else {
            return CaptainSimulationMeasuredTrial(command: command.display,
                                                  status: .skipped,
                                                  exitCode: nil,
                                                  timedOut: false,
                                                  elapsedSeconds: 0,
                                                  sandbox: "not executed",
                                                  outputExcerpt: "unsupported command for automatic sandbox execution")
        }
        let outcome = SandboxedProcessRunner.runRequired(
            launchPath: command.launchPath,
            launchArgs: command.launchArgs,
            root: projectRoot,
            cwd: projectRoot,
            env: simulationEnvironment(),
            timeoutSeconds: timeoutSeconds,
            capPerStream: 24_000)
        let elapsed = Date().timeIntervalSince(started)
        let status: CaptainSimulationMeasuredTrial.Status
        if outcome.timedOut {
            status = .timedOut
        } else if outcome.exitCode == 0 {
            status = .passed
        } else {
            status = .failed
        }
        return CaptainSimulationMeasuredTrial(command: command.display,
                                              status: status,
                                              exitCode: outcome.exitCode,
                                              timedOut: outcome.timedOut,
                                              elapsedSeconds: elapsed,
                                              sandbox: outcome.sandbox,
                                              outputExcerpt: Self.safe(String(outcome.combined.prefix(800))).singleLine)
    }

    func isGitRepository(_ root: String) -> Bool {
        guard let git = trustedSimulationExecutable("git") else { return false }
        let outcome = SandboxedProcessRunner.runRequired(launchPath: git,
                                                         launchArgs: ["rev-parse", "--is-inside-work-tree"],
                                                         root: projectRoot,
                                                         cwd: root,
                                                         env: simulationEnvironment(),
                                                         timeoutSeconds: 5,
                                                         capPerStream: 2_000)
        return outcome.exitCode == 0 && outcome.combined.lowercased().contains("true")
    }

    func trustedSimulationExecutable(_ name: String) -> String? {
        let candidates = [
            "/usr/bin/\(name)",
            "/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)"
        ]
        return candidates.compactMap { path -> String? in
            let resolved = (path as NSString).resolvingSymlinksInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)
                && !isDir.boolValue
                && FileManager.default.isExecutableFile(atPath: resolved)
                && isTrustedSimulationExecutablePath(resolved) else { return nil }
            return resolved
        }.first
    }

    func trustedProjectScript(_ path: String) -> String? {
        let root = (projectRoot as NSString).resolvingSymlinksInPath
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard resolved == (root as NSString).appendingPathComponent("test.sh"),
              resolved.hasPrefix(root + "/"),
              FileManager.default.isExecutableFile(atPath: resolved) else { return nil }
        return resolved
    }

    func isTrustedSimulationExecutablePath(_ path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        let root = (projectRoot as NSString).resolvingSymlinksInPath
        guard resolved != root, !resolved.hasPrefix(root + "/") else { return false }
        guard !resolved.hasPrefix("/tmp/"), !resolved.hasPrefix("/private/tmp/") else { return false }
        let allowedPrefixes = ["/usr/bin/", "/bin/", "/usr/local/bin/", "/opt/homebrew/bin/"]
        return allowedPrefixes.contains { resolved.hasPrefix($0) }
    }

    func simulationEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        let home = (projectRoot as NSString).appendingPathComponent(".kist/simulation-home")
        let tmp = (projectRoot as NSString).appendingPathComponent(".kist/simulation-tmp")
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "HOME": home,
            "TMPDIR": tmp
        ]
        for key in ["LANG", "LC_ALL", "LC_CTYPE", "TERM"] {
            if let value = parent[key] { env[key] = value }
        }
        return env
    }

}
