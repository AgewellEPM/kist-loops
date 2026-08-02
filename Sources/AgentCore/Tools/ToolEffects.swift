import Foundation

/// The build-relevant effects observed for one tool invocation.
///
/// This is deliberately stored beside an `ActionRecord` instead of being rediscovered independently by
/// every consumer. The observation describes what a SUCCESSFUL invocation would have done; callers must
/// still consult `ActionRecord.success` before treating it as progress or verification evidence.
public struct ToolEffectObservation: Sendable, Equatable, Codable {
    public enum Mutation: String, Sendable, Codable {
        case none
        case nonSource
        case source
        /// A known mutator whose target cannot be classified. Verification stays conservative.
        case unknownTarget
    }

    public enum Verification: String, Sendable, Codable {
        case none
        /// A command ran, but it was not a build/test/typecheck/lint command.
        case nonVerifyingCommand
        case buildOrTest
    }

    /// Whether a mutation was actually observed or is only possible from the invocation. Shell and opaque
    /// local calls are `mayMutate` unless a tool returns concrete change evidence. This distinction
    /// prevents a no-op opaque command from satisfying a promised-deliverable contract.
    public enum MutationEvidence: String, Sendable, Codable {
        case none
        case mayMutate
        case confirmed
    }

    /// Useful forward progress that is neither a filesystem mutation nor execution evidence. Keeping
    /// this separate prevents delegation from accidentally satisfying the verify-after-edit gate.
    public enum Progress: String, Sendable, Codable {
        case none
        case delegation
        case taskBoard
        case memory
        case research
        case evidence
        case externalState
        case artifact
    }

    public let mutation: Mutation
    public let verification: Verification
    public let progress: Progress
    public let mutationEvidence: MutationEvidence

    public init(mutation: Mutation = .none, verification: Verification = .none,
                progress: Progress = .none, mutationEvidence: MutationEvidence? = nil) {
        self.mutation = mutation
        self.verification = verification
        self.progress = progress
        self.mutationEvidence = mutationEvidence ?? Self.defaultEvidence(for: mutation)
    }

    private enum CodingKeys: String, CodingKey { case mutation, verification, progress, mutationEvidence }

    /// `progress` and `mutationEvidence` were added after effect observations first shipped. Defaulting
    /// missing fields keeps old checkpoints/replays readable without upgrading legacy intent to proof.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mutation = try values.decodeIfPresent(Mutation.self, forKey: .mutation) ?? .none
        verification = try values.decodeIfPresent(Verification.self, forKey: .verification) ?? .none
        progress = try values.decodeIfPresent(Progress.self, forKey: .progress) ?? .none
        mutationEvidence = try values.decodeIfPresent(MutationEvidence.self, forKey: .mutationEvidence)
            ?? (mutation == .none ? .none : .mayMutate)
    }

    private static func defaultEvidence(for mutation: Mutation) -> MutationEvidence {
        switch mutation {
        case .none: return .none
        case .unknownTarget: return .mayMutate
        case .source, .nonSource: return .confirmed
        }
    }

    /// Only concrete observed changes fulfill a mutation outcome. An unknown target remains possible,
    /// never confirmed, even if malformed legacy data tried to label its evidence confirmed.
    public var confirmsMutation: Bool {
        mutationEvidence == .confirmed && mutation != .none && mutation != .unknownTarget
    }

    /// Concrete progress for a build turn. A generic successful shell command is intentionally absent:
    /// `ls`, `pwd`, and `echo` are observations, not progress. A successful mutation or real verifier is.
    public var advancesBuild: Bool { confirmsMutation || verification == .buildOrTest }

    /// Fleet delegation is real progress for a fleet turn, but deliberately remains neither a mutation
    /// nor verification evidence. Other intents still require their own concrete progress.
    public func advances(intent: TaskBrief.Intent?) -> Bool {
        advancesBuild || (intent == .fleet && progress == .delegation)
    }

    /// Source and unclassifiable mutations fail strict; clearly documentary/config/data mutations do not.
    public var requiresBuildVerification: Bool {
        mutation == .source || mutation == .unknownTarget
    }

    public static let none = ToolEffectObservation()
}

