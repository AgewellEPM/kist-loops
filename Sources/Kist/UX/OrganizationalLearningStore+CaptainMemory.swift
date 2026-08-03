import Foundation
import AgentCore

extension OrganizationalLearningStore {
    func renderCaptainMemoryArchitecture() -> String {
        let locations: [CaptainMemoryLayerID: String] = [
            .contextWindow: "current model context",
            .knowledgeIndex: Self.projectRelative(knowledgeIndexPath, root: projectRoot),
            .organizationalRules: Self.projectRelative(rulesPath, root: projectRoot),
            .researchArchive: Self.projectRelative(researchArchiveRoot, root: projectRoot),
            .industryIntelligence: Self.projectRelative(industryIntelligencePath, root: projectRoot),
            .benchmarks: Self.projectRelative(benchmarksPath, root: projectRoot),
            .projectHistory: Self.projectRelative(capsulesPath, root: projectRoot),
        ]
        var lines = [
            "Captain Memory Architecture",
            "Context Window is RAM. Everything else is disk.",
            "Retrieval policy: load only relevant records into working memory for the current objective.",
            ""
        ]
        for layer in CaptainMemoryArchitecture.default.layers {
            lines += [
                "\(layer.title) [\(layer.medium.rawValue)]",
                "Role: \(layer.role)",
                "Store: \(locations[layer.id] ?? layer.location)",
                "Retrieval: \(layer.retrievalPolicy)",
                ""
            ]
        }
        return lines.joined(separator: "\n")
    }

    func renderCaptainLearning(limit: Int = 16) -> String {
        let store = CaptainLearningStore(projectRoot: projectRoot)
        let samples = store.load()
        guard !samples.isEmpty else {
            return """
            Captain Learning

            No benchmark or live-eval samples yet.
            Run `/bench <task>` or `/eval <task>` to create shadow evidence. Captain promotes evidence only after repeated verified wins.
            """
        }

        let assignment = store.assignmentContext()
        let summaries = captainLearningRetrievalSummaries()
        let promoted = summaries.filter(\.promoted)
        let shadow = summaries.filter { !$0.promoted }
        var lines = [
            "Captain Learning",
            "",
            "Source: \(CaptainLearningStore.relativePath)",
            "Samples: \(samples.count)",
            "Assignment status: \(assignment.statusLine)",
            "",
            "Promotion gate",
            "- at least 3 samples",
            "- success rate >= 67%",
            "- tool failures <= max(1, samples / 2)",
            "",
            "Promoted Evidence",
        ]
        if promoted.isEmpty {
            lines.append("- none yet")
        } else {
            lines += promoted.prefix(max(0, limit)).map(renderLearningSummary)
        }
        lines += ["", "Shadow Evidence"]
        if shadow.isEmpty {
            lines.append("- none")
        } else {
            lines += shadow.prefix(max(0, limit)).map(renderLearningSummary)
        }
        lines += [
            "",
            "How Captain uses this",
            "- promoted evidence can bias fleet role assignment and appears in benchmark retrieval memory",
            "- shadow evidence is visible but not trusted enough to steer policy",
            "- every new /bench or /eval sample can move a provider/role toward or away from promotion",
        ]
        return lines.joined(separator: "\n")
    }

