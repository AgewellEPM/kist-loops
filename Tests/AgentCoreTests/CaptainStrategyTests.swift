import XCTest
@testable import AgentCore

final class CaptainStrategyTests: XCTestCase {
    func testResearchComesBeforeExpertiseAndExecution() {
        let evidence = CaptainProjectEvidence(projectRoot: "/tmp/kist",
                                              trackedFileCount: 42,
                                              directorySnapshot: "Sources/AgentCore\nSources/Kist",
                                              languages: ["Swift"],
                                              manifests: ["Package.swift"],
                                              testEntrypoints: ["swift test"],
                                              changedFiles: ["Sources/AgentCore/CaptainStrategy.swift"])

        let plan = CaptainStrategist.plan(
            objective: "build Captain orchestration with MCP tools and live eval benchmarks",
            evidence: evidence,
            specialists: [])

        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .research)!,
                          plan.orderedStages.firstIndex(of: .researchPlan)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .researchPlan)!,
                          plan.orderedStages.firstIndex(of: .researchChecklist)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .knowledgeGapAnalysis)!,
                          plan.orderedStages.firstIndex(of: .becomeSubjectMatterExpert)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .becomeSubjectMatterExpert)!,
                          plan.orderedStages.firstIndex(of: .executionPlan)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .executionPlan)!,
                          plan.orderedStages.firstIndex(of: .assembleExistingSpecialists)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .planning)!,
                          plan.orderedStages.firstIndex(of: .buildPossiblePlan)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .buildPossiblePlan)!,
                          plan.orderedStages.firstIndex(of: .sandboxSimulation)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .sandboxSimulation)!,
                          plan.orderedStages.firstIndex(of: .probabilisticTrials)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .probabilisticTrials)!,
                          plan.orderedStages.firstIndex(of: .riskEstimation)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .riskEstimation)!,
                          plan.orderedStages.firstIndex(of: .strategyComparison)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .strategyComparison)!,
                          plan.orderedStages.firstIndex(of: .pickSafestHighestValueOption)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .pickSafestHighestValueOption)!,
                          plan.orderedStages.firstIndex(of: .execution)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .build)!,
                          plan.orderedStages.firstIndex(of: .selfReview)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .independentAIReview)!,
                          plan.orderedStages.firstIndex(of: .crossCompare)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .evidence)!,
                          plan.orderedStages.firstIndex(of: .acceptOrReject)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .knowledgeGained)!,
                          plan.orderedStages.firstIndex(of: .knowledgeDebt)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .platformEvolution)!,
                          plan.orderedStages.firstIndex(of: .strategicIntelligence)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .strategicIntelligence)!,
                          plan.orderedStages.firstIndex(of: .evolutionProposal)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .evolutionProposal)!,
                          plan.orderedStages.firstIndex(of: .teachCaptain)!)
        XCTAssertLessThan(plan.orderedStages.firstIndex(of: .teachCaptain)!,
                          plan.orderedStages.firstIndex(of: .readyForNextObjective)!)

        let names = Set(plan.requiredExpertise.map(\.name))
        XCTAssertTrue(names.contains("agent-orchestration-architect"))
        XCTAssertTrue(names.contains("tool-protocol-engineer"))
        XCTAssertTrue(names.contains("eval-and-learning-engineer"))
        XCTAssertTrue(names.contains("swift-cli-engineer"))
        XCTAssertTrue(plan.missingSpecialists.contains { $0.name == "agent-orchestration-architect" })
        XCTAssertTrue(plan.briefing.contains("Research -> Research Plan -> Research Checklist"))
        XCTAssertTrue(plan.briefing.contains("Never build before researching."))
        XCTAssertTrue(plan.briefing.contains("Always leave the organization smarter than before."))
        XCTAssertTrue(plan.briefing.contains("Always watch the industry before declaring the platform done."))
        XCTAssertTrue(plan.briefing.contains("Always ask what organizational lesson should become permanent."))
        XCTAssertTrue(plan.briefing.contains("Sandbox Simulation"))
        XCTAssertTrue(plan.briefing.contains("Probabilistic Trials"))
        XCTAssertTrue(plan.briefing.contains("CURRENT UNDERSTANDING"))
        XCTAssertTrue(plan.briefing.contains("CAPTAIN MEMORY ARCHITECTURE"))
        XCTAssertTrue(plan.briefing.contains("Context Window is RAM; everything else is disk."))
        XCTAssertTrue(plan.briefing.contains("Organizational Rules [disk]"))
        XCTAssertTrue(plan.briefing.contains("STRATEGIC INTELLIGENCE"))
        XCTAssertTrue(plan.briefing.contains("TEACH CAPTAIN"))
        XCTAssertTrue(plan.understanding.confidence < plan.understanding.threshold)
    }

    func testUnfamiliarRegulatedDomainRequiresLearningBeforeOrganization() {
        let plan = CaptainStrategist.plan(
            objective: "Captain, build a medical imaging platform for radiology workflows with DICOM and HIPAA")

        XCTAssertFalse(plan.understood)
        XCTAssertFalse(plan.understanding.canOrganize)
        XCTAssertLessThan(plan.understanding.confidence, plan.understanding.threshold)
        XCTAssertTrue(plan.understanding.currentUnderstanding.contains("should not pretend"))
        XCTAssertTrue(plan.understanding.missingKnowledge.contains { $0.contains("DICOM") })
        XCTAssertTrue(plan.understanding.missingKnowledge.contains { $0.contains("HIPAA") || $0.contains("FDA") })
        XCTAssertTrue(plan.requiredExpertise.contains { $0.name == "regulated-domain-researcher" })
        XCTAssertTrue(plan.nextAction.contains("Learn the domain first"))
    }

    func testPromptGuidanceCarriesConfidenceGate() {
        let guidance = CaptainStrategist.promptGuidance(
            objective: "build a medical imaging platform").joined(separator: "\n")

        XCTAssertTrue(guidance.contains("Captain's first responsibility is learning"))
        XCTAssertTrue(guidance.contains("Current understanding estimate"))
        XCTAssertTrue(guidance.contains("Below threshold"))
        XCTAssertTrue(guidance.contains("Strategic Intelligence"))
        XCTAssertTrue(guidance.contains("Teach Captain"))
        XCTAssertTrue(guidance.contains("Context Window is RAM"))
        XCTAssertTrue(guidance.contains("Retrieve only relevant disk-backed facts"))
        XCTAssertTrue(guidance.contains("sandbox simulations and probabilistic trials"))
    }

    func testExistingSpecialistsCoverMatchingExpertise() {
        let specialist = SpecialistDefinition(
            name: "agent-orchestration-architect",
            description: "Design Captain orchestration, swarm delegation, fleet leases, and worker lifecycle.",
            systemPrompt: "Review agent orchestration and non-overlapping specialist execution.")

        let plan = CaptainStrategist.plan(objective: "improve Captain swarm delegation",
                                          specialists: [specialist])

        let orchestration = plan.requiredExpertise.first { $0.name == "agent-orchestration-architect" }
        XCTAssertEqual(orchestration?.existingSpecialists, ["agent-orchestration-architect"])
        XCTAssertFalse(plan.missingSpecialists.contains { $0.name == "agent-orchestration-architect" })
    }

    func testPromptGuidanceNamesCaptainAsProcessNotModel() {
        let guidance = CaptainStrategist.promptGuidance(objective: "build a persistent research queue")
            .joined(separator: "\n")

        XCTAssertTrue(guidance.contains("Captain is the orchestration process"))
        XCTAssertTrue(guidance.contains("Research until the understanding confidence threshold"))
        XCTAssertTrue(guidance.contains("Always leave the organization smarter than before."))
        XCTAssertTrue(guidance.contains("Knowledge Debt"))
        XCTAssertTrue(guidance.contains("Evolution Proposal"))
    }

    func testMemoryArchitectureModelsContextAsRAMAndEverythingElseAsDisk() {
        let memory = CaptainMemoryArchitecture.default

        XCTAssertEqual(memory.contextWindow.medium, .ram)
        XCTAssertEqual(memory.diskLayers.count, 6)
        XCTAssertTrue(memory.diskLayers.contains { $0.id == .knowledgeIndex })
        XCTAssertTrue(memory.diskLayers.contains { $0.id == .organizationalRules })
        XCTAssertTrue(memory.diskLayers.contains { $0.id == .researchArchive })
        XCTAssertTrue(memory.diskLayers.contains { $0.id == .industryIntelligence })
        XCTAssertTrue(memory.diskLayers.contains { $0.id == .benchmarks })
        XCTAssertTrue(memory.diskLayers.contains { $0.id == .projectHistory })
        XCTAssertTrue(memory.briefing.contains("retrieval rule"))
    }

    func testRetrievalRanksRelevantDiskRecordsAndBuildsDecisionCards() {
        let candidates = [
            CaptainMemoryCandidate(layerID: .organizationalRules,
                                   recordID: "OR-agent-orchestration",
                                   title: "Rule: agent orchestration requires competitor comparison",
                                   excerpt: "Agent orchestration work requires runtime, benchmark, and competitor comparison.",
                                   sourcePath: ".kist/learning/organizational-rules.jsonl",
                                   baseRelevance: 40),
            CaptainMemoryCandidate(layerID: .projectHistory,
                                   recordID: "LC-unrelated",
                                   title: "History: terminal colors",
                                   excerpt: "Adjusted theme colors.",
                                   sourcePath: ".kist/learning/capsules.jsonl",
                                   baseRelevance: 5)
        ]

        let retrieved = CaptainRetrievalRanker.retrieve(
            objective: "improve Captain agent orchestration benchmarks",
            candidates: candidates,
            limit: 4)
        let strategy = CaptainStrategist.plan(objective: "improve Captain agent orchestration benchmarks")
        let cards = CaptainDecisionCards.build(objective: strategy.objective,
                                               retrieval: retrieved,
                                               strategy: strategy)

        XCTAssertEqual(retrieved.first?.recordID, "OR-agent-orchestration")
        XCTAssertTrue(retrieved.first?.reason.contains("matched objective terms") == true)
        XCTAssertTrue(cards.contains { $0.kind == .contextRetrieval })
        XCTAssertTrue(cards.contains { $0.kind == .ruleApplication })
        XCTAssertTrue(cards.contains { $0.kind == .benchmarkGate })
        XCTAssertTrue(CaptainRetrievalContext(objective: strategy.objective,
                                              retrieved: retrieved,
                                              decisionCards: cards)
            .briefing.contains("DECISION CARDS"))
    }

    func testStrategicIntelligenceAndTeachingInferSpecialists() {
        let plan = CaptainStrategist.plan(
            objective: "add Strategic Intelligence and Teach Captain permanent organizational rules")
        let names = Set(plan.requiredExpertise.map(\.name))

        XCTAssertTrue(names.contains("strategic-intelligence-analyst"))
        XCTAssertTrue(names.contains("organizational-rule-steward"))
        XCTAssertTrue(plan.researchQuestions.contains { $0.contains("What changed in the industry today") })
        XCTAssertTrue(CaptainStrategist.organizationalLessonCandidate(
            objective: plan.objective,
            expertiseNames: plan.requiredExpertise.map(\.name)
        ).contains("Platform evolution"))
    }

    func testSimulationRiskObjectivesCreateSimulationGateAndExpertise() {
        let plan = CaptainStrategist.plan(
            objective: "simulate a risky software rollout with probabilistic trials before execution")
        let names = Set(plan.requiredExpertise.map(\.name))
        let cards = CaptainDecisionCards.build(objective: plan.objective,
                                               retrieval: [],
                                               strategy: plan)

        XCTAssertTrue(names.contains("simulation-and-risk-engineer"))
        XCTAssertTrue(cards.contains { $0.kind == .simulationGate })
        XCTAssertTrue(plan.researchQuestions.contains { $0.contains("What sandbox") })
        XCTAssertTrue(CaptainStrategist.organizationalLessonCandidate(
            objective: plan.objective,
            expertiseNames: plan.requiredExpertise.map(\.name)
        ).contains("sandbox simulation"))
    }
}
