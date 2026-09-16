import Foundation

public enum CaptainStrategyStage: String, Codable, Sendable, Equatable, CaseIterable {
    case objective
    case captain
    case research
    case researchPlan
    case researchChecklist
    case knowledgeGapAnalysis
    case becomeSubjectMatterExpert
    case executionPlan
    case understand
    case determineExpertise
    case assembleExistingSpecialists
    case createNewSpecialists
    case planning
    case buildPossiblePlan
    case sandboxSimulation
    case probabilisticTrials
    case riskEstimation
    case strategyComparison
    case pickSafestHighestValueOption
    case execution
    case build
    case review
    case selfReview
    case independentAIReview
    case crossCompare
    case evidence
    case benchmarks
    case acceptOrReject
    case retrospective
    case knowledgeGained
    case knowledgeDebt
    case researchQueue
    case platformEvolution
    case strategicIntelligence
    case evolutionProposal
    case teachCaptain
    case memory
    case readyForNextObjective

    public var title: String {
        switch self {
        case .objective: return "Objective Received"
        case .captain: return "Captain"
        case .research: return "Research"
        case .researchPlan: return "Research Plan"
        case .researchChecklist: return "Research Checklist"
        case .knowledgeGapAnalysis: return "Knowledge Gap Analysis"
        case .becomeSubjectMatterExpert: return "Become Subject Matter Expert"
        case .executionPlan: return "Execution Plan"
        case .understand: return "Understand"
        case .determineExpertise: return "Determine Required Expertise"
        case .assembleExistingSpecialists: return "Assemble Existing Specialists"
        case .createNewSpecialists: return "Create New Specialists"
        case .planning: return "Planning"
        case .buildPossiblePlan: return "Build Possible Plan"
        case .sandboxSimulation: return "Sandbox Simulation"
        case .probabilisticTrials: return "Probabilistic Trials"
        case .riskEstimation: return "Estimate Success / Failure Risk"
        case .strategyComparison: return "Compare Strategies"
        case .pickSafestHighestValueOption: return "Pick Safest Highest-Value Option"
        case .execution: return "Execution"
        case .build: return "Build"
        case .review: return "Review"
        case .selfReview: return "Self Review"
        case .independentAIReview: return "Independent AI Review"
        case .crossCompare: return "Cross Compare"
        case .evidence: return "Evidence"
        case .benchmarks: return "Benchmarks"
        case .acceptOrReject: return "Accept or Reject"
        case .retrospective: return "Retrospective"
        case .knowledgeGained: return "Knowledge Gained"
        case .knowledgeDebt: return "Knowledge Debt"
        case .researchQueue: return "Research Queue"
        case .platformEvolution: return "Platform Evolution"
        case .strategicIntelligence: return "Strategic Intelligence"
        case .evolutionProposal: return "Evolution Proposal"
        case .teachCaptain: return "Teach Captain"
        case .memory: return "Memory"
        case .readyForNextObjective: return "Ready For Next Objective"
        }
    }
}

public struct CaptainProjectEvidence: Sendable, Equatable, Codable {
    public let projectRoot: String
    public let trackedFileCount: Int
    public let directorySnapshot: String
    public let languages: [String]
    public let manifests: [String]
    public let testEntrypoints: [String]
    public let changedFiles: [String]

    public init(projectRoot: String, trackedFileCount: Int, directorySnapshot: String,
                languages: [String], manifests: [String], testEntrypoints: [String],
                changedFiles: [String]) {
        self.projectRoot = projectRoot
        self.trackedFileCount = trackedFileCount
        self.directorySnapshot = directorySnapshot
        self.languages = languages
        self.manifests = manifests
        self.testEntrypoints = testEntrypoints
        self.changedFiles = changedFiles
    }

    public static func capture(projectRoot: String) -> CaptainProjectEvidence {
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        let files = GitIsolation.trackedFiles(repo: root)
        let scope = CaptainOrchestrator.deriveScopeContext(fromFiles: files)
        return CaptainProjectEvidence(projectRoot: root,
                                      trackedFileCount: files.count,
                                      directorySnapshot: scope.snapshot,
                                      languages: languages(from: files),
                                      manifests: files.filter(isManifest).sorted(),
                                      testEntrypoints: testEntrypoints(from: files),
                                      changedFiles: changedFiles(repo: root))
    }

    public var briefing: String {
        var lines = ["PROJECT EVIDENCE"]
        lines.append("tracked files: \(trackedFileCount)")
        if !languages.isEmpty { lines.append("languages: \(languages.joined(separator: ", "))") }
        if !manifests.isEmpty { lines.append("manifests: \(manifests.prefix(10).joined(separator: ", "))") }
        if !testEntrypoints.isEmpty { lines.append("tests: \(testEntrypoints.joined(separator: ", "))") }
        if !changedFiles.isEmpty { lines.append("changed files: \(changedFiles.prefix(16).joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    private static func isManifest(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if ["Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "go.mod",
            "Gemfile", "Podfile", "test.sh", "Makefile"].contains(name) { return true }
        return path.hasSuffix(".xcodeproj/project.pbxproj")
            || path.hasSuffix(".xcworkspace/contents.xcworkspacedata")
    }

    private static func testEntrypoints(from files: [String]) -> [String] {
        var out: [String] = []
        let set = Set(files)
        if set.contains("test.sh") { out.append("./test.sh") }
        if set.contains("Package.swift") { out.append("swift test") }
        if set.contains("package.json") { out.append("npm test") }
        if set.contains("Cargo.toml") { out.append("cargo test") }
        if set.contains("go.mod") { out.append("go test ./...") }
        if files.contains(where: { $0.hasSuffix(".xcodeproj/project.pbxproj") }) { out.append("xcodebuild test") }
        return out
    }

    private static func languages(from files: [String]) -> [String] {
        let map: [String: String] = [
            "swift": "Swift", "js": "JavaScript", "jsx": "JavaScript",
            "ts": "TypeScript", "tsx": "TypeScript", "py": "Python",
            "rs": "Rust", "go": "Go", "java": "Java", "kt": "Kotlin",
            "c": "C", "cc": "C++", "cpp": "C++", "m": "Objective-C", "mm": "Objective-C++"
        ]
        var counts: [String: Int] = [:]
        for file in files {
            let ext = (file as NSString).pathExtension.lowercased()
            guard let lang = map[ext] else { continue }
            counts[lang, default: 0] += 1
        }
        return counts.sorted { a, b in
            a.value == b.value ? a.key < b.key : a.value > b.value
        }.prefix(6).map(\.key)
    }

    private static func changedFiles(repo: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", repo, "status", "--porcelain"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                let text = String(line)
                guard text.count > 3 else { return nil }
                let path = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                return path.isEmpty ? nil : path
            }
            .sorted()
    }
}

