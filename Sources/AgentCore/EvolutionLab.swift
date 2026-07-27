import Foundation

/// Guardrails for the DGM-style evolution lab.
///
/// The lab may evolve prompts, routing, tools, and agent behavior, but it may not award itself a
/// "winner" by weakening the trust spine. Protected files can still be changed in an isolated branch
/// for human review; the automatic evaluator marks that candidate blocked.
public struct EvolutionPolicy: Sendable, Codable, Equatable {
    public let protectedGlobs: [String]
    public let requiredBenchmarkCommands: [String]

    public init(protectedGlobs: [String] = EvolutionPolicy.defaultProtectedGlobs,
                requiredBenchmarkCommands: [String] = []) {
        self.protectedGlobs = protectedGlobs
        self.requiredBenchmarkCommands = requiredBenchmarkCommands
    }

    public static let defaultProtectedGlobs: [String] = [
        "Sources/AgentCore/ForgeSeal.swift",
        "Sources/AgentCore/FleetSignoffLedger.swift",
        "Sources/AgentCore/Foreman.swift",
        "Sources/AgentCore/GitIsolation.swift",
        "Sources/AgentCore/FleetPromotionGate.swift",
        "Sources/AgentCore/PromotionAttestation.swift",
        "Sources/AgentCore/SecretMasker.swift",
        "Sources/AgentCore/Tools/ConfinedRoot.swift",
        "Sources/AgentCore/Tools/ProcessGroupRunner.swift",
        "Sources/AgentCore/Tools/RunCommandTool.swift",
        "Sources/AgentCore/Tools/SeatbeltSandbox.swift",
        "Sources/AgentCore/Tools/ToolRegistry.swift",
        "Sources/AgentCore/Fleet/CIIntegrityGuard.swift",   // a candidate may not weaken its own conscience
        "Sources/AgentCore/SECURITY.md",
    ]

    public func protectedFiles(in changedFiles: [String]) -> [String] {
        changedFiles.filter { file in
            // Any `.gitattributes` (at any depth) is protected — it can suppress a file's diff and blind the
            // integrity guard. (Defense-in-depth; GitIsolation also forces `--text` so the guard sees through
            // attributes regardless.) FleetMatcher has no `**`, so match the basename directly.
            if (file as NSString).lastPathComponent == ".gitattributes" { return true }
            return protectedGlobs.contains { glob in file == glob || FleetMatcher.matches(path: file, glob: glob) }
        }.sorted()
    }
}

public struct EvolutionBenchmarkResult: Sendable, Codable, Equatable {
    public let command: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let output: String

    public init(command: String, exitCode: Int32, timedOut: Bool, output: String) {
        self.command = command
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.output = output
    }

    public var success: Bool { !timedOut && exitCode == 0 }
}

public enum EvolutionCandidateStatus: String, Sendable, Codable, Equatable {
    case passed
    case failed
    case blocked
    case noChange
}

public struct EvolutionCandidateRecord: Sendable, Codable, Equatable {
    public let runID: String
    public let candidateID: String
    public let parentID: String?
    public let objective: String
    public let branch: String
    public let worktreePath: String
    public let baseSHA: String
    public let commitSHA: String
    public let status: EvolutionCandidateStatus
    public let score: Int
    public let changedFiles: [String]
    public let protectedFiles: [String]
    public let benchmarks: [EvolutionBenchmarkResult]
    public let summary: String
    public let createdAtEpoch: Double

    public init(runID: String,
                candidateID: String,
                parentID: String?,
                objective: String,
                branch: String,
                worktreePath: String,
                baseSHA: String,
                commitSHA: String,
                status: EvolutionCandidateStatus,
                score: Int,
                changedFiles: [String],
                protectedFiles: [String],
                benchmarks: [EvolutionBenchmarkResult],
                summary: String,
                createdAtEpoch: Double) {
        self.runID = runID
        self.candidateID = candidateID
        self.parentID = parentID
        self.objective = objective
        self.branch = branch
        self.worktreePath = worktreePath
        self.baseSHA = baseSHA
        self.commitSHA = commitSHA
        self.status = status
        self.score = score
        self.changedFiles = changedFiles
        self.protectedFiles = protectedFiles
        self.benchmarks = benchmarks
        self.summary = summary
        self.createdAtEpoch = createdAtEpoch
    }
}

