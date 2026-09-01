import Foundation
import AgentCore

struct VerifiedHeavyRouteContext: Equatable, Sendable {
    let substantiveSummary: String
    let artifactReferences: [String]
}

/// The small result boundary between the existing REPL and its long-running execution routes.
///
/// Heavy routes used to return `Void`, which forced replay to record a synthetic hand-off with an
/// unknown result.  Keep execution in the existing runners; this value only carries the facts the
/// runner already knows back to the REPL so one turn can be finalized honestly.
struct HeavyRouteResult: Equatable, Sendable {
    enum Review: Equatable, Sendable {
        case notApplicable(String)
        case handledInternally(String)

        var proofText: String {
            switch self {
            case .notApplicable(let detail):
                return "not applicable — \(detail)"
            case .handledInternally(let detail):
                return "handled internally — \(detail)"
            }
        }
    }

    enum Verification: Equatable, Sendable {
        case passed(String)
        case failed(String)
        case unavailable(String)

        var proofSuccess: Bool? {
            switch self {
            case .passed: return true
            case .failed: return false
            case .unavailable: return nil
            }
        }

        var proofText: String {
            switch self {
            case .passed(let detail):
                return "passed — \(detail)"
            case .failed(let detail):
                return "failed — \(detail)"
            case .unavailable(let detail):
                return "unavailable — \(detail)"
            }
        }
    }

    let exitCode: Int32
    let interruption: InterruptibleTurn.InterruptReason?
    let review: Review
    let verification: Verification
    let substantiveSummary: String?
    let artifactReferences: [String]

    init(exitCode: Int32,
         interruption: InterruptibleTurn.InterruptReason?,
         review: Review,
         verification: Verification,
         substantiveSummary: String? = nil,
         artifactReferences: [String] = []) {
        self.exitCode = exitCode
        self.interruption = interruption
        self.review = review
        self.verification = verification
        let summary = substantiveSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.substantiveSummary = summary?.isEmpty == false
            ? String(summary!.prefix(4_000)) : nil
        self.artifactReferences = Array(Set(artifactReferences.compactMap { reference in
            let clean = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : String(clean.prefix(1_000))
        })).sorted().prefix(8).map { $0 }
    }

    var succeeded: Bool { interruption == nil && exitCode == 0 }

    func satisfiesExpectedOutcome(intent: TaskBrief.Intent,
                                  mode: PromptCompiler.Mode) -> Bool {
        let expected = PromptCompiler.expectedOutcome(intent: intent, mode: mode)
        let verificationSatisfied = expected == .mutation
            ? verification.proofSuccess == true
            : verification.proofSuccess != false
        return succeeded && verificationSatisfied
    }

    var finalText: String {
        if let interruption {
            let reason = interruption == .cancel ? "cancelled" : "interrupted"
            return "\(reason) — heavy route stopped before completion"
        }
        return exitCode == 0
            ? "completed — heavy route exited 0"
            : "failed — heavy route exited \(exitCode)"
    }

