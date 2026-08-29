import Foundation

/// A compact, deterministic project picture for the Captain's planning pass.
/// It is intentionally bounded: enough evidence to choose models and scopes without
/// dumping the whole repo into a prompt.
public struct ProjectSnapshot: Sendable, Equatable {
    public struct ProviderCandidate: Sendable, Equatable {
        public let binding: ProviderBinding
        public let displayName: String
        public let capabilities: ModelCapabilities
        public let keyed: Bool

        public init(binding: ProviderBinding, displayName: String,
                    capabilities: ModelCapabilities, keyed: Bool) {
            self.binding = binding
            self.displayName = displayName
            self.capabilities = capabilities
            self.keyed = keyed
        }
    }

    public let repo: String
    public let trackedFileCount: Int
    public let directorySnapshot: String
    public let knownDirectories: Set<String>
    public let manifests: [String]
    public let testEntrypoints: [String]
    public let languages: [String]
    public let changedFiles: [String]
    public let providers: [ProviderCandidate]

    public init(repo: String, trackedFileCount: Int, directorySnapshot: String,
                knownDirectories: Set<String>, manifests: [String],
                testEntrypoints: [String], languages: [String],
                changedFiles: [String], providers: [ProviderCandidate]) {
        self.repo = repo
        self.trackedFileCount = trackedFileCount
        self.directorySnapshot = directorySnapshot
        self.knownDirectories = knownDirectories
        self.manifests = manifests
        self.testEntrypoints = testEntrypoints
        self.languages = languages
        self.changedFiles = changedFiles
        self.providers = providers
    }

    public static func capture(repo: String, registry: ProviderRegistry) -> ProjectSnapshot {
        let files = GitIsolation.trackedFiles(repo: repo)
        let scope = CaptainOrchestrator.deriveScopeContext(fromFiles: files)
        let manifests = files.filter(Self.isManifest).sorted()
        let tests = Self.testEntrypoints(from: files)
        let languages = Self.languages(from: files)
        let changed = Self.changedFiles(repo: repo)
        let providers = registry.providers.map { provider -> ProviderCandidate in
            let model = provider.defaultModel
            return ProviderCandidate(
                binding: ProviderBinding(providerId: provider.id, model: model.isEmpty ? nil : model),
                displayName: provider.name,
                capabilities: registry.capabilities(providerId: provider.id, model: model),
                keyed: registry.hasKey(for: provider)
            )
        }.filter { $0.keyed }

        return ProjectSnapshot(repo: repo, trackedFileCount: files.count,
                               directorySnapshot: scope.snapshot,
                               knownDirectories: scope.knownDirs,
                               manifests: manifests, testEntrypoints: tests,
                               languages: languages, changedFiles: changed,
                               providers: providers)
    }

    public var briefing: String {
        var lines: [String] = []
        lines.append("PROJECT SNAPSHOT")
        lines.append("tracked files: \(trackedFileCount)")
        if !languages.isEmpty { lines.append("languages: \(languages.joined(separator: ", "))") }
        if !manifests.isEmpty { lines.append("manifests: \(manifests.prefix(12).joined(separator: ", "))") }
        if !testEntrypoints.isEmpty { lines.append("tests: \(testEntrypoints.joined(separator: ", "))") }
        if !changedFiles.isEmpty { lines.append("changed files: \(changedFiles.prefix(20).joined(separator: ", "))") }
        if !providers.isEmpty {
            let names = providers.map { "\($0.binding.providerId):\($0.capabilities.summaryFlags.joined(separator: "+"))" }
            lines.append("available models: \(names.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func isManifest(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if ["Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "go.mod",
            "Gemfile", "Podfile", "test.sh", "Makefile"].contains(name) { return true }
        return path.hasSuffix(".xcodeproj/project.pbxproj") || path.hasSuffix(".xcworkspace/contents.xcworkspacedata")
    }

    private static func testEntrypoints(from files: [String]) -> [String] {
        var out: [String] = []
        let set = Set(files)
        if set.contains("test.sh") { out.append("./test.sh") }
        if set.contains("Package.swift") { out.append("swift test") }
        if set.contains("package.json") { out.append("npm test") }
        if set.contains("Cargo.toml") { out.append("cargo test") }
        if set.contains("go.mod") { out.append("go test ./...") }
        if files.contains(where: { $0.hasSuffix(".xcodeproj/project.pbxproj") }) { out.append("xcodebuild test") }
        return out
    }

    private static func languages(from files: [String]) -> [String] {
        let map: [String: String] = [
            "swift": "Swift", "js": "JavaScript", "ts": "TypeScript", "tsx": "TypeScript",
            "py": "Python", "rs": "Rust", "go": "Go", "java": "Java", "kt": "Kotlin",
            "c": "C", "cc": "C++", "cpp": "C++", "m": "Objective-C", "mm": "Objective-C++"
        ]
        var counts: [String: Int] = [:]
        for file in files {
            let ext = (file as NSString).pathExtension.lowercased()
            guard let lang = map[ext] else { continue }
            counts[lang, default: 0] += 1
        }
        return counts.sorted { a, b in
            a.value == b.value ? a.key < b.key : a.value > b.value
        }.prefix(6).map(\.key)
    }

    private static func changedFiles(repo: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", repo, "status", "--porcelain"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let text = String(line)
                guard text.count > 3 else { return nil }
                return String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .sorted()
    }
}

public struct ModelAssignmentDecision: Sendable, Equatable {
    public let taskTitle: String
    public let roles: RoleBindings
    public let worker: ProviderBinding
    public let confidence: Double
    public let reason: String
    public let capabilityTags: [String]

