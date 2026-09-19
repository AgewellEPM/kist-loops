import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct CaptainFailureHypothesis: Codable, Equatable, Sendable {
    var rank: Int
    var title: String
    var confidence: Int
    var reason: String
    var inspect: [String]
}

struct CaptainFailureCapsule: Codable, Equatable, Sendable {
    enum Layer: String, Codable, Equatable, Sendable {
        case mediaAttachmentSerialization = "media-attachment-serialization"
        case providerRequestSerialization = "provider-request-serialization"
        case documentExport = "document-export"
        case toolRuntime = "tool-runtime"
        case sandboxAuthorization = "sandbox-authorization"
        case schemaRefusal = "schema-refusal"
        case authorization = "authorization"
        case toolchain = "toolchain"
        case infrastructure = "infrastructure"
        case codeOrTest = "code-or-test"
        case uncertainMutation = "uncertain-mutation"
        case staleVerification = "stale-verification"
        case plannerExecution = "planner-execution"
        case providerRequestBudget = "provider-request-budget"
        case unknown = "unknown"
    }

    var id: String
    var objective: String
    var observed: String
    var likelyLayer: Layer
    var confidence: Int
    var evidence: [String]
    var hypotheses: [CaptainFailureHypothesis]
    var researchTasks: [String]
    var repairPlan: [String]
    var verificationPlan: [String]
    var teachCandidate: String
    var reportPath: String
    var createdAt: Double
}

struct CaptainFailureRepairVerification: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case verified
        case incomplete
        case failed
    }

    var capsuleID: String
    var status: Status
    var evidence: [String]
    var structuredEvidence: [VerificationEvidence]?
    var missingVerification: [String]
    var notes: String
    var createdAt: Double
}

struct VerificationEvidence: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Equatable, Sendable {
        case pass
        case fail
        case unknown
    }

    var command: String
    var outcome: Outcome
    var rawLine: String
    var timestamp: Date?
}

struct CaptainFailureAnalysisReport: Equatable, Sendable {
    var capsule: CaptainFailureCapsule
    var text: String
    var path: String
    var seededTasks: Int
    var writeSucceeded: Bool
    var writeError: String?
}

struct CaptainFailureAnalysis: Sendable {
    let projectRoot: String
    private let now: @Sendable () -> Date

    init(projectRoot: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.projectRoot = ToolContext.canonicalize(projectRoot) ?? projectRoot
        self.now = now
    }

    var failuresRoot: String { projectRoot + "/.kist/learning/failures" }
    var capsuleLedgerPath: String { projectRoot + "/.kist/learning/failure-capsules.jsonl" }
    var verificationLedgerPath: String { projectRoot + "/.kist/learning/failure-repair-verifications.jsonl" }

