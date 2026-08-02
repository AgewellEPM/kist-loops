import Foundation

// File content I/O tools. Every path goes through `context.confinedRoot()` — the
// `openat`/`O_NOFOLLOW` layer — so all three are confined to the project root and
// TOCTOU/symlink-escape-safe at the moment of the open (not a stale string check).

enum ReadFileWindow {
    static let defaultLines = 400
}

/// Read a file's contents (optionally a line range), with line numbers.
public struct ReadFileTool: AgentTool {
    public let name = "read_file"
    public let description = "Read a numbered file window. Defaults to the first 400 lines; use start_line/end_line to page through large files."
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "File path relative to the project root. Absolute paths under a session-armed read-only root (--allow-read, e.g. /Volumes) are also readable.", required: true),
        ToolParameter(name: "start_line", type: "integer", description: "Starting line (1-indexed)", required: false),
        ToolParameter(name: "end_line", type: "integer", description: "Ending line (inclusive). If omitted, reads a 400-line window.", required: false),
    ]
    public init() {}

    /// A skill signature sidecar (`SKILL.md.sig`) is a tiny JSON — cap it hard so a hostile project can't
    /// hand us a giant "signature" to read into memory before the decode fails.
    static let maxSignatureBytes = 65_536

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("path", from: arguments)

        // Agent-Skills: skill detection happens BEFORE any read and keys ONLY on the advertised
        // location map — never on the bare `kist:` prefix. A path the menu never offered gets no
        // skill treatment (no whole-file read, no markLoaded), even if it looks like a skill.
        let skillName = context.skillLocations[path]

        // A `kist:` path is ONLY valid when it was advertised; otherwise refuse it outright (it
        // would escape ConfinedRoot, which is exactly what we don't allow for unadvertised paths).
        if path.hasPrefix(Skill.builtinPrefix) {
            guard let skillName else { throw ToolError.notFound(path) }
            return try await readBuiltinSkill(path: path, skillName: skillName, context: context)
        }

        // A project-local skill the model was offered: load the WHOLE file (instructions load
        // complete, not in a 400-line window), capped, and mark loaded ONLY after we succeed.
        if let skillName {
            return try await readProjectSkill(path: path, skillName: skillName, context: context)
        }

        // Ordinary file: unchanged windowed behavior.
        // TOCTOU-safe read: openat/O_NOFOLLOW via ConfinedRoot (throws .notFound if absent).
        // Routes through the READING resolver so an absolute path under an armed external
        // read root (e.g. --allow-read /Volumes for a CD) is readable; writes never are.
        let (confined, readPath) = try context.confinedRootForReading(path)
        let content = try confined.readString(readPath)
        let lines = content.components(separatedBy: "\n")

        let start = max(0, (optionalInt("start_line", from: arguments) ?? 1) - 1)
        let explicitEnd = optionalInt("end_line", from: arguments)
        let end = min(lines.count, explicitEnd ?? (start + ReadFileWindow.defaultLines))
        guard start < end else { return .failure("invalid line range") }
        let truncated = end < lines.count

        let body = lines[start..<end].enumerated()
            .map { String(format: "%4d│ %@", start + $0.offset + 1, $0.element) }
            .joined(separator: "\n")
        let header = "[read_file path=\(path) lines=\(start + 1)-\(end) of \(lines.count)]"
        var output = header + "\n" + body
        var metadata = [
            "path": path,
            "total_lines": String(lines.count),
            "shown_lines": "\(start + 1)-\(end)",
            "truncated": String(truncated),
        ]
        if truncated {
            let nextStart = end + 1
            let nextEnd = min(lines.count, end + ReadFileWindow.defaultLines)
            output += "\n[read_file truncated: next window start_line=\(nextStart) end_line=\(nextEnd); use explicit line ranges to continue]"
            metadata["next_start_line"] = String(nextStart)
            metadata["next_end_line"] = String(nextEnd)
        }
        return ToolResult(success: true, output: output, metadata: metadata)
    }

    /// Read a builtin skill from the embedded bundle (whole file, size-capped inside `readBuiltin`)
    /// and mark it loaded only after the read succeeds. Reachable ONLY for an advertised `kist:`
    /// location (the caller already verified `skillName`).
    private func readBuiltinSkill(path: String, skillName: String, context: ToolContext) async throws -> ToolResult {
        let content = try SkillDiscovery.readBuiltin(path)               // throws before any mark on failure/oversize
        await context.skillTracker?.markLoaded(skillName)
        let scope = await context.skillTracker?.declaredTools(for: skillName) ?? []
        return wholeFileResult(path: path, content: content, builtin: true, scope: scope)
    }

    /// Read a project-local skill through ConfinedRoot, whole file, capped, marking loaded only
    /// after a successful read. Reachable ONLY for an advertised location.
    private func readProjectSkill(path: String, skillName: String, context: ToolContext) async throws -> ToolResult {
        let confined = try context.confinedRoot()
        // Cap before reading so a hostile project can't slurp a giant "skill" into memory. FAIL
        // CLOSED if we can't stat it — a `try?`-swallowed metadata error must NOT fall through to
        // an uncapped read (MiMo review).
        let meta: ConfinedRoot.FileMetadata
        do { meta = try confined.fileMetadata(path) }
        catch { return .failure("cannot stat skill file \(path): \(error)") }
        guard meta.bytes <= SkillDiscovery.maxSkillBytes else {
            return .failure("skill file exceeds \(SkillDiscovery.maxSkillBytes) bytes — refused")
        }
        let content = try confined.readString(path)                      // throws .notFound before any mark
        // Re-parse + re-validate the EXACT bytes at load. FAIL-CLOSED: a parse error (e.g. frontmatter
        // stripped) or a validation failure (hidden injection) REFUSES the load — no markLoaded — so a
        // file swapped after a clean discovery can't sneak poisoned content into context (Codex S3#2 +
        // the fail-open hole where `try?` swallowed a parse error and loaded anyway).
        let parsed: Skill
        do { parsed = try Skill.parse(content: content, path: (path as NSString).deletingLastPathComponent) }
        catch { return .failure("skill failed to re-parse at load (\(path)): \(error) — refused") }
        if let err = parsed.validate() {
            return .failure("skill failed re-validation at load (\(path)): \(err) — refused")
        }
        // RE-DERIVE TRUST FROM THE CURRENT BYTES (Codex CRITICAL — the TOCTOU seam). Trust is NOT the
        // stale discovery-time verdict: derive it from the exact bytes we just read. Two tiers (Sprint 2):
        // a valid publisher SIGNATURE (SKILL.md.sig from a PINNED key, bound to this name + these bytes)
        // OR a local hash PIN ⇒ trusted. A skill benign at pin/discovery but swapped to malicious bytes
        // now hashes differently ⇒ neither tier matches ⇒ untrusted ⇒ forced read-only.
        // The sidecar read is fail-soft: absent / symlinked (O_NOFOLLOW throws) / garbage ⇒ nil ⇒ falls
        // back to the hash-pin tier, NEVER up to trusted.
        // Read the sidecar with a HARD byte cap on the same fd (a .sig is a tiny JSON) — no metadata-then-
        // read race: a file that grows/replaces after a size check can't bypass the cap. Missing / oversized
        // / symlinked / unreadable ⇒ nil ⇒ falls to the hash-pin tier, never up.
        let sigPath = SkillTrustResolver.signaturePath(forSkillAt: path)
        let signatureJSON = try? confined.readString(sigPath, maxBytes: Self.maxSignatureBytes)
        let trusted = SkillTrustResolver.resolve(skillName: skillName, content: content,
                                                 projectRoot: context.projectRoot,
                                                 signatureJSON: signatureJSON) == .trusted
        // Enforce the scope parsed from THESE verified bytes (`parsed.allowedTools`), not a discovery
        // snapshot — trust was just proven on exactly these bytes.
        await context.skillTracker?.markLoaded(skillName, trusted: trusted, allowedTools: parsed.allowedTools)
        let scope = trusted ? parsed.allowedTools : []
        return wholeFileResult(path: path, content: content, builtin: false, scope: scope, untrusted: !trusted)
    }

    /// Render a whole skill file with line numbers — never truncated (instructions load complete).
    /// `scope` = the skill's declared allowed-tools; surfaced so the model knows the session is now
    /// least-privilege-scoped and won't be surprised by a capability-scope refusal.
    private func wholeFileResult(path: String, content: String, builtin: Bool, scope: [String] = [],
                                 untrusted: Bool = false) -> ToolResult {
        let lines = content.components(separatedBy: "\n")
        let body = lines.enumerated()
            .map { String(format: "%4d│ %@", $0.offset + 1, $0.element) }
            .joined(separator: "\n")
        // Trust tier (Sprint 2): an untrusted skill forces the session to read-only — say so loudly.
        let trustNote = untrusted ?
            "\n[⚠ UNTRUSTED SKILL — not pinned (review it, then `kist --trust-skill <name>`). The session "
            + "is restricted to READ-ONLY tools while it is loaded (its allowed-tools is IGNORED). Trust "
            + "is stored user-level, never in the repo.]" : ""
        let scopeNote = scope.isEmpty ? "" :
            "\n[skill capability scope ACTIVE — while this skill is loaded only these tools (plus "
            + "read-only tools) may run: \(scope.sorted().joined(separator: ", "))]"
        // S3: flag injection-heuristic matches at the moment the body enters context, so the model
        // treats the loaded skill as untrusted DATA (builtins are trusted → not scanned).
        let injectionWarning = builtin ? "" : SkillSafety.loadWarning(for: SkillSafety.injectionHeuristics(content))
        let kind = builtin ? " (builtin skill)" : " (skill)"
        let header = "[read_file path=\(path) lines=1-\(lines.count) of \(lines.count)\(kind)]"
        return ToolResult(success: true, output: injectionWarning + header + "\n" + body + trustNote + scopeNote,
                          metadata: ["path": path, "total_lines": String(lines.count),
                                     "shown_lines": "1-\(lines.count)", "truncated": "false",
                                     "skill_load": "true", "builtin_skill": String(builtin),
                                     "skill_trust": untrusted ? "untrusted" : "trusted",
                                     "skill_scope": scope.sorted().joined(separator: " ")])
    }
}