    public init(taskTitle: String, roles: RoleBindings, worker: ProviderBinding,
                confidence: Double, reason: String, capabilityTags: [String]) {
        self.taskTitle = taskTitle
        self.roles = roles
        self.worker = worker
        self.confidence = min(1, max(0, confidence))
        self.reason = reason
        self.capabilityTags = capabilityTags
    }

    public static func legacy(taskTitle: String, roles: RoleBindings) -> ModelAssignmentDecision {
        ModelAssignmentDecision(taskTitle: taskTitle, roles: roles, worker: roles.binding(for: .coder),
                                confidence: 0.5, reason: "legacy/static role binding",
                                capabilityTags: ["legacy"])
    }

    public var summary: String {
        let tags = capabilityTags.isEmpty ? "" : " [\(capabilityTags.joined(separator: ", "))]"
        return "\(taskTitle): worker=\(worker.providerId) planner=\(roles.binding(for: .planner).providerId) "
            + "coder=\(roles.binding(for: .coder).providerId) critic=\(roles.binding(for: .critic).providerId) "
            + "confidence=\(Int((confidence * 100).rounded()))% - \(reason)\(tags)"
    }
}

/// The Captain's single-turn (interactive) routing decision: the best worker binding for THIS turn plus
/// the task-profile capability flags, so the REPL can decide whether the signal is strong enough to switch
/// off the current model (its stability policy) rather than thrashing on every turn.
public struct InteractiveAssignment: Sendable, Equatable {
    public let binding: ProviderBinding
    public let reason: String
    public let confidence: Double
    public let wantsReasoning: Bool
    public let wantsVision: Bool
    public let prefersResearch: Bool
    public let wantsCoding: Bool     // EXPLICIT coding signal (keyword match), not the empty-tags default
    public let tags: [String]

    public init(binding: ProviderBinding, reason: String, confidence: Double,
                wantsReasoning: Bool, wantsVision: Bool, prefersResearch: Bool,
                wantsCoding: Bool, tags: [String]) {
        self.binding = binding
        self.reason = reason
        self.confidence = min(1, max(0, confidence))
        self.wantsReasoning = wantsReasoning
        self.wantsVision = wantsVision
        self.prefersResearch = prefersResearch
        self.wantsCoding = wantsCoding
        self.tags = tags
    }
}

public struct AssignedFleetTask: Sendable, Equatable {
    public let subtask: FleetSubtask
    public let roles: RoleBindings
    public let assignment: ModelAssignmentDecision

