import Foundation

public enum CaptainLearningSource: String, Codable, Sendable, Equatable {
    case benchmark
    case liveEval
    case fleetSignoff
}

/// One measured outcome the Captain can learn from.
///
/// Samples are evidence, not authority. The assignment engine treats sparse records as shadow data and
/// promotes only repeated, verified wins for the same role/task shape.
public struct CaptainLearningSample: Codable, Sendable, Equatable {
    public let taskSignature: String
    public let taskTags: [String]
    public let language: String?
    public let role: String
    public let providerId: String
    public let model: String?
    public let source: CaptainLearningSource
    public let success: Bool
    public let judgeScore: Double?
    public let tokens: Int
    public let latencyMs: Int
    public let toolFailures: Int
    public let atEpoch: Double
    // Failure/loop dimensions (added 2026-08-05 for the per-model scorecard). All optional-with-default so
    // pre-existing .kist/captain-learning.jsonl lines still decode (see the custom init(from:)).
    /// Categorized reason a run failed: providerFault|flaky|stuck|runawayLoop|failureSpike|noToolProgress|nearBudget|toolFailures. nil ⇒ succeeded / no fault.
    public let failureReason: String?
    /// Which phase failed: plan|act|verify. nil ⇒ n/a.
    public let failedAt: String?
    /// The loop/stall signal kinds observed this run (TrajectoryIssue.Kind raw values) — the "what/why" of a loop.
    public let loopKinds: [String]
    /// The run was judged stuck by the progress governor.
    public let wasStuck: Bool
    /// Fraction of this run's tool calls that failed (0…1).
    public let failureRate: Double

    public init(taskSignature: String, taskTags: [String], language: String?, role: String,
                providerId: String, model: String?, source: CaptainLearningSource,
                success: Bool, judgeScore: Double? = nil, tokens: Int = 0,
                latencyMs: Int = 0, toolFailures: Int = 0, atEpoch: Double,
                failureReason: String? = nil, failedAt: String? = nil,
                loopKinds: [String] = [], wasStuck: Bool = false, failureRate: Double = 0) {
        self.taskSignature = Self.normalizeSignature(taskSignature)
        self.taskTags = Array(Set(taskTags.map { $0.lowercased() })).sorted()
        self.language = language
        self.role = role.lowercased()
        self.providerId = providerId
        self.model = model
        self.source = source
        self.success = success
        self.judgeScore = judgeScore.map { min(1, max(0, $0)) }
        self.tokens = max(0, tokens)
        self.latencyMs = max(0, latencyMs)
        self.toolFailures = max(0, toolFailures)
        self.atEpoch = atEpoch
        self.failureReason = failureReason
        self.failedAt = failedAt
        self.loopKinds = loopKinds
        self.wasStuck = wasStuck
        self.failureRate = min(1, max(0, failureRate))
    }

    /// Backward-compatible decode: old JSONL lines lack the failure/loop fields → default them, so the
    /// whole (already-populated) store still reads instead of throwing and coming back empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskSignature = try c.decode(String.self, forKey: .taskSignature)
        taskTags = try c.decode([String].self, forKey: .taskTags)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        role = try c.decode(String.self, forKey: .role)
        providerId = try c.decode(String.self, forKey: .providerId)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        source = try c.decode(CaptainLearningSource.self, forKey: .source)
        success = try c.decode(Bool.self, forKey: .success)
        judgeScore = try c.decodeIfPresent(Double.self, forKey: .judgeScore)
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        latencyMs = try c.decodeIfPresent(Int.self, forKey: .latencyMs) ?? 0
        toolFailures = try c.decodeIfPresent(Int.self, forKey: .toolFailures) ?? 0
        atEpoch = try c.decode(Double.self, forKey: .atEpoch)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        failedAt = try c.decodeIfPresent(String.self, forKey: .failedAt)
        loopKinds = try c.decodeIfPresent([String].self, forKey: .loopKinds) ?? []
        wasStuck = try c.decodeIfPresent(Bool.self, forKey: .wasStuck) ?? false
        failureRate = try c.decodeIfPresent(Double.self, forKey: .failureRate) ?? 0
    }

    public static func normalizeSignature(_ text: String) -> String {
        let lowered = text.lowercased()
        let words = lowered.split { ch in
            !(ch.isLetter || ch.isNumber)
        }.map(String.init)
        let stop: Set<String> = ["the", "and", "for", "with", "this", "that", "from", "into", "your",
                                 "you", "are", "was", "were", "will", "should", "task", "build", "fix"]
        let kept = words.filter { $0.count > 2 && !stop.contains($0) }
        return kept.prefix(8).joined(separator: "-")
    }

    /// Categorize WHY a run failed, in ONE place so the great-loop and turn-end scorecard writers can't
    /// drift (review finding: the derivation was duplicated). Priority: hard provider fault → flaky →
    /// verifier-rejected → the loop/stall kind → high tool-failure rate → ungrounded/incomplete tail.
    /// Returns nil for a success (caller passes nil for a win).
    public static func scorecardReason(providerFault: Bool, flaky: Bool, verificationRejected: Bool,
                                       loopKind: String?, failureRate: Double, ungrounded: Bool) -> String? {
        if providerFault { return "providerFault" }
        if flaky { return "flaky" }
        if verificationRejected { return "verificationFail" }
        if let loopKind { return loopKind }
        if failureRate > 0.4 { return "toolFailures" }
        return ungrounded ? "ungrounded" : "incomplete"
    }

    public static func inferTaskTags(from text: String) -> [String] {
        let lowered = text.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { lowered.contains($0) } }
        var tags: [String] = []
        if has(["research", "docs", "document", "url", "web", "compare", "market", "strategy"]) {
            tags.append("research")
        }
        if has(["image", "screenshot", "video", "audio", "pdf", "media", "visual"]) {
            tags.append("vision")
        }
        if has(["implement", "code", "coding", "swift", "source", "edit", "build", "fix"]) {
            tags.append("coding")
        }
        if has(["architect", "design", "planner", "algorithm", "concurrency", "refactor",
                "schema", "parser", "compiler", "orchestrat", "routing"]) {
            tags.append("reasoning")
        }
        if has(["test", "verify", "review", "audit", "eval"]) {
            tags.append("verification")
        }
        return tags.isEmpty ? ["coding"] : tags
    }
}

