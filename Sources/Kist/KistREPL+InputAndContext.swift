import Foundation
import AgentCore

// Line input (hidden key entry), document-export request handling, and Captain
// retrieval-context attachment. Extracted verbatim from KistREPL.swift.
extension KistREPL {
    /// Read a line without echoing it (for pasting an API key inline). Falls back to a visible readLine
    /// when there's no controlling TTY (pipes/tests).
    static func readHiddenLine() -> String {
        if let c = getpass("") { return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum DocumentExportRequestResult: Equatable {
        case notDocumentExport
        case handled(String)
        case failed(String)
    }

    static func handleDocumentExportRequest(_ input: String,
                                            humanTranscript: [ChatMessage],
                                            projectRoot: String,
                                            now: Date = Date()) -> DocumentExportRequestResult {
        guard DocumentExport.parseIntent(input) != nil else { return .notDocumentExport }
        do {
            guard let message = try DocumentExport.writeLatestAssistantDocument(input: input,
                                                                                transcript: humanTranscript,
                                                                                projectRoot: projectRoot,
                                                                                now: now) else {
                return .notDocumentExport
            }
            return .handled(message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func attachCaptainRetrievalContext(to prompt: String,
                                              retrieval: CaptainRetrievalContext) -> String {
        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = """
        ---
        CAPTAIN WORKING MEMORY
        This section is retrieved disk-backed memory for the current objective. Treat it as evidence, constraints, and decision rationale. Use it to research before expertise, expertise before organization, and organization before execution.

        \(retrieval.briefing)
        ---
        """
        if base.isEmpty { return block }
        return base + "\n\n" + block
    }
}