    public init(subtask: FleetSubtask, roles: RoleBindings, assignment: ModelAssignmentDecision) {
        self.subtask = subtask
        self.roles = roles
        self.assignment = assignment
    }
}

public enum ModelAssignmentEngine {
    public static func assign(subtasks: [FleetSubtask], snapshot: ProjectSnapshot,
                              defaultRoles: RoleBindings,
                              learning: ModelAssignmentLearningContext? = nil) -> [AssignedFleetTask] {
        subtasks.map { subtask in
            let profile = profile(for: subtask)
            let language = snapshot.languages.first
            let planner = choose(for: .planner, profile: profile, snapshot: snapshot,
                                 fallback: defaultRoles.binding(for: .planner),
                                 learning: learning, language: language)
            let coder = choose(for: .coder, profile: profile, snapshot: snapshot,
                               fallback: defaultRoles.binding(for: .coder),
                               learning: learning, language: language)
            let critic = choose(for: .critic, profile: profile, snapshot: snapshot,
                                fallback: defaultRoles.binding(for: .critic), avoid: coder.binding.providerId,
                                learning: learning, language: language)
            let worker = choose(for: profile.prefersResearch ? .worker : .coder, profile: profile,
                                snapshot: snapshot, fallback: defaultRoles.binding(for: .worker),
                                learning: learning, language: language)

            var roles = RoleBindings(default: worker.binding)
                .binding(.planner, to: planner.binding)
                .binding(.worker, to: worker.binding)
                .binding(.coder, to: coder.binding)
                .binding(.critic, to: critic.binding)

            // Keep user-provided heterogeneous teams as a floor when the scorer has no candidates.
            if snapshot.providers.isEmpty { roles = defaultRoles }

            let best = max(planner.score, coder.score, critic.score, worker.score)
            let confidence = min(0.95, max(0.45, best / 100.0))
            var tags = profile.tags
            let learningNotes = [planner.learningEvidence, coder.learningEvidence,
                                 critic.learningEvidence, worker.learningEvidence]
                .compactMap { $0?.shortDescription }
            if learningNotes.contains(where: { $0.contains("promoted") }) { tags.append("learning") }
            let learningReason = learningNotes.isEmpty ? "" : "; learning: " + learningNotes.joined(separator: ", ")
            let reason = "\(profile.reason); project: \(language ?? "unknown")\(learningReason)"
            let decision = ModelAssignmentDecision(taskTitle: subtask.title, roles: roles,
                                                   worker: worker.binding, confidence: confidence,
                                                   reason: reason, capabilityTags: tags)
            return AssignedFleetTask(subtask: subtask, roles: roles, assignment: decision)
        }
    }

    /// INTERACTIVE (single-turn) assignment: pick the best worker model for ONE chat/build turn using the
    /// SAME project-data + learned-outcome scoring the fleet uses per subtask — so the REPL routes on the
    /// Captain's intelligence, not a keyword heuristic. Returns the chosen binding, a human reason, a
    /// confidence, and the task-profile capability flags so the CALLER can apply its own stability policy
    /// (e.g. only switch off the current model when a real capability signal is present — no churn on
    /// ordinary turns). Empty snapshot (no keyed providers) ⇒ the fallback, unchanged.
    /// `unavailable` is the live availability gate (cooldown + daemon health). Candidates that are
    /// known down/cooling are skipped during scoring, and an unavailable FALLBACK loses most of its
    /// incumbent baseline so any warm candidate can out-score it — without this, the selector kept
    /// nominating a dead session default and the caller's stability guard pinned it forever
    /// (routing audit 2026-08-25). Fail-open: with every candidate unavailable, the fallback stands.
    public static func assignInteractive(turn: String, snapshot: ProjectSnapshot,
                                         fallback: ProviderBinding,
                                         learning: ModelAssignmentLearningContext? = nil,
                                         unavailable: (String) -> Bool = { _ in false }) -> InteractiveAssignment {
        let trimmed = turn.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtask = FleetSubtask(title: String(trimmed.prefix(80)), intent: trimmed)
        let prof = profile(for: subtask)
        guard !snapshot.providers.isEmpty else {
            return InteractiveAssignment(binding: fallback, reason: "no project candidates — staying put",
                                         confidence: 0.5, wantsReasoning: prof.wantsReasoning,
                                         wantsVision: prof.wantsVision, prefersResearch: prof.prefersResearch,
                                         wantsCoding: prof.wantsCoding, tags: prof.tags)
        }
        // Select the SAME worker role the fleet uses, and derive confidence from THAT binding's OWN score —
        // not the cross-role aggregate (a strong critic/planner must not inflate a weak worker's confidence,
        // which is the number the REPL's switch floor reads).
        let language = snapshot.languages.first
        let worker = choose(for: prof.prefersResearch ? .worker : .coder, profile: prof, snapshot: snapshot,
                            fallback: fallback, learning: learning, language: language,
                            unavailable: unavailable)
        let confidence = min(0.95, max(0.45, worker.score / 100.0))
        let evidence = worker.learningEvidence.map { "; learning: \($0.shortDescription)" } ?? ""
        let reason = "\(prof.reason); project: \(language ?? "unknown")\(evidence)"
        return InteractiveAssignment(binding: worker.binding, reason: reason, confidence: confidence,
                                     wantsReasoning: prof.wantsReasoning, wantsVision: prof.wantsVision,
                                     prefersResearch: prof.prefersResearch, wantsCoding: prof.wantsCoding,
                                     tags: prof.tags)
    }