public struct CaptainLearningSummary: Sendable, Equatable {
    public let role: String
    public let providerId: String
    public let taskTags: [String]
    public let language: String?
    public let samples: Int
    public let successes: Int
    public let averageJudgeScore: Double?
    public let averageTokens: Int
    public let averageLatencyMs: Int
    public let toolFailures: Int
    public let latestEpoch: Double

    public init(role: String, providerId: String, taskTags: [String], language: String?,
                samples: Int, successes: Int, averageJudgeScore: Double?,
                averageTokens: Int, averageLatencyMs: Int, toolFailures: Int,
                latestEpoch: Double) {
        self.role = role
        self.providerId = providerId
        self.taskTags = taskTags
        self.language = language
        self.samples = samples
        self.successes = successes
        self.averageJudgeScore = averageJudgeScore
        self.averageTokens = averageTokens
        self.averageLatencyMs = averageLatencyMs
        self.toolFailures = toolFailures
        self.latestEpoch = latestEpoch
    }

    public var successRate: Double { samples == 0 ? 0 : Double(successes) / Double(samples) }
    public var promoted: Bool { samples >= 3 && successRate >= 0.67 && toolFailures <= max(1, samples / 2) }

    public var scoreBoost: Double {
        guard promoted else { return 0 }
        var score = 8 + (successRate * 14)
        if let averageJudgeScore { score += averageJudgeScore * 4 }
        score -= min(4, Double(toolFailures))
        score -= min(3, Double(averageLatencyMs) / 20_000.0)
        return max(0, score)
    }

    public var shortDescription: String {
        let pct = Int((successRate * 100).rounded())
        let mode = promoted ? "promoted" : "shadow"
        return "\(providerId)/\(role) \(mode) \(successes)/\(samples) \(pct)%"
    }
}

public struct ModelAssignmentLearningContext: Sendable, Equatable {
    public let summaries: [CaptainLearningSummary]

    public init(summaries: [CaptainLearningSummary]) {
        self.summaries = summaries
    }

    public var isEmpty: Bool { summaries.isEmpty }

    public func evidence(providerId: String, role: String, taskTags: [String],
                         language: String?) -> CaptainLearningSummary? {
        let wantedTags = Set(taskTags.map { $0.lowercased() })
        let role = role.lowercased()
        let provider = providerId.lowercased()
        let lang = language?.lowercased()
        let matches = summaries.filter { summary in
            summary.providerId.lowercased() == provider
                && summary.role == role
                && (!Set(summary.taskTags).isDisjoint(with: wantedTags))
                && (lang == nil || summary.language?.lowercased() == lang || summary.language == nil)
        }
        return matches.max { a, b in
            if a.promoted != b.promoted { return !a.promoted && b.promoted }
            if a.scoreBoost != b.scoreBoost { return a.scoreBoost < b.scoreBoost }
            if a.samples != b.samples { return a.samples < b.samples }
            return a.latestEpoch < b.latestEpoch
        }
    }

    public var statusLine: String {
        guard !summaries.isEmpty else { return "learning shadow: no samples yet" }
        let promoted = summaries.filter(\.promoted).count
        let sampleCount = summaries.reduce(0) { $0 + $1.samples }
        return promoted > 0
            ? "learning active: \(promoted) promoted profile(s), \(sampleCount) sample(s)"
            : "learning shadow: \(sampleCount) sample(s), awaiting promotion"
    }
}

