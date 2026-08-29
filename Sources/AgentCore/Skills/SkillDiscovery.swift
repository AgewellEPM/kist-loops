import Foundation

/// Per-file discovery outcome — surfaced for diagnostics / a future `/skills` command so an
/// author sees exactly which SKILL.md parsed, which failed, and why.
public struct SkillState: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case ok, error }
    public let name: String
    public let location: String
    public let status: Status
    public let message: String?
}

/// Discovery of skills from two sources:
///
///   1. BUILTINS shipped in the AgentCore bundle (`Skills/builtin/<name>/SKILL.md`), read at
///      runtime from `Bundle.module`. Their `location` is a synthetic `kist:<name>/SKILL.md`
///      that `read_file` resolves against the embedded resources only.
///   2. PROJECT-LOCAL skills under the confinement root (`.kist/skills`, `.claude/skills`),
///      discovered + read entirely through `ConfinedRoot` — ZERO new filesystem surface.
///
/// GLOBAL user skills (e.g. `~/.kist/skills`, outside the project root) are intentionally NOT
/// discovered yet: reading them would require widening `read_file` past `ConfinedRoot`, which
/// is a security-sensitive change that gets its own increment + review. Builtin + project-local
/// already deliver the Claude-Code-parity story.
public enum SkillDiscovery {

    /// Directories under the project root scanned for project-local skills, in priority order.
    public static let projectSkillDirs = [".kist/skills", ".claude/skills"]

    /// Hard cap on a single SKILL.md (frontmatter + body). A skill is procedural text, not data;
    /// anything past this is a malformed/hostile file and is refused rather than read into memory.
    public static let maxSkillBytes = 1 << 20   // 1 MiB

    // MARK: Builtins

    /// Discover builtin skills embedded in the AgentCore resource bundle.
    public static func discoverBuiltins() -> ([Skill], [SkillState]) {
        guard let root = builtinRoot() else {
            // Fail-LOUD (autopsy 2026-08-25): an absent resource bundle would silently amputate
            // every builtin skill — the deploy copies the binary, and AgentCore_AgentCore.bundle
            // must travel beside it. Say so instead of quietly returning nothing.
            FileHandle.standardError.write(Data(
                "skills · builtin resource bundle missing beside the executable — builtin skills UNAVAILABLE (deploy must copy AgentCore_AgentCore.bundle)\n".utf8))
            return ([], [])
        }
        var skills: [Skill] = []
        var states: [SkillState] = []
        let fm = FileManager.default

        let subdirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        for dir in subdirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let name = dir.lastPathComponent
            let skillURL = dir.appendingPathComponent(Self.skillFileName)
            guard let data = try? Data(contentsOf: skillURL), data.count <= Self.maxSkillBytes,
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }
            let location = Skill.builtinPrefix + name + "/" + Self.skillFileName
            do {
                let skill = try Skill.parse(content: content, path: name, skillFilePath: location, builtin: true)
                if let err = skill.validate() {
                    states.append(SkillState(name: name, location: location, status: .error, message: err.description))
                } else {
                    skills.append(skill)
                    states.append(SkillState(name: skill.name, location: location, status: .ok, message: nil))
                }
            } catch {
                states.append(SkillState(name: name, location: location, status: .error, message: "\(error)"))
            }
        }
        return (skills, states)
    }

    /// Read a builtin SKILL.md (or a Tier-3 asset beside it) by its `kist:`-prefixed id. Rejects
    /// any `..` traversal; resolves ONLY within the embedded builtin subtree.
    public static func readBuiltin(_ id: String) throws -> String {
        guard id.hasPrefix(Skill.builtinPrefix) else { throw SkillError.notFound(id) }
        let rel = String(id.dropFirst(Skill.builtinPrefix.count))
        // Defense: no absolute paths, no parent traversal.
        let comps = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if rel.hasPrefix("/") || comps.contains("..") || comps.contains(".") || comps.isEmpty {
            throw SkillError.notFound(id)
        }
        guard let root = builtinRoot() else { throw SkillError.notFound(id) }
        var url = root
        for c in comps { url.appendPathComponent(c) }
        // Containment: resolve symlinks FIRST, then require the resolved path to stay under the
        // (also-resolved) builtin root by PATH COMPONENTS (not a string hasPrefix, which a sibling
        // like `<root>EVIL` or a case quirk could slip past), and read from the RESOLVED path — so
        // there is no window between the check and the open for a symlink swap (residual TOCTOU).
        let rootReal = root.resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathComponents.starts(with: rootReal.pathComponents) else {
            throw SkillError.notFound(id)
        }
        guard let data = try? Data(contentsOf: resolved), data.count <= Self.maxSkillBytes,
              let s = String(data: data, encoding: .utf8) else {
            throw SkillError.notFound(id)
        }
        return s
    }

    static func builtinRoot() -> URL? {
        let bundle = Bundle.module
        // SwiftPM copies `Skills/builtin` into the resource bundle preserving the `builtin` dir.
        if let url = bundle.url(forResource: "builtin", withExtension: nil) { return url }
        if let res = bundle.resourceURL {
            let candidate = res.appendingPathComponent("builtin")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: Project-local

    /// Discover project-local skills under `root`, reading exclusively through `confined`.
    /// Each `<dir>/<name>/SKILL.md` becomes a skill whose `location` is the project-relative
    /// path the model passes to `read_file` (already inside the confinement root).
    public static func discoverProjectLocal(confined: ConfinedRoot,
                                            trustStore: SkillTrustStore = SkillTrustStore()) -> ([Skill], [SkillState]) {
        var skills: [Skill] = []
        var states: [SkillState] = []

        for base in projectSkillDirs {
            let (exists, isDir) = (try? confined.fileType(base)) ?? (false, false)
            guard exists, isDir else { continue }
            let entries = (try? confined.entries(base)) ?? []
            for entry in entries.sorted(by: { $0.name < $1.name }) where entry.isDir {
                let name = entry.name
                let location = base + "/" + name + "/" + Self.skillFileName
                // Cap before reading: refuse an oversized SKILL.md instead of slurping it into memory.
                if let meta = try? confined.fileMetadata(location), meta.bytes > Self.maxSkillBytes {
                    states.append(SkillState(name: name, location: location, status: .error,
                                             message: "SKILL.md exceeds \(Self.maxSkillBytes) bytes"))
                    continue
                }
                guard let content = try? confined.readString(location) else { continue }
                do {
                    let parsed = try Skill.parse(content: content, path: base + "/" + name,
                                                 skillFilePath: location, builtin: false)
                    if let err = parsed.validate() {
                        states.append(SkillState(name: name, location: location, status: .error, message: err.description))
                    } else {
                        // Trust upgrade: a project skill is `.untrusted` by default; it becomes
                        // `.trusted` only when its CURRENT content hash is pinned in the trust store
                        // (editing it drops trust again — pin-by-content defeats benign-then-swap).
                        let trusted = trustStore.isPinned(name: parsed.name, hash: parsed.contentHash)
                        let skill = trusted ? parsed.withTrust(.trusted) : parsed
                        skills.append(skill)
                        let note = trusted ? nil : "untrusted (unpinned) — loads read-only until pinned"
                        states.append(SkillState(name: skill.name, location: location, status: .ok, message: note))
                    }
                } catch {
                    states.append(SkillState(name: name, location: location, status: .error, message: "\(error)"))
                }
            }
        }
        return (skills, states)
    }

    static let skillFileName = "SKILL.md"
}