    /// Bounded context carried into the next conversational turn. Substantive model output stays
    /// advisory; typed proof remains exclusively in `HeavyRouteProof` below.
    var transcriptSummary: String {
        var parts = ["\(finalText); verification \(verification.proofText)"]
        if let substantiveSummary {
            parts.append("Substantive result (advisory):\n\(substantiveSummary)")
        }
        if !artifactReferences.isEmpty {
            parts.append("Host-verified artifact references:\n"
                + artifactReferences.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Accept only regular files that currently resolve inside the active project and bind each path
    /// to its observed SHA-256. A later worker can detect drift instead of trusting path existence.
    static func verifiedArtifactReferences(_ paths: [String], projectRoot: String) -> [String] {
        Array(Set(paths.compactMap { path -> String? in
            guard let file = verifiedRegularFile(path, projectRoot: projectRoot),
                  let digest = try? MythosCrypto.sha256File(path: file.path) else { return nil }
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return "\(file.path) [sha256:\(hex)]"
        })).sorted().prefix(8).map { $0 }
    }

    /// Recheck stored path/digest receipts immediately before a later worker consumes them. The file
    /// may have changed since the producing turn; an old receipt must never be relabeled current.
    static func revalidatedArtifactReferences(
        _ references: [String],
        projectRoot: String
    ) -> [String] {
        references.compactMap { reference in
            guard reference.hasSuffix("]"),
                  let marker = reference.range(of: " [sha256:", options: .backwards) else {
                return nil
            }
            let path = String(reference[..<marker.lowerBound])
            let digestStart = marker.upperBound
            let digestEnd = reference.index(before: reference.endIndex)
            let expected = String(reference[digestStart..<digestEnd]).lowercased()
            guard expected.count == 64,
                  expected.unicodeScalars.allSatisfy({
                    CharacterSet(charactersIn: "0123456789abcdef").contains($0)
                  }),
                  let file = verifiedRegularFile(path, projectRoot: projectRoot),
                  let digest = try? MythosCrypto.sha256File(path: file.path) else { return nil }
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            return actual == expected ? "\(file.path) [sha256:\(actual)]" : nil
        }
    }

    /// Validate that a council handoff still names the exact artifact written for the typed result.
    /// A path that merely exists is insufficient: replacement, escape, symlink, and directory cases
    /// all fail closed before model prose is retained as future conversational context.
    static func verifiedCouncilContext(
        _ capture: KistRunner.CouncilPipelineCapture?,
        projectRoot: String
    ) -> VerifiedHeavyRouteContext? {
        guard let capture,
              let file = verifiedRegularFile(capture.artifactPath, projectRoot: projectRoot),
              file.data == Data(capture.result.markdown.utf8) else { return nil }
        let summary = capture.result.finalPlan
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        let references = verifiedArtifactReferences(
            [capture.artifactPath], projectRoot: projectRoot)
        guard references.count == 1 else { return nil }
        return VerifiedHeavyRouteContext(
            substantiveSummary: summary, artifactReferences: references)
    }

    /// Validate the typed research lineage against its synthesized manifest and report. This keeps a
    /// stale or replaced report from silently becoming the referent for a later "build off it" turn.
    static func verifiedResearchContext(
        _ capture: KistRunner.ResearchPipelineCapture?,
        projectRoot: String
    ) -> VerifiedHeavyRouteContext? {
        guard let capture,
              let runID = try? ResearchRunStore.validRunID(capture.runID) else { return nil }
        let expectedBase = ".kist/research-runs/\(runID)"
        let expectedManifest = expectedBase + "/manifest.json"
        let expectedEvidence = expectedBase + "/evidence.jsonl"
        let expectedReport = expectedBase + "/report.md"
        guard capture.manifestPath == expectedManifest,
              capture.evidencePath == expectedEvidence,
              capture.reportPath == expectedReport,
              let manifestFile = verifiedRegularFile(expectedManifest, projectRoot: projectRoot),
              let evidenceFile = verifiedRegularFile(expectedEvidence, projectRoot: projectRoot),
              let reportFile = verifiedRegularFile(expectedReport, projectRoot: projectRoot),
              !evidenceFile.data.isEmpty,
              KistRunner.ResearchPipelineCapture.sha256Hex(evidenceFile.data)
                == capture.evidenceDigest,
              let manifest = try? JSONDecoder().decode(
                ResearchRunManifest.self, from: manifestFile.data),
              let canonicalRoot = ToolContext.canonicalize(projectRoot),
              manifest.runID == runID,
              manifest.projectRoot == canonicalRoot,
              // A nested council records progress in the same research manifest after synthesis.
              // Both states retain the exact reportPath/digest lineage checked below.
              ["synthesized", "council"].contains(manifest.status),
              manifest.reportPath == expectedReport else { return nil }
        let report = String(decoding: reportFile.data, as: UTF8.self)
        guard PEELEvidenceReceipt.contentDigest(report) == capture.dossierDigest,
              report == capture.dossier else { return nil }
        let references = verifiedArtifactReferences(
            [expectedManifest, expectedEvidence, expectedReport], projectRoot: projectRoot)
        guard references.count == 3 else { return nil }
        return VerifiedHeavyRouteContext(
            substantiveSummary: report.trimmingCharacters(in: .whitespacesAndNewlines),
            artifactReferences: references)
    }

    private static func verifiedRegularFile(
        _ path: String,
        projectRoot: String
    ) -> (path: String, data: Data)? {
        guard let root = ToolContext.canonicalize(projectRoot) else { return nil }
        let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let candidate = clean.hasPrefix("/") ? clean : root + "/" + clean
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let resolved = ToolContext.canonicalize(candidate) else { return nil }
        let rootPrefix = root == "/" ? "/" : root + "/"
        guard resolved == root || resolved.hasPrefix(rootPrefix),
              let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)) else { return nil }
        return (resolved, data)
    }
}

/// Typed proof entries for a heavy route. Splitting the pre-execution route fact from the three
/// post-execution facts preserves event order while making the one-of-each invariant testable.
enum HeavyRouteProof {
    static func routeEntry(intent: TaskBrief.Intent,
                           mode: PromptCompiler.Mode,
                           execution: String) -> TurnProofStore.Entry {
        let expected = PromptCompiler.expectedOutcome(intent: intent, mode: mode)
        return .init(kind: .routeSelected, tool: nil, success: nil,
                     text: "intent=\(intent.rawValue) outcome=\(expected.rawValue) execution=\(execution)")
    }

    static func completionEntries(result: HeavyRouteResult,
                                  intent: TaskBrief.Intent,
                                  mode: PromptCompiler.Mode,
                                  execution: String) -> [TurnProofStore.Entry] {
        let expected = PromptCompiler.expectedOutcome(intent: intent, mode: mode)
        // A mutation route cannot be finalized successful when its deterministic oracle was unavailable.
        // Advisory answer/evidence/plan routes may complete without an execution oracle, but a promised
        // state change needs an explicit passing verification fact.
        let finalSuccess = result.satisfiesExpectedOutcome(intent: intent, mode: mode)
        return [
            .init(kind: .reviewAssessment, tool: nil, success: nil,
                  text: result.review.proofText),
            .init(kind: .verificationAssessment, tool: nil,
                  success: result.verification.proofSuccess,
                  text: result.verification.proofText),
            .init(kind: .turnFinalized, tool: nil, success: finalSuccess,
                  text: "intent=\(intent.rawValue) expected=\(expected.rawValue) execution=\(execution) result=\(finalSuccess ? "completed" : "failed") route_status=\(result.finalText)"),
        ]
    }
}