public enum EvolutionEvaluator {
    public static func evaluate(runID: String,
                                candidateID: String,
                                parentID: String?,
                                objective: String,
                                branch: String,
                                worktreePath: String,
                                baseSHA: String,
                                commitSHA: String,
                                changedFiles: [String],
                                benchmarks: [EvolutionBenchmarkResult],
                                policy: EvolutionPolicy,
                                integrityViolations: [String] = [],
                                createdAtEpoch: Double) -> EvolutionCandidateRecord {
        let protected = policy.protectedFiles(in: changedFiles)
        let status: EvolutionCandidateStatus
        let score: Int
        let summary: String

        // The CONSCIENCE on the self-evolution path: a candidate that makes its own verifier easier
        // (deleted a test, added XCTSkip, focused/`|| true` the runner) is BLOCKED even if benchmarks went
        // green — a green exit earned by gaming the tests is the one thing self-evolution must never reward.
        if !protected.isEmpty || !integrityViolations.isEmpty {
            status = .blocked
            score = 0
            var reasons: [String] = []
            if !protected.isEmpty { reasons.append("changed protected trust-spine file(s): \(protected.joined(separator: ", "))") }
            if !integrityViolations.isEmpty { reasons.append("gamed the verifier: \(integrityViolations.joined(separator: "; "))") }
            summary = "blocked: " + reasons.joined(separator: " · ")
        } else if changedFiles.isEmpty {
            status = .noChange
            score = 0
            summary = "no change: candidate did not produce a diff"
        } else if benchmarks.contains(where: { !$0.success }) {
            let passed = benchmarks.filter(\.success).count
            status = .failed
            score = max(1, passed * 10)
            let failed = benchmarks.filter { !$0.success }.map(\.command).joined(separator: ", ")
            summary = "failed benchmark(s): \(failed)"
        } else {
            let reviewabilityBonus = max(0, 25 - max(0, changedFiles.count - 1))
            status = .passed
            score = 100 + min(50, benchmarks.count * 10) + reviewabilityBonus
            summary = "passed \(benchmarks.count) benchmark(s), changed \(changedFiles.count) file(s), reviewability +\(reviewabilityBonus)"
        }

        return EvolutionCandidateRecord(
            runID: runID,
            candidateID: candidateID,
            parentID: parentID,
            objective: objective,
            branch: branch,
            worktreePath: worktreePath,
            baseSHA: baseSHA,
            commitSHA: commitSHA,
            status: status,
            score: score,
            changedFiles: changedFiles.sorted(),
            protectedFiles: protected,
            benchmarks: benchmarks,
            summary: summary,
            createdAtEpoch: createdAtEpoch
        )
    }
}

public struct EvolutionArchiveStore: Sendable {
    public let root: String

    public init(root: String) {
        self.root = root
    }

    public var directoryURL: URL {
        URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".mythos/evolution", isDirectory: true)
    }

    public var archiveURL: URL {
        directoryURL.appendingPathComponent("archive.jsonl")
    }

    public func append(_ record: EvolutionCandidateRecord) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var line = try enc.encode(record)
        line.append(Data("\n".utf8))
        if let handle = try? FileHandle(forWritingTo: archiveURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: archiveURL)
        }
    }

    public func records() -> [EvolutionCandidateRecord] {
        guard let data = FileManager.default.contents(atPath: archiveURL.path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? dec.decode(EvolutionCandidateRecord.self, from: data)
        }
    }

    public func topCandidates(limit: Int = 5) -> [EvolutionCandidateRecord] {
        Array(records()
            .filter { $0.status == .passed }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.createdAtEpoch > rhs.createdAtEpoch
            }
            .prefix(max(0, limit)))
    }

    public func context(limit: Int = 5) -> String {
        let top = topCandidates(limit: limit)
        guard !top.isEmpty else { return "No prior passing evolution candidates in the local archive." }
        return top.map { record in
            "- \(record.candidateID) score=\(record.score) branch=\(record.branch): \(record.summary)"
        }.joined(separator: "\n")
    }

    /// Context for the sampled DGM parent. This keeps the orchestrator's selected parent aligned with
    /// what the candidate sees, including failed-with-diff stepping-stones that the old top-winners
    /// context intentionally omitted.
    public func context(selectedParent: EvolutionCandidateRecord?, limit: Int = 5,
                        config: EvolutionParentSelector.Config = .default) -> String {
        guard let selectedParent else { return context(limit: limit) }
        var lines = [
            "Selected parent to build from:",
            "- \(renderContextLine(selectedParent))"
        ]
        let rest = EvolutionParentSelector.frontier(records(), config: config)
            .filter { $0.candidateID != selectedParent.candidateID }
            .prefix(max(0, limit - 1))
        if !rest.isEmpty {
            lines.append("")
            lines.append("Other eligible frontier candidates:")
            lines.append(contentsOf: rest.map { "- \(renderContextLine($0))" })
        }
        return lines.joined(separator: "\n")
    }

    private func renderContextLine(_ record: EvolutionCandidateRecord) -> String {
        let files = record.changedFiles.prefix(5).joined(separator: ", ")
        let changed = files.isEmpty ? "no changed files" : "changed \(files)"
        return "\(record.candidateID) status=\(record.status.rawValue) score=\(record.score) branch=\(record.branch) \(changed): \(record.summary)"
    }

    // MARK: - Open-ended DGM parent selection (over the WHOLE archive, not just the greedy top-N)

    /// Deterministically pick the next parent to breed from, sampling the archive by fitness × exploration
    /// (Sakana-DGM open-endedness). nil ⇒ no eligible parent yet (seed a fresh root candidate). `seed` is
    /// chosen by the orchestrator per candidate slot so runs are reproducible.
    public func selectParent(seed: UInt64, config: EvolutionParentSelector.Config = .default) -> EvolutionCandidateRecord? {
        EvolutionParentSelector.selectParent(from: records(), seed: seed, config: config)
    }

    /// The exploration frontier — eligible parents ranked by "who the DGM would breed next".
    public func frontier(limit: Int = 5, config: EvolutionParentSelector.Config = .default) -> [EvolutionCandidateRecord] {
        Array(EvolutionParentSelector.frontier(records(), config: config).prefix(max(0, limit)))
    }
}