/// Write a file, creating parent directories as needed (within the root).
public struct WriteFileTool: AgentTool {
    public let name = "write_file"
    public let description = "Write content to a file, overwriting it. Creates parent directories if needed."
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "File path relative to the project root", required: true),
        ToolParameter(name: "content", type: "string", description: "Full file content to write", required: true),
    ]
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("path", from: arguments)
        let content = try requireString("content", from: arguments)
        let confined = try context.confinedRoot()
        // A whole-file write is legitimately any size, so only the always-valid marker
        // check applies (non-localized). `old` = current bytes if the file exists, "" for
        // a create — either way a newly-introduced marker is refused.
        let existing = try? confined.readString(path)
        if let block = EditGuards.validate(old: existing ?? "", new: content, path: path, localized: false) {
            return block
        }
        let changed = existing != content
        // ConfinedRoot.writeString creates parents inside the confined root and writes
        // atomically (temp + renameat); a symlinked leaf is replaced, never written through.
        if changed { try confined.writeString(path, content, createParents: true) }

        let lineCount = content.components(separatedBy: "\n").count
        let output = changed ? "Wrote \(path) (\(lineCount) lines)" : "Unchanged \(path) (content identical)"
        return ToolResult(success: true, output: output, metadata: [
            "path": path, "lines": String(lineCount), "changed": String(changed),
        ])
    }
}

