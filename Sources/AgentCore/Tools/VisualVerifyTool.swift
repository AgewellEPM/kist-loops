import Foundation

/// Visual verification loop primitive: capture a browser/app state (or accept an existing screenshot),
/// compare it with a reference screenshot and/or textual goal through a vision model, then persist a
/// durable local artifact under `.kist/visual-runs/<id>/`.
///
/// This deliberately does NOT patch code itself. The trusted loop is:
/// visual_verify -> edit_file/write_file -> test/run app -> visual_verify again. The replay ledger records
/// each tool call, while the visual run directory keeps the screenshots and model report.
public struct VisualVerifyTool: AgentTool {
    static let maxAttempts = 100

    public let name = "visual_verify"
    public let description = """
    Run a visual verification pass: capture a browser URL screenshot or compare an existing candidate \
    image, ask a vision model to diff it against a reference image and/or goal, and save the evidence \
    under .kist/visual-runs/<run_id>. Use this for UI/app/browser loops: capture -> visual diff -> patch \
    -> retest -> replay.
    """
    public let parameters = [
        ToolParameter(name: "goal", type: "string", description: "What the UI/app/browser state should satisfy.", required: true),
        ToolParameter(name: "reference", type: "string", description: "Optional project-relative reference screenshot/mockup.", required: false),
        ToolParameter(name: "candidate", type: "string", description: "Optional project-relative candidate screenshot. If omitted, provide url.", required: false),
        ToolParameter(name: "url", type: "string", description: "Optional http(s) URL to launch in the headless browser and screenshot.", required: false),
        ToolParameter(name: "actions", type: "array", description: "Optional browser steps before screenshot: click/fill/wait/press.", required: false),
        ToolParameter(name: "run_id", type: "string", description: "Optional stable visual loop id for retests.", required: false),
        ToolParameter(name: "threshold", type: "integer", description: "Pass threshold score 0-100, default 90.", required: false),
    ]

    public var capabilityNote: String? {
        "Use visual_verify after building UI/app changes. If it fails, patch the mismatches and rerun with the same run_id."
    }
    public var usageExamples: [String] {
        [
            "visual_verify(goal=\"match the settings screen\", reference=\"spec/settings.png\", url=\"http://127.0.0.1:5173/settings\", run_id=\"settings-ui\")",
            "visual_verify(goal=\"check after patch\", reference=\"spec/home.png\", candidate=\".kist/visual-runs/home/attempt-01.png\", run_id=\"home\")",
        ]
    }

    private let inlineCap: Int
    private let analyze: @Sendable (_ attachments: [MediaAttachment], _ prompt: String) async throws -> String
    private let captureBrowser: @Sendable (_ url: String, _ actions: [BrowserAction], _ screenshotPath: String, _ context: ToolContext) async throws -> ToolResult

    public init(registry: ProviderRegistry, binding: ProviderBinding,
                allowedHosts: [String] = [], inlineCap: Int = 12 * 1024 * 1024) {
        self.inlineCap = inlineCap
        self.analyze = { attachments, prompt in
            try await registry.complete(providerId: binding.providerId, model: binding.model,
                                        messages: [
                                            ChatMessage(role: .system, content: Self.systemPrompt),
                                            ChatMessage(role: .user, content: prompt, attachments: attachments),
                                        ],
                                        settings: ModelSettings(temperature: 0.0, maxTokens: 1800))
        }
        let browser = BrowserTool(allowedHosts: allowedHosts, allowLocalhost: true)
        self.captureBrowser = { url, actions, screenshotPath, context in
            var all = actions
            all.append(.screenshot(path: screenshotPath))
            // Re-enter the shared gate (scope + audit) for the composite's browser sub-action.
            return await ToolGate.run(name: browser.name, arguments: [
                "url": url, "actions": all.map { $0.json }, "extract": "text",
            ], context: context) {
                try await browser.execute(arguments: [
                    "url": url, "actions": all.map { $0.json }, "extract": "text",
                ], context: context)
            }
        }
    }