public struct CaptainExpertiseNeed: Codable, Sendable, Equatable {
    public let name: String
    public let reason: String
    public let keywords: [String]
    public let existingSpecialists: [String]
    public let suggestedSpecialist: SpecialistDefinition?

    public init(name: String, reason: String, keywords: [String],
                existingSpecialists: [String], suggestedSpecialist: SpecialistDefinition?) {
        self.name = name
        self.reason = reason
        self.keywords = keywords
        self.existingSpecialists = existingSpecialists
        self.suggestedSpecialist = suggestedSpecialist
    }

    public var isCovered: Bool { !existingSpecialists.isEmpty }
}

public struct CaptainUnderstandingAssessment: Codable, Sendable, Equatable {
    public let confidence: Int
    public let threshold: Int
    public let currentUnderstanding: String
    public let missingKnowledge: [String]
    public let recommendedResearchTime: String

    public init(confidence: Int, threshold: Int, currentUnderstanding: String,
                missingKnowledge: [String], recommendedResearchTime: String) {
        self.confidence = min(100, max(0, confidence))
        self.threshold = min(100, max(0, threshold))
        self.currentUnderstanding = currentUnderstanding
        self.missingKnowledge = missingKnowledge
        self.recommendedResearchTime = recommendedResearchTime
    }

    public var canOrganize: Bool { confidence >= threshold }

    public var gateSummary: String {
        canOrganize
            ? "qualified to design the organization after validating assumptions"
            : "not qualified yet; learn until temporary subject-matter expertise is reached"
    }
}

public enum CaptainMemoryMedium: String, Codable, Sendable, Equatable {
    case ram = "RAM"
    case disk = "disk"
}

public enum CaptainMemoryLayerID: String, Codable, Sendable, Equatable, CaseIterable {
    case contextWindow
    case knowledgeIndex
    case organizationalRules
    case researchArchive
    case industryIntelligence
    case benchmarks
    case projectHistory

    public var title: String {
        switch self {
        case .contextWindow: return "Context Window"
        case .knowledgeIndex: return "Knowledge Index"
        case .organizationalRules: return "Organizational Rules"
        case .researchArchive: return "Research Archive"
        case .industryIntelligence: return "Industry Intelligence"
        case .benchmarks: return "Benchmarks"
        case .projectHistory: return "Project History"
        }
    }
}

public struct CaptainMemoryLayer: Codable, Sendable, Equatable {
    public let id: CaptainMemoryLayerID
    public let title: String
    public let medium: CaptainMemoryMedium
    public let role: String
    public let location: String
    public let retrievalPolicy: String

    public init(id: CaptainMemoryLayerID, title: String, medium: CaptainMemoryMedium,
                role: String, location: String, retrievalPolicy: String) {
        self.id = id
        self.title = title
        self.medium = medium
        self.role = role
        self.location = location
        self.retrievalPolicy = retrievalPolicy
    }
}

public struct CaptainMemoryArchitecture: Codable, Sendable, Equatable {
    public let layers: [CaptainMemoryLayer]

    public init(layers: [CaptainMemoryLayer] = CaptainMemoryArchitecture.defaultLayers) {
        self.layers = layers
    }

    public static let defaultLayers: [CaptainMemoryLayer] = [
        CaptainMemoryLayer(id: .contextWindow,
                           title: "Context Window",
                           medium: .ram,
                           role: "Working memory for the current objective, current evidence, active plan, and selected retrieval.",
                           location: "current model context",
                           retrievalPolicy: "Keep only the most relevant facts needed for this turn."),
        CaptainMemoryLayer(id: .knowledgeIndex,
                           title: "Knowledge Index",
                           medium: .disk,
                           role: "Long-term index of learned concepts, sources, decisions, and open knowledge gaps.",
                           location: ".kist/learning/knowledge-index.jsonl",
                           retrievalPolicy: "Search by objective, domain, component, and decision pressure; load summaries, not whole archives."),
        CaptainMemoryLayer(id: .organizationalRules,
                           title: "Organizational Rules",
                           medium: .disk,
                           role: "The constitution: permanent operating principles Captain must obey unless explicitly retired.",
                           location: ".kist/learning/organizational-rules.jsonl",
                           retrievalPolicy: "Always retrieve applicable rules before planning or delegating."),
        CaptainMemoryLayer(id: .researchArchive,
                           title: "Research Archive",
                           medium: .disk,
                           role: "Evidence dossiers, cited research notes, competitor comparisons, and architecture studies.",
                           location: ".kist/learning/research-archive/",
                           retrievalPolicy: "Retrieve cited excerpts and conclusions relevant to the current objective."),
        CaptainMemoryLayer(id: .industryIntelligence,
                           title: "Industry Intelligence",
                           medium: .disk,
                           role: "Time-sensitive competitor, paper, standards, and product-movement observations.",
                           location: ".kist/learning/industry-intelligence.jsonl",
                           retrievalPolicy: "Refresh during Strategic Intelligence; load recent or high-impact changes only."),
        CaptainMemoryLayer(id: .benchmarks,
                           title: "Benchmarks",
                           medium: .disk,
                           role: "Eval results, live-loop measurements, model assignment outcomes, and policy promotion evidence.",
                           location: ".kist/learning/benchmarks.jsonl",
                           retrievalPolicy: "Retrieve comparable measurements before changing model routing, tools, or workflow policy."),
        CaptainMemoryLayer(id: .projectHistory,
                           title: "Project History",
                           medium: .disk,
                           role: "Completed work, failures, decisions, learning capsules, and task-board evolution.",
                           location: ".kist/learning/capsules.jsonl",
                           retrievalPolicy: "Retrieve recent and similar prior work to avoid repeating mistakes.")
    ]

