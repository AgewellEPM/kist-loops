import Foundation
import AgentCore
#if canImport(CoreGraphics) && canImport(CoreText)
import CoreGraphics
import CoreText
#endif

struct DocumentExport {
    enum Format: String, Equatable {
        case pdf
        case rtf

        var extensionName: String { rawValue }
        var label: String { rawValue.uppercased() }
    }

    struct Intent: Equatable {
        var format: Format
    }

    static func parseIntent(_ input: String) -> Intent? {
        let lower = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }

        // Do not steal debugging/self-heal requests that merely mention a PDF failure.
        let repairWords = ["fix", "broken", "bug", "error", "issue", "malformed", "code", "self heal", "self-heal"]
        guard !repairWords.contains(where: { lower.contains($0) }) else { return nil }

        let wantsPDF = lower.contains("pdf")
        let wantsDoc = lower.contains(" doc") || lower.contains("docu") || lower.contains("rtf")
        guard wantsPDF || wantsDoc else { return nil }

        let exportVerbs = ["export", "save", "make", "create", "turn", "convert", "give", "have", "send"]
        let refersToPriorOutput = [" this", " that", " last", " previous", " above", " letter", " document", " doc"]
            .contains { lower.contains($0) }
        guard exportVerbs.contains(where: { lower.contains($0) }) && refersToPriorOutput else { return nil }

        return Intent(format: wantsPDF ? .pdf : .rtf)
    }

    static func latestAssistantText(from transcript: [ChatMessage]) -> String? {
        transcript.reversed().first { $0.role == .assistant }?.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    @discardableResult
    static func writeLatestAssistantDocument(input: String,
                                             transcript: [ChatMessage],
                                             projectRoot: String,
                                             now: Date = Date()) throws -> String? {
        guard let intent = parseIntent(input) else { return nil }
        guard let text = latestAssistantText(from: transcript) else {
            return "No prior assistant answer to export yet. Generate the document text first, then ask for PDF or doc."
        }
        let relativePath = ".kist/exports/" + filename(for: text, format: intent.format, now: now)
        let confined = try ToolContext(projectRoot: projectRoot).confinedRoot()
        switch intent.format {
        case .pdf:
            #if canImport(CoreGraphics) && canImport(CoreText)
            let absolutePath = try ToolContext(projectRoot: projectRoot).resolvedPath(relativePath, mustExist: false)
            try writePDF(text: text, to: URL(fileURLWithPath: absolutePath))
            #else
            throw NSError(domain: "kist.document-export", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PDF export is not available on this platform"])
            #endif
        case .rtf:
            try confined.writeString(relativePath, rtf(text), createParents: true)
        }
        let absolute = try ToolContext(projectRoot: projectRoot).resolvedPath(relativePath, mustExist: true)
        return "exported \(intent.format.label) · \(absolute)"
    }

    private static func filename(for text: String, format: Format, now: Date) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? "document"
        let slug = firstLine
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .nilIfEmpty ?? "document"
        return "\(timestamp(now))-\(String(slug.prefix(48))).\(format.extensionName)"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func rtf(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\n", with: "\\par\n")
        return "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24\n\(escaped)\n}"
    }

    #if canImport(CoreGraphics) && canImport(CoreText)
    private static func writePDF(text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw NSError(domain: "kist.document-export", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "could not create PDF writer"])
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "kist.document-export", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "could not create PDF context"])
        }

        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let pageRect = CGRect(x: 54, y: 54, width: mediaBox.width - 108, height: mediaBox.height - 108)
        var range = CFRange(location: 0, length: 0)

        repeat {
            context.beginPDFPage(nil)
            let path = CGMutablePath()
            path.addRect(pageRect)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            range.location += max(visible.length, 1)
            context.endPDFPage()
        } while range.location < attributed.length

        context.closePDF()
    }
    #endif
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