/// Make a single exact-match replacement in a file (Claude-Code-style Edit).
public struct EditFileTool: AgentTool {
    public let name = "edit_file"
    public let description = "Replace an exact substring in a file. old_text must match exactly; unique by default, or set replace_all=true to replace every occurrence."
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "File path relative to the project root", required: true),
        ToolParameter(name: "old_text", type: "string", description: "Exact text to find (must be unique unless replace_all=true)", required: true),
        ToolParameter(name: "new_text", type: "string", description: "Replacement text", required: true),
        ToolParameter(name: "replace_all", type: "boolean", description: "Replace EVERY occurrence instead of requiring a unique match (default false)", required: false),
    ]
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("path", from: arguments)
        let oldText = try requireString("old_text", from: arguments)
        let newText = try requireString("new_text", from: arguments)
        let replaceAll = (arguments["replace_all"] as? Bool) ?? false
        let confined = try context.confinedRoot()

        let content = try confined.readString(path)
        let occurrences = content.components(separatedBy: oldText).count - 1
        guard occurrences > 0 else { return .failure("old_text not found in \(path)") }
        // Default = Claude-Code Edit semantics (must be unique). replace_all lifts that, replacing all N.
        if !replaceAll {
            guard occurrences == 1 else {
                return .failure("old_text appears \(occurrences) times in \(path); add surrounding context to make it unique, or set replace_all=true")
            }
        }

        let updated = content.replacingOccurrences(of: oldText, with: newText)
        // Reliability guards (marker leak / catastrophic truncation / dropped imports) —
        // a localized edit should never trip these; if it does, refuse before writing.
        if let block = EditGuards.validate(old: content, new: updated, path: path, localized: true) {
            return block
        }
        let changed = updated != content
        if changed { try confined.writeString(path, updated, createParents: false) }

        let perDiff = newText.components(separatedBy: "\n").count - oldText.components(separatedBy: "\n").count
        let lineDiff = perDiff * occurrences
        let count = replaceAll ? "\(occurrences)× " : ""
        let suffix = lineDiff == 0 ? "" : (lineDiff > 0 ? " (+\(lineDiff) lines)" : " (\(lineDiff) lines)")
        let output = changed ? "Edited \(count)\(path)\(suffix)" : "Unchanged \(path) (replacement identical)"
        return ToolResult(success: true, output: output, metadata: [
            "path": path, "line_diff": String(lineDiff), "occurrences": String(occurrences),
            "changed": String(changed),
        ])
    }
}

