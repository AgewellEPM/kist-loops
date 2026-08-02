import Foundation

/// Agent tool: translate a DOCUMENT (PDF, image of a doc, or a text file) into another language while
/// preserving its STRUCTURE — headings, lists, tables, emphasis, ordering — and save the result as
/// Markdown or HTML. This is the "drop a document, translate it, keep its styles" flow: structure
/// fidelity via Gemini document understanding (existing key). It does NOT re-render a byte-identical
/// PDF/DOCX (that's Cloud Translation v3, a separate phase) — it outputs faithful Markdown/HTML.
///
/// Small files inline; large PDFs/images go through the Gemini Files API. Confined to the project root.
public struct TranslateDocumentTool: AgentTool {
    public let name = "translate_document"
    public let description = """
    Translate a DOCUMENT into another language, preserving its structure (headings, lists, tables, \
    emphasis), and save it as Markdown or HTML. Accepts PDF, an image of a document, or a text file \
    (.txt/.md/.html/.csv/.json/.xml). Use for "translate this doc and keep its layout/styles".
    """
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "Project-relative path to the document (pdf/image/text). Absolute paths under a session-armed read-only root (--allow-read) also work."),
        ToolParameter(name: "to", type: "string", description: "Target language, e.g. 'Spanish', 'French', 'Japanese'."),
        ToolParameter(name: "output", type: "string", description: "Optional output path. Default <name>.<lang>.md", required: false),
        ToolParameter(name: "format", type: "string", description: "markdown (default) or html", required: false),
        ToolParameter(name: "fidelity", type: "string", description: "structure (default, Gemini → Markdown/HTML) or file (Cloud Translation v3 → re-rendered PDF/DOCX/PPTX/XLSX, needs GCP token).", required: false),
    ]

    static let textExtensions: Set<String> = ["txt", "md", "markdown", "html", "htm", "csv", "tsv", "json", "xml", "rtf", "log", "text"]

    /// A document translation can be LONG and silently hit the model's output cap. We stream so we can
    /// read the finish reason: `truncated` means the output was cut off and must NOT be shipped as done.
    public struct Output: Sendable { public var text: String; public var truncated: Bool
        public init(text: String, truncated: Bool) { self.text = text; self.truncated = truncated } }

    private let inlineCap: Int
    private let filesClient: GeminiFilesClient?
    /// (system, user, attachments?) → translated text + whether it was truncated. Injectable for tests.
    private let translate: @Sendable (_ system: String, _ user: String, _ attachment: MediaAttachment?) async throws -> Output
    /// fidelity=file path: (bytes, mime, targetLang) → re-rendered translated file. nil = unavailable.
    private let translateFile: (@Sendable (_ data: Data, _ mime: String, _ targetLang: String) async throws -> CloudTranslationClient.Translated)?

    public init(registry: ProviderRegistry, binding: ProviderBinding, geminiKey: String? = nil,
                inlineCap: Int = 20 * 1024 * 1024, maxTokens: Int = 32768) {
        self.inlineCap = inlineCap
        self.filesClient = geminiKey.map { GeminiFilesClient(apiKey: $0) }
        // Cloud Translation v3 reads its credentials from the environment AT CALL TIME (so a token set
        // after launch still works): GOOGLE_CLOUD_ACCESS_TOKEN + GOOGLE_CLOUD_PROJECT.
        self.translateFile = { data, mime, targetLang in
            let env = ProcessInfo.processInfo.environment
            guard let token = env["GOOGLE_CLOUD_ACCESS_TOKEN"], !token.isEmpty,
                  let project = env["GOOGLE_CLOUD_PROJECT"], !project.isEmpty else {
                throw ToolError.configuration("fidelity=file needs Cloud Translation v3 — set GOOGLE_CLOUD_ACCESS_TOKEN (e.g. `gcloud auth print-access-token`) and GOOGLE_CLOUD_PROJECT")
            }
            let client = CloudTranslationClient(accessToken: token, projectId: project,
                                                location: env["GOOGLE_CLOUD_LOCATION"] ?? "global")
            return try await client.translateDocument(data: data, mimeType: mime, targetLanguage: targetLang)
        }
        self.translate = { system, user, attachment in
            let userMessage = attachment.map { ChatMessage(role: .user, content: user, attachments: [$0]) }
                ?? ChatMessage(role: .user, content: user)
            // Stream (not complete) so the finish reason is observable — a long doc can hit the output
            // cap, and we must report that as incomplete instead of writing a silently-truncated file.
            let stream = try await registry.stream(providerId: binding.providerId, model: binding.model,
                                                   messages: [ChatMessage(role: .system, content: system), userMessage],
                                                   settings: ModelSettings(temperature: 0.1, maxTokens: maxTokens))
            var text = ""
            var finish: String?
            for try await event in stream {
                switch event {
                case .delta(let d): text += d
                case .finish(let r): finish = r
                default: break
                }
            }
            return Output(text: text, truncated: Self.isTruncated(finish))
        }
    }

    /// Test initializer: deterministic translator, no provider/network.
    public init(inlineCap: Int = 20 * 1024 * 1024,
                translateFile: (@Sendable (_ data: Data, _ mime: String, _ targetLang: String) async throws -> CloudTranslationClient.Translated)? = nil,
                translate: @escaping @Sendable (_ system: String, _ user: String, _ attachment: MediaAttachment?) async throws -> Output) {
        self.inlineCap = inlineCap
        self.filesClient = nil
        self.translateFile = translateFile
        self.translate = translate
    }

    /// A finish reason that means the output was cut off (Gemini "MAX_TOKENS"; OpenAI/Anthropic "length").
    static func isTruncated(_ finishReason: String?) -> Bool {
        let r = (finishReason ?? "").uppercased()
        return r == "MAX_TOKENS" || r == "LENGTH"
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("path", from: arguments)
        let to = try requireString("to", from: arguments)
        // INPUT is read-only → armed external read roots (--allow-read) also resolve. NOTE: the
        // inner byte reads below MUST use the ForReading helpers too — resolving here alone
        // would pass then fail at each confinedRoot() read (same-data sequential-consumption trap).
        let resolved = try context.resolvedPathForReading(path, mustExist: true)
        let ext = (resolved as NSString).pathExtension.lowercased()
        let format = (arguments["format"] as? String ?? "markdown").lowercased()
        let asHTML = format == "html" || format == "htm"
        let base = (resolved as NSString).lastPathComponent

        // fidelity=file → Cloud Translation v3: a re-rendered file with the ORIGINAL layout preserved
        // (PDF→PDF, DOCX→DOCX, …). Same extension out. Needs a GCP token (translateFile closure).
        if (arguments["fidelity"] as? String)?.lowercased() == "file" {
            guard let docMime = CloudTranslationClient.mimeType(forExtension: ext) else {
                return .failure("fidelity=file supports pdf/docx/pptx/xlsx; '\(path)' is not one of those")
            }
            guard let translateFile else { return .failure("fidelity=file (Cloud Translation v3) is not available here") }
            let stem = (base as NSString).deletingPathExtension
            let outArg = (arguments["output"] as? String)?.trimmingCharacters(in: .whitespaces)
            let outRel = (outArg?.isEmpty == false) ? outArg! : "\(stem).\(Self.langSlug(to)).\(ext)"
            let artifact = try ArtifactOutputEvidence.prepare(path: outRel, kind: .file, context: context)
            guard let data = try? context.readDataForReading(path) else { return .failure("couldn't read \(path)") }
            let translated = try await translateFile(data, docMime, Self.langCode(to))
            guard !translated.bytes.isEmpty else { return .failure("translation returned no file for \(path)") }
            try context.confinedRoot().writeData(artifact.relativePath, translated.bytes, createParents: true)
            var metadata = ["source_path": path, "path": artifact.relativePath,
                            "output": artifact.relativePath, "language": to, "fidelity": "file"]
            try metadata.mergeArtifactMetadata(artifact, context: context)
            return ToolResult(success: true,
                              output: "Translated \(base) → \(artifact.relativePath) (\(to), original \(ext.uppercased()) layout preserved, \(translated.bytes.count) bytes).",
                              metadata: metadata)
        }

        let outExt = asHTML ? "html" : "md"
        let stem = (base as NSString).deletingPathExtension
        let defaultOut = "\(stem).\(Self.langSlug(to)).\(outExt)"
        let requestedOut = (arguments["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outRel = (requestedOut?.isEmpty == false) ? requestedOut! : defaultOut
        let artifact = try ArtifactOutputEvidence.prepare(path: outRel, kind: .file, context: context)

        // Decide the source carrier: media part (pdf/image) vs inline text (text files). All reads go
        // through the CONFINED root (symlink-safe), never a raw resolvedPath open (TOCTOU).
        var attachment: MediaAttachment? = nil
        var inlineText = ""
        var uploadedURI: String? = nil   // a large-file Files API upload to clean up afterwards
        if let (kind, mime) = MediaAttachment.kindAndMime(forExtension: ext), kind == .pdf || kind == .image {
            guard let data = try? context.readDataForReading(path) else {
                return .failure("couldn't read \(path)")
            }
            if data.count <= inlineCap {
                attachment = MediaAttachment(kind: kind, mimeType: mime, payload: .inline(data), sourcePath: resolved)
            } else if let filesClient {
                let uri = try await filesClient.upload(data: data, mimeType: mime,
                                                       displayName: (resolved as NSString).lastPathComponent)
                uploadedURI = uri
                attachment = MediaAttachment(kind: kind, mimeType: mime, payload: .fileURI(uri), sourcePath: resolved)
            } else {
                return .failure("\(path) is over \(inlineCap / 1_048_576)MB and needs the Gemini Files API — no Gemini key is configured")
            }
        } else if Self.textExtensions.contains(ext) {
            guard let text = try? context.readStringForReading(path) else {
                return .failure("couldn't read \(path) as UTF-8 text")
            }
            inlineText = text
        } else {
            return .failure("translate_document handles PDF, images of documents, or text files; '\(path)' is not supported")
        }

        let system = "You are a professional document translator. You translate faithfully and preserve the document's structure exactly."
        let user = Self.prompt(to: to, asHTML: asHTML, inlineText: inlineText, hasAttachment: attachment != nil)
        // Clean up any Files API upload so it doesn't linger against quota (48h retention) — on EVERY
        // exit, including when translation THROWS (defer can't be async, so handle both paths).
        let translated: Output
        do {
            translated = try await translate(system, user, attachment)
        } catch {
            if let uploadedURI, let filesClient { try? await filesClient.delete(uri: uploadedURI) }
            throw error
        }
        if let uploadedURI, let filesClient { try? await filesClient.delete(uri: uploadedURI) }
        let body = translated.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .failure("translation came back empty for \(path)") }
        // Do NOT silently ship a cut-off translation. If the model hit its output cap, refuse to write
        // a partial file and tell the user to split the document.
        guard !translated.truncated else {
            return .failure("translation of \(base) hit the model's output limit and is INCOMPLETE — not saving a partial file. Split the document into smaller parts and translate each, or raise the output budget.")
        }

        // Save next to a default name unless an output path was given. Write through the CONFINED root
        // (symlink-safe atomic temp+rename inside the project), never a raw path that could follow a link.
        try context.confinedRoot().writeData(artifact.relativePath, Data(body.utf8), createParents: true)

        let lineCount = body.split(separator: "\n", omittingEmptySubsequences: false).count
        var metadata = ["source_path": path, "path": artifact.relativePath,
                        "output": artifact.relativePath, "language": to, "format": outExt]
        try metadata.mergeArtifactMetadata(artifact, context: context)
        return ToolResult(success: true,
                          output: "Translated \(base) → \(artifact.relativePath) (\(to), \(asHTML ? "HTML" : "Markdown"), \(lineCount) lines, structure preserved).",
                          metadata: metadata)
    }

    static func prompt(to: String, asHTML: Bool, inlineText: String, hasAttachment: Bool) -> String {
        let target = asHTML ? "clean HTML" : "clean Markdown"
        var lines = [
            "Translate the \(hasAttachment ? "attached document" : "document below") into \(to).",
            "Preserve the original structure EXACTLY: headings, lists, tables, bold/italic emphasis, and ordering.",
            "Output \(target) that mirrors the source layout. Translate all readable text; keep code, URLs, and proper nouns as-is unless they have a standard translation.",
            "Output ONLY the translated document — no preamble, no notes, no surrounding code fences.",
        ]
        if !hasAttachment {
            lines.append("")
            lines.append("Document:")
            lines.append(inlineText)
        }
        return lines.joined(separator: "\n")
    }

    /// Map a language name (or pass-through code) to a BCP-47 code for Cloud Translation v3.
    static func langCode(_ language: String) -> String {
        let l = language.trimmingCharacters(in: .whitespaces).lowercased()
        let map: [String: String] = [
            "spanish": "es", "french": "fr", "german": "de", "italian": "it", "portuguese": "pt",
            "japanese": "ja", "chinese": "zh", "korean": "ko", "russian": "ru", "arabic": "ar",
            "hindi": "hi", "dutch": "nl", "polish": "pl", "turkish": "tr", "english": "en",
            "vietnamese": "vi", "thai": "th", "indonesian": "id", "swedish": "sv", "greek": "el",
        ]
        if let code = map[l] { return code }
        // Already a code (e.g. "es", "pt-BR")? Pass it through; else best-effort first 2 letters.
        if l.count <= 5, l.allSatisfy({ $0.isLetter || $0 == "-" }) { return l }
        return String(l.prefix(2))
    }

    /// "Spanish" → "spanish", "Brazilian Portuguese" → "brazilian-portuguese".
    static func langSlug(_ language: String) -> String {
        let slug = language.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        return slug.isEmpty ? "translated" : String(slug.prefix(40))
    }
}