/// Centralized scorecard gates so thresholds aren't re-derived across EffortController/great-loop/etc.
public enum ScorecardThresholds {
    /// Below this many recent runs, a model is COLD-START NEUTRAL: no rank delta, no exclude — the system
    /// behaves exactly as it did before the scorecard existed. One transient 5xx can never exile a model.
    public static let minSamples = 3
    /// Auto-exclude is reserved for a CHRONIC offender: at least this many runs of evidence.
    public static let chronicMinSamples = 5
    public static let chronicFailureRate = 0.6
    public static let chronicLoopRate = 0.5
    /// Judge on the last N runs so a model that recovered isn't punished forever for ancient faults.
    public static let recencyWindow = 20
    /// A chronic offender whose last failure is older than this gets a fresh probe (never a permanent
    /// blacklist — otherwise a down-ranked model runs less, never gets sampled, and can never recover).
    public static let staleSeconds: Double = 24 * 3600
}

/// The Captain's at-a-glance judgement of a model, read by the escalator when it picks. Advisory: a
/// positive `rankDelta` nudges toward a strong model, a negative one away; `exclude` skips a chronic
/// offender UNLESS it's the only option (that guard lives in `pick`).
public struct ModelVerdict: Sendable, Equatable {
    public let providerId: String
    public let samples: Int
    public let successRate: Double
    public let failureRate: Double
    public let loopRate: Double
    public let byReason: [String: Int]
    public let lastFailureEpoch: Double?
    public let rankDelta: Int
    public let exclude: Bool
    public let reason: String

    public init(providerId: String, samples: Int, successRate: Double, failureRate: Double,
                loopRate: Double, byReason: [String: Int], lastFailureEpoch: Double?,
                rankDelta: Int, exclude: Bool, reason: String) {
        self.providerId = providerId; self.samples = samples
        self.successRate = successRate; self.failureRate = failureRate; self.loopRate = loopRate
        self.byReason = byReason; self.lastFailureEpoch = lastFailureEpoch
        self.rankDelta = rankDelta; self.exclude = exclude; self.reason = reason
    }
}

public final class CaptainLearningStore {
    public static let relativePath = ".kist/captain-learning.jsonl"

    private let path: String
    private let maxSamples: Int

    public init(projectRoot: String, maxSamples: Int = 5000) {
        self.path = projectRoot + "/" + Self.relativePath
        self.maxSamples = max(100, maxSamples)
    }