    private enum RoleTarget {
        case planner, worker, coder, critic

        var learningRole: String {
            switch self {
            case .planner: return "planner"
            case .worker: return "worker"
            case .coder: return "coder"
            case .critic: return "critic"
            }
        }
    }

    private struct TaskProfile {
        var prefersResearch: Bool
        var wantsVision: Bool
        var wantsReasoning: Bool
        var wantsCoding: Bool        // EXPLICIT coding signal (keyword match), NOT the empty-tags default
        var tags: [String]
        var reason: String
    }

    private struct Scored {
        var binding: ProviderBinding
        var score: Double
        var learningEvidence: CaptainLearningSummary?
    }

    private static func profile(for task: FleetSubtask) -> TaskProfile {
        let text = ([task.title, task.intent, task.acceptanceCriterion] + task.scopeGlobs)
            .joined(separator: " ").lowercased()
        var tags: [String] = []
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        let research = has(["research", "docs", "document", "url", "web", "compare", "market", "strategy"])
        let vision = has(["image", "screenshot", "video", "audio", "pdf", "media", "visual"])
        let coding = has(["implement", "code", "coding", "swift", "source", "edit", "build", "fix"])
        let reasoning = has(["architect", "design", "planner", "algorithm", "concurrency", "refactor",
                             "schema", "parser", "compiler", "orchestrat", "routing"])
        if research { tags.append("research") }
        if vision { tags.append("vision") }
        if coding { tags.append("coding") }
        if reasoning { tags.append("reasoning") }
        if has(["test", "verify", "review", "audit"]) { tags.append("verification") }
        if tags.isEmpty { tags.append("coding") }
        return TaskProfile(prefersResearch: research, wantsVision: vision, wantsReasoning: reasoning,
                           wantsCoding: coding, tags: tags, reason: tags.joined(separator: "+"))
    }

    private static func choose(for role: RoleTarget, profile: TaskProfile, snapshot: ProjectSnapshot,
                               fallback: ProviderBinding, avoid: String? = nil,
                               learning: ModelAssignmentLearningContext? = nil,
                               language: String? = nil,
                               unavailable: (String) -> Bool = { _ in false }) -> Scored {
        let fallbackEvidence = learning?.evidence(providerId: fallback.providerId, role: role.learningRole,
                                                  taskTags: profile.tags, language: language)
        // A down/cooling incumbent keeps only a token baseline: any warm keyed candidate (base 40+)
        // out-scores it, but with nothing warm at all it still stands (fail-open last resort).
        let fallbackBase: Double = unavailable(fallback.providerId) ? 20 : 45
        var best = Scored(binding: fallback,
                          score: fallbackBase + (fallbackEvidence?.scoreBoost ?? 0),
                          learningEvidence: fallbackEvidence)
        var bestWarm: Scored?
        for candidate in snapshot.providers {
            // Known-unavailable candidates never compete — selecting one guarantees a dead turn.
            if unavailable(candidate.binding.providerId) { continue }
            let evidence = learning?.evidence(providerId: candidate.binding.providerId,
                                              role: role.learningRole,
                                              taskTags: profile.tags,
                                              language: language)
            let score = score(candidate, for: role, profile: profile,
                              defaultProvider: fallback.providerId, avoid: avoid,
                              learningEvidence: evidence)
            let scored = Scored(binding: candidate.binding, score: score, learningEvidence: evidence)
            if score > (bestWarm?.score ?? -.infinity) { bestWarm = scored }
            if score > best.score { best = scored }
        }
        // A down incumbent may only stand when EVERY candidate is also unavailable (Codex P2,
        // 2026-08-25: a promoted scoreBoost could hold a dead fallback above a warm candidate —
        // reduced baseline + boost still out-scored a minimal-capability live model). If anything
        // warm exists, the best warm candidate wins outright.
        if unavailable(fallback.providerId), best.binding == fallback, let bestWarm {
            return bestWarm
        }
        return best
    }