/// One canonical, argument-aware catalog for effects that matter to build progress and completion.
/// Trajectory analysis and completion verification consume its observation rather than maintaining
/// separate tool-name sets that inevitably drift.
public enum ToolEffectCatalog {
    /// Public for compatibility projections only. Decisions should use `observe` because effects such as
    /// `run_command` and `custom_tool` depend on the invocation's arguments.
    public static let knownMutationTools: Set<String> = [
        "write_file", "edit_file", "apply_patch", "notebook_edit", "move_file",
        "make_dir", "create_directory", "ast_grep_apply", "custom_tool",
        "generate_image", "edit_image", "generate_audio", "generate_video", "extract_clip",
        "translate_document", "watch_video", "live_screen_watch",
    ]
    public static let knownCommandTools: Set<String> = ["run_command"]

    private static let pathMutationTools: Set<String> = ["write_file", "edit_file"]
    private static let directoryMutationTools: Set<String> = ["make_dir", "create_directory"]
    private static let nonSourceExtensions: Set<String> = [
        "md", "markdown", "mdx", "rst", "adoc", "org", "txt", "text",
        "json", "yaml", "yml", "toml", "cfg", "conf", "ini", "env", "properties", "plist",
        "lock", "csv", "tsv", "log", "gitignore", "gitattributes", "editorconfig", "dockerignore",
        "license", "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "pdf", "doc", "docx",
        "xls", "xlsx", "ppt", "pptx", "wav", "mp3", "m4a", "aac", "flac", "ogg", "mp4", "mov",
        "m4v", "avi", "webm",
    ]
    private static let nonSourceBasenames: Set<String> = [
        "license", "copying", "notice", "authors", "contributors", "changelog",
        ".gitignore", ".gitattributes", ".editorconfig", ".dockerignore", ".env",
    ]
    /// These files are executable inputs to builds, dependency resolution, tests, or CI. Treating every
    /// JSON/TOML/YAML/lock file as documentary let a turn rewrite its own oracle and finish unverified.
    private static let verificationRequiredBasenames: Set<String> = [
        "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
        "bun.lock", "bun.lockb", "pyproject.toml", "setup.cfg", "tox.ini", "pytest.ini",
        "cargo.toml", "cargo.lock", "go.mod", "go.sum", "gemfile", "gemfile.lock",
        "podfile", "podfile.lock", "cartfile", "cartfile.resolved", "makefile", "gnumakefile",
        "cmakelists.txt", "gradle.properties", "pom.xml", "build.xml", "project.pbxproj",
        "tsconfig.json", "jsconfig.json", "dockerfile", "docker-compose.yml", "docker-compose.yaml",
        "compose.yml", "compose.yaml",
    ]

