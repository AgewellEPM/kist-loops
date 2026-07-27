import Foundation

/// Agent tool: inspect an image/PDF file through a vision-capable provider and return a structured
/// visual report. This is the tool-call counterpart to Kist's user-facing drag/drop and /paste path:
/// the agent can now decide to look at a screenshot, browser capture, mockup, PDF, or visual evidence
/// during a plan instead of only receiving media that the user attached manually.
public struct ViewImageTool: AgentTool {
    public let name = "view_image"
    public let description = """
    Inspect an IMAGE or PDF file using a vision model and return a structured visual report: visible \
    text, UI/layout, notable objects, colors, errors, and task-relevant observations. Use for \
    screenshots, mockups, browser/app captures, visual diffs, PDFs, and "look at this" evidence.
    """
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "Project-relative path to an image/PDF file."),
        ToolParameter(name: "question", type: "string", description: "Optional focused question for the visual inspection.", required: false),
    ]

    private let inlineCap: Int
    private let analyze: @Sendable (MediaAttachment, String) async throws -> String

    public init(registry: ProviderRegistry, binding: ProviderBinding, inlineCap: Int = 12 * 1024 * 1024) {
        self.inlineCap = inlineCap
        self.analyze = { attachment, question in
            let prompt = Self.prompt(question: question, sourcePath: attachment.sourcePath)
            return try await registry.complete(providerId: binding.providerId, model: binding.model,
                                               messages: [
                                                ChatMessage(role: .system, content: "You are a precise visual inspection tool. Report only what is visible or directly inferable from the attached file."),
                                                ChatMessage(role: .user, content: prompt, attachments: [attachment]),
                                               ],
                                               settings: ModelSettings(temperature: 0.0, maxTokens: 1600))
        }
    }

    /// Test initializer: injects a deterministic analyzer, no live provider needed.
    public init(inlineCap: Int = 12 * 1024 * 1024,
                analyze: @escaping @Sendable (MediaAttachment, String) async throws -> String) {
        self.inlineCap = inlineCap
        self.analyze = analyze
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("path", from: arguments)
        let resolved = try context.resolvedPath(path, mustExist: true)
        let ext = (resolved as NSString).pathExtension.lowercased()
        guard let (kind, mime) = MediaAttachment.kindAndMime(forExtension: ext), kind == .image || kind == .pdf else {
            return .failure("view_image handles images/PDFs; '\(path)' is not a recognized image/PDF file")
        }
        let data: Data
        do {
            data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: URL(fileURLWithPath: resolved))
            }.value
        } catch {
            return .failure("couldn't read \(path)")
        }
        guard data.count <= inlineCap else {
            return .failure("view_image refuses inline files over \(inlineCap) bytes; shrink or split '\(path)' first")
        }

        let question = (arguments["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let attachment = MediaAttachment(kind: kind, mimeType: mime, payload: .inline(data), sourcePath: resolved)
        let report = try await analyze(attachment, question)
        let name = (resolved as NSString).lastPathComponent
        return ToolResult(success: true,
                          output: "Visual inspection · \(name)\n\n\(report.trimmingCharacters(in: .whitespacesAndNewlines))",
                          metadata: ["path": path, "mime": mime, "bytes": String(data.count)])
    }

    static func prompt(question: String, sourcePath: String?) -> String {
        var lines = [
            "Inspect the attached visual file\(sourcePath.map { " from \($0)" } ?? "").",
            "Return a concise structured report with:",
            "- visible text/OCR",
            "- UI/layout and important visual elements",
            "- errors, warnings, mismatches, or accessibility issues",
            "- task-relevant observations",
            "- uncertainty if something is unclear",
        ]
        if !question.isEmpty { lines.append("Focus question: \(question)") }
        return lines.joined(separator: "\n")
    }
}