    public init(inlineCap: Int = 12 * 1024 * 1024,
                analyze: @escaping @Sendable (_ attachments: [MediaAttachment], _ prompt: String) async throws -> String,
                captureBrowser: @escaping @Sendable (_ url: String, _ actions: [BrowserAction], _ screenshotPath: String, _ context: ToolContext) async throws -> ToolResult = { _, _, _, _ in
                    .failure("browser capture is not configured")
                }) {
        self.inlineCap = inlineCap
        self.analyze = analyze
        self.captureBrowser = captureBrowser
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let goal = try requireString("goal", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return .failure("goal cannot be empty") }
        let threshold = min(max(optionalInt("threshold", from: arguments) ?? 90, 0), 100)
        let runID = try Self.validRunID((arguments["run_id"] as? String), fallback: Self.makeRunID())
        let runDir = ".kist/visual-runs/\(runID)"
        let confined = try context.confinedRoot()
        try confined.makeDirectory(runDir)
        let attempt = try nextAttempt(in: runDir, confined: confined)

        let referenceAttachment: MediaAttachment?
        let referenceArtifact: String?
        if let reference = (arguments["reference"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reference.isEmpty {
            let loaded = try loadImage(reference, label: "reference", confined: confined)
            let artifact = "\(runDir)/reference.\(loaded.ext)"
            try write(data: loaded.data, to: artifact, confined: confined)
            referenceAttachment = loaded.attachment(sourcePath: artifact)
            referenceArtifact = artifact
        } else {
            referenceAttachment = nil
            referenceArtifact = nil
        }

        let candidateArtifact: String
        var browserSummary: String? = nil
        if let url = (arguments["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty {
            candidateArtifact = "\(runDir)/attempt-\(Self.attemptLabel(attempt)).png"
            let actions = (arguments["actions"] as? [[String: Any]] ?? []).compactMap(BrowserAction.parse)
            let browser = try await captureBrowser(url, actions, candidateArtifact, context)
            guard browser.success else {
                return .failure("browser capture failed: \(browser.error ?? browser.output)")
            }
            browserSummary = browser.output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let candidate = (arguments["candidate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty {
            let loaded = try loadImage(candidate, label: "candidate", confined: confined)
            candidateArtifact = "\(runDir)/attempt-\(Self.attemptLabel(attempt)).\(loaded.ext)"
            try write(data: loaded.data, to: candidateArtifact, confined: confined)
        } else {
            return .failure("provide either candidate (existing screenshot) or url (browser capture)")
        }

        let candidateLoaded = try loadImage(candidateArtifact, label: "candidate", confined: confined)
        let attachments = ([referenceAttachment].compactMap { $0 } + [candidateLoaded.attachment(sourcePath: candidateArtifact)])
        let prompt = Self.prompt(goal: goal, threshold: threshold,
                                 hasReference: referenceAttachment != nil,
                                 browserSummary: browserSummary)
        let report = try await analyze(attachments, prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        let score = Self.parseScore(report)
        let passed = Self.isPassing(report: report, score: score, threshold: threshold)
        let reportPath = "\(runDir)/attempt-\(Self.attemptLabel(attempt))-report.md"
        try confined.writeString(reportPath, Self.markdown(goal: goal, threshold: threshold, passed: passed,
                                                           score: score, reference: referenceArtifact,
                                                           candidate: candidateArtifact, report: report),
                                 createParents: true)
        let manifest = Manifest(runID: runID, attempt: attempt, goal: goal, reference: referenceArtifact,
                                candidate: candidateArtifact, report: reportPath,
                                threshold: threshold, passed: passed, score: score,
                                capturedAt: Date().timeIntervalSince1970)
        try confined.writeString("\(runDir)/latest.json", Self.json(manifest), createParents: true)

        let verdict = passed ? "PASS" : "FAIL"
        var lines = [
            "Visual verify \(verdict) · run \(runID) · attempt \(attempt)" + (score.map { " · score \($0)/100" } ?? ""),
            "Goal: \(goal)",
            "Candidate: \(candidateArtifact)",
            "Report: \(reportPath)",
        ]
        if let referenceArtifact { lines.insert("Reference: \(referenceArtifact)", at: 2) }
        lines += [
            "",
            "Loop:",
            passed
                ? "1. Visual target is accepted. Keep this report as replay evidence."
                : "1. Patch the mismatches with edit_file/write_file.",
            passed
                ? "2. If code changed afterward, rerun visual_verify with run_id=\(runID)."
                : "2. Rebuild/reload the app or browser target.",
            passed
                ? "3. Cite \(reportPath) in the final proof."
                : "3. Rerun visual_verify with run_id=\(runID) until it passes or the residual diff is accepted.",
            "",
            report,
        ]
        return ToolResult(success: passed,
                          output: lines.joined(separator: "\n"),
                          error: passed ? nil : "visual verification failed",
                          metadata: [
                            "run_id": runID,
                            "attempt": String(attempt),
                            "candidate": candidateArtifact,
                            "report": reportPath,
                            "passed": String(passed),
                          ])
    }

    private struct LoadedImage {
        let data: Data
        let mime: String
        let ext: String
        func attachment(sourcePath: String) -> MediaAttachment {
            MediaAttachment(kind: .image, mimeType: mime, payload: .inline(data), sourcePath: sourcePath)
        }
    }

    private struct Manifest: Codable, Equatable {
        let runID: String
        let attempt: Int
        let goal: String
        let reference: String?
        let candidate: String
        let report: String
        let threshold: Int
        let passed: Bool
        let score: Int?
        let capturedAt: Double
    }

    private func loadImage(_ path: String, label: String, confined: ConfinedRoot) throws -> LoadedImage {
        let ext = (path as NSString).pathExtension.lowercased()
        guard let (kind, mime) = MediaAttachment.kindAndMime(forExtension: ext), kind == .image else {
            throw ToolError.execution("\(label) must be an image file: \(path)")
        }
        let data = try confined.readData(path)
        guard data.count <= inlineCap else {
            throw ToolError.execution("\(label) image is over \(inlineCap) bytes: \(path)")
        }
        return LoadedImage(data: data, mime: mime, ext: ext.isEmpty ? "png" : ext)
    }

    private func write(data: Data, to relPath: String, confined: ConfinedRoot) throws {
        try confined.writeData(relPath, data, createParents: true)
    }

    private func nextAttempt(in runDir: String, confined: ConfinedRoot) throws -> Int {
        let entries = (try? confined.entries(runDir)) ?? []
        let attempts = entries.compactMap { entry -> Int? in
            guard entry.name.hasPrefix("attempt-") else { return nil }
            let suffix = entry.name.dropFirst("attempt-".count)
            let digits = suffix.prefix { $0.wholeNumberValue != nil }
            guard !digits.isEmpty else { return nil }
            return Int(digits)
        }
        let next = (attempts.max() ?? 0) + 1
        guard next <= Self.maxAttempts else {
            throw ToolError.execution("visual_verify run \(runDir) reached max attempt count \(Self.maxAttempts)")
        }
        return next
    }

    static let systemPrompt = """
    You are a strict visual QA judge. Compare only the visible evidence. Do not claim a pass unless the \
    candidate satisfies the stated goal. Be specific enough that a coder can patch the UI and rerun.
    """

    static func prompt(goal: String, threshold: Int, hasReference: Bool, browserSummary: String?) -> String {
        var lines = [
            "VISUAL VERIFICATION",
            "Goal: \(goal)",
            hasReference
                ? "Attachments: first image is the reference; final image is the candidate."
                : "Attachments: final image is the candidate. Judge it against the textual goal.",
            "Pass threshold: \(threshold)/100.",
            "",
            "Return exactly these sections:",
            "Verdict: PASS or FAIL",
            "Score: 0-100",
            "Matches:",
            "- visible things that are correct",
            "Mismatches:",
            "- concrete visual differences, missing UI, layout defects, broken states, or accessibility problems",
            "Patch guidance:",
            "- actionable UI/code changes to try next",
            "Retest:",
            "- what to capture/check on the next loop",
        ]
        if let browserSummary, !browserSummary.isEmpty {
            lines += ["", "Browser text summary from capture:", String(browserSummary.prefix(1_500))]
        }
        return lines.joined(separator: "\n")
    }

    static func parseScore(_ report: String) -> Int? {
        let patterns = [
            #"(?im)^\s*score\s*[:=-]\s*(\d{1,3})"#,
            #"(?im)\b(\d{1,3})\s*/\s*100\b"#,
            #"(?im)\b(\d{1,3})\s*%\b"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = report as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let match = re.firstMatch(in: report, range: range), match.numberOfRanges > 1 {
                let value = ns.substring(with: match.range(at: 1))
                if let n = Int(value) { return min(max(n, 0), 100) }
            }
        }
        return nil
    }

    static func isPassing(report: String, score: Int?, threshold: Int) -> Bool {
        let lower = report.lowercased()
        let explicitFail = lower.range(of: #"(?m)^\s*verdict\s*[:=-]\s*fail\b"#, options: .regularExpression) != nil
        if explicitFail { return false }
        if let score { return score >= threshold }
        return lower.range(of: #"(?m)^\s*verdict\s*[:=-]\s*pass\b"#, options: .regularExpression) != nil
    }

    private static func markdown(goal: String, threshold: Int, passed: Bool, score: Int?,
                                 reference: String?, candidate: String, report: String) -> String {
        var lines = [
            "# Visual Verification",
            "",
            "- Goal: \(goal)",
            "- Verdict: \(passed ? "PASS" : "FAIL")",
            "- Score: \(score.map(String.init) ?? "unknown") / 100",
            "- Threshold: \(threshold)",
        ]
        if let reference { lines.append("- Reference: \(reference)") }
        lines += [
            "- Candidate: \(candidate)",
            "",
            "## Vision Report",
            "",
            report,
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func json(_ manifest: Manifest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(manifest)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func validRunID(_ raw: String?, fallback: String) throws -> String {
        let value = (raw ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(value.count) else {
            throw ToolError.execution("run_id must be 1-80 characters")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ToolError.execution("run_id may contain only letters, numbers, underscore, and dash")
        }
        return value
    }

    private static func makeRunID() -> String {
        let ts = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
        return "visual-\(ts)-\(suffix)"
    }

    private static func attemptLabel(_ n: Int) -> String {
        String(format: "%02d", n)
    }
}