/// Move or rename a file/folder WITHOUT shell — closes the real capability hole behind the desktop-cleanup
/// failure (model had no way to move a file when shell was off, so it flailed). Confined to the project root.
public struct MoveFileTool: AgentTool {
    public let name = "move_file"
    public let description = "Move or rename a file or folder within the project (no shell needed). Creates the destination's parent folders if missing. Use this for organizing/cleaning files (e.g. moving images into an Images/ folder)."
    public let parameters = [
        ToolParameter(name: "from", type: "string", description: "Source path relative to the project root", required: true),
        ToolParameter(name: "to", type: "string", description: "Destination path relative to the project root", required: true),
    ]
    public var usageExamples: [String] {
        ["move_file(from=\"Desktop/photo.png\", to=\"Desktop/Images/photo.png\")"]
    }
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let from = try requireString("from", from: arguments)
        let to = try requireString("to", from: arguments)
        let confined = try context.confinedRoot()
        // Compare the same confined representation the move primitive uses. String-only path
        // standardization misses aliases such as an absolute in-root source and its relative form,
        // causing renameat(source, source) to be reported as a mutation even though no tree byte moved.
        let fromComponents = try confined.relativeComponents(from)
        let toComponents = try confined.relativeComponents(to)
        guard !fromComponents.isEmpty else { throw ToolError.execution("cannot move the root directory") }
        guard !toComponents.isEmpty else { throw ToolError.execution("invalid move destination: \(to)") }
        let changed = fromComponents != toComponents
        if changed {
            try confined.move(from, to, createParents: true)
        } else if try !confined.fileType(from).exists {
            // Preserve rename semantics: a no-op spelling does not turn a missing source into success.
            throw ToolError.notFound(from)
        }
        let output = changed ? "Moved \(from) → \(to)" : "Unchanged \(from) (source and destination match)"
        return ToolResult(success: true, output: output,
                          metadata: ["from": from, "to": to, "changed": String(changed)])
    }
}

/// Create a directory (and parents) WITHOUT shell, confined to the project root.
public struct MakeDirTool: AgentTool {
    public let name = "make_dir"
    public let description = "Create a folder (and any missing parent folders) within the project. No shell needed."
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "Folder path relative to the project root", required: true),
    ]
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("path", from: arguments)
        let confined = try context.confinedRoot()
        let existed = (try? confined.fileType(path).exists) ?? false
        try confined.makeDirectory(path)
        let changed = !existed
        let output = changed ? "Created folder \(path)" : "Unchanged folder \(path) (already exists)"
        return ToolResult(success: true, output: output,
                          metadata: ["path": path, "changed": String(changed)])
    }
}