    public static let `default` = CaptainMemoryArchitecture()

    public var contextWindow: CaptainMemoryLayer {
        layers.first { $0.id == .contextWindow } ?? Self.defaultLayers[0]
    }

    public var diskLayers: [CaptainMemoryLayer] {
        layers.filter { $0.medium == .disk }
    }

    public var briefing: String {
        var lines = [
            "CAPTAIN MEMORY ARCHITECTURE",
            "model: Context Window is RAM; everything else is disk.",
            "retrieval rule: Captain retrieves only relevant disk-backed evidence into working memory."
        ]
        for layer in layers {
            lines += [
                "- \(layer.title) [\(layer.medium.rawValue)]",
                "  Role: \(layer.role)",
                "  Store: \(layer.location)",
                "  Retrieval: \(layer.retrievalPolicy)"
            ]
        }
        return lines.joined(separator: "\n")
    }
}

public enum CaptainDecisionCardKind: String, Codable, Sendable, Equatable {
    case contextRetrieval
    case ruleApplication
    case researchGate
    case simulationGate
    case benchmarkGate
    case specialistAssignment
}

public struct CaptainDecisionCard: Codable, Sendable, Equatable {
    public let kind: CaptainDecisionCardKind
    public let title: String
    public let decision: String
    public let confidence: Int
    public let reason: String
    public let evidenceIDs: [String]
    public let risk: String
    public let nextAction: String

    public init(kind: CaptainDecisionCardKind, title: String, decision: String,
                confidence: Int, reason: String, evidenceIDs: [String],
                risk: String, nextAction: String) {
        self.kind = kind
        self.title = title
        self.decision = decision
        self.confidence = min(100, max(0, confidence))
        self.reason = reason
        self.evidenceIDs = evidenceIDs
        self.risk = risk
        self.nextAction = nextAction
    }
}

public struct CaptainRetrievalContext: Codable, Sendable, Equatable {
    public let objective: String
    public let retrieved: [CaptainRetrievedMemory]
    public let decisionCards: [CaptainDecisionCard]

    public init(objective: String, retrieved: [CaptainRetrievedMemory],
                decisionCards: [CaptainDecisionCard]) {
        self.objective = objective
        self.retrieved = retrieved
        self.decisionCards = decisionCards
    }