    /// Classify a live invocation from its complete arguments, before trajectory fingerprints truncate
    /// values. This is the authoritative path for new records.
    public static func observe(tool: String, arguments: [String: Any],
                               outcomeMetadata: [String: String]? = nil) -> ToolEffectObservation {
        // Explicit filesystem tools can prove a delta, but only from their post-call result. Missing
        // metadata (including old checkpoints) is possible intent, never confirmation.
        if confirmedChangeTools.contains(tool) {
            let classified: ToolEffectObservation
            if pathMutationTools.contains(tool) {
                classified = mutationObservation(paths: stringValues(["path", "file"], in: arguments))
            } else if directoryMutationTools.contains(tool) {
                classified = ToolEffectObservation(mutation: .nonSource)
            } else if tool == "notebook_edit" {
                classified = ToolEffectObservation(mutation: .source)
            } else if tool == "apply_patch" {
                classified = mutationObservation(paths: patchPaths(arguments["patch"] as? String ?? ""))
            } else { // move_file
                classified = mutationObservation(
                    paths: stringValues(["from", "to", "path", "file"], in: arguments))
            }
            guard outcomeMetadata?["changed"] != "false" else { return .none }
            let evidence: ToolEffectObservation.MutationEvidence =
                outcomeMetadata?["changed"] == "true" && classified.mutation != .unknownTarget
                    ? .confirmed : .mayMutate
            return ToolEffectObservation(mutation: classified.mutation,
                                         verification: classified.verification,
                                         progress: classified.progress,
                                         mutationEvidence: classified.mutation == .none
                                            ? ToolEffectObservation.MutationEvidence.none : evidence)
        }
        if mediaArtifactTools.contains(tool) {
            // A media/output invocation is only a possible mutation until the BUILT-IN tool returns
            // evidence for the exact normalized, confined target it snapshotted before and after. Model
            // arguments alone are never proof (and default output paths are absent from those arguments).
            let keys: [String]
            switch tool {
            case "translate_document": keys = ["output", "out"]
            case "watch_video", "live_screen_watch": keys = ["out_dir"]
            default: keys = ["out", "output"]
            }
            let predicted = mutationObservation(paths: stringValues(keys, in: arguments))
            // A successful built-in that explicitly observed no delta cannot satisfy a mutation contract,
            // even if it predates the richer target metadata below.
            if outcomeMetadata?["changed"] == "false" {
                return ToolEffectObservation(progress: .artifact)
            }
            guard let metadata = outcomeMetadata,
                  metadata["artifact_confined"] == "true",
                  let resultPath = metadata["artifact_path"],
                  isNormalizedRelativeArtifactPath(resultPath) else {
                return ToolEffectObservation(mutation: predicted.mutation, progress: .artifact,
                                             mutationEvidence: predicted.mutation == .none
                                                ? ToolEffectObservation.MutationEvidence.none : .mayMutate)
            }

            let expectedKind = (tool == "watch_video" || tool == "live_screen_watch")
                ? "directory" : "file"
            guard metadata["artifact_kind"] == expectedKind else {
                return ToolEffectObservation(mutation: predicted.mutation, progress: .artifact,
                                             mutationEvidence: predicted.mutation == .none
                                                ? ToolEffectObservation.MutationEvidence.none : .mayMutate)
            }
            guard metadata["changed"] != "false" else {
                return ToolEffectObservation(progress: .artifact)
            }
            let classified = expectedKind == "directory"
                ? ToolEffectObservation(mutation: .nonSource)
                : mutationObservation(paths: [resultPath])
            let evidence: ToolEffectObservation.MutationEvidence =
                metadata["changed"] == "true" && classified.mutation != .unknownTarget
                    ? .confirmed : .mayMutate
            return ToolEffectObservation(mutation: classified.mutation, progress: .artifact,
                                         mutationEvidence: classified.mutation == .none
                                            ? ToolEffectObservation.MutationEvidence.none : evidence)
        }
        // External MCP servers execute outside AgentCore's filesystem boundary. Only the strict shared
        // read-only classifier proves inspection; other calls are external-state progress, not evidence
        // that this workspace changed.
        if ReversibilityClassifier.isMCPTool(tool) {
            return ReversibilityClassifier.isReadOnlyMCPTool(tool)
                ? ToolEffectObservation(progress: .evidence)
                : ToolEffectObservation(progress: .externalState)
        }
        switch tool {
        case "ast_grep_apply":
            // The default `.` and directory targets may rewrite many source types, so missing/extensionless
            // paths stay unknown rather than being laundered as non-source. Until the external process
            // reports an actual changed-file set, this remains possible rather than confirmed.
            let observed = mutationObservation(paths: stringValues(["path"], in: arguments))
            return ToolEffectObservation(mutation: observed.mutation, mutationEvidence: .mayMutate)
        case "custom_tool":
            switch (arguments["action"] as? String)?.lowercased() {
            case "create": return ToolEffectObservation(mutation: .source, mutationEvidence: .mayMutate)
            case "list": return .none
            case "run": return ToolEffectObservation(mutation: .unknownTarget)
            default: return ToolEffectObservation(mutation: .unknownTarget)
            }
        case "run_command":
            let observed = CommandClassifier.observe(arguments: arguments)
            if arguments["background"] as? Bool == true {
                return ToolEffectObservation(mutation: observed.mutation, progress: .externalState,
                                             mutationEvidence: observed.mutation == .none
                                                ? ToolEffectObservation.MutationEvidence.none : .mayMutate)
            }
            return observed
        case "computer_control":
            let action = (arguments["action"] as? String)?.lowercased() ?? ""
            if action == "clean_desktop" {
                guard arguments["dry_run"] as? Bool != true,
                      outcomeMetadata?["dry_run"] != "true",
                      Int(outcomeMetadata?["count"] ?? "0") ?? 0 > 0 else { return .none }
            }
            return ["open_app", "open_url", "youtube_search", "clean_desktop"].contains(action)
                ? ToolEffectObservation(progress: .externalState) : .none
        case "desktop_control":
            let action = (arguments["action"] as? String)?.lowercased() ?? ""
            return ["move", "click", "double_click", "right_click", "drag", "type", "key", "scroll"]
                .contains(action) ? ToolEffectObservation(progress: .externalState) : .none
        case "ax_press":
            return outcomeMetadata?["pressed"] == "true"
                ? ToolEffectObservation(progress: .externalState) : .none
        case "tap", "point_click":
            let found = Int(outcomeMetadata?["found"] ?? "0") ?? 0
            return found > 0 ? ToolEffectObservation(progress: .externalState) : .none
        case "spawn_agent", "spawn_specialist":
            return ToolEffectObservation(progress: .delegation)
        case "tasks":
            let action = ((arguments["action"] as? String) ?? "list").lowercased()
            return ["list", "validate", "check"].contains(action)
                ? .none : ToolEffectObservation(progress: .taskBoard)
        case "cortex":
            return (arguments["action"] as? String)?.lowercased() == "recall"
                ? .none : ToolEffectObservation(progress: .memory)
        case "remember":
            return ToolEffectObservation(progress: .memory)
        case "recall":
            return .none
        case "research_run":
            let action = (arguments["action"] as? String)?.lowercased() ?? ""
            let gatherers: Set<String> = ["search", "fetch", "browse", "visual", "context", "estate"]
            return gatherers.contains(action) && outcomeMetadata?["evidence_id"] != nil
                ? ToolEffectObservation(progress: .research) : .none
        case "jeeves_research", "web_search":
            return ToolEffectObservation(progress: .research)
        case "fetch_url", "browse", "read_file", "search_code", "ast_grep", "symbols":
            return ToolEffectObservation(progress: .evidence)
        case "job":
            let action = (arguments["action"] as? String)?.lowercased() ?? "list"
            if ["kill", "stop", "terminate"].contains(action) {
                return ToolEffectObservation(progress: .externalState)
            }
            return ["output", "read", "logs"].contains(action)
                ? ToolEffectObservation(progress: .evidence) : .none
        case "context_brain", "analyze_media", "view_image", "read_spreadsheet", "query_data",
             "generate", "grounded_answer", "visual_verify":
            return ToolEffectObservation(progress: .evidence)
        default:
            return .none
        }
    }