    @discardableResult
    func analyze(goal rawGoal: String,
                 summary rawSummary: String,
                 trajectory: [ActionRecord],
                 proofEntries: [TurnProofStore.Entry] = [],
                 seedTasks: Bool = true) -> CaptainFailureAnalysisReport {
        let created = now()
        let goal = Self.safe(rawGoal).nilIfBlank ?? "unknown objective"
        let summary = Self.safe(rawSummary).nilIfBlank ?? "failure with no summary"
        let classification = classify(summary: summary, trajectory: trajectory, proofEntries: proofEntries)
        let id = failureID(for: classification.observed, at: created)
        let reportPath = ".kist/learning/failures/\(id).md"
        let capsule = CaptainFailureCapsule(id: id,
                                            objective: goal,
                                            observed: classification.observed,
                                            likelyLayer: classification.layer,
                                            confidence: classification.confidence,
                                            evidence: classification.evidence,
                                            hypotheses: classification.hypotheses,
                                            researchTasks: classification.researchTasks,
                                            repairPlan: classification.repairPlan,
                                            verificationPlan: classification.verificationPlan,
                                            teachCandidate: classification.teachCandidate,
                                            reportPath: reportPath,
                                            createdAt: created.timeIntervalSince1970)
        let text = render(capsule)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: failuresRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: (capsuleLedgerPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: projectRoot + "/" + reportPath, atomically: true, encoding: .utf8)
            try appendCapsule(capsule)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
        }
        let seeded = writeSucceeded && seedTasks ? seedDiagnosisTasks(for: capsule) : 0
        return CaptainFailureAnalysisReport(capsule: capsule,
                                            text: text,
                                            path: reportPath,
                                            seededTasks: seeded,
                                            writeSucceeded: writeSucceeded,
                                            writeError: writeError)
    }

    static func latest(projectRoot rawRoot: String) -> CaptainFailureCapsule? {
        let root = ToolContext.canonicalize(rawRoot) ?? rawRoot
        let path = root + "/.kist/learning/failure-capsules.jsonl"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return text.split(separator: "\n")
            .compactMap { try? decoder.decode(CaptainFailureCapsule.self, from: Data($0.utf8)) }
            .max { $0.createdAt < $1.createdAt }
    }

    static func capsule(projectRoot rawRoot: String, id: String) -> CaptainFailureCapsule? {
        let root = ToolContext.canonicalize(rawRoot) ?? rawRoot
        let path = root + "/.kist/learning/failure-capsules.jsonl"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return text.split(separator: "\n")
            .compactMap { try? decoder.decode(CaptainFailureCapsule.self, from: Data($0.utf8)) }
            .last { $0.id == id }
    }

    static func latestRepairVerification(projectRoot rawRoot: String,
                                         capsuleID: String) -> CaptainFailureRepairVerification? {
        let root = ToolContext.canonicalize(rawRoot) ?? rawRoot
        let path = root + "/.kist/learning/failure-repair-verifications.jsonl"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return text.split(separator: "\n")
            .compactMap { try? decoder.decode(CaptainFailureRepairVerification.self, from: Data($0.utf8)) }
            .filter { $0.capsuleID == capsuleID }
            .max { $0.createdAt < $1.createdAt }
    }

    static func renderLatest(projectRoot: String) -> String {
        guard let capsule = latest(projectRoot: projectRoot) else {
            return "No failure capsules yet. The next failed turn will write .kist/learning/failures/<id>.md."
        }
        var lines = [
            "Captain Failure Analysis",
            "Failure ID: \(capsule.id)",
            "Observed: \(capsule.observed)",
            "Likely layer: \(capsule.likelyLayer.rawValue)",
            "Confidence: \(capsule.confidence)%",
            "Report: \(capsule.reportPath)",
            "",
            "Top hypotheses:",
        ]
        lines += capsule.hypotheses.prefix(3).map {
            "\($0.rank). \($0.title) (\($0.confidence)%)"
        }
        lines += [
            "",
            "Repair plan:",
        ]
        lines += capsule.repairPlan.prefix(5).map { "- \($0)" }
        lines += [
            "",
            "Verification:",
        ]
        lines += capsule.verificationPlan.prefix(5).map { "- \($0)" }
        lines += [
            "",
            "Teach candidate:",
            capsule.teachCandidate
        ]
        if let verification = latestRepairVerification(projectRoot: projectRoot, capsuleID: capsule.id) {
            lines += [
                "",
                "Repair status: \(verification.status.rawValue)",
                "Repair evidence:",
            ]
            lines += verification.evidence.prefix(5).map { "- \($0)" }
            if !verification.missingVerification.isEmpty {
                lines += ["", "Missing verification:"]
                lines += verification.missingVerification.prefix(5).map { "- \($0)" }
            }
            lines += ["", "Repair notes:", verification.notes]
        } else {
            lines += [
                "",
                "Repair status: open",
                "Run /failures verify <evidence> after the repair and tests complete."
            ]
        }
        return lines.joined(separator: "\n")
    }

    static func handleCommand(_ rawArgs: String, projectRoot: String) -> String {
        let args = rawArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard args.lowercased().hasPrefix("verify") else {
            return renderLatest(projectRoot: projectRoot)
        }
        let body = String(args.dropFirst("verify".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return "usage: /failures verify [failure-id --] <test/review evidence>"
        }
        let parsed = parseVerifyBody(body)
        do {
            let verification = try CaptainFailureAnalysis(projectRoot: projectRoot)
                .recordRepairVerification(capsuleID: parsed.capsuleID, evidenceText: parsed.evidenceText)
            return renderRepairVerification(verification)
        } catch {
            return "failure repair verification failed: \(error)"
        }
    }

    @discardableResult
    func recordRepairVerification(capsuleID rawID: String? = nil,
                                  evidenceText: String) throws -> CaptainFailureRepairVerification {
        let verification = try makeRepairVerification(capsuleID: rawID,
                                                      evidenceText: evidenceText,
                                                      structuredEvidence: Self.extractStructuredEvidence(from: evidenceText))
        try appendVerification(verification)
        return verification
    }

    @discardableResult
    func recordRepairVerification(capsuleID rawID: String? = nil,
                                  evidence: [VerificationEvidence]) throws -> CaptainFailureRepairVerification {
        let verification = try makeRepairVerification(capsuleID: rawID, evidence: evidence)
        try appendVerification(verification)
        return verification
    }

    @discardableResult
    func recordRepairVerificationIfChanged(capsuleID rawID: String? = nil,
                                           evidenceText: String) throws -> CaptainFailureRepairVerification? {
        let verification = try makeRepairVerification(capsuleID: rawID,
                                                      evidenceText: evidenceText,
                                                      structuredEvidence: Self.extractStructuredEvidence(from: evidenceText))
        return try appendVerificationIfChanged(verification)
    }

    @discardableResult
    func recordRepairVerificationIfChanged(capsuleID rawID: String? = nil,
                                           evidence: [VerificationEvidence]) throws -> CaptainFailureRepairVerification? {
        let verification = try makeRepairVerification(capsuleID: rawID, evidence: evidence)
        return try appendVerificationIfChanged(verification)
    }

    private func appendVerificationIfChanged(_ verification: CaptainFailureRepairVerification) throws -> CaptainFailureRepairVerification? {
        if let previous = Self.latestRepairVerification(projectRoot: projectRoot,
                                                        capsuleID: verification.capsuleID),
           previous.status == verification.status,
           previous.missingVerification == verification.missingVerification,
           previous.evidence == verification.evidence,
           previous.structuredEvidence == verification.structuredEvidence {
            return nil
        }
        try appendVerification(verification)
        return verification
    }

    private func makeRepairVerification(capsuleID rawID: String?,
                                        evidence: [VerificationEvidence]) throws -> CaptainFailureRepairVerification {
        try makeRepairVerification(capsuleID: rawID,
                                   evidenceLines: Self.evidenceLines(from: evidence),
                                   structuredEvidence: evidence)
    }

    private func makeRepairVerification(capsuleID rawID: String?,
                                        evidenceText: String,
                                        structuredEvidence: [VerificationEvidence]) throws -> CaptainFailureRepairVerification {
        try makeRepairVerification(capsuleID: rawID,
                                   evidenceLines: Self.evidenceLines(from: evidenceText),
                                   structuredEvidence: structuredEvidence)
    }

    private func makeRepairVerification(capsuleID rawID: String?,
                                        evidenceLines evidence: [String],
                                        structuredEvidence: [VerificationEvidence]) throws -> CaptainFailureRepairVerification {
        guard let capsule = rawID.flatMap({ Self.capsule(projectRoot: projectRoot, id: $0) })
                ?? Self.latest(projectRoot: projectRoot) else {
            throw NSError(domain: "CaptainFailureAnalysis", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no failure capsule found"])
        }
        guard !evidence.isEmpty else {
            throw NSError(domain: "CaptainFailureAnalysis", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "verification evidence is empty"])
        }
        let missing = Self.missingVerification(for: capsule, evidence: evidence)
        let explicitlyFailed = Self.hasUnresolvedFailureEvidence(structuredEvidence)
            || (structuredEvidence.isEmpty && evidence.contains { line in
                Self.lineHasFailedStatusMarker(line.lowercased())
            })
        let status: CaptainFailureRepairVerification.Status = explicitlyFailed
            ? .failed
            : (missing.isEmpty ? .verified : .incomplete)
        let notes: String
        switch status {
        case .verified:
            notes = "All verification plan items were matched by repair evidence."
        case .incomplete:
            notes = "Repair evidence exists, but not every verification plan item is proven yet."
        case .failed:
            notes = "Repair verification was explicitly marked failed; keep the failure capsule open."
        }
        return CaptainFailureRepairVerification(capsuleID: capsule.id,
                                                status: status,
                                                evidence: evidence,
                                                structuredEvidence: structuredEvidence.isEmpty ? nil : structuredEvidence,
                                                missingVerification: missing,
                                                notes: notes,
                                                createdAt: now().timeIntervalSince1970)
    }

    private static func parseVerifyBody(_ body: String) -> (capsuleID: String?, evidenceText: String) {
        let marker = " -- "
        if let range = body.range(of: marker) {
            let possibleID = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let evidence = String(body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if possibleID.hasPrefix("failure-") || possibleID.hasPrefix("fail-") {
                return (possibleID, evidence)
            }
        }
        return (nil, body)
    }

    private static func evidenceLines(from text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func evidenceLines(from evidence: [VerificationEvidence]) -> [String] {
        evidence
            .map { $0.rawLine.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func extractVerificationEvidence(from rawText: String) -> String {
        evidenceText(from: extractStructuredEvidence(from: rawText))
    }

    static func extractStructuredEvidence(from rawText: String,
                                          timestamp: Date? = nil) -> [VerificationEvidence] {
        evidenceLines(from: rawText)
            .compactMap { structuredEvidence(from: $0, timestamp: timestamp) }
    }

    private static func structuredEvidence(from line: String,
                                           timestamp: Date?) -> VerificationEvidence? {
        let lower = line.lowercased()
        guard isVerificationEvidenceLine(lower) else { return nil }
        return VerificationEvidence(command: verificationCommand(from: line),
                                    outcome: verificationOutcome(from: lower),
                                    rawLine: line,
                                    timestamp: timestamp)
    }

    private static func isVerificationEvidenceLine(_ lower: String) -> Bool {
        if lower.hasPrefix("verify:") || lower.hasPrefix("verification:") {
            return true
        }
        if lower.contains("swift test") || lower.contains("git diff --check") {
            return lineHasPositiveVerificationSignal(lower) || lineHasNegativeVerificationSignal(lower)
        }
        return lower.contains("executed")
            && (lower.contains("all tests") || lower.contains("full suite"))
            && lineHasPositiveVerificationSignal(lower)
    }

    private static func verificationOutcome(from lower: String) -> VerificationEvidence.Outcome {
        if lower.contains("=> fail")
            || lower.contains("status: failed")
            || lower.contains("status=failed")
            || lineHasNegativeVerificationSignal(lower) {
            return .fail
        }
        if lower.contains("=> pass") || lineHasPositiveVerificationSignal(lower) {
            return .pass
        }
        return .unknown
    }

    private static func verificationCommand(from line: String) -> String {
        let lower = line.lowercased()
        if lower.contains("full suite"), lower.contains("executed") {
            return "swift test"
        }
        if lower.contains("git diff --check") {
            return "git diff --check"
        }
        if let range = lower.range(of: "swift test") {
            return trimmedCommand(from: String(line[range.lowerBound...]))
        }
        let stripped = stripVerificationPrefix(line)
        if let range = stripped.range(of: "=>") {
            return String(stripped[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripVerificationPrefix(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in ["verify:", "verification:"] where lower.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func trimmedCommand(from tail: String) -> String {
        let lowerTail = tail.lowercased()
        let markers = [
            " =>",
            " passed",
            " failed",
            " succeeded",
            " success",
            " clean",
            " with ",
            " executed",
            ",",
            ";"
        ]
        let cut = markers.compactMap { marker -> String.Index? in
            lowerTail.range(of: marker)?.lowerBound
        }.min()
        let command = cut.map { String(tail[..<$0]) } ?? tail
        return command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func evidenceText(from evidence: [VerificationEvidence]) -> String {
        evidence.map(\.rawLine).joined(separator: "\n")
    }

    private static func hasUnresolvedFailureEvidence(_ evidence: [VerificationEvidence]) -> Bool {
        var latestEvidenceByCommand: [String: VerificationEvidence] = [:]
        for item in evidence {
            let command = item.command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !command.isEmpty else { continue }
            latestEvidenceByCommand[command] = item
        }
        return latestEvidenceByCommand.values.contains { item in
            item.outcome == .fail
                && lineHasExplicitFailedVerificationStatus(item.rawLine.lowercased())
        }
    }

    private static func lineHasExplicitFailedVerificationStatus(_ line: String) -> Bool {
        line.contains("=> fail")
            || lineHasFailedStatusMarker(line)
    }

    private static func lineHasFailedStatusMarker(_ line: String) -> Bool {
        line.contains("status: failed")
            || line.contains("status=failed")
    }

    private static func missingVerification(for capsule: CaptainFailureCapsule,
                                            evidence: [String]) -> [String] {
        return capsule.verificationPlan.filter { item in
            !verificationItemIsSatisfied(item, evidence: evidence)
        }
    }

    private static func verificationItemIsSatisfied(_ item: String, evidence: [String]) -> Bool {
        let lowerLines = evidence.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let lower = item.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "swift test" {
            return lowerLines.contains { line in
                lineSatisfiesFullSwiftTest(line)
            }
        }
        let needles = verificationNeedles(for: lower)
        let commandLike = lower.hasPrefix("swift test") || lower.contains("git diff --check")
        return lowerLines.contains { line in
            guard needles.allSatisfy({ line.contains($0) }) else { return false }
            guard !lineHasNegativeVerificationSignal(line) else { return false }
            return commandLike ? lineHasPositiveVerificationSignal(line) : true
        }
    }

    private static func verificationNeedles(for lowerItem: String) -> [String] {
        let lower = lowerItem.trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("swift test --filter") {
            let filter = lower.components(separatedBy: "--filter").dropFirst().joined(separator: "--filter")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return filter.isEmpty ? ["swift test"] : ["swift test", filter]
        }
        if lower.contains("git diff --check") { return ["git diff --check"] }
        return [lower]
    }

    private static func lineSatisfiesFullSwiftTest(_ line: String) -> Bool {
        guard !lineHasNegativeVerificationSignal(line) else { return false }
        if line.contains("full suite") && lineHasPositiveVerificationSignal(line) { return true }
        if line.contains("swift test") && !line.contains("--filter") && lineHasPositiveVerificationSignal(line) {
            return true
        }
        return line.contains("executed")
            && (line.contains("all tests") || line.contains("full suite"))
            && lineHasPositiveVerificationSignal(line)
    }

    private static func lineHasPositiveVerificationSignal(_ line: String) -> Bool {
        if line.contains("0 failures") || line.contains("0 failure") || line.contains("no failures") {
            return true
        }
        return [
            "passed",
            "success",
            "succeeded",
            "clean",
            "exit 0",
            "exit code 0"
        ].contains { line.contains($0) }
    }

    private static func lineHasNegativeVerificationSignal(_ line: String) -> Bool {
        if line.contains("0 failures") || line.contains("0 failure") || line.contains("no failures") {
            return false
        }
        if [
            "did not run",
            "not run",
            "not executed",
            "could not run",
            "unable to run",
            "error:",
            "exit 1",
            "nonzero",
            "blocked"
        ].contains(where: { line.contains($0) }) {
            return true
        }
        return line.range(of: #"(?<![a-z])failed(?![a-z])"#, options: .regularExpression) != nil
            || line.range(of: #"(?<![a-z])failures?(?![a-z])"#, options: .regularExpression) != nil
    }

    private static func renderRepairVerification(_ verification: CaptainFailureRepairVerification) -> String {
        var lines = [
            "Captain Repair Verification",
            "Failure ID: \(verification.capsuleID)",
            "Status: \(verification.status.rawValue)",
            "",
            "Evidence:",
        ]
        lines += verification.evidence.map { "- \($0)" }
        if let evidence = verification.structuredEvidence, !evidence.isEmpty {
            lines += [
                "",
                "Evidence summary:",
                renderVerificationEvidenceSummary(evidence)
            ]
        }
        if !verification.missingVerification.isEmpty {
            lines += ["", "Missing verification:"]
            lines += verification.missingVerification.map { "- \($0)" }
        }
        lines += ["", "Notes:", verification.notes]
        return lines.joined(separator: "\n")
    }

    static func renderVerificationEvidenceSummary(_ evidence: [VerificationEvidence],
                                                  limit: Int = 6) -> String {
        let rendered = evidence.prefix(max(0, limit)).map { item in
            let marker: String
            switch item.outcome {
            case .pass:
                marker = "pass"
            case .fail:
                marker = "fail"
            case .unknown:
                marker = "unknown"
            }
            let command = item.command.nilIfBlank ?? item.rawLine.singleLineCapped(80)
            return "\(marker): \(command)"
        }
        guard !rendered.isEmpty else { return "none" }
        let remaining = evidence.count - rendered.count
        if remaining > 0 {
            return (rendered + ["+\(remaining) more"]).joined(separator: " · ")
        }
        return rendered.joined(separator: " · ")
    }

    private struct Classification {
        var layer: CaptainFailureCapsule.Layer
        var confidence: Int
        var observed: String
        var evidence: [String]
        var hypotheses: [CaptainFailureHypothesis]
        var researchTasks: [String]
        var repairPlan: [String]
        var verificationPlan: [String]
        var teachCandidate: String
    }

    private func classify(summary: String,
                          trajectory: [ActionRecord],
                          proofEntries: [TurnProofStore.Entry]) -> Classification {
        let proofFailures = proofEntries.compactMap { entry -> String? in
            if entry.kind == .failed { return entry.text }
            if entry.kind == .actionFinished, entry.success == false { return entry.text }
            return nil
        }
        let lower = ([summary] + proofFailures).joined(separator: "\n").lowercased()
        let failedTools = trajectory.filter { !$0.success }
        let typedVerdict = FailureClassifier.classify(FailureSignals.from(trajectory))
        var evidence = [
            "summary: \(summary.singleLineCapped(220))",
            "trajectory: \(trajectory.count) tool step(s), \(failedTools.count) failed",
        ]
        evidence += proofFailures.prefix(4).map { "proof failure: \($0.singleLineCapped(220))" }

        if lower.contains("image_url") || (lower.contains("unknown variant") && lower.contains("expected") && lower.contains("text")) {
            return Classification(
                layer: .mediaAttachmentSerialization,
                confidence: 92,
                observed: "Provider rejected image payload in a text-only request history.",
                evidence: evidence + [
                    "failure mentions image_url/text variant mismatch",
                    "this usually means prior media stayed attached when routing to a text-only model"
                ],
                hypotheses: [
                    .init(rank: 1, title: "Stale media attachment leaked into text-only provider body", confidence: 92,
                          reason: "A text-only OpenAI-compatible provider rejected image_url content.",
                          inspect: ["OpenAICompatibleProvider request body", "media transcript history", "vision routing fallback"]),
                    .init(rank: 2, title: "Prompt compiler reused a multimodal message after the media turn", confidence: 63,
                          reason: "The failure appears on a follow-up request after an image/document workflow.",
                          inspect: ["REPL human transcript", "message compaction", "attachment cleanup"]),
                    .init(rank: 3, title: "Provider catalog incorrectly advertised vision", confidence: 40,
                          reason: "If the model was marked vision-capable incorrectly, request building would choose image parts.",
                          inspect: ["model capabilities", "provider health", "catalog defaults"])
                ],
                researchTasks: [
                    "Compare how OpenAI-compatible text-only providers expect user content to be serialized.",
                    "Inspect the last successful media workflow and the next failed text-only turn.",
                    "Review provider request builders for capability-gated media inclusion."
                ],
                repairPlan: [
                    "Gate image_url serialization on the selected model's vision capability.",
                    "Replace media attachments with a redacted attachment summary for text-only providers.",
                    "Add regression tests for a media turn followed by a text-only PDF/doc request."
                ],
                verificationPlan: [
                    "swift test --filter ProviderVisionEncodingTests",
                    "swift test --filter DocumentExportTests",
                    "swift test"
                ],
                teachCandidate: "A provider failure that mentions image_url on a text-only model must trigger media-history serialization diagnosis before retrying.")
        }

        if lower.contains("document export failed")
            || lower.contains("pdf export is not available")
            || lower.contains("could not create pdf writer")
            || lower.contains("could not create pdf context")
            || lower.contains("no prior assistant answer to export") {
            return Classification(
                layer: .documentExport,
                confidence: 88,
                observed: "Document export failed before producing the requested file.",
                evidence: evidence + [
                    "failure happened in the direct document-export path",
                    "this path runs before normal model/media routing"
                ],
                hypotheses: [
                    .init(rank: 1, title: "Document export writer failed or platform PDF backend was unavailable", confidence: 88,
                          reason: "The failure text came from DocumentExport before provider/tool execution.",
                          inspect: ["DocumentExport.writeLatestAssistantDocument", "PDF writer availability", ".kist/exports permissions"]),
                    .init(rank: 2, title: "The export request had no prior assistant document to serialize", confidence: 62,
                          reason: "Direct export depends on the latest assistant answer in the local transcript.",
                          inspect: ["human transcript", "latest assistant message", "DocumentExport.latestAssistantText"]),
                    .init(rank: 3, title: "The export intent collided with debugging or media-routing text", confidence: 45,
                          reason: "PDF/debug wording can look like both an export request and a repair request.",
                          inspect: ["DocumentExport.parseIntent", "REPL command ordering", "media resolver ordering"])
                ],
                researchTasks: [
                    "Inspect the exact document-export error and the latest assistant transcript.",
                    "Compare the failed request against DocumentExport intent parsing and output writer requirements.",
                    "Check whether .kist/exports is writable inside the active project sandbox."
                ],
                repairPlan: [
                    "Patch DocumentExport or REPL ordering at the smallest failing layer.",
                    "Add a regression for the failed PDF/doc request wording.",
                    "Ensure document-export failures open a Captain failure capsule and self-heal mission."
                ],
                verificationPlan: [
                    "swift test --filter DocumentExportTests",
                    "swift test --filter CaptainFailureAnalysisTests",
                    "swift test --filter KistREPLTests"
                ],
                teachCandidate: "Document export failures are first-class system failures; Captain must diagnose the export path and preserve the user request instead of returning a generic malformed error.")
        }

        if let typed = typedClassification(verdict: typedVerdict, evidence: evidence) {
            return typed
        }

        // Provider-request-budget exhaustion. The loop's own terminal signal is
        // "provider request limit reached (consumed/limit)" (HeadlessAgentLoop.finishFailed /
        // finishProviderRequestBudgetFailure). It is a deterministic budget/convergence condition —
        // NOT a telemetry gap — so it must never fall through to the "unknown" bucket that spawns
        // endless "improve telemetry" missions. Gated on `failedTools.isEmpty`: if a tool failed, the
        // tool failure is the actionable root cause and owns the classification (see below); the
        // budget was likely burned by that failure's retries.
        if failedTools.isEmpty, lower.contains("provider request limit reached") {
            let counts = Self.parseProviderRequestCounts(from: [summary] + proofFailures)
            let ratio = counts.map { "\($0.consumed)/\($0.limit)" } ?? "at the configured ceiling"
            return Classification(
                layer: .providerRequestBudget,
                confidence: 90,
                observed: "Turn exhausted its provider-request budget (\(ratio)) before completing the objective.",
                evidence: evidence + [
                    "provider request ceiling reached: \(ratio)",
                    "no tool failed — the turn was making tool progress but ran out of provider requests, not on an error",
                ],
                hypotheses: [
                    .init(rank: 1, title: "Objective needs more provider requests than the per-turn ceiling allows", confidence: 60,
                          reason: "The loop halted at the hard request ceiling (\(ratio)) rather than on a tool or provider error.",
                          inspect: ["run replay: is progress monotonic per request?", "objective scope vs. maxIterations", "HeadlessAgentLoop maxIterations ceiling"]),
                    .init(rank: 2, title: "Agent looped without converging (repeated work, no new progress)", confidence: 55,
                          reason: "A non-converging agent spends its whole budget re-doing work instead of finishing.",
                          inspect: ["trajectory for repeated / near-duplicate tool calls", "replan events", "no-progress detection"])
                ],
                researchTasks: [
                    "Open the run replay and decide: is this a legitimately large objective, or a non-converging loop?",
                    "Compare provider requests consumed against real progress made per request."
                ],
                repairPlan: [
                    "If the objective is legitimately large, DECOMPOSE it into sub-goals that each fit the request ceiling — do not blindly raise the limit.",
                    "If the agent looped without progress, fix the non-convergence that burned the budget, not the ceiling.",
                    "Raise maxIterations only as a deliberate, evidenced decision after non-convergence is ruled out."
                ],
                verificationPlan: [
                    "Re-run the objective (decomposed, or with a justified higher ceiling) and confirm it completes within budget",
                    "swift test --filter ProviderRequestBudgetTests"
                ],
                teachCandidate: "Provider-request-budget exhaustion is a deterministic budget/convergence signal, not an unknown failure: decompose the objective or fix non-convergence before ever raising the ceiling.")
        }

        let structuredDenial = proofFailures.first(where: {
            let text = $0.lowercased()
            return text.contains("denied by") || text.contains("permission denied")
                || text.contains("not authorized") || text.contains("approval required")
                || text.contains("operation not permitted")
        })
        if let structuredDenial {
            return Classification(
                layer: .sandboxAuthorization,
                confidence: 82,
                observed: "Execution was blocked by sandbox or authorization constraints.",
                evidence: evidence + ["structured denial: \(structuredDenial.singleLineCapped(220))"],
                hypotheses: [
                    .init(rank: 1, title: "Command required OS sandbox but launched without it", confidence: 82,
                          reason: "Failure text names sandbox or permissions.",
                          inspect: ["custom_tool policy", "run_command sandbox flags", "Kist launch mode"]),
                    .init(rank: 2, title: "Generated helper requested a capability outside the current gate", confidence: 68,
                          reason: "Permission failures often come from helper scripts crossing the active scope.",
                          inspect: ["tool authorization scope", "helper manifest", "approval mode"])
                ],
                researchTasks: [
                    "Inspect the failed tool's authorization scope and Kist launch flags.",
                    "Compare intended sandbox policy against the command that was blocked."
                ],
                repairPlan: [
                    "Make the error message name the exact missing launch mode or permission.",
                    "Route self-heal helpers through the sandboxed runner when the command is reversible.",
                    "Add a regression test for blocked helper execution."
                ],
                verificationPlan: ["swift test --filter CustomToolTests", "swift test --filter SeatbeltSandboxTests"],
                teachCandidate: "Sandbox failures are policy evidence; Captain must diagnose the missing gate instead of retrying raw execution.")
        }

        if !failedTools.isEmpty {
            let top = failedTools.first?.tool ?? "tool"
            return Classification(
                layer: .toolRuntime,
                confidence: 76,
                observed: "Tool execution failed during the turn.",
                evidence: evidence + failedTools.prefix(5).map { "failed tool: \($0.tool) \($0.argsFingerprint)" },
                hypotheses: [
                    .init(rank: 1, title: "Tool precondition missing or path target wrong", confidence: 76,
                          reason: "\(top) reported failure in the trajectory.",
                          inspect: ["tool arguments", "project root", "proof log"]),
                    .init(rank: 2, title: "Agent repeated work without reading the failure evidence", confidence: 55,
                          reason: "Tool failures often need a replan before another action.",
                          inspect: ["trajectory analyzer", "replan events", "task board evidence"])
                ],
                researchTasks: [
                    "Read the failed tool output and identify the missing precondition.",
                    "Inspect the surrounding task plan to see whether the tool was appropriate."
                ],
                repairPlan: [
                    "Fix the failed tool precondition or route to the correct tool.",
                    "Add or update a targeted test for the failed tool path.",
                    "Record the recovery path in task evidence."
                ],
                verificationPlan: ["Run the focused test for \(top)", "git diff --check"],
                teachCandidate: "A failed tool call must become evidence for replanning, not a blind retry.")
        }

        if lower.contains("malformed") || lower.contains("bad request") || lower.contains("provider error") || lower.contains("rejected") {
            return Classification(
                layer: .providerRequestSerialization,
                confidence: trajectory.isEmpty ? 83 : 72,
                observed: "Provider rejected the model request before useful execution.",
                evidence: evidence + (trajectory.isEmpty ? ["no tool trajectory was recorded before failure"] : []),
                hypotheses: [
                    .init(rank: 1, title: "Request body or transcript shape violated provider schema", confidence: 83,
                          reason: "The provider rejected the request as malformed/bad-request.",
                          inspect: ["provider request body builder", "last transcript messages", "tool/native mode selection"]),
                    .init(rank: 2, title: "Router selected a model/provider with incompatible capabilities", confidence: 66,
                          reason: "Provider compatibility bugs often surface before a tool step exists.",
                          inspect: ["AutoModelRouter", "model capabilities", "provider health"])
                ],
                researchTasks: [
                    "Read the provider error body and map it to the request builder field.",
                    "Inspect router capability decisions for the selected provider/model.",
                    "Compare the last successful request shape with the failed request shape."
                ],
                repairPlan: [
                    "Patch request serialization or routing capability checks.",
                    "Add a regression test that builds the failed request shape.",
                    "Verify provider health and the focused request-builder tests."
                ],
                verificationPlan: ["swift test --filter Provider", "swift test --filter KistREPLTests"],
                teachCandidate: "Malformed provider requests must open a request-shape investigation before Captain retries.")
        }

        return Classification(
            layer: lower.contains("plan") ? .plannerExecution : .unknown,
            confidence: 50,
            observed: "Turn failed without a classified root-cause signature.",
            evidence: evidence,
            hypotheses: [
                .init(rank: 1, title: "Insufficient failure telemetry", confidence: 50,
                      reason: "The failure did not match a known deterministic signature.",
                      inspect: ["proof log", "trajectory", "run replay", "provider trace"])
            ],
            researchTasks: [
                "Open /logs and the run replay to collect the missing evidence.",
                "Classify the failure layer before implementing a repair."
            ],
            repairPlan: [
                "Improve failure telemetry if the proof log cannot identify the layer.",
                "Create a focused reproduction once the failure signature is known."
            ],
            verificationPlan: ["Reproduce the failure", "Run the focused regression test"],
            teachCandidate: "Unknown failures must first improve telemetry or produce a reproduction; do not patch from vibes.")
    }

    private func typedClassification(verdict: FailureClassifier.Verdict,
                                     evidence: [String]) -> Classification? {
        let commonEvidence = evidence + [
            "typed diagnosis: \(verdict.category.rawValue)",
            "typed receipt evidence: \(verdict.evidence.singleLineCapped(400))",
        ]
        let layer: CaptainFailureCapsule.Layer
        let observed: String
        let repair: [String]
        let verification: [String]
        switch verdict.category {
        case .staleProof:
            layer = .staleVerification
            observed = "A post-verification mutation invalidated earlier deterministic proof."
            repair = [
                "Re-run the exact last passed check named in typed receipt evidence against the latest revision.",
                "Run independent review only after the fresh check passes.",
                "Do not widen capabilities, add allowed exit codes, skip checks, or weaken tests."
            ]
            verification = ["Fresh deterministic check after the invalidating mutation", "Independent review of that exact revision"]
        case .uncertainMutation:
            layer = .uncertainMutation
            observed = "An uncertain mutation effect left the final revision unverified."
            repair = ["Inspect the effect receipt and fail closed.", "Run fresh deterministic verification without widening authority."]
            verification = [
                "Run the focused test for \(verdict.culpritTool ?? "failed tool")",
                "git diff --check",
            ]
        case .authorization:
            layer = .authorization
            observed = "A typed tool receipt recorded an actual authorization denial."
            repair = ["Surface the exact denial reason.", "Do not widen capabilities; preserve authority if the same executable already succeeded."]
            verification = ["Retry only after explicit operator-approved authority changes"]
        case .schemaRefusal:
            layer = .schemaRefusal
            observed = "A typed tool receipt recorded a schema refusal."
            repair = ["Correct the malformed call shape only.", "Do not change permissions or accepted exit codes."]
            verification = ["Replay the corrected call under the unchanged capability envelope"]
        case .toolchain:
            layer = .toolchain
            observed = "The toolchain precondition failed."
            repair = ["Repair the named toolchain precondition and retry once.", "Do not weaken tests or widen capabilities."]
            verification = ["Re-run the same deterministic build/test"]
        case .infrastructure:
            layer = .infrastructure
            observed = "Infrastructure failed independently of application correctness."
            repair = ["Repair the concrete infrastructure condition and use one bounded retry.", "Do not alter test or permission policy."]
            verification = ["Re-run the same deterministic check after infrastructure recovery"]
        case .codeOrTest:
            layer = .codeOrTest
            observed = "A typed command/check receipt recorded an application code or test failure."
            repair = ["Fix the concrete code/test failure.", "Keep assertions and expected-exit policy unchanged."]
            verification = ["Re-run the same build/test and then independent review"]
        case .taskBug, .knowledgeGap, .toolLimit, .blocked:
            return nil
        }
        return Classification(
            layer: layer,
            confidence: Int((verdict.confidence * 100).rounded()),
            observed: observed,
            evidence: commonEvidence,
            hypotheses: [
                .init(rank: 1, title: observed, confidence: Int((verdict.confidence * 100).rounded()),
                      reason: verdict.evidence, inspect: ["typed trajectory receipts", "completion verifier ordering"])
            ],
            researchTasks: ["Inspect the named typed receipts; do not infer authority from summary prose."],
            repairPlan: repair,
            verificationPlan: verification,
            teachCandidate: "Typed tool/effect receipts outrank summary keywords; never heal verification ordering by widening authority or weakening checks.")
    }

    private func seedDiagnosisTasks(for capsule: CaptainFailureCapsule) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        let activeBefore = store.load().active
        var firstID: Int?
        var count = 0
        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String, _ verification: String) {
            guard !taskExists(title: title) else { return }
            let task = store.add(title: title,
                                 detail: detail,
                                 owner: owner,
                                 kind: kind,
                                 acceptance: acceptance,
                                 verification: verification,
                                 evidence: [capsule.reportPath])
            if firstID == nil { firstID = task.id }
            count += 1
        }

        add("PLAN: Diagnose failure \(capsule.id)", .plan, "captain",
            "Observed: \(capsule.observed)\nLikely layer: \(capsule.likelyLayer.rawValue)\nConfidence: \(capsule.confidence)%",
            "Root-cause hypotheses are ranked with evidence and inspection targets.",
            "Open \(capsule.reportPath) and confirm or reject the top hypothesis.")
        add("RESEARCH: Compare failure pattern \(capsule.id)", .research, "failure-analysis-researcher",
            capsule.researchTasks.map { "- \($0)" }.joined(separator: "\n"),
            "Relevant provider/tool/runtime patterns are compared before repair.",
            "Attach notes or source references to this task.")
        add("ACTION: Repair failure \(capsule.id)", .action, "self-heal-builder",
            capsule.repairPlan.map { "- \($0)" }.joined(separator: "\n"),
            "Repair addresses the confirmed root cause and stays scoped to the failing layer.",
            capsule.verificationPlan.first ?? "Run focused regression tests.")
        add("TEST: Verify failure repair \(capsule.id)", .test, "self-heal-critic",
            capsule.verificationPlan.map { "- \($0)" }.joined(separator: "\n"),
            "Focused regression and broad verification pass, or blockers are recorded.",
            capsule.verificationPlan.joined(separator: "; "))
        add("DECISION: Teach Captain failure lesson \(capsule.id)", .decision, "captain",
            capsule.teachCandidate,
            "The lesson is promoted only after root cause, repair, review, and tests are evidenced.",
            "/teach add <lesson> with \(capsule.reportPath) as evidence.")

        if activeBefore == nil, let firstID {
            _ = store.update(id: firstID, status: .inProgress)
        }
        return count
    }

    private func taskExists(title: String) -> Bool {
        PlanStore(projectRoot: projectRoot).load().tasks.contains { existing in
            existing.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(title) == .orderedSame
        }
    }

    private func appendCapsule(_ capsule: CaptainFailureCapsule) throws {
        let data = try JSONEncoder().encode(capsule)
        let line = data + Data("\n".utf8)
        try withFileLock(path: capsuleLedgerPath) {
            try FileManager.default.createDirectory(atPath: (capsuleLedgerPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: capsuleLedgerPath) {
                FileManager.default.createFile(atPath: capsuleLedgerPath, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: capsuleLedgerPath))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }

    private func appendVerification(_ verification: CaptainFailureRepairVerification) throws {
        let data = try JSONEncoder().encode(verification)
        let line = data + Data("\n".utf8)
        try withFileLock(path: verificationLedgerPath) {
            try FileManager.default.createDirectory(atPath: (verificationLedgerPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: verificationLedgerPath) {
                FileManager.default.createFile(atPath: verificationLedgerPath, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: verificationLedgerPath))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }

    private func withFileLock(path: String, _ body: () throws -> Void) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        #endif
        try body()
    }

    private func render(_ capsule: CaptainFailureCapsule) -> String {
        var lines = [
            "# Captain Failure Analysis",
            "",
            "Failure ID: \(capsule.id)",
            "Objective: \(capsule.objective)",
            "Observed: \(capsule.observed)",
            "Likely layer: \(capsule.likelyLayer.rawValue)",
            "Confidence: \(capsule.confidence)%",
            "",
            "## Evidence",
        ]
        lines += capsule.evidence.map { "- \($0)" }
        lines += ["", "## Hypotheses"]
        for hypothesis in capsule.hypotheses {
            lines += [
                "\(hypothesis.rank). \(hypothesis.title)",
                "   Confidence: \(hypothesis.confidence)%",
                "   Reason: \(hypothesis.reason)",
                "   Inspect: \(hypothesis.inspect.joined(separator: ", "))"
            ]
        }
        lines += ["", "## Research Tasks"]
        lines += capsule.researchTasks.map { "- \($0)" }
        lines += ["", "## Repair Plan"]
        lines += capsule.repairPlan.enumerated().map { "\($0.offset + 1). \($0.element)" }
        lines += ["", "## Verification"]
        lines += capsule.verificationPlan.map { "- \($0)" }
        lines += [
            "",
            "## Teach Captain Candidate",
            capsule.teachCandidate,
            "",
            "## Gate",
            "Do not retry blindly. Confirm the root cause, patch the smallest failing layer, verify, then promote or reject the lesson."
        ]
        return lines.joined(separator: "\n")
    }

    private func failureID(for observed: String, at date: Date) -> String {
        let timestamp = Int(date.timeIntervalSince1970)
        let slug = observed
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .nilIfBlank ?? "failure"
        return "failure-\(timestamp)-\(String(slug.prefix(42)))"
    }

    private static func safe(_ text: String) -> String {
        SecretScanner.redactSecrets(in: text)
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Pull `(consumed, limit)` out of the loop's terminal budget signature
    /// "provider request limit reached (consumed/limit)". Returns nil if the phrase carries no
    /// parseable ratio (the caller still classifies as budget, just without the exact numbers).
    private static func parseProviderRequestCounts(from texts: [String]) -> (consumed: Int, limit: Int)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"provider request limit reached \((\d+)/(\d+)\)"#,
            options: [.caseInsensitive]) else {
            return nil
        }
        for text in texts {
            let ns = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges == 3,
                  let consumed = Int(ns.substring(with: match.range(at: 1))),
                  let limit = Int(ns.substring(with: match.range(at: 2))) else {
                continue
            }
            return (consumed, limit)
        }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    func singleLineCapped(_ max: Int) -> String {
        let compact = replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard compact.count > max else { return compact.isEmpty ? "(empty)" : compact }
        return String(compact.prefix(max - 1)) + "..."
    }
}