    private static func score(_ candidate: ProjectSnapshot.ProviderCandidate, for role: RoleTarget,
                              profile: TaskProfile, defaultProvider: String, avoid: String?,
                              learningEvidence: CaptainLearningSummary?) -> Double {
        let id = candidate.binding.providerId.lowercased()
        let model = (candidate.binding.model ?? "").lowercased()
        let caps = candidate.capabilities
        // CONFIDENCE-WEIGHTED PRIOR (router audit 2026-08-15, fix #1: "let evidence DRIVE, not just nudge").
        // The hardcoded model-NAME preference in the switch below is a COLD-START PRIOR, not a permanent thumb on
        // the scale — it FADES as measured evidence for THIS candidate accumulates, so a proven model wins on its
        // record and a name-favored model with a poor record loses its artificial edge. (Before this, `scoreBoost`
        // was `max(0, …)` and 0 until promoted, so a bad record could never overcome a name prior — evidence could
        // only reward, never demote.) With no evidence the prior holds in FULL ⇒ routing is identical to before
        // until the scorecard has something to say. See `namePriorWeight(samples:)`.
        let namePrior = namePriorWeight(samples: learningEvidence?.samples ?? 0)
        var score: Double = candidate.keyed ? 40 : 0
        if id == defaultProvider.lowercased() { score += 4 }
        if let avoid, id == avoid.lowercased() { score -= 8 }
        if let ctx = caps.contextWindowTokens { score += min(12, Double(ctx) / 100_000.0) }
        if caps.nativeTools { score += 5 }
        if caps.structuredOutput { score += 4 }
        if profile.wantsReasoning && caps.reasoning { score += 12 }
        if profile.wantsVision && (caps.vision || caps.video || caps.audio) { score += 18 }
        if profile.prefersResearch && (caps.grounding || caps.urlContext || caps.deepResearch) { score += 16 }
        if model.contains("flash") || model.contains("mini") || model.contains("lite") { score += role == .worker ? 4 : -3 }
        score += learningEvidence?.scoreBoost ?? 0

        switch role {
        case .planner:
            score += preference(id, ["openai": 12, "gemini": 11, "mimo": 10, "deepseek": 9, "anthropic": 8]) * namePrior
            if caps.reasoning { score += 8 }
        case .worker:
            score += preference(id, ["deepseek": 11, "mimo": 10, "qwen": 9, "gemini": 8, "ollama": 6, "mlx": 6]) * namePrior
            if profile.prefersResearch { score += preference(id, ["gemini": 10, "openai": 8, "perplexity": 14]) * namePrior }
        case .coder:
            score += preference(id, ["deepseek": 14, "mimo": 13, "qwen": 10, "openai": 9, "anthropic": 8, "mlx": 7]) * namePrior
            if caps.codeExecution { score += 8 }
        case .critic:
            score += preference(id, ["gemini": 13, "openai": 12, "anthropic": 11, "deepseek": 8, "mimo": 7]) * namePrior
            if caps.reasoning { score += 7 }
        }
        return score
    }

    private static func preference(_ id: String, _ table: [String: Double]) -> Double {
        for (needle, value) in table where id.contains(needle) { return value }
        return 0
    }

    /// Confidence weight on the model-NAME preference prior: 1.0 at cold start (no samples ⇒ the prior fully
    /// holds and routing is unchanged from before the scorecard existed), decaying toward 0 as measured evidence
    /// accumulates so the EARNED signal (`scoreBoost`) takes over. `samples/(samples+K)` shrinkage with K=8 ⇒
    /// half weight by ~8 runs, ~20% by ~32. Clamped to [0,1]; negative input is treated as cold start. Internal
    /// so the decay curve + the cold-start fail-safe are unit-testable directly.
    static func namePriorWeight(samples: Int) -> Double {
        let s = Double(max(0, samples))
        return 1.0 - s / (s + 8.0)
    }
}
