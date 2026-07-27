import Foundation

// MARK: - Agent Skills (open standard: https://agentskills.io)
//
// A Skill is a `SKILL.md` file: YAML-ish frontmatter (name/description/flags) + a markdown
// body of instructions. The point is PROGRESSIVE DISCLOSURE — three tiers:
//
//   Tier 1 (always in the system prompt, ~cheap): name + description + location only.
//   Tier 2 (loaded on demand): the model reads the SKILL.md via `read_file` when it decides
//           the skill is relevant; the full instructions enter context then, and only then.
//   Tier 3 (referenced from the body): bundled scripts/files the model reads/runs as needed.
//
// This file owns Tier-1 representation + parsing/validation. Discovery, the in-prompt menu,
// and the on-demand load hook live in SkillDiscovery / SkillManager / SkillCatalog and the
// `read_file` tool. NOTHING here loads a body into the prompt — that is the whole design.

/// A parsed `SKILL.md`. Immutable + `Sendable`: one instance is shared freely across the
/// registry, the loop, and concurrent tool calls.
public struct Skill: Sendable, Equatable {
    /// Spec limits (mirrors the open standard / Crush). Enforced by `validate()`.
    public static let maxNameLength = 64
    public static let maxDescriptionLength = 1024
    public static let maxCompatibilityLength = 500

    /// Synthetic location prefix for builtins shipped in the bundle (read via `read_file`
    /// from the embedded resources, bypassing project-root confinement for this KNOWN,
    /// read-only subtree only). Mirrors Crush's `crush:` prefix.
    public static let builtinPrefix = "kist:"

    public let name: String
    public let description: String
    public let userInvocable: Bool
    public let disableModelInvocation: Bool
    public let license: String?
    public let compatibility: String?
    public let metadata: [String: String]
    /// The spec's `allowed-tools` capability scope (agentskills.io): the tools this skill is
    /// permitted to use. Empty = unrestricted (no scope declared). When a skill WITH a non-empty
    /// allow-list is loaded, the session is scoped to those tools (plus always-safe read-only tools)
    /// for least-privilege — a benign read-only skill can't have the model wander into write/shell,
    /// and it's the enforcement hook untrusted-skill trust tiers will reuse.
    public let allowedTools: [String]
    /// Trust tier (Sprint 2). `.trusted` skills honor their own `allowed-tools`; an `.untrusted`
    /// (unpinned project / third-party) skill is forced to a read-only scope when loaded — its
    /// self-declared allow-list is IGNORED, so a malicious skill can't grant itself run_command.
    public let trust: SkillTrust
    /// SHA-256 (hex) of the raw SKILL.md bytes — the content identity used to pin/verify trust.
    public let contentHash: String
    /// The markdown body — the actual instructions. NEVER injected into the system prompt;
    /// loaded on demand when the model reads the SKILL.md.
    public let instructions: String
    /// Directory containing the SKILL.md (Tier-3 bundled assets live alongside).
    public let path: String
    /// The path the model reads to load Tier-2 instructions. For builtins this is a
    /// `kist:<name>/SKILL.md` synthetic path; for user skills it is the real file path.
    public let skillFilePath: String
    public let builtin: Bool

    public init(name: String, description: String, userInvocable: Bool = false,
                disableModelInvocation: Bool = false, license: String? = nil,
                compatibility: String? = nil, metadata: [String: String] = [:],
                allowedTools: [String] = [],
                trust: SkillTrust = .trusted, contentHash: String = "",
                instructions: String, path: String = "", skillFilePath: String = "",
                builtin: Bool = false) {
        self.name = name
        self.description = description
        self.userInvocable = userInvocable
        self.disableModelInvocation = disableModelInvocation
        self.license = license
        self.compatibility = compatibility
        self.metadata = metadata
        self.allowedTools = allowedTools
        self.trust = trust
        self.contentHash = contentHash
        self.instructions = instructions
        self.path = path
        self.skillFilePath = skillFilePath
        self.builtin = builtin
    }

    /// Immutable copy with a resolved trust tier (discovery decides trust once it has the content
    /// hash + trust store; the parser can't know trust).
    public func withTrust(_ t: SkillTrust) -> Skill {
        Skill(name: name, description: description, userInvocable: userInvocable,
              disableModelInvocation: disableModelInvocation, license: license, compatibility: compatibility,
              metadata: metadata, allowedTools: allowedTools, trust: t, contentHash: contentHash,
              instructions: instructions, path: path, skillFilePath: skillFilePath, builtin: builtin)
    }

    // MARK: Validation