    public func load() -> [CaptainLearningSample] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            line.data(using: .utf8).flatMap { try? JSONDecoder().decode(CaptainLearningSample.self, from: $0) }
        }
    }

    public func record(_ sample: CaptainLearningSample) {
        var samples = load()
        samples.append(sample)
        if samples.count > maxSamples { samples = Array(samples.suffix(maxSamples)) }
        persist(samples)
    }

    public func record(_ samples: [CaptainLearningSample]) {
        guard !samples.isEmpty else { return }
        var all = load()
        all.append(contentsOf: samples)
        if all.count > maxSamples { all = Array(all.suffix(maxSamples)) }
        persist(all)
    }

    public func assignmentContext() -> ModelAssignmentLearningContext {
        ModelAssignmentLearningContext(summaries: Self.summarize(load()))
    }

    /// Per-model verdicts the escalator reads to steer toward strong models and away from failers/loopers.
    /// Keyed by lowercased providerId. `now` is injectable for tests.
    public func modelVerdicts(now: Double = Date().timeIntervalSince1970) -> [String: ModelVerdict] {
        Self.modelVerdicts(load(), now: now)
    }

    public static func modelVerdicts(_ samples: [CaptainLearningSample], now: Double) -> [String: ModelVerdict] {
        var byProvider: [String: [CaptainLearningSample]] = [:]
        for s in samples { byProvider[s.providerId.lowercased(), default: []].append(s) }
        var out: [String: ModelVerdict] = [:]
        for (pid, all) in byProvider { out[pid] = verdict(providerId: pid, samples: all, now: now) }
        return out
    }

    /// Deterministic per-model verdict over its recent runs. Cold-start neutral; chronic-exclude only;
    /// stale offenders get a probe. Pure (given `now`) so it is unit-testable without a clock.
    static func verdict(providerId: String, samples all: [CaptainLearningSample], now: Double) -> ModelVerdict {
        let recent = all.sorted { $0.atEpoch < $1.atEpoch }.suffix(ScorecardThresholds.recencyWindow)
        let n = recent.count
        let successes = recent.filter(\.success).count
        let successRate = n == 0 ? 0 : Double(successes) / Double(n)
        let failureRate = n == 0 ? 0 : 1 - successRate
        let looped = recent.filter { !$0.loopKinds.isEmpty || $0.wasStuck }.count
        let loopRate = n == 0 ? 0 : Double(looped) / Double(n)
        var byReason: [String: Int] = [:]
        for s in recent { if let r = s.failureReason { byReason[r, default: 0] += 1 } }
        let lastFailure = recent.filter { !$0.success }.map(\.atEpoch).max()

        // Cold-start neutral: not enough evidence ⇒ behave exactly like before the scorecard existed.
        guard n >= ScorecardThresholds.minSamples else {
            return ModelVerdict(providerId: providerId, samples: n, successRate: successRate,
                                failureRate: failureRate, loopRate: loopRate, byReason: byReason,
                                lastFailureEpoch: lastFailure, rankDelta: 0, exclude: false,
                                reason: "insufficient evidence (\(n) run\(n == 1 ? "" : "s"))")
        }
        // Reward strong, penalize failing/looping. Clamped so the scorecard NUDGES the static strength
        // table, never dominates it.
        let reward = Int((successRate * 5).rounded())
        let penalty = Int((failureRate * 6 + loopRate * 8).rounded())
        let rankDelta = max(-12, min(6, reward - penalty))

        // Chronic-offender exclude — but not if the last failure is stale (probe it; no permanent blacklist).
        let stale = lastFailure.map { now - $0 > ScorecardThresholds.staleSeconds } ?? true
        let chronic = n >= ScorecardThresholds.chronicMinSamples
            && (failureRate >= ScorecardThresholds.chronicFailureRate || loopRate >= ScorecardThresholds.chronicLoopRate)
        let exclude = chronic && !stale

        let pct = Int((successRate * 100).rounded())
        let loopPct = Int((loopRate * 100).rounded())
        let top = byReason.max { $0.value < $1.value }?.key
        let reason = exclude
            ? "chronic: \(pct)% ok · \(loopPct)% looped over \(n) runs\(top.map { " · \($0)" } ?? "")"
            : "\(pct)% ok over \(n) runs\(rankDelta != 0 ? " · Δrank \(rankDelta > 0 ? "+" : "")\(rankDelta)" : "")\(top.map { " · \($0)" } ?? "")"
        return ModelVerdict(providerId: providerId, samples: n, successRate: successRate,
                            failureRate: failureRate, loopRate: loopRate, byReason: byReason,
                            lastFailureEpoch: lastFailure, rankDelta: rankDelta, exclude: exclude, reason: reason)
    }

    public static func summarize(_ samples: [CaptainLearningSample]) -> [CaptainLearningSummary] {
        struct BucketKey: Hashable {
            let role: String
            let providerId: String
            let tag: String
            let language: String?
        }
        var buckets: [BucketKey: [CaptainLearningSample]] = [:]
        for sample in samples {
            let tags = sample.taskTags.isEmpty ? ["coding"] : sample.taskTags
            for tag in tags {
                let key = BucketKey(role: sample.role, providerId: sample.providerId,
                                    tag: tag, language: sample.language)
                buckets[key, default: []].append(sample)
            }
        }
        return buckets.map { key, values in
            let successes = values.filter(\.success).count
            let scored = values.compactMap(\.judgeScore)
            let avgScore = scored.isEmpty ? nil : scored.reduce(0, +) / Double(scored.count)
            let avgTokens = values.isEmpty ? 0 : values.reduce(0) { $0 + $1.tokens } / values.count
            let avgLatency = values.isEmpty ? 0 : values.reduce(0) { $0 + $1.latencyMs } / values.count
            let failures = values.reduce(0) { $0 + $1.toolFailures }
            let latest = values.map(\.atEpoch).max() ?? 0
            return CaptainLearningSummary(role: key.role, providerId: key.providerId,
                                          taskTags: [key.tag], language: key.language,
                                          samples: values.count, successes: successes,
                                          averageJudgeScore: avgScore, averageTokens: avgTokens,
                                          averageLatencyMs: avgLatency, toolFailures: failures,
                                          latestEpoch: latest)
        }.sorted { a, b in
            if a.promoted != b.promoted { return a.promoted && !b.promoted }
            if a.scoreBoost != b.scoreBoost { return a.scoreBoost > b.scoreBoost }
            if a.samples != b.samples { return a.samples > b.samples }
            return a.providerId < b.providerId
        }
    }

    private func persist(_ samples: [CaptainLearningSample]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let text = samples.compactMap { sample -> String? in
            (try? encoder.encode(sample)).flatMap { String(data: $0, encoding: .utf8) }
        }.joined(separator: "\n")
        try? (text + (text.isEmpty ? "" : "\n")).write(toFile: path, atomically: true, encoding: .utf8)
    }
}
