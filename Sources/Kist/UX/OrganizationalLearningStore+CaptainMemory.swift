import Foundation
import AgentCore

extension OrganizationalLearningStore {
    func renderCaptainMemoryArchitecture() -> String {
        let temporalReadiness = genericMemoryTemporalReadiness()
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
            "Generic temporal admission: \(temporalReadiness.operational) clocked row(s); \(temporalReadiness.auditOnly) legacy or invalid row(s) remain raw audit-only.",
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
            Run `/bench <task>` or `/eval <task>` to create unsigned shadow observations. Repetition can make them eligible for route bias, but never turns them into signed proof.
            """
        }

        let nowEpoch = now().timeIntervalSince1970
        let assignment = store.assignmentContext(now: nowEpoch)
        let summaries = captainLearningRetrievalSummaries(now: nowEpoch)
        let promoted = summaries.filter(\.promoted)
        let shadow = summaries.filter { !$0.promoted }
        var lines = [
            "Captain Learning",
            "",
            "Source: \(CaptainLearningStore.relativePath)",
            "Samples: \(samples.count)",
            "Assignment status: \(assignment.statusLine)",
            "",
            "Unsigned route-bias eligibility gate",
            "- at least 3 samples",
            "- success rate >= 67%",
            "- tool failures <= max(1, samples / 2)",
            "",
            "Unsigned Route-Bias Profiles",
        ]
        if promoted.isEmpty {
            lines.append("- none yet")
        } else {
            lines += promoted.prefix(max(0, limit)).map(renderLearningSummary)
        }
        lines += ["", "Unsigned Shadow Profiles"]
        if shadow.isEmpty {
            lines.append("- none")
        } else {
            lines += shadow.prefix(max(0, limit)).map(renderLearningSummary)
        }
        lines += [
            "",
            "How Captain uses this",
            "- route-eligible unsigned observations can bias fleet role assignment and appear in advisory retrieval memory",
            "- shadow observations are visible but do not steer policy",
            "- these profiles are not signed receipts, independent proof, or benchmark promotion authority",
            "- every new /bench or /eval sample can move a provider/role toward or away from route-bias eligibility",
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

    func captainLearningRetrievalSummaries(now nowEpoch: Double? = nil) -> [CaptainLearningSummary] {
        let samples = CaptainLearningStore(projectRoot: projectRoot).load()
        return CaptainLearningStore.summarizeForRetrieval(
            samples, now: nowEpoch ?? now().timeIntervalSince1970)
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
            + "toolFailures=\(summary.toolFailures) status="
            + (summary.promoted ? "route-bias-eligible" : "shadow-only")
    }

}