    /// Validate against the spec. Returns every problem found (joined), not just the first —
    /// a malformed skill should tell the author all of what's wrong in one pass.
    public func validate() -> SkillError? {
        var problems: [String] = []

        if name.isEmpty {
            problems.append("name is required")
        } else {
            if name.count > Self.maxNameLength {
                problems.append("name exceeds \(Self.maxNameLength) characters")
            }
            if !Self.isValidName(name) {
                problems.append("name must be alphanumeric with single internal hyphens "
                    + "(no leading/trailing/consecutive hyphens)")
            }
            // Skill identity is the directory name — guards against a copy-paste where the
            // frontmatter name and the folder drift apart (the loader keys on directory).
            if !path.isEmpty {
                let dir = (path as NSString).lastPathComponent
                if dir.caseInsensitiveCompare(name) != .orderedSame {
                    problems.append("name \"\(name)\" must match directory \"\(dir)\"")
                }
            }
        }

        if description.isEmpty {
            problems.append("description is required")
        } else if description.count > Self.maxDescriptionLength {
            problems.append("description exceeds \(Self.maxDescriptionLength) characters")
        }

        if let compatibility, compatibility.count > Self.maxCompatibilityLength {
            problems.append("compatibility exceeds \(Self.maxCompatibilityLength) characters")
        }

        // HARD reject invisible-injection encodings anywhere in the skill (Unicode Tag chars render
        // blank to humans but carry instructions to the model — never legitimate). The skill is
        // dropped at discovery rather than ever entering context.
        if Self.containsHiddenInjection(name) || Self.containsHiddenInjection(description)
            || Self.containsHiddenInjection(instructions) {
            problems.append("contains hidden Unicode Tag characters (U+E0000–U+E007F) — invisible "
                + "injection; refused")
        }

        return problems.isEmpty ? nil : SkillError.invalid(problems)
    }

    static func containsHiddenInjection(_ s: String) -> Bool { SkillSafety.containsHiddenTagChars(s) }

    /// `^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$` without a regex engine (Linux-portable, allocation-light).
    static func isValidName(_ s: String) -> Bool {
        if s.isEmpty { return false }
        var prevHyphen = false
        for (i, ch) in s.enumerated() {
            let isAlnum = ch.isASCII && (ch.isLetter || ch.isNumber)
            if ch == "-" {
                if i == 0 || prevHyphen { return false }   // no leading / consecutive hyphen
                prevHyphen = true
            } else if isAlnum {
                prevHyphen = false
            } else {
                return false
            }
        }
        return !prevHyphen   // no trailing hyphen
    }

    // MARK: Parsing

    /// Parse a `SKILL.md` from raw bytes. `path`/`skillFilePath`/`builtin` are supplied by the
    /// caller (the discoverer knows where it found the file); parsing only fills frontmatter+body.
    public static func parse(content: String, path: String = "", skillFilePath: String = "",
                             builtin: Bool = false) throws -> Skill {
        guard let (frontmatter, body) = splitFrontmatter(content) else {
            throw SkillError.noFrontmatter
        }
        let fm = parseFlatYAML(frontmatter)
        // Reject duplicate scalar keys: last-wins lets a crafted SKILL.md hide its effective value
        // (e.g. `disable-model-invocation: true` then `: false`). Fail loudly instead.
        if !fm.duplicateKeys.isEmpty {
            throw SkillError.invalid(["duplicate frontmatter key(s): " + fm.duplicateKeys.sorted().joined(separator: ", ")])
        }
        // `allowed-tools`: space-separated per the agentskills.io spec (e.g. "read_file search_code").
        let allowedTools = (fm.scalar("allowed-tools") ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        return Skill(
            name: fm.scalar("name") ?? "",
            description: fm.scalar("description") ?? "",
            userInvocable: fm.bool("user-invocable"),
            disableModelInvocation: fm.bool("disable-model-invocation"),
            license: fm.scalar("license"),
            compatibility: fm.scalar("compatibility"),
            metadata: fm.metadata,
            allowedTools: allowedTools,
            trust: builtin ? .trusted : .untrusted,           // discovery upgrades a pinned/signed project skill
            contentHash: SkillTrustStore.hash(content),
            instructions: body.trimmingCharacters(in: .whitespacesAndNewlines),
            path: path, skillFilePath: skillFilePath, builtin: builtin
        )
    }

    /// Split leading `---`-delimited YAML frontmatter from the markdown body. Tolerant of a
    /// UTF-8 BOM and CRLF/CR line endings. Returns nil when there is no opening fence.
    static func splitFrontmatter(_ raw: String) -> (frontmatter: String, body: String)? {
        var content = raw
        if content.hasPrefix("\u{FEFF}") { content.removeFirst() }
        content = content.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
        let lines = content.components(separatedBy: "\n")

        guard let start = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[start].trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }
        let after = lines[(start + 1)...]
        guard let endRel = after.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil   // unclosed frontmatter
        }
        let frontmatter = lines[(start + 1)..<endRel].joined(separator: "\n")
        let body = lines[(endRel + 1)...].joined(separator: "\n")
        return (frontmatter, body)
    }

    // MARK: Tier-1 prompt rendering

    /// The menu entry injected into the system prompt: name + description + location ONLY.
    /// Excluded when `disableModelInvocation` (a user-only skill the model can't pick) or when the
    /// location is empty (nothing the model could read — an unloadable, confusing entry).
    func promptEntry() -> String? {
        if disableModelInvocation || skillFilePath.isEmpty { return nil }
        var s = "  <skill>\n"
        s += "    <name>\(Self.escape(name))</name>\n"
        s += "    <description>\(Self.escape(description))</description>\n"
        s += "    <location>\(Self.escape(skillFilePath))</location>\n"
        if builtin { s += "    <type>builtin</type>\n" }
        s += "  </skill>"
        return s
    }

    /// Full skill wrapped for injection when a user explicitly invokes it (slash command).
    public func invocationXML() -> String {
        var s = "<loaded_skill>\n"
        s += "  <name>\(Self.escape(name))</name>\n"
        s += "  <description>\(Self.escape(description))</description>\n"
        s += "  <location>\(Self.escape(skillFilePath))</location>\n"
        s += "  <instructions>\n\(Self.escape(instructions))\n  </instructions>\n"
        s += "</loaded_skill>"
        return s
    }

    /// Minimal XML-attribute/text escaping for prompt injection safety.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Rough token estimate (~4 chars/token) for diagnostic logging of menu cost.
    public static func approxTokenCount(_ s: String) -> Int {
        s.isEmpty ? 0 : (s.utf8.count + 3) / 4
    }
}