    private static let confirmedChangeTools: Set<String> = [
        "write_file", "edit_file", "apply_patch", "notebook_edit", "move_file",
        "make_dir", "create_directory",
    ]
    private static let mediaArtifactTools: Set<String> = [
        "generate_image", "edit_image", "generate_audio", "generate_video", "extract_clip",
        "translate_document", "watch_video", "live_screen_watch",
    ]

    /// Backward-compatible inference for checkpoints created before effect observations were recorded.
    /// Unknown paths stay strict, while generic commands remain non-progress unless they are recognizable
    /// build/test commands. Consumers call this only when `ActionRecord.effectObservation == nil`.
    public static func inferLegacy(tool: String, argsFingerprint: String) -> ToolEffectObservation {
        if tool == "run_command" {
            return CommandClassifier.observe(argsFingerprint)
        }
        return observe(tool: tool, arguments: fingerprintArguments(argsFingerprint))
    }

    /// An untruncated command representation in the shapes `CommandClassifier` accepts.
    static func commandFingerprint(_ arguments: [String: Any]) -> String {
        let executable = arguments["executable"] as? String
        let command = arguments["command"] as? String
        if executable?.isEmpty == false, command?.isEmpty == false {
            return TrajectoryAnalyzer.fingerprint(arguments)
        }
        if let executable, !executable.isEmpty {
            let argv = (arguments["args"] as? [String]) ?? []
            let cwd = (arguments["cwd"] as? String).map { "&cwd=\($0)" } ?? ""
            return "executable=\(executable)&args=\(argv)\(cwd)"
        }
        if let command, !command.isEmpty { return "command=\(command)" }
        return TrajectoryAnalyzer.fingerprint(arguments)
    }

