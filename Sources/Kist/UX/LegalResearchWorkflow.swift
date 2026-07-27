import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(PDFKit)
import PDFKit
#endif

struct LegalResearchAssignment: Equatable, Sendable, Codable {
    var specialistName: String
    var role: String
    var preferredModel: String
    var task: String
}

struct LegalResearchSource: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case text, pdf, document, unsupported }

    var originalToken: String
    var path: String
    var displayPath: String
    var kind: Kind
    var byteCount: Int
    var extractedText: String
    var extractionNote: String

    var hasExtractedText: Bool {
        !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LegalJurisdictionDetection: Equatable, Sendable {
    var jurisdiction: String?
    var confidence: Int
    var evidence: String

    static let missing = LegalJurisdictionDetection(jurisdiction: nil,
                                                    confidence: 0,
                                                    evidence: "no jurisdiction evidence")
}

struct LegalResearchReport: Equatable, Sendable {
    var path: String
    var text: String
    var objective: String
    var jurisdiction: String?
    var jurisdictionConfidence: Int
    var jurisdictionEvidence: String
    var documentType: String
    var sourceCount: Int
    var extractedSourceCount: Int
    var seededTasks: Int
    var createdSpecialists: Int
    var memoryRecords: Int
    var knowledgeDebtCreated: Int
    var agentAssignments: [LegalResearchAssignment]
    var researchGoal: String
    var dispatchCommand: String
    var readyForResearch: Bool
    var blockers: [String]
    var writeSucceeded: Bool
    var writeError: String?
}

struct LegalResearchWorkflow: Sendable {
    let projectRoot: String
    private let now: @Sendable () -> Date
    private let makeSpecialistRegistry: @Sendable (String) -> SpecialistRegistry

    init(projectRoot: String,
         now: @escaping @Sendable () -> Date = { Date() },
         specialistRegistry: @escaping @Sendable (String) -> SpecialistRegistry = { SpecialistRegistry(projectRoot: $0) }) {
        self.projectRoot = ToolContext.canonicalize(projectRoot) ?? projectRoot
        self.now = now
        self.makeSpecialistRegistry = specialistRegistry
    }

    var legalResearchRoot: String {
        projectRoot + "/.kist/learning/research-archive/legal-research"
    }

    func run(input rawInput: String, trajectory: [ActionRecord] = []) -> LegalResearchReport {
        let parsed = Self.parse(rawInput, projectRoot: projectRoot)
        let sources = parsed.sources.map { loadSource($0) }
        let extractedText = sources
            .filter(\.hasExtractedText)
            .map { "# \($0.displayPath)\n\($0.extractedText)" }
            .joined(separator: "\n\n---\n\n")
        let objective = Self.objective(from: parsed.cleanedInput, sources: sources)
        let detection = parsed.jurisdiction.jurisdiction != nil
            ? parsed.jurisdiction
            : Self.detectJurisdiction(in: [objective, extractedText].joined(separator: "\n"))
        let jurisdiction = detection.jurisdiction
        let documentType = Self.detectDocumentType(in: [objective, extractedText].joined(separator: "\n"))
        let blockers = Self.blockers(objective: objective, jurisdiction: jurisdiction,
                                     jurisdictionConfidence: detection.confidence, sources: sources)
        let ready = blockers.isEmpty
        let assignments = legalAssignments(objective: objective,
                                           jurisdiction: jurisdiction,
                                           documentType: documentType,
                                           sources: sources)
        let createdSpecialists = createLegalSpecialists()
        let timestamp = Int(now().timeIntervalSince1970)
        let path = legalResearchRoot + "/\(timestamp)-\(Self.slug(objective)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        let researchGoal = Self.researchGoal(objective: objective,
                                             jurisdiction: jurisdiction,
                                             documentType: documentType,
                                             sources: sources,
                                             extractedText: extractedText)
        let seededTasks = seedTasks(objective: objective,
                                    jurisdiction: jurisdiction,
                                    jurisdictionConfidence: detection.confidence,
                                    documentType: documentType,
                                    sources: sources,
                                    assignments: assignments,
                                    reportPath: relativePath,
                                    ready: ready,
                                    trajectory: trajectory)
        let knowledgeDebt = seedKnowledgeDebt(objective: objective,
                                              jurisdiction: jurisdiction,
                                              documentType: documentType,
                                              sources: sources,
                                              blockers: blockers)
        let memoryRecords = recordMemory(objective: objective,
                                         jurisdiction: jurisdiction,
                                         documentType: documentType,
                                         reportPath: relativePath,
                                         ready: ready,
                                         blockers: blockers)
        let dispatchCommand = "/legal-research run \(objective)"
        let text = renderReport(objective: objective,
                                jurisdiction: jurisdiction,
                                jurisdictionConfidence: detection.confidence,
                                jurisdictionEvidence: detection.evidence,
                                documentType: documentType,
                                sources: sources,
                                assignments: assignments,
                                researchGoal: researchGoal,
                                reportPath: relativePath,
                                blockers: blockers,
                                dispatchCommand: dispatchCommand)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
        }

        return LegalResearchReport(path: relativePath,
                                   text: text,
                                   objective: objective,
                                   jurisdiction: jurisdiction,
                                   jurisdictionConfidence: detection.confidence,
                                   jurisdictionEvidence: detection.evidence,
                                   documentType: documentType,
                                   sourceCount: sources.count,
                                   extractedSourceCount: sources.filter(\.hasExtractedText).count,
                                   seededTasks: seededTasks,
                                   createdSpecialists: createdSpecialists,
                                   memoryRecords: memoryRecords,
                                   knowledgeDebtCreated: knowledgeDebt,
                                   agentAssignments: assignments,
                                   researchGoal: researchGoal,
                                   dispatchCommand: dispatchCommand,
                                   readyForResearch: ready,
                                   blockers: blockers,
                                   writeSucceeded: writeSucceeded,
                                   writeError: writeError)
    }

    static func isLegalResearchIntent(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        let repairWords = ["fix the code", "bug", "malformed", "self-heal", "self heal", "failed request"]
        if repairWords.contains(where: { lower.contains($0) }) { return false }
        let exactSignals = [
            "legal research", "full legal research", "legal memo", "law research",
            "case law", "court rule", "statutory research", "research this case",
            "analyze this contract legally", "legal document"
        ]
        if exactSignals.contains(where: { lower.contains($0) }) { return true }
        let legalSignals = [
            "legal", "law", "statute", "regulation", "court", "attorney", "lawsuit",
            "litigation", "foreclosure", "eviction", "lease", "deed", "mortgage",
            "contract", "plaintiff", "defendant", "jurisdiction"
        ]
        let workSignals = ["research", "analyze", "review", "memo", "case", "document", "question", "help"]
        return legalSignals.contains { lower.contains($0) }
            && workSignals.contains { lower.contains($0) }
    }

    static func shouldAutoRunResearch(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isLegalResearchIntent(lower) else { return false }
        if lower.hasPrefix("plan ") || lower.contains("plan only") || lower.contains("don't research yet") {
            return false
        }
        return lower.contains("full") || lower.contains("research") || lower.contains("run")
            || lower.contains("do it") || lower.contains("help me")
    }

    static func parse(_ raw: String, projectRoot: String) -> (cleanedInput: String, sources: [(token: String, path: String)], jurisdiction: LegalJurisdictionDetection) {
        var kept: [String] = []
        var sources: [(token: String, path: String)] = []
        for token in MediaResolver.tokenize(raw) {
            if let path = resolveLegalDocumentPath(token, projectRoot: projectRoot) {
                sources.append((token, ToolContext.canonicalize(path) ?? path))
            } else {
                kept.append(token)
            }
        }
        let cleaned = stripExternalConsentMarkers(stripCommandPrefixes(kept.joined(separator: " ")))
        let jurisdiction = detectJurisdiction(in: cleaned)
        return (cleaned, sources, jurisdiction)
    }

    static func resolveLegalDocumentPath(_ rawToken: String, projectRoot: String) -> String? {
        var token = rawToken
        if token.hasPrefix("@") { token.removeFirst() }
        guard !token.isEmpty else { return nil }
        let ext = (token as NSString).pathExtension.lowercased()
        guard legalDocumentExtensions.contains(ext) else { return nil }
        for candidate in MediaResolver.candidatePaths(token, projectRoot: projectRoot) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                guard let confined = confinedLegalDocumentPath(candidate, projectRoot: projectRoot) else {
                    continue
                }
                return confined
            }
        }
        return nil
    }

    private static func confinedLegalDocumentPath(_ path: String, projectRoot: String) -> String? {
        let root = ToolContext.canonicalize(projectRoot)
            ?? URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL.path
        guard let canonical = ToolContext.canonicalize(path) else { return nil }
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        guard canonical == root || canonical.hasPrefix(rootPrefix) else { return nil }
        return canonical
    }

    private func loadSource(_ source: (token: String, path: String)) -> LegalResearchSource {
        let ext = (source.path as NSString).pathExtension.lowercased()
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        let display = Self.projectRelative(source.path, root: projectRoot)
        switch ext {
        case "pdf":
            let extracted = Self.extractPDFText(source.path)
            return LegalResearchSource(originalToken: source.token,
                                       path: source.path,
                                       displayPath: display,
                                       kind: .pdf,
                                       byteCount: size,
                                       extractedText: extracted.text,
                                       extractionNote: extracted.note)
        case "txt", "md", "markdown", "rtf", "html", "htm":
            let text = (try? String(contentsOfFile: source.path, encoding: .utf8))
                ?? (try? String(contentsOfFile: source.path, encoding: .ascii))
                ?? ""
            let safeText = Self.safe(text)
            let clipped = Self.excerptInfo(safeText, limit: 12_000)
            var note = safeText.isEmpty ? "text extraction failed" : "text extracted locally"
            if clipped.truncated {
                note += "; truncated to 12000 characters"
            }
            return LegalResearchSource(originalToken: source.token,
                                       path: source.path,
                                       displayPath: display,
                                       kind: .text,
                                       byteCount: size,
                                       extractedText: clipped.text,
                                       extractionNote: note)
        case "doc", "docx":
            return LegalResearchSource(originalToken: source.token,
                                       path: source.path,
                                       displayPath: display,
                                       kind: .document,
                                       byteCount: size,
                                       extractedText: "",
                                       extractionNote: "DOC/DOCX text extraction is not available yet; convert to PDF/text or paste content for full analysis")
        default:
            return LegalResearchSource(originalToken: source.token,
                                       path: source.path,
                                       displayPath: display,
                                       kind: .unsupported,
                                       byteCount: size,
                                       extractedText: "",
                                       extractionNote: "unsupported legal document type")
        }
    }

    private func createLegalSpecialists() -> Int {
        let registry = makeSpecialistRegistry(projectRoot)
        let existing = Set(registry.load().map(\.name))
        let defs = [
            SpecialistDefinition(
                name: "legal-document-intake",
                description: "Extracts facts, parties, dates, deadlines, legal issues, assumptions, and missing evidence from legal documents before research.",
                systemPrompt: """
                You are Kist's legal document intake analyst. This is research support, not legal advice. Extract only what the document supports: parties, dates, jurisdiction clues, claims, obligations, deadlines, exhibits needed, contradictions, and missing facts. Do not invent law. Hand off research questions to the legal research lead.
                """,
                toolAllowlist: ["read_file", "tasks", "ask_user"],
                modelAlias: "inherit",
                permissionMode: "plan",
                maxTurns: 6,
                memory: "project",
                color: "cyan",
                source: "captain-legal-research"),
            SpecialistDefinition(
                name: "legal-research-lead",
                description: "Runs jurisdiction-specific legal research from official sources first and produces cited legal research memos.",
                systemPrompt: """
                You are Kist's legal research lead. This is research support, not legal advice. Start with jurisdiction and source hierarchy. Use official statutes, regulations, court/agency guidance, legal aid/government resources, and primary materials before blogs. Separate document facts from source-backed legal facts. Produce citations, risks, deadlines, research gaps, and questions for a licensed attorney.
                """,
                toolAllowlist: ["web_search", "fetch_url", "read_file", "tasks", "ask_user"],
                modelAlias: "inherit",
                permissionMode: "plan",
                maxTurns: 8,
                memory: "project",
                color: "green",
                source: "captain-legal-research"),
            SpecialistDefinition(
                name: "legal-citation-critic",
                description: "Independently reviews legal research for citation quality, jurisdiction drift, unsupported claims, deadlines, and legal-advice overreach.",
                systemPrompt: """
                You are Kist's legal citation critic. Be skeptical. Block unsupported claims, stale sources, wrong jurisdiction, blog-first research, legal-advice overreach, and missing deadline warnings. Require citations or mark a point as unknown. End with fixes needed before the memo can be trusted.
                """,
                toolAllowlist: ["web_search", "fetch_url", "read_file", "tasks", "ask_user"],
                model: ProviderBinding(providerId: "deepseek"),
                permissionMode: "plan",
                maxTurns: 6,
                memory: "project",
                color: "purple",
                source: "captain-legal-research")
        ]
        var created = 0
        for def in defs where !existing.contains(def.name) {
            if (try? registry.save(def)) != nil { created += 1 }
        }
        return created
    }

    private func legalAssignments(objective: String,
                                  jurisdiction: String?,
                                  documentType: String,
                                  sources: [LegalResearchSource]) -> [LegalResearchAssignment] {
        let sourceSummary = sources.isEmpty
            ? "No document source was attached; ask for the relevant document/facts if needed."
            : sources.map { "\($0.displayPath) (\($0.kind.rawValue), \($0.extractionNote))" }.joined(separator: "\n")
        let jurisdictionText = jurisdiction ?? "UNKNOWN - ask user before jurisdiction-specific conclusions"
        return [
            LegalResearchAssignment(
                specialistName: "legal-document-intake",
                role: "Document facts and missing evidence",
                preferredModel: "MiMo or strongest long-context model",
                task: """
                Objective: \(objective)
                Jurisdiction: \(jurisdictionText)
                Document type: \(documentType)
                Sources:
                \(sourceSummary)

                Extract parties, dates, deadlines, obligations, claimed facts, legal issues, evidence gaps, contradictions, and questions that must be answered before legal research conclusions.
                """),
            LegalResearchAssignment(
                specialistName: "legal-research-lead",
                role: "Official-source legal research memo",
                preferredModel: "Gemini/OpenAI with grounding or strongest research model",
                task: """
                Objective: \(objective)
                Jurisdiction: \(jurisdictionText)
                Document type: \(documentType)

                Run source-backed legal research. Official sources first. Separate document facts from law/source facts. Produce Issue Summary, Applicable Law/Programs, Risks/Deadlines, Evidence Needed, Attorney Questions, Sources Cited, and Research Gaps.
                """),
            LegalResearchAssignment(
                specialistName: "legal-citation-critic",
                role: "Independent legal research critique",
                preferredModel: "DeepSeek or independent critic model",
                task: """
                Objective: \(objective)
                Jurisdiction: \(jurisdictionText)
                Review the legal memo for unsupported claims, missing citations, wrong jurisdiction, legal-advice overreach, stale or weak sources, and missing deadline warnings. Return blocking findings first.
                """)
        ]
    }

    private func seedTasks(objective: String,
                           jurisdiction: String?,
                           jurisdictionConfidence: Int,
                           documentType: String,
                           sources: [LegalResearchSource],
                           assignments: [LegalResearchAssignment],
                           reportPath: String,
                           ready: Bool,
                           trajectory: [ActionRecord]) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        let activeBefore = store.load().active
        var firstAddedID: Int?
        var count = 0

        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String,
                 _ verification: String, _ evidence: [String] = []) {
            guard !store.load().tasks.contains(where: { $0.title == title }) else { return }
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

        add("PLAN: Legal research intake -- \(objective)", .plan, "captain",
            "Jurisdiction: \(jurisdiction ?? "unknown"). Document type: \(documentType). Sources: \(sources.count).",
            "Jurisdiction, source hierarchy, document facts, research questions, attorney questions, and citation requirements are explicit.",
            "/legal-research \(objective) shows the durable dossier.",
            [reportPath])
        if jurisdiction == nil {
            add("DECISION: Confirm legal jurisdiction -- \(objective)", .decision, "luke",
                "Legal research is jurisdiction-sensitive. Ask for state/country/court/venue before conclusions.",
                "Jurisdiction is recorded in the legal research dossier or the memo states only general educational context.",
                "Update the legal dossier with jurisdiction before running source-specific research.",
                [reportPath])
        }
        add("RESEARCH: Extract document facts -- \(objective)", .research, "legal-document-intake",
            "Extract parties, dates, deadlines, obligations, claims, evidence gaps, and assumptions from the attached or pasted document.",
            "Facts are separated from assumptions and every uncertainty is listed.",
            "Attach intake notes to the legal research report.",
            [reportPath])
        add("RESEARCH: Official-source legal research -- \(objective)", .research, "legal-research-lead",
            "Research official statutes, regulations, court/agency guidance, government/legal-aid resources, and primary material before secondary commentary.",
            "Memo cites sources and separates document facts, source-backed legal facts, assumptions, and unknowns.",
            "/research goal or specialist output is attached as evidence.",
            [reportPath])
        add("REVIEW: Citation and jurisdiction critique -- \(objective)", .review, "legal-citation-critic",
            "Check for wrong jurisdiction, unsupported claims, stale sources, legal-advice overreach, and missing deadline warnings.",
            "Critic either clears the memo or lists blocking corrections.",
            "Attach critic notes and source URLs.",
            [reportPath])
        add("DECISION: Attorney questions and next-step checklist -- \(objective)", .decision, "captain",
            "Turn the research into questions for a licensed attorney/housing counselor and a non-advice next-step checklist.",
            "The final output avoids legal advice, names deadlines/risks, and identifies evidence to gather.",
            "Legal memo contains Questions for Attorney and Research Gaps sections.",
            [reportPath])

        if !ready {
            let blockerText = Self.blockers(objective: objective,
                                            jurisdiction: jurisdiction,
                                            jurisdictionConfidence: jurisdictionConfidence,
                                            sources: sources)
                .joined(separator: "; ")
            add("REVIEW: Resolve legal research blockers -- \(objective)", .review, "captain",
                "Blockers: \(blockerText)",
                "All blockers are resolved or explicitly scoped before final legal conclusions.",
                "/legal-research shows readyForResearch true.",
                [reportPath])
        }
        if trajectory.contains(where: { !$0.success }) {
            add("REVIEW: Account for failed tool evidence -- \(objective)", .review, "legal-citation-critic",
                "The triggering turn had failed tool actions; include the failure in the research/recovery record.",
                "Failed tools are resolved, scoped out, or turned into blockers.",
                "/logs and legal research evidence name the recovery path.",
                [reportPath])
        }

        _ = assignments
        if activeBefore == nil, let firstAddedID {
            _ = store.update(id: firstAddedID, status: .inProgress)
        }
        return count
    }

    private func seedKnowledgeDebt(objective: String,
                                   jurisdiction: String?,
                                   documentType: String,
                                   sources: [LegalResearchSource],
                                   blockers: [String]) -> Int {
        let store = OrganizationalLearningStore(projectRoot: projectRoot, now: now)
        var count = 0
        if jurisdiction == nil {
            _ = store.addKnowledgeDebt(topic: "Legal jurisdiction for: \(objective)",
                                       reason: "Legal research cannot make jurisdiction-specific conclusions until venue/state/country is known.",
                                       visit: "Ask user; inspect document caption/address; court/agency records when authorized.",
                                       impact: 5,
                                       priority: .high,
                                       estimatedLearning: "5-15 minutes",
                                       expectedBenefit: ["prevent wrong-jurisdiction legal conclusions"])
            count += 1
        }
        _ = store.addKnowledgeDebt(topic: "Official legal sources for \(documentType): \(objective)",
                                   reason: "Legal workflow requires source-backed research, not model memory.",
                                   visit: "Official statutes, court rules, agency guidance, government/legal-aid resources, and primary materials.",
                                   impact: 5,
                                   priority: .high,
                                   estimatedLearning: "1-3 hours",
                                   expectedBenefit: ["produce a citation-backed memo", "surface deadlines and risk"])
        count += 1
        if sources.contains(where: { !$0.hasExtractedText }) {
            _ = store.addKnowledgeDebt(topic: "Extract/OCR legal document text for: \(objective)",
                                       reason: "At least one legal document could not be fully extracted locally.",
                                       visit: "Convert to text/searchable PDF or use vision/OCR, then rerun /legal-research.",
                                       impact: 4,
                                       priority: .high,
                                       estimatedLearning: "15-30 minutes",
                                       expectedBenefit: ["ground research in actual document facts"])
            count += 1
        }
        if !blockers.isEmpty && blockers.allSatisfy({ !$0.lowercased().contains("jurisdiction") }) {
            _ = store.addKnowledgeDebt(topic: "Legal research blockers for: \(objective)",
                                       reason: blockers.joined(separator: "; "),
                                       visit: "Resolve blockers in the legal research dossier before final memo.",
                                       impact: 4,
                                       priority: .high,
                                       estimatedLearning: "30-60 minutes",
                                       expectedBenefit: ["avoid premature legal conclusions"])
            count += 1
        }
        return count
    }

    private func recordMemory(objective: String,
                              jurisdiction: String?,
                              documentType: String,
                              reportPath: String,
                              ready: Bool,
                              blockers: [String]) -> Int {
        let record = DiskMemoryRecord(
            id: "AA-legal-research-\(Self.slug(objective).prefix(48))",
            title: "Legal Research: \(objective)",
            summary: "\(jurisdiction ?? "unknown jurisdiction") · \(documentType) · \(ready ? "ready" : "blocked")",
            body: [
                "Objective: \(objective)",
                "Jurisdiction: \(jurisdiction ?? "unknown")",
                "Document type: \(documentType)",
                "Blockers: \(blockers.joined(separator: "; "))",
                "Report: \(reportPath)"
            ].joined(separator: "\n"),
            source: reportPath,
            confidence: ready ? 72 : 55,
            impact: 5,
            tags: ["legal-research", "regulated-domain", "citation-required", "captain"]
        )
        return Self.appendJSON(record, to: projectRoot + "/.kist/learning/knowledge-index.jsonl") ? 1 : 0
    }

    private func renderReport(objective: String,
                              jurisdiction: String?,
                              jurisdictionConfidence: Int,
                              jurisdictionEvidence: String,
                              documentType: String,
                              sources: [LegalResearchSource],
                              assignments: [LegalResearchAssignment],
                              researchGoal: String,
                              reportPath: String,
                              blockers: [String],
                              dispatchCommand: String) -> String {
        var lines = [
            "# Legal Research Dossier",
            "",
            "Research support only. This is not legal advice and is not a substitute for a licensed attorney.",
            "",
            "Report: \(reportPath)",
            "",
            "## Objective",
            objective,
            "",
            "## Jurisdiction",
            jurisdiction ?? "UNKNOWN - ask user before jurisdiction-specific conclusions.",
            "Confidence: \(jurisdictionConfidence)%",
            "Evidence: \(jurisdictionEvidence)",
            "",
            "## Document Type",
            documentType,
            "",
            "## Privacy Note",
            "Legal documents can contain sensitive information. Kist stores only a bounded local research dossier and sends the research brief to the configured model/research tools when you run the full research handoff.",
            "",
            "## Document Intake",
        ]
        if sources.isEmpty {
            lines.append("No document file was attached. Research will rely on the user's stated facts until a document is provided.")
        } else {
            for source in sources {
                lines += [
                    "- \(source.displayPath)",
                    "  Type: \(source.kind.rawValue) · bytes: \(source.byteCount)",
                    "  Extraction: \(source.extractionNote)",
                ]
                if source.hasExtractedText {
                    lines += [
                        "  Extracted text preview:",
                        Self.indent(Self.excerpt(source.extractedText, limit: 1_500), by: "  ")
                    ]
                }
            }
        }
        lines += [
            "",
            "## Research Plan",
            "1. Confirm jurisdiction, venue, court/agency, parties, dates, and deadlines.",
            "2. Extract document facts separately from assumptions.",
            "3. Search official sources first: statutes, regulations, court rules/forms, agency guidance, and government/legal-aid resources.",
            "4. Research case-specific programs, remedies, procedural deadlines, and evidence requirements.",
            "5. Draft a memo with citations, risk/deadline warnings, attorney questions, and research gaps.",
            "6. Run independent citation/jurisdiction critique before relying on the memo.",
            "",
            "## Required Output",
            "- Issue Summary",
            "- Facts From Document",
            "- Applicable Law / Programs / Rules",
            "- Risks and Deadlines",
            "- Evidence Needed",
            "- Questions for Attorney / Counselor",
            "- Possible Non-Advice Next Steps",
            "- Sources Cited",
            "- Research Gaps",
            "",
            "## Legal Specialist Assignments",
        ]
        for assignment in assignments {
            lines += [
                "- \(assignment.specialistName)",
                "  Role: \(assignment.role)",
                "  Preferred model: \(assignment.preferredModel)"
            ]
        }
        lines += [
            "",
            "## Blockers",
        ]
        lines += blockers.isEmpty ? ["None. Ready for evidence-first research."] : blockers.map { "- \($0)" }
        lines += [
            "",
            "## Research Handoff",
            "Run: \(dispatchCommand)",
            "",
            "Research goal:",
            "```text",
            researchGoal,
            "```"
        ]
        return lines.joined(separator: "\n")
    }

    static func researchGoal(objective: String,
                             jurisdiction: String?,
                             documentType: String,
                             sources: [LegalResearchSource],
                             extractedText: String) -> String {
        var lines = [
            "FULL LEGAL RESEARCH REQUEST",
            "",
            "Important: provide legal research support only, not legal advice. Recommend licensed attorney review before action.",
            "",
            "Objective: \(objective)",
            "Jurisdiction: \(jurisdiction ?? "UNKNOWN - ask user before jurisdiction-specific legal conclusions")",
            "Document type: \(documentType)",
            "",
            "Source hierarchy:",
            "1. Official statutes/regulations/court rules/forms/agency guidance.",
            "2. Government and legal-aid resources.",
            "3. Primary material and authoritative secondary sources.",
            "4. Blogs/marketing pages only as context, never as authority.",
            "",
            "Required memo sections: Issue Summary; Facts From Document; Applicable Law/Programs/Rules; Risks and Deadlines; Evidence Needed; Questions for Attorney/Counselor; Possible Non-Advice Next Steps; Sources Cited; Research Gaps.",
        ]
        if !sources.isEmpty {
            lines += ["", "Documents:"]
            lines += sources.map { "- \($0.displayPath): \($0.kind.rawValue), \($0.extractionNote)" }
        }
        let excerptText = excerpt(extractedText, limit: 6_000)
        if !excerptText.isEmpty {
            lines += ["", "Extracted document text preview:", excerptText]
        } else if sources.contains(where: { !$0.hasExtractedText }) {
            lines += ["", "Document text was not fully extracted. First research task: ask for searchable text/OCR or use a vision-capable document intake step before legal conclusions."]
        }
        return lines.joined(separator: "\n")
    }

    private static let legalDocumentExtensions: Set<String> = [
        "pdf", "txt", "md", "markdown", "rtf", "html", "htm", "doc", "docx"
    ]

    private static let states: [(String, String)] = [
        ("Alabama", "AL"), ("Alaska", "AK"), ("Arizona", "AZ"), ("Arkansas", "AR"),
        ("California", "CA"), ("Colorado", "CO"), ("Connecticut", "CT"), ("Delaware", "DE"),
        ("Florida", "FL"), ("Georgia", "GA"), ("Hawaii", "HI"), ("Idaho", "ID"),
        ("Illinois", "IL"), ("Indiana", "IN"), ("Iowa", "IA"), ("Kansas", "KS"),
        ("Kentucky", "KY"), ("Louisiana", "LA"), ("Maine", "ME"), ("Maryland", "MD"),
        ("Massachusetts", "MA"), ("Michigan", "MI"), ("Minnesota", "MN"), ("Mississippi", "MS"),
        ("Missouri", "MO"), ("Montana", "MT"), ("Nebraska", "NE"), ("Nevada", "NV"),
        ("New Hampshire", "NH"), ("New Jersey", "NJ"), ("New Mexico", "NM"), ("New York", "NY"),
        ("North Carolina", "NC"), ("North Dakota", "ND"), ("Ohio", "OH"), ("Oklahoma", "OK"),
        ("Oregon", "OR"), ("Pennsylvania", "PA"), ("Rhode Island", "RI"), ("South Carolina", "SC"),
        ("South Dakota", "SD"), ("Tennessee", "TN"), ("Texas", "TX"), ("Utah", "UT"),
        ("Vermont", "VT"), ("Virginia", "VA"), ("Washington", "WA"), ("West Virginia", "WV"),
        ("Wisconsin", "WI"), ("Wyoming", "WY"), ("District of Columbia", "DC")
    ]

    private static func stripCommandPrefixes(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "run ", "full legal research", "legal research", "legal-research",
            "legal memo", "law research", "case-research", "case research",
            "research this case", "research this document"
        ]
        var changed = true
        while changed {
            changed = false
            let lower = text.lowercased()
            for prefix in prefixes where lower.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return text
    }

    private static func stripExternalConsentMarkers(_ raw: String) -> String {
        var text = raw
        let markers = [
            "--send-docs", "--allow-external", "--external-ok",
            "external ok", "send document to model", "send documents to model",
            "share document with model", "share documents with model",
            "i consent to send", "i consent"
        ]
        for marker in markers {
            text = text.replacingOccurrences(of: marker, with: "", options: [.caseInsensitive])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func objective(from cleaned: String, sources: [LegalResearchSource]) -> String {
        let text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return safe(text) }
        if let source = sources.first {
            return "Research legal issues in \(source.displayPath)"
        }
        return "Full legal research on the provided legal question"
    }

    private static func detectJurisdiction(in raw: String) -> LegalJurisdictionDetection {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .missing }
        if let explicit = firstRegexGroup(#"(?i)\b(?:jurisdiction|venue|state)\s*:\s*([A-Za-z .-]{2,50})"#, in: text) {
            let clean = explicit.trimmingCharacters(in: CharacterSet(charactersIn: " .,-;\n\t"))
            if let known = knownJurisdiction(in: clean, allowAbbreviations: true, requireContext: false) {
                return LegalJurisdictionDetection(jurisdiction: known,
                                                  confidence: 96,
                                                  evidence: "explicit jurisdiction/venue/state field")
            }
            let stopped = clean.components(separatedBy: " on ").first?
                .components(separatedBy: " for ").first?
                .components(separatedBy: " about ").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,-;\n\t"))
            if let stopped = stopped?.legalNilIfEmpty {
                return LegalJurisdictionDetection(jurisdiction: stopped,
                                                  confidence: 78,
                                                  evidence: "explicit jurisdiction/venue/state field with unrecognized value")
            }
        }
        if let known = knownJurisdiction(in: text, allowAbbreviations: false, requireContext: true) {
            return LegalJurisdictionDetection(jurisdiction: known,
                                              confidence: 82,
                                              evidence: "state name appeared in legal/location context")
        }
        if let known = contextualAbbreviationJurisdiction(in: text) {
            return LegalJurisdictionDetection(jurisdiction: known,
                                              confidence: 84,
                                              evidence: "state abbreviation appeared in address/court context")
        }
        if looksFederalJurisdiction(text) {
            return LegalJurisdictionDetection(jurisdiction: "United States federal",
                                              confidence: 86,
                                              evidence: "federal court/statute/source context")
        }
        return .missing
    }

    private static func knownJurisdiction(in text: String,
                                          allowAbbreviations: Bool,
                                          requireContext: Bool) -> String? {
        let lower = text.lowercased()
        for (name, abbr) in states {
            if containsStateName(name, in: text, lower: lower, requireContext: requireContext) { return name }
            if allowAbbreviations && containsUppercaseWord(abbr, in: text) { return name }
        }
        return nil
    }

    private static func containsStateName(_ name: String, in text: String,
                                          lower: String, requireContext: Bool) -> Bool {
        let state = name.lowercased()
        guard lower.contains(state) else { return false }
        guard requireContext else { return true }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let contextPatterns = [
            #"(?i)\b(?:jurisdiction|venue|state|forum|court|county|resident|resides|lives|located|property|address|city)\b.{0,80}\b"# + escaped + #"\b"#,
            #"(?i)\b"# + escaped + #"\b.{0,80}\b(?:jurisdiction|venue|state|forum|court|county|resident|resides|lives|located|property|address)\b"#,
            #"(?i),\s*"# + escaped + #"\b"#,
            #"(?i)\bstate\s+of\s+"# + escaped + #"\b"#,
            #"(?i)\b"# + escaped + #"\s+(?:superior|supreme|district|trial|probate|family|housing)\s+court\b"#
        ]
        return contextPatterns.contains { regexMatches($0, in: text) }
    }

    private static func contextualAbbreviationJurisdiction(in text: String) -> String? {
        for (name, abbr) in states {
            let escaped = NSRegularExpression.escapedPattern(for: abbr)
            let patterns = [
                #"(?<![A-Za-z])"# + escaped + #"(?![A-Za-z])\s+\d{5}(?:-\d{4})?"#,
                #",\s*"# + escaped + #"(?![A-Za-z])(?:\s+\d{5}(?:-\d{4})?)?"#,
                #"(?<![A-Za-z])"# + escaped + #"(?![A-Za-z]).{0,40}\b(?:superior|supreme|district|trial|probate|family|housing)\s+court\b"#,
                #"\b(?:jurisdiction|venue|state|court|county)\b.{0,30}(?<![A-Za-z])"# + escaped + #"(?![A-Za-z])"#
            ]
            if patterns.contains(where: { regexMatches($0, in: text) }) { return name }
        }
        return nil
    }

    private static func looksFederalJurisdiction(_ text: String) -> Bool {
        let patterns = [
            #"(?i)\bunited\s+states\s+(?:district|bankruptcy|tax|supreme|federal)\s+court\b"#,
            #"(?i)\bfederal\s+(?:court|district|statute|regulation|agency|claim|rule)\b"#,
            #"(?i)\b\d+\s+U\.?S\.?C\.?\b"#,
            #"(?i)\bC\.?F\.?R\.?\b"#
        ]
        return patterns.contains { regexMatches($0, in: text) }
    }

    private static func detectDocumentType(in raw: String) -> String {
        let lower = raw.lowercased()
        let pairs = [
            ("mortgage/HELOC hardship or foreclosure prevention", ["heloc", "mortgage", "foreclosure", "loan modification", "forbearance"]),
            ("lease or landlord-tenant document", ["lease", "landlord", "tenant", "eviction", "rent"]),
            ("contract or agreement", ["contract", "agreement", "clause", "breach"]),
            ("court case or litigation document", ["court", "plaintiff", "defendant", "complaint", "motion", "summons"]),
            ("employment/legal workplace document", ["employment", "termination", "discrimination", "wage"]),
            ("intellectual property document", ["patent", "trademark", "copyright", "license"])
        ]
        for (label, needles) in pairs where needles.contains(where: { lower.contains($0) }) {
            return label
        }
        return "general legal document or legal question"
    }

    private static func blockers(objective: String,
                                 jurisdiction: String?,
                                 jurisdictionConfidence: Int,
                                 sources: [LegalResearchSource]) -> [String] {
        var out: [String] = []
        if jurisdiction == nil {
            out.append("missing jurisdiction/venue; legal conclusions must stay general until confirmed")
        } else if jurisdictionConfidence < 75 {
            out.append("low-confidence jurisdiction detection; confirm venue before jurisdiction-specific conclusions")
        }
        if sources.contains(where: { !$0.hasExtractedText }) {
            out.append("one or more documents need OCR/searchable text before document-specific conclusions")
        }
        return unique(out)
    }

    private static func extractPDFText(_ path: String) -> (text: String, note: String) {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            return ("", "PDF text extraction failed; OCR/vision needed")
        }
        let pageLimit = 40
        let inspectedPages = min(doc.pageCount, pageLimit)
        var pages: [String] = []
        for idx in 0..<inspectedPages {
            if let text = doc.page(at: idx)?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(text)
            }
        }
        let joined = safe(pages.joined(separator: "\n\n"))
        if joined.isEmpty {
            return ("", "PDF contained no extractable text; OCR/vision needed")
        }
        let clipped = excerptInfo(joined, limit: 12_000)
        var notes = ["PDF text extracted locally"]
        if doc.pageCount > inspectedPages {
            notes.append("first \(inspectedPages) of \(doc.pageCount) pages only")
        }
        if clipped.truncated {
            notes.append("truncated to 12000 characters")
        }
        return (clipped.text, notes.joined(separator: "; "))
        #else
        return ("", "PDF text extraction is unavailable on this platform; OCR/vision needed")
        #endif
    }

    private static func firstRegexGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func regexMatches(_ pattern: String, in text: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern))
            .flatMap { $0.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) } != nil
    }

    private static func containsUppercaseWord(_ word: String, in text: String) -> Bool {
        let pattern = #"(?<![A-Za-z])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![A-Za-z])"#
        return (try? NSRegularExpression(pattern: pattern))
            .flatMap { $0.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) } != nil
    }

    private static func appendJSON<T: Encodable>(_ value: T, to path: String) -> Bool {
        do {
            try withFileLock(path: path) {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(value)
                if !FileManager.default.fileExists(atPath: path) {
                    FileManager.default.createFile(atPath: path, contents: nil,
                                                   attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                try handle.seekToEnd()
                var line = data
                line.append(0x0a)
                try handle.write(contentsOf: line)
            }
            return true
        } catch {
            return false
        }
    }

    private static func withFileLock(path: String, _ body: () throws -> Void) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        #endif
        try body()
    }

    private struct DiskMemoryRecord: Codable, Equatable, Sendable {
        var id: String?
        var title: String?
        var summary: String?
        var body: String?
        var source: String?
        var confidence: Int?
        var impact: Int?
        var tags: [String]?
    }

    private static func projectRelative(_ path: String, root: String) -> String {
        let cleanRoot = (ToolContext.canonicalize(root) ?? root).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanPath = ToolContext.canonicalize(path) ?? path
        let rootPrefix = "/" + cleanRoot + "/"
        if cleanPath.hasPrefix(rootPrefix) {
            return String(cleanPath.dropFirst(rootPrefix.count))
        }
        return cleanPath
    }

    private static func indent(_ text: String, by prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }

    private static func excerpt(_ text: String, limit: Int) -> String {
        excerptInfo(text, limit: limit).text
    }

    private static func excerptInfo(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return (clean, false) }
        return (String(clean.prefix(limit)) + "\n[truncated]", true)
    }

    private static func safe(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func slug(_ raw: String) -> String {
        let slug = raw.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((slug.legalNilIfEmpty ?? "legal-research").prefix(60))
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let key = value.lowercased()
            if seen.insert(key).inserted { out.append(value) }
        }
        return out
    }
}

private extension String {
    var legalNilIfEmpty: String? { isEmpty ? nil : self }
}