// MARK: - Errors

public enum SkillError: Error, Sendable, Equatable, CustomStringConvertible {
    case noFrontmatter
    case invalid([String])
    case notFound(String)

    public var description: String {
        switch self {
        case .noFrontmatter: return "no YAML frontmatter found (SKILL.md must start with a --- fenced block)"
        case .invalid(let problems): return "invalid skill: " + problems.joined(separator: "; ")
        case .notFound(let id): return "skill not found: \(id)"
        }
    }
}

// MARK: - Flat frontmatter parser
//
// The skill frontmatter is intentionally shallow: top-level scalars plus a single optional
// `metadata:` map of indented key/value scalars. We hand-parse it rather than pull in a YAML
// dependency — the grammar we accept is exactly what the spec needs and nothing more.

struct FlatFrontmatter {
    let scalars: [String: String]
    let metadata: [String: String]
    /// Top-level scalar keys that appeared more than once — surfaced so the parser can reject the
    /// skill rather than silently last-wins.
    let duplicateKeys: Set<String>

    func scalar(_ key: String) -> String? {
        guard let v = scalars[key], !v.isEmpty else { return nil }
        return v
    }
    func bool(_ key: String) -> Bool {
        guard let v = scalars[key]?.lowercased() else { return false }
        return v == "true" || v == "yes" || v == "1"
    }
}

func parseFlatYAML(_ text: String) -> FlatFrontmatter {
    var scalars: [String: String] = [:]
    var metadata: [String: String] = [:]
    var duplicateKeys: Set<String> = []
    var inMetadata = false

    for rawLine in text.components(separatedBy: "\n") {
        if rawLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        let indented = rawLine.first == " " || rawLine.first == "\t"
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") { continue }   // comment

        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = stripScalar(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))

        if key == "metadata" && value.isEmpty {
            inMetadata = true
            continue
        }
        if inMetadata && indented {
            if !key.isEmpty { metadata[key] = value }
            continue
        }
        // A non-indented key ends any metadata block.
        inMetadata = false
        if !key.isEmpty {
            if scalars[key] != nil { duplicateKeys.insert(key) }
            scalars[key] = value
        }
    }
    return FlatFrontmatter(scalars: scalars, metadata: metadata, duplicateKeys: duplicateKeys)
}

/// Strip matching surrounding quotes from a scalar value, then remove any control characters
/// (newlines/tabs survive line-splitting can't reach here, but defense-in-depth keeps raw control
/// bytes out of the prompt XML even after entity-escaping).
private func stripScalar(_ s: String) -> String {
    var v = s
    if v.count >= 2 {
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
    }
    return String(v.unicodeScalars.filter { !($0.value < 0x20 || $0.value == 0x7F) })
}