    static func mutationObservation(paths: [String]) -> ToolEffectObservation {
        guard !paths.isEmpty else { return ToolEffectObservation(mutation: .unknownTarget) }
        let kinds = paths.map(mutationKind(forPath:))
        if kinds.contains(.source) { return ToolEffectObservation(mutation: .source) }
        if kinds.contains(.unknownTarget) { return ToolEffectObservation(mutation: .unknownTarget) }
        if kinds.allSatisfy({ $0 == .none }) { return .none }
        return ToolEffectObservation(mutation: .nonSource)
    }

    static func mutationKind(forPath rawPath: String) -> ToolEffectObservation.Mutation {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path != ".", !path.hasSuffix("/") else { return .unknownTarget }
        if path == "/dev/null" || path == "/dev/stdout" || path == "/dev/stderr"
            || path.hasPrefix("/dev/fd/") {
            return .none
        }
        let basename = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        if verificationRequiredBasenames.contains(basename)
            || (basename.hasPrefix("tsconfig.") && basename.hasSuffix(".json"))
            || (basename.hasPrefix("requirements") && basename.hasSuffix(".txt"))
            || normalized.contains("/.github/workflows/") || normalized.hasPrefix(".github/workflows/") {
            return .source
        }
        if nonSourceBasenames.contains(basename)
            || basename.hasPrefix("readme.") || basename == "readme"
            || basename.hasPrefix("license.") {
            return .nonSource
        }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard !ext.isEmpty else { return .unknownTarget }
        return nonSourceExtensions.contains(ext) ? .nonSource : .source
    }

    private static func patchPaths(_ patch: String) -> [String] {
        let prefixes = ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "]
        return patch.components(separatedBy: .newlines).compactMap { line in
            for prefix in prefixes where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    private static func stringValues(_ keys: [String], in arguments: [String: Any]) -> [String] {
        keys.compactMap { arguments[$0] as? String }.filter { !$0.isEmpty }
    }

    /// Artifact evidence is emitted by confined built-ins as a canonical project-relative path. Keep
    /// this strict so forged/legacy metadata cannot turn an absolute or ambiguous target into proof.
    private static func isNormalizedRelativeArtifactPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("//") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Decode the stable `k=v&...` part of an old record. Values were historically truncated, but path
    /// classification is still useful when present; missing/partial values naturally fail strict.
    private static func fingerprintArguments(_ fingerprint: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for field in fingerprint.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            result[String(pair[0])] = String(pair[1])
        }
        return result
    }
}