public enum EvolutionBenchmarkRunner {
    public static func defaultCommands(repoRoot: String) -> [String] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: repoRoot, isDirectory: true)
        if fm.fileExists(atPath: root.appendingPathComponent("test.sh").path) {
            return ["./test.sh"]
        }
        if fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            return ["swift test"]
        }
        return ["git diff --check"]
    }

    public static func run(commands: [String], cwd: String, timeoutSeconds: Int = 600) async -> [EvolutionBenchmarkResult] {
        var results: [EvolutionBenchmarkResult] = []
        for command in commands where !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let started = Date()
            let result = await RunCommandTool.spawnAndCollect(
                launchPath: "/bin/sh",
                launchArgs: ["-lc", command],
                cwd: cwd,
                timeout: max(1, timeoutSeconds)
            )
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
            let output = "\(result.output)\n[elapsed \(elapsed)]"
            results.append(EvolutionBenchmarkResult(
                command: command,
                exitCode: Int32(result.metadata["exit_code"] ?? "1") ?? (result.success ? 0 : 1),
                timedOut: result.metadata["timed_out"] == "true",
                output: String(output.prefix(8_000))
            ))
        }
        return results
    }
}

public enum EvolutionLab {
    public static func candidatePrompt(objective: String,
                                       variantIndex: Int,
                                       variantCount: Int,
                                       archiveContext: String,
                                       policy: EvolutionPolicy) -> String {
        """
        EVOLUTION LAB CANDIDATE \(variantIndex)/\(variantCount)

        Objective:
        \(objective)

        You are improving Mythos itself in a DGM-style isolated candidate branch. Make ONE bounded,
        measurable improvement to the agent system, add or update focused tests, and keep the diff
        reviewable. Prefer prompt/tool/routing/evaluation improvements over broad rewrites.

        Selected parent / local archive context:
        \(archiveContext)

        Hard constraints:
        - Do not merge, rebase, push, or promote this branch.
        - Do not weaken tests, sandboxing, secret masking, signoff, merge gates, or verification.
        - Do not modify protected trust-spine files; the evaluator will block the candidate if these change:
        \(policy.protectedGlobs.map { "  - \($0)" }.joined(separator: "\n"))
        - The final answer must summarize the intended improvement, files changed, and how it was verified.

        Benchmark commands expected after your work:
        \((policy.requiredBenchmarkCommands.isEmpty ? ["auto-detected benchmark command(s)"] : policy.requiredBenchmarkCommands).map { "  - \($0)" }.joined(separator: "\n"))
        """
    }

    public static func headSHA(worktreePath: String) -> String {
        run(["git", "-C", worktreePath, "rev-parse", "HEAD"], cwd: worktreePath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(_ argv: [String], cwd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