    public var briefing: String {
        var lines = [
            "CAPTAIN RETRIEVAL CONTEXT",
            "objective: \(objective)",
            "context window policy: load these slices into RAM; leave the rest on disk.",
        ]
        if retrieved.isEmpty {
            lines += [
                "retrieved: none",
                "reason: no relevant disk-backed memory matched this objective yet."
            ]
        } else {
            lines.append("retrieved:")
            for item in retrieved {
                lines += [
                    "- \(item.evidenceID) (\(item.relevance)%): \(item.title)",
                    "  Layer: \(item.layerID.title)",
                    "  Source: \(item.sourcePath)",
                    "  Why: \(item.reason)",
                    "  Excerpt: \(item.excerpt)"
                ]
            }
        }

        lines += ["", "DECISION CARDS"]
        if decisionCards.isEmpty {
            lines.append("- none")
        } else {
            for card in decisionCards {
                lines += [
                    "- \(card.title) (\(card.confidence)%)",
                    "  Decision: \(card.decision)",
                    "  Reason: \(card.reason)",
                    "  Evidence: \(card.evidenceIDs.isEmpty ? "none" : card.evidenceIDs.joined(separator: ", "))",
                    "  Risk: \(card.risk)",
                    "  Next: \(card.nextAction)"
                ]
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum CaptainRetrievalRanker {
    public static func retrieve(objective: String,
                                candidates: [CaptainMemoryCandidate],
                                limit: Int = 8) -> [CaptainRetrievedMemory] {
        let objectiveTokens = Set(tokens(objective))
        let ranked = candidates.map { candidate -> CaptainRetrievedMemory in
            let haystackTokens = Set(tokens(candidate.title + " " + candidate.excerpt + " " + candidate.layerID.rawValue))
            let overlap = objectiveTokens.intersection(haystackTokens)
            let phraseBonus = phraseMatchBonus(objective: objective, candidate: candidate)
            let layerBonus = layerPriority(candidate.layerID)
            // A high base/layer priority is useful only AFTER relevance is established. Previously an
            // organizational rule could clear the >=20 threshold with zero shared terms, so unrelated
            // old roadmaps were injected into every new turn as "working memory". No lexical/phrase
            // match means no retrieval; explicit /retrieve still reports an honest empty result.
            let hasObjectiveMatch = !overlap.isEmpty || phraseBonus > 0
            let score = hasObjectiveMatch
                ? min(100, candidate.baseRelevance + layerBonus + phraseBonus + overlap.count * 12)
                : 0
            let reason: String
            if !overlap.isEmpty {
                reason = "matched objective terms: \(overlap.sorted().prefix(8).joined(separator: ", "))"
            } else {
                reason = "no objective-term match"
            }
            return CaptainRetrievedMemory(layerID: candidate.layerID,
                                          recordID: candidate.recordID,
                                          title: candidate.title,
                                          excerpt: candidate.excerpt,
                                          sourcePath: candidate.sourcePath,
                                          relevance: score,
                                          reason: reason)
        }
        return ranked
            .filter { $0.relevance >= 20 }
            .sorted {
                if $0.relevance != $1.relevance { return $0.relevance > $1.relevance }
                if $0.layerID != $1.layerID { return $0.layerID.rawValue < $1.layerID.rawValue }
                return $0.recordID < $1.recordID
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    private static func phraseMatchBonus(objective: String, candidate: CaptainMemoryCandidate) -> Int {
        let lowerObjective = objective.lowercased()
        let lowerBody = (candidate.title + " " + candidate.excerpt).lowercased()
        var score = 0
        for phrase in ["captain", "strategic intelligence", "teach captain", "benchmark",
                       "orchestration", "mcp", "memory", "research", "knowledge debt"] {
            if lowerObjective.contains(phrase) && lowerBody.contains(phrase) { score += 10 }
        }
        return score
    }

    private static func layerPriority(_ layer: CaptainMemoryLayerID) -> Int {
        switch layer {
        case .organizationalRules: return 18
        case .benchmarks: return 12
        case .knowledgeIndex: return 10
        case .projectHistory: return 8
        case .researchArchive: return 8
        case .industryIntelligence: return 8
        case .contextWindow: return 0
        }
    }

    private static func tokens(_ text: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "and", "for", "from", "with", "that", "this", "then", "into", "your", "our",
            "you", "are", "was", "were", "has", "have", "had", "not", "but", "can", "will",
            "current", "new", "old", "task", "work", "fix", "build", "make"
        ]
        return text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) }
    }
}

public enum CaptainDecisionCards {
    public static func build(objective: String,
                             retrieval: [CaptainRetrievedMemory],
                             strategy: CaptainStrategyPlan) -> [CaptainDecisionCard] {
        var cards: [CaptainDecisionCard] = []
        let evidenceIDs = retrieval.map(\.evidenceID)
        cards.append(CaptainDecisionCard(
            kind: .contextRetrieval,
            title: "Context Window Load",
            decision: retrieval.isEmpty ? "Start with fresh project evidence." : "Load \(retrieval.count) relevant disk-backed record(s) into working memory.",
            confidence: retrieval.isEmpty ? 55 : min(95, 60 + retrieval.count * 5),
            reason: retrieval.isEmpty
                ? "No matching long-term memory was found for this objective."
                : "The retrieved records ranked highest for objective overlap and layer priority.",
            evidenceIDs: evidenceIDs,
            risk: retrieval.count > 8 ? "Context flooding." : "Missing stale or uncaptured knowledge.",
            nextAction: "Use only these records in the current context window unless new evidence is gathered."
        ))

        let ruleEvidence = retrieval.filter { $0.layerID == .organizationalRules }.map(\.evidenceID)
        if !ruleEvidence.isEmpty {
            cards.append(CaptainDecisionCard(
                kind: .ruleApplication,
                title: "Applicable Organizational Rules",
                decision: "Apply retrieved constitutional rules before planning.",
                confidence: 92,
                reason: "Organizational Rules are Captain's constitution and ranked relevant to this objective.",
                evidenceIDs: ruleEvidence,
                risk: "A stale rule could over-constrain work if never retired.",
                nextAction: "Treat these rules as constraints and note any rule that should be challenged."
            ))
        }

        if !strategy.understanding.canOrganize {
            cards.append(CaptainDecisionCard(
                kind: .researchGate,
                title: "Research Gate",
                decision: "Research before execution.",
                confidence: max(70, strategy.understanding.threshold - strategy.understanding.confidence + 55),
                reason: strategy.understanding.gateSummary,
                evidenceIDs: evidenceIDs,
                risk: "Building before expertise will encode weak assumptions.",
                nextAction: "Answer missing-knowledge questions before spawning workers."
            ))
        }

        if objective.lowercased().contains("simulate")
            || objective.lowercased().contains("sandbox")
            || objective.lowercased().contains("risk")
            || objective.lowercased().contains("trial")
            || objective.lowercased().contains("probabilistic") {
            cards.append(CaptainDecisionCard(
                kind: .simulationGate,
                title: "Simulation Gate",
                decision: "Run sandbox simulation and probabilistic trials before real-world execution.",
                confidence: 86,
                reason: "The objective explicitly asks for risk or simulation handling.",
                evidenceIDs: evidenceIDs,
                risk: "A sandbox can be over-trusted if its assumptions are not reviewed.",
                nextAction: "Use `/simulate <objective>` to create the trial matrix, benchmark record, and accept/reject tasks."
            ))
        }

        let benchmarkEvidence = retrieval.filter { $0.layerID == .benchmarks }.map(\.evidenceID)
        if objective.lowercased().contains("benchmark")
            || objective.lowercased().contains("eval")
            || objective.lowercased().contains("routing")
            || !benchmarkEvidence.isEmpty {
            cards.append(CaptainDecisionCard(
                kind: .benchmarkGate,
                title: "Benchmark Gate",
                decision: "Require benchmark or live-eval evidence before policy promotion.",
                confidence: benchmarkEvidence.isEmpty ? 75 : 88,
                reason: "The objective touches evaluation, routing, or policy behavior.",
                evidenceIDs: benchmarkEvidence,
                risk: "A policy change can feel better while regressing measured behavior.",
                nextAction: "Define the eval command or live-loop metric before accepting the change."
            ))
        }

        let missing = strategy.missingSpecialists.map(\.name)
        if !strategy.requiredExpertise.isEmpty {
            cards.append(CaptainDecisionCard(
                kind: .specialistAssignment,
                title: "Specialist Assignment",
                decision: missing.isEmpty
                    ? "Use existing specialists for required expertise."
                    : "Create missing specialists: \(missing.prefix(5).joined(separator: ", ")).",
                confidence: missing.isEmpty ? 82 : 76,
                reason: "Required expertise was inferred after objective and project evidence analysis.",
                evidenceIDs: evidenceIDs,
                risk: "Specialists created too early can reflect the wrong problem framing.",
                nextAction: "Assemble specialists after research confirms the expertise map."
            ))
        }
        return cards
    }
}

public struct CaptainStrategyPlan: Sendable, Equatable {
    public let objective: String
    public let understood: Bool
    public let understanding: CaptainUnderstandingAssessment
    public let researchQuestions: [String]
    public let requiredExpertise: [CaptainExpertiseNeed]
    public let existingSpecialists: [String]
    public let missingSpecialists: [SpecialistDefinition]
    public let orderedStages: [CaptainStrategyStage]
    public let projectEvidence: CaptainProjectEvidence?
    public let memoryArchitecture: CaptainMemoryArchitecture
    public let nextAction: String

    public init(objective: String, understood: Bool,
                understanding: CaptainUnderstandingAssessment,
                researchQuestions: [String],
                requiredExpertise: [CaptainExpertiseNeed], existingSpecialists: [String],
                missingSpecialists: [SpecialistDefinition], orderedStages: [CaptainStrategyStage],
                projectEvidence: CaptainProjectEvidence?,
                memoryArchitecture: CaptainMemoryArchitecture = .default,
                nextAction: String) {
        self.objective = objective
        self.understood = understood
        self.understanding = understanding
        self.researchQuestions = researchQuestions
        self.requiredExpertise = requiredExpertise
        self.existingSpecialists = existingSpecialists
        self.missingSpecialists = missingSpecialists
        self.orderedStages = orderedStages
        self.projectEvidence = projectEvidence
        self.memoryArchitecture = memoryArchitecture
        self.nextAction = nextAction
    }

    public var briefing: String {
        var lines = [
            "CAPTAIN STRATEGY PIPELINE",
            "objective: \(objective)",
            "order: \(orderedStages.map(\.title).joined(separator: " -> "))",
            "",
            "CAPTAIN RULES",
        ]
        lines += CaptainStrategist.commandments.map { "- \($0)" }
        lines += [
            "",
            "principle: Research before expertise. Expertise before organization. Organization before execution.",
            "philosophy: Always leave the organization smarter than before.",
            "understanding gate: \(understanding.gateSummary)",
            "",
            "CURRENT UNDERSTANDING",
            "\(understanding.confidence)% (threshold \(understanding.threshold)%)",
            understanding.currentUnderstanding,
        ]
        if !understanding.missingKnowledge.isEmpty {
            lines += [
                "",
                "MISSING KNOWLEDGE",
            ]
            lines += understanding.missingKnowledge.map { "- \($0)" }
            lines += ["", "RECOMMENDED RESEARCH TIME", understanding.recommendedResearchTime]
        }
        if let projectEvidence {
            lines += ["", projectEvidence.briefing]
        }
        lines += ["", memoryArchitecture.briefing]
        lines += ["", "RESEARCH QUESTIONS"]
        lines += researchQuestions.map { "- \($0)" }
        lines += ["", "STRATEGIC INTELLIGENCE"]
        lines += CaptainStrategist.strategicIntelligenceQuestions.map { "- \($0)" }
        lines += [
            "",
            "TEACH CAPTAIN",
            "Question: What organizational lesson should become permanent?",
            "Candidate rule: \(CaptainStrategist.organizationalLessonCandidate(objective: objective, expertiseNames: requiredExpertise.map(\.name)))",
            "Promotion gate: recurring or high-confidence lesson with evidence, benchmark impact, or avoided failure."
        ]
        lines += ["", "REQUIRED EXPERTISE"]
        for need in requiredExpertise {
            let coverage = need.isCovered ? "covered by \(need.existingSpecialists.joined(separator: ", "))" : "missing"
            lines.append("- \(need.name): \(coverage) -- \(need.reason)")
        }
        if !missingSpecialists.isEmpty {
            lines += ["", "SPECIALISTS TO CREATE"]
            lines += missingSpecialists.map { "- \($0.name): \($0.description)" }
        }
        lines += ["", "NEXT", nextAction]
        return lines.joined(separator: "\n")
    }
}

public enum CaptainStrategist {
    public static let operatingOrder: [CaptainStrategyStage] = [
        .objective, .captain, .research, .researchPlan, .researchChecklist,
        .knowledgeGapAnalysis, .becomeSubjectMatterExpert, .executionPlan,
        .assembleExistingSpecialists, .createNewSpecialists, .planning,
        .buildPossiblePlan, .sandboxSimulation, .probabilisticTrials,
        .riskEstimation, .strategyComparison, .pickSafestHighestValueOption,
        .execution, .build,
        .selfReview, .independentAIReview, .crossCompare, .benchmarks,
        .evidence, .acceptOrReject, .retrospective, .knowledgeGained,
        .knowledgeDebt, .researchQueue, .platformEvolution, .strategicIntelligence,
        .evolutionProposal, .teachCaptain, .memory, .readyForNextObjective
    ]

    public static let commandments: [String] = [
        "Never build before researching.",
        "Never research without a plan.",
        "Never plan without understanding.",
        "Never execute without evidence.",
        "Never act in the real world before sandbox simulation and probabilistic risk comparison when failure can hurt users, systems, money, or reputation.",
        "Never trust one AI.",
        "Always seek independent review.",
        "Always compare against industry standards, competitors, papers, and open source.",
        "Always identify knowledge gaps.",
        "Always leave the organization smarter than before.",
        "Always watch the industry before declaring the platform done.",
        "Always ask what organizational lesson should become permanent."
    ]

    public static let strategicIntelligenceQuestions: [String] = [
        "What changed in the industry today that could affect Kist?",
        "What research papers, benchmark suites, or open-source projects appeared or matured?",
        "Did competitors ship a workflow, agent runtime, permission model, or persistence primitive Kist should compare against?",
        "Should Kist architecture, model routing, tool policy, memory, or evaluation change because of that evidence?",
        "What evolution proposal should be created, rejected, or deferred?"
    ]

    public static func plan(objective rawObjective: String,
                            evidence: CaptainProjectEvidence? = nil,
                            specialists: [SpecialistDefinition] = []) -> CaptainStrategyPlan {
        let objective = normalize(rawObjective)
        let lower = objective.lowercased()
        let questions = researchQuestions(objective: objective, evidence: evidence)
        let needSpecs = inferNeeds(lower: lower, evidence: evidence)
        let assessment = understandingAssessment(lower: lower,
                                                 evidence: evidence,
                                                 questions: questions,
                                                 needSpecs: needSpecs)
        let needs = needSpecs.map { spec -> CaptainExpertiseNeed in
            let matches = matchingSpecialists(for: spec, specialists: specialists)
            let suggested = matches.isEmpty ? suggestedSpecialist(for: spec) : nil
            return CaptainExpertiseNeed(name: spec.name, reason: spec.reason, keywords: spec.keywords,
                                        existingSpecialists: matches.map(\.name),
                                        suggestedSpecialist: suggested)
        }
        let missing = needs.compactMap(\.suggestedSpecialist)
        let covered = needs.flatMap(\.existingSpecialists).sorted()
        let understood = assessment.canOrganize
        let next = understood
            ? "Act as a temporary subject-matter expert, design the organization, then plan with the covered specialist roster."
            : "Learn the domain first. Research until confidence reaches \(assessment.threshold)% before planning or spawning workers."
        return CaptainStrategyPlan(objective: objective,
                                   understood: understood,
                                   understanding: assessment,
                                   researchQuestions: questions,
                                   requiredExpertise: needs,
                                   existingSpecialists: covered,
                                   missingSpecialists: missing,
                                   orderedStages: operatingOrder,
                                   projectEvidence: evidence,
                                   nextAction: next)
    }

    public static func promptGuidance(objective: String) -> [String] {
        let plan = plan(objective: objective)
        var lines = [
            "Captain is the orchestration process, not the worker model. Treat models and specialists as workers the Captain commands.",
            "Use this operating order: \(operatingOrder.map(\.title).joined(separator: " -> ")).",
            "Captain commandments: \(commandments.joined(separator: " "))",
            "Captain memory architecture: Context Window is RAM; Knowledge Index, Organizational Rules, Research Archive, Industry Intelligence, Benchmarks, and Project History are disk.",
            "Retrieve only relevant disk-backed facts into the context window; do not flood working memory with everything Kist knows.",
            "Captain's first responsibility is learning, not coding. Admit when the domain is not understood yet.",
            "Research until the understanding confidence threshold is met; only then act as a temporary subject-matter expert.",
            "After research, determine required expertise, use existing specialists first, and create a new specialist only when an expertise gap is real.",
            "Planning and execution come after research, understanding, and organization design; build a possible plan, run sandbox simulations and probabilistic trials, estimate failure risk, compare strategies, then execute only after evidence clears the gate.",
            "Self-review, independent AI review, cross-compare, benchmark, evidence, and accept/reject come before retrospective.",
            "Retrospective must create Knowledge Gained, Knowledge Debt, Research Queue, Platform Evolution, Strategic Intelligence, Evolution Proposal, Teach Captain, and Memory updates.",
            "Strategic Intelligence asks what changed in industry, papers, competitors, standards, and architecture pressure before declaring the platform done.",
            "Teach Captain promotes high-confidence lessons into permanent organizational rules; this is institutional knowledge, not transcript memory.",
        ]
        lines.append("Current understanding estimate: \(plan.understanding.confidence)% (threshold \(plan.understanding.threshold)%).")
        if !plan.understanding.canOrganize {
            lines.append("Below threshold: do not pretend expertise; perform research and report missing knowledge before execution.")
        }
        lines += plan.researchQuestions.prefix(4).map { "Research question: \($0)" }
        return lines
    }

    private struct NeedSpec: Equatable {
        let name: String
        let reason: String
        let keywords: [String]
        let color: String
    }

    private static func inferNeeds(lower: String, evidence: CaptainProjectEvidence?) -> [NeedSpec] {
        var specs: [NeedSpec] = []
        func add(_ name: String, _ reason: String, _ keywords: [String], color: String = "cyan") {
            guard !specs.contains(where: { $0.name == name }) else { return }
            specs.append(NeedSpec(name: name, reason: reason, keywords: keywords, color: color))
        }

        add("systems-architect", "Keep architecture coherent before implementation starts.",
            ["architecture", "system", "design", "planning", "roadmap"], color: "blue")

        if containsAny(lower, ["captain", "orchestrat", "agent", "swarm", "fleet", "delegate", "worker", "specialist", "model assign"]) {
            add("agent-orchestration-architect",
                "Design Captain-to-worker lifecycle, delegation gates, and non-colliding execution.",
                ["captain", "orchestration", "agent", "swarm", "fleet", "delegate", "worker", "specialist"], color: "purple")
        }
        if containsAny(lower, ["mcp", "tool", "protocol", "server", "lsp", "browser", "computer control"]) {
            add("tool-protocol-engineer",
                "Compare tool lifecycles, permissions, protocol boundaries, and failure isolation.",
                ["mcp", "tool", "protocol", "server", "permission", "lifecycle", "lsp"], color: "green")
        }
        if containsAny(lower, ["eval", "benchmark", "bench", "learning", "learn", "evolve", "dgm", "live eval"]) {
            add("eval-and-learning-engineer",
                "Build benchmark/live-eval loops so policy changes are earned by evidence.",
                ["eval", "benchmark", "learning", "evolve", "dgm", "experiment", "measurement"], color: "yellow")
        }
        if containsAny(lower, ["simulate", "simulation", "sandbox", "probabilistic", "trial", "risk",
                               "digital twin", "mock", "fake api", "failure mode"]) {
            add("simulation-and-risk-engineer",
                "Design sandbox simulations, probabilistic trials, failure-mode models, and accept/reject thresholds before real-world execution.",
                ["simulate", "simulation", "sandbox", "trial", "risk", "digital", "mock", "failure"], color: "blue")
        }
        if containsAny(lower, ["memory", "knowledge debt", "research queue", "retrospective", "reflection", "learned"]) {
            add("organizational-learning-architect",
                "Turn completed work into durable learning, knowledge debt, and platform evolution.",
                ["memory", "knowledge", "research", "retrospective", "reflection", "roadmap"], color: "cyan")
        }
        if containsAny(lower, ["strategic intelligence", "industry", "competitor", "papers", "paper", "roadmap", "architecture change"]) {
            add("strategic-intelligence-analyst",
                "Track industry movement, competitor workflows, papers, standards, and architecture pressure.",
                ["strategic", "industry", "competitor", "paper", "roadmap", "architecture", "proposal"], color: "blue")
        }
        if containsAny(lower, ["teach captain", "organizational rule", "institutional", "permanent lesson", "lesson", "commandment"]) {
            add("organizational-rule-steward",
                "Promote recurring high-confidence lessons into permanent organizational rules with evidence.",
                ["teach", "rule", "institutional", "lesson", "commandment", "memory", "evidence"], color: "yellow")
        }
        if containsAny(lower, ["security", "auth", "permission", "sandbox", "secret", "token", "signoff", "gate"]) {
            add("security-reviewer",
                "Check permissions, secrets, sandboxing, and fail-closed gates before promotion.",
                ["security", "auth", "permission", "sandbox", "secret", "signoff", "gate"], color: "red")
        }
        if containsAny(lower, ["medical", "radiology", "dicom", "hipaa", "fda", "clinical", "healthcare", "imaging"]) {
            add("regulated-domain-researcher",
                "Learn regulated domain constraints before architecture or implementation decisions.",
                ["medical", "radiology", "dicom", "hipaa", "fda", "clinical", "regulated", "workflow"], color: "green")
        }
        if containsAny(lower, ["ui", "dashboard", "terminal", "repl", "tui", "frontend", "screen", "display"]) {
            add("product-ux-engineer",
                "Make the orchestration visible without flooding the user or hiding important state.",
                ["ui", "ux", "dashboard", "terminal", "repl", "tui", "display"], color: "pink")
        }
        if evidence?.languages.contains("Swift") == true
            || containsAny(lower, ["swift", "package.swift", "macos", "cli", "repl", "terminal"]) {
            add("swift-cli-engineer",
                "Implement changes in the Swift CLI/runtime while respecting package and test patterns.",
                ["swift", "cli", "package", "macos", "repl", "terminal"], color: "orange")
        }
        if evidence?.languages.contains("TypeScript") == true
            || containsAny(lower, ["react", "typescript", "frontend", "web", "tsx"]) {
            add("frontend-engineer",
                "Handle web/frontend concerns when the objective reaches UI surfaces.",
                ["react", "typescript", "frontend", "web", "tsx", "ui"], color: "blue")
        }
        return specs
    }

    private static func understandingAssessment(lower: String, evidence: CaptainProjectEvidence?,
                                                questions: [String],
                                                needSpecs: [NeedSpec]) -> CaptainUnderstandingAssessment {
        let threshold = 80
        var confidence = 35
        if let evidence {
            if evidence.trackedFileCount > 0 { confidence += 10 }
            if !evidence.languages.isEmpty { confidence += 8 }
            if !evidence.manifests.isEmpty { confidence += 6 }
            if !evidence.testEntrypoints.isEmpty { confidence += 6 }
            if !evidence.changedFiles.isEmpty { confidence += 4 }
        }
        if needSpecs.contains(where: { $0.name == "agent-orchestration-architect" }) { confidence += 6 }
        if needSpecs.contains(where: { $0.name == "swift-cli-engineer" }) { confidence += 4 }
        if looksUnderstoodOnlyAfterResearch(lower) { confidence -= 14 }
        if containsAny(lower, ["medical", "radiology", "dicom", "hipaa", "fda", "clinical", "healthcare", "legal", "finance"]) {
            confidence -= 22
        }

        let missing = missingKnowledge(lower: lower, evidence: evidence, questions: questions,
                                       needSpecs: needSpecs)
        confidence -= min(18, missing.count * 2)
        confidence = min(95, max(20, confidence))
        let researchTime = recommendedResearchTime(confidence: confidence, threshold: threshold,
                                                   missingCount: missing.count)
        let understanding = confidence >= threshold
            ? "Captain has enough project and domain evidence to lead organization design, but should still validate assumptions."
            : "Captain should not pretend to be the subject expert yet. Research first, then lead."
        return CaptainUnderstandingAssessment(confidence: confidence,
                                              threshold: threshold,
                                              currentUnderstanding: understanding,
                                              missingKnowledge: missing,
                                              recommendedResearchTime: researchTime)
    }

    private static func missingKnowledge(lower: String, evidence: CaptainProjectEvidence?,
                                         questions: [String],
                                         needSpecs: [NeedSpec]) -> [String] {
        var items: [String] = []
        func add(_ item: String) {
            guard !items.contains(item) else { return }
            items.append(item)
        }

        add("Landscape analysis: what already solves this, and where those systems fail.")
        add("Primary documentation and source examples for the core technologies.")
        add("Architecture comparison against competitors and open-source peers.")
        add("Benchmark/eval design that proves the chosen approach improves outcomes.")
        add("Sandbox simulation design: disposable environment, trial count, failure modes, and accept/reject threshold.")

        if containsAny(lower, ["captain", "orchestrat", "agent", "swarm", "fleet", "delegate"]) {
            add("Claude Code, Cursor background agents, OpenHands, and MCP lifecycle comparisons.")
            add("Delegation decision-card design: why this specialist/model, confidence, cost, and risk.")
        }
        if containsAny(lower, ["medical", "radiology", "dicom", "imaging"]) {
            add("DICOM fundamentals, PACS/RIS workflows, and open-source medical imaging platforms.")
            add("Clinical user workflows: radiologist, technician, administrator, and audit trail needs.")
        }
        if containsAny(lower, ["hipaa", "fda", "clinical", "healthcare", "medical"]) {
            add("HIPAA, FDA/SaMD, privacy, audit, and compliance constraints before implementation.")
        }
        if containsAny(lower, ["oauth", "auth", "security", "permission", "sandbox"]) {
            add("OAuth/security edge cases, threat model, permission boundaries, and recovery paths.")
        }
        if containsAny(lower, ["apple", "foundation models", "offline", "local reasoning"]) {
            add("Apple Foundation Models local reasoning docs and offline orchestration constraints.")
        }
        if containsAny(lower, ["strategic intelligence", "industry", "competitor", "papers", "paper", "roadmap"]) {
            add("Strategic intelligence feed: current competitor releases, papers, standards, and product shifts.")
        }
        if containsAny(lower, ["teach captain", "organizational rule", "institutional", "permanent lesson", "lesson"]) {
            add("Promotion criteria for turning lessons into permanent organizational rules.")
        }
        if evidence?.trackedFileCount == 0 {
            add("Local project evidence: files, manifests, test entrypoints, and current architecture.")
        }
        if evidence?.testEntrypoints.isEmpty != false {
            add("Verification entrypoint or benchmark harness for this domain.")
        }
        if questions.count > 6 {
            add("Research notes that answer the open questions with citations or local evidence.")
        }
        return Array(items.prefix(10))
    }

    private static func recommendedResearchTime(confidence: Int, threshold: Int, missingCount: Int) -> String {
        let gap = max(0, threshold - confidence)
        if gap >= 35 || missingCount >= 8 { return "4-6 hours" }
        if gap >= 20 || missingCount >= 5 { return "2-3 hours" }
        if gap >= 10 { return "1-2 hours" }
        return "30-60 minutes"
    }

    private static func researchQuestions(objective: String, evidence: CaptainProjectEvidence?) -> [String] {
        var out = [
            "What is this objective really asking us to change?",
            "What technologies, protocols, and runtime constraints already exist for this class of problem?",
            "What already solves this well in comparable products or open-source systems?",
            "What documentation, source code, and design notes should we read before planning?",
            "What competitors probably solved better, and what should we reverse engineer?",
            "What papers or benchmark suites could change the architecture decision?",
            "What industry standards and best practices constrain acceptable design?",
            "What known failures, incident reports, or anti-patterns should we avoid?",
            "What evidence in this project proves the current architecture and its weak points?",
            "What benchmark or live eval would prove the next policy change is better?"
        ]
        out.append("What sandbox, fake API, digital twin, benchmark, or probabilistic trial can safely test this before real-world execution?")
        out += strategicIntelligenceQuestions
        out.append("What organizational lesson, if proven, should Teach Captain promote into a permanent rule?")
        if let evidence {
            if !evidence.languages.isEmpty {
                out.append("How do the project's languages (\(evidence.languages.joined(separator: ", "))) constrain the implementation strategy?")
            }
            if !evidence.testEntrypoints.isEmpty {
                out.append("Which existing verification entrypoint (\(evidence.testEntrypoints.joined(separator: ", "))) becomes the benchmark gate?")
            }
            if !evidence.changedFiles.isEmpty {
                out.append("Do the current changed files reveal unfinished architecture or risky drift?")
            }
        }
        return out
    }

    public static func organizationalLessonCandidate(objective: String,
                                                      expertiseNames: [String] = []) -> String {
        let lower = objective.lowercased()
        let expertise = Set(expertiseNames)
        if containsAny(lower, ["medical", "radiology", "dicom", "hipaa", "fda", "clinical", "healthcare"])
            || expertise.contains("regulated-domain-researcher") {
            return "Regulated or medical projects require domain, workflow, privacy, and compliance research before planning."
        }
        if containsAny(lower, ["strategic intelligence", "industry", "competitor", "papers", "roadmap"])
            || expertise.contains("strategic-intelligence-analyst") {
            return "Platform evolution requires recurring strategic-intelligence review of competitors, papers, standards, and architecture pressure."
        }
        if containsAny(lower, ["teach captain", "organizational rule", "institutional", "permanent lesson"])
            || expertise.contains("organizational-rule-steward") {
            return "High-confidence lessons should be promoted into permanent organizational rules, separate from memory."
        }
        if containsAny(lower, ["eval", "benchmark", "learning", "evolve", "live eval"])
            || expertise.contains("eval-and-learning-engineer") {
            return "Learning-system changes require benchmark or live-eval evidence before policy promotion."
        }
        if containsAny(lower, ["simulate", "simulation", "sandbox", "probabilistic", "trial", "risk"])
            || expertise.contains("simulation-and-risk-engineer") {
            return "Risk-bearing objectives require sandbox simulation, probabilistic trials, strategy comparison, and accept/reject evidence before real-world execution."
        }
        if containsAny(lower, ["captain", "orchestrat", "agent", "swarm", "fleet", "delegate"])
            || expertise.contains("agent-orchestration-architect") {
            return "Agent-orchestration work requires competitor/runtime comparison before implementation."
        }
        return "Every non-trivial objective must leave behind research, evidence, review, and one candidate organizational lesson."
    }

    private static func matchingSpecialists(for spec: NeedSpec,
                                            specialists: [SpecialistDefinition]) -> [SpecialistDefinition] {
        let needles = Set((spec.keywords + [spec.name]).flatMap(tokens))
        guard !needles.isEmpty else { return [] }
        let scored = specialists.map { def -> (SpecialistDefinition, Int) in
            let hay = Set(tokens(def.name + " " + def.description + " " + String(def.systemPrompt.prefix(500))))
            return (def, needles.intersection(hay).count)
        }.filter { $0.1 > 0 }
        return scored.sorted { a, b in
            a.1 == b.1 ? a.0.name < b.0.name : a.1 > b.1
        }.prefix(3).map(\.0)
    }

    private static func suggestedSpecialist(for spec: NeedSpec) -> SpecialistDefinition {
        SpecialistDefinition(
            name: spec.name,
            description: spec.reason,
            systemPrompt: """
            You are Kist's \(spec.name). Work only after the Captain has gathered enough evidence to understand the objective. Identify the required expertise, compare local project facts with external research, propose risks and benchmarks, then produce a concise recommendation that can be verified.
            """,
            toolAllowlist: ["read_file", "search_code", "tasks"],
            modelAlias: "inherit",
            permissionMode: "plan",
            maxTurns: 6,
            memory: "project",
            color: spec.color,
            source: "captain-strategy"
        )
    }

    private static func looksUnderstoodOnlyAfterResearch(_ lower: String) -> Bool {
        let signal = tokens(lower).filter { $0.count > 2 }
        if signal.count < 4 { return true }
        return containsAny(lower, ["build it all", "make it better", "fix this", "everything", "fully shift",
                                   "best", "autonomous", "evolve", "platform", "organization", "architecture"])
    }

    private static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty objective)" : trimmed
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }
    }
}