    func renderStrategicIntelligence(limit: Int = 12) -> String {
        let intelligence = loadJSONL(DiskMemoryRecord.self, path: industryIntelligencePath)
        let proposals = loadJSONL(DiskMemoryRecord.self, path: evolutionProposalsPath)
        guard !intelligence.isEmpty || !proposals.isEmpty else {
            return """
            Strategic Intelligence

            No industry intelligence records yet.
            Run `/evolve` to create a competitor, paper, standards, and benchmark comparison agenda.
            """
        }

        var lines = [
            "Strategic Intelligence",
            "",
            "Source: \(Self.projectRelative(industryIntelligencePath, root: projectRoot))",
            "Evolution proposals: \(Self.projectRelative(evolutionProposalsPath, root: projectRoot))",
            "",
            "Industry Radar",
        ]
        for item in intelligence.suffix(max(0, limit)).reversed() {
            lines += [
                "- \(item.title ?? item.id ?? "industry item")",
                "  \(item.summary ?? item.body ?? "")",
            ]
            if let body = item.body, body != item.summary, !body.isEmpty {
                lines.append("  \(body.replacingOccurrences(of: "\n", with: "\n  "))")
            }
            if let source = item.source, !source.isEmpty {
                lines.append("  Source target: \(source)")
            }
            if let impact = item.impact {
                lines.append("  Impact: \(stars(impact))")
            }
        }
        lines += ["", "Evolution Proposals"]
        for proposal in proposals.suffix(max(0, limit)).reversed() {
            lines += [
                "- \(proposal.title ?? proposal.id ?? "proposal")",
                "  \(proposal.summary ?? proposal.body ?? "")",
            ]
            if let body = proposal.body, body != proposal.summary, !body.isEmpty {
                lines.append("  \(body.replacingOccurrences(of: "\n", with: "\n  "))")
            }
            if let impact = proposal.impact {
                lines.append("  Impact: \(stars(impact))")
            }
        }
        lines += [
            "",
            "Use `/evolve` to refresh the radar, seed research tasks, and promote one high-confidence organizational rule."
        ]
        return lines.joined(separator: "\n")
    }

    func captainLearningRetrievalSummaries() -> [CaptainLearningSummary] {
        struct Key: Hashable {
            let role: String
            let providerId: String
            let language: String?
        }
        let samples = CaptainLearningStore(projectRoot: projectRoot).load()
        var buckets: [Key: [CaptainLearningSample]] = [:]
        for sample in samples {
            buckets[Key(role: sample.role, providerId: sample.providerId, language: sample.language), default: []].append(sample)
        }
        return buckets.map { key, values in
            let successes = values.filter(\.success).count
            let scored = values.compactMap(\.judgeScore)
            let tags = Array(Set(values.flatMap(\.taskTags))).sorted()
            let avgScore = scored.isEmpty ? nil : scored.reduce(0, +) / Double(scored.count)
            let avgTokens = values.isEmpty ? 0 : values.reduce(0) { $0 + $1.tokens } / values.count
            let avgLatency = values.isEmpty ? 0 : values.reduce(0) { $0 + $1.latencyMs } / values.count
            let failures = values.reduce(0) { $0 + $1.toolFailures }
            let latest = values.map(\.atEpoch).max() ?? 0
            return CaptainLearningSummary(role: key.role, providerId: key.providerId,
                                          taskTags: tags.isEmpty ? ["coding"] : tags,
                                          language: key.language, samples: values.count,
                                          successes: successes, averageJudgeScore: avgScore,
                                          averageTokens: avgTokens,
                                          averageLatencyMs: avgLatency,
                                          toolFailures: failures, latestEpoch: latest)
        }.sorted { a, b in
            if a.promoted != b.promoted { return a.promoted && !b.promoted }
            if a.scoreBoost != b.scoreBoost { return a.scoreBoost > b.scoreBoost }
            if a.samples != b.samples { return a.samples > b.samples }
            return a.providerId < b.providerId
        }
    }

    func renderLearningSummary(_ summary: CaptainLearningSummary) -> String {
        let pct = Int((summary.successRate * 100).rounded())
        let tags = summary.taskTags.isEmpty ? "general" : summary.taskTags.joined(separator: ", ")
        let language = summary.language ?? "any"
        let judge = summary.averageJudgeScore.map { " judge=\(Int(($0 * 100).rounded()))%" } ?? ""
        let latency = summary.averageLatencyMs > 0 ? " avgLatency=\(summary.averageLatencyMs)ms" : ""
        let tokens = summary.averageTokens > 0 ? " avgTokens=\(summary.averageTokens)" : ""
        return "- \(summary.providerId) / \(summary.role) [\(tags)] language=\(language) "
            + "\(summary.successes)/\(summary.samples) \(pct)%\(judge)\(tokens)\(latency) "
            + "toolFailures=\(summary.toolFailures) status=\(summary.promoted ? "promoted" : "shadow")"
    }

}
