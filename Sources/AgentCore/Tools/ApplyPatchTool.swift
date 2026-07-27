import Foundation

/// Apply a multi-file V4A patch — the structured-edit tool the field standardized on (Codex), preferred
/// over write_file/edit_file for real edits because it's atomic across files and located by context (no
/// line numbers). Validates the WHOLE patch in memory first (every hunk must match), so a bad patch fails
/// before anything is written. Confined to the project root via ConfinedRoot.
public struct ApplyPatchTool: AgentTool {
    public let name = "apply_patch"
    public let description = """
    Apply a patch in V4A format. Preferred for edits over write_file. Envelope:
    *** Begin Patch / *** End Patch, with *** Add File: / *** Update File: (optional *** Move to:) /
    *** Delete File:. Update hunks use @@ then space-context, -removed, +added lines (no line numbers —
    include a few context lines so the hunk locates uniquely).
    """
    public let parameters = [
        ToolParameter(name: "patch", type: "string", description: "The full V4A patch text (*** Begin Patch … *** End Patch)", required: true),
    ]
    public var usageExamples: [String] {
        ["apply_patch(patch=\"*** Begin Patch\\n*** Update File: src/a.swift\\n@@\\n let x = 1\\n-let y = 2\\n+let y = 3\\n*** End Patch\")"]
    }
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let patch = try requireString("patch", from: arguments)
        let ops: [ApplyPatch.Op]
        do { ops = try ApplyPatch.parse(patch) }
        catch let e as ApplyPatch.PatchError { return .failure(message(for: e)) }

        let confined = try context.confinedRoot()
        // Pre-read the files an Update needs (Add/Delete don't need the old content).
        var files: [String: String] = [:]
        for op in ops {
            if case .update(let path, _, _) = op, let c = try? confined.readString(path) { files[path] = c }
        }
        let result: (files: [String: String?], summary: [String])
        do { result = try ApplyPatch.applyToMap(ops, files: files) }
        catch let e as ApplyPatch.PatchError { return .failure(message(for: e)) }

        // An Update that MOVES writes its new content to the DESTINATION path, whose old
        // content is the source's pre-read bytes — that destination is still a localized
        // edit and must be guarded as one (Codex). Map move destination → source old content.
        var moveOldContent: [String: String] = [:]
        for op in ops {
            if case .update(let src, let moveTo?, _) = op, let old = files[src] { moveOldContent[moveTo] = old }
        }
        // Reliability guards run on the WHOLE result before any byte is written, so a
        // tripped guard leaves the tree untouched (same atomic contract as hunk matching).
        // Localized = the new content derives from known old bytes (in-place Update or a Move
        // destination); a pure Add has no old content and only gets the marker check.
        for (path, content) in result.files {
            guard let content else { continue }               // deletes have nothing to guard
            let old = files[path] ?? moveOldContent[path]
            let localized = old != nil
            if let block = EditGuards.validate(old: old ?? "", new: content, path: path, localized: localized) {
                return block
            }
        }
        // Commit: every hunk matched and every guard passed, so writes here are the only failure surface.
        for (path, content) in result.files {
            if let content { try confined.writeString(path, content, createParents: true) }
            else { try? confined.removeFile(path) }
        }
        return ToolResult(success: true,
                          output: "applied patch:\n" + result.summary.joined(separator: "\n"),
                          metadata: ["files": String(result.files.count)])
    }

    private func message(for e: ApplyPatch.PatchError) -> String {
        switch e {
        case .envelope(let m): return "patch format error: \(m)"
        case .empty: return "patch contained no file operations"
        case .hunkNoMatch(let p): return "a hunk did not match \(p) — the context/removed lines aren't in the file. Re-read the file and regenerate the hunk with exact surrounding lines."
        case .missingFile(let p): return "cannot update \(p): file not found (use *** Add File: to create it)"
        }
    }
}
